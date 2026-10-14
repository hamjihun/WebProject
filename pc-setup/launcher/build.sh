#!/bin/sh
# Linux/mono 에서 PCSetup.exe 빌드 (PCSetup.ps1 과 config.json 을 exe 안에 포함)
set -e
cd "$(dirname "$0")/.."
mcs -nologo -sdk:4.5 -target:winexe -optimize+ -out:PCSetup.exe \
    -win32icon:launcher/pcsetup.ico \
    -r:System.Windows.Forms.dll \
    -resource:PCSetup.ps1,PCSetup.ps1 \
    -resource:config.json,config.json \
    launcher/PCSetupLauncher.cs
echo "built: $(pwd)/PCSetup.exe"
