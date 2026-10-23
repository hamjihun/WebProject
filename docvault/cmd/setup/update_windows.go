//go:build windows

package main

// Automatic updates. The installer registers the DocVaultUpdate service
// (this program with /service, running as SYSTEM so employees need no
// administrator rights). 20 seconds after Windows starts and then every
// 10 minutes it asks the server which version
// of the PC program it offers; when that is newer than the installed one it
// downloads the installer and runs it with /update. The running agent sees
// the new version.txt and restarts itself into the new version unless a
// document program is open (or when the user picks [업데이트 적용]).

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"docvault/internal/buildinfo"

	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

const updateServiceName = "DocVaultUpdate"

// updateNowControl is the service control code the agent sends for
// [업데이트 확인] (codes 128-255 are user defined; by default Windows lets
// signed-in users send them).
const updateNowControl = svc.Cmd(128)

// setupMarker is found in this file by the server (buildinfo.VersionIn).
// A variable, so the text stays in the program as written.
var setupMarker = buildinfo.SetupMarkerPrefix + buildinfo.Version + ";"

func setupVersion() string {
	return strings.TrimSuffix(strings.TrimPrefix(setupMarker, buildinfo.SetupMarkerPrefix), ";")
}

func installedVersion() string {
	b, _ := os.ReadFile(filepath.Join(installDir(), "version.txt"))
	return strings.TrimSpace(string(b))
}

func updateDir() string {
	return filepath.Join(os.Getenv("ProgramData"), "DocVault")
}

func updateLog(format string, args ...any) {
	os.MkdirAll(updateDir(), 0o755)
	f, err := os.OpenFile(filepath.Join(updateDir(), "update.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	if st, _ := f.Stat(); st != nil && st.Size() > 1<<20 {
		f.Truncate(0)
	}
	fmt.Fprintf(f, "%s "+format+"\r\n", append([]any{time.Now().Format("2006-01-02 15:04:05")}, args...)...)
}

// doUpdate installs this version over the running one, without asking.
func doUpdate() error {
	server := serverFromTrailer()
	if server == "" {
		server = existingServer()
	}
	if server == "" {
		return fmt.Errorf("서버 주소를 알 수 없습니다")
	}
	updateLog("업데이트 설치 시작: %s → %s", installedVersion(), setupVersion())
	if err := installFiles(server); err != nil {
		return err
	}
	updateLog("업데이트 설치 완료: %s", setupVersion())
	return nil
}

// ---- the update service ----

type updateService struct{}

func runUpdateService() {
	if err := svc.Run(updateServiceName, updateService{}); err != nil {
		updateLog("서비스 오류: %v", err)
	}
}

func (updateService) Execute(args []string, req <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	tick := time.NewTicker(10 * time.Minute)
	defer tick.Stop()
	failures := map[string]int{}
	var mu sync.Mutex // one check at a time
	updated := make(chan struct{}, 1)
	check := func(manual bool) {
		if !mu.TryLock() {
			return
		}
		go func() {
			defer mu.Unlock()
			if manual {
				clear(failures) // the user asked: try again even after failures
			}
			if checkForUpdate(ctx, failures) {
				updated <- struct{}{}
			}
		}()
	}
	first := time.After(20 * time.Second) // soon after Windows starts, before work begins
	for {
		select {
		case c := <-req:
			switch c.Cmd {
			case svc.Interrogate:
				status <- c.CurrentStatus
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				return false, 0
			case updateNowControl:
				updateLog("사용자가 업데이트 확인을 요청했습니다")
				check(true)
			}
		case <-updated:
			// This running copy is the old program: start the service again
			// (a few seconds after this copy has stopped) so the new one runs.
			c := exec.Command("cmd")
			c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true,
				CmdLine: `cmd /c ping 127.0.0.1 -n 4 >nul & sc start ` + updateServiceName}
			if c.Start() == nil {
				updateLog("새 버전으로 업데이트 서비스를 다시 시작합니다")
				status <- svc.Status{State: svc.StopPending}
				return false, 0
			}
		case <-first:
			check(false)
		case <-tick.C:
			check(false)
		}
	}
}

