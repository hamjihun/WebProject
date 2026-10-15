package vault

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"strings"
	"sync"

	"golang.org/x/crypto/bcrypt"
)

type User struct {
	ID           int64    `json:"id"`
	Username     string   `json:"username"`
	DisplayName  string   `json:"displayName"`
	IsAdmin      bool     `json:"isAdmin"`
	Disabled     bool     `json:"disabled"`
	WriteBlocked bool     `json:"writeBlocked"`
	Groups       []string `json:"groups,omitempty"`
	GroupIDs     []int64  `json:"groupIds,omitempty"`
}

// Label is how the user appears in logs and lists.
func (u *User) Label() string {
	if u == nil {
		return ""
	}
	if u.DisplayName != "" {
		return u.DisplayName + "(" + u.Username + ")"
	}
	return u.Username
}

const userCols = `id, username, display_name, is_admin, disabled, write_blocked`

type rowScanner interface{ Scan(...any) error }

func scanUser(r rowScanner) (*User, error) {
	u := &User{}
	err := r.Scan(&u.ID, &u.Username, &u.DisplayName, &u.IsAdmin, &u.Disabled, &u.WriteBlocked)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return u, err
}

func (v *Vault) UserByID(id int64) (*User, error) {
	return scanUser(v.DB.QueryRow(`SELECT `+userCols+` FROM users WHERE id=?`, id))
}

func (v *Vault) UserCount() (n int64) {
	v.DB.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&n)
	return
}

func validUsername(s string) bool {
	if len(s) < 2 || len(s) > 64 {
		return false
	}
	for _, c := range s {
		if !(c == '.' || c == '_' || c == '-' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
			return false
		}
	}
	return true
}

func hashPassword(p string) (string, error) {
	if len(p) < 8 {
		return "", errors.New("비밀번호는 8자 이상이어야 합니다")
	}
	h, err := bcrypt.GenerateFromPassword([]byte(p), bcrypt.DefaultCost)
	return string(h), err
}

func (v *Vault) CreateUser(a Actor, username, displayName, password string, isAdmin bool) (*User, error) {
	username = strings.TrimSpace(username)
	if !validUsername(username) {
		return nil, errors.New("아이디는 영문/숫자/._- 2~64자여야 합니다")
	}
	h, err := hashPassword(password)
	if err != nil {
		return nil, err
	}
	res, err := v.DB.Exec(`INSERT INTO users(username, display_name, password_hash, is_admin, created_at) VALUES(?,?,?,?,?)`,
		username, strings.TrimSpace(displayName), h, isAdmin, v.Now())
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			return nil, errors.New("이미 존재하는 아이디입니다")
		}
		return nil, err
	}
	id, _ := res.LastInsertId()
	v.Audit(a, "admin_user_create", "", "", username)
	return v.UserByID(id)
}

type UserUpdate struct {
	DisplayName  *string `json:"displayName"`
	Password     *string `json:"password"`
	IsAdmin      *bool   `json:"isAdmin"`
	Disabled     *bool   `json:"disabled"`
	WriteBlocked *bool   `json:"writeBlocked"`
	GroupIDs     []int64 `json:"groupIds"`
}

