@echo off
chcp 65001 >nul
cd /d "%~dp0"
net session >nul 2>&1 || (echo 마우스 오른쪽 클릭 → [관리자 권한으로 실행] 으로 다시 실행하세요. & pause & exit /b 1)
docvault-server.exe start && echo 서비스를 시작했습니다.
pause