// checkForUpdate installs a newer version the server offers and reports
// whether it did.
func checkForUpdate(ctx context.Context, failures map[string]int) bool {
	server := existingServer()
	if server == "" {
		return false
	}
	c := &http.Client{Timeout: 15 * time.Second}
	resp, err := c.Get(server + "/api/setup-info")
	if err != nil {
		return false
	}
	var info struct{ Version string }
	json.NewDecoder(resp.Body).Decode(&info)
	resp.Body.Close()
	// 웹 첨부 차단 보류: CBCM 토큰을 심지 않고 남아 있으면 지운다.
	removeEnrollmentToken()
	have := installedVersion()
	if info.Version == "" || !buildinfo.NewerThan(info.Version, have) || failures[info.Version] >= 3 {
		return false
	}
	updateLog("새 버전 발견: %s (설치된 버전 %s)", info.Version, have)
	if err := downloadAndRun(ctx, server, info.Version); err != nil {
		failures[info.Version]++
		updateLog("업데이트 실패 (%d/3): %v", failures[info.Version], err)
		return false
	}
	return true
}

func downloadAndRun(ctx context.Context, server, want string) error {
	dc := &http.Client{Timeout: 10 * time.Minute}
	resp, err := dc.Get(server + "/download/setup")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("다운로드: %s", resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 512<<20))
	if err != nil {
		return err
	}
	if got := buildinfo.VersionIn(data); got != want {
		return fmt.Errorf("받은 설치 파일의 버전이 %q 입니다 (기대: %s)", got, want)
	}
	dst := filepath.Join(updateDir(), "update", "docvault-setup.exe")
	os.MkdirAll(filepath.Dir(dst), 0o755)
	if err := os.WriteFile(dst, data, 0o644); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()
	out, err := exec.CommandContext(ctx, dst, "/update").CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	if v := installedVersion(); v != want {
		return fmt.Errorf("설치 후 버전이 %q 입니다", v)
	}
	return nil
}

// installUpdateService registers (or points at exe) and starts the service.
func installUpdateService(exe string) error {
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	s, err := m.OpenService(updateServiceName)
	if err == nil {
		defer s.Close()
		if c, err := s.Config(); err == nil && !strings.Contains(strings.ToLower(c.BinaryPathName), strings.ToLower(exe)) {
			c.BinaryPathName = `"` + exe + `" /service`
			s.UpdateConfig(c)
		}
	} else {
		s, err = m.CreateService(updateServiceName, exe, mgr.Config{
			DisplayName: "DocVault 자동 업데이트",
			Description: "DocVault 문서 드라이브 PC 프로그램을 서버의 새 버전으로 자동 업데이트합니다.",
			StartType:   mgr.StartAutomatic,
		}, "/service")
		if err != nil {
			return err
		}
		defer s.Close()
		s.SetRecoveryActions([]mgr.RecoveryAction{{Type: mgr.ServiceRestart, Delay: time.Minute}}, 86400)
	}
	if st, err := s.Query(); err == nil && st.State == svc.Stopped {
		s.Start()
	}
	return nil
}

func removeUpdateService() {
	m, err := mgr.Connect()
	if err != nil {
		return
	}
	defer m.Disconnect()
	s, err := m.OpenService(updateServiceName)
	if err != nil {
		return
	}
	defer s.Close()
	s.Control(svc.Stop)
	for i := 0; i < 20; i++ {
		if st, err := s.Query(); err != nil || st.State == svc.Stopped {
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	if err := s.Delete(); err != nil {
		log.Printf("업데이트 서비스 제거: %v", err)
	}
	os.RemoveAll(updateDir())
}
