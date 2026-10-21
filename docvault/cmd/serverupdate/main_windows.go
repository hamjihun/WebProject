//go:build windows

// DocVault_서버업데이트.exe updates a DocVault server in one double-click:
// it stops the Windows service, replaces docvault-server.exe and
// downloads\docvault-setup.exe (the PC installer the agents auto-update from)
// with the versions embedded here, and starts the service again. It needs
// administrator rights and elevates itself.
package main

import (
	"bufio"
	"embed"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

//go:embed payload
var payload embed.FS

const serviceName = "DocVault"

func main() {
	if !windows.GetCurrentProcessToken().IsElevated() {
		relaunchElevated()
		return
	}
	if err := run(); err != nil {
		fmt.Println()
		fmt.Println("❌ 업데이트 실패:", err)
		fmt.Println("   서버 폴더의 파일을 수동으로 교체하거나, 다시 시도하세요.")
		pause()
		os.Exit(1)
	}
	pause()
}

func run() error {
	fmt.Println("==============================================")
	fmt.Println("  DocVault 서버 업데이트")
	fmt.Println("==============================================")

	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("서비스 관리자 연결 실패 (관리자 권한 필요): %w", err)
	}
	defer m.Disconnect()
	s, err := m.OpenService(serviceName)
	if err != nil {
		return fmt.Errorf("DocVault 서비스를 찾을 수 없습니다. 먼저 [윈도우서비스로설치.bat]으로 설치하세요")
	}
	defer s.Close()

	dir, err := installDir(s)
	if err != nil {
		return err
	}
	fmt.Println("서버 폴더:", dir)

	fmt.Println("[1/4] 서비스 중지")
	s.Control(svc.Stop)
	waitState(s, svc.Stopped, 30*time.Second)

	fmt.Println("[2/4] 프로그램 파일 교체 (기존 파일은 .bak 로 백업)")
	if err := replace(filepath.Join(dir, "docvault-server.exe"), "payload/docvault-server.exe"); err != nil {
		return err
	}
	os.MkdirAll(filepath.Join(dir, "downloads"), 0o755)
	if err := replace(filepath.Join(dir, "downloads", "docvault-setup.exe"), "payload/docvault-setup.exe"); err != nil {
		return err
	}

	fmt.Println("[3/4] 서비스 시작")
	if err := s.Start(); err != nil {
		return fmt.Errorf("서비스 시작 실패: %w", err)
	}
	waitState(s, svc.Running, 30*time.Second)

	fmt.Println("[4/4] 확인")
	fmt.Println()
	fmt.Println("✅ 서버를 업데이트했습니다.")
	fmt.Println("   직원 PC는 켜져 있으면 10분 안에, 또는 아이콘 → [업데이트 확인]으로 자동 업데이트됩니다.")
	return nil
}

// installDir reads the folder the service runs from (its binary path).
func installDir(s *mgr.Service) (string, error) {
	if c, err := s.Config(); err == nil {
		bin := strings.Trim(c.BinaryPathName, `"`)
		if i := strings.Index(bin, `" `); i > 0 {
			bin = bin[:i]
		}
		if d := filepath.Dir(bin); d != "" && d != "." {
			return d, nil
		}
	}
	return `C:\DocVault`, nil
}

func replace(dst, embedded string) error {
	src, err := payload.Open(embedded)
	if err != nil {
		return fmt.Errorf("이 업데이트 파일에 %s 이 없습니다", filepath.Base(embedded))
	}
	defer src.Close()
	tmp := dst + ".new"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, src); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	f.Close()
	if _, err := os.Stat(dst); err == nil {
		os.Remove(dst + ".bak")
		os.Rename(dst, dst+".bak")
	}
	if err := os.Rename(tmp, dst); err != nil {
		return err
	}
	fmt.Println("      교체:", dst)
	return nil
}

func waitState(s *mgr.Service, want svc.State, timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if st, err := s.Query(); err == nil && st.State == want {
			return
		}
		time.Sleep(300 * time.Millisecond)
	}
}

func relaunchElevated() {
	exe, _ := os.Executable()
	verb, _ := windows.UTF16PtrFromString("runas")
	file, _ := windows.UTF16PtrFromString(exe)
	windows.ShellExecute(0, verb, file, nil, nil, windows.SW_NORMAL)
}

func pause() {
	fmt.Println("\n엔터를 누르면 창이 닫힙니다.")
	bufio.NewReader(os.Stdin).ReadString('\n')
}
