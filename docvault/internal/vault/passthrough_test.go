package vault

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// setupPassthrough makes an env with a real on-disk folder exposed as a
// passthrough drive, granting kim write access. readOnly controls the drive.
func setupPassthrough(t *testing.T, readOnly bool) (*env, string) {
	t.Helper()
	e := newEnv(t)
	backend := t.TempDir()
	// Seed the backend folder with an existing file and subfolder, as if it
	// were the company's live storage.
	if err := os.WriteFile(filepath.Join(backend, "기존문서.txt"), []byte("original"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(backend, "2024"), 0o755); err != nil {
		t.Fatal(err)
	}
	s, err := e.v.CreatePassthroughShare(e.admin, "스토리지", "P", backend, readOnly)
	if err != nil {
		t.Fatal(err)
	}
	if err := e.v.SetShareACL(e.admin, s.ID, []ACLEntry{
		{PrincipalType: "user", PrincipalID: e.kim.User.ID, Level: LevelWrite},
	}); err != nil {
		t.Fatal(err)
	}
	return e, backend
}

func TestPassthroughServesExistingFiles(t *testing.T) {
	e, _ := setupPassthrough(t, false)

	// Existing files are visible without any import.
	if got := names(t, e, e.kim, "스토리지", ""); !strings.Contains(got, "기존문서.txt") || !strings.Contains(got, "2024") {
		t.Fatalf("existing entries not listed: %q", got)
	}
	// And readable in place.
	if got := e.read(t, e.kim, "스토리지", "기존문서.txt"); got != "original" {
		t.Fatalf("read existing = %q, want original", got)
	}
}

func TestPassthroughWriteHitsDisk(t *testing.T) {
	e, backend := setupPassthrough(t, false)

	e.put(t, e.kim, "스토리지", "새파일.txt", "hello")
	// The write lands on the real folder as a plain file (no hash-blob store).
	b, err := os.ReadFile(filepath.Join(backend, "새파일.txt"))
	if err != nil {
		t.Fatalf("file not on disk: %v", err)
	}
	if string(b) != "hello" {
		t.Fatalf("disk content = %q, want hello", b)
	}
	// Overwriting an existing file works too.
	e.put(t, e.kim, "스토리지", "기존문서.txt", "updated")
	if got := e.read(t, e.kim, "스토리지", "기존문서.txt"); got != "updated" {
		t.Fatalf("overwrite = %q, want updated", got)
	}
}

func TestPassthroughReadOnlyBlocksWrites(t *testing.T) {
	e, backend := setupPassthrough(t, true)

	// Reads still work.
	if got := e.read(t, e.kim, "스토리지", "기존문서.txt"); got != "original" {
		t.Fatalf("read on read-only = %q", got)
	}
	// Writes are refused before touching disk.
	if _, _, err := e.v.Put(e.kim, "스토리지", "막힘.txt", strings.NewReader("x")); err == nil {
		t.Fatal("write to read-only drive should fail")
	}
	if _, err := os.Stat(filepath.Join(backend, "막힘.txt")); !os.IsNotExist(err) {
		t.Fatal("read-only drive must not create files on disk")
	}
	// Mkdir and delete are refused too.
	if err := e.v.Mkdir(e.kim, "스토리지", "새폴더"); err == nil {
		t.Fatal("mkdir on read-only drive should fail")
	}
	if err := e.v.Delete(e.kim, "스토리지", "기존문서.txt"); err == nil {
		t.Fatal("delete on read-only drive should fail")
	}
	// The original file is untouched.
	if _, err := os.Stat(filepath.Join(backend, "기존문서.txt")); err != nil {
		t.Fatalf("original file disturbed: %v", err)
	}
}

func TestPassthroughRejectsPathEscape(t *testing.T) {
	e, _ := setupPassthrough(t, false)
	// A traversal attempt must not read outside the backend folder.
	if _, f, err := e.v.Open(e.kim, "스토리지", "../../etc/passwd"); err == nil {
		if f != nil {
			io.Copy(io.Discard, f)
			f.Close()
		}
		t.Fatal("path escape should be rejected")
	}
}
