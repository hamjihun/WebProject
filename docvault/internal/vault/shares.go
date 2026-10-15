package vault

import (
	"database/sql"
	"errors"
	"strconv"
	"strings"
)

const (
	LevelNone   = 0
	LevelRead   = 1
	LevelWrite  = 2
	LevelManage = 3 // 팀장: 반출 결재, 휴지통 관리
)

var levelNames = map[int]string{LevelRead: "읽기", LevelWrite: "읽기/쓰기", LevelManage: "관리"}

// Share is one drive (드라이브) shown on users' PCs.
type Share struct {
	ID          int64  `json:"id"`
	Name        string `json:"name"`
	DriveLetter string `json:"driveLetter"`
	Personal    bool   `json:"personal"`
	QuotaBytes  int64  `json:"quotaBytes"`
}

type ACLEntry struct {
	PrincipalType string `json:"principalType"` // user | group
	PrincipalID   int64  `json:"principalId"`
	Name          string `json:"name"`
	Level         int    `json:"level"`
}

const shareCols = `id, name, drive_letter, personal, quota_bytes`

func scanShare(r rowScanner) (*Share, error) {
	s := &Share{}
	err := r.Scan(&s.ID, &s.Name, &s.DriveLetter, &s.Personal, &s.QuotaBytes)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return s, err
}

func (v *Vault) ShareByName(name string) (*Share, error) {
	return scanShare(v.DB.QueryRow(`SELECT `+shareCols+` FROM shares WHERE name=?`, name))
}

func (v *Vault) ShareByID(id int64) (*Share, error) {
	return scanShare(v.DB.QueryRow(`SELECT `+shareCols+` FROM shares WHERE id=?`, id))
}

