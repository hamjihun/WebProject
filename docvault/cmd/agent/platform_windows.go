//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

const rcloneExe = "rclone.exe"

func stateDir() string {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		base = exeDir()
	}
	return filepath.Join(base, "DocVault")
}

// protect encrypts data for the current Windows user (DPAPI), so the saved
// session cannot be read by other accounts or copied to another PC.
func protect(data []byte) ([]byte, error) {
	in := windows.DataBlob{Size: uint32(len(data)), Data: &data[0]}
	var out windows.DataBlob
	if err := windows.CryptProtectData(&in, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out); err != nil {
		return nil, err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	return append([]byte(nil), unsafe.Slice(out.Data, out.Size)...), nil
}

func unprotect(data []byte) ([]byte, error) {
	if len(data) == 0 {
		return nil, fmt.Errorf("empty")
	}
	in := windows.DataBlob{Size: uint32(len(data)), Data: &data[0]}
	var out windows.DataBlob
	if err := windows.CryptUnprotectData(&in, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out); err != nil {
		return nil, err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	return append([]byte(nil), unsafe.Slice(out.Data, out.Size)...), nil
}

func mountTarget(letter string) string { return letter + ":" }

func prepareTarget(target string) error {
	if _, err := os.Stat(target + `\`); err == nil {
		return fmt.Errorf("%s 드라이브 문자를 이미 다른 드라이브가 쓰고 있습니다", target)
	}
	return nil
}

func cleanupTarget(string) {}

// Network mode makes Explorer treat the drive like a mapped network drive
// (no Recycle Bin on it: deletions go to the server's trash instead).
func platformMountArgs(d Drive) []string {
	return []string{"--network-mode", "--volname", `\\DocVault\` + d.Name}
}

func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000} // CREATE_NO_WINDOW
}

// WinFsp unmounts the drive when the rclone process ends.
func stopProcess(cmd *exec.Cmd) { cmd.Process.Kill() }

var (
	kernel32         = windows.NewLazySystemDLL("kernel32.dll")
	user32           = windows.NewLazySystemDLL("user32.dll")
	getConsoleWindow = kernel32.NewProc("GetConsoleWindow")
	getConsolePList  = kernel32.NewProc("GetConsoleProcessList")
	showWindow       = user32.NewProc("ShowWindow")
)

// hideConsole hides the console window, but only when it was opened just for
// this program (double-click / startup), not a command prompt the user typed in.
func hideConsole() {
	var pids [4]uint32
	if n, _, _ := getConsolePList.Call(uintptr(unsafe.Pointer(&pids[0])), 4); n != 1 {
		return
	}
	if h, _, _ := getConsoleWindow.Call(); h != 0 {
		showWindow.Call(h, 0) // SW_HIDE
	}
}

func openBrowser(url string) {
	exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
}
