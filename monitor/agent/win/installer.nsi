; 서버 모니터 에이전트 설치 프로그램 (NSIS 3)
; 빌드: makensis installer.nsi  →  ../../dist/ServerMonitorAgent-Setup.exe
Unicode true
!include "MUI2.nsh"
!include "nsDialogs.nsh"
!include "LogicLib.nsh"

!define APPNAME "IMS Monitoring Agent"
!define APPID "IMSMonitoringAgent"
!define VERSION "1.0.0"
!define PUBLISHER "ILSAN IT"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPID}"

Name "${APPNAME}"
OutFile "..\..\dist\IMS-Monitoring-Agent-Setup.exe"
InstallDir "$PROGRAMFILES64\${APPID}"
InstallDirRegKey HKLM "${UNINST_KEY}" "InstallLocation"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
BrandingText "${APPNAME} ${VERSION}"

; 아이콘 (설치/제거 프로그램, 프로그램 추가/제거, 트레이 공용)
!define MUI_ICON "app.ico"
!define MUI_UNICON "app.ico"

; exe 속성 정보
VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=1042 "ProductName" "${APPNAME}"
VIAddVersionKey /LANG=1042 "CompanyName" "${PUBLISHER}"
VIAddVersionKey /LANG=1042 "FileDescription" "${APPNAME} Setup"
VIAddVersionKey /LANG=1042 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=1042 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=1042 "LegalCopyright" "${PUBLISHER}"

Var Url
Var Token
Var Interval
Var hUrl
Var hToken
Var hInterval

!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "${APPNAME} 설치"
!define MUI_WELCOMEPAGE_TITLE_3LINES
!define MUI_WELCOMEPAGE_TEXT "이 프로그램은 이 서버의 CPU / 메모리 / 디스크 / 네트워크 상태를 IMS 모니터링 서버로 전송합니다.$\r$\n$\r$\n설치 후 시스템 시작 시 자동으로 실행되며, 작업 표시줄 트레이에 실행 상태 아이콘이 표시됩니다.$\r$\n$\r$\n계속하려면 다음을 누르세요."
!define MUI_FINISHPAGE_TITLE "설치 완료"
!define MUI_FINISHPAGE_TEXT "에이전트가 실행 중입니다.$\r$\n$\r$\n작업 표시줄 오른쪽 트레이의 원형 아이콘이 초록색이면 정상 전송 중, 빨간색이면 전송 실패입니다.$\r$\n아이콘을 두 번 클릭하면 모니터링 화면이 열립니다.$\r$\n$\r$\n제거는 [설정 > 앱] 또는 [프로그램 추가/제거]에서 $\"IMS Monitoring Agent$\" 를 선택하면 됩니다."

!insertmacro MUI_PAGE_WELCOME
Page custom ConfigPage ConfigPageLeave
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Korean"

Function .onInit
  StrCpy $Url "http://192.168.0.9:15138/api/metrics"
  StrCpy $Token ""
  StrCpy $Interval "5"
  ; 재설치 시 기존 설정 불러오기
  IfFileExists "$INSTDIR\agent.conf" 0 done
    ClearErrors
    FileOpen $0 "$INSTDIR\agent.conf" r
    loop:
      FileRead $0 $1
      IfErrors close
      StrCpy $2 $1 4
      ${If} $2 == "URL="
        StrCpy $Url $1 "" 4
        Call TrimNL
      ${EndIf}
      StrCpy $2 $1 6
      ${If} $2 == "TOKEN="
        StrCpy $Token $1 "" 6
        Call TrimNL2
      ${EndIf}
      Goto loop
    close:
    FileClose $0
  done:
FunctionEnd

Function TrimNL
  Push $Url
  Call Trim
  Pop $Url
FunctionEnd
Function TrimNL2
  Push $Token
  Call Trim
  Pop $Token
