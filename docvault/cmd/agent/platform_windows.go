//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
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

// Drives are mounted as local disks (no --network-mode) so Explorer lists them
// under "장치 및 드라이브" as "이름 (F:)", like a local disk.
func platformMountArgs(d Drive) []string { return nil }

// setDriveIcon shows the DocVault icon for a drive letter in Explorer (per
// user, no admin rights needed); on=false removes it again.
// clearDriveIcons removes DocVault icons left behind (e.g. after a crash), so a
// USB stick that later gets the same letter does not show the DocVault icon.
func clearDriveIcons() {
	const base = `Software\Classes\Applications\Explorer.exe\Drives`
	k, err := registry.OpenKey(registry.CURRENT_USER, base, registry.ENUMERATE_SUB_KEYS)
	if err != nil {
		return
	}
	letters, _ := k.ReadSubKeyNames(-1)
	k.Close()
	for _, l := range letters {
		ik, err := registry.OpenKey(registry.CURRENT_USER, base+`\`+l+`\DefaultIcon`, registry.QUERY_VALUE)
		if err != nil {
			continue
		}
		v, _, _ := ik.GetStringValue("")
		ik.Close()
		if strings.Contains(strings.ToLower(v), "docvault-agent.exe") {
			setDriveIcon(l, false)
		}
	}
}

func setDriveIcon(letter string, on bool) {
	key := `Software\Classes\Applications\Explorer.exe\Drives\` + letter
	if on {
		exe, err := os.Executable()
		if err != nil {
			return
		}
		k, _, err := registry.CreateKey(registry.CURRENT_USER, key+`\DefaultIcon`, registry.SET_VALUE)
		if err != nil {
			return
		}
		k.SetStringValue("", exe+",0")
		k.Close()
	} else {
		registry.DeleteKey(registry.CURRENT_USER, key+`\DefaultIcon`)
		registry.DeleteKey(registry.CURRENT_USER, key)
	}
	// SHCNE_ASSOCCHANGED: make Explorer pick up the icon change
	windows.NewLazySystemDLL("shell32.dll").NewProc("SHChangeNotify").Call(0x08000000, 0, 0, 0)
}

func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000} // CREATE_NO_WINDOW
}

// WinFsp unmounts the drive when the rclone process ends.
func stopProcess(cmd *exec.Cmd) { cmd.Process.Kill() }

func openBrowser(url string) {
	exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
}

// stopOtherAgents ends a running DocVault agent and the drives it mounted.
func stopOtherAgents() {
	self := os.Getpid()
	c := exec.Command("taskkill", "/F", "/FI", fmt.Sprintf("PID ne %d", self), "/IM", "docvault-agent.exe")
	hideWindow(c)
	c.Run()
	c = exec.Command("powershell", "-NoProfile", "-Command",
		`Get-Process rclone -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '`+exeDir()+`\*' } | Stop-Process -Force`)
	hideWindow(c)
	c.Run()
}
