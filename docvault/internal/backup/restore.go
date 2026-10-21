package backup

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Restore rebuilds a store and database from a backup disk. storeDir and
// dataDir must be empty or not yet in use (restore into a fresh server).
// If dbSnapshot is "", the newest snapshot is used.
func Restore(backupDisk, storeDir, dataDir, dbSnapshot string, log Progress) error {
	if log == nil {
		log = func(string) {}
	}
	root := filepath.Join(backupDisk, FolderName)
	if _, err := os.Stat(root); err != nil {
		return fmt.Errorf("백업을 찾을 수 없습니다: %s", root)
	}

	// 1) Blobs → store.
	log("파일 복구 중...")
	srcBlobs := filepath.Join(root, "blobs")
	dstBlobs := filepath.Join(storeDir, "blobs")
	var n int64
	err := filepath.Walk(srcBlobs, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(srcBlobs, path)
		out := filepath.Join(dstBlobs, rel)
		if st, err := os.Stat(out); err == nil && st.Size() == info.Size() {
			return nil
		}
		if err := copyFile(path, out); err != nil {
			return err
		}
		n++
		if n%500 == 0 {
			log(fmt.Sprintf("  ... 파일 %d개 복구", n))
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("파일 복구 실패: %w", err)
	}
	os.MkdirAll(filepath.Join(storeDir, "tmp"), 0o750)

	// 2) Database snapshot → data dir.
	snap := dbSnapshot
	if snap == "" {
		snap = newestSnapshot(filepath.Join(root, "db"))
	}
	if snap == "" {
		return fmt.Errorf("백업에 데이터베이스 스냅샷이 없습니다")
	}
	log("데이터베이스 복구: " + snap)
	if err := os.MkdirAll(dataDir, 0o750); err != nil {
		return err
	}
	if err := copyFile(filepath.Join(root, "db", snap), filepath.Join(dataDir, "docvault.db")); err != nil {
		return fmt.Errorf("데이터베이스 복구 실패: %w", err)
	}
	// Remove stale WAL/SHM from any previous run.
	os.Remove(filepath.Join(dataDir, "docvault.db-wal"))
	os.Remove(filepath.Join(dataDir, "docvault.db-shm"))
	log(fmt.Sprintf("복구 완료: 파일 %d개, DB %s", n, snap))
	return nil
}

// Snapshots lists the database snapshots on a backup disk, newest first.
func Snapshots(backupDisk string) []string {
	entries, _ := os.ReadDir(filepath.Join(backupDisk, FolderName, "db"))
	var out []string
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "docvault-") && strings.HasSuffix(e.Name(), ".db") {
			out = append(out, e.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(out)))
	return out
}

func newestSnapshot(dbDir string) string {
	entries, _ := os.ReadDir(dbDir)
	var out []string
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "docvault-") && strings.HasSuffix(e.Name(), ".db") {
			out = append(out, e.Name())
		}
	}
	if len(out) == 0 {
		return ""
	}
	sort.Strings(out)
	return out[len(out)-1] // newest
}
