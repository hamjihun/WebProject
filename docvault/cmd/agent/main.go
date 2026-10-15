// docvault-agent runs on each employee PC. After login it connects every
// drive the user may access as a drive letter (via rclone + WinFsp), keeps
// the set in sync with the permissions on the server, and reports to the
// server once a minute so admins can see which PCs are connected.
//
//	docvault-agent login    connect this PC to an account through the browser
//	docvault-agent login --password   sign in on the console instead
//	docvault-agent          connect drives and keep them in sync (run at Windows logon)
//	docvault-agent logout   sign out; drives disconnect
//	docvault-agent status   show the signed-in user and drives
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/term"
)

const version = "0.1.0"

type Config struct {
	Server   string `json:"server"`    // e.g. http://docvault.ilsan.local:8080
	Rclone   string `json:"rclone"`    // path to rclone.exe (default: next to the agent)
	CacheDir string `json:"cache_dir"` // write cache for files being saved (default: state dir)
}

type Drive struct {
	ID          int64  `json:"id"`
	Name        string `json:"name"`
	DriveLetter string `json:"driveLetter"`
	Personal    bool   `json:"personal"`
	QuotaBytes  int64  `json:"quotaBytes"`
	Level       int    `json:"level"`
	Used        int64  `json:"used"`
}

var errUnauthorized = errors.New("로그인이 만료되었거나 해제되었습니다")

func exeDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(exe)
}

func configPath() string { return filepath.Join(exeDir(), "agent.json") }

func loadConfig() (*Config, error) {
	cfg := &Config{}
	b, err := os.ReadFile(configPath())
	if err == nil {
		if err := json.Unmarshal(b, cfg); err != nil {
			return nil, fmt.Errorf("agent.json: %w", err)
		}
	}
	if cfg.Rclone == "" {
		cfg.Rclone = filepath.Join(exeDir(), rcloneExe)
	}
	if cfg.CacheDir == "" {
		cfg.CacheDir = filepath.Join(stateDir(), "cache")
	}
	cfg.Server = strings.TrimRight(cfg.Server, "/")
	return cfg, nil
}

func saveConfig(cfg *Config) error {
	b, _ := json.MarshalIndent(cfg, "", "  ")
	return os.WriteFile(configPath(), b, 0o644)
}

// ---- token storage (DPAPI-protected on Windows) ----

func tokenPath() string { return filepath.Join(stateDir(), "session.dat") }

func saveToken(tok string) error {
	if err := os.MkdirAll(stateDir(), 0o700); err != nil {
		return err
	}
	enc, err := protect([]byte(tok))
	if err != nil {
		return err
	}
	return os.WriteFile(tokenPath(), enc, 0o600)
}

func loadToken() string {
	b, err := os.ReadFile(tokenPath())
	if err != nil {
		return ""
	}
	dec, err := unprotect(b)
	if err != nil {
		return ""
	}
	return string(dec)
}

// ---- server API ----

type client struct {
	server string
	token  string
	http   *http.Client
}

