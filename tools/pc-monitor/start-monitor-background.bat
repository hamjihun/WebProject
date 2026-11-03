@echo off
rem PC monitor - background mode (no window). Logs: Documents\PCMonitor
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0pc-monitor.ps1" -Quiet
