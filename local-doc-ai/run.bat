@echo off
REM Local Document AI - start
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
  echo Please run install.bat first.
  pause
  exit /b 1
)
powershell -NoProfile -Command "try { Invoke-RestMethod http://127.0.0.1:11434/api/tags -TimeoutSec 2 | Out-Null } catch { $o = Get-Command ollama -ErrorAction SilentlyContinue; if ($o) { Start-Process $o.Source -ArgumentList serve -WindowStyle Hidden; Start-Sleep 4 } }"
".venv\Scripts\python.exe" -m app
pause