func (c *client) call(method, path string, in, out any) error {
	var body io.Reader
	if in != nil {
		b, _ := json.Marshal(in)
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.server+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized && c.token != "" {
		return errUnauthorized
	}
	if resp.StatusCode != http.StatusOK {
		var e struct{ Error string }
		json.NewDecoder(resp.Body).Decode(&e)
		if e.Error == "" {
			e.Error = resp.Status
		}
		return errors.New(e.Error)
	}
	if out != nil {
		return json.NewDecoder(resp.Body).Decode(out)
	}
	return nil
}

func newClient(cfg *Config, token string) *client {
	return &client{server: cfg.Server, token: token, http: &http.Client{Timeout: 30 * time.Second}}
}

// ---- commands ----

func prompt(r *bufio.Reader, label string) string {
	fmt.Print(label)
	s, _ := r.ReadString('\n')
	return strings.TrimSpace(s)
}

func ensureServer(cfg *Config) error {
	if cfg.Server != "" {
		return nil
	}
	s := prompt(bufio.NewReader(os.Stdin), "문서중앙화 서버 주소 (예: http://192.168.50.10:8080): ")
	if s == "" {
		return errors.New("서버 주소가 필요합니다")
	}
	if !strings.HasPrefix(s, "http://") && !strings.HasPrefix(s, "https://") {
		s = "http://" + s
	}
	cfg.Server = strings.TrimRight(s, "/")
	return saveConfig(cfg)
}

// cmdLogin connects this PC to the user's account through the browser: the
// user signs in on the web page that opens and clicks "이 PC 연결".
func cmdLogin(cfg *Config) error {
	if err := ensureServer(cfg); err != nil {
		return err
	}
	host, _ := os.Hostname()
	c := newClient(cfg, "")
	var start struct{ Code, Secret, URL string }
	if err := c.call("POST", "/api/agent/pair", map[string]string{"device": host}, &start); err != nil {
		return fmt.Errorf("서버에 연결할 수 없습니다 (%s): %w", cfg.Server, err)
	}
	link := cfg.Server + start.URL
	fmt.Println()
	fmt.Println("  ┌──────────────────────────────────────────────┐")
	fmt.Println("  │  브라우저에서 로그인한 뒤 [이 PC 연결]을 누르세요  │")
	fmt.Println("  └──────────────────────────────────────────────┘")
	fmt.Println("  브라우저가 열리지 않으면 아래 주소로 접속하세요:")
	fmt.Println("  " + link)
	fmt.Println()
	openBrowser(link)
	deadline := time.Now().Add(10 * time.Minute)
	for time.Now().Before(deadline) {
		time.Sleep(2 * time.Second)
		b, _ := json.Marshal(map[string]string{"code": start.Code, "secret": start.Secret})
		resp, err := c.http.Post(cfg.Server+"/api/agent/pair/claim", "application/json", bytes.NewReader(b))
		if err != nil {
			continue
		}
		var out struct{ Token string }
		json.NewDecoder(resp.Body).Decode(&out)
		resp.Body.Close()
		switch {
		case resp.StatusCode == http.StatusOK && out.Token != "":
			if err := saveToken(out.Token); err != nil {
				return err
			}
			fmt.Println("연결되었습니다. 잠시 후 내 PC에 드라이브가 나타납니다.")
			return nil
		case resp.StatusCode == http.StatusNotFound:
			return errors.New("연결 요청이 만료되었습니다. 다시 실행하세요")
		}
	}
	return errors.New("시간이 초과되었습니다. 다시 실행하세요")
}

// cmdPasswordLogin is the console fallback: docvault-agent login --password
func cmdPasswordLogin(cfg *Config) error {
	if err := ensureServer(cfg); err != nil {
		return err
	}
	in := bufio.NewReader(os.Stdin)
	for attempt := 0; attempt < 3; attempt++ {
		user := prompt(in, "아이디: ")
		fmt.Print("비밀번호: ")
		pw, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Println()
		if err != nil {
			pw = []byte(prompt(in, ""))
		}
		host, _ := os.Hostname()
		var out struct{ Token string }
		err = newClient(cfg, "").call("POST", "/api/login",
			map[string]string{"username": user, "password": string(pw), "kind": "agent", "device": host}, &out)
		if err != nil {
			fmt.Println("로그인 실패:", err)
			continue
		}
		if err := saveToken(out.Token); err != nil {
			return err
		}
		fmt.Println("로그인했습니다.")
		return nil
	}
	return errors.New("로그인하지 못했습니다")
}

func cmdLogout(cfg *Config) error {
	if tok := loadToken(); tok != "" && cfg.Server != "" {
		newClient(cfg, tok).call("POST", "/api/logout", map[string]string{}, nil)
	}
	os.Remove(tokenPath())
	os.RemoveAll(cfg.CacheDir)
	fmt.Println("로그아웃했습니다. 실행 중인 에이전트는 1분 안에 드라이브 연결을 해제합니다.")
	return nil
}

func cmdStatus(cfg *Config) error {
	tok := loadToken()
	if tok == "" || cfg.Server == "" {
		return errors.New("로그인되어 있지 않습니다 (docvault-agent login)")
	}
	c := newClient(cfg, tok)
	var me struct{ Username, DisplayName string }
	if err := c.call("GET", "/api/me", nil, &me); err != nil {
		return err
	}
	var drives []Drive
	if err := c.call("GET", "/api/me/drives", nil, &drives); err != nil {
		return err
	}
	fmt.Printf("서버: %s\n사용자: %s (%s)\n", cfg.Server, me.DisplayName, me.Username)
	for _, d := range drives {
		fmt.Printf("  %s: %s  [%s]\n", d.DriveLetter, d.Name, levelName(d.Level))
	}
	return nil
}

func levelName(l int) string {
	switch l {
	case 1:
		return "읽기"
	case 2:
		return "읽기/쓰기"
	default:
		return "관리"
	}
}

// ---- mounting ----

type mount struct {
	drive Drive
	cmd   *exec.Cmd
	done  chan struct{}
}

type agent struct {
	cfg    *Config
	client *client
	mu     sync.Mutex
	mounts map[string]*mount // by drive letter
}

func (a *agent) start(d Drive) error {
	letter := strings.ToUpper(d.DriveLetter)
	remote := "DV" + letter
	target := mountTarget(letter)
	if err := prepareTarget(target); err != nil {
		return err
	}
	cache := filepath.Join(a.cfg.CacheDir, letter)
	os.RemoveAll(cache) // never leave old document copies behind
	logDir := filepath.Join(stateDir(), "logs")
	os.MkdirAll(logDir, 0o700)
	args := []string{"mount", remote + ":", target,
		"--volname", d.Name,
		"--vfs-cache-mode", "writes", // needed so Office can save; files are uploaded right after
		"--vfs-write-back", "2s",
		"--vfs-cache-max-age", "1h",
		"--cache-dir", cache,
		"--dir-cache-time", "30s",
		"--poll-interval", "0",
		"--log-file", filepath.Join(logDir, "drive-"+letter+".log"),
		"--log-level", "NOTICE",
	}
	args = append(args, platformMountArgs(d)...)
	if d.Level < 2 {
		args = append(args, "--read-only")
	}
	cmd := exec.Command(a.cfg.Rclone, args...)
	cmd.Env = append(os.Environ(),
		"RCLONE_CONFIG="+os.DevNull,
		"RCLONE_CONFIG_"+remote+"_TYPE=webdav",
		"RCLONE_CONFIG_"+remote+"_URL="+a.cfg.Server+"/dav/"+url.PathEscape(d.Name),
		"RCLONE_CONFIG_"+remote+"_VENDOR=other",
		"RCLONE_CONFIG_"+remote+"_BEARER_TOKEN="+a.client.token,
	)
	hideWindow(cmd)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("rclone 실행 실패 (%s): %w", a.cfg.Rclone, err)
	}
	m := &mount{drive: d, cmd: cmd, done: make(chan struct{})}
	go func() { cmd.Wait(); close(m.done) }()
	a.mounts[letter] = m
	log.Printf("연결: %s: %s", letter, d.Name)
	return nil
}

