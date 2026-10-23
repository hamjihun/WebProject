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
	"docvault/internal/buildinfo"
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
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/term"
)

const version = buildinfo.Version

// exportFolder is the folder of the personal drive that holds approved
// exports (vault.ExportFolder).
const exportFolder = "반출"

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

// passwordLogin signs this PC in with an ID and password and saves the session.
// reachable reports whether the DocVault server answers (so login is only
// possible on the company network).
func reachable(server string) bool {
	if server == "" {
		return false
	}
	c := &http.Client{Timeout: 5 * time.Second}
	resp, err := c.Get(server + "/api/setup-available")
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode < 500
}

var errServerUnreachable = errors.New("사내 망(DocVault 서버)에 연결되어 있지 않습니다.\n회사 네트워크(사내망/VPN)에 연결한 뒤 다시 시도하세요.")

func passwordLogin(cfg *Config, user, pw string) error {
	if !reachable(cfg.Server) {
		return errServerUnreachable
	}
	host, _ := os.Hostname()
	var out struct{ Token string }
	err := newClient(cfg, "").call("POST", "/api/login",
		map[string]string{"username": strings.TrimSpace(user), "password": pw, "kind": "agent", "device": host}, &out)
	if err != nil {
		return err
	}
	return saveToken(out.Token)
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
		if err := passwordLogin(cfg, user, string(pw)); err != nil {
			fmt.Println("로그인 실패:", err)
			continue
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
	// Disconnect the drives now instead of waiting for the next heartbeat.
	stopOtherAgents()
	clearDriveIcons()
	os.RemoveAll(cfg.CacheDir)
	fmt.Println("로그아웃했습니다. 문서 드라이브 연결을 해제했습니다.")
	fmt.Println("다시 사용하려면 시작 메뉴의 'DocVault 문서 드라이브'를 실행하세요.")
	time.Sleep(3 * time.Second)
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

	copyWatch     atomic.Bool                  // remove copies of drive files made on this PC
	blockDownload atomic.Bool                  // refuse browser downloads saved on this PC
	up            *uploadState                 // 웹 첨부관리: policy + exportable hashes for the browser extension
	srvPol        atomic.Pointer[serverPolicy] // last program-block policy from the server
	user          string                       // signed-in account, keys the drive caches (under mu)
	personalDrive string                       // name of the personal drive (개인문서함), under mu
	offline       atomic.Bool                  // server down: drives stay disconnected (see health)
}

func (a *agent) personalDriveName() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.personalDrive
}

// setUser records the signed-in account (see cacheDir).
func (a *agent) setUser(name string) {
	a.mu.Lock()
	a.user = name
	a.mu.Unlock()
}

// cacheDir is where a drive keeps what it read and what it has still to
// upload. It is kept when the drive is disconnected (server down, restart,
// update, Windows shutdown): the drive program uploads leftover changes when
// it connects again. Keyed by account and drive so changes always go back
// where they came from. Called with a.mu held.
func (a *agent) cacheDir(d Drive) string {
	user := a.user
	if user == "" {
		user = "_"
	}
	return filepath.Join(a.cfg.CacheDir, safeName(user), fmt.Sprintf("s%d", d.ID))
}

func safeName(s string) string {
	return strings.Map(func(r rune) rune {
		if strings.ContainsRune(`\/:*?"<>|`, r) || r < 32 {
			return '_'
		}
		return r
	}, s)
}

