package vault

import (
	"database/sql"
	"errors"
	"os"
	"strings"
)

// Export is a 반출 신청: a request to take one file version out of the system.
type Export struct {
	ID            int64  `json:"id"`
	ShareName     string `json:"shareName"`
	FilePath      string `json:"filePath"`
	FileName      string `json:"fileName"`
	VersionID     int64  `json:"versionId"`
	Size          int64  `json:"size"`
	RequesterID   int64  `json:"-"`
	Requester     string `json:"requester"`
	Reason        string `json:"reason"`
	Status        string `json:"status"` // pending approved rejected cancelled expired
	Approver      string `json:"approver"`
	DecisionNote  string `json:"decisionNote"`
	CreatedAt     int64  `json:"createdAt"`
	DecidedAt     int64  `json:"decidedAt"`
	ExpiresAt     int64  `json:"expiresAt"`
	DownloadCount int    `json:"downloadCount"`
	MaxDownloads  int    `json:"maxDownloads"`
	CanApprove    bool   `json:"canApprove"`
	CanDownload   bool   `json:"canDownload"`
	shareID       int64
	blobSHA       string
}

const exportSelect = `SELECT e.id, s.name, e.file_path, e.file_name, e.version_id, COALESCE(ver.size,0), COALESCE(ver.blob_sha,''),
	e.requester_id, COALESCE(ru.username,''), COALESCE(ru.display_name,''), e.reason, e.status,
	COALESCE(au.username,''), COALESCE(au.display_name,''), e.decision_note, e.created_at, COALESCE(e.decided_at,0),
	COALESCE(e.expires_at,0), e.download_count, e.max_downloads, e.share_id
	FROM exports e JOIN shares s ON s.id=e.share_id
	LEFT JOIN versions ver ON ver.id=e.version_id
	LEFT JOIN users ru ON ru.id=e.requester_id
	LEFT JOIN users au ON au.id=e.approver_id `

func scanExport(r rowScanner) (*Export, error) {
	e := &Export{}
	var run, rdn, aun, adn string
	err := r.Scan(&e.ID, &e.ShareName, &e.FilePath, &e.FileName, &e.VersionID, &e.Size, &e.blobSHA,
		&e.RequesterID, &run, &rdn, &e.Reason, &e.Status, &aun, &adn, &e.DecisionNote, &e.CreatedAt, &e.DecidedAt,
		&e.ExpiresAt, &e.DownloadCount, &e.MaxDownloads, &e.shareID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	e.Requester = (&User{Username: run, DisplayName: rdn}).Label()
	if aun != "" {
		e.Approver = (&User{Username: aun, DisplayName: adn}).Label()
	}
	return e, err
}

func (v *Vault) canApprove(u *User, e *Export) bool {
	if u.ID == e.RequesterID {
		return false
	}
	return u.IsAdmin || aclLevel(v.DB, u, e.shareID) >= LevelManage
}

func (v *Vault) decorate(u *User, e *Export) *Export {
	now := v.Now()
	e.CanApprove = e.Status == "pending" && v.canApprove(u, e)
	e.CanDownload = e.Status == "approved" && u.ID == e.RequesterID && now < e.ExpiresAt && e.DownloadCount < e.MaxDownloads
	return e
}

// RequestExport files a 반출 신청 for the file's current version.
func (v *Vault) RequestExport(a Actor, shareName, p, reason string) (*Export, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return nil, errors.New("반출 사유를 입력하세요")
	}
	n, err := v.Stat(a, shareName, p)
	if err != nil {
		return nil, err
	}
	if n.IsDir {
		return nil, errors.New("폴더는 반출 신청할 수 없습니다. 파일을 선택하세요")
	}
	s, _ := v.ShareByName(shareName)
	var vid int64
	if err := v.DB.QueryRow(`SELECT MAX(id) FROM versions WHERE node_id=?`, n.ID).Scan(&vid); err != nil || vid == 0 {
		return nil, ErrNotFound
	}
	fp := joinPathStr(p)
	res, err := v.DB.Exec(`INSERT INTO exports(node_id, version_id, share_id, file_name, file_path, requester_id, reason, created_at, max_downloads)
		VALUES(?,?,?,?,?,?,?,?,?)`, n.ID, vid, s.ID, n.Name, fp, a.User.ID, reason, v.Now(), v.Setting("export_max_downloads"))
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	v.Audit(a, "export_request", s.Name, fp, reason)
	return v.ExportByID(a.User, id)
}

func (v *Vault) ExportByID(u *User, id int64) (*Export, error) {
	e, err := scanExport(v.DB.QueryRow(exportSelect+`WHERE e.id=?`, id))
	if err != nil {
		return nil, err
	}
	if e.RequesterID != u.ID && !u.IsAdmin && aclLevel(v.DB, u, e.shareID) < LevelManage {
		return nil, ErrNotFound
	}
	return v.decorate(u, e), nil
}

