package dav

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"

	"docvault/internal/blob"
	"docvault/internal/db"
	"docvault/internal/vault"
)

func setup(t *testing.T) (*httptest.Server, *vault.Vault, string) {
	t.Helper()
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	bs, _ := blob.New(filepath.Join(dir, "store"))
	v := vault.New(d, bs)
	sys := vault.Actor{Client: "test"}
	u, _ := v.CreateUser(sys, "kim", "", "password123", false)
	s, _ := v.CreateShare(sys, "영업", "O", false, 1000)
	v.SetShareACL(sys, s.ID, []vault.ACLEntry{{PrincipalType: "user", PrincipalID: u.ID, Level: vault.LevelWrite}})
	tok, _, err := v.Login("kim", "password123", "agent", "", "")
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(&Handler{V: v, Prefix: "/dav"})
	t.Cleanup(srv.Close)
	return srv, v, tok
}

func do(t *testing.T, srv *httptest.Server, tok, method, p, body string, hdr map[string]string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(method, srv.URL+"/dav/"+url.PathEscape("영업")+p, strings.NewReader(body))
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func TestDAV(t *testing.T) {
	srv, _, tok := setup(t)
	if c, _ := do(t, srv, "", "PROPFIND", "/", "", nil); c != 401 {
		t.Fatalf("anonymous: %d", c)
	}
	if c, _ := do(t, srv, tok, "MKCOL", "/폴더", "", nil); c != 201 {
		t.Fatalf("mkcol %d", c)
	}
	if c, _ := do(t, srv, tok, "PUT", "/폴더/a.txt", "hello", nil); c != 201 {
		t.Fatalf("put %d", c)
	}
	if c, _ := do(t, srv, tok, "PUT", "/폴더/a.txt", "hello2", nil); c != 204 {
		t.Fatalf("put again %d", c)
	}
	if c, _ := do(t, srv, tok, "PUT", "/없는폴더/a.txt", "x", nil); c != 409 {
		t.Fatalf("put without parent %d", c)
	}
	c, body := do(t, srv, tok, "PROPFIND", "/", "", map[string]string{"Depth": "1"})
	if c != 207 || !strings.Contains(body, "<D:quota-available-bytes>994</D:quota-available-bytes>") ||
		!strings.Contains(body, "/dav/%EC%98%81%EC%97%85/%ED%8F%B4%EB%8D%94/") {
		t.Fatalf("propfind %d %s", c, body)
	}
	if c, b := do(t, srv, tok, "GET", "/폴더/a.txt", "", map[string]string{"Range": "bytes=1-3"}); c != 206 || b != "ell" {
		t.Fatalf("range get %d %q", c, b)
	}
	dest := srv.URL + "/dav/" + url.PathEscape("영업") + "/" + url.PathEscape("b.txt")
	if c, _ := do(t, srv, tok, "COPY", "/폴더/a.txt", "", map[string]string{"Destination": dest}); c != 201 {
		t.Fatalf("copy %d", c)
	}
	if c, _ := do(t, srv, tok, "MOVE", "/폴더/a.txt", "", map[string]string{"Destination": dest, "Overwrite": "F"}); c != 412 {
		t.Fatalf("move no-overwrite %d", c)
	}
	if c, _ := do(t, srv, tok, "MOVE", "/폴더/a.txt", "", map[string]string{"Destination": dest}); c != 204 {
		t.Fatalf("move overwrite %d", c)
	}
	if c, b := do(t, srv, tok, "GET", "/b.txt", "", nil); c != 200 || b != "hello2" {
		t.Fatalf("get moved %d %q", c, b)
	}
	if c, _ := do(t, srv, tok, "PUT", "/big.bin", strings.Repeat("x", 2000), nil); c != 507 {
		t.Fatalf("quota %d", c)
	}
	if c, _ := do(t, srv, tok, "PUT", "/bad:name.txt", "x", nil); c != 400 {
		t.Fatalf("invalid name %d", c)
	}
	if c, _ := do(t, srv, tok, "DELETE", "/b.txt", "", nil); c != 204 {
		t.Fatalf("delete %d", c)
	}
	if c, _ := do(t, srv, tok, "GET", "/b.txt", "", nil); c != 404 {
		t.Fatalf("get deleted %d", c)
	}
	other := srv.URL + "/dav/" + url.PathEscape("남의드라이브") + "/x.txt"
	if c, _ := do(t, srv, tok, "COPY", "/폴더", "", map[string]string{"Destination": other}); c != 404 {
		t.Fatalf("copy to inaccessible drive %d", c)
	}
}
