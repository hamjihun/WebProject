package vault

// Passthrough drives serve an existing folder on disk in place — no import, no
// hash-blob store. A share with BackendPath set maps directly to that folder:
// list/open/save/rename go straight to the real files. Used to put an existing
// storage (e.g. a PlusDrive tree) behind DocVault's drives, permissions and DLP
// without migrating the data.

import (
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// trashDir holds files deleted from a passthrough drive, so a delete is
// recoverable (there is no DocVault trash for in-place folders).
const trashDir = ".docvault_trash"

// isInternalName hides the backend's own system folders from the drive view.
func isInternalName(name string) bool {
	if strings.HasPrefix(name, "%%") {
		return true
	}
	switch name {
	case trashDir, "lost+found",
		"RECYCLER", "DOC_EXPORT", "file_ext", "version_mgmt_files",
		"empty_recycle_bin", "application_tmp_files", "export_files":
		return true
	}
	return false
}

// ptResolve maps a drive-relative path to an absolute path inside the backend,
// refusing anything that would escape it.
func (v *Vault) ptResolve(s *Share, parts []string) (string, error) {
	full := s.BackendPath
	for _, p := range parts {
		if p == "" || p == "." || p == ".." || strings.ContainsAny(p, `/\`) {
			return "", ErrInvalidName
		}
		full = filepath.Join(full, p)
	}
	rel, err := filepath.Rel(s.BackendPath, full)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", ErrNotFound
	}
	return full, nil
}

func ptNode(name string, fi os.FileInfo, root bool) *Node {
	h := fnv.New64a()
	h.Write([]byte(name))
	n := &Node{
		ID:         int64(h.Sum64() >> 1),
		Name:       name,
		IsDir:      fi.IsDir(),
		Size:       fi.Size(),
		ModifiedAt: fi.ModTime().Unix(),
		CreatedAt:  fi.ModTime().Unix(),
		ParentID:   1,
	}
	if root {
		n.ParentID = 0
	}
	if !fi.IsDir() {
		// Synthetic etag source: changes when the file's mtime changes.
		n.BlobSHA = fmt.Sprintf("%016x", fi.ModTime().UnixNano())
	}
	return n
}

func (v *Vault) ptStat(l *loc) (*Node, error) {
	full, err := v.ptResolve(l.share, l.parts)
	if err != nil {
		return nil, err
	}
	fi, err := os.Stat(full)
	if err != nil {
		return nil, ErrNotFound
	}
	name := l.share.Name
	root := len(l.parts) == 0
	if !root {
		name = l.parts[len(l.parts)-1]
		if isInternalName(name) {
			return nil, ErrNotFound
		}
	}
	return ptNode(name, fi, root), nil
}

func (v *Vault) ptList(l *loc) ([]*Node, error) {
	full, err := v.ptResolve(l.share, l.parts)
	if err != nil {
		return nil, err
	}
	ents, err := os.ReadDir(full)
	if err != nil {
		return nil, ErrNotFound
	}
	out := []*Node{}
	for _, e := range ents {
		if isInternalName(e.Name()) {
			continue
		}
		fi, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, ptNode(e.Name(), fi, false))
	}
	return out, nil
}

func (v *Vault) ptOpen(a Actor, l *loc) (*Node, *os.File, error) {
	full, err := v.ptResolve(l.share, l.parts)
	if err != nil {
		return nil, nil, err
	}
	fi, err := os.Stat(full)
	if err != nil {
		return nil, nil, ErrNoContent
	}
	if fi.IsDir() {
		return nil, nil, ErrIsDir
	}
	f, err := os.Open(full)
	if err != nil {
		return nil, nil, err
	}
	name := l.parts[len(l.parts)-1]
	if !isTransient(name) {
		v.auditRead(a, l.share.Name, l.path(), 0)
	}
	return ptNode(name, fi, false), f, nil
}

func (v *Vault) ptPut(a Actor, l *loc, r io.Reader) (*Node, bool, error) {
	if len(l.parts) == 0 {
		return nil, false, ErrIsDir
	}
	name := l.parts[len(l.parts)-1]
	if name == "" || isInternalName(name) {
		return nil, false, ErrForbidden
	}
	full, err := v.ptResolve(l.share, l.parts)
	if err != nil {
		return nil, false, err
	}
	created := false
	if _, e := os.Stat(full); e != nil {
		created = true
	}
	tmp := full + ".dv.tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return nil, false, err
	}
	_, err = io.Copy(f, r)
	f.Close()
	if err != nil {
		os.Remove(tmp)
		return nil, false, err
	}
	if err := os.Rename(tmp, full); err != nil {
		os.Remove(tmp)
		return nil, false, err
	}
	fi, err := os.Stat(full)
	if err != nil {
		return nil, false, err
	}
	if !isTransient(name) {
		v.Audit(a, map[bool]string{true: "create", false: "update"}[created], l.share.Name, l.path(), sizeText(fi.Size()))
	}
	return ptNode(name, fi, false), created, nil
}

func (v *Vault) ptMkdir(a Actor, l *loc) error {
	if len(l.parts) == 0 {
		return ErrExists
	}
	name := l.parts[len(l.parts)-1]
	if isInternalName(name) {
		return ErrForbidden
	}
	full, err := v.ptResolve(l.share, l.parts)
	if err != nil {
		return err
	}
	if err := os.Mkdir(full, 0o775); err != nil {
		if os.IsExist(err) {
			return ErrExists
		}
		return err
	}
	v.Audit(a, "mkdir", l.share.Name, l.path(), "")
	return nil
}

func (v *Vault) ptDelete(a Actor, l *loc) error {
	if len(l.parts) == 0 {
		return ErrForbidden
	}
	name := l.parts[len(l.parts)-1]
	if isInternalName(name) {
		return ErrForbidden
	}
	full, err := v.ptResolve(l.share, l.parts)
	if err != nil {
		return err
	}
	if _, err := os.Stat(full); err != nil {
		return ErrNotFound
	}
	if isTransient(name) {
		os.RemoveAll(full)
		return nil
	}
	// Move to the backend's trash folder so the delete is recoverable.
	trash := filepath.Join(l.share.BackendPath, trashDir)
	os.MkdirAll(trash, 0o775)
	dst := filepath.Join(trash, fmt.Sprintf("%d_%s", v.Now(), name))
	if err := os.Rename(full, dst); err != nil {
		if err := os.RemoveAll(full); err != nil {
			return err
		}
	}
	v.Audit(a, "delete", l.share.Name, l.path(), "")
	return nil
}

func (v *Vault) ptMove(a Actor, sl, dl *loc) (bool, error) {
	if sl.share.BackendPath == "" || dl.share.BackendPath == "" {
		return false, errors.New("기존 폴더 드라이브와 자체 저장 드라이브 사이의 이동/복사는 아직 지원하지 않습니다")
	}
	src, err := v.ptResolve(sl.share, sl.parts)
	if err != nil {
		return false, err
	}
	dst, err := v.ptResolve(dl.share, dl.parts)
	if err != nil {
		return false, err
	}
	created := false
	if _, e := os.Stat(dst); e != nil {
		created = true
	}
	os.MkdirAll(filepath.Dir(dst), 0o775)
	if err := os.Rename(src, dst); err != nil {
		if err := copyPath(src, dst); err != nil {
			return false, err
		}
		os.RemoveAll(src)
	}
	v.Audit(a, "move", sl.share.Name, sl.path(), "→ "+dl.share.Name+":"+dl.path())
	return created, nil
}

func (v *Vault) ptCopy(a Actor, sl, dl *loc) (bool, error) {
	if sl.share.BackendPath == "" || dl.share.BackendPath == "" {
		return false, errors.New("기존 폴더 드라이브와 자체 저장 드라이브 사이의 이동/복사는 아직 지원하지 않습니다")
	}
	src, err := v.ptResolve(sl.share, sl.parts)
	if err != nil {
		return false, err
	}
	dst, err := v.ptResolve(dl.share, dl.parts)
	if err != nil {
		return false, err
	}
	created := false
	if _, e := os.Stat(dst); e != nil {
		created = true
	}
	os.MkdirAll(filepath.Dir(dst), 0o775)
	if err := copyPath(src, dst); err != nil {
		return false, err
	}
	v.Audit(a, "copy", sl.share.Name, sl.path(), "→ "+dl.share.Name+":"+dl.path())
	return created, nil
}

func copyPath(src, dst string) error {
	fi, err := os.Stat(src)
	if err != nil {
		return err
	}
	if fi.IsDir() {
		if err := os.MkdirAll(dst, 0o775); err != nil {
			return err
		}
		ents, err := os.ReadDir(src)
		if err != nil {
			return err
		}
		for _, e := range ents {
			if err := copyPath(filepath.Join(src, e.Name()), filepath.Join(dst, e.Name())); err != nil {
				return err
			}
		}
		return nil
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
