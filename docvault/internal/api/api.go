// Package api is the JSON API used by the web UI and the PC agent.
package api

import (
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"

	"docvault/internal/backup"
	"docvault/internal/buildinfo"
	"docvault/internal/netutil"
	"docvault/internal/vault"
	"docvault/internal/web"
)

const cookieName = "dv_session"

type API struct {
	V            *vault.Vault
	TrustProxy   bool
	SecureCookie bool
	DownloadDir  string                                   // holds docvault-setup.exe for employees to download
	PublicURL    string                                   // address PCs use to reach the server (default: from the request)
	BackupDir    string                                   // configured offline backup location (empty = off)
	RunBackup    func(dir string) (*backup.Result, error) // run a backup now to dir (set by the server)
}

type ctx struct {
	a     vault.Actor
	token string
	sess  *vault.Session
}

func (s *API) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("POST /api/login", s.login)
	mux.HandleFunc("POST /api/logout", s.auth(s.logout))
	mux.HandleFunc("GET /api/me", s.auth(s.me))
	mux.HandleFunc("GET /api/me/drives", s.auth(s.drives))

	mux.HandleFunc("GET /api/files", s.auth(s.listFiles))
	mux.HandleFunc("POST /api/files/upload", s.auth(s.upload))
	mux.HandleFunc("POST /api/files/mkdir", s.auth(s.mkdir))
	mux.HandleFunc("POST /api/files/delete", s.auth(s.deleteFile))
	mux.HandleFunc("POST /api/files/rename", s.auth(s.rename))
	mux.HandleFunc("GET /api/files/versions", s.auth(s.versions))
	mux.HandleFunc("POST /api/files/versions/restore", s.auth(s.restoreVersion))

	mux.HandleFunc("GET /api/trash", s.auth(s.trash))
	mux.HandleFunc("POST /api/trash/restore", s.auth(s.restoreTrash))
	mux.HandleFunc("POST /api/trash/purge", s.auth(s.purgeTrash))

	mux.HandleFunc("POST /api/exports", s.auth(s.requestExport))
	mux.HandleFunc("GET /api/exports", s.auth(s.listExports))
	mux.HandleFunc("POST /api/exports/{id}/decide", s.auth(s.decideExport))
	mux.HandleFunc("POST /api/exports/{id}/cancel", s.auth(s.cancelExport))
	mux.HandleFunc("GET /api/exports/{id}/download", s.auth(s.downloadExport))

	mux.HandleFunc("POST /api/agent/heartbeat", s.auth(s.heartbeat))
	mux.HandleFunc("GET /api/agent/policy", s.auth(s.agentPolicy))
	mux.HandleFunc("POST /api/agent/event", s.auth(s.agentEvent))
	mux.HandleFunc("POST /api/agent/copy-check", s.auth(s.agentCopyCheck))
	mux.HandleFunc("GET /api/agent/upload", s.auth(s.agentUpload))
	mux.HandleFunc("GET /ext/update.xml", s.extUpdateXML)
	mux.HandleFunc("GET /ext/docvault.crx", s.extCRX)
	s.registerPairing(mux)

	mux.HandleFunc("GET /api/admin/users", s.admin(s.listUsers))
	mux.HandleFunc("POST /api/admin/users", s.admin(s.createUser))
	mux.HandleFunc("POST /api/admin/users/{id}", s.admin(s.updateUser))
	mux.HandleFunc("GET /api/admin/groups", s.admin(s.listGroups))
	mux.HandleFunc("POST /api/admin/groups", s.admin(s.createGroup))
	mux.HandleFunc("POST /api/admin/groups/{id}/delete", s.admin(s.deleteGroup))
	mux.HandleFunc("GET /api/admin/shares", s.admin(s.listShares))
	mux.HandleFunc("POST /api/admin/shares", s.admin(s.createShare))
	mux.HandleFunc("POST /api/admin/shares/{id}", s.admin(s.updateShare))
	mux.HandleFunc("POST /api/admin/shares/{id}/delete", s.admin(s.deleteShare))
	mux.HandleFunc("GET /api/admin/shares/{id}/acl", s.admin(s.getACL))
	mux.HandleFunc("POST /api/admin/shares/{id}/acl", s.admin(s.setACL))
	mux.HandleFunc("GET /api/admin/audit", s.admin(s.audit))
	mux.HandleFunc("GET /api/admin/audit.csv", s.admin(s.auditCSV))
	mux.HandleFunc("GET /api/admin/sessions", s.admin(s.sessions))
	mux.HandleFunc("POST /api/admin/sessions/{id}/revoke", s.admin(s.revokeSession))
	mux.HandleFunc("GET /api/admin/settings", s.admin(s.getSettings))
	mux.HandleFunc("POST /api/admin/settings", s.admin(s.setSettings))
	mux.HandleFunc("POST /api/admin/maintain", s.admin(s.maintain))
	mux.HandleFunc("GET /api/admin/store-check", s.admin(s.storeCheck))
	mux.HandleFunc("GET /api/admin/overview", s.admin(s.overview))
	mux.HandleFunc("GET /api/admin/storage", s.admin(s.storage))
	mux.HandleFunc("GET /api/admin/backup", s.admin(s.backupStatus))
	mux.HandleFunc("POST /api/admin/backup", s.admin(s.runBackup))
}

