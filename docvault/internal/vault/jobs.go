package vault

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"time"
)

type MaintenanceResult struct {
	PurgedItems    int
	PrunedVersions int64
	ExpiredExports int64
	DeletedBlobs   int
	PrunedAudit    int64
}

// Maintain applies the retention rules: empties trash items older than the
// retention period, prunes old versions, expires export approvals, removes
// expired sessions and deletes file contents nothing refers to anymore.
func (v *Vault) Maintain() (MaintenanceResult, error) {
	var r MaintenanceResult
	now := v.Now()
	retention := v.Setting("retention_days") * 86400
	keepCount := v.Setting("version_keep_count")
	if keepCount < 1 {
		keepCount = 1
	}
	keepDays := v.Setting("version_keep_days")

	rows, err := v.DB.Query(`SELECT id FROM nodes WHERE delete_root=1 AND deleted_at IS NOT NULL AND deleted_at<? ORDER BY deleted_at`, now-retention)
	if err != nil {
		return r, err
	}
	var ids []int64
	for rows.Next() {
		var id int64
		rows.Scan(&id)
		ids = append(ids, id)
	}
	rows.Close()
	for _, id := range ids {
		err := v.withTx(func(tx *sql.Tx) error {
			// It may already be gone as part of an older, enclosing item.
			if _, err := nodeByID(tx, id); err != nil {
				return nil
			}
			return purgeSubtree(tx, id)
		})
		if err != nil {
			return r, err
		}
		r.PurgedItems++
	}

	res, err := v.DB.Exec(`DELETE FROM versions WHERE id IN (
			SELECT id FROM (SELECT id, created_at, ROW_NUMBER() OVER (PARTITION BY node_id ORDER BY id DESC) AS rn FROM versions)
			WHERE rn>? AND created_at<?)
		AND id NOT IN (SELECT version_id FROM exports WHERE status IN ('pending','approved'))`, keepCount, now-keepDays*86400)
	if err != nil {
		return r, err
	}
	r.PrunedVersions, _ = res.RowsAffected()

	res, err = v.DB.Exec(`UPDATE exports SET status='expired' WHERE (status='approved' AND expires_at<?) OR (status='pending' AND created_at<?)`,
		now, now-30*86400)
	if err != nil {
		return r, err
	}
	r.ExpiredExports, _ = res.RowsAffected()

	v.DB.Exec(`DELETE FROM sessions WHERE expires_at<?`, now)

	// Keep the audit log from growing without bound (0 = keep forever).
	if d := v.Setting("audit_keep_days"); d > 0 {
		if res, err := v.DB.Exec(`DELETE FROM audit WHERE ts<?`, now-d*86400); err == nil {
			r.PrunedAudit, _ = res.RowsAffected()
		}
	}

	r.DeletedBlobs, err = v.collectGarbage()
	if err != nil {
		return r, err
	}
	if r.PurgedItems > 0 || r.PrunedVersions > 0 || r.DeletedBlobs > 0 || r.ExpiredExports > 0 || r.PrunedAudit > 0 {
		v.Audit(Actor{Client: "system"}, "maintenance", "", "", fmt.Sprintf("휴지통 영구삭제 %d건, 이전버전 정리 %d건, 반출만료 %d건, 파일내용 정리 %d건",
			r.PurgedItems, r.PrunedVersions, r.ExpiredExports, r.DeletedBlobs))
	}
	return r, nil
}

func (v *Vault) collectGarbage() (int, error) {
	var shas []string
	if err := v.Blobs.Walk(func(sha string) { shas = append(shas, sha) }); err != nil {
		return 0, err
	}
	deleted := 0
	for _, sha := range shas {
		v.blobMu.Lock()
		var one int
		err := v.DB.QueryRow(`SELECT 1 FROM versions WHERE blob_sha=? LIMIT 1`, sha).Scan(&one)
		if err == sql.ErrNoRows {
			if v.Blobs.Delete(sha) == nil {
				deleted++
			}
		}
		v.blobMu.Unlock()
	}
	return deleted, nil
}

// RunMaintenance runs Maintain shortly after start and then every 6 hours.
func (v *Vault) RunMaintenance(ctx context.Context) {
	t := time.NewTimer(time.Minute)
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if r, err := v.Maintain(); err != nil {
			log.Printf("maintenance: %v", err)
		} else {
			log.Printf("maintenance: %+v", r)
		}
		t.Reset(6 * time.Hour)
	}
}

