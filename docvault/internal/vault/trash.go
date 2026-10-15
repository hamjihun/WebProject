package vault

import (
	"database/sql"
	"path"
	"strings"
)

// ---- versions ----

type Version struct {
	ID        int64  `json:"id"`
	Size      int64  `json:"size"`
	CreatedAt int64  `json:"createdAt"`
	CreatedBy string `json:"createdBy"`
	Note      string `json:"note"`
	Current   bool   `json:"current"`
}

func (v *Vault) Versions(a Actor, shareName, p string) ([]Version, error) {
	n, err := v.Stat(a, shareName, p)
	if err != nil {
		return nil, err
	}
	if n.IsDir {
		return nil, ErrIsDir
	}
	rows, err := v.DB.Query(`SELECT v.id, v.size, v.created_at, COALESCE(u.username,''), COALESCE(u.display_name,''), v.note
		FROM versions v LEFT JOIN users u ON u.id=v.created_by WHERE v.node_id=? ORDER BY v.id DESC`, n.ID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Version{}
	for rows.Next() {
		var ver Version
		var un, dn string
		rows.Scan(&ver.ID, &ver.Size, &ver.CreatedAt, &un, &dn, &ver.Note)
		ver.CreatedBy = (&User{Username: un, DisplayName: dn}).Label()
		out = append(out, ver)
	}
	if len(out) > 0 {
		out[0].Current = true
	}
	return out, nil
}

// RestoreVersion makes an old version current again (as a new version, so
// nothing is lost).
func (v *Vault) RestoreVersion(a Actor, shareName, p string, versionID int64) error {
	l, err := v.locate(a, shareName, p, LevelWrite)
	if err != nil {
		return err
	}
	now := v.Now()
	v.blobMu.RLock()
	defer v.blobMu.RUnlock()
	return v.withTx(func(tx *sql.Tx) error {
		n, err := v.resolve(tx, l, l.parts)
		if err != nil {
			return err
		}
		if n.IsDir {
			return ErrIsDir
		}
		var sha string
		var size int64
		var created int64
		if err := tx.QueryRow(`SELECT blob_sha, size, created_at FROM versions WHERE id=? AND node_id=?`, versionID, n.ID).Scan(&sha, &size, &created); err != nil {
			return ErrNotFound
		}
		n.BlobSHA = "" // always record the restore as a new version
		if err := addVersion(tx, n, sha, size, a.User.ID, now, "이전 버전 복원 (#"+itoa(versionID)+")"); err != nil {
			return err
		}
		if err := checkQuota(tx, l.share, l.owner); err != nil {
			return err
		}
		v.auditTx(tx, a, "restore_version", l.share.Name, l.path(), "버전 #"+itoa(versionID))
		return nil
	})
}

// ---- trash ----

type TrashItem struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	OrigPath  string `json:"origPath"`
	IsDir     bool   `json:"isDir"`
	Size      int64  `json:"size"`
	DeletedAt int64  `json:"deletedAt"`
	DeletedBy string `json:"deletedBy"`
	PurgeAt   int64  `json:"purgeAt"`
}

func (v *Vault) Trash(a Actor, shareName string) ([]TrashItem, error) {
	l, err := v.locate(a, shareName, "/", LevelWrite)
	if err != nil {
		return nil, err
	}
	retention := v.Setting("retention_days") * 86400
	rows, err := v.DB.Query(`SELECT n.id, n.name, n.orig_path, n.is_dir,
		CASE n.is_dir WHEN 1 THEN (SELECT COALESCE(SUM(size),0) FROM nodes m WHERE m.delete_batch=n.delete_batch AND m.is_dir=0) ELSE n.size END,
		n.deleted_at, COALESCE(u.username,''), COALESCE(u.display_name,'')
		FROM nodes n LEFT JOIN users u ON u.id=n.deleted_by
		WHERE n.share_id=? AND n.owner_id=? AND n.delete_root=1 AND n.deleted_at IS NOT NULL
		ORDER BY n.deleted_at DESC LIMIT 2000`, l.share.ID, l.owner)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []TrashItem{}
	for rows.Next() {
		var t TrashItem
		var un, dn string
		rows.Scan(&t.ID, &t.Name, &t.OrigPath, &t.IsDir, &t.Size, &t.DeletedAt, &un, &dn)
		t.DeletedBy = (&User{Username: un, DisplayName: dn}).Label()
		t.PurgeAt = t.DeletedAt + retention
		out = append(out, t)
	}
	return out, nil
}

func (v *Vault) trashItem(tx *sql.Tx, l *loc, id int64) (*Node, error) {
	n, err := nodeByID(tx, id)
	if err != nil || n.ShareID != l.share.ID || n.OwnerID != l.owner || !n.DeleteRoot || n.DeletedAt == 0 {
		return nil, ErrNotFound
	}
	return n, nil
}

// RestoreTrash puts a deleted item back to its folder (or the drive root if that
// folder no longer exists). Name clashes get a " (복원 N)" suffix.
func (v *Vault) RestoreTrash(a Actor, shareName string, id int64) (string, error) {
	l, err := v.locate(a, shareName, "/", LevelWrite)
	if err != nil {
		return "", err
	}
	var restored string
	err = v.withTx(func(tx *sql.Tx) error {
		n, err := v.trashItem(tx, l, id)
		if err != nil {
			return err
		}
		parentID := n.ParentID
		if p, err := nodeByID(tx, parentID); err != nil || p.DeletedAt != 0 || p.ShareID != n.ShareID || p.OwnerID != n.OwnerID {
			root, err := spaceRoot(tx, l.share.ID, l.owner, v.Now())
			if err != nil {
				return err
			}
			parentID = root.ID
		}
		name := uniqueName(tx, parentID, n.Name)
		if _, err := tx.Exec(`UPDATE nodes SET delete_root=0, orig_path='', parent_id=?, name=?, prev_name='', prev_name_at=0 WHERE id=?`,
			parentID, name, n.ID); err != nil {
			return err
		}
		if _, err := tx.Exec(`UPDATE nodes SET deleted_at=NULL, deleted_by=NULL, delete_batch=NULL WHERE delete_batch=?`, n.DeleteBatch); err != nil {
			return err
		}
		n.ParentID, n.Name = parentID, name
		restored = pathOf(tx, n)
		if err := checkQuota(tx, l.share, l.owner); err != nil {
			return err
		}
		v.auditTx(tx, a, "restore_trash", l.share.Name, restored, "원래 위치: "+n.OrigPath)
		return nil
	})
	return restored, err
}

func uniqueName(q querier, parentID int64, name string) string {
	if _, err := child(q, parentID, name); err == ErrNotFound {
		return name
	}
	ext := path.Ext(name)
	base := strings.TrimSuffix(name, ext)
	for i := 1; ; i++ {
		cand := base + " (복원 " + itoa(int64(i)) + ")" + ext
		if _, err := child(q, parentID, cand); err == ErrNotFound {
			return cand
		}
	}
}

// PurgeTrash permanently deletes a trash item before its retention ends.
// Only drive managers (팀장) and admins may do this.
func (v *Vault) PurgeTrash(a Actor, shareName string, id int64) error {
	l, err := v.locate(a, shareName, "/", LevelManage)
	if err != nil {
		return err
	}
	return v.withTx(func(tx *sql.Tx) error {
		n, err := v.trashItem(tx, l, id)
		if err != nil {
			return err
		}
		if err := purgeSubtree(tx, n.ID); err != nil {
			return err
		}
		v.auditTx(tx, a, "purge", l.share.Name, n.OrigPath, "휴지통에서 영구 삭제")
		return nil
	})
}