func (v *Vault) ListShares() ([]*Share, error) {
	rows, err := v.DB.Query(`SELECT ` + shareCols + ` FROM shares ORDER BY drive_letter, name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Share
	for rows.Next() {
		s, err := scanShare(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, nil
}

func normLetter(l string) (string, error) {
	l = strings.ToUpper(strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(l), ":")))
	if l == "" {
		return "", nil
	}
	if len(l) != 1 || l[0] < 'D' || l[0] > 'Z' {
		return "", errors.New("드라이브 문자는 D~Z 중 하나여야 합니다")
	}
	return l, nil
}

func (v *Vault) CreateShare(a Actor, name, letter string, personal bool, quota int64) (*Share, error) {
	name = strings.TrimSpace(name)
	if err := validName(name); err != nil {
		return nil, errors.New("드라이브 이름에 사용할 수 없는 문자가 있습니다")
	}
	l, err := normLetter(letter)
	if err != nil {
		return nil, err
	}
	if quota < 0 {
		return nil, ErrBadRequest
	}
	res, err := v.DB.Exec(`INSERT INTO shares(name, drive_letter, personal, quota_bytes, created_at) VALUES(?,?,?,?,?)`,
		name, l, personal, quota, v.Now())
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			return nil, errors.New("이미 존재하는 드라이브 이름입니다")
		}
		return nil, err
	}
	id, _ := res.LastInsertId()
	v.Audit(a, "admin_share_create", name, "", "")
	return v.ShareByID(id)
}

func (v *Vault) UpdateShare(a Actor, id int64, letter string, quota int64) error {
	l, err := normLetter(letter)
	if err != nil {
		return err
	}
	if quota < 0 {
		return ErrBadRequest
	}
	s, err := v.ShareByID(id)
	if err != nil {
		return err
	}
	_, err = v.DB.Exec(`UPDATE shares SET drive_letter=?, quota_bytes=? WHERE id=?`, l, quota, id)
	if err == nil {
		v.Audit(a, "admin_share_update", s.Name, "", "드라이브 "+l)
	}
	return err
}

// DeleteShare removes an empty drive. Drives with files must be emptied first.
func (v *Vault) DeleteShare(a Actor, id int64) error {
	return v.withTx(func(tx *sql.Tx) error {
		var name string
		if err := tx.QueryRow(`SELECT name FROM shares WHERE id=?`, id).Scan(&name); err != nil {
			return ErrNotFound
		}
		var n int
		tx.QueryRow(`SELECT COUNT(*) FROM nodes WHERE share_id=? AND parent_id IS NOT NULL`, id).Scan(&n)
		if n > 0 {
			return errors.New("파일이 있는 드라이브는 삭제할 수 없습니다 (휴지통 포함)")
		}
		tx.Exec(`DELETE FROM nodes WHERE share_id=?`, id)
		tx.Exec(`DELETE FROM share_acl WHERE share_id=?`, id)
		if _, err := tx.Exec(`DELETE FROM shares WHERE id=?`, id); err != nil {
			return err
		}
		v.auditTx(tx, a, "admin_share_delete", name, "", "")
		return nil
	})
}

func (v *Vault) ShareACL(id int64) ([]ACLEntry, error) {
	rows, err := v.DB.Query(`SELECT a.principal_type, a.principal_id, a.level,
		CASE a.principal_type WHEN 'user' THEN (SELECT CASE WHEN display_name<>'' THEN display_name||'('||username||')' ELSE username END FROM users WHERE id=a.principal_id)
		ELSE (SELECT name FROM groups WHERE id=a.principal_id) END
		FROM share_acl a WHERE a.share_id=? ORDER BY a.principal_type, a.level DESC`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ACLEntry{}
	for rows.Next() {
		var e ACLEntry
		var name sql.NullString
		rows.Scan(&e.PrincipalType, &e.PrincipalID, &e.Level, &name)
		e.Name = name.String
		out = append(out, e)
	}
	return out, nil
}

func (v *Vault) SetShareACL(a Actor, id int64, entries []ACLEntry) error {
	return v.withTx(func(tx *sql.Tx) error {
		var name string
		if err := tx.QueryRow(`SELECT name FROM shares WHERE id=?`, id).Scan(&name); err != nil {
			return ErrNotFound
		}
		if _, err := tx.Exec(`DELETE FROM share_acl WHERE share_id=?`, id); err != nil {
			return err
		}
		var desc []string
		for _, e := range entries {
			if (e.PrincipalType != "user" && e.PrincipalType != "group") || e.Level < 1 || e.Level > 3 {
				return ErrBadRequest
			}
			if _, err := tx.Exec(`INSERT OR REPLACE INTO share_acl(share_id,principal_type,principal_id,level) VALUES(?,?,?,?)`,
				id, e.PrincipalType, e.PrincipalID, e.Level); err != nil {
				return err
			}
			var who string
			if e.PrincipalType == "group" {
				tx.QueryRow(`SELECT '그룹 '||name FROM groups WHERE id=?`, e.PrincipalID).Scan(&who)
			} else {
				tx.QueryRow(`SELECT username FROM users WHERE id=?`, e.PrincipalID).Scan(&who)
			}
			desc = append(desc, who+"="+levelNames[e.Level])
		}
		if len(desc) == 0 {
			desc = []string{"모든 권한 삭제"}
		}
		v.auditTx(tx, a, "admin_share_acl", name, "", strings.Join(desc, ", "))
		return nil
	})
}

// aclLevel is the highest level granted to u (directly or via a group) on the share.
func aclLevel(q interface {
	QueryRow(string, ...any) *sql.Row
}, u *User, shareID int64) int {
	var lvl sql.NullInt64
	q.QueryRow(`SELECT MAX(level) FROM share_acl WHERE share_id=? AND (
		(principal_type='user' AND principal_id=?) OR
		(principal_type='group' AND principal_id IN (SELECT group_id FROM group_members WHERE user_id=?)))`,
		shareID, u.ID, u.ID).Scan(&lvl)
	return int(lvl.Int64)
}

// Level is u's effective permission on the share. For a personal share every
// user can write their own space; the ACL only grants approver (manage) rights.
func (v *Vault) Level(u *User, s *Share) int {
	if u == nil {
		return LevelNone
	}
	if u.IsAdmin {
		return LevelManage
	}
	lvl := aclLevel(v.DB, u, s.ID)
	if s.Personal && lvl < LevelWrite {
		lvl = LevelWrite
	}
	return lvl
}

// Drive is a share as seen by one user (for the PC agent and the web UI).
type Drive struct {
	Share
	Level int   `json:"level"`
	Used  int64 `json:"used"`
}

func (v *Vault) DrivesFor(u *User) ([]Drive, error) {
	shares, err := v.ListShares()
	if err != nil {
		return nil, err
	}
	out := []Drive{}
	for _, s := range shares {
		lvl := v.Level(u, s)
		if lvl == LevelNone {
			continue
		}
		out = append(out, Drive{Share: *s, Level: lvl, Used: v.Usage(s, v.spaceOwner(s, u))})
	}
	return out, nil
}

// DriveFor returns one drive as seen by u, or ErrNotFound if u has no access.
func (v *Vault) DriveFor(u *User, name string) (*Drive, error) {
	s, err := v.ShareByName(name)
	if err != nil {
		return nil, ErrNotFound
	}
	lvl := v.Level(u, s)
	if lvl == LevelNone {
		return nil, ErrNotFound
	}
	return &Drive{Share: *s, Level: lvl, Used: v.Usage(s, v.spaceOwner(s, u))}, nil
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
