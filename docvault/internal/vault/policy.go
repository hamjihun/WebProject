package vault

import "strings"

// Programs whose reads of DocVault drive files the PC agent refuses.
//
// Explorer is deliberately not here: it is also the desktop and taskbar, and
// refusing its reads (thumbnails, right-click menus, properties) hangs it.
// Explorer copies are caught after the fact instead: the agent watches the
// PC's folders and USB drives and asks CopyCheck about each new file.
var (
	// Copying out to the PC: command-line copy, archivers.
	copyOutProcesses = []string{"cmd.exe", "powershell.exe", "pwsh.exe", "robocopy.exe", "xcopy.exe",
		"bandizip.exe", "bz.exe", "alzip.exe", "7zfm.exe", "7zg.exe", "7z.exe", "winrar.exe", "rar.exe",
		"winzip32.exe", "winzip64.exe"}
	messengerProcesses = []string{"kakaotalk.exe", "telegram.exe", "line.exe", "whatsapp.exe", "discord.exe"}
	browserProcesses   = []string{"chrome.exe", "msedge.exe", "whale.exe", "firefox.exe", "iexplore.exe"}
)

// Policy is the block list the PC agent applies for user u: exe name -> kind
// (copy, messenger, upload, custom).
// Administrators are never blocked.
func (v *Vault) Policy(u *User) map[string]string {
	block := map[string]string{}
	if u.IsAdmin {
		return block
	}
	add := func(list []string, kind string) {
		for _, p := range list {
			block[p] = kind
		}
	}
	if v.Setting("block_copy_out") != 0 && !u.AllowCopy {
		add(copyOutProcesses, "copy")
	}
	if v.Setting("block_messenger") != 0 {
		add(messengerProcesses, "messenger")
	}
	if v.Setting("block_browser_upload") != 0 {
		add(browserProcesses, "upload")
	}
	for _, p := range strings.Split(v.StringSetting("block_extra_processes"), ",") {
		if p = strings.ToLower(strings.TrimSpace(p)); p != "" {
			if !strings.HasSuffix(p, ".exe") {
				p += ".exe"
			}
			block[p] = "custom"
		}
	}
	return block
}

// CopyWatch reports whether the agent should remove copies of drive files
// that appear on u's PC (Explorer copy/drag to the desktop, USB, ...).
func (v *Vault) CopyWatch(u *User) bool {
	return !u.IsAdmin && !u.AllowCopy && v.Setting("block_copy_out") != 0
}

// CopyCheck tells whether a file with this content (SHA-256 and size) that
// appeared on the user's PC is a copy of a drive file the user can see, and
// so must be removed. Files the user had approved for export are allowed.
// It returns the drive name and path of the matching file.
func (v *Vault) CopyCheck(u *User, sha string, size int64) (drive, p string, found bool) {
	if !v.CopyWatch(u) || size <= 0 || len(sha) != 64 {
		return "", "", false
	}
	var exported int
	v.DB.QueryRow(`SELECT COUNT(*) FROM exports e JOIN versions ver ON ver.id=e.version_id
		WHERE e.requester_id=? AND e.status IN ('approved','expired','post') AND ver.blob_sha=?`, u.ID, sha).Scan(&exported)
	if exported > 0 {
		return "", "", false
	}
	rows, err := v.DB.Query(`SELECT n.id, n.share_id, n.owner_id FROM nodes n
		WHERE n.blob_sha=? AND n.size=? AND n.is_dir=0 AND n.deleted_at IS NULL LIMIT 50`, strings.ToLower(sha), size)
	if err != nil {
		return "", "", false
	}
	type hit struct{ id, share, owner int64 }
	var hits []hit
	for rows.Next() {
		var h hit
		if rows.Scan(&h.id, &h.share, &h.owner) == nil {
			hits = append(hits, h)
		}
	}
	rows.Close()
	for _, h := range hits {
		s, err := v.ShareByID(h.share)
		if err != nil || v.Level(u, s) == LevelNone || (s.Personal && h.owner != u.ID) {
			continue
		}
		n, err := nodeByID(v.DB, h.id)
		if err != nil {
			continue
		}
		return s.Name, pathOf(v.DB, n), true
	}
	return "", "", false
}

// BlockDownload reports whether the agent should refuse browser downloads
// saved on the PC itself (they belong in the DocVault drives).
func (v *Vault) BlockDownload(u *User) bool {
	return !u.IsAdmin && !u.AllowCopy && v.Setting("block_download_local") != 0
}

// DownloadDrive is the drive letter browsers save downloads to: the
// personal drive.
func (v *Vault) DownloadDrive() string {
	if s := v.personalShare(); s != nil {
		return s.DriveLetter
	}
	return ""
}

// CopySizeKnown is a cheap first test for CopyCheck: whether any drive file
// has this size, so the agent need not hash every new file on the PC.
func (v *Vault) CopySizeKnown(u *User, size int64) bool {
	if !v.CopyWatch(u) || size <= 0 {
		return false
	}
	var one int
	return v.DB.QueryRow(`SELECT 1 FROM nodes WHERE size=? AND is_dir=0 AND deleted_at IS NULL LIMIT 1`, size).Scan(&one) == nil
}

// RecordBlocked logs a refusal reported by the PC agent.
func (v *Vault) RecordBlocked(a Actor, kind, proc, drive, p string) {
	action := map[string]string{"copy": "block_copy", "messenger": "block_messenger", "upload": "block_upload", "download": "block_download"}[kind]
	if action == "" {
		action = "block_custom"
	}
	detail := proc + " 의 파일 읽기 차단"
	if kind == "download" {
		detail = "웹브라우저 다운로드를 PC에 저장 → 삭제"
	}
	v.Audit(a, action, drive, p, detail)
}
