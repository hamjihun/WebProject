@echo off
rem Build PCSetup.exe on Windows with the built-in .NET Framework compiler.
rem Run this after editing PCSetup.ps1 (config.json next to the exe can be edited without rebuilding).
cd /d "%~dp0.."
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
"%CSC%" /nologo /target:winexe /optimize+ /out:PCSetup.exe /win32icon:launcher\pcsetup.ico /r:System.Windows.Forms.dll /resource:PCSetup.ps1,PCSetup.ps1 /resource:config.json,config.json launcher\PCSetupLauncher.cs
if errorlevel 1 (echo Build failed & pause & exit /b 1)
echo Built: %cd%\PCSetup.exe
pause