func (a *agent) stop(letter string) {
	m := a.mounts[letter]
	if m == nil {
		return
	}
	stopProcess(m.cmd)
	select {
	case <-m.done:
	case <-time.After(10 * time.Second):
		m.cmd.Process.Kill()
		<-m.done
	}
	cleanupTarget(mountTarget(letter))
	os.RemoveAll(filepath.Join(a.cfg.CacheDir, letter))
	delete(a.mounts, letter)
	log.Printf("해제: %s: %s", letter, m.drive.Name)
}

func (a *agent) stopAll() {
	a.mu.Lock()
	defer a.mu.Unlock()
	for l := range a.mounts {
		a.stop(l)
	}
}

// sync makes the mounted drives match what the server says the user may use.
func (a *agent) sync(drives []Drive) {
	a.mu.Lock()
	defer a.mu.Unlock()
	want := map[string]Drive{}
	for _, d := range drives {
		if l := strings.ToUpper(d.DriveLetter); l != "" {
			want[l] = d
		}
	}
	for l, m := range a.mounts {
		d, ok := want[l]
		exited := false
		select {
		case <-m.done:
			exited = true
		default:
		}
		if !ok || exited || d.Name != m.drive.Name || d.Level != m.drive.Level {
			a.stop(l)
		}
	}
	for l, d := range want {
		if _, ok := a.mounts[l]; !ok {
			if err := a.start(d); err != nil {
				log.Printf("%s: 연결 실패: %v", l, err)
			}
		}
	}
}

