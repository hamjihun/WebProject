# 코드 구조 (PCSetup.ps1)

사내 PC 자동 셋팅 도구. Windows 10/11, **Windows PowerShell 5.1 + WinForms** 단일 스크립트.
VS Code 에서 `Ctrl+Shift+O`(기호 이동) 또는 왼쪽 접기(`#region`)로 구역을 오갈 수 있습니다.

## 파일

| 파일 | 역할 |
|---|---|
| `Setup.bat` | 관리자 권한 요청 → `powershell -STA -File PCSetup.ps1` |
| `PCSetup.ps1` | 프로그램 전체 (화면 + 작업) |
| `config.json` | 설치할 프로그램, 각종 설정 값 (스키마: `docs/config.schema.json`) |
| `README.md` | 사용자용 설명 (진행 순서, 설치 방식, 설정 키) |
| `logs/` | 실행 로그 (git 제외) |
| `installers/`, `drivers/` | 로컬 설치파일/드라이버 (git 제외, 보통 USB 사용) |

실행 환경: USB `프로그램USB` 의 `【 Application 】` 폴더에서 설치파일을 찾음.
재부팅 후 이어하기 시 도구가 `C:\ProgramData\PCSetup\app` 에 복사되어 거기서 실행됨 (`resume.json` 도 `C:\ProgramData\PCSetup`).

## 실행 흐름

```
Setup.bat (관리자) → PCSetup.ps1
  ├─ 관리자/중복 실행 확인 (Global\PCSetupTool 뮤텍스)
  ├─ $Common  : 화면/작업 공용 함수 (설치파일 찾기, 설치 확인, 정품 인증)
  ├─ Read-Config
  ├─ $Worker  : 실제 작업 스크립트블록 → 별도 런스페이스(STA)에서 실행
  ├─ 화면 구성 (WinForms) / 화면 데이터 / 이벤트
  └─ [셋팅 시작] → Start-Setup → $Plan 만들고 $Worker 실행
       ↕ $Sync (동기화 해시테이블: 로그 큐, 작업/프로그램 상태, 안내창, 취소, 재부팅 요청)
     타이머가 $Sync 를 읽어 화면(상태판, 로그, 안내창) 갱신
```

- `$Sync` 주요 키: `Queue`(로그), `TaskStates`, `ProgStates`, `Notices`, `Guide`/`GuideWait`/`GuideAck`(노란 안내창),
  `Cancel`, `ResumeRequested`, `RebootRequired`, `RebootStarted`, `Bg`(백그라운드 업데이트), `ErrorCount`/`WarnCount`.
- `$Plan`: `Steps`(실행할 작업 Id 목록), `Config`, `AppRoot`, `Site`, `Printers`, `Network`, `WorkerCode`, `CommonCode`, `Background`.
- 윈도우 업데이트는 `$Plan.WorkerCode` 로 **두 번째 런스페이스**(`Background=$true`)를 띄워 프로그램 설치와 동시에 진행.

## 작업 목록 (`$TaskDefs`, 실행 순서)

| Id | 함수 (Worker) |
|---|---|
| `uac` | `Set-Uac` |
| `network` | `Set-Network` |
| `update` | `Start-BackgroundUpdate` → `Invoke-UpdateCycle` (백그라운드) |
| `programs` | `Install-Programs` (설치 엔진, 아래) |
| `fonts` | `Install-Fonts` |
| `taskbar` | `Set-Taskbar`, `Remove-TaskbarPins`, `Close-Leftovers` |
| `desktop` | `Set-DesktopIcons` |
| `officeLinks` | `New-OfficeShortcuts` |
| `misc` | `Set-Misc` (확장명, PC 이름) |
| `power` | `Set-Power` |
| `startmenu` | `Set-StartMenu` (Win11: start2.bin / Win10: 레이아웃 정책 잠깐 적용) |
| `extensions` | `Update-Browsers`, `Install-BrowserExtensions` |
| `edge` | `Set-EdgeSettings` (권장 정책, `Set-EdgeProfilePrefs`, `Add-BrowserBookmarks`, `New-EdgeDesktopLinks`) |
| `chrome` | `Set-ChromeSettings` |
| `printer` | `Install-Printers` |
| `drivers` | `Install-Drivers` |
| `docCentral` | `Install-DocCentral` (업데이트 끝난 뒤, 재부팅 시작하면 멈추고 이어하기) |
| `activation` | `Test-Activation` |

화면 분류(`$TaskCategories`)는 표시용이고 실행 순서는 `$TaskDefs` 순서.
메인 루프는 `#region 실행` 의 `for ($s ...)` + `switch ($step.Id)`.

