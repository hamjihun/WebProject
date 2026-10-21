// Package backup copies the DocVault database and file store to an offline
// disk (e.g. a USB drive) so the system can be restored even if the server
// and the NAS are both lost (hardware failure, ransomware).
//
// The file store is content-addressed: a blob never changes once written, so
// a backup only needs to copy blobs the target does not already have
// (incremental). The database is small and is copied in full as a consistent
// snapshot (VACUUM INTO), keeping the most recent snapshots.
package backup

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// FolderName is the directory created on the backup disk.
const FolderName = "DocVaultBackup"

const keepDBSnapshots = 14

// Result summarises one backup run.
type Result struct {
	StartedAt    time.Time `json:"startedAt"`
	FinishedAt   time.Time `json:"finishedAt"`
	BlobsCopied  int64     `json:"blobsCopied"`
	BytesCopied  int64     `json:"bytesCopied"`
	BlobsTotal   int64     `json:"blobsTotal"`
	BytesTotal   int64     `json:"bytesTotal"`
	DBSnapshot   string    `json:"dbSnapshot"`
	DBBytes      int64     `json:"dbBytes"`
	TargetFreeGB float64   `json:"targetFreeGB"`
	Error        string    `json:"error,omitempty"`
	DurationSec  int64     `json:"durationSec"`
}

// Progress is called with human-readable step lines (for the console).
type Progress func(string)

// Run backs up the database and store under dest/DocVaultBackup.
func Run(db *sql.DB, storeDir, dest string, log Progress) (*Result, error) {
	if log == nil {
		log = func(string) {}
	}
	r := &Result{StartedAt: time.Now()}
	root := filepath.Join(dest, FolderName)
	blobDst := filepath.Join(root, "blobs")
	dbDst := filepath.Join(root, "db")
	for _, d := range []string{blobDst, dbDst} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return r, fmt.Errorf("백업 폴더를 만들 수 없습니다 (%s): %w", d, err)
		}
	}

	// 1) Database snapshot (consistent, via VACUUM INTO).
	log("데이터베이스 백업 중...")
	name := "docvault-" + r.StartedAt.Format("20060102-150405") + ".db"
	snap := filepath.Join(dbDst, name)
	if _, err := db.Exec("VACUUM INTO ?", snap); err != nil {
		return r, fmt.Errorf("데이터베이스 백업 실패: %w", err)
	}
	if st, err := os.Stat(snap); err == nil {
		r.DBBytes = st.Size()
	}
	r.DBSnapshot = name
	pruneOldSnapshots(dbDst, log)

	// 2) Blobs (incremental: copy only what the target is missing).
	log("파일 백업 중... (새로 생긴 파일만 복사)")
	srcBlobs := filepath.Join(storeDir, "blobs")
	err := filepath.Walk(srcBlobs, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		r.BlobsTotal++
		r.BytesTotal += info.Size()
		rel, _ := filepath.Rel(srcBlobs, path)
		out := filepath.Join(blobDst, rel)
		if st, err := os.Stat(out); err == nil && st.Size() == info.Size() {
			return nil // already backed up (content-addressed: never changes)
		}
		if err := copyFile(path, out); err != nil {
			return fmt.Errorf("파일 복사 실패 (%s): %w", rel, err)
		}
		r.BlobsCopied++
		r.BytesCopied += info.Size()
		if r.BlobsCopied%500 == 0 {
			log(fmt.Sprintf("  ... %d개 복사 (%s)", r.BlobsCopied, humanBytes(r.BytesCopied)))
		}
		return nil
	})
	if err != nil {
		return r, err
	}

	r.FinishedAt = time.Now()
	r.DurationSec = int64(r.FinishedAt.Sub(r.StartedAt).Seconds())
	r.TargetFreeGB = freeGB(dest)
	writeManifest(root, r)
	log(fmt.Sprintf("완료: 새 파일 %d개 (%s), 전체 %d개 (%s), %d초",
		r.BlobsCopied, humanBytes(r.BytesCopied), r.BlobsTotal, humanBytes(r.BytesTotal), r.DurationSec))
	return r, nil
}

func pruneOldSnapshots(dbDst string, log Progress) {
	entries, _ := os.ReadDir(dbDst)
	var snaps []string
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "docvault-") && strings.HasSuffix(e.Name(), ".db") {
			snaps = append(snaps, e.Name())
		}
	}
	sort.Strings(snaps) // names sort by time
	for len(snaps) > keepDBSnapshots {
		os.Remove(filepath.Join(dbDst, snaps[0]))
		snaps = snaps[1:]
	}
}

func writeManifest(root string, r *Result) {
	b, _ := json.MarshalIndent(r, "", "  ")
	os.WriteFile(filepath.Join(root, "last-backup.json"), b, 0o644)
	// A human-readable note next to it.
	note := fmt.Sprintf("DocVault 백업\r\n마지막 백업: %s\r\n파일: %d개 (%s)\r\nDB 스냅샷: %s\r\n\r\n복구 방법은 서버 폴더의 README 또는 관리자에게 문의하세요.\r\n",
		r.FinishedAt.Format("2006-01-02 15:04:05"), r.BlobsTotal, humanBytes(r.BytesTotal), r.DBSnapshot)
	os.WriteFile(filepath.Join(root, "읽어보기.txt"), []byte("\xef\xbb\xbf"+note), 0o644)
}

// LoadLast reads the last backup result from a backup disk (or the store's
// configured backup dir), returning nil if there is none.
func LoadLast(dest string) *Result {
	b, err := os.ReadFile(filepath.Join(dest, FolderName, "last-backup.json"))
	if err != nil {
		return nil
	}
	var r Result
	if json.Unmarshal(b, &r) != nil {
		return nil
	}
	return &r
}

func copyFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".part"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

func humanBytes(n int64) string {
	const u = 1024
	if n < u {
		return fmt.Sprintf("%dB", n)
	}
	div, exp := int64(u), 0
	for m := n / u; m >= u; m /= u {
		div *= u
		exp++
	}
	return fmt.Sprintf("%.1f%cB", float64(n)/float64(div), "KMGTPE"[exp])
}
