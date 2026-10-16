// docvault-server is the document-centralization server. The same program runs
// on a Windows 10 test PC, Windows Server 2019 (as a Windows service) or Linux.
//
//	docvault-server                 run in the foreground
//	docvault-server install         register as a Windows service (auto start)
//	docvault-server uninstall       remove the Windows service
//	docvault-server reset-password <user> <new password>
//	docvault-server maintain        apply retention rules now
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"docvault/internal/api"
	"docvault/internal/blob"
	"docvault/internal/dav"
	"docvault/internal/db"
	"docvault/internal/vault"
	"docvault/internal/web"
)

type Config struct {
	Listen     string `json:"listen"`    // e.g. ":8080" or ":443"
	DataDir    string `json:"data_dir"`  // database and logs (server's own disk)
	StoreDir   string `json:"store_dir"` // file contents (NAS iSCSI disk / mount)
	TLSCert    string `json:"tls_cert"`  // PEM certificate; empty = plain HTTP (test only)
	TLSKey     string `json:"tls_key"`
	TrustProxy bool   `json:"trust_proxy"` // behind a reverse proxy that sets X-Forwarded-For
	PublicURL  string `json:"public_url"`  // address PCs use, e.g. http://192.168.50.10:8080 (optional)
}

func exeDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(exe)
}

// loadConfig reads docvault.json next to the program, creating it with
// defaults on first run.
func loadConfig() (*Config, string, error) {
	path := os.Getenv("DOCVAULT_CONFIG")
	if path == "" {
		path = filepath.Join(exeDir(), "docvault.json")
	}
	cfg := &Config{
		Listen:   ":8080",
		DataDir:  filepath.Join(exeDir(), "data"),
		StoreDir: filepath.Join(exeDir(), "store"),
	}
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		out, _ := json.MarshalIndent(cfg, "", "  ")
		if err := os.WriteFile(path, out, 0o600); err != nil {
			return nil, path, err
		}
		return cfg, path, nil
	}
	if err != nil {
		return nil, path, err
	}
	if err := json.Unmarshal(b, cfg); err != nil {
		return nil, path, fmt.Errorf("%s: %w", path, err)
	}
	return cfg, path, nil
}

type server struct {
	cfg   *Config
	vault *vault.Vault
	http  *http.Server
}

func open(cfg *Config) (*vault.Vault, error) {
	if err := os.MkdirAll(cfg.DataDir, 0o750); err != nil {
		return nil, err
	}
	d, err := db.Open(filepath.Join(cfg.DataDir, "docvault.db"))
	if err != nil {
		return nil, err
	}
	bs, err := blob.New(cfg.StoreDir)
	if err != nil {
		return nil, fmt.Errorf("저장소 폴더(store_dir)를 열 수 없습니다: %w", err)
	}
	return vault.New(d, bs), nil
}

// bootstrap creates the first admin account and a personal drive on first run.
func bootstrap(cfg *Config, v *vault.Vault) error {
	if v.UserCount() > 0 {
		return nil
	}
	b := make([]byte, 12)
	rand.Read(b)
	pw := base64.RawURLEncoding.EncodeToString(b)
	sys := vault.Actor{Client: "system"}
	if _, err := v.CreateUser(sys, "admin", "관리자", pw, true); err != nil {
		return err
	}
	if _, err := v.CreateShare(sys, "개인문서함", "F", true, 0); err != nil {
		return err
	}
	file := filepath.Join(cfg.DataDir, "초기관리자비밀번호.txt")
	msg := "DocVault 초기 관리자 계정\r\n아이디: admin\r\n비밀번호: " + pw + "\r\n\r\n로그인 후 [관리자 > 사용자]에서 비밀번호를 바꾸고 이 파일을 삭제하세요.\r\n"
	os.WriteFile(file, []byte(msg), 0o600)
	log.Printf("초기 관리자 계정을 만들었습니다: admin / %s (%s 에도 저장)", pw, file)
	return nil
}

func newServer() (*server, error) {
	cfg, path, err := loadConfig()
	if err != nil {
		return nil, err
	}
	log.Printf("설정 파일: %s", path)
	v, err := open(cfg)
	if err != nil {
		return nil, err
	}
	if err := bootstrap(cfg, v); err != nil {
		return nil, err
	}
	mux := http.NewServeMux()
	dh := &dav.Handler{V: v, Prefix: "/dav", TrustProxy: cfg.TrustProxy}
	mux.Handle("/dav/", dh)
	mux.Handle("/dav", dh)
	downloads := filepath.Join(exeDir(), "downloads")
	os.MkdirAll(downloads, 0o755)
	(&api.API{V: v, TrustProxy: cfg.TrustProxy, SecureCookie: cfg.TLSCert != "",
		DownloadDir: downloads, PublicURL: cfg.PublicURL}).Register(mux)
	mux.Handle("/", web.Handler())
	return &server{cfg: cfg, vault: v, http: &http.Server{
		Addr:              cfg.Listen,
		Handler:           mux,
		ReadHeaderTimeout: 30 * time.Second,
		IdleTimeout:       5 * time.Minute,
	}}, nil
}

