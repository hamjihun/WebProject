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
//
// Files under the folder named by DOCVAULT_ALLOW (the export folder of the
// personal drive, holding approved exports) are never refused.

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
	allow      string // lower-case folder (no slashes) whose files stay readable
	eventsPath string
	block      map[string]string // lower-case exe name -> kind
	watch      map[string]bool   // lower-case exe name: report its reads of the allow folder
	docWatch   map[string]bool   // lower-case exe name: document programs (report open/close)
	docHandles map[uint64]bool   // handles a document program holds open
	policyMod  time.Time
	checked    time.Time
	procs      map[int]dvProc
	marked     map[uint64]string // file handle -> "exe|kind"
	reported   map[uint64]bool
}{
	policyPath: os.Getenv("DOCVAULT_POLICY"),
	allow:      strings.ToLower(strings.Trim(os.Getenv("DOCVAULT_ALLOW"), "/")),
	eventsPath: os.Getenv("DOCVAULT_EVENTS"),
	block:      map[string]string{},
	watch:      map[string]bool{},
	docWatch:   map[string]bool{},
	docHandles: map[uint64]bool{},
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
		Block    map[string]string `json:"block"`
		Watch    []string          `json:"watch"`
		DocWatch []string          `json:"docWatch"`
	}
	if json.Unmarshal(b, &p) != nil {
		return
	}
	block := map[string]string{}
	for k, v := range p.Block {
		block[strings.ToLower(k)] = v
	}
	watch := map[string]bool{}
	for _, k := range p.Watch {
		watch[strings.ToLower(k)] = true
	}
	docWatch := map[string]bool{}
	for _, k := range p.DocWatch {
		docWatch[strings.ToLower(k)] = true
	}
	dv.block, dv.watch, dv.docWatch, dv.policyMod = block, watch, docWatch, st.ModTime()
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

// dvInAllow reports a path inside (or equal to) the export folder.
func dvInAllow(path string) bool {
	if dv.allow == "" {
		return false
	}
	low := strings.ToLower(strings.TrimLeft(path, "/"))
	return low == dv.allow || strings.HasPrefix(low, dv.allow+"/")
}

func dvIsAllowRoot(path string) bool {
	return dv.allow != "" && strings.ToLower(strings.Trim(path, "/")) == dv.allow
}

// dvWriteLocked: nothing may be added to or changed in the export folder
// (the server refuses it too) except Office lock and temporary files.
func dvWriteLocked(path string) bool {
	if !dvInAllow(path) || dvIsAllowRoot(path) {
		return false
	}
	name := strings.ToLower(path[strings.LastIndex(path, "/")+1:])
	return !(strings.HasPrefix(name, "~$") || strings.HasSuffix(name, ".tmp"))
}

func dvOnOpen(path string, fi *fuse.FileInfo_t, size int64) {
	_, _, pid := fuse.Getcontext()
	dv.mu.Lock()
	defer dv.mu.Unlock()
	reloadPolicy()
	if len(dv.block) == 0 && len(dv.watch) == 0 && len(dv.docWatch) == 0 {
		return
	}
	name := procName(pid)
	if dv.docWatch[name] && !dvInAllow(path) {
		// A document program (Excel, Word, ...) opened a confidential file.
		// While it holds the file open, the agent moves any document saved to
		// the PC into the vault (catches [다른 이름으로 저장] to the desktop).
		dv.docHandles[fi.Fh] = true
		dvDocEvent("doc-open", fi.Fh)
	}
	if dvInAllow(path) {
		// A copy-capable program read a file in the 반출 folder: report it so
		// the agent lets a matching copy on the PC stay (only that file may
		// leave; the identical original elsewhere may not).
		if dv.watch[name] {
			dvExportRead(size)
		}
		return
	}
	kind, ok := dv.block[name]
	if !ok {
		return
	}
	fi.DirectIo = true // bypass the Windows cache so the read check always runs
	dv.marked[fi.Fh] = name + "|" + kind
}

// dvExportRead records that an approved (반출 folder) file of this size was
// just served to a copy-capable program.
func dvExportRead(size int64) {
	if dv.eventsPath == "" || size <= 0 {
		return
	}
	line, _ := json.Marshal(map[string]any{"time": time.Now().Unix(), "kind": "export-read", "size": size})
	dvEventMu.Lock()
	defer dvEventMu.Unlock()
	f, err := os.OpenFile(dv.eventsPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	f.Write(append(line, '\n'))
	f.Close()
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
	wasDoc := dv.docHandles[fh]
	delete(dv.docHandles, fh)
	delete(dv.marked, fh)
	delete(dv.reported, fh)
	dv.mu.Unlock()
	if wasDoc {
		dvDocEvent("doc-close", fh)
	}
}

// dvDocEvent reports that a document program opened or closed a confidential
// file, so the agent knows whether a PC document save should be redirected.
func dvDocEvent(kind string, fh uint64) {
	if dv.eventsPath == "" {
		return
	}
	line, _ := json.Marshal(map[string]any{"time": time.Now().Unix(), "kind": kind, "fh": fh})
	dvEventMu.Lock()
	defer dvEventMu.Unlock()
	f, err := os.OpenFile(dv.eventsPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	f.Write(append(line, '\n'))
	f.Close()
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