// ---- plumbing ----

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, err error) {
	status, msg := http.StatusInternalServerError, "서버 오류가 발생했습니다"
	switch {
	case errors.Is(err, vault.ErrNotFound):
		status, msg = http.StatusNotFound, "찾을 수 없습니다"
	case errors.Is(err, vault.ErrForbidden):
		status, msg = http.StatusForbidden, "권한이 없습니다"
	case errors.Is(err, vault.ErrUnauthorized):
		status, msg = http.StatusUnauthorized, "로그인이 필요합니다"
	case errors.Is(err, vault.ErrLocked):
		status, msg = http.StatusTooManyRequests, "비밀번호를 여러 번 틀려 10분간 잠겼습니다"
	case errors.Is(err, vault.ErrExists):
		status, msg = http.StatusConflict, "같은 이름이 이미 있습니다"
	case errors.Is(err, vault.ErrConflict):
		status, msg = http.StatusConflict, "상위 폴더가 없거나 이동할 수 없는 위치입니다"
	case errors.Is(err, vault.ErrQuota):
		status, msg = http.StatusInsufficientStorage, "드라이브 용량이 부족합니다"
	case errors.Is(err, vault.ErrNoContent):
		status, msg = http.StatusGone, "저장소(NAS)에 이 파일의 내용이 없습니다. 관리자에게 문의하세요 (관리자 → 설정 → 저장소 점검)"
	case errors.Is(err, vault.ErrInvalidName):
		status, msg = http.StatusBadRequest, `이름에 사용할 수 없는 문자가 있습니다 (\ / : * ? " < > |)`
	case errors.Is(err, vault.ErrIsDir), errors.Is(err, vault.ErrNotDir), errors.Is(err, vault.ErrBadRequest):
		status, msg = http.StatusBadRequest, "잘못된 요청입니다"
	default:
		// Errors the vault creates for users are written in Korean; anything
		// else is internal and only logged.
		if err != nil && hasHangul(err.Error()) {
			status, msg = http.StatusBadRequest, err.Error()
		} else {
			log.Printf("api error: %v", err)
		}
	}
	writeJSON(w, status, map[string]string{"error": msg})
}

func hasHangul(s string) bool {
	for _, r := range s {
		if r >= 0xAC00 && r <= 0xD7A3 {
			return true
		}
	}
	return false
}

func readJSON(r *http.Request, v any) error {
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(v); err != nil {
		return vault.ErrBadRequest
	}
	return nil
}

