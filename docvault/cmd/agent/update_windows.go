//go:build windows

package main

// Self-restart after an automatic update. The update service replaces the
// program files while this copy keeps running; this copy notices the new
// version.txt and restarts into the new program right away unless a
// document program is open (then as soon as it is closed), or when the user
// picks [업데이트 적용].

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"
	"unsafe"

	"docvault/internal/buildinfo"

	"golang.org/x/sys/windows"
)

var (
	startExe, _ = os.Executable() // path at start: still the program's path after an update renames this copy

)

const (
	wmRestart      = wmApp + 6
	cmdApplyUpdate = 2009
)

// documentPrograms with files possibly open on the drives: never restart
// (and briefly disconnect the drives) under them.
var documentPrograms = map[string]bool{
	"excel.exe": true, "winword.exe": true, "powerpnt.exe": true, "msaccess.exe": true, "visio.exe": true,
	"hwp.exe": true, "hcell.exe": true, "hshow.exe": true, "hword.exe": true,
	"acrobat.exe": true, "acrord32.exe": true, "notepad.exe": true, "acad.exe": true,
}

func installedVersion() string {
	b, _ := os.ReadFile(filepath.Join(filepath.Dir(startExe), "version.txt"))
	return strings.TrimSpace(string(b))
}

// watchUpdates runs in the background for the life of the program.
func (g *gui) watchUpdates() {
	announced := ""
	for range time.Tick(15 * time.Second) {
		v := installedVersion()
		if !buildinfo.NewerThan(v, version) {
			continue
		}
		g.mu.Lock()
		g.updateTo = v
		g.mu.Unlock()
		if announced != v {
			announced = v
			log.Printf("새 버전 %s 설치됨 (실행 중 %s)", v, version)
			g.queueBalloon("DocVault 업데이트 준비됨 (v"+v+")",
				"Excel·Word·한글 등을 닫으면 바로 적용됩니다.\n지금 적용하려면 DocVault 아이콘 → [업데이트 적용]")
		}
		if !documentProgramOpen() {
			log.Printf("열린 문서 프로그램이 없어 업데이트 적용")
			g.post(wmRestart)
			return
		}
	}
}

// restart starts the new program and ends this one.
func (g *gui) restart() {
	log.Printf("업데이트 적용: 다시 시작합니다")
	g.endSession()
	if err := exec.Command(startExe, "run", "--restarted").Start(); err != nil {
		log.Printf("다시 시작 실패: %v", err)
		g.startSession()
		return
	}
	if g.login != 0 {
		pDestroyWindow.Call(g.login)
		g.login = 0
	}
	pPostQuitMessage.Call(0)
}

func documentProgramOpen() bool {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return true
	}
	defer windows.CloseHandle(snap)
	var pe windows.ProcessEntry32
	pe.Size = uint32(unsafe.Sizeof(pe))
	for err = windows.Process32First(snap, &pe); err == nil; err = windows.Process32Next(snap, &pe) {
		if documentPrograms[strings.ToLower(windows.UTF16ToString(pe.ExeFile[:]))] {
			return true
		}
	}
	return false
}

// cleanupOldCopies removes program copies an update renamed away.
func cleanupOldCopies() {
	old, _ := filepath.Glob(filepath.Join(filepath.Dir(startExe), "*.old-*"))
	for _, f := range old {
		os.Remove(f) // may belong to the SYSTEM-owned install; failing is fine
	}
}

const cmdCheckUpdate = 2010

var checkingUpdate atomic.Bool

