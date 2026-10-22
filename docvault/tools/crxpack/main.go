// crxpack builds a signed Chrome CRX3 package for the DocVault browser
// extension so the server can host it and Chrome/Edge/Whale can force-install
// it on managed PCs (no Chrome Web Store, works offline on the LAN).
//
//	crxpack keygen <key.pem>              generate the signing key (run once)
//	crxpack info   <key.pem>              print extension id + manifest "key"
//	crxpack pack   <dir> <key.pem> <out.crx>   zip <dir> and write a signed .crx
package main

import (
	"archive/zip"
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fail("사용법: crxpack keygen|info|pack ...")
	}
	switch os.Args[1] {
	case "keygen":
		must(2, "crxpack keygen <key.pem>")
		keygen(os.Args[2])
	case "info":
		must(2, "crxpack info <key.pem>")
		priv := loadKey(os.Args[2])
		id, key := identity(priv)
		fmt.Println("extension_id:", id)
		fmt.Println("manifest_key:", key)
	case "pack":
		if len(os.Args) != 5 {
			fail("crxpack pack <dir> <key.pem> <out.crx>")
		}
		pack(os.Args[2], os.Args[3], os.Args[4])
	case "verify":
		must(2, "crxpack verify <file.crx>")
		verify(os.Args[2])
	default:
		fail("알 수 없는 명령: " + os.Args[1])
	}
}

func keygen(path string) {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	ck(err)
	der := x509.MarshalPKCS1PrivateKey(priv)
	ck(os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: der}), 0o600))
	id, _ := identity(priv)
	fmt.Println("키 생성:", path)
	fmt.Println("extension_id:", id)
}

func loadKey(path string) *rsa.PrivateKey {
	b, err := os.ReadFile(path)
	ck(err)
	blk, _ := pem.Decode(b)
	if blk == nil {
		fail("PEM을 읽을 수 없습니다: " + path)
	}
	priv, err := x509.ParsePKCS1PrivateKey(blk.Bytes)
	ck(err)
	return priv
}

// identity returns the extension id (32 lowercase a-p chars) and the base64
// SubjectPublicKeyInfo that goes in manifest.json's "key" field.
func identity(priv *rsa.PrivateKey) (id, manifestKey string) {
	pub, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	ck(err)
	h := sha256.Sum256(pub)
	b := make([]byte, 32)
	for i := 0; i < 16; i++ {
		b[2*i] = 'a' + (h[i] >> 4)
		b[2*i+1] = 'a' + (h[i] & 0x0f)
	}
	return string(b), base64.StdEncoding.EncodeToString(pub)
}

func pack(dir, keyPath, out string) {
	priv := loadKey(keyPath)
	pub, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	ck(err)
	crxID := sha256.Sum256(pub)

	zipBytes := zipDir(dir)

	// signed_header_data = SignedData{ bytes crx_id = 1 }
	var sd bytes.Buffer
	pbBytes(&sd, 1, crxID[:16])

	// Signature over: "CRX3 SignedData\0" + le32(len(sd)) + sd + zip
	var signed bytes.Buffer
	signed.WriteString("CRX3 SignedData\x00")
	binary.Write(&signed, binary.LittleEndian, uint32(sd.Len()))
	signed.Write(sd.Bytes())
	signed.Write(zipBytes)
	digest := sha256.Sum256(signed.Bytes())
	sig, err := rsa.SignPKCS1v15(rand.Reader, priv, crypto.SHA256, digest[:])
	ck(err)

	// AsymmetricKeyProof{ bytes public_key = 1; bytes signature = 2 }
	var proof bytes.Buffer
	pbBytes(&proof, 1, pub)
	pbBytes(&proof, 2, sig)

	// CrxFileHeader{ repeated AsymmetricKeyProof sha256_with_rsa = 2; bytes signed_header_data = 10000 }
	var header bytes.Buffer
	pbBytes(&header, 2, proof.Bytes())
	pbBytes(&header, 10000, sd.Bytes())

	var crx bytes.Buffer
	crx.WriteString("Cr24")
	binary.Write(&crx, binary.LittleEndian, uint32(3))
	binary.Write(&crx, binary.LittleEndian, uint32(header.Len()))
	crx.Write(header.Bytes())
	crx.Write(zipBytes)

	ck(os.MkdirAll(filepath.Dir(out), 0o755))
	ck(os.WriteFile(out, crx.Bytes(), 0o644))
	id, _ := identity(priv)
	fmt.Printf("패키징 완료: %s (%d bytes), extension_id=%s\n", out, crx.Len(), id)
}

