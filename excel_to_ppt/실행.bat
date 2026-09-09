@echo off
chcp 65001 > nul
cd /d "%~dp0"
python -c "import openpyxl, pptx" 2>nul || (
  echo 필요한 라이브러리를 설치합니다...
  python -m pip install -r requirements.txt
)
python gui.py
if errorlevel 1 pause
