// Package vault holds the document-centralization business logic:
// users and permissions, files with automatic versioning, the trash
// (soft delete with a retention period), export (반출) approval and the audit log.
package vault

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"sync"
	"time"

	"docvault/internal/blob"
)

var (
	ErrNotFound     = errors.New("not found")
	ErrExists       = errors.New("already exists")
	ErrForbidden    = errors.New("forbidden")
	ErrConflict     = errors.New("conflict")
	ErrQuota        = errors.New("quota exceeded")
	ErrInvalidName  = errors.New("invalid name")
	ErrIsDir        = errors.New("is a directory")
	ErrNotDir       = errors.New("not a directory")
	ErrUnauthorized = errors.New("unauthorized")
	ErrLocked       = errors.New("account locked")
	ErrBadRequest   = errors.New("bad request")
	// ErrNoContent: the file is listed but its content is missing from the
	// store (e.g. the store folder was changed). Not worth retrying.
	ErrNoContent = errors.New("file content missing from store")
)

type Vault struct {
	DB    *sql.DB
	Blobs *blob.Store
	// Now returns the current Unix time in seconds; overridable in tests.
	Now func() int64

	readMu   sync.Mutex
	lastRead map[string]int64

	// blobMu keeps garbage collection from deleting a blob that an upload is
	// about to reference: uploads hold it shared, GC holds it exclusively.
	blobMu sync.RWMutex

	guardMu sync.Mutex
	guardEv map[int64][]int64

	usageMu    sync.Mutex
	usageCache map[[2]int64][2]int64 // (share, owner) -> (bytes, computed at)
}

func New(db *sql.DB, blobs *blob.Store) *Vault {
	return &Vault{
		DB:       db,
		Blobs:    blobs,
		Now:      func() int64 { return time.Now().Unix() },
		lastRead: map[string]int64{},
		guardEv:  map[int64][]int64{},

		usageCache: map[[2]int64][2]int64{},
	}
}

// Actor is who performs an operation, for permission checks and the audit log.
type Actor struct {
	User   *User
	IP     string
	Client string // "drive", "web", "agent", "system"
}

func (v *Vault) withTx(fn func(tx *sql.Tx) error) error {
	tx, err := v.DB.BeginTx(context.Background(), nil)
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		tx.Rollback()
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	// Any committed change may have changed how much space a drive uses.
	v.usageMu.Lock()
	clear(v.usageCache)
	v.usageMu.Unlock()
	return nil
}

func randomID(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

// ---- settings ----

var defaultSettings = map[string]int64{
	"retention_days":       180, // 휴지통 보관 기간
	"version_keep_days":    180, // 이전 버전 보관 기간
	"version_keep_count":   20,  // 기간이 지나도 최소한 남길 최근 버전 수
	"export_valid_days":    7,   // 반출 승인 후 다운로드 가능 기간
	"export_max_downloads": 3,
	"session_web_hours":    12,
	"session_agent_days":   30,
	"guard_threshold":      200, // 랜섬웨어 의심: 이 건수 이상 수정하면(삭제는 2건=1건) 쓰기 차단 (0=끔)
	"guard_window_sec":     300, // 위 횟수를 세는 시간(초)
	"block_copy_out":       1,   // 탐색기·명령창·압축 프로그램으로 PC에 복사 차단
	"block_messenger":      1,   // 카카오톡 등 메신저 첨부 차단
	"block_browser_upload": 0,   // 웹브라우저 업로드(웹메일 첨부 등) 차단
	"block_download_local": 1,   // 웹브라우저 다운로드를 PC(바탕화면 등)에 저장 차단
	"allow_post_export":    1,   // 후결재 반출: 신청하면 바로 반출 폴더에, 결재는 나중에
}

// String settings (stored in the same table).
var defaultStringSettings = map[string]string{
	"block_extra_processes": "", // 추가로 차단할 프로그램 (쉼표로 구분, 예: slack.exe, teams.exe)
}

func (v *Vault) StringSetting(key string) string {
	var s string
	if err := v.DB.QueryRow(`SELECT value FROM settings WHERE key=?`, key).Scan(&s); err == nil {
		return s
	}
	return defaultStringSettings[key]
}

func (v *Vault) SetStringSetting(a Actor, key, val string) error {
	if _, ok := defaultStringSettings[key]; !ok {
		return ErrBadRequest
	}
	val = strings.TrimSpace(val)
	_, err := v.DB.Exec(`INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`, key, val)
	if err == nil {
		v.Audit(a, "admin_setting", "", "", key+"="+val)
	}
	return err
}

func SettingKeys() []string {
	return []string{"retention_days", "version_keep_days", "version_keep_count",
		"export_valid_days", "export_max_downloads", "session_web_hours", "session_agent_days",
		"guard_threshold", "guard_window_sec", "block_copy_out", "block_messenger", "block_browser_upload", "block_download_local", "allow_post_export"}
}

func (v *Vault) Setting(key string) int64 {
	var s string
	if err := v.DB.QueryRow(`SELECT value FROM settings WHERE key=?`, key).Scan(&s); err == nil {
		if n, err := strconv.ParseInt(s, 10, 64); err == nil {
			return n
		}
	}
	return defaultSettings[key]
}

func (v *Vault) settingTx(tx *sql.Tx, key string) int64 {
	var s string
	if err := tx.QueryRow(`SELECT value FROM settings WHERE key=?`, key).Scan(&s); err == nil {
		if n, err := strconv.ParseInt(s, 10, 64); err == nil {
			return n
		}
	}
	return defaultSettings[key]
}

func (v *Vault) Settings() map[string]int64 {
	out := map[string]int64{}
	for _, k := range SettingKeys() {
		out[k] = v.Setting(k)
	}
	return out
}

func (v *Vault) SetSetting(a Actor, key string, val int64) error {
	if _, ok := defaultSettings[key]; !ok {
		return ErrBadRequest
	}
	if val < 0 || (key == "retention_days" && val < 1) {
		return ErrBadRequest
	}
	_, err := v.DB.Exec(`INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`,
		key, strconv.FormatInt(val, 10))
	if err == nil {
		v.Audit(a, "admin_setting", "", "", key+"="+strconv.FormatInt(val, 10))
	}
	return err
}
