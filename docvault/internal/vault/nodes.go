package vault

import (
	"database/sql"
	"errors"
	"io"
	"log"
	"os"
	"path"
	"strings"

	"docvault/internal/blob"
)

// Node is a file or folder.
type Node struct {
	ID          int64  `json:"id"`
	ShareID     int64  `json:"-"`
	OwnerID     int64  `json:"-"`
	ParentID    int64  `json:"-"`
	Name        string `json:"name"`
	IsDir       bool   `json:"isDir"`
	Size        int64  `json:"size"`
	BlobSHA     string `json:"-"`
	CreatedAt   int64  `json:"createdAt"`
	CreatedBy   int64  `json:"-"`
	ModifiedAt  int64  `json:"modifiedAt"`
	ModifiedBy  int64  `json:"-"`
	DeletedAt   int64  `json:"-"`
	DeletedBy   int64  `json:"-"`
	DeleteBatch string `json:"-"`
	DeleteRoot  bool   `json:"-"`
	OrigPath    string `json:"-"`
	PrevName    string `json:"-"`
	PrevNameAt  int64  `json:"-"`
}

const nodeCols = `id, share_id, owner_id, COALESCE(parent_id,0), name, is_dir, size, blob_sha, created_at, created_by,
	modified_at, modified_by, COALESCE(deleted_at,0), COALESCE(deleted_by,0), COALESCE(delete_batch,''), delete_root,
	orig_path, prev_name, prev_name_at`

func scanNode(r rowScanner) (*Node, error) {
	n := &Node{}
	err := r.Scan(&n.ID, &n.ShareID, &n.OwnerID, &n.ParentID, &n.Name, &n.IsDir, &n.Size, &n.BlobSHA, &n.CreatedAt, &n.CreatedBy,
		&n.ModifiedAt, &n.ModifiedBy, &n.DeletedAt, &n.DeletedBy, &n.DeleteBatch, &n.DeleteRoot,
		&n.OrigPath, &n.PrevName, &n.PrevNameAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return n, err
}

type querier interface {
	QueryRow(string, ...any) *sql.Row
	Query(string, ...any) (*sql.Rows, error)
	Exec(string, ...any) (sql.Result, error)
}

// saveWindow is how long (seconds) a renamed-away or deleted file is remembered
// so an application's "safe save" sequence keeps the file's version history.
const saveWindow = 120

// ---- names ----

func validName(name string) error {
	if name == "" || name == "." || name == ".." || len(name) > 255 {
		return ErrInvalidName
	}
	for _, c := range name {
		if c < 0x20 || strings.ContainsRune(`/\:*?"<>|`, c) {
			return ErrInvalidName
		}
	}
	if strings.HasSuffix(name, " ") || strings.HasSuffix(name, ".") {
		return ErrInvalidName
	}
	return nil
}

// isReserved reports folders Windows creates on local disks (the Recycle Bin
// and system folders). Refusing them makes Explorer delete straight to the
// server's trash instead of a hidden recycle-bin folder on the drive.
func isReserved(name string) bool {
	switch strings.ToLower(name) {
	case "$recycle.bin", "recycler", "recycled", "system volume information", "$recycle":
		return true
	}
	return false
}

// isTransient reports names of lock/temp files that Office, Windows and other
// programs create while saving. They are not versioned, logged or kept in the trash.
func isTransient(name string) bool {
	l := strings.ToLower(name)
	switch {
	case strings.HasPrefix(name, "~$"), strings.HasPrefix(l, ".~lock."), strings.HasPrefix(name, "._"),
		l == "thumbs.db", l == "desktop.ini", l == ".ds_store",
		strings.HasSuffix(l, ".tmp"):
		return true
	}
	if len(name) == 8 {
		for _, c := range l {
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
				return false
			}
		}
		return true // Excel's temporary save file, e.g. "6C3F2A10"
	}
	return false
}

func splitPath(p string) ([]string, error) {
	var parts []string
	for _, s := range strings.Split(p, "/") {
		switch s {
		case "", ".":
			continue
		case "..":
			return nil, ErrNotFound
		}
		parts = append(parts, s)
	}
	return parts, nil
}

func joinPath(parts []string) string { return "/" + strings.Join(parts, "/") }

// ---- locating a user's space ----

