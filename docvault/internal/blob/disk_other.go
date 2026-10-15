//go:build !windows

package blob

import "syscall"

// DiskSpace reports the total and free bytes of the disk holding the store.
func (s *Store) DiskSpace() (total, free uint64, err error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(s.root, &st); err != nil {
		return 0, 0, err
	}
	bs := uint64(st.Bsize)
	return uint64(st.Blocks) * bs, uint64(st.Bavail) * bs, nil
}