// MissingFile is a file whose current content is not in the store.
type MissingFile struct {
	Share string `json:"share"`
	Owner string `json:"owner"` // personal drive: whose space
	Path  string `json:"path"`
	Size  int64  `json:"size"`
	// RestorableVersion is the newest older version whose content is still
	// there (0 if none): restoring it brings the file back to that state.
	RestorableVersion int64 `json:"restorableVersion"`
}

// CheckStore looks for files (not in the trash) whose content is missing
// from the store, e.g. because the store folder (store_dir) was changed
// after they were saved.
func (v *Vault) CheckStore() (missing []MissingFile, checked int, err error) {
	rows, err := v.DB.Query(`SELECT n.id, n.share_id, n.owner_id, n.size, n.blob_sha FROM nodes n
		WHERE n.is_dir=0 AND n.deleted_at IS NULL`)
	if err != nil {
		return nil, 0, err
	}
	type cand struct {
		id, share, owner, size int64
		sha                    string
	}
	var bad []cand
	for rows.Next() {
		var c cand
		if rows.Scan(&c.id, &c.share, &c.owner, &c.size, &c.sha) != nil {
			continue
		}
		checked++
		if !v.Blobs.Exists(c.sha) {
			bad = append(bad, c)
		}
	}
	rows.Close()
	missing = []MissingFile{}
	for _, c := range bad {
		m := MissingFile{Size: c.size}
		if s, err := v.ShareByID(c.share); err == nil {
			m.Share = s.Name
		}
		if c.owner != 0 {
			if u, err := v.UserByID(c.owner); err == nil {
				m.Owner = u.DisplayName + " (" + u.Username + ")"
			}
		}
		if n, err := nodeByID(v.DB, c.id); err == nil {
			m.Path = pathOf(v.DB, n)
		}
		vr, _ := v.DB.Query(`SELECT id, blob_sha FROM versions WHERE node_id=? ORDER BY id DESC`, c.id)
		for vr != nil && vr.Next() {
			var id int64
			var sha string
			vr.Scan(&id, &sha)
			if sha != c.sha && v.Blobs.Exists(sha) {
				m.RestorableVersion = id
				break
			}
		}
		if vr != nil {
			vr.Close()
		}
		missing = append(missing, m)
	}
	return missing, checked, nil
}

// Overview is the admin dashboard summary.
type Overview struct {
	Users          int   `json:"users"`
	Groups         int   `json:"groups"`
	Shares         int   `json:"shares"`
	PendingExports int   `json:"pendingExports"`
	ConnectedPCs   int   `json:"connectedPCs"` // agent sessions seen in the last 5 min
	WriteBlocked   int   `json:"writeBlocked"` // accounts auto-blocked (ransomware guard)
	TrashItems     int   `json:"trashItems"`
	StoreBytes     int64 `json:"storeBytes"` // size of current file versions (not trash)
}

func (v *Vault) Overview() Overview {
	var o Overview
	q := func(sql string) int {
		var n int
		v.DB.QueryRow(sql).Scan(&n)
		return n
	}
	o.Users = q(`SELECT COUNT(*) FROM users WHERE disabled=0`)
	o.Groups = q(`SELECT COUNT(*) FROM groups`)
	o.Shares = q(`SELECT COUNT(*) FROM shares`)
	o.PendingExports = q(`SELECT COUNT(*) FROM exports WHERE status IN ('pending','post')`)
	o.WriteBlocked = q(`SELECT COUNT(*) FROM users WHERE write_blocked=1`)
	o.TrashItems = q(`SELECT COUNT(*) FROM nodes WHERE delete_root=1 AND deleted_at IS NOT NULL`)
	cutoff := v.Now() - 300
	var n int
	v.DB.QueryRow(`SELECT COUNT(*) FROM sessions WHERE kind='agent' AND last_seen>?`, cutoff).Scan(&n)
	o.ConnectedPCs = n
	v.DB.QueryRow(`SELECT COALESCE(SUM(size),0) FROM nodes WHERE is_dir=0 AND deleted_at IS NULL`).Scan(&o.StoreBytes)
	return o
}
