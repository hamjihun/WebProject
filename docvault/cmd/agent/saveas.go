package main

// "Save As to the PC" redirect. While a document program (Excel, Word, 한글,
// …) has a confidential file open — reported by the drive program as
// doc-open/doc-close — any document it saves onto a local disk (e.g.
// [다른 이름으로 저장] to the desktop) is moved into the user's 개인문서함 and
// a popup tells the user to save there. The file is not lost.

import (
	"bytes"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// RedirectFolder is where redirected PC saves land inside 개인문서함.
const redirectFolder = "PC에서_옮김"

const docHandleTTL = 12 * time.Hour // recover if a close event is ever missed

var docSession = struct {
	sync.Mutex
	open map[uint64]time.Time
}{open: map[uint64]time.Time{}}

func (a *agent) noteDocOpen(fh uint64) {
	docSession.Lock()
	docSession.open[fh] = time.Now()
	docSession.Unlock()
}

func (a *agent) noteDocClose(fh uint64) {
	docSession.Lock()
	delete(docSession.open, fh)
	docSession.Unlock()
}

// docActive reports whether a document program currently holds a confidential
// file open.
func (a *agent) docActive() bool {
	docSession.Lock()
	defer docSession.Unlock()
	for fh, t := range docSession.open {
		if time.Since(t) > docHandleTTL {
			delete(docSession.open, fh)
			continue
		}
		return true
	}
	return false
}

// documentExts are the file types treated as "documents" for the redirect.
var documentExts = map[string]bool{
	"xlsx": true, "xls": true, "xlsm": true, "xlsb": true, "csv": true,
	"docx": true, "doc": true, "docm": true, "rtf": true, "txt": true,
	"pptx": true, "ppt": true, "pptm": true,
	"hwp": true, "hwpx": true, "hml": true,
	"pdf": true, "odt": true, "ods": true, "odp": true,
}

func isDocumentFile(path string) bool {
	ext := strings.ToLower(path[strings.LastIndex(path, ".")+1:])
	return documentExts[ext]
}

// redirectSave moves a document saved on the PC into 개인문서함 and removes the
// local copy. It returns true when the file still needs another look later.
func (a *agent) redirectSave(path string) (retry bool) {
	st, err := os.Stat(path)
	if err != nil || !st.Mode().IsRegular() || st.Size() <= 0 || st.Size() > copyMaxSize {
		return false
	}
	drive := a.personalDriveName()
	if drive == "" {
		return true // drives not connected yet
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return !os.IsNotExist(err) // still being written / locked
	}
	if st2, err := os.Stat(path); err != nil || st2.Size() != st.Size() || !st2.ModTime().Equal(st.ModTime()) {
		return err == nil // changed while reading
	}
	name := filepath.Base(path)
	if err := a.uploadToVault(drive, name, b); err != nil {
		log.Printf("개인문서함으로 이동 실패 %s: %v", path, err)
		return true // keep the file and try again (do not lose it)
	}
	if err := removeCopy(path); err != nil {
		return true
	}
	log.Printf("PC에 저장된 문서를 개인문서함으로 이동: %s", path)
	notifyBlockedPopup("PC에 문서를 저장할 수 없습니다",
		"문서는 PC(바탕화면 등)에 저장할 수 없습니다.\n"+name+" 파일을 개인문서함의 ["+redirectFolder+"] 폴더로 옮겼습니다.\n\n문서는 개인문서함(드라이브)에 저장하세요.")
	return false
}

// uploadToVault PUTs the bytes into 개인문서함\PC에서_옮김 (a free name).
func (a *agent) uploadToVault(drive, name string, data []byte) error {
	// Make sure the destination folder exists (idempotent).
	mk, _ := http.NewRequest("MKCOL", a.cfg.Server+"/dav/"+url.PathEscape(drive)+"/"+url.PathEscape(redirectFolder), nil)
	mk.Header.Set("Authorization", "Bearer "+a.client.token)
	if resp, err := a.client.http.Do(mk); err == nil {
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
	}
	base, ext := name, ""
	if i := strings.LastIndex(name, "."); i > 0 {
		base, ext = name[:i], name[i:]
	}
	for i := 0; i < 100; i++ {
		leaf := name
		if i > 0 {
			leaf = base + " (" + itoa(i+1) + ")" + ext
		}
		u := a.cfg.Server + "/dav/" + url.PathEscape(drive) + "/" + url.PathEscape(redirectFolder) + "/" + url.PathEscape(leaf)
		if a.davExists(u) {
			continue // name taken: try the next
		}
		req, _ := http.NewRequest("PUT", u, bytes.NewReader(data))
		req.Header.Set("Authorization", "Bearer "+a.client.token)
		resp, err := a.client.http.Do(req)
		if err != nil {
			return err
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		switch resp.StatusCode {
		case http.StatusCreated, http.StatusNoContent, http.StatusOK:
			return nil
		default:
			return &httpError{resp.StatusCode}
		}
	}
	return &httpError{0}
}

// davExists reports whether a file already exists at the WebDAV URL.
func (a *agent) davExists(u string) bool {
	req, _ := http.NewRequest("HEAD", u, nil)
	req.Header.Set("Authorization", "Bearer "+a.client.token)
	resp, err := a.client.http.Do(req)
	if err != nil {
		return false
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

type httpError struct{ code int }

func (e *httpError) Error() string { return "업로드 실패 (" + itoa(e.code) + ")" }

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