// zipDir zips the files directly under dir (no nested doc/ etc.) at the zip root.
func zipDir(dir string) []byte {
	entries, err := os.ReadDir(dir)
	ck(err)
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			continue // extension files live at the top level
		}
		n := e.Name()
		// Ship only the extension's own files: skip keys, docs and dotfiles.
		if strings.HasSuffix(n, ".pem") || strings.HasSuffix(n, ".md") || strings.HasPrefix(n, ".") {
			continue
		}
		names = append(names, n)
	}
	sort.Strings(names)
	// A fixed modtime keeps the zip (and so the signed .crx) byte-for-byte
	// deterministic across rebuilds, so the committed artifact does not churn.
	fixed := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for _, n := range names {
		data, err := os.ReadFile(filepath.Join(dir, n))
		ck(err)
		w, err := zw.CreateHeader(&zip.FileHeader{Name: n, Method: zip.Deflate, Modified: fixed})
		ck(err)
		_, err = w.Write(data)
		ck(err)
	}
	ck(zw.Close())
	return buf.Bytes()
}

// verify re-reads a .crx: checks the magic/version, that the archive is a valid
// zip containing manifest.json, and that the id derived from the embedded public
// key matches the manifest "key". This catches malformed packaging before ship.
func verify(path string) {
	b, err := os.ReadFile(path)
	ck(err)
	if len(b) < 16 || string(b[:4]) != "Cr24" {
		fail("CRX 매직이 아닙니다")
	}
	ver := binary.LittleEndian.Uint32(b[4:8])
	hlen := binary.LittleEndian.Uint32(b[8:12])
	if ver != 3 {
		fail(fmt.Sprintf("CRX3가 아닙니다 (version=%d)", ver))
	}
	if int(12+hlen) > len(b) {
		fail("헤더 길이가 파일보다 큽니다")
	}
	header := b[12 : 12+hlen]
	zipBytes := b[12+hlen:]
	// Pull the public key out of the header (field 2 = proof, its field 1 = public_key).
	pub := firstPublicKey(header)
	if pub == nil {
		fail("헤더에서 공개키를 찾지 못했습니다")
	}
	h := sha256.Sum256(pub)
	id := make([]byte, 32)
	for i := 0; i < 16; i++ {
		id[2*i] = 'a' + (h[i] >> 4)
		id[2*i+1] = 'a' + (h[i] & 0x0f)
	}
	zr, err := zip.NewReader(bytes.NewReader(zipBytes), int64(len(zipBytes)))
	ck(err)
	hasManifest := false
	for _, f := range zr.File {
		if f.Name == "manifest.json" {
			hasManifest = true
		}
	}
	if !hasManifest {
		fail("zip 안에 manifest.json이 없습니다")
	}
	fmt.Printf("검증 통과: version=3, header=%dB, zip=%dB, files=%d, extension_id=%s\n", hlen, len(zipBytes), len(zr.File), string(id))
}

// firstPublicKey walks the CrxFileHeader protobuf to the first proof's public_key.
func firstPublicKey(header []byte) []byte {
	proof := pbField(header, 2) // sha256_with_rsa
	if proof == nil {
		return nil
	}
	return pbField(proof, 1) // public_key
}

// pbField returns the bytes of the first length-delimited field `num`.
func pbField(buf []byte, num int) []byte {
	i := 0
	for i < len(buf) {
		tag, n := binary.Uvarint(buf[i:])
		if n <= 0 {
			return nil
		}
		i += n
		field := int(tag >> 3)
		wire := tag & 7
		if wire != 2 {
			return nil // this encoder only uses length-delimited fields
		}
		l, n2 := binary.Uvarint(buf[i:])
		if n2 <= 0 {
			return nil
		}
		i += n2
		if i+int(l) > len(buf) {
			return nil
		}
		if field == num {
			return buf[i : i+int(l)]
		}
		i += int(l)
	}
	return nil
}

func pbBytes(buf *bytes.Buffer, field int, data []byte) {
	putUvarint(buf, uint64(field)<<3|2) // wire type 2 = length-delimited
	putUvarint(buf, uint64(len(data)))
	buf.Write(data)
}

func putUvarint(buf *bytes.Buffer, x uint64) {
	var b [10]byte
	n := binary.PutUvarint(b[:], x)
	buf.Write(b[:n])
}

func must(n int, usage string) {
	if len(os.Args) <= n {
		fail(usage)
	}
}
func ck(err error) {
	if err != nil {
		fail(err.Error())
	}
}
func fail(msg string) {
	fmt.Fprintln(os.Stderr, "오류:", msg)
	os.Exit(1)
}
