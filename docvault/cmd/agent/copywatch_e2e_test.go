package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"docvault/internal/api"
	"docvault/internal/blob"
	"docvault/internal/db"
	"docvault/internal/vault"
)

// A copy of a drive file made on the PC is removed; other files stay.
func TestCopyWatchRemovesDriveCopies(t *testing.T) {
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	bs, _ := blob.New(filepath.Join(dir, "store"))
	v := vault.New(d, bs)
	admin := vault.Actor{Client: "test"}
	kim, err := v.CreateUser(admin, "kim", "kim", "password123", false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := v.CreateShare(admin, "개인문서함", "F", true, 0); err != nil {
		t.Fatal(err)
	}
	if _, _, err := v.Put(vault.Actor{User: kim, Client: "test"}, "개인문서함", "/test.xlsx", strings.NewReader("quarterly numbers")); err != nil {
		t.Fatal(err)
	}
	tok, _, err := v.Login("kim", "password123", "agent", "pc", "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	(&api.API{V: v}).Register(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	a := &agent{cfg: &Config{Server: srv.URL}, mounts: map[string]*mount{}}
	a.client = newClient(a.cfg, tok)
	t.Setenv("LOCALAPPDATA", dir)
	t.Setenv("HOME", dir)
	a.updatePolicy()
	if !a.copyWatch.Load() {
		t.Fatal("copy watch should be on for a regular user")
	}

	desk := filepath.Join(dir, "Desktop")
	os.MkdirAll(desk, 0o755)
	copyFile := filepath.Join(desk, "test (2).xlsx")
	same := filepath.Join(desk, "mine.txt")
	os.WriteFile(copyFile, []byte("quarterly numbers"), 0o644)
	os.WriteFile(same, []byte("quarterly numberz"), 0o644) // same size, other content

	if a.checkLocal(copyFile) {
		t.Fatal("unexpected retry")
	}
	if _, err := os.Stat(copyFile); !os.IsNotExist(err) {
		t.Fatal("copy of a drive file was not removed")
	}
	a.checkLocal(same)
	if _, err := os.Stat(same); err != nil {
		t.Fatal("unrelated file was removed")
	}
	entries, _, _ := v.QueryAudit(vault.AuditQuery{Action: "block_copy"})
	if len(entries) != 1 {
		t.Fatalf("audit entries: %d", len(entries))
	}
}
