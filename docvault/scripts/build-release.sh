#!/bin/sh
# Builds the Windows release on Linux/macOS: server, agent and the all-in-one
# employee installer (docvault-setup.exe, which embeds the agent, rclone and WinFsp).
set -e
cd "$(dirname "$0")/.."
WINFSP_TAG=${WINFSP_TAG:-v2.0}
WINFSP_MSI=${WINFSP_MSI:-winfsp-2.0.23075.msi}
P=cmd/setup/payload
# Drive program: rclone trimmed to WebDAV + mount, with DocVault's program
# blocking (tools/dvmount). Shipped as rclone.exe inside rclone.zip.
(cd tools/dvmount && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -tags cmount -trimpath -ldflags="-s -w" -o ../../$P/rclone.exe .)
python3 -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w',zipfile.ZIP_DEFLATED); z.write(sys.argv[2],'rclone.exe'); z.close()" $P/rclone.zip $P/rclone.exe
rm -f $P/rclone.exe
[ -f $P/winfsp.msi ] || curl -fsSL -o $P/winfsp.msi "https://github.com/winfsp/winfsp/releases/download/$WINFSP_TAG/$WINFSP_MSI"
export GOOS=windows GOARCH=amd64
F="-trimpath"
go build $F -ldflags="-s -w -H=windowsgui" -o $P/docvault-agent.exe ./cmd/agent
mkdir -p dist/server/downloads dist/agent
go build $F -ldflags="-s -w" -o dist/server/docvault-server.exe ./cmd/server
go build $F -ldflags="-s -w" -o dist/server/downloads/docvault-setup.exe ./cmd/setup
cp $P/docvault-agent.exe dist/agent/

# Package for people installing it: numbered Korean folders with guides.
#   STORE_DIR=\\\\nas\\share ./scripts/build-release.sh  → docvault.json stores files on that NAS
PKG=dist/DocVault_설치파일
rm -rf "$PKG" dist/DocVault_설치파일.zip
mkdir -p "$PKG/1_서버설치/downloads" "$PKG/2_직원PC설치" "$PKG/3_관리자참고"
cp -r release/. "$PKG/"
cp dist/server/docvault-server.exe "$PKG/1_서버설치/"
cp dist/server/downloads/docvault-setup.exe "$PKG/1_서버설치/downloads/"
cp dist/server/downloads/docvault-setup.exe "$PKG/2_직원PC설치/DocVault_PC설치.exe"
cp README.md "$PKG/3_관리자참고/README.md"
python3 - "$PKG/1_서버설치/docvault.json" "${STORE_DIR:-}" <<'PY'
import sys
# Paths are written as Windows shows them; the server reads them as such.
lines = ['  "listen": ":8080"']
if sys.argv[2]:
    lines.append('  "store_dir": "%s"' % sys.argv[2])
lines += ['  "tls_cert": ""', '  "tls_key": ""', '  "trust_proxy": false', '  "public_url": ""']
open(sys.argv[1], "w", newline="").write("{\r\n" + ",\r\n".join(lines) + "\r\n}\r\n")
PY
(cd dist && python3 -c "
import os, zipfile
z = zipfile.ZipFile('DocVault_설치파일.zip', 'w', zipfile.ZIP_DEFLATED)
for r, d, fs in os.walk('DocVault_설치파일'):
    for f in fs:
        z.write(os.path.join(r, f))
z.close()")
echo "완료: dist/DocVault_설치파일 (dist/DocVault_설치파일.zip)"