FunctionEnd
; 문자열 끝의 CR/LF 제거
Function Trim
  Exch $R0
  Push $R1
  again:
    StrCpy $R1 $R0 1 -1
    ${If} $R1 == "$\r"
    ${OrIf} $R1 == "$\n"
      StrCpy $R0 $R0 -1
      Goto again
    ${EndIf}
  Pop $R1
  Exch $R0
FunctionEnd

Function ConfigPage
  !insertmacro MUI_HEADER_TEXT "전송 설정" "IMS 모니터링 서버 주소와 토큰을 입력하세요."
  nsDialogs::Create 1018
  Pop $0
  ${If} $0 == error
    Abort
  ${EndIf}

  ${NSD_CreateLabel} 0 0 100% 24u "수집기(IMS 서버) 전송 주소:  예) http://192.168.0.9:15138/api/metrics"
  Pop $0
  ${NSD_CreateText} 0 26u 100% 13u $Url
  Pop $hUrl

  ${NSD_CreateLabel} 0 48u 100% 12u "토큰 (수집기 설치 시 정한 값과 동일하게):"
  Pop $0
  ${NSD_CreateText} 0 62u 100% 13u $Token
  Pop $hToken

  ${NSD_CreateLabel} 0 84u 100% 12u "전송 간격 (초):"
  Pop $0
  ${NSD_CreateNumber} 0 98u 60u 13u $Interval
  Pop $hInterval

  ${NSD_CreateLabel} 0 122u 100% 24u "에이전트는 읽기만 하며 서버 설정을 변경하지 않습니다. 부하는 CPU 1% 미만입니다."
  Pop $0

  nsDialogs::Show
FunctionEnd

Function ConfigPageLeave
  ${NSD_GetText} $hUrl $Url
  ${NSD_GetText} $hToken $Token
  ${NSD_GetText} $hInterval $Interval
  StrCpy $0 $Url 4
  ${If} $0 != "http"
    MessageBox MB_ICONEXCLAMATION|MB_OK "전송 주소는 http:// 또는 https:// 로 시작해야 합니다."
    Abort
  ${EndIf}
  ${If} $Interval < 2
    StrCpy $Interval "5"
  ${EndIf}
FunctionEnd

Section "Install"
  SetOutPath "$INSTDIR"
  File "agent.ps1"
  File "tray.ps1"
  File "tray.vbs"
  File "service.ps1"
  File "app.ico"

  ; 설정 파일
  FileOpen $0 "$INSTDIR\agent.conf" w
  FileWrite $0 "URL=$Url$\r$\n"
  FileWrite $0 "TOKEN=$Token$\r$\n"
  FileWrite $0 "INTERVAL=$Interval$\r$\n"
  FileWrite $0 "SKIPCERT=0$\r$\n"
  FileClose $0

  ; 자동 실행 등록 + 시작
  DetailPrint "작업 스케줄러 등록 중..."
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\service.ps1" -Install'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONEXCLAMATION|MB_OK "자동 실행 등록에 실패했습니다 (코드 $0). 설치 로그를 확인하세요."
  ${EndIf}

  ; 프로그램 추가/제거 등록
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINST_KEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKLM "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\app.ico"
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1
  WriteRegDWORD HKLM "${UNINST_KEY}" "EstimatedSize" 512

  ; 현재 사용자에게 트레이 아이콘 바로 표시
  Exec 'wscript.exe "$INSTDIR\tray.vbs"'
SectionEnd

Section "Uninstall"
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\service.ps1" -Uninstall'
  Pop $0
  Delete "$INSTDIR\agent.ps1"
  Delete "$INSTDIR\tray.ps1"
  Delete "$INSTDIR\tray.vbs"
  Delete "$INSTDIR\service.ps1"
  Delete "$INSTDIR\agent.conf"
  Delete "$INSTDIR\app.ico"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  SetShellVarContext all
  RMDir /r "$APPDATA\${APPID}"
  DeleteRegKey HKLM "${UNINST_KEY}"
SectionEnd
