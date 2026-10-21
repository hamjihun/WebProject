package main

// 반출 신청 from Explorer: the right-click menu runs
// "docvault-agent.exe export <file>", which asks for a reason and files the
// request. Once approved, the file appears in 개인문서함\반출, from where it
// may be taken out of the system.

import (
	"errors"
	"path/filepath"
	"strings"
)

// exportTarget maps a file on a DocVault drive (e.g. O:\견적\a.xlsx) to its
// drive and path on the server.
func exportTarget(c *client, local string) (Drive, string, error) {
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
			p := strings.ReplaceAll(local[2:], `\`, "/")
			if d.Personal && (strings.EqualFold(p, "/"+exportFolder) || strings.HasPrefix(strings.ToLower(p), strings.ToLower("/"+exportFolder+"/"))) {
				return d, p, errAlreadyExported
			}
			return d, p, nil
		}
	}
	return Drive{}, "", errNotOnDrive
}

var (
	errNotOnDrive      = errors.New("DocVault 문서함 드라이브에 있는 파일만 반출 신청할 수 있습니다.")
	errAlreadyExported = errors.New("반출 폴더의 파일은 이미 반출 승인된 파일입니다.\n바탕화면 등 PC로 바로 복사할 수 있습니다.")
)

func requestExport(c *client, d Drive, p, reason string) error {
	return c.call("POST", "/api/exports", map[string]string{"share": d.Name, "path": p, "reason": reason}, nil)
}

const exportDoneText = "반출 신청했습니다.\n\n결재자가 승인하면 개인문서함의 [" + exportFolder + "] 폴더에 파일이 들어갑니다.\n그 폴더의 파일은 바탕화면 등 PC로 복사할 수 있습니다.\n\n진행 상황은 웹 문서함 → 반출에서 볼 수 있습니다."
