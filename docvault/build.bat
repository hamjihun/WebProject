@echo off
chcp 65001 >nul
rem DocVault 빌드 - Go 설치 필요 (https://go.dev/dl/)
rem 결과: dist\server\docvault-server.exe, dist\server\downloads\docvault-setup.exe (직원 PC 통합 설치 파일)
cd /d "%~dp0"
where go >nul 2>nul || (echo Go가 설치되어 있지 않습니다. https://go.dev/dl/ 에서 설치하세요. & pause & exit /b 1)
set P=cmd\setup\payload
set RCLONE_VER=v1.68.2
set WINFSP_TAG=v2.0
set WINFSP_MSI=winfsp-2.0.23075.msi
if not exist %P%\rclone.zip powershell -NoProfile -Command "Invoke-WebRequest -UseBasicParsing -OutFile '%P%\rclone.zip' 'https://github.com/rclone/rclone/releases/download/%RCLONE_VER%/rclone-%RCLONE_VER%-windows-amd64.zip'" || goto :err
if not exist %P%\winfsp.msi powershell -NoProfile -Command "Invoke-WebRequest -UseBasicParsing -OutFile '%P%\winfsp.msi' 'https://github.com/winfsp/winfsp/releases/download/%WINFSP_TAG%/%WINFSP_MSI%'" || goto :err
set GOOS=windows
set GOARCH=amd64
go build -trimpath -ldflags "-s -w" -o %P%\docvault-agent.exe .\cmd\agent || goto :err
go build -trimpath -ldflags "-s -w" -o dist\server\docvault-server.exe .\cmd\server || goto :err
go build -trimpath -ldflags "-s -w" -o dist\server\downloads\docvault-setup.exe .\cmd\setup || goto :err
if not exist dist\agent mkdir dist\agent
copy /y %P%\docvault-agent.exe dist\agent\ >nul
echo.
echo 완료:
echo   dist\server\docvault-server.exe
echo   dist\server\downloads\docvault-setup.exe  (직원 PC 통합 설치 파일 - 서버 웹에서 내려받기 제공)
pause
exit /b 0
:err
echo 빌드 실패
pause
exit /b 1
