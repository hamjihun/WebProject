package main

import (
	"log"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

var procGetDriveType = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetDriveTypeW")

const (
	driveRemovable = 2
	driveFixed     = 3
)

// watchLocalFolders watches every local disk and USB drive of the PC for
// new files (system folders are skipped by skipLocal). The DocVault drives
// themselves and network drives are not watched.
func watchLocalFolders(a *agent) {
	go func() {
		var mu sync.Mutex
		watching := map[string]bool{}
		for {
			for l := 'C'; l <= 'Z'; l++ {
				root := string(l) + `:\`
				mu.Lock()
				busy := watching[root]
				mu.Unlock()
				if busy || !localDisk(root) {
					continue
				}
				mu.Lock()
				watching[root] = true
				mu.Unlock()
				go watchDir(a, root, func() { mu.Lock(); delete(watching, root); mu.Unlock() })
			}
			time.Sleep(5 * time.Second)
		}
	}()
}

// localDisk is true for fixed and removable disks (not DocVault or other
// virtual drives).
func localDisk(root string) bool {
	p, _ := windows.UTF16PtrFromString(root)
	if t, _, _ := procGetDriveType.Call(uintptr(unsafe.Pointer(p))); t != driveRemovable && t != driveFixed {
		return false
	}
	var fs [64]uint16
	if windows.GetVolumeInformation(p, nil, 0, nil, nil, nil, &fs[0], uint32(len(fs))) != nil {
		return false // e.g. empty card reader
	}
	// Only real disks: virtual drives of other programs (e.g. another
	// document system's drives) are left alone.
	switch strings.ToLower(windows.UTF16ToString(fs[:])) {
	case "ntfs", "fat", "fat32", "exfat", "refs":
		return true
	}
	return false
}

// watchDir reports changed files under root until the folder goes away
// (e.g. the USB drive is pulled out).
func watchDir(a *agent, root string, done func()) {
	if done != nil {
		defer done()
	}
	p, err := windows.UTF16PtrFromString(root)
	if err != nil {
		return
	}
	h, err := windows.CreateFile(p, windows.FILE_LIST_DIRECTORY,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		log.Printf("폴더 감시 실패 %s: %v", root, err)
		return
	}
	defer windows.CloseHandle(h)
	buf := make([]byte, 64*1024)
	renamedFrom := "" // old name of the rename being reported
	const filter = windows.FILE_NOTIFY_CHANGE_FILE_NAME | windows.FILE_NOTIFY_CHANGE_SIZE | windows.FILE_NOTIFY_CHANGE_LAST_WRITE
	for {
		var n uint32
		if err := windows.ReadDirectoryChanges(h, &buf[0], uint32(len(buf)), true, filter, &n, nil, 0); err != nil {
			log.Printf("폴더 감시 종료 %s: %v", root, err)
			return
		}
		if n == 0 { // overflow: too many changes at once; nothing to do but go on
			continue
		}
		for off := uint32(0); ; {
			info := (*windows.FileNotifyInformation)(unsafe.Pointer(&buf[off]))
			name := windows.UTF16ToString(unsafe.Slice(&info.FileName, info.FileNameLength/2))
			path := filepath.Join(root, name)
			switch info.Action {
			case windows.FILE_ACTION_ADDED:
				a.noteDownloadStarted(path)
				a.noteLocalChange(path)
			case windows.FILE_ACTION_MODIFIED:
				a.noteLocalChange(path)
			case windows.FILE_ACTION_RENAMED_OLD_NAME:
				renamedFrom = path
			case windows.FILE_ACTION_RENAMED_NEW_NAME:
				if isPartialDownload(renamedFrom) {
					a.noteDownloadFinished(path)
				}
				renamedFrom = ""
				a.noteLocalChange(path)
			}
			if info.NextEntryOffset == 0 {
				break
			}
			off += info.NextEntryOffset
		}
	}
}
