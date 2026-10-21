//go:build !windows

package backup

import "syscall"

func freeGB(path string) float64 {
	var st syscall.Statfs_t
	if syscall.Statfs(path, &st) != nil {
		return 0
	}
	return float64(st.Bavail) * float64(st.Bsize) / (1 << 30)
}
