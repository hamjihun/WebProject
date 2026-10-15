#!/bin/sh
# Builds the Windows release on Linux/macOS: server, agent and the all-in-one
# employee installer (docvault-setup.exe, which embeds the agent, rclone and WinFsp).
set -e
cd "$(dirname "$0")/.."
RCLONE_VER=${RCLONE_VER:-v1.68.2}
WINFSP_TAG=${WINFSP_TAG:-v2.0}
WINFSP_MSI=${WINFSP_MSI:-winfsp-2.0.23075.msi}
P=cmd/setup/payload
[ -f $P/rclone.zip ] || curl -fsSL -o $P/rclone.zip "https://github.com/rclone/rclone/releases/download/$RCLONE_VER/rclone-$RCLONE_VER-windows-amd64.zip"
[ -f $P/winfsp.msi ] || curl -fsSL -o $P/winfsp.msi "https://github.com/winfsp/winfsp/releases/download/$WINFSP_TAG/$WINFSP_MSI"
export GOOS=windows GOARCH=amd64
F="-trimpath -ldflags=-s -ldflags=-w"
go build $F -o $P/docvault-agent.exe ./cmd/agent
mkdir -p dist/server/downloads dist/agent
go build $F -o dist/server/docvault-server.exe ./cmd/server
go build $F -o dist/server/downloads/docvault-setup.exe ./cmd/setup
cp $P/docvault-agent.exe dist/agent/
echo "완료: dist/server (서버 + downloads/docvault-setup.exe)"
