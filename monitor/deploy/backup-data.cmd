@echo off
chcp 949 >nul
REM ==========================================================
REM  서버 모니터 데이터 백업 (작업 스케줄러 ServerMonitorBackup 이 매일 새벽 1시에 실행)
REM  - daily\날짜\ : data 폴더(계정·일정·설정·이력) 30일치 보관
REM  - full\       : 프로그램 전체 한 벌 (이 폴더만 복사하면 그대로 복구됨)
REM
REM  저장 위치는 같은 폴더의 backup-target.txt 에 한 줄에 하나씩 적는다 (여러 곳에 동시에 보관됨).
REM  # 로 시작하는 줄은 무시한다.
REM
REM  ※ 공유 폴더(\\...)에 저장하는 방법은 두 가지다.
REM     (1) 같은 폴더의 backup-cred.txt 에 아래처럼 한 줄 적는다 (가장 쉬움, 계정 바꿀 필요 없음)
REM           \\192.168.0.231\경영기획팀|계정|비밀번호
REM         (| 앞뒤에 공백을 넣지 말 것. 이 파일은 관리자만 볼 수 있게 두세요.)
REM     (2) 작업 스케줄러에서 ServerMonitorBackup 작업의 실행 계정을 그 공유 폴더에 접근되는
REM         계정으로 바꾼다. (설치할 때 -BackupUser / -BackupPass 를 줘도 같다)
REM
REM  직접 실행해서 확인해도 된다 (두 번 눌러도 안전).
REM ==========================================================
setlocal
set ROOT=%~dp0..
set SRC=%ROOT%\data
set LIST=%~dp0backup-target.txt
set CRED=%~dp0backup-cred.txt

for /f "tokens=2 delims==" %%i in ('wmic os get localdatetime /value') do set DT=%%i
set YMD=%DT:~0,4%-%DT:~4,2%-%DT:~6,2%
set STAMP=%DT:~0,4%-%DT:~4,2%-%DT:~6,2% %DT:~8,2%:%DT:~10,2%:%DT:~12,2%

echo 서버 모니터 데이터 백업 - %STAMP%
REM 공유 폴더에 먼저 연결 (backup-cred.txt 가 있을 때만)
if exist "%CRED%" for /f "usebackq eol=# tokens=1,2,3 delims=|" %%a in ("%CRED%") do call :netuse "%%a" "%%b" "%%c"

if not exist "%LIST%" (
  call :backup "C:\ims\monitor-backup"
  goto :done
)
for /f "usebackq eol=# delims=" %%t in ("%LIST%") do call :backup "%%t"

:done
REM 백업 결과를 모니터링 화면에서 볼 수 있도록 data\backup-status.json 으로 남긴다
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup-status.ps1" >nul 2>&1
echo 끝났습니다. 자세한 기록은 각 저장 위치의 backup.log 에 있습니다.
endlocal
exit /b 0

REM ---------- 공유 폴더 연결 ----------
:netuse
set "SH=%~1"
set "SU=%~2"
set "SP=%~3"
if "%SH%"=="" goto :eof
if "%SU%"=="" goto :eof
net use "%SH%" /delete /y >nul 2>&1
net use "%SH%" "%SP%" /user:"%SU%" >nul 2>&1
if errorlevel 1 (
  echo   [실패] 공유 연결 : %SH%  ^(계정 %SU%^)
  echo          계정·비밀번호 또는 공유 권한을 확인하세요.
  echo [%STAMP%] 공유 연결 실패 : %SH% ^(계정 %SU%^) >> "%ROOT%\data\backup-error.log"
) else (
  echo   [연결] %SH%
)
goto :eof

REM ---------- 한 곳에 백업 ----------
:backup
set "DST=%~1"
if "%DST%"=="" goto :eof
if not exist "%DST%" mkdir "%DST%" 2>nul
if not exist "%DST%" (
  echo   [실패] %DST%
  echo          폴더를 열 수 없습니다. 공유 폴더면 backup-cred.txt 에 계정을 적으세요.
  echo [%STAMP%] 실패 : 폴더를 열 수 없습니다 - %DST% >> "%ROOT%\data\backup-error.log"
  goto :eof
)
set "LOG=%DST%\backup.log"
echo. >> "%LOG%"
echo [%STAMP%] 백업 시작 : %DST% >> "%LOG%"

robocopy "%SRC%" "%DST%\daily\%YMD%" *.json *.log /R:2 /W:3 /NFL /NDL /NJH /NJS >> "%LOG%" 2>&1
set RC=%ERRORLEVEL%
robocopy "%ROOT%" "%DST%\full" /E /XD .git node_modules /XF collector.log /R:2 /W:3 /NFL /NDL /NJH /NJS >> "%LOG%" 2>&1
forfiles /p "%DST%\daily" /d -30 /c "cmd /c if @isdir==TRUE rd /s /q @path" >nul 2>&1

if %RC% GEQ 8 (
  echo   [실패] %DST%  ^(복사 오류 코드 %RC%^)
  echo [%STAMP%] 실패 : robocopy 코드 %RC% >> "%LOG%"
) else (
  echo   [완료] %DST%\daily\%YMD%
  echo [%STAMP%] 완료 : %DST%\daily\%YMD% >> "%LOG%"
)
goto :eof
