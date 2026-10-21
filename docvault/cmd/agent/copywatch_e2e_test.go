package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"docvault/internal/api"
	"docvault/internal/blob"
	"docvault/internal/dav"
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

	// A browser download that finished on the desktop is deleted.
	if !a.blockDownload.Load() {
		t.Fatal("download block should be on for a regular user")
	}
	if !isPartialDownload(`C:\Users\kim\Desktop\Unconfirmed 1234.crdownload`) || isPartialDownload(`C:\a\b.xlsx`) {
		t.Fatal("isPartialDownload")
	}
	dl := filepath.Join(desk, "견적서.pdf")
	os.WriteFile(dl, []byte("pdf"), 0o644)
	a.noteDownloadFinished(dl)
	for i := 0; i < 50; i++ {
		if entries, _, _ = v.QueryAudit(vault.AuditQuery{Action: "block_download"}); len(entries) == 1 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := os.Stat(dl); !os.IsNotExist(err) || len(entries) != 1 {
		t.Fatalf("download not removed/logged: %v %d", err, len(entries))
	}
	// Admins are not blocked.
	kim.IsAdmin = true
	v.UpdateUser(admin, kim.ID, vault.UserUpdate{IsAdmin: &kim.IsAdmin})
	a.updatePolicy()
	if a.blockDownload.Load() || a.copyWatch.Load() {
		t.Fatal("admin should not be blocked")
	}
}

// A copy that matches a protected drive file is removed, unless the drive
// just reported serving that content out of the 반출 folder (export token).
func TestExportTokenKeepsCopy(t *testing.T) {
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	bs, _ := blob.New(filepath.Join(dir, "store"))
	v := vault.New(d, bs)
	admin := vault.Actor{Client: "test"}
	kim, _ := v.CreateUser(admin, "kim", "kim", "password123", false)
	v.CreateShare(admin, "개인문서함", "F", true, 0)
	body := "quarterly report body"
	v.Put(vault.Actor{User: kim, Client: "test"}, "개인문서함", "/report.xlsx", strings.NewReader(body))
	tok, _, _ := v.Login("kim", "password123", "agent", "pc", "127.0.0.1")
	mux := http.NewServeMux()
	(&api.API{V: v}).Register(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()
	a := &agent{cfg: &Config{Server: srv.URL}, mounts: map[string]*mount{}}
	a.client = newClient(a.cfg, tok)
	t.Setenv("LOCALAPPDATA", dir)
	a.updatePolicy()

	desk := filepath.Join(dir, "Desktop")
	os.MkdirAll(desk, 0o755)
	write := func(name string) string {
		p := filepath.Join(desk, name)
		os.WriteFile(p, []byte(body), 0o644)
		return p
	}

	// No token: an ordinary copy of the original is removed.
	p1 := write("report.xlsx")
	a.checkLocal(p1)
	if _, err := os.Stat(p1); !os.IsNotExist(err) {
		t.Fatal("copy without a token should be removed")
	}
	// Token present (drive served it from 반출): the copy is kept.
	a.noteExportRead(int64(len(body)))
	p2 := write("report (2).xlsx")
	a.checkLocal(p2)
	if _, err := os.Stat(p2); err != nil {
		t.Fatal("copy with an export token should be kept")
	}
	// Token is single-use: a second copy is removed again.
	p3 := write("report (3).xlsx")
	a.checkLocal(p3)
	if _, err := os.Stat(p3); !os.IsNotExist(err) {
		t.Fatal("token should be consumed; second copy removed")
	}
}

func TestLoginBlockedOffNetwork(t *testing.T) {
	// No server listening here: login must fail with the off-network error.
	cfg := &Config{Server: "http://127.0.0.1:1"} // nothing listens
	if reachable(cfg.Server) {
		t.Fatal("should be unreachable")
	}
	if err := passwordLogin(cfg, "kim", "password123"); err != errServerUnreachable {
		t.Fatalf("expected off-network error, got %v", err)
	}
}

// A document saved on the PC while a confidential file is open is moved into
// 개인문서함 (not lost) and the local copy is removed.
func TestSaveAsRedirect(t *testing.T) {
	dir := t.TempDir()
	d, _ := db.Open(filepath.Join(dir, "t.db"))
	defer d.Close()
	bs, _ := blob.New(filepath.Join(dir, "store"))
	v := vault.New(d, bs)
	admin := vault.Actor{Client: "test"}
	kim, _ := v.CreateUser(admin, "kim", "kim", "password123", false)
	v.CreateShare(admin, "개인문서함", "F", true, 0)
	tok, _, _ := v.Login("kim", "password123", "agent", "pc", "127.0.0.1")
	mux := http.NewServeMux()
	(&api.API{V: v}).Register(mux)
	mux.Handle("/dav/", &dav.Handler{V: v, Prefix: "/dav"})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	a := &agent{cfg: &Config{Server: srv.URL}, mounts: map[string]*mount{}, personalDrive: "개인문서함"}
	a.client = newClient(a.cfg, tok)

	desk := filepath.Join(dir, "Desktop")
	os.MkdirAll(desk, 0o755)
	f := filepath.Join(desk, "보고서.xlsx")
	os.WriteFile(f, []byte("brand new content from Save As"), 0o644)

	// No document open: a save is left alone by the redirect path.
	if a.docActive() {
		t.Fatal("no doc open yet")
	}
	// Document program opens a confidential file:
	a.noteDocOpen(42)
	if !a.docActive() {
		t.Fatal("doc should be active")
	}
	if a.handleLocal(f) {
		t.Fatal("unexpected retry")
	}
	if _, err := os.Stat(f); !os.IsNotExist(err) {
		t.Fatal("local file should be moved away")
	}
	// It must now be in 개인문서함\PC에서_옮김
	nodes, err := v.List(vault.Actor{User: kim, Client: "test"}, "개인문서함", "/"+redirectFolder)
	if err != nil || len(nodes) != 1 || nodes[0].Name != "보고서.xlsx" {
		t.Fatalf("redirected file: %v %+v", err, nodes)
	}
	_, rf, _ := v.Open(vault.Actor{User: kim, Client: "test"}, "개인문서함", "/"+redirectFolder+"/보고서.xlsx")
	b, _ := io.ReadAll(rf)
	rf.Close()
	if string(b) != "brand new content from Save As" {
		t.Fatalf("content %q", b)
	}
	// Second save of the same name goes to "보고서 (2).xlsx"
	os.WriteFile(f, []byte("second"), 0o644)
	a.handleLocal(f)
	nodes, _ = v.List(vault.Actor{User: kim, Client: "test"}, "개인문서함", "/"+redirectFolder)
	if len(nodes) != 2 {
		t.Fatalf("expected 2 files, got %d", len(nodes))
	}
	// After close and once the short backup window has lapsed, it is inactive.
	a.noteDocClose(42)
	docSession.Lock()
	docSession.lastOpen = time.Now().Add(-docWindow - time.Second)
	docSession.Unlock()
	if a.docActive() {
		t.Fatal("doc should be inactive after close and window")
	}
}