// auth resolves the caller from the session cookie (web) or a bearer token
// (agent). Cookie-authenticated writes must carry X-DocVault, which browsers
// do not let other sites send, as CSRF protection.
func (s *API) auth(fn func(http.ResponseWriter, *http.Request, *ctx)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token, viaCookie := netutil.BearerToken(r), false
		if token == "" {
			if c, err := r.Cookie(cookieName); err == nil {
				token, viaCookie = c.Value, true
			}
		}
		u, sess, err := s.V.Authenticate(token)
		if err != nil {
			fail(w, vault.ErrUnauthorized)
			return
		}
		if viaCookie && r.Method != http.MethodGet && r.Header.Get("X-DocVault") != "1" {
			fail(w, vault.ErrForbidden)
			return
		}
		client := "web"
		if sess.Kind == "agent" {
			client = "agent"
		}
		fn(w, r, &ctx{a: vault.Actor{User: u, IP: netutil.ClientIP(r, s.TrustProxy), Client: client}, token: token, sess: sess})
	}
}

func (s *API) admin(fn func(http.ResponseWriter, *http.Request, *ctx)) http.HandlerFunc {
	return s.auth(func(w http.ResponseWriter, r *http.Request, c *ctx) {
		if !c.a.User.IsAdmin {
			fail(w, vault.ErrForbidden)
			return
		}
		fn(w, r, c)
	})
}

func pathID(r *http.Request) int64 {
	n, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	return n
}

func itoa64(n int64) string { return strconv.FormatInt(n, 10) }

func ok(w http.ResponseWriter) { writeJSON(w, http.StatusOK, map[string]bool{"ok": true}) }

// ---- session ----

func (s *API) login(w http.ResponseWriter, r *http.Request) {
	var in struct{ Username, Password, Kind, Device string }
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	token, u, err := s.V.Login(in.Username, in.Password, in.Kind, in.Device, netutil.ClientIP(r, s.TrustProxy))
	if err != nil {
		if errors.Is(err, vault.ErrUnauthorized) {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "아이디 또는 비밀번호가 올바르지 않습니다"})
			return
		}
		fail(w, err)
		return
	}
	if in.Kind == "agent" {
		writeJSON(w, http.StatusOK, map[string]any{"token": token, "user": u})
		return
	}
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: token, Path: "/", HttpOnly: true,
		Secure: s.SecureCookie, SameSite: http.SameSiteStrictMode})
	writeJSON(w, http.StatusOK, map[string]any{"user": u})
}

func (s *API) logout(w http.ResponseWriter, r *http.Request, c *ctx) {
	s.V.Logout(c.a, c.token)
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/", MaxAge: -1, HttpOnly: true})
	ok(w)
}

func (s *API) me(w http.ResponseWriter, r *http.Request, c *ctx) {
	writeJSON(w, http.StatusOK, c.a.User)
}

func (s *API) drives(w http.ResponseWriter, r *http.Request, c *ctx) {
	d, err := s.V.DrivesFor(c.a.User)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, d)
}

func (s *API) heartbeat(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in struct{ Version, Mounted string }
	readJSON(r, &in)
	s.V.Heartbeat(c.sess, c.a.IP, in.Version, in.Mounted)
	s.drives(w, r, c)
}

// ---- files ----

type fileReq struct {
	Share   string `json:"share"`
	Path    string `json:"path"`
	NewName string `json:"newName"`
	ID      int64  `json:"id"`
	Reason  string `json:"reason"`
	Post    bool   `json:"post"` // 후결재
}

func (s *API) listFiles(w http.ResponseWriter, r *http.Request, c *ctx) {
	q := r.URL.Query()
	list, err := s.V.List(c.a, q.Get("share"), q.Get("path"))
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, list)
}

