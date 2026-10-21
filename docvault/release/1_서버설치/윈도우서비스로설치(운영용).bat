@echo off
chcp 65001 >nul
cd /d "%~dp0"
net session >nul 2>&1 || (echo 마우스 오른쪽 클릭 → [관리자 권한으로 실행] 으로 다시 실행하세요. & pause & exit /b 1)
docvault-server.exe install
echo.
echo 이제 PC를 켜면 DocVault 서버가 자동으로 실행됩니다.
echo 서비스 이름: DocVault 문서중앙화 서버 (services.msc 에서 확인)
pause
