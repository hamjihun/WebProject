@echo off
rem Stop background PC monitor
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*pc-monitor.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host Stopped $_.ProcessId }"
pause
