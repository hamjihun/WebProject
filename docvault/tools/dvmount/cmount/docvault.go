//go:build cmount && (windows || (linux && cgo))

package cmount

// DocVault: refuse to hand file contents to programs on a block list.
//
// The DocVault agent writes the list to the file named by DOCVAULT_POLICY:
//
//	{"block": {"kakaotalk.exe": "messenger", "explorer.exe": "copy"}}
//
// When a blocked program opens a file, the handle is marked (and opened
// without the Windows cache, so every read reaches this code); its reads then
// fail with "access denied". Opening for delete or rename never reads, so
// those keep working. Each refusal is appended as a JSON line to the file
// named by DOCVAULT_EVENTS so the agent can tell the user and the server.

import (
	"encoding/json"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/winfsp/cgofuse/fuse"
)

type dvProc struct {
	name string
	at   time.Time
}

var dv = struct {
	mu         sync.Mutex
	policyPath string
	eventsPath string
	block      map[string]string // lower-case exe name -> kind
	policyMod  time.Time
	checked    time.Time
	procs      map[int]dvProc
	marked     map[uint64]string // file handle -> "exe|kind"
	reported   map[uint64]bool
}{
	policyPath: os.Getenv("DOCVAULT_POLICY"),
	eventsPath: os.Getenv("DOCVAULT_EVENTS"),
	block:      map[string]string{},
	procs:      map[int]dvProc{},
	marked:     map[uint64]string{},
	reported:   map[uint64]bool{},
}

// reloadPolicy re-reads the policy file when it changed (checked every 3s).
// Called with dv.mu held.
func reloadPolicy() {
	if dv.policyPath == "" || time.Since(dv.checked) < 3*time.Second {
		return
	}
	dv.checked = time.Now()
	st, err := os.Stat(dv.policyPath)
	if err != nil || st.ModTime().Equal(dv.policyMod) {
		return
	}
	b, err := os.ReadFile(dv.policyPath)
	if err != nil {
		return
	}
	var p struct {
		Block map[string]string `json:"block"`
	}
	if json.Unmarshal(b, &p) != nil {
		return
	}
	block := map[string]string{}
	for k, v := range p.Block {
		block[strings.ToLower(k)] = v
	}
	dv.block, dv.policyMod = block, st.ModTime()
}

// procName returns the lower-case executable name of a process, cached for
// 30 seconds. Called with dv.mu held.
func procName(pid int) string {
	if pid <= 4 {
		return ""
	}
	if p, ok := dv.procs[pid]; ok && time.Since(p.at) < 30*time.Second {
		return p.name
	}
	name := exeName(pid)
	if len(dv.procs) > 4096 {
		dv.procs = map[int]dvProc{}
	}
	dv.procs[pid] = dvProc{name, time.Now()}
	return name
}

func dvOnOpen(path string, fi *fuse.FileInfo_t) {
	_, _, pid := fuse.Getcontext()
	dv.mu.Lock()
	defer dv.mu.Unlock()
	reloadPolicy()
	if len(dv.block) == 0 {
		return
	}
	name := procName(pid)
	kind, ok := dv.block[name]
	if !ok {
		return
	}
	fi.DirectIo = true // bypass the Windows cache so the read check always runs
	dv.marked[fi.Fh] = name + "|" + kind
}

func dvCheckRead(path string, fh uint64) int {
	dv.mu.Lock()
	m, ok := dv.marked[fh]
	first := ok && !dv.reported[fh]
	if first {
		dv.reported[fh] = true
	}
	dv.mu.Unlock()
	if !ok {
		return 0
	}
	if first {
		name, kind, _ := strings.Cut(m, "|")
		dvEvent(name, kind, path)
	}
	return -fuse.EACCES
}

func dvOnRelease(fh uint64) {
	dv.mu.Lock()
	delete(dv.marked, fh)
	delete(dv.reported, fh)
	dv.mu.Unlock()
}

var dvEventMu sync.Mutex

func dvEvent(proc, kind, path string) {
	if dv.eventsPath == "" {
		return
	}
	line, _ := json.Marshal(map[string]any{"time": time.Now().Unix(), "proc": proc, "kind": kind, "path": path})
	dvEventMu.Lock()
	defer dvEventMu.Unlock()
	f, err := os.OpenFile(dv.eventsPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	f.Write(append(line, '\n'))
	f.Close()
}
