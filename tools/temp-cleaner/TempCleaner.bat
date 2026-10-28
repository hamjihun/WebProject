@echo off
setlocal EnableExtensions
REM ============================================================
REM  TempCleaner - permanently deletes everything in the TEMP folder
REM  Schedule: every Wednesday 11:50 (runs late if the PC was off)
REM
REM  Double-click        : install (register scheduled task) + clean once
REM  TempCleaner.bat /run       : clean now
REM  TempCleaner.bat /uninstall : remove scheduled task
REM ============================================================

REM ---- Settings ------------------------------------------------
REM Folder to clean (default: C:\Users\<user>\AppData\Local\Temp)
set "TARGET=%LOCALAPPDATA%\Temp"
set "DAY=WED"
set "TIME_AT=11:50"
REM -------------------------------------------------------------

set "TASK=TempCleaner"
set "DEST_DIR=%LOCALAPPDATA%\TempCleaner"
set "DEST=%DEST_DIR%\TempCleaner.bat"
set "LOG=%DEST_DIR%\cleanup.log"

if /i "%~1"=="/run" goto :clean
if /i "%~1"=="/uninstall" goto :uninstall

:install
echo Target folder : %TARGET%
echo Schedule      : every %DAY% %TIME_AT%
echo.
if not exist "%DEST_DIR%" mkdir "%DEST_DIR%"
copy /y "%~f0" "%DEST%" >nul || (echo [ERROR] copy failed & pause & exit /b 1)

schtasks /create /f /tn "%TASK%" /sc weekly /d %DAY% /st %TIME_AT% /tr "\"%DEST%\" /run" >nul || (echo [ERROR] task registration failed & pause & exit /b 1)
REM Run missed schedules as soon as the PC is on, also on battery
powershell -NoProfile -Command "Set-ScheduledTask -TaskName '%TASK%' -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries)" >nul 2>&1

REM Clean up the old multi-file version if present
if exist "C:\Scripts\TempCleaner" rd /s /q "C:\Scripts\TempCleaner" 2>nul

REM Run the first clean as a separate task (this file may itself be inside TEMP)
schtasks /run /tn "%TASK%" >nul
echo Installed: %DEST%
echo Log file : %LOG%
echo First clean started.
echo.
pause
exit /b 0

:clean
for %%I in ("%TARGET%") do if /i not "%%~nxI"=="Temp" (
    echo %date% %time% ABORT: unexpected target "%TARGET%">>"%LOG%"
    exit /b 1
)
if not exist "%TARGET%\" exit /b 1
REM /q = never ask for confirmation; deletes permanently (no Recycle Bin)
for /f "delims=" %%D in ('dir /b /a:d "%TARGET%" 2^>nul') do rd /s /q "%TARGET%\%%D" 2>nul
del /f /s /q /a "%TARGET%\*" >nul 2>&1
set /a LEFT=0
for /f "delims=" %%F in ('dir /b /a "%TARGET%" 2^>nul') do set /a LEFT+=1
echo %date% %time% cleaned "%TARGET%" remaining_items=%LEFT% (in use)>>"%LOG%"
exit /b 0

:uninstall
schtasks /delete /f /tn "%TASK%" >nul 2>&1
echo Scheduled task removed. You can delete "%DEST_DIR%" manually.
pause
exit /b 0
