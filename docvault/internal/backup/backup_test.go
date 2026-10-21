package backup

import (
	"io"
	"os"
	"path/filepath"
	"testing"

	"docvault/internal/blob"
	"docvault/internal/db"
)

func TestBackupRestoreRoundTrip(t *testing.T) {
	src := t.TempDir()
	disk := t.TempDir()
	store := filepath.Join(src, "store")
	data := filepath.Join(src, "data")
	os.MkdirAll(data, 0o750)
	bs, _ := blob.New(store)
	d, err := db.Open(filepath.Join(data, "docvault.db"))
	if err != nil {
		t.Fatal(err)
	}
	// put some blobs + a settings row to prove the DB is restored
	shas := map[string]string{}
	for _, body := range []string{"alpha", "beta", "gamma", "delta"} {
		sha, _, err := bs.Put(strReader(body), 0)
		if err != nil {
			t.Fatal(err)
		}
		shas[body] = sha
	}
	d.Exec(`CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT)`)
	d.Exec(`INSERT INTO settings(key,value) VALUES('marker','hello')`)

	// backup
	r, err := Run(d, store, disk, nil)
	if err != nil {
		t.Fatalf("backup: %v", err)
	}
	if r.BlobsCopied != int64(len(shas)) || r.DBSnapshot == "" {
		t.Fatalf("result %+v", r)
	}
	// second backup copies nothing new (incremental)
	r2, _ := Run(d, store, disk, nil)
	if r2.BlobsCopied != 0 {
		t.Fatalf("incremental copied %d, want 0", r2.BlobsCopied)
	}
	d.Close()

	// restore into a fresh location
	dst := t.TempDir()
	if err := Restore(disk, filepath.Join(dst, "store"), filepath.Join(dst, "data"), "", nil); err != nil {
		t.Fatalf("restore: %v", err)
	}
	bs2, _ := blob.New(filepath.Join(dst, "store"))
	for body, sha := range shas {
		if !bs2.Exists(sha) {
			t.Fatalf("blob for %q missing after restore", body)
		}
	}
	d2, err := db.Open(filepath.Join(dst, "data", "docvault.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d2.Close()
	var v string
	if err := d2.QueryRow(`SELECT value FROM settings WHERE key='marker'`).Scan(&v); err != nil || v != "hello" {
		t.Fatalf("db not restored: %v %q", err, v)
	}
}

type sr struct{ s string }

func (r *sr) Read(p []byte) (int, error) {
	if r.s == "" {
		return 0, io.EOF
	}
	n := copy(p, r.s)
	r.s = r.s[n:]
	return n, nil
}

func strReader(s string) *sr { return &sr{s} }
