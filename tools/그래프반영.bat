@echo off
chcp 65001 >nul
rem ------------------------------------------------------------
rem  사용법: 표를 고친 pptx 파일을 이 배치 파일 아이콘 위에 끌어다 놓으세요.
rem  같은 폴더에 "파일명_그래프반영.pptx" 가 만들어집니다.
rem  처음 한 번만 파이썬(python.org, "Add Python to PATH" 체크)이 필요합니다.
rem ------------------------------------------------------------
if "%~1"=="" (
    echo pptx 파일을 이 아이콘 위에 끌어다 놓으세요.
    pause
    exit /b 1
)
where python >nul 2>nul
if errorlevel 1 (
    echo 파이썬이 설치되어 있지 않습니다. https://www.python.org/downloads/ 에서 설치하고
    echo 설치 화면의 "Add Python to PATH" 를 체크해 주세요.
    pause
    exit /b 1
)
python -c "import lxml, openpyxl" >nul 2>nul
if errorlevel 1 (
    echo 필요한 패키지를 설치합니다...
    python -m pip install --quiet lxml openpyxl
)
set "OUT=%~dpn1_그래프반영.pptx"
python "%~dp0sync_chart_from_table.py" "%~1" "%OUT%"
if errorlevel 1 (
    echo.
    echo 오류가 발생했습니다. 위 메시지를 확인해 주세요.
) else (
    echo.
    echo 완료: %OUT%
)
pause