func (a *agent) start(d Drive) error {
	letter := strings.ToUpper(d.DriveLetter)
	remote := "DV" + letter
	target := mountTarget(letter)
	if err := prepareTarget(target); err != nil {
		return err
	}
	cache := a.cacheDir(d)
	os.Remove(eventsPath(letter))
	logDir := filepath.Join(stateDir(), "logs")
	os.MkdirAll(logDir, 0o700)
	args := []string{"mount", remote + ":", target,
		"--volname", d.Name,
		// full: what is read is kept in the local cache too, so programs that
		// jump around a file or read it several times (Explorer menus, icons
		// and signature checks of .exe, antivirus, archivers) don't download it
		// again for every read. Writes are uploaded 2 s after closing.
		"--vfs-cache-mode", "full",
		"--vfs-write-back", "2s",
		"--vfs-cache-max-age", "1h",
		"--vfs-cache-max-size", "20G",
		"--cache-dir", cache,
		"--dir-cache-time", "8s", // new files (반출 폴더 등)·권한 변경이 8초 안에 반영되도록
		"--poll-interval", "0",
		// Give up quickly when the server does not answer: every program
		// touching the drive (Explorer, i.e. also the taskbar) waits for it.
		// The agent disconnects the drives when the server is down.
		"--contimeout", "5s",
		"--timeout", "20s",
		"--low-level-retries", "2",
		"--retries", "1",
		"--log-file", filepath.Join(logDir, "drive-"+letter+".log"),
		"--log-level", "NOTICE",
	}
	args = append(args, platformMountArgs(d)...)
	if d.Level < 2 {
		args = append(args, "--read-only")
	}
	cmd := exec.Command(a.cfg.Rclone, args...)
	cmd.Env = os.Environ()
	if d.Personal {
		cmd.Env = append(cmd.Env, "DOCVAULT_ALLOW=/"+exportFolder) // approved exports may leave
	}
	cmd.Env = append(cmd.Env,
		"RCLONE_CONFIG="+os.DevNull,
		"RCLONE_CONFIG_"+remote+"_TYPE=webdav",
		"RCLONE_CONFIG_"+remote+"_URL="+a.cfg.Server+"/dav/"+url.PathEscape(d.Name),
		"RCLONE_CONFIG_"+remote+"_VENDOR=other",
		"RCLONE_CONFIG_"+remote+"_BEARER_TOKEN="+a.client.token,
		"DOCVAULT_POLICY="+policyPath(),
		"DOCVAULT_EVENTS="+eventsPath(letter),
	)
	hideWindow(cmd)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("rclone 실행 실패 (%s): %w", a.cfg.Rclone, err)
	}
	setDriveIcon(letter, true)
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
	setDriveIcon(letter, false)
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
		if d.Personal {
			a.personalDrive = d.Name
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

func openLog() func() {
	logDir := filepath.Join(stateDir(), "logs")
	os.MkdirAll(logDir, 0o700)
	f, err := os.OpenFile(filepath.Join(logDir, "agent.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return func() {}
	}
	log.SetOutput(io.MultiWriter(os.Stderr, f))
	return func() { f.Close() }
}

func newAgent(cfg *Config) *agent {
	clearDriveIcons()
	a := &agent{cfg: cfg, client: newClient(cfg, loadToken()), mounts: map[string]*mount{}, up: newUploadState()}
	go a.watchEvents()
	go a.copyWatchLoop()
	go a.serveUploadOracle()
	go a.deadmanLoop()
	watchLocalFolders(a)
	return a
}

// heartbeat reports to the server and makes the mounted drives match the
// drives the user may access now. It returns errUnauthorized when the
// session has ended.
func (a *agent) heartbeat() ([]Drive, error) {
	var drives []Drive
	err := a.client.call("POST", "/api/agent/heartbeat", map[string]string{"version": version, "mounted": a.mounted()}, &drives)
	if err != nil {
		return nil, err
	}
	a.updatePolicy()
	a.mu.Lock()
	known := a.user != ""
	a.mu.Unlock()
	if !known { // the caches are kept per account
		var me struct{ Username string }
		if err := a.client.call("GET", "/api/me", nil, &me); err != nil {
			return drives, nil
		}
		a.setUser(me.Username)
	}
	if a.offline.Load() {
		return drives, nil
	}
	a.sync(drives)
	a.sync(drives) // sync stops crashed mounts; start them again right away
	return drives, nil
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
	defer openLog()()
	a := newAgent(cfg)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	defer a.stopAll()
	log.Printf("DocVault 에이전트 %s 시작 (서버 %s)", version, cfg.Server)
	refresh := make(chan struct{}, 1)
	kick := func() {
		select {
		case refresh <- struct{}{}:
		default:
		}
	}
	go a.health(make(chan struct{}), func() { log.Printf("서버 응답 없음 → 드라이브 연결 해제") },
		func() { log.Printf("서버 복구 → 드라이브 다시 연결"); kick() },
		func(l string) { log.Printf("%s: 응답 없음 → 다시 연결", l); kick() })
	for {
		_, err := a.heartbeat()
		switch {
		case errors.Is(err, errUnauthorized):
			// The session ended on the server (expired, revoked by an admin,
			// server reset): disconnect, then ask to connect this PC again.
			log.Printf("%v → 드라이브 연결 해제 후 다시 연결 요청", err)
			a.stopAll()
			os.Remove(tokenPath())
			if err := cmdLogin(cfg); err != nil {
				return err
			}
			a.client = newClient(cfg, loadToken())
			continue
		case err != nil:
			log.Printf("서버 연결 실패: %v", err)
		}
		select {
		case <-sig:
			log.Printf("종료합니다")
			return nil
		case <-refresh:
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
			err = runApp(cfg)
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
		case "export": // 탐색기 오른쪽 클릭 → DocVault 반출 신청
			if len(os.Args) < 3 {
				err = errors.New("반출 신청할 파일을 지정하세요")
			} else {
				err = cmdExport(cfg, os.Args[2])
			}
		case "versions": // 탐색기 오른쪽 클릭 → DocVault 이전 버전
			if len(os.Args) < 3 {
				err = errors.New("이전 버전을 볼 파일을 지정하세요")
			} else {
				err = cmdVersions(cfg, os.Args[2])
			}
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
