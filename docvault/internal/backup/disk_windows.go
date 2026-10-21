//go:build windows

package backup

import (
	"path/filepath"

	"golang.org/x/sys/windows"
)

func freeGB(path string) float64 {
	p, err := windows.UTF16PtrFromString(filepath.VolumeName(path) + `\`)
	if err != nil {
		return 0
	}
	var free, total, totalFree uint64
	if windows.GetDiskFreeSpaceEx(p, &free, &total, &totalFree) != nil {
		return 0
	}
	return float64(free) / (1 << 30)
}