func (v *Vault) spaceOwner(s *Share, u *User) int64 {
	if s.Personal {
		return u.ID
	}
	return 0
}

type loc struct {
	share *Share
	owner int64
	level int
	parts []string
}

func (l *loc) path() string { return joinPath(l.parts) }

// ExportFolder is the folder in each personal space that receives approved
// exports (반출). Only the system puts files there; users may open, copy out
// and delete them, but not add, change or rename anything in it, so whatever
// is in it has been approved.
const ExportFolder = "반출"

// exportRoot reports whether the loc is the export folder itself (not a file
// inside it): that folder may not be deleted or renamed by a user, so it is
// always there to receive approved exports.
func exportRoot(a Actor, l *loc) bool {
	return l.share.Personal && len(l.parts) == 1 && strings.EqualFold(l.parts[0], ExportFolder) && a.Client != "export"
}

// exportLocked reports a write into the export folder by a user. Office lock
// and temporary files are let through so opening a file there works.
func exportLocked(a Actor, l *loc) bool {
	if !l.share.Personal || len(l.parts) == 0 || !strings.EqualFold(l.parts[0], ExportFolder) || a.Client == "export" {
		return false
	}
	return len(l.parts) == 1 || !isTransient(l.parts[len(l.parts)-1])
}

// locate resolves a share for the actor and checks it has at least level need.
func (v *Vault) locate(a Actor, shareName, p string, need int) (*loc, error) {
	if a.User == nil {
		return nil, ErrUnauthorized
	}
	s, err := v.ShareByName(shareName)
	if err != nil {
		return nil, ErrNotFound
	}
	lvl := v.Level(a.User, s)
	if lvl == LevelNone {
		return nil, ErrNotFound
	}
	if lvl < need {
		return nil, ErrForbidden
	}
	if need >= LevelWrite && a.User.WriteBlocked {
		return nil, ErrForbidden
	}
	parts, err := splitPath(p)
	if err != nil {
		return nil, err
	}
	return &loc{share: s, owner: v.spaceOwner(s, a.User), level: lvl, parts: parts}, nil
}

func spaceRoot(q querier, shareID, owner int64, now int64) (*Node, error) {
	n, err := scanNode(q.QueryRow(`SELECT `+nodeCols+` FROM nodes WHERE share_id=? AND owner_id=? AND parent_id IS NULL`, shareID, owner))
	if err == ErrNotFound {
		if _, err := q.Exec(`INSERT INTO nodes(share_id, owner_id, name, is_dir, created_at, modified_at) VALUES(?,?,?,1,?,?)`,
			shareID, owner, "", now, now); err != nil {
			return nil, err
		}
		return spaceRoot(q, shareID, owner, now)
	}
	return n, err
}

func child(q querier, parentID int64, name string) (*Node, error) {
	return scanNode(q.QueryRow(`SELECT `+nodeCols+` FROM nodes WHERE parent_id=? AND name=? AND deleted_at IS NULL`, parentID, name))
}

func nodeByID(q querier, id int64) (*Node, error) {
	return scanNode(q.QueryRow(`SELECT `+nodeCols+` FROM nodes WHERE id=?`, id))
}

func (v *Vault) resolve(q querier, l *loc, parts []string) (*Node, error) {
	n, err := spaceRoot(q, l.share.ID, l.owner, v.Now())
	if err != nil {
		return nil, err
	}
	for _, p := range parts {
		if !n.IsDir {
			return nil, ErrNotFound
		}
		if n, err = child(q, n.ID, p); err != nil {
			return nil, err
		}
	}
	return n, nil
}

// resolveParent returns the folder that should contain the last path element.
func (v *Vault) resolveParent(q querier, l *loc) (*Node, string, error) {
	if len(l.parts) == 0 {
		return nil, "", ErrForbidden
	}
	name := l.parts[len(l.parts)-1]
	if err := validName(name); err != nil {
		return nil, "", err
	}
	if isReserved(name) {
		return nil, "", ErrForbidden
	}
	parent, err := v.resolve(q, l, l.parts[:len(l.parts)-1])
	if err == ErrNotFound || (err == nil && !parent.IsDir) {
		return nil, "", ErrConflict
	}
	return parent, name, err
}

