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
rem 설치용 패키지: 번호 붙은 한글 폴더 + 설명서
set PKG=dist\DocVault_설치파일
if exist "%PKG%" rmdir /s /q "%PKG%"
xcopy /e /i /q release "%PKG%" >nul
mkdir "%PKG%\1_서버설치\downloads" "%PKG%\3_관리자참고" 2>nul
copy /y dist\server\docvault-server.exe "%PKG%\1_서버설치\" >nul
copy /y dist\server\downloads\docvault-setup.exe "%PKG%\1_서버설치\downloads\" >nul
copy /y dist\server\downloads\docvault-setup.exe "%PKG%\2_직원PC설치\DocVault_PC설치.exe" >nul
copy /y README.md "%PKG%\3_관리자참고\" >nul
echo.
echo 완료: %PKG%
echo   (1_서버설치 폴더의 docvault.json 은 처음 실행할 때 자동으로 만들어집니다)
pause
exit /b 0
:err
echo 빌드 실패
pause
exit /b 1
