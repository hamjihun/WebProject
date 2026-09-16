@echo off
chcp 949 >nul
REM ==========================================================
REM  서버 모니터 데이터 백업 (작업 스케줄러가 매일 새벽에 실행)
REM  - daily\날짜\   : data 폴더(계정·일정·설정·이력) 30일치 보관
REM  - full\         : 프로그램 전체 한 벌 (이 폴더만 복사하면 그대로 복구됨)
REM  저장 위치를 바꾸려면 이 파일과 같은 폴더의 backup-target.txt 에 경로 한 줄만 적으세요.
REM    예)  D:\ims-monitor-backup   또는   \\192.168.0.238\backup\ims-monitor
REM  ※ NAS 같은 공유 폴더로 보내려면 작업 스케줄러에서 이 작업(ServerMonitorBackup)의
REM     실행 계정을 NAS 에 접근되는 계정으로 바꿔야 합니다. (기본 SYSTEM 계정은 공유 폴더 접근 불가)
REM  직접 실행해서 확인해도 됩니다 (두 번 눌러도 안전).
REM ==========================================================
setlocal
set ROOT=%~dp0..
set SRC=%ROOT%\data
set DST=C:\ims\monitor-backup
if exist "%~dp0backup-target.txt" (for /f "usebackq delims=" %%i in ("%~dp0backup-target.txt") do set DST=%%i)

for /f "tokens=2 delims==" %%i in ('wmic os get localdatetime /value') do set DT=%%i
set YMD=%DT:~0,4%-%DT:~4,2%-%DT:~6,2%
set STAMP=%DT:~0,4%-%DT:~4,2%-%DT:~6,2% %DT:~8,2%:%DT:~10,2%:%DT:~12,2%

if not exist "%DST%" mkdir "%DST%" 2>nul
if not exist "%DST%" (
  echo 백업 폴더를 만들 수 없습니다: %DST%
  exit /b 1
)
set LOG=%DST%\backup.log

echo. >> "%LOG%"
echo [%STAMP%] 백업 시작 : %DST% >> "%LOG%"

REM 1) 데이터(계정·일정·설정·이력) 날짜별 보관
robocopy "%SRC%" "%DST%\daily\%YMD%" *.json *.log /R:2 /W:3 /NFL /NDL /NJH /NJS >> "%LOG%" 2>&1
set RC=%ERRORLEVEL%

REM 2) 프로그램 전체 한 벌 (복구용). 용량 큰 실행 기록(collector.log)은 뺀다.
robocopy "%ROOT%" "%DST%\full" /E /XD .git node_modules /XF collector.log /R:2 /W:3 /NFL /NDL /NJH /NJS >> "%LOG%" 2>&1

REM 3) 30일보다 오래된 날짜 폴더 정리
forfiles /p "%DST%\daily" /d -30 /c "cmd /c if @isdir==TRUE rd /s /q @path" >nul 2>&1

if %RC% GEQ 8 (
  echo [%STAMP%] 실패 : robocopy 코드 %RC% >> "%LOG%"
  exit /b %RC%
)
echo [%STAMP%] 완료 : %DST%\daily\%YMD% >> "%LOG%"
exit /b 0
