@echo off
chcp 65001 >nul
rem 모든 사용자의 Windows 시작 시 DocVault 에이전트를 자동 실행하도록 등록합니다 (관리자 권한 필요).
set AGENT=%ProgramFiles%\DocVault\docvault-agent.exe
if not exist "%AGENT%" (echo "%AGENT%" 파일이 없습니다. 먼저 복사하세요. & pause & exit /b 1)
powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut(\"$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\DocVault.lnk\"); $s.TargetPath=\"%AGENT%\"; $s.WindowStyle=1; $s.Save()"
echo 등록했습니다. 다음 로그인부터 자동으로 드라이브가 연결됩니다.
pause
