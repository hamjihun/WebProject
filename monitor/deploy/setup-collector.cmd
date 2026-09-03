@echo off
REM ==========================================================
REM  수집기 설치 (IMS 서버에서 더블클릭)
REM  monitor 폴더를 IMS 서버(예: C:\ims\monitor)에 복사한 뒤
REM  이 파일을 더블클릭하면 작업 스케줄러 등록 + 방화벽 허용 + 시작까지 됩니다.
REM  Node.js 가 먼저 설치되어 있어야 합니다. (https://nodejs.org)
REM ==========================================================
set PORT=15138
set TOKEN=ilsan-mon-2026
REM ==========================================================

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0install-collector-windows.ps1\" -Public -Port %PORT% -Token \"%TOKEN%\"'"
