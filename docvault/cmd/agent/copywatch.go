package main

// Copy-out removal: Explorer cannot be refused reads of drive files (it is
// also the desktop and taskbar and hangs when its reads fail), so copies it
// makes are removed afterwards instead. The agent watches the user's folders
// and USB drives; for each new or changed file it asks the server whether the
// content is a drive file the user may not take out, and deletes it if so.

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	copySettle   = 2 * time.Second // wait until the file stops changing
	copyMaxTries = 30              // file still being written / locked
	copyMaxSize  = 4 << 30
)

type copyPending struct {
	last  time.Time
	tries int
}

var copyQueue = struct {
	sync.Mutex
	m map[string]*copyPending
}{m: map[string]*copyPending{}}

// noteLocalChange is called by the folder watchers for every new or changed
// file on the PC.
func (a *agent) noteLocalChange(path string) {
	if !a.copyWatch.Load() || skipLocal(path) {
		return
	}
	copyQueue.Lock()
	if p := copyQueue.m[path]; p != nil {
		p.last = time.Now()
	} else if len(copyQueue.m) < 10000 {
		copyQueue.m[path] = &copyPending{last: time.Now()}
	}
	copyQueue.Unlock()
}

// skipLocal leaves out Windows, programs, program data, temporary and
// partial files.
func skipLocal(path string) bool {
	low := strings.ToLower(path)
	if len(low) > 3 && low[1] == ':' {
		for _, dir := range []string{`\windows\`, `\windows.old\`, `\program files`, `\programdata\`, `\$`, `\msocache\`, `\intel\`, `\perflogs\`} {
			if strings.HasPrefix(low[2:], dir) {
				return true
			}
		}
	}
	if strings.Contains(low, `\appdata\`) || strings.Contains(low, "/appdata/") ||
		strings.Contains(low, `\$recycle.bin`) || strings.Contains(low, `\system volume information`) {
		return true
	}
	name := low[strings.LastIndexAny(low, `\/`)+1:]
	if strings.HasPrefix(name, "~$") || strings.HasPrefix(name, ".") || strings.HasPrefix(name, "~") {
		return true
	}
	switch name[strings.LastIndex(name, ".")+1:] {
	case "tmp", "temp", "crdownload", "part", "partial", "download", "lnk", "url", "ini", "lock":
		return true
	}
	return false
}

// copyWatchLoop processes files that have settled.
func (a *agent) copyWatchLoop() {
	for range time.Tick(time.Second) {
		var ready []string
		copyQueue.Lock()
		for p, e := range copyQueue.m {
			if time.Since(e.last) >= copySettle {
				ready = append(ready, p)
			}
		}
		copyQueue.Unlock()
		for _, p := range ready {
			retry := a.copyWatch.Load() && a.checkLocal(p)
			copyQueue.Lock()
			if e := copyQueue.m[p]; e != nil {
				if retry && e.tries < copyMaxTries {
					e.tries++
					e.last = time.Now()
				} else {
					delete(copyQueue.m, p)
				}
			}
			copyQueue.Unlock()
		}
	}
}

// checkLocal checks one file and removes it when it is a copy of a drive
// file. It returns true when the file should be looked at again later.
func (a *agent) checkLocal(path string) (retry bool) {
	st, err := os.Stat(path)
	if err != nil || !st.Mode().IsRegular() || st.Size() <= 0 || st.Size() > copyMaxSize {
		return false
	}
	var pre struct{ Maybe bool }
	if err := a.client.call("POST", "/api/agent/copy-check", map[string]any{"sha256": "", "size": st.Size()}, &pre); err != nil {
		return err != errUnauthorized
	}
	if !pre.Maybe {
		return false
	}
	f, err := os.Open(path)
	if err != nil {
		return !os.IsNotExist(err) // still being written by the copier
	}
	h := sha256.New()
	_, err = io.Copy(h, f)
	f.Close()
	if err != nil {
		return true
	}
	if st2, err := os.Stat(path); err != nil || st2.Size() != st.Size() || !st2.ModTime().Equal(st.ModTime()) {
		return err == nil // changed while hashing
	}
	var res struct {
		Block       bool
		Drive, Path string
	}
	if err := a.client.call("POST", "/api/agent/copy-check",
		map[string]any{"sha256": hex.EncodeToString(h.Sum(nil)), "size": st.Size(), "local": path}, &res); err != nil {
		return err != errUnauthorized
	}
	if !res.Block {
		return false
	}
	if err := removeCopy(path); err != nil {
		log.Printf("복사본 삭제 실패 %s: %v", path, err)
		return true
	}
	log.Printf("PC로 복사된 문서함 파일 삭제: %s (%s %s)", path, res.Drive, res.Path)
	if time.Since(lastNotice) >= 5*time.Second {
		lastNotice = time.Now()
		notifyBlocked("PC로 복사가 차단되었습니다",
			"문서함 파일("+filepath.Base(path)+")은 바탕화면 등 PC로 복사할 수 없어 삭제했습니다.\n필요하면 웹에서 반출 신청을 하세요.")
	}
	return false
}

func removeCopy(path string) error {
	os.Chmod(path, 0o600) // clear read-only
	return os.Remove(path)
}

func isNotExist(err error) bool { return os.IsNotExist(err) }