func (v *Vault) UpdateUser(a Actor, id int64, up UserUpdate) error {
	u, err := v.UserByID(id)
	if err != nil {
		return err
	}
	var hash string
	if up.Password != nil && *up.Password != "" {
		if hash, err = hashPassword(*up.Password); err != nil {
			return err
		}
	}
	if a.User != nil && a.User.ID == id && ((up.IsAdmin != nil && !*up.IsAdmin) || (up.Disabled != nil && *up.Disabled)) {
		return errors.New("자기 자신의 관리자 권한 해제/비활성화는 할 수 없습니다")
	}
	var changes []string
	err = v.withTx(func(tx *sql.Tx) error {
		if up.DisplayName != nil {
			tx.Exec(`UPDATE users SET display_name=? WHERE id=?`, strings.TrimSpace(*up.DisplayName), id)
			changes = append(changes, "이름")
		}
		if hash != "" {
			tx.Exec(`UPDATE users SET password_hash=?, failed_logins=0, locked_until=0 WHERE id=?`, hash, id)
			changes = append(changes, "비밀번호")
		}
		if up.IsAdmin != nil {
			tx.Exec(`UPDATE users SET is_admin=? WHERE id=?`, *up.IsAdmin, id)
			changes = append(changes, "관리자")
		}
		if up.Disabled != nil {
			tx.Exec(`UPDATE users SET disabled=? WHERE id=?`, *up.Disabled, id)
			if *up.Disabled {
				tx.Exec(`DELETE FROM sessions WHERE user_id=?`, id)
			}
			changes = append(changes, "사용여부")
		}
		if up.WriteBlocked != nil {
			tx.Exec(`UPDATE users SET write_blocked=? WHERE id=?`, *up.WriteBlocked, id)
			changes = append(changes, "쓰기차단")
		}
		if up.GroupIDs != nil {
			if _, err := tx.Exec(`DELETE FROM group_members WHERE user_id=?`, id); err != nil {
				return err
			}
			for _, g := range up.GroupIDs {
				if _, err := tx.Exec(`INSERT OR IGNORE INTO group_members(group_id,user_id) VALUES(?,?)`, g, id); err != nil {
					return err
				}
			}
			changes = append(changes, "그룹")
		}
		return nil
	})
	if err == nil {
		v.Audit(a, "admin_user_update", "", "", u.Username+": "+strings.Join(changes, ","))
	}
	return err
}

func (v *Vault) ListUsers() ([]*User, error) {
	rows, err := v.DB.Query(`SELECT ` + userCols + ` FROM users ORDER BY username`)
	if err != nil {
		return nil, err
	}
	var out []*User
	byID := map[int64]*User{}
	for rows.Next() {
		u, err := scanUser(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		out = append(out, u)
		byID[u.ID] = u
	}
	rows.Close()
	rows, err = v.DB.Query(`SELECT gm.user_id, g.id, g.name FROM group_members gm JOIN groups g ON g.id=gm.group_id ORDER BY g.name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var uid, gid int64
		var name string
		rows.Scan(&uid, &gid, &name)
		if u := byID[uid]; u != nil {
			u.Groups = append(u.Groups, name)
			u.GroupIDs = append(u.GroupIDs, gid)
		}
	}
	return out, nil
}

// ---- groups ----

type Group struct {
	ID      int64  `json:"id"`
	Name    string `json:"name"`
	Members int    `json:"members"`
}

func (v *Vault) ListGroups() ([]Group, error) {
	rows, err := v.DB.Query(`SELECT g.id, g.name, (SELECT COUNT(*) FROM group_members m WHERE m.group_id=g.id) FROM groups g ORDER BY g.name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Group
	for rows.Next() {
		var g Group
		rows.Scan(&g.ID, &g.Name, &g.Members)
		out = append(out, g)
	}
	return out, nil
}

func (v *Vault) CreateGroup(a Actor, name string) (int64, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return 0, ErrBadRequest
	}
	res, err := v.DB.Exec(`INSERT INTO groups(name) VALUES(?)`, name)
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			return 0, errors.New("이미 존재하는 그룹입니다")
		}
		return 0, err
	}
	v.Audit(a, "admin_group_create", "", "", name)
	return res.LastInsertId()
}

func (v *Vault) DeleteGroup(a Actor, id int64) error {
	return v.withTx(func(tx *sql.Tx) error {
		var name string
		if err := tx.QueryRow(`SELECT name FROM groups WHERE id=?`, id).Scan(&name); err != nil {
			return ErrNotFound
		}
		tx.Exec(`DELETE FROM share_acl WHERE principal_type='group' AND principal_id=?`, id)
		if _, err := tx.Exec(`DELETE FROM groups WHERE id=?`, id); err != nil {
			return err
		}
		v.auditTx(tx, a, "admin_group_delete", "", "", name)
		return nil
	})
}

// ---- authentication & sessions ----

