package main

// Program blocking: the server decides which programs may not read files on
// the DocVault drives (e.g. KakaoTalk.exe, Explorer copying to the desktop).
// The agent writes that list to policy.json, which the drive program reads;
// the drive program reports each refusal in events-<letter>.jsonl, which the
// agent turns into a notice for the user and an entry in the server's log.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func policyPath() string              { return filepath.Join(stateDir(), "policy.json") }
func eventsPath(letter string) string { return filepath.Join(stateDir(), "events-"+letter+".jsonl") }

// notifyBlocked tells the user that a program was refused; the Windows tray
// app replaces it with a notification balloon.
var notifyBlocked = func(title, text string) { log.Printf("%s: %s", title, text) }

// notifyBlockedPopup shows a modal popup window (not just a balloon), used
// for PC-copy and PC-download blocks the user must notice. Rate-limited so a
// burst of blocked files shows one popup. The Windows tray app replaces it.
var notifyBlockedPopup = func(title, text string) { log.Printf("%s: %s", title, text) }

func (a *agent) updatePolicy() {
	var p struct {
		Block         map[string]string `json:"block"`
		Watch         []string          `json:"watch"`
		DocWatch      []string          `json:"docWatch"`
		CopyWatch     bool              `json:"copyWatch"`
		BlockDownload bool              `json:"blockDownload"`
	}
	if err := a.client.call("GET", "/api/agent/policy", nil, &p); err != nil {
		if err == errUnauthorized {
			a.copyWatch.Store(false)
			a.blockDownload.Store(false)
		}
		return
	}
	a.copyWatch.Store(p.CopyWatch)
	a.blockDownload.Store(p.BlockDownload)
	if p.Block == nil {
		p.Block = map[string]string{}
	}
	b, _ := json.Marshal(map[string]any{"block": p.Block, "watch": p.Watch, "docWatch": p.DocWatch})
	if old, err := os.ReadFile(policyPath()); err == nil && bytes.Equal(old, b) {
		return
	}
	os.MkdirAll(stateDir(), 0o700)
	tmp := policyPath() + ".tmp"
	if os.WriteFile(tmp, b, 0o600) == nil {
		os.Rename(tmp, policyPath())
	}
}

type blockEvent struct {
	Time int64  `json:"time"`
	Proc string `json:"proc"`
	Kind string `json:"kind"`
	Path string `json:"path"`
	Size int64  `json:"size"`
	FH   uint64 `json:"fh"`
}

// watchEvents follows the refusal logs of all drives.
func (a *agent) watchEvents() {
	offsets := map[string]int64{}
	for range time.Tick(300 * time.Millisecond) {
		files, _ := filepath.Glob(filepath.Join(stateDir(), "events-*.jsonl"))
		for _, f := range files {
			letter := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(f), "events-"), ".jsonl")
			st, err := os.Stat(f)
			if err != nil {
				continue
			}
			off, seen := offsets[f]
			if !seen || st.Size() < off {
				// File new to us: older lines were already handled (or are from
				// a previous run), start at its end... unless it was just created.
				if !seen && time.Since(st.ModTime()) > 5*time.Second {
					offsets[f] = st.Size()
					continue
				}
				off = 0
			}
			if st.Size() == off {
				offsets[f] = off
				continue
			}
			fh, err := os.Open(f)
			if err != nil {
				continue
			}
			fh.Seek(off, io.SeekStart)
			sc := bufio.NewScanner(fh)
			for sc.Scan() {
				var ev blockEvent
				if json.Unmarshal(sc.Bytes(), &ev) == nil {
					switch ev.Kind {
					case "export-read":
						a.noteExportRead(ev.Size)
					case "doc-open":
						a.noteDocOpen(ev.FH)
					case "doc-close":
						a.noteDocClose(ev.FH)
					default:
						a.reportBlocked(letter, ev)
					}
				}
			}
			pos, _ := fh.Seek(0, io.SeekCurrent)
			fh.Close()
			offsets[f] = pos
		}
	}
}

var lastNotice time.Time

func (a *agent) reportBlocked(letter string, ev blockEvent) {
	a.mu.Lock()
	drive := letter + ":"
	if m := a.mounts[letter]; m != nil {
		drive = m.drive.Name
	}
	a.mu.Unlock()
	log.Printf("차단: %s 가 %s:%s 읽기 시도", ev.Proc, letter, ev.Path)
	a.client.call("POST", "/api/agent/event", map[string]string{"kind": ev.Kind, "proc": ev.Proc, "drive": drive, "path": ev.Path}, nil)

	if time.Since(lastNotice) < 5*time.Second {
		return
	}
	lastNotice = time.Now()
	name := filepath.Base(ev.Path)
	switch ev.Kind {
	case "messenger":
		notifyBlocked("메신저 첨부가 차단되었습니다",
			"문서함 파일("+name+")은 메신저("+ev.Proc+")로 보낼 수 없습니다.\n외부로 보내야 하면 웹에서 반출 신청을 하세요.")
	case "copy":
		notifyBlocked("PC로 복사가 차단되었습니다",
			"문서함 파일("+name+")은 바탕화면 등 PC로 복사할 수 없습니다.\n필요하면 웹에서 반출 신청을 하세요.")
	case "upload":
		notifyBlocked("웹 업로드가 차단되었습니다",
			"문서함 파일("+name+")은 웹브라우저로 올릴 수 없습니다.\n필요하면 웹에서 반출 신청을 하세요.")
	default:
		notifyBlocked("파일 사용이 차단되었습니다",
			ev.Proc+" 프로그램은 문서함 파일("+name+")을 열 수 없습니다.")
	}
}
