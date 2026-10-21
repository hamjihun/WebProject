//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"golang.org/x/sys/windows/registry"
)

// Browser policies: downloads go to the personal DocVault drive by default.
// Set as recommended (not mandatory) policies, so a user may still pick
// another folder in the browser's settings (administrators may want the
// desktop); for regular users a download finished on the PC itself is
// deleted by the agent anyway.
var browserPolicyKeys = []string{
	`SOFTWARE\Policies\Google\Chrome`,
	`SOFTWARE\Policies\Microsoft\Edge`,
	`SOFTWARE\Policies\Naver\Whale`,
}

// downloadDrive asks the server for the personal drive letter.
func downloadDrive(server string) string {
	c := &http.Client{Timeout: 10 * time.Second}
	resp, err := c.Get(server + "/api/setup-info")
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	var info struct{ DownloadDrive string }
	if json.NewDecoder(resp.Body).Decode(&info) != nil {
		return ""
	}
	l := strings.ToUpper(strings.TrimSuffix(info.DownloadDrive, ":"))
	if len(l) != 1 || l[0] < 'D' || l[0] > 'Z' {
		return ""
	}
	return l
}

func setBrowserPolicies(server string) {
	l := downloadDrive(server)
	if l == "" {
		fmt.Println("      서버에서 개인문서함 드라이브를 찾지 못해 건너뜁니다.")
		return
	}
	removeBrowserPolicies() // also the mandatory ones of versions before 0.8.2
	for _, key := range browserPolicyKeys {
		k, _, err := registry.CreateKey(registry.LOCAL_MACHINE, key+`\Recommended`, registry.SET_VALUE|registry.WOW64_64KEY)
		if err != nil {
			continue
		}
		k.SetStringValue("DownloadDirectory", l+`:\`)
		k.Close()
	}
	fmt.Printf("      크롬·엣지·웨일 기본 다운로드 위치: %s:\\ (개인문서함, 브라우저 설정에서 바꿀 수 있음)\n", l)
}

func removeBrowserPolicies() {
	for _, key := range browserPolicyKeys {
		removePolicyValues(key + `\Recommended`)
		removePolicyValues(key)
	}
}

func removePolicyValues(key string) {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, key, registry.SET_VALUE|registry.QUERY_VALUE|registry.WOW64_64KEY)
	if err != nil {
		return
	}
	k.DeleteValue("DownloadDirectory")
	k.DeleteValue("PromptForDownloadLocation")
	names, _ := k.ReadValueNames(0)
	subs, _ := k.ReadSubKeyNames(0)
	k.Close()
	if len(names) == 0 && len(subs) == 0 {
		registry.DeleteKey(registry.LOCAL_MACHINE, key)
	}
}

// Explorer's right-click menu on files: "DocVault 반출 신청".
const exportMenuKey = `SOFTWARE\Classes\*\shell\DocVaultExport`

func addExportMenu(agent string) {
	k, _, err := registry.CreateKey(registry.LOCAL_MACHINE, exportMenuKey, registry.SET_VALUE|registry.WOW64_64KEY)
	if err != nil {
		return
	}
	k.SetStringValue("", "DocVault 반출 신청")
	k.SetStringValue("Icon", `"`+agent+`",0`)
	k.Close()
	c, _, err := registry.CreateKey(registry.LOCAL_MACHINE, exportMenuKey+`\command`, registry.SET_VALUE|registry.WOW64_64KEY)
	if err != nil {
		return
	}
	c.SetStringValue("", `"`+agent+`" export "%1"`)
	c.Close()
}

func removeExportMenu() {
	registry.DeleteKey(registry.LOCAL_MACHINE, exportMenuKey+`\command`)
	registry.DeleteKey(registry.LOCAL_MACHINE, exportMenuKey)
}
