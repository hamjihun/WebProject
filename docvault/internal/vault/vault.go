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
)

type Vault struct {
	DB    *sql.DB
	Blobs *blob.Store
	// Now returns the current Unix time in seconds; overridable in tests.
	Now func() int64

	readMu   sync.Mutex
	lastRead map[string]int64
}

func New(db *sql.DB, blobs *blob.Store) *Vault {
	return &Vault{
		DB:       db,
		Blobs:    blobs,
		Now:      func() int64 { return time.Now().Unix() },
		lastRead: map[string]int64{},
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
	return tx.Commit()
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
}

func SettingKeys() []string {
	return []string{"retention_days", "version_keep_days", "version_keep_count",
		"export_valid_days", "export_max_downloads", "session_web_hours", "session_agent_days"}
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
