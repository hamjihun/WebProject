// Package dav serves the drives over WebDAV. The PC agent mounts each drive
// (rclone + WinFsp) so it appears as a drive letter in Explorer; every open,
// save, rename and delete arrives here and goes through the vault's
// permission checks, versioning, trash and audit log.
package dav

import (
	"encoding/xml"
	"errors"
	"io"
	"mime"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"

	"docvault/internal/netutil"
	"docvault/internal/vault"
)

type Handler struct {
	V          *vault.Vault
	Prefix     string // e.g. "/dav"
	TrustProxy bool
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	u := h.authenticate(r)
	if u == nil {
		w.Header().Set("WWW-Authenticate", `Basic realm="DocVault"`)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	a := vault.Actor{User: u, IP: netutil.ClientIP(r, h.TrustProxy), Client: "drive"}
	share, p := h.split(r.URL.Path)

	switch r.Method {
	case "OPTIONS":
		w.Header().Set("Allow", "OPTIONS, PROPFIND, PROPPATCH, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY")
		w.Header().Set("DAV", "1")
		w.Header().Set("MS-Author-Via", "DAV")
		w.WriteHeader(http.StatusOK)
	case "PROPFIND":
		h.propfind(w, r, a, share, p)
	case "PROPPATCH":
		drain(r)
		h.proppatch(w, r, a, share, p)
	case "GET", "HEAD":
		h.get(w, r, a, share, p)
	case "PUT":
		if share == "" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		_, created, err := h.V.Put(a, share, p, r.Body)
		if err != nil {
			writeErr(w, err, http.StatusConflict)
			return
		}
		if created {
			w.WriteHeader(http.StatusCreated)
		} else {
			w.WriteHeader(http.StatusNoContent)
		}
	case "MKCOL":
		drain(r)
		if share == "" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		if err := h.V.Mkdir(a, share, p); err != nil {
			writeErr(w, err, http.StatusMethodNotAllowed)
			return
		}
		w.WriteHeader(http.StatusCreated)
	case "DELETE":
		if share == "" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		if err := h.V.Delete(a, share, p); err != nil {
			writeErr(w, err, http.StatusConflict)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case "MOVE", "COPY":
		h.moveCopy(w, r, a, share, p)
	default:
		w.Header().Set("Allow", "OPTIONS, PROPFIND, PROPPATCH, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (h *Handler) authenticate(r *http.Request) *vault.User {
	if tok := netutil.BearerToken(r); tok != "" {
		if u, _, err := h.V.Authenticate(tok); err == nil {
			return u
		}
		return nil
	}
	if user, pass, ok := r.BasicAuth(); ok {
		if u, err := h.V.AuthenticateBasic(user, pass); err == nil {
			return u
		}
	}
	return nil
}

// split turns "/dav/일산영업/a/b.xlsx" into ("일산영업", "/a/b.xlsx").
func (h *Handler) split(p string) (share, rest string) {
	p = strings.TrimPrefix(p, h.Prefix)
	p = strings.TrimPrefix(p, "/")
	share, rest, _ = strings.Cut(p, "/")
	return share, "/" + rest
}

func drain(r *http.Request) { io.Copy(io.Discard, io.LimitReader(r.Body, 1<<20)) }

func writeErr(w http.ResponseWriter, err error, existsStatus int) {
	switch {
	case errors.Is(err, vault.ErrNotFound):
		http.Error(w, "not found", http.StatusNotFound)
	case errors.Is(err, vault.ErrForbidden):
		http.Error(w, "forbidden", http.StatusForbidden)
	case errors.Is(err, vault.ErrUnauthorized):
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	case errors.Is(err, vault.ErrExists):
		http.Error(w, "already exists", existsStatus)
	case errors.Is(err, vault.ErrConflict), errors.Is(err, vault.ErrNotDir):
		http.Error(w, "conflict", http.StatusConflict)
	case errors.Is(err, vault.ErrIsDir):
		http.Error(w, "is a collection", http.StatusMethodNotAllowed)
	case errors.Is(err, vault.ErrQuota):
		http.Error(w, "insufficient storage", http.StatusInsufficientStorage)
	case errors.Is(err, vault.ErrInvalidName), errors.Is(err, vault.ErrBadRequest):
		http.Error(w, "bad request", http.StatusBadRequest)
	default:
		http.Error(w, "internal error", http.StatusInternalServerError)
	}
}

func (h *Handler) href(share, p string, dir bool) string {
	var b strings.Builder
	b.WriteString(h.Prefix)
	b.WriteString("/")
	if share != "" {
		b.WriteString(url.PathEscape(share))
		for _, seg := range strings.Split(strings.Trim(p, "/"), "/") {
			if seg != "" {
				b.WriteString("/")
				b.WriteString(url.PathEscape(seg))
			}
		}
		if dir {
			b.WriteString("/")
		}
	}
	return b.String()
}

type propEntry struct {
	href      string
	name      string
	dir       bool
	size      int64
	modified  int64
	created   int64
	etag      string
	quotaUsed int64
	quotaFree int64 // -1 = unknown
}

func (h *Handler) propfind(w http.ResponseWriter, r *http.Request, a vault.Actor, share, p string) {
	drain(r)
	depth := r.Header.Get("Depth")
	var entries []propEntry
	if share == "" {
		entries = append(entries, propEntry{href: h.Prefix + "/", name: "", dir: true, quotaFree: -1})
		if depth != "0" {
			drives, err := h.V.DrivesFor(a.User)
			if err != nil {
				writeErr(w, err, 0)
				return
			}
			for _, d := range drives {
				entries = append(entries, h.driveEntry(&d, share))
			}
		}
	} else {
		n, err := h.V.Stat(a, share, p)
		if err != nil {
			writeErr(w, err, 0)
			return
		}
		drive, _ := h.V.DriveFor(a.User, share)
		entries = append(entries, h.nodeEntry(share, p, n, drive))
		if n.IsDir && depth != "0" {
			kids, err := h.V.List(a, share, p)
			if err != nil {
				writeErr(w, err, 0)
				return
			}
			for _, k := range kids {
				entries = append(entries, h.nodeEntry(share, path.Join(p, k.Name), k, drive))
			}
		}
	}
	w.Header().Set("Content-Type", `application/xml; charset="utf-8"`)
	w.WriteHeader(http.StatusMultiStatus)
	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="utf-8"?>` + "\n" + `<D:multistatus xmlns:D="DAV:">`)
	for _, e := range entries {
		writeEntry(&b, e)
	}
	b.WriteString("</D:multistatus>\n")
	io.WriteString(w, b.String())
}

func (h *Handler) driveEntry(d *vault.Drive, _ string) propEntry {
	e := propEntry{href: h.href(d.Name, "/", true), name: d.Name, dir: true, quotaUsed: d.Used, modified: time.Now().Unix()}
	e.quotaFree = h.free(d)
	return e
}

// free is the space left on a drive: its quota, or with no quota the free
// space of the server's storage disk (so Explorer shows the NAS capacity).
func (h *Handler) free(d *vault.Drive) int64 {
	if d.QuotaBytes > 0 {
		return max(d.QuotaBytes-d.Used, 0)
	}
	if _, free, err := h.V.Blobs.DiskSpace(); err == nil {
		return int64(free)
	}
	return -1
}

func (h *Handler) nodeEntry(share, p string, n *vault.Node, d *vault.Drive) propEntry {
	e := propEntry{href: h.href(share, p, n.IsDir), name: n.Name, dir: n.IsDir, size: n.Size,
		modified: n.ModifiedAt, created: n.CreatedAt, quotaFree: -1}
	if n.IsDir {
		e.etag = `"d` + strconv.FormatInt(n.ID, 36) + "-" + strconv.FormatInt(n.ModifiedAt, 36) + `"`
		if d != nil {
			e.quotaUsed = d.Used
			e.quotaFree = h.free(d)
		}
		if n.ParentID == 0 {
			e.name = share
		}
	} else {
		sha := n.BlobSHA
		if len(sha) > 16 {
			sha = sha[:16]
		}
		e.etag = `"` + sha + "-" + strconv.FormatInt(n.Size, 36) + `"`
	}
	return e
}

func xmlEsc(s string) string {
	var b strings.Builder
	xml.EscapeText(&b, []byte(s))
	return b.String()
}

func writeEntry(b *strings.Builder, e propEntry) {
	b.WriteString("<D:response><D:href>")
	b.WriteString(xmlEsc(e.href))
	b.WriteString("</D:href><D:propstat><D:prop>")
	b.WriteString("<D:displayname>" + xmlEsc(e.name) + "</D:displayname>")
	if e.modified > 0 {
		b.WriteString("<D:getlastmodified>" + time.Unix(e.modified, 0).UTC().Format(http.TimeFormat) + "</D:getlastmodified>")
	}
	if e.created > 0 {
		b.WriteString("<D:creationdate>" + time.Unix(e.created, 0).UTC().Format(time.RFC3339) + "</D:creationdate>")
	}
	if e.etag != "" {
		b.WriteString("<D:getetag>" + xmlEsc(e.etag) + "</D:getetag>")
	}
	if e.dir {
		b.WriteString("<D:resourcetype><D:collection/></D:resourcetype>")
		if e.quotaFree >= 0 {
			b.WriteString("<D:quota-used-bytes>" + strconv.FormatInt(e.quotaUsed, 10) + "</D:quota-used-bytes>")
			b.WriteString("<D:quota-available-bytes>" + strconv.FormatInt(e.quotaFree, 10) + "</D:quota-available-bytes>")
		}
	} else {
		b.WriteString("<D:resourcetype/>")
		b.WriteString("<D:getcontentlength>" + strconv.FormatInt(e.size, 10) + "</D:getcontentlength>")
		ct := mime.TypeByExtension(path.Ext(e.name))
		if ct == "" {
			ct = "application/octet-stream"
		}
		b.WriteString("<D:getcontenttype>" + xmlEsc(ct) + "</D:getcontenttype>")
	}
	b.WriteString("</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>")
}

// proppatch accepts property changes (e.g. timestamps Windows tries to set)
// without storing them; the server keeps its own times for the audit trail.
func (h *Handler) proppatch(w http.ResponseWriter, r *http.Request, a vault.Actor, share, p string) {
	if share == "" {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	n, err := h.V.Stat(a, share, p)
	if err != nil {
		writeErr(w, err, 0)
		return
	}
	w.Header().Set("Content-Type", `application/xml; charset="utf-8"`)
	w.WriteHeader(http.StatusMultiStatus)
	io.WriteString(w, `<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:"><D:response><D:href>`+
		xmlEsc(h.href(share, p, n.IsDir))+`</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>`)
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request, a vault.Actor, share, p string) {
	if share == "" {
		http.Error(w, "collection", http.StatusMethodNotAllowed)
		return
	}
	n, f, err := h.V.Open(a, share, p)
	if err != nil {
		writeErr(w, err, 0)
		return
	}
	defer f.Close()
	sha := n.BlobSHA
	if len(sha) > 16 {
		sha = sha[:16]
	}
	w.Header().Set("ETag", `"`+sha+"-"+strconv.FormatInt(n.Size, 36)+`"`)
	if ct := mime.TypeByExtension(path.Ext(n.Name)); ct != "" {
		w.Header().Set("Content-Type", ct)
	} else {
		w.Header().Set("Content-Type", "application/octet-stream")
	}
	http.ServeContent(w, r, "", time.Unix(n.ModifiedAt, 0), f)
}

func (h *Handler) moveCopy(w http.ResponseWriter, r *http.Request, a vault.Actor, share, p string) {
	dest := r.Header.Get("Destination")
	du, err := url.Parse(dest)
	if dest == "" || err != nil {
		http.Error(w, "bad destination", http.StatusBadRequest)
		return
	}
	if du.Host != "" && !strings.EqualFold(du.Host, r.Host) {
		http.Error(w, "cross-server destination", http.StatusBadGateway)
		return
	}
	if !strings.HasPrefix(du.Path, h.Prefix+"/") {
		http.Error(w, "bad destination", http.StatusBadRequest)
		return
	}
	dshare, dpath := h.split(du.Path)
	if share == "" || dshare == "" {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	overwrite := !strings.EqualFold(r.Header.Get("Overwrite"), "F")
	var created bool
	if r.Method == "MOVE" {
		created, err = h.V.Move(a, share, p, dshare, dpath, overwrite)
	} else {
		created, err = h.V.Copy(a, share, p, dshare, dpath, overwrite)
	}
	if err != nil {
		writeErr(w, err, http.StatusPreconditionFailed)
		return
	}
	if created {
		w.WriteHeader(http.StatusCreated)
	} else {
		w.WriteHeader(http.StatusNoContent)
	}
}
