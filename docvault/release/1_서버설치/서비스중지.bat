@echo off
chcp 65001 >nul
cd /d "%~dp0"
net session >nul 2>&1 || (echo 마우스 오른쪽 클릭 → [관리자 권한으로 실행] 으로 다시 실행하세요. & pause & exit /b 1)
docvault-server.exe stop && echo 서비스를 멈췄습니다. 이제 파일을 교체할 수 있습니다.
pause