func (a *agent) mounted() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	var s []string
	for l, m := range a.mounts {
		s = append(s, l+":"+m.drive.Name)
	}
	sort.Strings(s)
	return strings.Join(s, ", ")
}

func cmdRun(cfg *Config) error {
	if cfg.Server == "" || loadToken() == "" {
		fmt.Println("DocVault 문서 드라이브 – 이 PC를 계정에 연결합니다.")
		if err := cmdLogin(cfg); err != nil {
			fmt.Println("오류:", err)
			fmt.Println("엔터를 누르면 닫힙니다.")
			bufio.NewReader(os.Stdin).ReadString('\n')
			return err
		}
	}
	if _, err := os.Stat(cfg.Rclone); err != nil {
		return fmt.Errorf("rclone을 찾을 수 없습니다: %s (agent.json의 rclone 경로 확인)", cfg.Rclone)
	}
	logDir := filepath.Join(stateDir(), "logs")
	os.MkdirAll(logDir, 0o700)
	if f, err := os.OpenFile(filepath.Join(logDir, "agent.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600); err == nil {
		defer f.Close()
		log.SetOutput(io.MultiWriter(os.Stderr, f))
	}
	// Runs at Windows logon: keep working in the background without a window.
	hideConsole()
	a := &agent{cfg: cfg, client: newClient(cfg, loadToken()), mounts: map[string]*mount{}}
	os.RemoveAll(cfg.CacheDir)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	defer a.stopAll()
	log.Printf("DocVault 에이전트 %s 시작 (서버 %s)", version, cfg.Server)
	for {
		var drives []Drive
		err := a.client.call("POST", "/api/agent/heartbeat", map[string]string{"version": version, "mounted": a.mounted()}, &drives)
		switch {
		case errors.Is(err, errUnauthorized):
			log.Printf("%v → 드라이브 연결 해제", err)
			a.stopAll()
			os.Remove(tokenPath())
			return err
		case err != nil:
			// Server unreachable: keep current drives; rclone retries on its own.
			log.Printf("서버 연결 실패: %v", err)
		default:
			a.sync(drives)
			// sync stops crashed mounts; start them again right away
			a.sync(drives)
		}
		select {
		case <-sig:
			log.Printf("종료합니다")
			return nil
		case <-time.After(time.Minute):
		}
	}
}

func main() {
	log.SetFlags(log.LstdFlags)
	cfg, err := loadConfig()
	if err == nil {
		cmd := "run"
		if len(os.Args) > 1 {
			cmd = os.Args[1]
		}
		switch cmd {
		case "run":
			err = cmdRun(cfg)
		case "login":
			if len(os.Args) > 2 && os.Args[2] == "--password" {
				err = cmdPasswordLogin(cfg)
			} else {
				err = cmdLogin(cfg)
			}
		case "logout":
			err = cmdLogout(cfg)
		case "status":
			err = cmdStatus(cfg)
		case "version":
			fmt.Println(version)
		default:
			err = fmt.Errorf("알 수 없는 명령: %s (login | run | logout | status)", cmd)
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "오류:", err)
		os.Exit(1)
	}
}
