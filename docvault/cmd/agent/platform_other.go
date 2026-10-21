//go:build !windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

// Non-Windows builds exist for development and testing: drives are mounted
// as folders under ~/.docvault/mnt/<letter>.

const rcloneExe = "rclone"

func stateDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = exeDir()
	}
	return filepath.Join(home, ".docvault")
}

func protect(b []byte) ([]byte, error)   { return b, nil }
func unprotect(b []byte) ([]byte, error) { return b, nil }

func mountTarget(letter string) string { return filepath.Join(stateDir(), "mnt", letter) }

func prepareTarget(t string) error { return os.MkdirAll(t, 0o700) }

func cleanupTarget(t string) { os.Remove(t) }

func platformMountArgs(d Drive) []string { return nil }

func setDriveIcon(string, bool) {}

func clearDriveIcons() {}

func hideWindow(*exec.Cmd) {}

func stopProcess(cmd *exec.Cmd) { cmd.Process.Signal(syscall.SIGTERM) }

func runApp(cfg *Config) error { return cmdRun(cfg) }

func openBrowser(url string) {
	if p, err := exec.LookPath("xdg-open"); err == nil {
		exec.Command(p, url).Start()
	}
}

func stopOtherAgents() {}
