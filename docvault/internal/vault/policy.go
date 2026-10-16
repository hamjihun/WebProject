package vault

import "strings"

// Programs whose reads of DocVault drive files the PC agent refuses.
var (
	// Copying out to the PC: Explorer copy/drag, command-line copy, archivers.
	copyOutProcesses = []string{"explorer.exe", "cmd.exe", "powershell.exe", "pwsh.exe", "robocopy.exe", "xcopy.exe",
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

// RecordBlocked logs a refusal reported by the PC agent.
func (v *Vault) RecordBlocked(a Actor, kind, proc, drive, p string) {
	action := map[string]string{"copy": "block_copy", "messenger": "block_messenger", "upload": "block_upload"}[kind]
	if action == "" {
		action = "block_custom"
	}
	v.Audit(a, action, drive, p, proc+" 의 파일 읽기 차단")
}
