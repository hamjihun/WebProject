package vault

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"path/filepath"
	"strings"
	"testing"

	"docvault/internal/blob"
	"docvault/internal/db"
)

type env struct {
	v     *Vault
	now   int64
	admin Actor
	kim   Actor // write on 영업
	lee   Actor // read on 영업
	boss  Actor // manage (팀장) on 영업
}

func newEnv(t *testing.T) *env {
	t.Helper()
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	bs, err := blob.New(filepath.Join(dir, "store"))
	if err != nil {
		t.Fatal(err)
	}
	e := &env{now: 1_800_000_000}
	e.v = New(d, bs)
	e.v.Now = func() int64 { return e.now }
	mk := func(name string, admin bool) Actor {
		u, err := e.v.CreateUser(Actor{}, name, name, "password123", admin)
		if err != nil {
			t.Fatal(err)
		}
		return Actor{User: u, Client: "test"}
	}
	e.admin, e.kim, e.lee, e.boss = mk("admin", true), mk("kim", false), mk("lee", false), mk("boss", false)
	s, err := e.v.CreateShare(e.admin, "영업", "O", false, 0)
	if err != nil {
		t.Fatal(err)
	}
	gid, _ := e.v.CreateGroup(e.admin, "영업팀")
	e.v.UpdateUser(e.admin, e.kim.User.ID, UserUpdate{GroupIDs: []int64{gid}})
	if err := e.v.SetShareACL(e.admin, s.ID, []ACLEntry{
		{PrincipalType: "group", PrincipalID: gid, Level: LevelWrite},
		{PrincipalType: "user", PrincipalID: e.lee.User.ID, Level: LevelRead},
		{PrincipalType: "user", PrincipalID: e.boss.User.ID, Level: LevelManage},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.v.CreateShare(e.admin, "개인문서함", "F", true, 0); err != nil {
		t.Fatal(err)
	}
	return e
}

func (e *env) put(t *testing.T, a Actor, share, p, body string) {
	t.Helper()
	if _, _, err := e.v.Put(a, share, p, strings.NewReader(body)); err != nil {
		t.Fatalf("put %s: %v", p, err)
	}
}

func (e *env) read(t *testing.T, a Actor, share, p string) string {
	t.Helper()
	_, f, err := e.v.Open(a, share, p)
	if err != nil {
		t.Fatalf("open %s: %v", p, err)
	}
	defer f.Close()
	b, _ := io.ReadAll(f)
	return string(b)
}

func names(t *testing.T, e *env, a Actor, share, p string) string {
	t.Helper()
	list, err := e.v.List(a, share, p)
	if err != nil {
		t.Fatal(err)
	}
	var s []string
	for _, n := range list {
		s = append(s, n.Name)
	}
	return strings.Join(s, ",")
}

func TestPermissions(t *testing.T) {
	e := newEnv(t)
	e.put(t, e.kim, "영업", "/견적.xlsx", "v1")
	if got := e.read(t, e.lee, "영업", "/견적.xlsx"); got != "v1" {
		t.Fatalf("lee read %q", got)
	}
	if _, _, err := e.v.Put(e.lee, "영업", "/x.txt", strings.NewReader("x")); err != ErrForbidden {
		t.Fatalf("read-only user write: %v", err)
	}
	outsider, _ := e.v.CreateUser(Actor{}, "park", "", "password123", false)
	if _, err := e.v.Stat(Actor{User: outsider}, "영업", "/"); err != ErrNotFound {
		t.Fatalf("outsider should not see drive: %v", err)
	}
	drives, _ := e.v.DrivesFor(outsider)
	if len(drives) != 1 || drives[0].Name != "개인문서함" {
		t.Fatalf("outsider drives: %+v", drives)
	}
}

func TestPersonalSpacesAreSeparate(t *testing.T) {
	e := newEnv(t)
	e.put(t, e.kim, "개인문서함", "/메모.txt", "kim")
	e.put(t, e.lee, "개인문서함", "/메모.txt", "lee")
	if e.read(t, e.kim, "개인문서함", "/메모.txt") != "kim" || e.read(t, e.lee, "개인문서함", "/메모.txt") != "lee" {
		t.Fatal("personal spaces leaked")
	}
}

func TestVersionsAndRestore(t *testing.T) {
	e := newEnv(t)
	for _, b := range []string{"v1", "v2", "v3"} {
		e.put(t, e.kim, "영업", "/a.xlsx", b)
		e.now += 10
	}
	vers, err := e.v.Versions(e.kim, "영업", "/a.xlsx")
	if err != nil || len(vers) != 3 || !vers[0].Current {
		t.Fatalf("versions %+v %v", vers, err)
	}
	if err := e.v.RestoreVersion(e.kim, "영업", "/a.xlsx", vers[2].ID); err != nil {
		t.Fatal(err)
	}
	if got := e.read(t, e.kim, "영업", "/a.xlsx"); got != "v1" {
		t.Fatalf("after restore %q", got)
	}
	vers, _ = e.v.Versions(e.kim, "영업", "/a.xlsx")
	if len(vers) != 4 {
		t.Fatalf("restore should add a version, have %d", len(vers))
	}
}

// Excel/Word "safe save": write temp, rename original away, rename temp to
// the original name, delete the renamed original.
func TestOfficeSafeSaveKeepsHistory(t *testing.T) {
	e := newEnv(t)
	e.put(t, e.kim, "영업", "/보고서.xlsx", "v1")
	e.now += 60
	e.put(t, e.kim, "영업", "/~$보고서.xlsx", "lock")
	e.put(t, e.kim, "영업", "/6C3F2A10", "v2")
	if _, err := e.v.Move(e.kim, "영업", "/보고서.xlsx", "영업", "/A1B2C3D4.tmp", false); err != nil {
		t.Fatal(err)
	}
	if _, err := e.v.Move(e.kim, "영업", "/6C3F2A10", "영업", "/보고서.xlsx", false); err != nil {
		t.Fatal(err)
	}
	if err := e.v.Delete(e.kim, "영업", "/A1B2C3D4.tmp"); err != nil {
		t.Fatal(err)
	}
	if err := e.v.Delete(e.kim, "영업", "/~$보고서.xlsx"); err != nil {
		t.Fatal(err)
	}
	if got := names(t, e, e.kim, "영업", "/"); got != "보고서.xlsx" {
		t.Fatalf("listing %q", got)
	}
	if got := e.read(t, e.kim, "영업", "/보고서.xlsx"); got != "v2" {
		t.Fatalf("content %q", got)
	}
	vers, _ := e.v.Versions(e.kim, "영업", "/보고서.xlsx")
	if len(vers) != 2 {
		t.Fatalf("want 2 versions, got %+v", vers)
	}
	if trash, _ := e.v.Trash(e.kim, "영업"); len(trash) != 0 {
		t.Fatalf("trash should be empty: %+v", trash)
	}
}

// Same save, but the drive delivers the delete before the new content
// (rclone uploads written files after a short delay).
func TestSafeSaveDeleteBeforeUpload(t *testing.T) {
	e := newEnv(t)
	e.put(t, e.kim, "영업", "/도면.dwg", "v1")
	e.now += 60
	e.v.Move(e.kim, "영업", "/도면.dwg", "영업", "/A1B2C3D4.tmp", false)
	if err := e.v.Delete(e.kim, "영업", "/A1B2C3D4.tmp"); err != nil {
		t.Fatal(err)
	}
	e.now += 5
	e.put(t, e.kim, "영업", "/도면.dwg", "v2")
	vers, _ := e.v.Versions(e.kim, "영업", "/도면.dwg")
	if len(vers) != 2 {
		t.Fatalf("want 2 versions, got %d", len(vers))
	}
	if trash, _ := e.v.Trash(e.kim, "영업"); len(trash) != 0 {
		t.Fatalf("trash should be empty: %+v", trash)
	}
}

func TestTrashRestoreAndRetention(t *testing.T) {
	e := newEnv(t)
	e.v.Mkdir(e.kim, "영업", "/계약")
	e.put(t, e.kim, "영업", "/계약/A사.pdf", "a")
	e.put(t, e.kim, "영업", "/계약/B사.pdf", "b")
	if err := e.v.Delete(e.kim, "영업", "/계약"); err != nil {
		t.Fatal(err)
	}
	if got := names(t, e, e.kim, "영업", "/"); got != "" {
		t.Fatalf("listing after delete %q", got)
	}
	trash, _ := e.v.Trash(e.kim, "영업")
	if len(trash) != 1 || trash[0].Size != 2 || trash[0].PurgeAt != e.now+180*86400 {
		t.Fatalf("trash %+v", trash)
	}
	// a new folder with the same name exists by now -> restored under another name
	e.v.Mkdir(e.kim, "영업", "/계약")
	p, err := e.v.RestoreTrash(e.kim, "영업", trash[0].ID)
	if err != nil || p != "/계약 (복원 1)" {
		t.Fatalf("restore %q %v", p, err)
	}
	if got := e.read(t, e.kim, "영업", "/계약 (복원 1)/B사.pdf"); got != "b" {
		t.Fatalf("restored content %q", got)
	}

	// retention: deleted 181 days ago -> purged, content blob removed
	e.put(t, e.kim, "영업", "/old.txt", "unique-old-content")
	e.v.Delete(e.kim, "영업", "/old.txt")
	e.now += 179 * 86400
	if r, _ := e.v.Maintain(); r.PurgedItems != 0 {
		t.Fatalf("purged too early: %+v", r)
	}
	e.now += 2 * 86400
	r, err := e.v.Maintain()
	if err != nil || r.PurgedItems != 1 || r.DeletedBlobs != 1 {
		t.Fatalf("maintain %+v %v", r, err)
	}
	if trash, _ := e.v.Trash(e.kim, "영업"); len(trash) != 0 {
		t.Fatalf("trash after purge %+v", trash)
	}
}

func TestExportApproval(t *testing.T) {
	e := newEnv(t)
	e.put(t, e.kim, "영업", "/견적.xlsx", "v1")
	ex, err := e.v.RequestExport(e.kim, "영업", "/견적.xlsx", "고객사 제출")
	if err != nil || ex.Status != "pending" {
		t.Fatalf("request %+v %v", ex, err)
	}
	if _, _, err := e.v.OpenExport(e.kim, ex.ID); err != ErrForbidden {
		t.Fatalf("download before approval: %v", err)
	}
	if err := e.v.DecideExport(e.kim, ex.ID, true, ""); err != ErrForbidden {
		t.Fatalf("self approval: %v", err)
	}
	if err := e.v.DecideExport(e.lee, ex.ID, true, ""); err != ErrForbidden {
		t.Fatalf("reader approval: %v", err)
	}
	inbox, _ := e.v.ListExports(e.boss.User, "inbox")
	if len(inbox) != 1 || !inbox[0].CanApprove {
		t.Fatalf("boss inbox %+v", inbox)
	}
	// file changes after the request: the requested version is what goes out
	e.put(t, e.kim, "영업", "/견적.xlsx", "v2")
	if err := e.v.DecideExport(e.boss, ex.ID, true, "승인"); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		_, f, err := e.v.OpenExport(e.kim, ex.ID)
		if err != nil {
			t.Fatalf("download %d: %v", i, err)
		}
		b, _ := io.ReadAll(f)
		f.Close()
		if string(b) != "v1" {
			t.Fatalf("exported %q", b)
		}
	}
	if _, _, err := e.v.OpenExport(e.kim, ex.ID); err != ErrForbidden {
		t.Fatalf("4th download: %v", err)
	}
}

func TestRansomwareGuard(t *testing.T) {
	e := newEnv(t)
	e.v.SetSetting(e.admin, "guard_threshold", 5)
	e.put(t, e.kim, "영업", "/f.txt", "v0") // create: not counted
	for i := 1; i <= 4; i++ {
		e.put(t, e.kim, "영업", "/f.txt", "v"+itoa(int64(i)))
	}
	// 4 overwrites so far; one more trips the guard
	e.put(t, e.kim, "영업", "/f.txt", "encrypted")
	if _, _, err := e.v.Put(e.kim, "영업", "/f.txt", strings.NewReader("x")); err != ErrForbidden {
		t.Fatalf("expected write block, got %v", err)
	}
	u, _ := e.v.UserByID(e.kim.User.ID)
	if !u.WriteBlocked {
		t.Fatal("user not blocked in DB")
	}
	// reading still works so people can keep working read-only
	if got := e.read(t, e.kim, "영업", "/f.txt"); got != "encrypted" {
		t.Fatalf("read %q", got)
	}
}

func TestDeletingFolderContentsDoesNotTripGuard(t *testing.T) {
	e := newEnv(t)
	e.v.SetSetting(e.admin, "guard_threshold", 5)
	e.v.Mkdir(e.kim, "영업", "/old")
	for i := 0; i < 8; i++ {
		e.put(t, e.kim, "영업", "/old/"+itoa(int64(i))+".txt", "x")
	}
	for i := 0; i < 8; i++ {
		if err := e.v.Delete(e.kim, "영업", "/old/"+itoa(int64(i))+".txt"); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.v.Delete(e.kim, "영업", "/old"); err != nil {
		t.Fatal(err)
	}
	u, _ := e.v.UserByID(e.kim.User.ID)
	if u.WriteBlocked {
		t.Fatal("9 deletions (< 2x5 points) should not block")
	}
}

// Explorer deletes a folder's files one by one, then the folder: the trash
// should show one folder that restores with its files.
func TestFolderDeletedFileByFileIsOneTrashItem(t *testing.T) {
	e := newEnv(t)
	e.v.Mkdir(e.kim, "영업", "/설계")
	e.v.Mkdir(e.kim, "영업", "/설계/상세")
	e.put(t, e.kim, "영업", "/설계/a.dwg", "a")
	e.put(t, e.kim, "영업", "/설계/상세/b.dwg", "bb")
	e.now += 5
	e.v.Delete(e.kim, "영업", "/설계/상세/b.dwg")
	e.v.Delete(e.kim, "영업", "/설계/상세")
	e.v.Delete(e.kim, "영업", "/설계/a.dwg")
	e.v.Delete(e.kim, "영업", "/설계")
	trash, _ := e.v.Trash(e.kim, "영업")
	if len(trash) != 1 || trash[0].Name != "설계" || trash[0].Size != 3 {
		t.Fatalf("trash %+v", trash)
	}
	if _, err := e.v.RestoreTrash(e.kim, "영업", trash[0].ID); err != nil {
		t.Fatal(err)
	}
	if got := e.read(t, e.kim, "영업", "/설계/상세/b.dwg"); got != "bb" {
		t.Fatalf("restored %q", got)
	}
}

func TestLoginLockout(t *testing.T) {
	e := newEnv(t)
	for i := 0; i < 5; i++ {
		if _, _, err := e.v.Login("kim", "wrong", "web", "", ""); err != ErrUnauthorized {
			t.Fatalf("attempt %d: %v", i, err)
		}
	}
	if _, _, err := e.v.Login("kim", "password123", "web", "", ""); err != ErrLocked {
		t.Fatalf("expected lock, got %v", err)
	}
	e.now += 601
	tok, _, err := e.v.Login("kim", "password123", "agent", "PC-01", "")
	if err != nil {
		t.Fatal(err)
	}
	if u, _, err := e.v.Authenticate(tok); err != nil || u.Username != "kim" {
		t.Fatalf("auth %v", err)
	}
}

func TestMoveIntoOwnSubfolderRejected(t *testing.T) {
	e := newEnv(t)
	e.v.Mkdir(e.kim, "영업", "/a")
	e.v.Mkdir(e.kim, "영업", "/a/b")
	if _, err := e.v.Move(e.kim, "영업", "/a", "영업", "/a/b/a", false); err != ErrConflict {
		t.Fatalf("got %v", err)
	}
}

func TestPolicyBlocksUsersButNotAdmins(t *testing.T) {
	e := newEnv(t)
	if p := e.v.Policy(e.admin.User); len(p) != 0 {
		t.Fatalf("admin should have no blocks: %v", p)
	}
	p := e.v.Policy(e.kim.User)
	if p["kakaotalk.exe"] != "messenger" || p["cmd.exe"] != "copy" || p["explorer.exe"] != "" {
		t.Fatalf("user policy %v", p)
	}
	if !e.v.CopyWatch(e.kim.User) || e.v.CopyWatch(e.admin.User) {
		t.Fatal("copy watch")
	}
	e.kim.User.AllowCopy = true
	if p := e.v.Policy(e.kim.User); p["cmd.exe"] != "" || p["kakaotalk.exe"] != "messenger" || e.v.CopyWatch(e.kim.User) {
		t.Fatalf("copy exemption %v", p)
	}
}

func TestCopyCheck(t *testing.T) {
	e := newEnv(t)
	e.put(t, e.kim, "영업", "/견적.xlsx", "quote")
	e.put(t, e.lee, "개인문서함", "/메모.txt", "memo")
	sum := func(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

	if d, p, ok := e.v.CopyCheck(e.kim.User, sum("quote"), 5); !ok || d != "영업" || p != "/견적.xlsx" {
		t.Fatalf("copy of a drive file: %v %q %q", ok, d, p)
	}
	if _, _, ok := e.v.CopyCheck(e.kim.User, sum("other"), 5); ok {
		t.Fatal("unrelated file matched")
	}
	if _, _, ok := e.v.CopyCheck(e.kim.User, sum("memo"), 4); ok {
		t.Fatal("someone else's personal file matched")
	}
	if _, _, ok := e.v.CopyCheck(e.lee.User, sum("memo"), 4); !ok {
		t.Fatal("own personal file not matched")
	}
	if _, _, ok := e.v.CopyCheck(e.admin.User, sum("quote"), 5); ok {
		t.Fatal("admin is never blocked")
	}
	ex, err := e.v.RequestExport(e.kim, "영업", "/견적.xlsx", "고객사 제출")
	if err != nil {
		t.Fatal(err)
	}
	if err := e.v.DecideExport(e.boss, ex.ID, true, "승인"); err != nil {
		t.Fatal(err)
	}
	if _, _, ok := e.v.CopyCheck(e.kim.User, sum("quote"), 5); ok {
		t.Fatal("approved export should be allowed")
	}
}

func TestRecycleBinFolderRefused(t *testing.T) {
	e := newEnv(t)
	if err := e.v.Mkdir(e.kim, "영업", "/$RECYCLE.BIN"); err != ErrForbidden {
		t.Fatalf("mkdir recycle bin: %v", err)
	}
	if _, _, err := e.v.Put(e.kim, "영업", "/System Volume Information", strings.NewReader("x")); err != ErrForbidden {
		t.Fatalf("put system folder: %v", err)
	}
}
