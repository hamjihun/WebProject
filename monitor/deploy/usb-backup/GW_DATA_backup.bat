@echo off
chcp 65001 > nul
title DATA 특정 날짜 이후 증분 백업

:: ==========================================
:: [사용자 설정 항목]
:: ==========================================
:: 1. 원본 및 대상 경로 설정
set "SRC=D:\DATA"
set "DST=G:\0.백업\2.그룹웨어\DATA"

:: 2. 로그 전용 폴더 (날짜별 폴더가 자동으로 생기고 30일 지나면 지워짐)
set "BASE_LOG_DIR=C:\Users\Administrator\Desktop\Log\DATA"

:: 3. 기준 날짜 (형식: YYYYMMDD) - 이 날짜 이후에 바뀐 파일만 복사
set BACKUP_DATE=20260519

:: 4. robocopy 옵션 (각 항목에 띄어쓰기 없이)
::    /XF : 복사하지 않을 파일 (사용 중 잠금·임시 파일),  /XD Spam 처럼 폴더도 뺄 수 있음
set "OPTS=/E /XO /MAXAGE:%BACKUP_DATE% /XF *.ldb *.lck *.lock ~$* /R:2 /W:5"
:: ==========================================

set YYYYMMDD=%date:~0,4%-%date:~5,2%-%date:~8,2%
set "LOG_FILE=%BASE_LOG_DIR%\%YYYYMMDD%\GW_Data_OK.txt"

echo [백업 시작] %date% %time%
echo 원본: %SRC%
echo 대상: %DST%
echo 로그: %LOG_FILE%
echo --------------------------------------------------

:: 진행률(%%)만 보여 주며 복사 (같은 폴더의 usb-copy.ps1). 로그에는 실패한 파일과 요약만 남음
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0usb-copy.ps1" -Src "%SRC%" -Dst "%DST%" -Log "%LOG_FILE%" -Options "%OPTS%"
set RC=%ERRORLEVEL%

:: 모니터링에 결과 알림 (0~7 정상, 8 이상 실패)
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\IMSMonitoringAgent\usb-done.ps1" %RC% "%DST%"

:: 30일 지난 날짜별 로그 폴더 자동 삭제
forfiles /p "%BASE_LOG_DIR%" /d -30 /c "cmd /c if @isdir==TRUE rd /s /q @path" > nul 2>&1

echo --------------------------------------------------
if %RC% GEQ 8 (
  echo [백업 일부 실패] 결과 코드 %RC% - 위 '실패한 파일' 또는 로그를 확인하세요
) else (
  echo [백업 완료] 결과 코드 %RC%
)
echo %date% %time%
echo --------------------------------------------------

:: 외장하드 안전하게 꺼내기 명령
RemoveDrive.exe G: -b

cmd /k