func pathOf(q querier, n *Node) string {
	var parts []string
	for n != nil && n.ParentID != 0 {
		parts = append([]string{n.Name}, parts...)
		var err error
		if n, err = nodeByID(q, n.ParentID); err != nil {
			break
		}
	}
	return joinPath(parts)
}

// Usage is the total size of current file versions in a space (trash
// excluded). It is cached for 30 seconds because drives ask for it often;
// quota checks on save use the exact figure.
func (v *Vault) Usage(s *Share, owner int64) int64 {
	key := [2]int64{s.ID, owner}
	now := v.Now()
	v.usageMu.Lock()
	c, ok := v.usageCache[key]
	v.usageMu.Unlock()
	if ok && now-c[1] < 30 {
		return c[0]
	}
	n := usage(v.DB, s.ID, owner)
	v.usageMu.Lock()
	v.usageCache[key] = [2]int64{n, now}
	v.usageMu.Unlock()
	return n
}

func usage(q querier, shareID, owner int64) (n int64) {
	q.QueryRow(`SELECT COALESCE(SUM(size),0) FROM nodes WHERE share_id=? AND owner_id=? AND is_dir=0 AND deleted_at IS NULL`, shareID, owner).Scan(&n)
	return
}

func checkQuota(q querier, s *Share, owner int64) error {
	if s.QuotaBytes > 0 && usage(q, s.ID, owner) > s.QuotaBytes {
		return ErrQuota
	}
	return nil
}

// ---- reading ----

func (v *Vault) Stat(a Actor, shareName, p string) (*Node, error) {
	l, err := v.locate(a, shareName, p, LevelRead)
	if err != nil {
		return nil, err
	}
	return v.resolve(v.DB, l, l.parts)
}

func (v *Vault) List(a Actor, shareName, p string) ([]*Node, error) {
	dir, err := v.Stat(a, shareName, p)
	if err != nil {
		return nil, err
	}
	if !dir.IsDir {
		return nil, ErrNotDir
	}
	return listChildren(v.DB, dir.ID)
}

