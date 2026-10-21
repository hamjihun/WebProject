package main

// Browser downloads saved on the PC: the installer points Chrome, Edge and
// Whale at the personal drive, but [다른 이름으로 저장] can still pick the
// desktop. Browsers write a download to "<name>.crdownload" (Firefox:
// ".part") and rename it when done; such a file appearing on a local disk
// gets a warning at once, and the finished file is deleted.

import (
	"log"
	"path/filepath"
	"strings"
	"time"
)

func isPartialDownload(path string) bool {
	low := strings.ToLower(path)
	return strings.HasSuffix(low, ".crdownload") || strings.HasSuffix(low, ".part")
}

// downloadSkipped leaves out program folders (e.g. a browser opening a file
// straight from its temporary folder, which stays allowed).
func downloadSkipped(path string) bool {
	return skipLocal(strings.TrimSuffix(strings.TrimSuffix(path, ".crdownload"), ".part") + ".x")
}

var downloadNoticeAt time.Time

func (a *agent) noteDownloadStarted(path string) {
	if !a.blockDownload.Load() || !isPartialDownload(path) || downloadSkipped(path) {
		return
	}
	if time.Since(downloadNoticeAt) < 5*time.Second {
		return
	}
	downloadNoticeAt = time.Now()
	notifyBlockedPopup("PC에 저장할 수 없습니다",
		"바탕화면 등 PC에는 파일을 저장할 수 없습니다.\nDocVault 문서함(개인문서함)에 저장하세요.")
}

// noteDownloadFinished deletes a download that finished on the PC.
func (a *agent) noteDownloadFinished(path string) {
	if !a.blockDownload.Load() || downloadSkipped(path) {
		return
	}
	go func() {
		var err error
		for i := 0; i < 30; i++ { // antivirus may hold it for a moment
			if err = removeCopy(path); err == nil || isNotExist(err) {
				break
			}
			time.Sleep(time.Second)
		}
		if err != nil && !isNotExist(err) {
			log.Printf("다운로드 파일 삭제 실패 %s: %v", path, err)
			return
		}
		log.Printf("PC에 저장된 다운로드 삭제: %s", path)
		a.client.call("POST", "/api/agent/event", map[string]string{"kind": "download", "proc": "browser", "drive": "PC", "path": path}, nil)
		downloadNoticeAt = time.Now()
		notifyBlockedPopup("PC에 저장할 수 없습니다",
			filepath.Base(path)+" 파일은 PC에 저장할 수 없습니다.\nDocVault 문서함(개인문서함)에 저장하세요.")
	}()
}
