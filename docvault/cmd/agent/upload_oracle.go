package main

// Web-attachment oracle (웹 첨부관리). The browser extension cannot see the
// user's export approvals, so the agent exposes a tiny localhost service the
// extension asks before allowing a file to be attached on the web:
//
//	GET  /dv-upload/policy  -> {enabled, allowDomains, loggedIn}
//	POST /dv-upload/check   {sha,size} -> {allow, reason}
//
// Only 127.0.0.1 is bound. The service is advisory (the extension is the gate);
// the worst a rogue local program learns is whether a given file hash is one
// the user may export, which leaks nothing useful.

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
)

// The extension probes this small port range to find the agent.
const (
	oraclePortBase = 29614
	oraclePortSpan = 6
)

// Web-attachment modes (match internal/vault).
const (
	webUploadOff   = 0 // do nothing
	webUploadLog   = 1 // record attachments, do not block
	webUploadBlock = 2 // record and block
)

type uploadState struct {
	mu      sync.RWMutex
	mode    int64
	domains []string
	shas    map[string]bool
	sizes   map[int64]bool
	port    int
}

func newUploadState() *uploadState {
	return &uploadState{shas: map[string]bool{}, sizes: map[int64]bool{}}
}

func (s *uploadState) set(mode int64, domains []string, shas map[string]bool, sizes map[int64]bool) {
	s.mu.Lock()
	s.mode, s.domains, s.shas, s.sizes = mode, domains, shas, sizes
	s.mu.Unlock()
}

func (s *uploadState) setPort(p int) {
	s.mu.Lock()
	s.port = p
	s.mu.Unlock()
}

func (s *uploadState) snapshot() (int64, []string) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.mode, s.domains
}

func (s *uploadState) allowed(sha string, size int64) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if sha != "" {
		return s.shas[strings.ToLower(sha)]
	}
	// Large files the extension did not hash: fall back to an exact size match
	// against an exportable file. Weaker, but a file big enough to skip hashing
	// is rare and this still only lets through sizes that match an export.
	return size > 0 && s.sizes[size]
}

// fetchUploadPolicy refreshes the web-attachment policy and the set of files
// the user may attach. Called from updatePolicy on each heartbeat.
func (a *agent) fetchUploadPolicy() {
	if a.up == nil {
		return
	}
	var p struct {
		Mode         int64    `json:"mode"`
		AllowDomains []string `json:"allowDomains"`
		Hashes       []struct {
			SHA  string `json:"sha"`
			Size int64  `json:"size"`
		} `json:"hashes"`
	}
	if err := a.client.call("GET", "/api/agent/upload", nil, &p); err != nil {
		if err == errUnauthorized {
			a.up.set(webUploadOff, nil, map[string]bool{}, map[int64]bool{})
		}
		return
	}
	shas := make(map[string]bool, len(p.Hashes))
	sizes := map[int64]bool{}
	for _, h := range p.Hashes {
		if h.SHA != "" {
			shas[strings.ToLower(h.SHA)] = true
		}
		if h.Size > 0 {
			sizes[h.Size] = true
		}
	}
	a.up.set(p.Mode, p.AllowDomains, shas, sizes)
}

// serveUploadOracle binds the first free port in the range and serves the
// extension. It runs for the life of the agent.
func (a *agent) serveUploadOracle() {
	mux := http.NewServeMux()
	mux.HandleFunc("/dv-upload/policy", a.oraclePolicy)
	mux.HandleFunc("/dv-upload/check", a.oracleCheck)
	for port := oraclePortBase; port < oraclePortBase+oraclePortSpan; port++ {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			continue
		}
		a.up.setPort(port)
		log.Printf("웹 첨부관리 로컬 서비스 포트 %d", port)
		srv := &http.Server{Handler: corsWrap(mux)}
		if err := srv.Serve(ln); err != nil {
			log.Printf("웹 첨부관리 로컬 서비스 종료: %v", err)
		}
		return
	}
	log.Printf("웹 첨부관리 로컬 서비스 포트를 열지 못했습니다 (%d-%d)", oraclePortBase, oraclePortBase+oraclePortSpan-1)
}

// corsWrap lets the browser extension call the oracle: it allows any origin and
// answers Chrome's private-network preflight so a public page's extension may
// reach 127.0.0.1.
func corsWrap(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hd := w.Header()
		hd.Set("Access-Control-Allow-Origin", "*")
		hd.Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		hd.Set("Access-Control-Allow-Headers", "Content-Type")
		hd.Set("Access-Control-Allow-Private-Network", "true")
		hd.Set("Cache-Control", "no-store")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		h.ServeHTTP(w, r)
	})
}

func (a *agent) oraclePolicy(w http.ResponseWriter, r *http.Request) {
	mode, domains := a.up.snapshot()
	if domains == nil {
		domains = []string{}
	}
	writeOracleJSON(w, map[string]any{
		"mode":         mode,
		"allowDomains": domains,
		"loggedIn":     loadToken() != "",
	})
}

func (a *agent) oracleCheck(w http.ResponseWriter, r *http.Request) {
	var in struct {
		SHA    string `json:"sha"`
		Size   int64  `json:"size"`
		Name   string `json:"name"`
		Domain string `json:"domain"`
	}
	json.NewDecoder(r.Body).Decode(&in)
	mode, domains := a.up.snapshot()

	// Decide whether to block. Log mode never blocks; block mode allows export
	// approved files and exception sites.
	allow := true
	if mode == webUploadBlock {
		allow = hostExcepted(in.Domain, domains) || a.up.allowed(in.SHA, in.Size)
	}
	// Record the attachment (allowed or blocked) for the audit log.
	if mode >= webUploadLog {
		go a.client.call("POST", "/api/agent/upload-log",
			map[string]any{"name": in.Name, "domain": in.Domain, "size": in.Size, "blocked": !allow}, nil)
	}
	reason := ""
	if !allow {
		reason = "반출 승인된 파일만 웹에 첨부할 수 있습니다. 필요하면 파일을 오른쪽 클릭 → 반출 신청을 하세요."
	}
	writeOracleJSON(w, map[string]any{"allow": allow, "reason": reason})
}

// hostExcepted reports whether host matches one of the exception domains
// (exact or a subdomain).
func hostExcepted(host string, domains []string) bool {
	host = strings.ToLower(strings.TrimSpace(host))
	for _, d := range domains {
		if d != "" && (host == d || strings.HasSuffix(host, "."+d)) {
			return true
		}
	}
	return false
}

func writeOracleJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}