func listChildren(q querier, id int64) ([]*Node, error) {
	rows, err := q.Query(`SELECT `+nodeCols+` FROM nodes WHERE parent_id=? AND deleted_at IS NULL ORDER BY is_dir DESC, name`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []*Node{}
	for rows.Next() {
		n, err := scanNode(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

// Open returns the file's current content. The caller must close the file.
func (v *Vault) Open(a Actor, shareName, p string) (*Node, *os.File, error) {
	n, err := v.Stat(a, shareName, p)
	if err != nil {
		return nil, nil, err
	}
	if n.IsDir {
		return nil, nil, ErrIsDir
	}
	f, err := v.Blobs.Open(n.BlobSHA)
	if errors.Is(err, os.ErrNotExist) {
		log.Printf("저장소에 파일 내용이 없습니다: %s:%s (%s) — 관리자 → 설정 → [저장소 점검]", shareName, p, n.BlobSHA)
		return nil, nil, ErrNoContent
	}
	if err != nil {
		return nil, nil, err
	}
	if !isTransient(n.Name) {
		v.auditRead(a, shareName, joinPathStr(p), n.ID)
	}
	return n, f, nil
}

func joinPathStr(p string) string {
	parts, _ := splitPath(p)
	return joinPath(parts)
}

// ---- writing ----

// Put stores content at path, creating the file or adding a new version.
// mtime is ignored (the server records its own time). created reports whether
// the path did not exist before.
func (v *Vault) Put(a Actor, shareName, p string, r io.Reader) (n *Node, created bool, err error) {
	l, err := v.locate(a, shareName, p, LevelWrite)
	if err != nil {
		return nil, false, err
	}
	if len(l.parts) == 0 {
		return nil, false, ErrIsDir
	}
	if exportLocked(a, l) {
		return nil, false, ErrForbidden
	}
	if err := validName(l.parts[len(l.parts)-1]); err != nil {
		return nil, false, err
	}
	var limit int64
	if l.share.QuotaBytes > 0 {
		var existing int64
		if cur, err := v.resolve(v.DB, l, l.parts); err == nil {
			existing = cur.Size
		}
		limit = l.share.QuotaBytes - v.Usage(l.share, l.owner) + existing
		if limit < 0 {
			limit = 0
		}
	}

	v.blobMu.RLock()
	defer v.blobMu.RUnlock()
	sha, size, err := v.Blobs.Put(r, limit)
	if err == blob.ErrTooLarge {
		return nil, false, ErrQuota
	}
	if err != nil {
		return nil, false, err
	}
	now := v.Now()
	uid := a.User.ID
	var action string
	err = v.withTx(func(tx *sql.Tx) error {
		parent, name, err := v.resolveParent(tx, l)
		if err != nil {
			return err
		}
		if n, err = child(tx, parent.ID, name); err == nil {
			if n.IsDir {
				return ErrIsDir
			}
			action = "update"
		} else if err != ErrNotFound {
			return err
		} else if n, err = findRecentlyGone(tx, parent.ID, name, uid, now); err == nil {
			// The application deleted/renamed the file a moment ago as part of a
			// save: bring the old node back so its history continues.
			if err := revive(tx, n, parent.ID, name); err != nil {
				return err
			}
			created, action = true, "update"
		} else if err == ErrNotFound {
			res, err := tx.Exec(`INSERT INTO nodes(share_id, owner_id, parent_id, name, is_dir, created_at, created_by, modified_at, modified_by)
				VALUES(?,?,?,?,0,?,?,?,?)`, l.share.ID, l.owner, parent.ID, name, now, uid, now, uid)
			if err != nil {
				return err
			}
			id, _ := res.LastInsertId()
			if n, err = nodeByID(tx, id); err != nil {
				return err
			}
			created, action = true, "create"
		} else {
			return err
		}
		if err := addVersion(tx, n, sha, size, uid, now, ""); err != nil {
			return err
		}
		if err := checkQuota(tx, l.share, l.owner); err != nil {
			return err
		}
		if !v.Blobs.Exists(sha) {
			return errors.New("blob vanished during upload; retry")
		}
		if !isTransient(name) {
			v.auditTx(tx, a, action, l.share.Name, l.path(), sizeText(size))
		}
		return nil
	})
	if err != nil {
		return nil, false, err
	}
	if action == "update" && !isTransient(n.Name) {
		v.guard(a, l.share.Name, 2)
	}
	n.Size, n.BlobSHA, n.ModifiedAt = size, sha, now
	return n, created, nil
}

func addVersion(q querier, n *Node, sha string, size, uid, now int64, note string) error {
	var count int
	q.QueryRow(`SELECT COUNT(*) FROM versions WHERE node_id=?`, n.ID).Scan(&count)
	if count > 0 && n.BlobSHA == sha {
		_, err := q.Exec(`UPDATE nodes SET modified_at=?, modified_by=? WHERE id=?`, now, uid, n.ID)
		return err
	}
	res, err := q.Exec(`INSERT INTO versions(node_id, blob_sha, size, created_at, created_by, note) VALUES(?,?,?,?,?,?)`,
		n.ID, sha, size, now, uid, note)
	if err != nil {
		return err
	}
	if isTransient(n.Name) {
		vid, _ := res.LastInsertId()
		q.Exec(`DELETE FROM versions WHERE node_id=? AND id<?`, n.ID, vid)
	}
	_, err = q.Exec(`UPDATE nodes SET size=?, blob_sha=?, modified_at=?, modified_by=? WHERE id=?`, size, sha, now, uid, n.ID)
	return err
}

// findRecentlyGone finds a file in parent that the same user deleted within the
// save window and that was called name before (directly or before a rename).
func findRecentlyGone(q querier, parentID int64, name string, uid, now int64) (*Node, error) {
	return scanNode(q.QueryRow(`SELECT `+nodeCols+` FROM nodes
		WHERE parent_id=? AND is_dir=0 AND delete_root=1 AND deleted_at IS NOT NULL AND deleted_at>=? AND deleted_by=?
		AND (name=? OR (prev_name=? AND prev_name_at>=?))
		ORDER BY deleted_at DESC, id DESC LIMIT 1`, parentID, now-saveWindow, uid, name, name, now-saveWindow))
}

func revive(q querier, n *Node, parentID int64, name string) error {
	_, err := q.Exec(`UPDATE nodes SET deleted_at=NULL, deleted_by=NULL, delete_batch=NULL, delete_root=0, orig_path='',
		parent_id=?, name=?, prev_name='', prev_name_at=0 WHERE id=?`, parentID, name, n.ID)
	n.DeletedAt, n.ParentID, n.Name = 0, parentID, name
	return err
}

// mergeInto moves from's history onto into (from's content becomes current),
// removes from, and places into at parentID/name.
func mergeInto(q querier, from, into *Node, parentID int64, name string) error {
	if _, err := q.Exec(`UPDATE versions SET node_id=? WHERE node_id=?`, into.ID, from.ID); err != nil {
		return err
	}
	q.Exec(`UPDATE exports SET node_id=? WHERE node_id=?`, into.ID, from.ID)
	if _, err := q.Exec(`DELETE FROM nodes WHERE id=?`, from.ID); err != nil {
		return err
	}
	_, err := q.Exec(`UPDATE nodes SET parent_id=?, name=?, size=?, blob_sha=?, modified_at=?, modified_by=?,
		prev_name='', prev_name_at=0, deleted_at=NULL, deleted_by=NULL, delete_batch=NULL, delete_root=0, orig_path='' WHERE id=?`,
		parentID, name, from.Size, from.BlobSHA, from.ModifiedAt, from.ModifiedBy, into.ID)
	return err
}

func (v *Vault) Mkdir(a Actor, shareName, p string) error {
	l, err := v.locate(a, shareName, p, LevelWrite)
	if err != nil {
		return err
	}
	if exportLocked(a, l) {
		return ErrForbidden
	}
	now := v.Now()
	return v.withTx(func(tx *sql.Tx) error {
		parent, name, err := v.resolveParent(tx, l)
		if err != nil {
			return err
		}
		if _, err := child(tx, parent.ID, name); err == nil {
			return ErrExists
		}
		if _, err := tx.Exec(`INSERT INTO nodes(share_id, owner_id, parent_id, name, is_dir, created_at, created_by, modified_at, modified_by)
			VALUES(?,?,?,?,1,?,?,?,?)`, l.share.ID, l.owner, parent.ID, name, now, a.User.ID, now, a.User.ID); err != nil {
			return err
		}
		v.auditTx(tx, a, "mkdir", l.share.Name, l.path(), "")
		return nil
	})
}

const subtreeLive = `WITH RECURSIVE sub(id) AS (SELECT ? UNION ALL SELECT n.id FROM nodes n JOIN sub ON n.parent_id=sub.id WHERE n.deleted_at IS NULL) SELECT id FROM sub`
const subtreeAll = `WITH RECURSIVE sub(id) AS (SELECT ? UNION ALL SELECT n.id FROM nodes n JOIN sub ON n.parent_id=sub.id) SELECT id FROM sub`

func softDelete(q querier, n *Node, origPath string, uid, now int64) error {
	batch := randomID(8)
	if _, err := q.Exec(`UPDATE nodes SET deleted_at=?, deleted_by=?, delete_batch=? WHERE deleted_at IS NULL AND id IN (`+subtreeLive+`)`,
		now, uid, batch, n.ID); err != nil {
		return err
	}
	if n.IsDir {
		// Explorer and the drive delete a folder's files one by one before the
		// folder itself. Fold those just-deleted items into this deletion so
		// the folder is one trash item and restores with its contents.
		if _, err := q.Exec(`UPDATE nodes SET delete_batch=?, delete_root=0, orig_path='' WHERE id IN (`+subtreeAll+`)
			AND id<>? AND deleted_at IS NOT NULL AND deleted_by=? AND deleted_at>=? AND delete_batch<>?`,
			batch, n.ID, n.ID, uid, now-saveWindow, batch); err != nil {
			return err
		}
	}
	_, err := q.Exec(`UPDATE nodes SET delete_root=1, orig_path=? WHERE id=?`, origPath, n.ID)
	return err
}

// purgeSubtree permanently removes a node and everything below it.
func purgeSubtree(q querier, id int64) error {
	if _, err := q.Exec(`DELETE FROM versions WHERE node_id IN (`+subtreeAll+`)`, id); err != nil {
		return err
	}
	_, err := q.Exec(`DELETE FROM nodes WHERE id IN (`+subtreeAll+`)`, id)
	return err
}

// Delete moves a file or folder to the trash.
func (v *Vault) Delete(a Actor, shareName, p string) error {
	l, err := v.locate(a, shareName, p, LevelWrite)
	if err != nil {
		return err
	}
	if len(l.parts) == 0 || exportRoot(a, l) {
		return ErrForbidden
	}
	now := v.Now()
	uid := a.User.ID
	var logged bool
	err = v.withTx(func(tx *sql.Tx) error {
		n, err := v.resolve(tx, l, l.parts)
		if err != nil {
			return err
		}
		recentRename := n.PrevName != "" && n.PrevNameAt >= now-saveWindow
		if !n.IsDir && recentRename {
			// "Safe save": the app renamed the original away, wrote the new
			// content under the original name and now deletes the renamed
			// original. Keep one file with the full history instead.
			if t, err := child(tx, n.ParentID, n.PrevName); err == nil && !t.IsDir && t.ID != n.ID && t.CreatedAt >= n.PrevNameAt-5 {
				return mergeInto(tx, t, n, t.ParentID, t.Name)
			}
		}
		if !n.IsDir && isTransient(n.Name) && (!recentRename || isTransient(n.PrevName)) {
			return purgeSubtree(tx, n.ID)
		}
		if err := softDelete(tx, n, l.path(), uid, now); err != nil {
			return err
		}
		if !(isTransient(n.Name) && recentRename) {
			v.auditTx(tx, a, "delete", l.share.Name, l.path(), "")
			logged = true
		}
		return nil
	})
	if err == nil && logged {
		v.guard(a, l.share.Name, 1)
	}
	return err
}

func isAncestor(q querier, ancestorID, id int64) bool {
	for id != 0 {
		if id == ancestorID {
			return true
		}
		if err := q.QueryRow(`SELECT COALESCE(parent_id,0) FROM nodes WHERE id=?`, id).Scan(&id); err != nil {
			return false
		}
	}
	return false
}

// Move renames/moves src to dst (possibly across drives).
func (v *Vault) Move(a Actor, srcShare, srcPath, dstShare, dstPath string, overwrite bool) (created bool, err error) {
	sl, err := v.locate(a, srcShare, srcPath, LevelWrite)
	if err != nil {
		return false, err
	}
	dl, err := v.locate(a, dstShare, dstPath, LevelWrite)
	if err != nil {
		return false, err
	}
	if len(sl.parts) == 0 || exportLocked(a, dl) || exportRoot(a, sl) {
		return false, ErrForbidden
	}
	now := v.Now()
	uid := a.User.ID
	err = v.withTx(func(tx *sql.Tx) error {
		src, err := v.resolve(tx, sl, sl.parts)
		if err != nil {
			return err
		}
		parent, name, err := v.resolveParent(tx, dl)
		if err != nil {
			return err
		}
		if src.IsDir && isAncestor(tx, src.ID, parent.ID) {
			return ErrConflict
		}
		sameSpace := sl.share.ID == dl.share.ID && sl.owner == dl.owner
		prevName, prevAt := "", int64(0)
		if !src.IsDir && parent.ID == src.ParentID && !isTransient(src.Name) {
			prevName, prevAt = src.Name, now
		}
		dst, err := child(tx, parent.ID, name)
		switch {
		case err == nil && dst.ID == src.ID:
			// case-only rename
		case err == nil:
			if !overwrite {
				return ErrExists
			}
			if !src.IsDir && !dst.IsDir {
				if err := mergeInto(tx, src, dst, parent.ID, name); err != nil {
					return err
				}
				if !sameSpace {
					if err := checkQuota(tx, dl.share, dl.owner); err != nil {
						return err
					}
				}
				v.auditTx(tx, a, "move", sl.share.Name, sl.path(), "→ "+dl.share.Name+":"+dl.path()+" (덮어쓰기)")
				return nil
			}
			if err := softDelete(tx, dst, dl.path(), uid, now); err != nil {
				return err
			}
		case err == ErrNotFound:
			created = true
			if !src.IsDir {
				if old, err := findRecentlyGone(tx, parent.ID, name, uid, now); err == nil {
					if err := mergeInto(tx, src, old, parent.ID, name); err != nil {
						return err
					}
					return checkQuota(tx, dl.share, dl.owner)
				}
			}
		default:
			return err
		}
		if _, err := tx.Exec(`UPDATE nodes SET parent_id=?, name=?, prev_name=?, prev_name_at=? WHERE id=?`,
			parent.ID, name, prevName, prevAt, src.ID); err != nil {
			return err
		}
		if !sameSpace {
			if _, err := tx.Exec(`UPDATE nodes SET share_id=?, owner_id=? WHERE id IN (`+subtreeAll+`)`, dl.share.ID, dl.owner, src.ID); err != nil {
				return err
			}
			if err := checkQuota(tx, dl.share, dl.owner); err != nil {
				return err
			}
		}
		if !isTransient(src.Name) && !isTransient(name) {
			v.auditTx(tx, a, "move", sl.share.Name, sl.path(), "→ "+dl.share.Name+":"+dl.path())
		}
		return nil
	})
	if err == nil && !isTransient(path.Base(dl.path())) {
		v.guard(a, dl.share.Name, 2)
	}
	return created, err
}

// Copy copies src to dst. Copies start a fresh history with the current content.
func (v *Vault) Copy(a Actor, srcShare, srcPath, dstShare, dstPath string, overwrite bool) (created bool, err error) {
	sl, err := v.locate(a, srcShare, srcPath, LevelRead)
	if err != nil {
		return false, err
	}
	dl, err := v.locate(a, dstShare, dstPath, LevelWrite)
	if err != nil {
		return false, err
	}
	if exportLocked(a, dl) {
		return false, ErrForbidden
	}
	now := v.Now()
	uid := a.User.ID
	err = v.withTx(func(tx *sql.Tx) error {
		src, err := v.resolve(tx, sl, sl.parts)
		if err != nil {
			return err
		}
		parent, name, err := v.resolveParent(tx, dl)
		if err != nil {
			return err
		}
		if src.IsDir && isAncestor(tx, src.ID, parent.ID) {
			return ErrConflict
		}
		dst, err := child(tx, parent.ID, name)
		if err == nil {
			if !overwrite {
				return ErrExists
			}
			if !src.IsDir && !dst.IsDir {
				if err := addVersion(tx, dst, src.BlobSHA, src.Size, uid, now, ""); err != nil {
					return err
				}
				v.auditTx(tx, a, "copy", sl.share.Name, sl.path(), "→ "+dl.share.Name+":"+dl.path())
				return checkQuota(tx, dl.share, dl.owner)
			}
			if err := softDelete(tx, dst, dl.path(), uid, now); err != nil {
				return err
			}
		} else if err != ErrNotFound {
			return err
		} else {
			created = true
		}
		if err := copyTree(tx, src, parent.ID, name, dl.share.ID, dl.owner, uid, now); err != nil {
			return err
		}
		v.auditTx(tx, a, "copy", sl.share.Name, sl.path(), "→ "+dl.share.Name+":"+dl.path())
		return checkQuota(tx, dl.share, dl.owner)
	})
	return created, err
}

func copyTree(q querier, src *Node, parentID int64, name string, shareID, owner, uid, now int64) error {
	res, err := q.Exec(`INSERT INTO nodes(share_id, owner_id, parent_id, name, is_dir, size, blob_sha, created_at, created_by, modified_at, modified_by)
		VALUES(?,?,?,?,?,?,?,?,?,?,?)`, shareID, owner, parentID, name, src.IsDir, src.Size, src.BlobSHA, now, uid, now, uid)
	if err != nil {
		return err
	}
	id, _ := res.LastInsertId()
	if !src.IsDir {
		_, err = q.Exec(`INSERT INTO versions(node_id, blob_sha, size, created_at, created_by, note) VALUES(?,?,?,?,?,?)`,
			id, src.BlobSHA, src.Size, now, uid, "복사본")
		return err
	}
	kids, err := listChildren(q, src.ID)
	if err != nil {
		return err
	}
	for _, k := range kids {
		if err := copyTree(q, k, id, k.Name, shareID, owner, uid, now); err != nil {
			return err
		}
	}
	return nil
}

func sizeText(n int64) string {
	const u = 1024
	switch {
	case n < u:
		return itoa(n) + " B"
	case n < u*u:
		return itoa(n/u) + " KB"
	case n < u*u*u:
		return itoa(n/(u*u)) + " MB"
	default:
		return itoa(n/(u*u*u)) + " GB"
	}
}
