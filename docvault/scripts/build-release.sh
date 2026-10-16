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
echo "완료: dist/server (서버 + downloads/docvault-setup.exe)"
