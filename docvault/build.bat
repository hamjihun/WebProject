@echo off
chcp 65001 >nul
rem DocVault 빌드 - Go 설치 필요 (https://go.dev/dl/)
rem 결과: dist\server\docvault-server.exe, dist\server\downloads\docvault-setup.exe (직원 PC 통합 설치 파일)
cd /d "%~dp0"
where go >nul 2>nul || (echo Go가 설치되어 있지 않습니다. https://go.dev/dl/ 에서 설치하세요. & pause & exit /b 1)
set P=cmd\setup\payload
set WINFSP_TAG=v2.0
set WINFSP_MSI=winfsp-2.0.23075.msi
rem 드라이브 프로그램 (rclone 기반 + DocVault 프로그램 차단 기능, tools\dvmount)
set CGO_ENABLED=0
pushd tools\dvmount
go build -tags cmount -trimpath -ldflags "-s -w" -o ..\..\%P%\rclone.exe . || (popd & goto :err)
popd
powershell -NoProfile -Command "Compress-Archive -Force -Path '%P%\rclone.exe' -DestinationPath '%P%\rclone.zip'" || goto :err
del %P%\rclone.exe
if not exist %P%\winfsp.msi powershell -NoProfile -Command "Invoke-WebRequest -UseBasicParsing -OutFile '%P%\winfsp.msi' 'https://github.com/winfsp/winfsp/releases/download/%WINFSP_TAG%/%WINFSP_MSI%'" || goto :err
set GOOS=windows
set GOARCH=amd64
go build -trimpath -ldflags "-s -w -H windowsgui" -o %P%\docvault-agent.exe .\cmd\agent || goto :err
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
