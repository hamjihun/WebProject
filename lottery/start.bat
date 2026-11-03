@echo off
chcp 65001 >nul
cd /d "%~dp0"
title YearEnd Lottery Server
set "NODE_EXE="
if exist "%~dp0node\node.exe" set "NODE_EXE=%~dp0node\node.exe"
if not defined NODE_EXE (
  where node >nul 2>nul && set "NODE_EXE=node"
)
if not defined NODE_EXE (
  echo Node.js not found. Running install.bat first...
  call "%~dp0install.bat"
  if exist "%~dp0node\node.exe" set "NODE_EXE=%~dp0node\node.exe"
)
if not defined NODE_EXE (
  echo.
  echo [ERROR] Node.js is required. Run install.bat or install Node.js LTS from https://nodejs.org
  pause
  exit /b 1
)
"%NODE_EXE%" "%~dp0server.js"
echo.
echo Server stopped.
pause