// ListExports returns the user's own requests ("mine"), the requests they can
// decide ("inbox"), or everything visible to an admin ("all").
func (v *Vault) ListExports(u *User, scope string) ([]*Export, error) {
	var q string
	var args []any
	switch scope {
	case "mine":
		q, args = exportSelect+`WHERE e.requester_id=? ORDER BY e.id DESC LIMIT 500`, []any{u.ID}
	case "inbox":
		if u.IsAdmin {
			q, args = exportSelect+`WHERE e.requester_id<>? ORDER BY e.status='pending' DESC, e.id DESC LIMIT 500`, []any{u.ID}
		} else {
			q, args = exportSelect+`WHERE e.requester_id<>? AND e.share_id IN (SELECT share_id FROM share_acl WHERE level>=3 AND (
				(principal_type='user' AND principal_id=?) OR
				(principal_type='group' AND principal_id IN (SELECT group_id FROM group_members WHERE user_id=?))))
				ORDER BY e.status='pending' DESC, e.id DESC LIMIT 500`, []any{u.ID, u.ID, u.ID}
		}
	case "all":
		if !u.IsAdmin {
			return nil, ErrForbidden
		}
		q = exportSelect + `ORDER BY e.id DESC LIMIT 1000`
	default:
		return nil, ErrBadRequest
	}
	rows, err := v.DB.Query(q, args...)
	if err != nil {
		return nil, err
	}
	var list []*Export
	for rows.Next() {
		e, err := scanExport(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		list = append(list, e)
	}
	rows.Close()
	out := []*Export{}
	for _, e := range list {
		out = append(out, v.decorate(u, e))
	}
	return out, nil
}

// DecideExport approves or rejects a pending request.
func (v *Vault) DecideExport(a Actor, id int64, approve bool, note string) error {
	e, err := scanExport(v.DB.QueryRow(exportSelect+`WHERE e.id=?`, id))
	if err != nil {
		return err
	}
	if e.Status != "pending" {
		return errors.New("이미 처리된 신청입니다")
	}
	if !v.canApprove(a.User, e) {
		return ErrForbidden
	}
	now := v.Now()
	status, action := "rejected", "export_reject"
	var expires any
	if approve {
		status, action = "approved", "export_approve"
		expires = now + v.Setting("export_valid_days")*86400
	}
	res, err := v.DB.Exec(`UPDATE exports SET status=?, approver_id=?, decision_note=?, decided_at=?, expires_at=? WHERE id=? AND status='pending'`,
		status, a.User.ID, strings.TrimSpace(note), now, expires, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return errors.New("이미 처리된 신청입니다")
	}
	v.Audit(a, action, e.ShareName, e.FilePath, "신청자: "+e.Requester+" / "+note)
	if approve {
		v.deliverExport(e)
	}
	return nil
}

// deliverExport puts the approved file version in the requester's export
// folder (개인문서함\반출), from where it may be taken out of the system.
func (v *Vault) deliverExport(e *Export) {
	u, err := v.UserByID(e.RequesterID)
	if err != nil {
		return
	}
	s := v.personalShare()
	if s == nil {
		return
	}
	a := Actor{User: u, Client: "export"}
	if err := v.Mkdir(a, s.Name, "/"+ExportFolder); err != nil && err != ErrExists {
		v.Audit(a, "export_deliver_fail", s.Name, "/"+ExportFolder, err.Error())
		return
	}
	name := e.FileName
	base, ext := name, ""
	if i := strings.LastIndex(name, "."); i > 0 {
		base, ext = name[:i], name[i:]
	}
	for i := 2; i < 100; i++ {
		if _, err := v.Stat(a, s.Name, "/"+ExportFolder+"/"+name); err == ErrNotFound {
			break
		}
		name = base + " (" + itoa(int64(i)) + ")" + ext
	}
	f, err := v.Blobs.Open(e.blobSHA)
	if err != nil {
		v.Audit(a, "export_deliver_fail", s.Name, "/"+ExportFolder+"/"+name, err.Error())
		return
	}
	defer f.Close()
	if _, _, err := v.Put(a, s.Name, "/"+ExportFolder+"/"+name, f); err != nil {
		v.Audit(a, "export_deliver_fail", s.Name, "/"+ExportFolder+"/"+name, err.Error())
	}
}

func (v *Vault) personalShare() *Share {
	shares, _ := v.ListShares()
	for _, s := range shares {
		if s.Personal {
			return s
		}
	}
	return nil
}

func (v *Vault) CancelExport(a Actor, id int64) error {
	res, err := v.DB.Exec(`UPDATE exports SET status='cancelled', decided_at=? WHERE id=? AND requester_id=? AND status='pending'`, v.Now(), id, a.User.ID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	v.Audit(a, "export_cancel", "", "", "신청 #"+itoa(id))
	return nil
}

// OpenExport hands an approved file to its requester and counts the download.
func (v *Vault) OpenExport(a Actor, id int64) (*Export, *os.File, error) {
	e, err := v.ExportByID(a.User, id)
	if err != nil {
		return nil, nil, err
	}
	if !e.CanDownload {
		return nil, nil, ErrForbidden
	}
	res, err := v.DB.Exec(`UPDATE exports SET download_count=download_count+1 WHERE id=? AND download_count<max_downloads AND status='approved'`, id)
	if err != nil {
		return nil, nil, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, nil, ErrForbidden
	}
	f, err := v.Blobs.Open(e.blobSHA)
	if err != nil {
		return nil, nil, err
	}
	v.Audit(a, "export_download", e.ShareName, e.FilePath, "신청 #"+itoa(id)+" ("+itoa(int64(e.DownloadCount+1))+"/"+itoa(int64(e.MaxDownloads))+"회)")
	return e, f, nil
}
