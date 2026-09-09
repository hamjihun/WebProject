@echo off
chcp 65001 > nul
cd /d "%~dp0"
echo Windows 실행 파일(MonthlyPPT.exe)을 만듭니다. (Python 이 설치되어 있어야 합니다)
python -m pip install -q -r requirements.txt pyinstaller
python -m PyInstaller --noconfirm --clean --onefile --windowed --name MonthlyPPT --icon app.ico ^
  --add-data "mapping.json;." --add-data "app.ico;." --add-data "app.png;." ^
  --collect-all tkinterdnd2 gui.py
if errorlevel 1 (echo 빌드 실패 & pause & exit /b 1)
copy /y mapping.json dist\ > nul
copy /y README.md dist\ > nul
echo.
echo 완료: dist\MonthlyPPT.exe  (mapping.json 과 같은 폴더에 두고 실행하세요)
pause
