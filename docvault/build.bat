@echo off
chcp 65001 >nul
rem DocVault 빌드 - Go 설치 필요 (https://go.dev/dl/)
cd /d "%~dp0"
where go >nul 2>nul || (echo Go가 설치되어 있지 않습니다. https://go.dev/dl/ 에서 설치하세요. & pause & exit /b 1)
set GOOS=windows
set GOARCH=amd64
go build -trimpath -ldflags "-s -w" -o dist\server\docvault-server.exe .\cmd\server || goto :err
go build -trimpath -ldflags "-s -w" -o dist\agent\docvault-agent.exe .\cmd\agent || goto :err
echo.
echo 완료: dist\server\docvault-server.exe, dist\agent\docvault-agent.exe
pause
exit /b 0
:err
echo 빌드 실패
pause
exit /b 1
