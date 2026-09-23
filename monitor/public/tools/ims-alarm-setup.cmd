@echo off
chcp 949 >nul
title IMS 알림 설치
setlocal
set "SRV=http://192.168.0.9:15138"
set "DEST=%LOCALAPPDATA%\IMS-Alarm"

echo.
echo   IMS 알림 (윈도우 팝업) 설치
echo   ----------------------------------------
echo   메모 보드 알림판에 등록한 알림을 시간이 되면
echo   바탕화면에 팝업으로 띄웁니다. (브라우저를 열어 두지 않아도 됩니다)
echo.
echo   프로그램을 내려받는 중... (%SRV%)

if not exist "%DEST%" mkdir "%DEST%"
curl.exe -s -f -o "%DEST%\ims-alarm.ps1" "%SRV%/tools/ims-alarm.ps1" 2>nul
if not exist "%DEST%\ims-alarm.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -Uri '%SRV%/tools/ims-alarm.ps1' -OutFile '%DEST%\ims-alarm.ps1' -UseBasicParsing } catch { }"
)
if not exist "%DEST%\ims-alarm.ps1" (
  echo.
  echo   내려받지 못했습니다. 서버 주소를 확인해 주세요: %SRV%
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%DEST%\ims-alarm.ps1" -Setup -Server "%SRV%"
endlocal
