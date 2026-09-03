@echo off
REM ==========================================================
REM  서버 모니터 에이전트 설치 (더블클릭)
REM  아래 두 줄만 회사 환경에 맞게 한 번 고친 뒤,
REM  이 폴더(agent.ps1, install-windows.ps1, setup-agent.cmd)를
REM  각 서버에 복사하고 이 파일을 더블클릭하면 끝입니다.
REM  (관리자 권한 확인 창이 뜨면 "예")
REM ==========================================================
set URL=http://192.168.0.9:15138/api/metrics
set TOKEN=ilsan-mon-2026
REM ==========================================================

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0install-windows.ps1\" -Url \"%URL%\" -Token \"%TOKEN%\"'"