// upload streams one or more multipart files into the folder ?share=&path=.
func (s *API) upload(w http.ResponseWriter, r *http.Request, c *ctx) {
	q := r.URL.Query()
	mr, err := r.MultipartReader()
	if err != nil {
		fail(w, vault.ErrBadRequest)
		return
	}
	var saved []string
	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			fail(w, vault.ErrBadRequest)
			return
		}
		name := path.Base(strings.ReplaceAll(part.FileName(), `\`, "/"))
		if part.FormName() != "file" || name == "" || name == "." || name == "/" {
			part.Close()
			continue
		}
		_, _, err = s.V.Put(c.a, q.Get("share"), path.Join("/", q.Get("path"), name), part)
		part.Close()
		if err != nil {
			fail(w, err)
			return
		}
		saved = append(saved, name)
	}
	writeJSON(w, http.StatusOK, map[string]any{"saved": saved})
}

func (s *API) mkdir(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in fileReq
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	if err := s.V.Mkdir(c.a, in.Share, in.Path); err != nil {
		fail(w, err)
		return
	}
	ok(w)
}

func (s *API) deleteFile(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in fileReq
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	if err := s.V.Delete(c.a, in.Share, in.Path); err != nil {
		fail(w, err)
		return
	}
	ok(w)
}

func (s *API) rename(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in fileReq
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	dst := path.Join(path.Dir(path.Join("/", in.Path)), in.NewName)
	if strings.Contains(in.NewName, "/") {
		fail(w, vault.ErrInvalidName)
		return
	}
	if _, err := s.V.Move(c.a, in.Share, in.Path, in.Share, dst, false); err != nil {
		fail(w, err)
		return
	}
	ok(w)
}

func (s *API) versions(w http.ResponseWriter, r *http.Request, c *ctx) {
	q := r.URL.Query()
	list, err := s.V.Versions(c.a, q.Get("share"), q.Get("path"))
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, list)
}

func (s *API) restoreVersion(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in fileReq
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	if err := s.V.RestoreVersion(c.a, in.Share, in.Path, in.ID); err != nil {
		fail(w, err)
		return
	}
	ok(w)
}

// ---- trash ----

func (s *API) trash(w http.ResponseWriter, r *http.Request, c *ctx) {
	list, err := s.V.Trash(c.a, r.URL.Query().Get("share"))
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, list)
}

func (s *API) restoreTrash(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in fileReq
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	p, err := s.V.RestoreTrash(c.a, in.Share, in.ID)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"path": p})
}

func (s *API) purgeTrash(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in fileReq
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	if err := s.V.PurgeTrash(c.a, in.Share, in.ID); err != nil {
		fail(w, err)
		return
	}
	ok(w)
}

// ---- exports (반출) ----

func (s *API) requestExport(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in fileReq
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	e, err := s.V.RequestExport(c.a, in.Share, in.Path, in.Reason, in.Post)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, e)
}

func (s *API) listExports(w http.ResponseWriter, r *http.Request, c *ctx) {
	list, err := s.V.ListExports(c.a.User, r.URL.Query().Get("scope"))
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, list)
}

func (s *API) decideExport(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in struct {
		Approve bool   `json:"approve"`
		Note    string `json:"note"`
	}
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	if err := s.V.DecideExport(c.a, pathID(r), in.Approve, in.Note); err != nil {
		fail(w, err)
		return
	}
	ok(w)
}

func (s *API) cancelExport(w http.ResponseWriter, r *http.Request, c *ctx) {
	if err := s.V.CancelExport(c.a, pathID(r)); err != nil {
		fail(w, err)
		return
	}
	ok(w)
}

func (s *API) downloadExport(w http.ResponseWriter, r *http.Request, c *ctx) {
	e, f, err := s.V.OpenExport(c.a, pathID(r))
	if err != nil {
		fail(w, err)
		return
	}
	defer f.Close()
	ct := mime.TypeByExtension(path.Ext(e.FileName))
	if ct == "" {
		ct = "application/octet-stream"
	}
	w.Header().Set("Content-Type", ct)
	w.Header().Set("Content-Disposition", "attachment; filename*=UTF-8''"+url.PathEscape(e.FileName))
	w.Header().Set("Content-Length", strconv.FormatInt(e.Size, 10))
	w.Header().Set("Cache-Control", "no-store")
	io.Copy(w, f)
}

// ---- admin ----

func (s *API) listUsers(w http.ResponseWriter, r *http.Request, c *ctx) {
	list, err := s.V.ListUsers()
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, list)
}

func (s *API) createUser(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in struct {
		Username, DisplayName, Password string
		IsAdmin                         bool
		GroupIDs                        []int64
	}
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	u, err := s.V.CreateUser(c.a, in.Username, in.DisplayName, in.Password, in.IsAdmin)
	if err != nil {
		fail(w, err)
		return
	}
	if len(in.GroupIDs) > 0 {
		s.V.UpdateUser(c.a, u.ID, vault.UserUpdate{GroupIDs: in.GroupIDs})
	}
	writeJSON(w, http.StatusOK, u)
}

func (s *API) updateUser(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in vault.UserUpdate
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	if err := s.V.UpdateUser(c.a, pathID(r), in); err != nil {
		fail(w, err)
		return
	}
	ok(w)
}

func (s *API) listGroups(w http.ResponseWriter, r *http.Request, c *ctx) {
	list, err := s.V.ListGroups()
	if err != nil {
		fail(w, err)
		return
	}
	if list == nil {
		list = []vault.Group{}
	}
	writeJSON(w, http.StatusOK, list)
}

func (s *API) createGroup(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in struct{ Name string }
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	id, err := s.V.CreateGroup(c.a, in.Name)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int64{"id": id})
}

func (s *API) deleteGroup(w http.ResponseWriter, r *http.Request, c *ctx) {
	if err := s.V.DeleteGroup(c.a, pathID(r)); err != nil {
		fail(w, err)
		return
	}
	ok(w)
}

func (s *API) listShares(w http.ResponseWriter, r *http.Request, c *ctx) {
	list, err := s.V.ListShares()
	if err != nil {
		fail(w, err)
		return
	}
	type row struct {
		*vault.Share
		Used int64 `json:"used"`
	}
	out := []row{}
	for _, sh := range list {
		var used int64
		if !sh.Personal {
			used = s.V.Usage(sh, 0)
		}
		out = append(out, row{sh, used})
	}
	writeJSON(w, http.StatusOK, out)
}

type shareIn struct {
	Name        string `json:"name"`
	DriveLetter string `json:"driveLetter"`
	Personal    bool   `json:"personal"`
	QuotaGB     int64  `json:"quotaGB"`
}

func (s *API) createShare(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in shareIn
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	sh, err := s.V.CreateShare(c.a, in.Name, in.DriveLetter, in.Personal, in.QuotaGB<<30)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sh)
}

func (s *API) updateShare(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in shareIn
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	if err := s.V.UpdateShare(c.a, pathID(r), in.DriveLetter, in.QuotaGB<<30); err != nil {
		fail(w, err)
		return
	}
	ok(w)
}

func (s *API) deleteShare(w http.ResponseWriter, r *http.Request, c *ctx) {
	if err := s.V.DeleteShare(c.a, pathID(r)); err != nil {
		fail(w, err)
		return
	}
	ok(w)
}

func (s *API) getACL(w http.ResponseWriter, r *http.Request, c *ctx) {
	list, err := s.V.ShareACL(pathID(r))
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, list)
}

func (s *API) setACL(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in []vault.ACLEntry
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	if err := s.V.SetShareACL(c.a, pathID(r), in); err != nil {
		fail(w, err)
		return
	}
	ok(w)
}

func auditQuery(r *http.Request) vault.AuditQuery {
	q := r.URL.Query()
	day := func(s string, add int) int64 {
		t, err := time.ParseInLocation("2006-01-02", s, time.Local)
		if err != nil {
			return 0
		}
		return t.AddDate(0, 0, add).Unix()
	}
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	return vault.AuditQuery{From: day(q.Get("from"), 0), To: day(q.Get("to"), 1), User: q.Get("user"),
		Action: q.Get("action"), Share: q.Get("share"), Text: q.Get("q"), Limit: limit, Offset: offset}
}

func (s *API) audit(w http.ResponseWriter, r *http.Request, c *ctx) {
	list, total, err := s.V.QueryAudit(auditQuery(r))
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": list, "total": total})
}

func (s *API) auditCSV(w http.ResponseWriter, r *http.Request, c *ctx) {
	q := auditQuery(r)
	q.Limit = 5000
	list, _, err := s.V.QueryAudit(q)
	if err != nil {
		fail(w, err)
		return
	}
	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition", "attachment; filename*=UTF-8''"+url.PathEscape("감사로그_"+time.Now().Format("20060102")+".csv"))
	io.WriteString(w, "\xef\xbb\xbf") // BOM so Excel opens Korean text correctly
	cw := csv.NewWriter(w)
	cw.Write([]string{"시간", "사용자", "IP", "경로(접속)", "작업", "드라이브", "파일", "상세"})
	for _, e := range list {
		cw.Write([]string{time.Unix(e.TS, 0).Format("2006-01-02 15:04:05"), e.User, e.IP, e.Client,
			ActionLabel(e.Action), e.Share, e.Path, e.Detail})
	}
	cw.Flush()
	s.V.Audit(c.a, "admin_audit_export", "", "", strconv.Itoa(len(list))+"건")
}

func (s *API) sessions(w http.ResponseWriter, r *http.Request, c *ctx) {
	list, err := s.V.ListSessions()
	if err != nil {
		fail(w, err)
		return
	}
	if list == nil {
		list = []vault.SessionInfo{}
	}
	writeJSON(w, http.StatusOK, list)
}

func (s *API) revokeSession(w http.ResponseWriter, r *http.Request, c *ctx) {
	if err := s.V.RevokeSession(c.a, pathID(r)); err != nil {
		fail(w, err)
		return
	}
	ok(w)
}

func (s *API) getSettings(w http.ResponseWriter, r *http.Request, c *ctx) {
	out := map[string]any{}
	for k, v := range s.V.Settings() {
		out[k] = v
	}
	out["block_extra_processes"] = s.V.StringSetting("block_extra_processes")
	out["web_upload_allow_domains"] = s.V.StringSetting("web_upload_allow_domains")
	writeJSON(w, http.StatusOK, out)
}

func (s *API) setSettings(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in map[string]json.RawMessage
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	cur := s.V.Settings()
	for k, raw := range in {
		if k == "block_extra_processes" || k == "web_upload_allow_domains" {
			var v string
			if json.Unmarshal(raw, &v) != nil {
				fail(w, vault.ErrBadRequest)
				return
			}
			if v != s.V.StringSetting(k) {
				if err := s.V.SetStringSetting(c.a, k, v); err != nil {
					fail(w, err)
					return
				}
			}
			continue
		}
		var v int64
		if json.Unmarshal(raw, &v) != nil {
			fail(w, vault.ErrBadRequest)
			return
		}
		if cur[k] == v {
			continue
		}
		if err := s.V.SetSetting(c.a, k, v); err != nil {
			fail(w, err)
			return
		}
	}
	ok(w)
}

// agentPolicy tells the PC agent which programs may not read drive files.
func (s *API) agentPolicy(w http.ResponseWriter, r *http.Request, c *ctx) {
	writeJSON(w, http.StatusOK, map[string]any{"block": s.V.Policy(c.a.User), "copyWatch": s.V.CopyWatch(c.a.User),
		"blockDownload": s.V.BlockDownload(c.a.User), "watch": s.V.CopyWatchProcs(c.a.User), "docWatch": s.V.DocPrograms(c.a.User), "archiveWatch": s.V.ArchivePrograms(c.a.User)})
}

// agentUpload gives the PC agent the web-attachment policy (웹 첨부관리):
// whether it is on, the exception sites, and the fingerprints of files the
// user may attach (반출 승인받은 파일). The agent caches these and answers the
// browser extension over localhost. DLP-exempt users (admin, free권한) get it
// turned off.
func (s *API) agentUpload(w http.ResponseWriter, r *http.Request, c *ctx) {
	u := c.a.User
	enabled := s.V.WebUploadEnabled() && !u.IsAdmin && !u.DLPFree
	resp := map[string]any{
		"enabled":      enabled,
		"allowDomains": s.V.WebUploadAllowDomains(),
		"hashes":       []vault.HashSize{},
	}
	if enabled {
		resp["hashes"] = s.V.UploadAllowedHashes(u)
	}
	writeJSON(w, http.StatusOK, resp)
}

// extUpdateXML is the Chrome/Edge/Whale force-install update manifest. The
// browser's ExtensionInstallForcelist policy points at this URL; it tells the
// browser where to download the signed .crx and which version it is.
func (s *API) extUpdateXML(w http.ResponseWriter, r *http.Request) {
	base := s.publicURL(r)
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	fmt.Fprintf(w, `<?xml version="1.0" encoding="UTF-8"?>
<gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">
  <app appid="%s">
    <updatecheck codebase="%s/ext/docvault.crx" version="%s" />
  </app>
</gupdate>
`, buildinfo.ExtensionID, base, buildinfo.Version)
}

// extCRX serves the signed extension package with the Chrome CRX MIME type so
// Chrome/Edge/Whale accept it for policy-based force-install.
func (s *API) extCRX(w http.ResponseWriter, r *http.Request) {
	b := web.ExtensionCRX()
	if len(b) == 0 {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/x-chrome-extension")
	w.Header().Set("Cache-Control", "no-cache")
	w.Write(b)
}

// agentCopyCheck answers whether a new file on the PC is a copy of a drive
// file (see Vault.CopyCheck); when it is, the agent deletes it and the
// attempt is logged here.
func (s *API) agentCopyCheck(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in struct {
		SHA256 string `json:"sha256"`
		Size   int64  `json:"size"`
		Local  string `json:"local"`
	}
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	if in.SHA256 == "" { // size-only pre-check
		writeJSON(w, http.StatusOK, map[string]any{"maybe": s.V.CopySizeKnown(c.a.User, in.Size)})
		return
	}
	drive, p, found := s.V.CopyCheck(c.a.User, in.SHA256, in.Size)
	if found {
		s.V.Audit(c.a, "block_copy", drive, p, "PC로 복사된 파일 삭제: "+in.Local)
	}
	writeJSON(w, http.StatusOK, map[string]any{"block": found, "drive": drive, "path": p})
}

// agentEvent records a refusal the PC agent applied.
func (s *API) agentEvent(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in struct{ Kind, Proc, Drive, Path string }
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	s.V.RecordBlocked(c.a, in.Kind, in.Proc, in.Drive, in.Path)
	ok(w)
}

// storeCheck lists files whose content is missing from the store.
func (s *API) storeCheck(w http.ResponseWriter, r *http.Request, c *ctx) {
	missing, checked, err := s.V.CheckStore()
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"checked": checked, "missing": missing})
}

// healthz is an unauthenticated liveness/readiness check for monitoring:
// 200 when the database and the file store (NAS) both respond, 503 otherwise.
func (s *API) healthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if err := s.V.DB.Ping(); err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		io.WriteString(w, "db: "+err.Error())
		return
	}
	if err := s.V.Blobs.Healthy(); err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		io.WriteString(w, "store: 저장소(NAS)에 접근할 수 없습니다")
		return
	}
	io.WriteString(w, "ok")
}

func (s *API) overview(w http.ResponseWriter, r *http.Request, c *ctx) {
	storeOK := s.V.Blobs.Healthy() == nil
	out := map[string]any{"stats": s.V.Overview(), "setupVersion": s.setupVersion(), "storeOK": storeOK}
	if s.BackupDir != "" {
		out["backup"] = backup.LoadLast(s.BackupDir)
		out["backupConfigured"] = true
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *API) storage(w http.ResponseWriter, r *http.Request, c *ctx) {
	drives, cur, trash := s.V.StorageByShare()
	storeFreeGB := 0.0
	if f, err := s.V.Blobs.FreeGB(); err == nil {
		storeFreeGB = f
	}
	writeJSON(w, http.StatusOK, map[string]any{"drives": drives, "currentBytes": cur, "trashBytes": trash, "storeFreeGB": storeFreeGB})
}

func (s *API) backupStatus(w http.ResponseWriter, r *http.Request, c *ctx) {
	out := map[string]any{"configured": s.BackupDir != "", "dir": s.BackupDir}
	if s.BackupDir != "" {
		out["last"] = backup.LoadLast(s.BackupDir)
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *API) runBackup(w http.ResponseWriter, r *http.Request, c *ctx) {
	var in struct{ Dir string }
	readJSON(r, &in)
	dir := strings.TrimSpace(in.Dir)
	if dir == "" {
		dir = s.BackupDir
	}
	if s.RunBackup == nil || dir == "" {
		fail(w, errors.New("백업 위치를 입력하세요 (예: E:\\)"))
		return
	}
	res, err := s.RunBackup(dir)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *API) maintain(w http.ResponseWriter, r *http.Request, c *ctx) {
	res, err := s.V.Maintain()
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// ActionLabel is the Korean name of an audit action.
func ActionLabel(a string) string {
	if l, ok := actionLabels[a]; ok {
		return l
	}
	return a
}

var actionLabels = map[string]string{
	"login": "로그인", "login_fail": "로그인 실패", "logout": "로그아웃",
	"read": "열람", "create": "새 파일", "update": "수정 저장", "mkdir": "폴더 생성", "delete": "삭제(휴지통)",
	"move": "이동/이름변경", "copy": "복사", "restore_trash": "휴지통 복원", "purge": "영구 삭제",
	"restore_version": "이전 버전 복원", "export_request": "반출 신청", "export_approve": "반출 승인",
	"export_reject": "반출 반려", "export_post": "후결재 반출", "export_approve_post": "후결재 승인", "export_reject_post": "후결재 반려(반출 폴더에서 회수)", "export_cancel": "반출 신청 취소", "export_download": "반출 다운로드",
	"guard_block": "랜섬웨어 의심 차단", "maintenance": "자동 정리",
	"admin_user_create": "[관리] 사용자 생성", "admin_user_update": "[관리] 사용자 변경",
	"admin_group_create": "[관리] 그룹 생성", "admin_group_delete": "[관리] 그룹 삭제",
	"admin_share_create": "[관리] 드라이브 생성", "admin_share_update": "[관리] 드라이브 변경",
	"admin_share_delete": "[관리] 드라이브 삭제", "admin_share_acl": "[관리] 권한 변경",
	"admin_setting": "[관리] 설정 변경", "admin_session_revoke": "[관리] 접속 강제 종료",
	"admin_audit_export": "[관리] 로그 내보내기", "agent_pair": "PC 연결",
	"block_copy": "PC 복사 차단", "block_messenger": "메신저 첨부 차단", "block_upload": "웹 업로드 차단", "block_custom": "프로그램 차단", "block_download": "PC 저장 차단", "export_deliver_fail": "반출 폴더 넣기 실패",
}
