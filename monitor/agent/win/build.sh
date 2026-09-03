#!/usr/bin/env bash
# 설치 프로그램 빌드 (Linux/Mac: apt install nsis, Windows: NSIS 설치 후 makensis.exe)
set -e
cd "$(dirname "$0")"
mkdir -p ../../dist
makensis -V2 installer.nsi
ls -la ../../dist/IMS-Monitoring-Agent-Setup.exe
