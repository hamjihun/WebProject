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

	r.DeletedBlobs, err = v.collectGarbage()
	if err != nil {
		return r, err
	}
	if r.PurgedItems > 0 || r.PrunedVersions > 0 || r.DeletedBlobs > 0 || r.ExpiredExports > 0 {
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
