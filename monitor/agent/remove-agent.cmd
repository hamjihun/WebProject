@echo off
REM 서버 모니터 에이전트 제거 (더블클릭)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0install-windows.ps1\" -Uninstall'"