const (
	maxFailedLogins = 5
	lockSeconds     = 600
)

var dummyHash, _ = bcrypt.GenerateFromPassword([]byte("dummy-password-for-timing"), bcrypt.DefaultCost)

// Login checks the credentials and opens a session. kind is "web" or "agent".
func (v *Vault) Login(username, password, kind, device, ip string) (string, *User, error) {
	a := Actor{IP: ip, Client: kind}
	var u *User
	var hash string
	var failed int
	var lockedUntil int64
	row := v.DB.QueryRow(`SELECT `+userCols+`, password_hash, failed_logins, locked_until FROM users WHERE username=?`, strings.TrimSpace(username))
	u = &User{}
	err := row.Scan(&u.ID, &u.Username, &u.DisplayName, &u.IsAdmin, &u.Disabled, &u.WriteBlocked, &hash, &failed, &lockedUntil)
	if err != nil {
		bcrypt.CompareHashAndPassword(dummyHash, []byte(password))
		v.Audit(a, "login_fail", "", "", "없는 아이디: "+username)
		return "", nil, ErrUnauthorized
	}
	a.User = u
	now := v.Now()
	if lockedUntil > now {
		v.Audit(a, "login_fail", "", "", "잠긴 계정")
		return "", nil, ErrLocked
	}
	if u.Disabled {
		v.Audit(a, "login_fail", "", "", "비활성 계정")
		return "", nil, ErrUnauthorized
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) != nil {
		failed++
		if failed >= maxFailedLogins {
			v.DB.Exec(`UPDATE users SET failed_logins=0, locked_until=? WHERE id=?`, now+lockSeconds, u.ID)
			v.Audit(a, "login_fail", "", "", "비밀번호 5회 오류 - 10분 잠금")
		} else {
			v.DB.Exec(`UPDATE users SET failed_logins=? WHERE id=?`, failed, u.ID)
			v.Audit(a, "login_fail", "", "", "비밀번호 오류")
		}
		return "", nil, ErrUnauthorized
	}
	v.DB.Exec(`UPDATE users SET failed_logins=0, locked_until=0 WHERE id=?`, u.ID)
	token, err := v.newSession(u, kind, device, ip)
	if err != nil {
		return "", nil, err
	}
	v.Audit(a, "login", "", "", device)
	return token, u, nil
}

func (v *Vault) newSession(u *User, kind, device, ip string) (string, error) {
	if kind != "agent" {
		kind = "web"
	}
	now := v.Now()
	token := randomID(32)
	_, err := v.DB.Exec(`INSERT INTO sessions(token_hash,user_id,kind,device,ip,created_at,expires_at,last_seen) VALUES(?,?,?,?,?,?,?,?)`,
		tokenHash(token), u.ID, kind, device, ip, now, now+v.sessionTTL(kind), now)
	return token, err
}

// PairAgent opens a PC-agent session for a user who approved the PC in the
// browser (they are already signed in there, so no password is asked again).
func (v *Vault) PairAgent(a Actor, device, agentIP string) (string, error) {
	if a.User == nil || a.User.Disabled {
		return "", ErrUnauthorized
	}
	token, err := v.newSession(a.User, "agent", device, agentIP)
	if err == nil {
		v.Audit(a, "agent_pair", "", "", "PC 연결 승인: "+device+" ("+agentIP+")")
	}
	return token, err
}

func (v *Vault) sessionTTL(kind string) int64 {
	if kind == "agent" {
		return v.Setting("session_agent_days") * 86400
	}
	return v.Setting("session_web_hours") * 3600
}

func tokenHash(t string) string {
	h := sha256.Sum256([]byte(t))
	return hex.EncodeToString(h[:])
}

type Session struct {
	ID   int64
	Kind string
}

