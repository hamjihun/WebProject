// Package blob stores file contents on disk (typically a NAS mount),
// addressed by their SHA-256 so identical contents are stored once.
package blob

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
)

type Store struct {
	root string
}

func New(root string) (*Store, error) {
	for _, d := range []string{"blobs", "tmp"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o750); err != nil {
			return nil, err
		}
	}
	return &Store{root: root}, nil
}

func (s *Store) path(sha string) string {
	return filepath.Join(s.root, "blobs", sha[:2], sha[2:4], sha)
}

// Put streams r into the store and returns its hash and size.
// limit > 0 caps the number of bytes accepted; exceeding it returns ErrTooLarge.
func (s *Store) Put(r io.Reader, limit int64) (sha string, size int64, err error) {
	tmp, err := os.CreateTemp(filepath.Join(s.root, "tmp"), "up-*")
	if err != nil {
		return "", 0, err
	}
	defer func() {
		tmp.Close()
		os.Remove(tmp.Name())
	}()
	h := sha256.New()
	src := r
	if limit > 0 {
		src = io.LimitReader(r, limit+1)
	}
	size, err = io.Copy(io.MultiWriter(tmp, h), src)
	if err != nil {
		return "", 0, err
	}
	if limit > 0 && size > limit {
		return "", 0, ErrTooLarge
	}
	if err := tmp.Sync(); err != nil {
		return "", 0, err
	}
	if err := tmp.Close(); err != nil {
		return "", 0, err
	}
	sha = hex.EncodeToString(h.Sum(nil))
	dst := s.path(sha)
	if _, err := os.Stat(dst); err == nil {
		return sha, size, nil
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o750); err != nil {
		return "", 0, err
	}
	if err := os.Rename(tmp.Name(), dst); err != nil {
		return "", 0, err
	}
	return sha, size, nil
}

var ErrTooLarge = errors.New("blob: size limit exceeded")

// EmptySHA is the hash of zero bytes; such blobs are never read from disk.
const EmptySHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

func (s *Store) Open(sha string) (*os.File, error) {
	if sha == "" || sha == EmptySHA {
		// Ensure the empty blob exists so callers can treat it like any other.
		p := s.path(EmptySHA)
		if _, err := os.Stat(p); err != nil {
			os.MkdirAll(filepath.Dir(p), 0o750)
			if f, err := os.Create(p); err == nil {
				f.Close()
			}
		}
		return os.Open(p)
	}
	return os.Open(s.path(sha))
}

func (s *Store) Delete(sha string) error {
	err := os.Remove(s.path(sha))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
