//go:build cmount && linux && cgo

package cmount

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// exeName returns the lower-case executable file name of a process plus
// ".exe", so block lists written for Windows can be tested on Linux.
func exeName(pid int) string {
	p, err := os.Readlink("/proc/" + strconv.Itoa(pid) + "/exe")
	if err != nil {
		return ""
	}
	return strings.ToLower(filepath.Base(p)) + ".exe"
}