// checkUpdateNow is [업데이트 확인]: asks the server for its version and, if
// it is newer, has the update service install it now, then offers to apply.
func (g *gui) checkUpdateNow() {
	if !checkingUpdate.CompareAndSwap(false, true) {
		return
	}
	defer checkingUpdate.Store(false)
	if v := installedVersion(); buildinfo.NewerThan(v, version) {
		g.offerRestart(v)
		return
	}
	var info struct{ Version string }
	resp, err := probeClient.Get(g.cfg.Server + "/api/setup-info")
	if err == nil {
		json.NewDecoder(resp.Body).Decode(&info)
		resp.Body.Close()
	}
	switch {
	case err != nil:
		msgBox(0, "서버에 연결할 수 없어 업데이트를 확인하지 못했습니다.\n잠시 후 다시 시도하세요.", mbIconWarning)
		return
	case !buildinfo.NewerThan(info.Version, version):
		msgBox(0, "최신 버전입니다. (v"+version+")", mbIconInformation)
		return
	}
	logPath := filepath.Join(os.Getenv("ProgramData"), "DocVault", "update.log")
	before := fileSize(logPath)
	if err := triggerUpdateService(); err != nil {
		log.Printf("업데이트 서비스 호출 실패: %v", err)
		msgBox(0, "자동 업데이트 서비스에 연결할 수 없습니다.\n웹 문서함 → [PC 프로그램 설치]로 새 버전(v"+info.Version+")을 직접 설치하세요.", mbIconWarning)
		return
	}
	g.queueBalloon("업데이트를 받는 중입니다 (v"+info.Version+")", "1분 정도 걸립니다. 다 되면 알려 드립니다.")
	for i := 0; i < 150; i++ { // up to 5 minutes
		time.Sleep(2 * time.Second)
		if i == 7 && fileSize(logPath) == before {
			// The installed update service is old (before [업데이트 확인]) and
			// ignores the request: install directly instead (needs admin).
			g.updateElevatedFallback(info.Version)
			return
		}
		if v := installedVersion(); buildinfo.NewerThan(v, version) {
			g.offerRestart(v)
			return
		}
	}
	g.updateElevatedFallback(info.Version)
}

// updateElevatedFallback downloads the new PC installer and runs it with
// administrator rights (a UAC prompt), so the update applies now even when
// the background service is an old version. Employees without admin rights
// get the automatic update on reboot instead.
func (g *gui) updateElevatedFallback(want string) {
	if msgBox(0, "새 버전(v"+want+")을 지금 설치할까요?\n\n[예]를 누르면 관리자 승인 창이 한 번 뜹니다. (관리자 권한이 없으면 PC를 다시 켤 때 자동으로 업데이트됩니다.)", mbYesNo|mbIconQuestion) != idYes {
		return
	}
	tmp := filepath.Join(os.TempDir(), "docvault-setup-update.exe")
	if err := downloadFile(g.cfg.Server+"/download/setup", tmp); err != nil {
		msgBox(0, "설치 파일을 받지 못했습니다: "+err.Error(), mbIconWarning)
		return
	}
	if err := runElevated(tmp, "/update"); err != nil {
		msgBox(0, "설치를 시작하지 못했습니다.\n웹 문서함 → [PC 프로그램 설치]로 직접 설치하세요.", mbIconWarning)
		return
	}
	g.queueBalloon("업데이트를 설치하는 중입니다 (v"+want+")", "1분 정도 걸립니다. 다 되면 적용할지 여쭤봅니다.")
	for i := 0; i < 150; i++ {
		time.Sleep(2 * time.Second)
		if v := installedVersion(); buildinfo.NewerThan(v, version) {
			g.offerRestart(v)
			return
		}
	}
}

func downloadFile(url, dst string) error {
	c := &http.Client{Timeout: 10 * time.Minute}
	resp, err := c.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s", resp.Status)
	}
	f, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, resp.Body)
	return err
}

func runElevated(exe, args string) error {
	verb, _ := windows.UTF16PtrFromString("runas")
	file, _ := windows.UTF16PtrFromString(exe)
	a, _ := windows.UTF16PtrFromString(args)
	return windows.ShellExecute(0, verb, file, a, nil, windows.SW_SHOWNORMAL)
}

func (g *gui) offerRestart(v string) {
	g.mu.Lock()
	g.updateTo = v
	g.mu.Unlock()
	if msgBox(0, "새 버전(v"+v+")이 설치되었습니다. 지금 적용할까요?\n\n문서 드라이브가 몇 초 동안 끊기니, 열려 있는 문서는 먼저 저장하세요.", mbYesNo|mbIconQuestion) == idYes {
		g.post(wmRestart)
	}
}

func triggerUpdateService() error {
	m, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if err != nil {
		return err
	}
	defer windows.CloseServiceHandle(m)
	s, err := windows.OpenService(m, wstr("DocVaultUpdate"), windows.SERVICE_USER_DEFINED_CONTROL)
	if err != nil {
		return err
	}
	defer windows.CloseServiceHandle(s)
	var st windows.SERVICE_STATUS
	return windows.ControlService(s, 128, &st)
}

func fileSize(p string) int64 {
	st, err := os.Stat(p)
	if err != nil {
		return -1
	}
	return st.Size()
}
