// Package buildinfo holds the release version shared by the PC agent and
// its installer, which PCs use to update themselves from the server.
package buildinfo

import (
	"bytes"
	"strconv"
	"strings"
)

const Version = "0.9.10"

// SetupMarkerPrefix starts the "DVSETUPVER:<version>;" text embedded in
// docvault-setup.exe, from which the server reads the version it offers.
const SetupMarkerPrefix = "DVSETUPVER:"

// NewerThan reports whether version a (like "0.7.0") is newer than b.
// Anything unreadable counts as 0.
func NewerThan(a, b string) bool {
	pa, pb := parts(a), parts(b)
	for i := range pa {
		if pa[i] != pb[i] {
			return pa[i] > pb[i]
		}
	}
	return false
}

func parts(v string) (p [3]int) {
	for i, s := range strings.SplitN(strings.TrimSpace(v), ".", 3) {
		p[i], _ = strconv.Atoi(s)
	}
	return p
}

// VersionIn finds the version marker in an installer file's contents. The
// bare prefix may occur elsewhere in the program too; only "<prefix>1.2.3;"
// counts.
func VersionIn(b []byte) string {
	for {
		i := bytes.Index(b, []byte(SetupMarkerPrefix))
		if i < 0 {
			return ""
		}
		b = b[i+len(SetupMarkerPrefix):]
		n := 0
		for n < len(b) && n < 20 && (b[n] == '.' || b[n] >= '0' && b[n] <= '9') {
			n++
		}
		if n > 0 && n < len(b) && b[n] == ';' {
			return string(b[:n])
		}
	}
}
