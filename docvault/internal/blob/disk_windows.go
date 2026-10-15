//go:build windows

package blob

import (
	"strings"

	"golang.org/x/sys/windows"
)

// DiskSpace reports the total and free bytes of the disk holding the store.
// It works for local disks (E:\Store) and NAS shares (\\nas\share).
func (s *Store) DiskSpace() (total, free uint64, err error) {
	root := s.root
	if !strings.HasSuffix(root, `\`) {
		root += `\` // required for UNC paths
	}
	p, err := windows.UTF16PtrFromString(root)
	if err != nil {
		return 0, 0, err
	}
	var avail uint64
	err = windows.GetDiskFreeSpaceEx(p, &avail, &total, &free)
	return total, avail, err
}
