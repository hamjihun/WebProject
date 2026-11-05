@echo off
rem Year-end lottery: open index.html in Chrome (no server needed)
set "F=%~dp0index.html"
set "CH=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not exist "%CH%" set "CH=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
if not exist "%CH%" set "CH=%LocalAppData%\Google\Chrome\Application\chrome.exe"
if exist "%CH%" (
  start "" "%CH%" --new-window "%F%"
) else (
  start "" "%F%"
)