// serve runs until ctx is cancelled.
func (s *server) serve(ctx context.Context) error {
	go s.vault.RunMaintenance(ctx)
	errc := make(chan error, 1)
	go func() {
		scheme := "http"
		if s.cfg.TLSCert != "" {
			scheme = "https"
		}
		log.Printf("DocVault 서버 시작: %s 주소 %s  (저장소: %s)", scheme, s.cfg.Listen, s.cfg.StoreDir)
		if s.cfg.TLSCert != "" {
			errc <- s.http.ListenAndServeTLS(s.cfg.TLSCert, s.cfg.TLSKey)
		} else {
			errc <- s.http.ListenAndServe()
		}
	}()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
		sctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		s.http.Shutdown(sctx)
		s.vault.DB.Close()
		log.Printf("DocVault 서버 종료")
		return nil
	}
}

func runForeground() error {
	s, err := newServer()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return s.serve(ctx)
}

func main() {
	if isService() {
		runService()
		return
	}
	cmd := "run"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	var err error
	switch cmd {
	case "run":
		err = runForeground()
	case "install", "uninstall", "start", "stop":
		err = serviceCommand(cmd)
	case "reset-password":
		if len(os.Args) != 4 {
			err = errors.New("사용법: docvault-server reset-password <아이디> <새 비밀번호>")
			break
		}
		err = resetPassword(os.Args[2], os.Args[3])
	case "maintain":
		err = maintainNow()
	default:
		err = fmt.Errorf("알 수 없는 명령: %s (run | install | uninstall | start | stop | reset-password | maintain)", cmd)
	}
	if err != nil {
		reportStartupError(err)
		os.Exit(1)
	}
}

func resetPassword(user, pw string) error {
	cfg, _, err := loadConfig()
	if err != nil {
		return err
	}
	v, err := open(cfg)
	if err != nil {
		return err
	}
	defer v.DB.Close()
	users, err := v.ListUsers()
	if err != nil {
		return err
	}
	for _, u := range users {
		if u.Username == user {
			f := false
			if err := v.UpdateUser(vault.Actor{Client: "system"}, u.ID, vault.UserUpdate{Password: &pw, Disabled: &f}); err != nil {
				return err
			}
			fmt.Println("비밀번호를 변경했습니다:", user)
			return nil
		}
	}
	return errors.New("사용자를 찾을 수 없습니다: " + user)
}

func maintainNow() error {
	cfg, _, err := loadConfig()
	if err != nil {
		return err
	}
	v, err := open(cfg)
	if err != nil {
		return err
	}
	defer v.DB.Close()
	r, err := v.Maintain()
	fmt.Printf("휴지통 영구삭제 %d건, 이전 버전 정리 %d건, 반출 만료 %d건, 파일내용 정리 %d건\n",
		r.PurgedItems, r.PrunedVersions, r.ExpiredExports, r.DeletedBlobs)
	return err
}

// reportStartupError shows why the server stopped and keeps the window open,
// so a double-clicked server does not just flash and disappear. The message
// is also saved next to the program.
func reportStartupError(err error) {
	msg := "오류: " + err.Error()
	low := strings.ToLower(err.Error())
	if strings.Contains(err.Error(), "store_dir") || strings.Contains(low, "access is denied") ||
		strings.Contains(err.Error(), "액세스") || strings.Contains(low, "network") || strings.Contains(err.Error(), "네트워크") {
		msg += "\n\n[확인할 것]\n" +
			" 1. 탐색기 주소창에 docvault.json의 store_dir 경로(예: \\\\192.168.50.201\\DocVaultStore)를 입력해 열리는지\n" +
			" 2. 열릴 때 NAS 계정으로 로그인하고 '자격 증명 기억'을 체크했는지\n" +
			" 3. 그 계정에 이 폴더 쓰기 권한이 있는지 (새 파일을 만들어 보기)\n" +
			" 4. docvault.json에서 역슬래시를 두 번씩 썼는지: \"\\\\\\\\192.168.50.201\\\\DocVaultStore\""
	} else if strings.Contains(low, "only one usage of each socket") || strings.Contains(low, "address already in use") {
		msg += "\n\n[확인할 것] 서버가 이미 실행 중이거나 다른 프로그램이 같은 포트(listen)를 쓰고 있습니다.\n" +
			" 작업 관리자에서 docvault-server.exe가 이미 떠 있는지 확인하세요."
	} else if strings.Contains(err.Error(), "docvault.json") {
		msg += "\n\n[확인할 것] docvault.json 형식 오류입니다. 쉼표(,)와 따옴표(\"), 역슬래시(\\\\) 개수를 확인하세요."
	}
	fmt.Fprintln(os.Stderr, msg)
	os.WriteFile(filepath.Join(exeDir(), "시작오류.txt"), []byte(time.Now().Format("2006-01-02 15:04:05")+"\r\n"+strings.ReplaceAll(msg, "\n", "\r\n")+"\r\n"), 0o644)
	fmt.Fprintln(os.Stderr, "\n(이 내용은 서버 폴더의 시작오류.txt 에도 저장했습니다)\n엔터를 누르면 창이 닫힙니다.")
	bufio.NewReader(os.Stdin).ReadString('\n')
}
