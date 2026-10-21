//go:build windows

package main

// Self-restart after an automatic update. The update service replaces the
// program files while this copy keeps running; this copy notices the new
// version.txt and restarts into the new program right away unless a
// document program is open (then as soon as it is closed), or when the user
// picks [업데이트 적용].

import (
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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
