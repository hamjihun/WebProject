package main

// 이전 버전 보기/되돌리기: 탐색기 오른쪽 클릭 → "DocVault 이전 버전" 메뉴가
// "docvault-agent.exe versions <file>" 을 실행한다. 저장할 때마다 서버가 쌓아둔
// 이전 버전 목록을 보여주고, 고른 버전으로 되돌린다(되돌리기도 새 버전으로
// 기록되므로 기존 내용은 사라지지 않는다).

import (
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// verInfo mirrors vault.Version as returned by /api/files/versions.
type verInfo struct {
	ID        int64  `json:"id"`
	Size      int64  `json:"size"`
	CreatedAt int64  `json:"createdAt"`
	CreatedBy string `json:"createdBy"`
	Note      string `json:"note"`
	Current   bool   `json:"current"`
}

// driveTarget maps a file on a DocVault drive (e.g. O:\견적\a.xlsx) to its drive
// and server path. Unlike exportTarget it accepts any file on a drive, the 반출
// folder included.
func driveTarget(c *client, local string) (Drive, string, error) {
	local = filepath.Clean(local)
	if len(local) < 4 || local[1] != ':' {
		return Drive{}, "", errNotOnDrive
	}
	letter := strings.ToUpper(local[:1])
	var drives []Drive
	if err := c.call("GET", "/api/me/drives", nil, &drives); err != nil {
		return Drive{}, "", err
	}
	for _, d := range drives {
		if strings.EqualFold(d.DriveLetter, letter) {
			return d, strings.ReplaceAll(local[2:], `\`, "/"), nil
		}
	}
	return Drive{}, "", errNotOnDrive
}

func fetchVersions(c *client, d Drive, p string) ([]verInfo, error) {
	q := url.Values{"share": {d.Name}, "path": {p}}
	var out []verInfo
	err := c.call("GET", "/api/files/versions?"+q.Encode(), nil, &out)
	return out, err
}

func restoreVersionReq(c *client, d Drive, p string, id int64) error {
	return c.call("POST", "/api/files/versions/restore", map[string]any{"share": d.Name, "path": p, "id": id}, nil)
}

// verLabel is one row in the version list, e.g.
// "2026-10-22 14:30   1.2 MB   홍길동   (현재)".
func verLabel(v verInfo) string {
	when := time.Unix(v.CreatedAt, 0).Format("2006-01-02 15:04")
	row := when + "   " + humanSize(v.Size)
	if v.CreatedBy != "" {
		row += "   " + v.CreatedBy
	}
	if v.Current {
		row += "   (현재)"
	}
	if v.Note != "" {
		row += "   · " + v.Note
	}
	return row
}

func humanSize(n int64) string {
	const u = 1024
	i64 := func(v int64) string { return strconv.FormatInt(v, 10) }
	switch {
	case n < u:
		return i64(n) + " B"
	case n < u*u:
		return i64(n/u) + " KB"
	case n < u*u*u:
		return i64(n*10/(u*u)/10) + "." + i64(n*10/(u*u)%10) + " MB"
	default:
		return i64(n*10/(u*u*u)/10) + "." + i64(n*10/(u*u*u)%10) + " GB"
	}
}
