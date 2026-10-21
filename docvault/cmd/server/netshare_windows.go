//go:build windows

package main

import (
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

var procWNetAddConnection2 = windows.NewLazySystemDLL("mpr.dll").NewProc("WNetAddConnection2W")

type netResource struct {
	Scope, Type, DisplayType, Usage              uint32
	LocalName, RemoteName, Comment, ProviderName *uint16
}

// connectStore logs in to the NAS share holding store_dir with the account in
// docvault.json, so the server works as a Windows service (system account).
func connectStore(cfg *Config) error {
	if cfg.StoreUser == "" || !strings.HasPrefix(cfg.StoreDir, `\\`) {
		return nil
	}
	// \\server\share\sub\dir -> \\server\share
	parts := strings.SplitN(strings.TrimPrefix(cfg.StoreDir, `\\`), `\`, 3)
	if len(parts) < 2 {
		return nil
	}
	share := `\\` + parts[0] + `\` + parts[1]
	remote, _ := syscall.UTF16PtrFromString(share)
	user, _ := syscall.UTF16PtrFromString(cfg.StoreUser)
	pass, _ := syscall.UTF16PtrFromString(cfg.StorePassword)
	nr := netResource{Type: 1 /* RESOURCETYPE_DISK */, RemoteName: remote}
	r, _, _ := procWNetAddConnection2.Call(uintptr(unsafe.Pointer(&nr)), uintptr(unsafe.Pointer(pass)), uintptr(unsafe.Pointer(user)), 0)
	switch syscall.Errno(r) {
	case 0, 85, 1219: // connected, already connected, already connected with other credentials
		return nil
	}
	return syscall.Errno(r)
}