// Authenticate resolves a session token. Sessions slide: each use extends them.
func (v *Vault) Authenticate(token string) (*User, *Session, error) {
	if token == "" {
		return nil, nil, ErrUnauthorized
	}
	var sid, expires, lastSeen int64
	var kind string
	u := &User{}
	err := v.DB.QueryRow(`SELECT s.id, s.kind, s.expires_at, s.last_seen, u.id, u.username, u.display_name, u.is_admin, u.disabled, u.write_blocked
		FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=?`, tokenHash(token)).
		Scan(&sid, &kind, &expires, &lastSeen, &u.ID, &u.Username, &u.DisplayName, &u.IsAdmin, &u.Disabled, &u.WriteBlocked)
	now := v.Now()
	if err != nil || expires <= now || u.Disabled {
		return nil, nil, ErrUnauthorized
	}
	if now-lastSeen >= 60 {
		v.DB.Exec(`UPDATE sessions SET last_seen=?, expires_at=? WHERE id=?`, now, now+v.sessionTTL(kind), sid)
	}
	return u, &Session{ID: sid, Kind: kind}, nil
}

// basicCache avoids running bcrypt on every WebDAV request that uses Basic auth.
var basicCache sync.Map // key: username+"\x00"+sha256(password) -> expiry unix

// AuthenticateBasic accepts either the user's password or one of their session tokens.
func (v *Vault) AuthenticateBasic(username, password string) (*User, error) {
	if u, _, err := v.Authenticate(password); err == nil && strings.EqualFold(u.Username, username) {
		return u, nil
	}
	key := strings.ToLower(username) + "\x00" + tokenHash(password)
	now := v.Now()
	var u *User
	var hash string
	var lockedUntil int64
	u = &User{}
	err := v.DB.QueryRow(`SELECT `+userCols+`, password_hash, locked_until FROM users WHERE username=?`, username).
		Scan(&u.ID, &u.Username, &u.DisplayName, &u.IsAdmin, &u.Disabled, &u.WriteBlocked, &hash, &lockedUntil)
	if err != nil || u.Disabled || lockedUntil > now {
		return nil, ErrUnauthorized
	}
	if exp, ok := basicCache.Load(key + hash); ok && exp.(int64) > now {
		return u, nil
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) != nil {
		return nil, ErrUnauthorized
	}
	basicCache.Store(key+hash, now+300)
	return u, nil
}

func (v *Vault) Logout(a Actor, token string) {
	v.DB.Exec(`DELETE FROM sessions WHERE token_hash=?`, tokenHash(token))
	v.Audit(a, "logout", "", "", "")
}

// Heartbeat records what an agent has mounted, for the admin's PC list.
func (v *Vault) Heartbeat(s *Session, ip, agentVer, mounted string) {
	v.DB.Exec(`UPDATE sessions SET last_seen=?, ip=?, agent_ver=?, mounted=? WHERE id=?`, v.Now(), ip, agentVer, mounted, s.ID)
}

type SessionInfo struct {
	ID        int64  `json:"id"`
	User      string `json:"user"`
	Kind      string `json:"kind"`
	Device    string `json:"device"`
	IP        string `json:"ip"`
	AgentVer  string `json:"agentVer"`
	Mounted   string `json:"mounted"`
	CreatedAt int64  `json:"createdAt"`
	LastSeen  int64  `json:"lastSeen"`
}

func (v *Vault) ListSessions() ([]SessionInfo, error) {
	rows, err := v.DB.Query(`SELECT s.id, u.username, u.display_name, s.kind, s.device, s.ip, s.agent_ver, s.mounted, s.created_at, s.last_seen
		FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.expires_at > ? ORDER BY s.last_seen DESC`, v.Now())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SessionInfo
	for rows.Next() {
		var s SessionInfo
		var uname, dname string
		rows.Scan(&s.ID, &uname, &dname, &s.Kind, &s.Device, &s.IP, &s.AgentVer, &s.Mounted, &s.CreatedAt, &s.LastSeen)
		s.User = (&User{Username: uname, DisplayName: dname}).Label()
		out = append(out, s)
	}
	return out, nil
}

func (v *Vault) RevokeSession(a Actor, id int64) error {
	res, err := v.DB.Exec(`DELETE FROM sessions WHERE id=?`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	v.Audit(a, "admin_session_revoke", "", "", "")
	return nil
}
