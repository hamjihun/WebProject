; 사내 문서 AI 설치 프로그램 (Inno Setup 6)
; 빌드:  iscc packaging\installer.iss   (먼저 PyInstaller 로 dist\LocalDocAI 를 만든 뒤)

#define AppName "사내 문서 AI"
#define AppExe "LocalDocAI.exe"
#define AppVersion GetEnv("APP_VERSION")
#if AppVersion == ""
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{8E2B6A4C-3D1F-4B7A-9C5E-2F6A1D8B4C71}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=사내 문서 AI
DefaultDirName={localappdata}\Programs\LocalDocAI
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; 관리자 권한 없이 사용자 계정에 설치
PrivilegesRequired=lowest
OutputDir=..\dist-installer
OutputBaseFilename=LocalDocAI-Setup-{#AppVersion}
SetupIconFile=app.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"

[Tasks]
Name: "desktopicon"; Description: "바탕화면에 바로가기 만들기"; GroupDescription: "추가 작업:"

[Files]
Source: "..\dist\LocalDocAI\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; 이전 버전의 라이브러리가 섞이지 않도록 정리
Type: filesandordirs; Name: "{app}\_internal"

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{#AppName} 실행하기"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM {#AppExe} /F"; Flags: runhidden; RunOnceId: "StopApp"

[Code]
const
  OLLAMA_SETUP_URL = 'https://ollama.com/download/OllamaSetup.exe';
  OLLAMA_PAGE_URL = 'https://ollama.com/download';
  COLOR_OK = $00559D1F;   { BGR: 초록 }
  COLOR_BAD = $003B3BC6;  { BGR: 빨강 }

var
  OllamaPage: TWizardPage;
  StatusLabel: TNewStaticText;
  DownloadButton, RecheckButton: TNewButton;
  LinkLabel: TNewStaticText;
  TimerID: LongWord;

function SetTimer(hWnd: LongWord; nIDEvent, uElapse: LongWord; lpTimerFunc: LongWord): LongWord;
  external 'SetTimer@user32.dll stdcall';
function KillTimer(hWnd: LongWord; uIDEvent: LongWord): BOOL;
  external 'KillTimer@user32.dll stdcall';

{ Ollama 설치 여부: 흔한 설치 위치와 PATH(방금 설치해 반영 안 된 값 포함)를 찾아본다 }
function FindOllama(): String;
var
  Paths, S: String;
begin
  Result := ExpandConstant('{localappdata}\Programs\Ollama\ollama.exe');
  if FileExists(Result) then Exit;
  if GetEnv('ProgramFiles') <> '' then begin
    Result := AddBackslash(GetEnv('ProgramFiles')) + 'Ollama\ollama.exe';
    if FileExists(Result) then Exit;
  end;
  if GetEnv('ProgramW6432') <> '' then begin
    Result := AddBackslash(GetEnv('ProgramW6432')) + 'Ollama\ollama.exe';
    if FileExists(Result) then Exit;
  end;
  Paths := GetEnv('PATH');
  if RegQueryStringValue(HKCU, 'Environment', 'Path', S) then
    Paths := Paths + ';' + S;
  Result := FileSearch('ollama.exe', Paths);
end;

function OllamaInstalled(): Boolean;
begin
  Result := FindOllama() <> '';
end;

procedure UpdateOllamaStatus();
var
  Found: Boolean;
begin
  Found := OllamaInstalled();
  if Found then begin
    StatusLabel.Caption := '확인됨: Ollama가 설치되어 있습니다. [다음]을 눌러 계속하세요.';
    StatusLabel.Font.Color := COLOR_OK;
    DownloadButton.Enabled := False;
  end else begin
    StatusLabel.Caption := '아직 Ollama가 설치되지 않았습니다. 설치가 끝나면 자동으로 확인됩니다.';
    StatusLabel.Font.Color := COLOR_BAD;
    DownloadButton.Enabled := True;
  end;
  if (OllamaPage <> nil) and (WizardForm.CurPageID = OllamaPage.ID) then
    WizardForm.NextButton.Enabled := Found;
end;

procedure OllamaTimerProc(Wnd: LongWord; Msg: LongWord; IdEvent: LongWord; Time: LongWord);
begin
  UpdateOllamaStatus();
end;

procedure StartOllamaTimer();
begin
  if TimerID = 0 then
    TimerID := SetTimer(0, 0, 2000, CreateCallback(@OllamaTimerProc));
end;

procedure StopOllamaTimer();
begin
  if TimerID <> 0 then begin
    KillTimer(0, TimerID);
    TimerID := 0;
  end;
end;

procedure OpenUrl(const Url: String);
var
  Code: Integer;
begin
  ShellExec('open', Url, '', '', SW_SHOWNORMAL, ewNoWait, Code);
end;

procedure DownloadClick(Sender: TObject);
begin
  OpenUrl(OLLAMA_SETUP_URL);
end;

procedure LinkClick(Sender: TObject);
begin
  OpenUrl(OLLAMA_PAGE_URL);
end;

procedure RecheckClick(Sender: TObject);
begin
  UpdateOllamaStatus();
  if not OllamaInstalled() then
    MsgBox('아직 Ollama를 찾지 못했습니다.' + #13#10 +
      'Ollama 설치 프로그램이 끝까지 완료되었는지 확인해 주세요.', mbInformation, MB_OK);
end;

procedure InitializeWizard();
var
  Intro, Note: TNewStaticText;
begin
  OllamaPage := CreateCustomPage(wpWelcome,
    'AI 엔진(Ollama) 설치 확인',
    '사내 문서 AI는 이 PC 안에서 AI를 실행하기 위해 무료 프로그램 Ollama가 필요합니다.');

  Intro := TNewStaticText.Create(OllamaPage);
  Intro.Parent := OllamaPage.Surface;
  Intro.Width := OllamaPage.SurfaceWidth;
  Intro.WordWrap := True;
  Intro.AutoSize := True;
  Intro.Caption :=
    '설치 방법' + #13#10 + #13#10 +
    '1. 아래 [Ollama 내려받기] 버튼을 눌러 설치 파일(OllamaSetup.exe)을 받습니다.' + #13#10 +
    '2. 받은 파일을 실행해 Ollama 설치를 마칩니다. (이 창은 닫지 마세요)' + #13#10 +
    '3. 설치가 끝나면 자동으로 확인되고 [다음] 버튼이 켜집니다.' + #13#10 + #13#10 +
    '이미 Ollama가 설치되어 있다면 바로 [다음]을 누르면 됩니다.';

  DownloadButton := TNewButton.Create(OllamaPage);
  DownloadButton.Parent := OllamaPage.Surface;
  DownloadButton.Caption := 'Ollama 내려받기';
  DownloadButton.Left := 0;
  DownloadButton.Top := Intro.Top + Intro.Height + ScaleY(16);
  DownloadButton.Width := ScaleX(150);
  DownloadButton.Height := WizardForm.NextButton.Height + ScaleY(4);
  DownloadButton.OnClick := @DownloadClick;

  RecheckButton := TNewButton.Create(OllamaPage);
  RecheckButton.Parent := OllamaPage.Surface;
  RecheckButton.Caption := '다시 확인';
  RecheckButton.Left := DownloadButton.Left + DownloadButton.Width + ScaleX(8);
  RecheckButton.Top := DownloadButton.Top;
  RecheckButton.Width := ScaleX(100);
  RecheckButton.Height := DownloadButton.Height;
  RecheckButton.OnClick := @RecheckClick;

  LinkLabel := TNewStaticText.Create(OllamaPage);
  LinkLabel.Parent := OllamaPage.Surface;
  LinkLabel.Caption := '다운로드 페이지 열기: ' + OLLAMA_PAGE_URL;
  LinkLabel.Top := DownloadButton.Top + DownloadButton.Height + ScaleY(10);
  LinkLabel.Font.Color := clBlue;
  LinkLabel.Font.Style := [fsUnderline];
  LinkLabel.Cursor := crHand;
  LinkLabel.OnClick := @LinkClick;

  StatusLabel := TNewStaticText.Create(OllamaPage);
  StatusLabel.Parent := OllamaPage.Surface;
  StatusLabel.Top := LinkLabel.Top + LinkLabel.Height + ScaleY(18);
  StatusLabel.Width := OllamaPage.SurfaceWidth;
  StatusLabel.WordWrap := True;
  StatusLabel.AutoSize := True;
  StatusLabel.Font.Style := [fsBold];

  Note := TNewStaticText.Create(OllamaPage);
  Note.Parent := OllamaPage.Surface;
  Note.Top := StatusLabel.Top + ScaleY(40);
  Note.Width := OllamaPage.SurfaceWidth;
  Note.WordWrap := True;
  Note.AutoSize := True;
  Note.Font.Color := clGray;
  Note.Caption := '회사 보안 정책으로 다운로드가 막히면, 인터넷이 되는 PC에서 OllamaSetup.exe를 받아 옮겨 설치하세요.';

  UpdateOllamaStatus();
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = OllamaPage.ID then begin
    UpdateOllamaStatus();
    StartOllamaTimer();
  end else
    StopOllamaTimer();

  if CurPageID = wpFinished then
    WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10 + #13#10 +
      '처음 실행하면 PC 메모리에 맞는 AI 모델(약 2~4GB)을 받는 화면이 나옵니다. ' +
      '안내에 따라 [모델 받기 시작]을 눌러 주세요.';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = OllamaPage.ID) and not OllamaInstalled() then begin
    MsgBox('Ollama를 먼저 설치해 주세요.' + #13#10 +
      '[Ollama 내려받기]로 받은 파일을 실행해 설치가 끝나면 [다음]이 켜집니다.', mbInformation, MB_OK);
    Result := False;
  end;
end;

procedure DeinitializeSetup();
begin
  StopOllamaTimer();
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usPostUninstall then begin
    DataDir := ExpandConstant('{localappdata}\LocalDocAI');
    if DirExists(DataDir) then
      if SuppressibleMsgBox('올린 문서와 대화 기록도 함께 삭제할까요?' + #13#10 + #13#10 +
        '[아니요]를 누르면 나중에 다시 설치했을 때 그대로 이어서 쓸 수 있습니다.' + #13#10 +
        '(저장 위치: ' + DataDir + ')', mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES then
        DelTree(DataDir, True, True, True);
  end;
end;
