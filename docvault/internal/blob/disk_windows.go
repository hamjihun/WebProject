//go:build windows

package blob

import "golang.org/x/sys/windows"

// DiskSpace reports the total and free bytes of the disk holding the store.
func (s *Store) DiskSpace() (total, free uint64, err error) {
	p, err := windows.UTF16PtrFromString(s.root)
	if err != nil {
		return 0, 0, err
	}
	var avail uint64
	err = windows.GetDiskFreeSpaceEx(p, &avail, &total, &free)
	return total, avail, err
}
