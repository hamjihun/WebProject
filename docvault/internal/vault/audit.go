package vault

import (
	"strings"
)

// Audit records an event. share/path may be empty for non-file events.
func (v *Vault) Audit(a Actor, action, share, p, detail string) {
	v.auditTx(v.DB, a, action, share, p, detail)
}

func (v *Vault) auditTx(q querier, a Actor, action, share, p, detail string) {
	var uid int64
	var uname string
	if a.User != nil {
		uid, uname = a.User.ID, a.User.Label()
	}
	q.Exec(`INSERT INTO audit(ts, user_id, username, ip, client, action, share_name, path, detail) VALUES(?,?,?,?,?,?,?,?,?)`,
		v.Now(), uid, uname, a.IP, a.Client, action, share, p, detail)
}

// auditRead logs a file read, but at most once a minute per user and file:
// a drive reads one opened file with many partial requests.
func (v *Vault) auditRead(a Actor, share, p string, nodeID int64) {
	key := itoa(a.User.ID) + ":" + itoa(nodeID)
	now := v.Now()
	v.readMu.Lock()
	last := v.lastRead[key]
	if now-last < 60 {
		v.readMu.Unlock()
		return
	}
	v.lastRead[key] = now
	if len(v.lastRead) > 100000 {
		for k, t := range v.lastRead {
			if now-t >= 60 {
				delete(v.lastRead, k)
			}
		}
	}
	v.readMu.Unlock()
	v.Audit(a, "read", share, p, "")
}

type AuditEntry struct {
	ID     int64  `json:"id"`
	TS     int64  `json:"ts"`
	User   string `json:"user"`
	IP     string `json:"ip"`
	Client string `json:"client"`
	Action string `json:"action"`
	Share  string `json:"share"`
	Path   string `json:"path"`
	Detail string `json:"detail"`
}

type AuditQuery struct {
	From, To int64
	User     string
	Action   string
	Share    string
	Text     string
	Limit    int
	Offset   int
}

func (v *Vault) QueryAudit(q AuditQuery) ([]AuditEntry, int, error) {
	where := []string{"1=1"}
	var args []any
	if q.From > 0 {
		where, args = append(where, "ts>=?"), append(args, q.From)
	}
	if q.To > 0 {
		where, args = append(where, "ts<?"), append(args, q.To)
	}
	if q.User != "" {
		where, args = append(where, "username LIKE ?"), append(args, "%"+q.User+"%")
	}
	if q.Action != "" {
		where, args = append(where, "action=?"), append(args, q.Action)
	}
	if q.Share != "" {
		where, args = append(where, "share_name=?"), append(args, q.Share)
	}
	if q.Text != "" {
		where, args = append(where, "(path LIKE ? OR detail LIKE ?)"), append(args, "%"+q.Text+"%", "%"+q.Text+"%")
	}
	w := strings.Join(where, " AND ")
	var total int
	v.DB.QueryRow(`SELECT COUNT(*) FROM audit WHERE `+w, args...).Scan(&total)
	if q.Limit <= 0 || q.Limit > 5000 {
		q.Limit = 100
	}
	rows, err := v.DB.Query(`SELECT id, ts, username, ip, client, action, share_name, path, detail FROM audit WHERE `+w+
		` ORDER BY id DESC LIMIT ? OFFSET ?`, append(args, q.Limit, q.Offset)...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := []AuditEntry{}
	for rows.Next() {
		var e AuditEntry
		rows.Scan(&e.ID, &e.TS, &e.User, &e.IP, &e.Client, &e.Action, &e.Share, &e.Path, &e.Detail)
		out = append(out, e)
	}
	return out, total, nil
}

// guard scores a user's changes to existing files: 2 points per overwrite or
// rename, 1 per deletion (deleting a folder through Explorer deletes every file
// in it, which is normal). Reaching 2×guard_threshold points within the window
// is how ransomware on a PC looks, so the account's write access is blocked
// until an admin releases it. Every save is a new version and deletions go to
// the trash, so the damage done before the block can be undone.
func (v *Vault) guard(a Actor, share string, points int) {
	threshold := v.Setting("guard_threshold")
	window := v.Setting("guard_window_sec")
	if threshold <= 0 || window <= 0 || a.User == nil {
		return
	}
	now := v.Now()
	v.guardMu.Lock()
	ev := v.guardEv[a.User.ID]
	i := 0
	for i < len(ev) && ev[i] < now-window {
		i++
	}
	ev = ev[i:]
	for p := 0; p < points; p++ {
		ev = append(ev, now)
	}
	v.guardEv[a.User.ID] = ev
	trip := int64(len(ev)) >= 2*threshold
	if trip {
		delete(v.guardEv, a.User.ID)
	}
	v.guardMu.Unlock()
	if !trip {
		return
	}
	v.DB.Exec(`UPDATE users SET write_blocked=1 WHERE id=?`, a.User.ID)
	a.User.WriteBlocked = true
	v.Audit(a, "guard_block", share, "",
		"랜섬웨어 의심: "+itoa(window/60)+"분 안에 기존 파일 수정 "+itoa(threshold)+"건(삭제는 2건을 1건으로 계산) 이상 → 쓰기 차단. 관리자 해제 필요")
}
