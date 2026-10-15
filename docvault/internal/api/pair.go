package api

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"docvault/internal/netutil"
	"docvault/internal/vault"
)

// PC pairing: instead of typing a password into a console, the agent shows a
// code and opens the browser; the user signs in on the web page and clicks
// "이 PC 연결". The agent then collects its session with a secret only it knows.

const pairTTL = 10 * time.Minute

type pairing struct {
	secret  string
	device  string
	ip      string
	created time.Time
	token   string
}

type pairStore struct {
	mu sync.Mutex
	m  map[string]*pairing
}

var pairs = &pairStore{m: map[string]*pairing{}}

func (p *pairStore) get(code string) *pairing {
	p.mu.Lock()
	defer p.mu.Unlock()
	for k, v := range p.m {
		if time.Since(v.created) > pairTTL {
			delete(p.m, k)
		}
	}
	return p.m[strings.ToUpper(code)]
}

const codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // no 0/O, 1/I

func newCode() string {
	b := make([]byte, 8)
	rand.Read(b)
	for i := range b {
		b[i] = codeAlphabet[int(b[i])%len(codeAlphabet)]
	}
	return string(b)
}

func randHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func (s *API) registerPairing(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/agent/pair", s.pairStart)
	mux.HandleFunc("POST /api/agent/pair/claim", s.pairClaim)
	mux.HandleFunc("GET /api/agent/pair/{code}", s.auth(s.pairInfo))
	mux.HandleFunc("POST /api/agent/pair/{code}/approve", s.auth(s.pairApprove))
	mux.HandleFunc("GET /download/setup", s.downloadSetup)
	mux.HandleFunc("GET /api/setup-available", s.setupAvailable)
}

func (s *API) pairStart(w http.ResponseWriter, r *http.Request) {
	var in struct{ Device string }
	readJSON(r, &in)
	dev := strings.TrimSpace(in.Device)
	if len(dev) > 64 {
		dev = dev[:64]
	}
	pairs.mu.Lock()
	if len(pairs.m) > 1000 {
		pairs.mu.Unlock()
		fail(w, vault.ErrForbidden)
		return
	}
	code := newCode()
	p := &pairing{secret: randHex(24), device: dev, ip: netutil.ClientIP(r, s.TrustProxy), created: time.Now()}
	pairs.m[code] = p
	pairs.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]string{"code": code, "secret": p.secret, "url": "/#/pair/" + code})
}

func (s *API) pairInfo(w http.ResponseWriter, r *http.Request, c *ctx) {
	p := pairs.get(r.PathValue("code"))
	if p == nil || p.token != "" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "연결 요청이 없거나 만료되었습니다. PC에서 다시 시도하세요"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"device": p.device, "ip": p.ip})
}

func (s *API) pairApprove(w http.ResponseWriter, r *http.Request, c *ctx) {
	p := pairs.get(r.PathValue("code"))
	if p == nil || p.token != "" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "연결 요청이 없거나 만료되었습니다. PC에서 다시 시도하세요"})
		return
	}
	token, err := s.V.PairAgent(c.a, p.device, p.ip)
	if err != nil {
		fail(w, err)
		return
	}
	pairs.mu.Lock()
	p.token = token
	pairs.mu.Unlock()
	ok(w)
}

func (s *API) pairClaim(w http.ResponseWriter, r *http.Request) {
	var in struct{ Code, Secret string }
	if err := readJSON(r, &in); err != nil {
		fail(w, err)
		return
	}
	code := strings.ToUpper(in.Code)
	p := pairs.get(code)
	if p == nil || !vaultSecretEqual(p.secret, in.Secret) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "expired"})
		return
	}
	pairs.mu.Lock()
	token := p.token
	if token != "" {
		delete(pairs.m, code)
	}
	pairs.mu.Unlock()
	if token == "" {
		writeJSON(w, http.StatusAccepted, map[string]bool{"pending": true})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"token": token})
}

func vaultSecretEqual(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	var d byte
	for i := 0; i < len(a); i++ {
		d |= a[i] ^ b[i]
	}
	return d == 0
}

// ---- installer download ----

func (s *API) setupPath() string { return filepath.Join(s.DownloadDir, "docvault-setup.exe") }

func (s *API) setupAvailable(w http.ResponseWriter, r *http.Request) {
	_, err := os.Stat(s.setupPath())
	writeJSON(w, http.StatusOK, map[string]bool{"available": err == nil})
}

// SetupTrailerMagic marks the server settings appended to docvault-setup.exe
// when it is downloaded, so the installer knows which server to use.
const SetupTrailerMagic = "DVCFG1\x00\x00"

func (s *API) publicURL(r *http.Request) string {
	if s.PublicURL != "" {
		return strings.TrimRight(s.PublicURL, "/")
	}
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	return scheme + "://" + r.Host
}

func (s *API) downloadSetup(w http.ResponseWriter, r *http.Request) {
	f, err := os.Open(s.setupPath())
	if err != nil {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusNotFound)
		io.WriteString(w, "설치 파일이 아직 서버에 없습니다. 관리자에게 문의하세요.\n(관리자: 서버 폴더의 downloads\\docvault-setup.exe 에 넣으세요)")
		return
	}
	defer f.Close()
	st, _ := f.Stat()
	cfg, _ := json.Marshal(map[string]string{"server": s.publicURL(r)})
	var n [4]byte
	binary.LittleEndian.PutUint32(n[:], uint32(len(cfg)))
	trailer := append(append(cfg, n[:]...), SetupTrailerMagic...)
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", `attachment; filename="docvault-setup.exe"`)
	w.Header().Set("Content-Length", itoa64(st.Size()+int64(len(trailer))))
	w.Header().Set("Cache-Control", "no-store")
	io.Copy(w, f)
	w.Write(trailer)
}
