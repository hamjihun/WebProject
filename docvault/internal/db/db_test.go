package db

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// A database created by an older release gains the columns added since.
func TestUpgradeAddsColumns(t *testing.T) {
	p := filepath.Join(t.TempDir(), "old.db")
	old, err := sql.Open("sqlite", p)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := old.Exec(`CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE COLLATE NOCASE,
		display_name TEXT NOT NULL DEFAULT '', password_hash TEXT NOT NULL DEFAULT '', is_admin INTEGER NOT NULL DEFAULT 0,
		disabled INTEGER NOT NULL DEFAULT 0, write_blocked INTEGER NOT NULL DEFAULT 0, failed_logins INTEGER NOT NULL DEFAULT 0,
		locked_until INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL);
		INSERT INTO users(username, created_at) VALUES('kim', 1)`); err != nil {
		t.Fatal(err)
	}
	old.Close()
	d, err := Open(p)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	var allow int
	if err := d.QueryRow(`SELECT allow_copy FROM users WHERE username='kim'`).Scan(&allow); err != nil || allow != 0 {
		t.Fatalf("allow_copy: %v %d", err, allow)
	}
	d.Close()
	if d, err = Open(p); err != nil { // opening again is a no-op
		t.Fatal(err)
	}
}
