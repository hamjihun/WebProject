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

// Browser policies: downloads go to the personal DocVault drive and the
// browser does not ask where to save. Applies to every user of the PC.
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
	for _, key := range browserPolicyKeys {
		k, _, err := registry.CreateKey(registry.LOCAL_MACHINE, key, registry.SET_VALUE|registry.WOW64_64KEY)
		if err != nil {
			continue
		}
		k.SetStringValue("DownloadDirectory", l+`:\`)
		k.SetDWordValue("PromptForDownloadLocation", 0)
		k.Close()
	}
	fmt.Printf("      크롬·엣지·웨일 다운로드 위치: %s:\\ (개인문서함)\n", l)
}

func removeBrowserPolicies() {
	for _, key := range browserPolicyKeys {
		k, err := registry.OpenKey(registry.LOCAL_MACHINE, key, registry.SET_VALUE|registry.QUERY_VALUE|registry.WOW64_64KEY)
		if err != nil {
			continue
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
}
