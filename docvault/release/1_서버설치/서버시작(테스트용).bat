@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo DocVault 서버를 실행합니다. 이 창을 닫으면 서버도 꺼집니다.
echo.
docvault-server.exe
pause
