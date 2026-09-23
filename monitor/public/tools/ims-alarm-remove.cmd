@echo off
chcp 949 >nul
title IMS 알림 제거
setlocal
set "DEST=%LOCALAPPDATA%\IMS-Alarm"
echo.
echo   IMS 알림을 지웁니다. (등록해 둔 알림 내용은 그대로 남습니다)
echo.
if exist "%DEST%\ims-alarm.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%DEST%\ims-alarm.ps1" -Remove
) else (
  del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\IMS-Alarm.vbs" 2>nul
  echo   지웠습니다.
  pause
)
endlocal