## 설치 엔진 (`#region 2. 프로그램 설치`)

- `New-InstallJob` → `Start-InstallJob` → 반복: `Update-InstallJob` → `Complete-InstallJob`
- `Invoke-InstallJobs`: `install.staggerSeconds` 간격으로 실행, 동시에 진행, 1초마다 프로세스/창 목록 갱신.
- 프로세스 트리 추적: `Update-JobTree` (Win32_Process ParentProcessId + CreationDate).
- 설치 확인: `Test-Installed` (`installed` 파일 경로 / `installedName` 프로그램 추가/제거 이름). 종료코드 0 이어도 확인 안 되면 실패 처리.
- 실패하면 마지막에 1번 재설치 (`noRetry` 제외, 그사이 설치된 것 제외), `fallbackUrl`, `winget` → USB 대체.
- `waitInstalled`: 설치 프로그램이 먼저 끝나도 설치 확인까지 기다림 (V3 EPP 에이전트).

### 설치 화면 자동 조작 (`#region 설치 화면 자동 조작`)

- UI Automation(`System.Windows.Automation`)으로 설치 창의 버튼/체크박스/입력칸을 찾음.
- `Find-UIControl` + `Test-UIVisible`: **숨겨진 버튼 제외** (InstallShield 는 다른 페이지 버튼을 숨긴 채 가짐 → IsOffscreen, 크기, Win32 IsWindowVisible 로 거름).
- `Find-UIButton` 은 제목줄 버튼(닫기 X 등) 제외 (`Test-TitleBarButton`).
- `Step-AutoJob`: `config.json` 의 `auto` 단계를 하나씩 진행 (`click`, `alsoClick`, `uncheck`, `radio`, `select`, `setText`, `clickAt`, `close`, `process`, `waitIdle`, `optional`, `timeout` …). 키 설명은 스키마/README.
- `dismiss`/`dismissWhen`: 언제든 보이면 누를 팝업 버튼.
- `Invoke-ClickAt`: 버튼을 못 찾는 화면(반디집)용 마우스 위치 클릭. 창 복원·맨 앞·클릭 위치 확인 후 클릭, DPI 컨텍스트 복원.
- `Wait-RebootSafe`: 재부팅 버튼 누르기 전 업데이트/다른 설치 끝났는지 확인.
- 제한시간이 지나면 '직접 진행' 으로 전환하고 `Write-WindowDump` 로 창의 버튼 이름을 로그에 남김 (설정 맞출 때 참고).

## 재부팅 후 이어하기

- `Save-Checkpoint`(단계마다) / `Register-Resume`: `resume.json` 저장 + 도구를 `C:\ProgramData\PCSetup\app` 에 복사
  + 작업 스케줄러 `PCSetupResume`(로그온 20초 뒤, SID) + RunOnce 예비.
- 다시 켜지면 `-Resume` 으로 실행 → `Read-ResumeState` → `Apply-ResumeState` → `Start-Setup $true`.
- 모든 작업이 끝나면 `Clear-Resume`. 문서중앙화가 재부팅을 시작하면(`$Sync.RebootStarted`) 지우지 않고 멈춤.

## 화면 (GUI)

- 왼쪽 작업 트리(`$tvTasks`) / 실행 중에는 상태판(`$lvTasks`, `$lvPrograms`, `Set-StatusRow`).
- 노란 안내창(`Update-GuideWindow`), 진행 순서 창(`Show-OrderWindow`), 마무리 체크리스트(`Show-Checklist`, 편집 → `config.json` 저장),
  업데이트 재부팅 카운트다운(`Show-RebootCountdown`).
- `Start-Setup`: 입력 확인 → `$Plan`/`$Sync` 생성 → 런스페이스 실행 → 타이머로 갱신 → 끝나면 결과 메시지/체크리스트.

## 브라우저 설정 원칙

- 직원이 바꿀 수 있게: 정책은 `...\Recommended` (권장값). `Clear-LockedPolicies` 로 예전 고정값 제거.
- 권장값이 안 되는 것(다운로드 단추, 즐겨찾기 모음 항상)은 프로필 `Preferences` 를 **글자 단위로** 수정 (`Set-JsonPrefBool`) — 파일 전체를 ConvertTo-Json 으로 다시 쓰지 않음 (5.1 에서 깨질 수 있음).
- 즐겨찾기는 정책이 아니라 프로필 `Bookmarks` 파일에 직접 추가 (직원이 지울 수 있게).
- 확장프로그램만 `ExtensionInstallForcelist` (강제).
