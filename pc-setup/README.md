# 사내 PC 자동 셋팅 도구

새 PC나 포맷한 PC에서 **`Setup.bat` 더블클릭 한 번**으로 아래 작업을 자동으로 진행합니다.

| 작업 | 내용 |
|---|---|
| 작업표시줄 설정 | 왼쪽 정렬, 검색창 아이콘화, 작업 보기·위젯·채팅 버튼 숨김 |
| 전원 관리 설정 | 전원 계획, 모니터 끄기, 절전 시간, 덮개 닫기 동작 |
| 기타 설정 | 파일 확장자 표시, PC 이름 변경 |
| 프로그램 설치 | winget 또는 설치파일로 무인 설치 (이미 설치된 프로그램은 건너뜀) |
| 드라이버 확인 및 설치 | 문제 장치 확인 → 드라이버 폴더 설치 → 제조사 도구(Dell) → 윈도우 업데이트 드라이버 |
| 윈도우 업데이트 | 보안·누적 업데이트 설치 (Windows 10→11 같은 버전 업그레이드는 제외) |

- 지원: Windows 10 / 11 (별도 설치 필요 없음)
- 작업이 끝나면 재부팅이 필요한 경우 재부팅 여부를 물어봅니다.
- 모든 작업 결과는 `logs\setup_PC이름_날짜.log` 에 저장됩니다.

## 폴더 구성

```
pc-setup\
├─ Setup.bat        ← 이것을 실행 (관리자 권한 자동 요청)
├─ PCSetup.ps1      ← 프로그램 본체
├─ config.json      ← 설치 목록, 설정 값
├─ installers\      ← 사내 프로그램 설치파일(.exe/.msi) 넣는 곳
├─ drivers\         ← 미리 받아둔 드라이버(.inf 포함 폴더) 넣는 곳
└─ logs\            ← 실행 기록 (자동 생성)
```

폴더째 USB나 공유폴더에 두고 사용하면 됩니다.

## 사용 방법

1. `Setup.bat` 을 더블클릭하고, 관리자 권한 확인 창에서 **예**를 누릅니다.
2. 왼쪽에서 실행할 작업을, 오른쪽에서 설치할 프로그램을 체크합니다.
3. **셋팅 시작**을 누르고 진행 상황과 로그를 확인합니다.

## 프로그램 추가하는 방법

### 방법 1. 화면에서 추가 (추천)

**+ 프로그램 추가** 버튼을 누릅니다.

- **winget 으로 설치**: 이름과 winget ID를 입력합니다.
  - ID 찾기: 명령 프롬프트에서 `winget search 프로그램명` 을 실행하거나 https://winget.run 에서 검색합니다.
- **설치파일로 설치**: 설치파일을 선택하고 무인설치 옵션을 입력합니다.
  - 선택한 파일을 `installers` 폴더로 복사할지 물어봅니다. 복사해 두면 USB로 옮길 때 함께 따라갑니다.

추가한 내용은 `config.json` 에 자동으로 저장됩니다.

### 방법 2. config.json 직접 수정

**설정 파일 열기** 버튼으로 메모장에서 수정한 뒤 **설정 다시 불러오기**를 누릅니다.

```json
"programs": [
  { "name": "Chrome", "winget": "Google.Chrome" },
  { "name": "사내 ERP", "file": "installers\\erp_setup.exe", "args": "/S" },
  { "name": "보안모듈", "file": "installers\\security.msi" },
  { "name": "가끔 쓰는 프로그램", "winget": "Zoom.Zoom", "selected": false }
]
```

| 항목 | 설명 |
|---|---|
| `name` | 화면에 표시될 이름 |
| `winget` | winget ID (winget 으로 설치할 때) |
| `file` | 설치파일 경로 (이 폴더 기준 상대경로 또는 `\\서버\공유\...` 같은 전체 경로) |
| `args` | 무인설치 옵션. `.exe` 는 보통 `/S`, `/silent`, `/quiet`, `/verysilent` 중 하나이고, `.msi` 는 비워두면 자동으로 `/qn` 이 적용됩니다 |
| `selected` | `false` 면 처음에 체크 해제된 상태로 표시 |

> 경로의 `\` 는 JSON 에서 `\\` 로 두 번 써야 합니다.

## 그 밖의 설정 값 (config.json)

```json
"taskbar": {
  "alignLeft": true,        // 작업표시줄 왼쪽 정렬 (Windows 11)
  "search": "icon",         // "hide" 숨김 / "icon" 아이콘 / "box" 검색창
  "hideTaskView": true,     // 작업 보기 버튼 숨김
  "hideWidgets": true,      // 위젯(Win11) / 뉴스 및 관심사(Win10) 끄기
  "hideChat": true          // 채팅(Teams) 버튼 숨김 (Windows 11)
},
"power": {
  "plan": "high",           // "high" 고성능 / "balanced" 균형 조정 / "" 변경 안 함
  "monitorTimeoutAC": 30,   // 모니터 끄기(분), 전원 연결 시. 0 = 사용 안 함
  "sleepTimeoutAC": 0,      // 절전 모드(분), 전원 연결 시
  "monitorTimeoutDC": 10,   // 배터리 사용 시
  "sleepTimeoutDC": 30,
  "lidCloseAC": "nothing",  // 덮개 닫을 때: "nothing" / "sleep" / "hibernate" / "shutdown"
  "lidCloseDC": "sleep",
  "disableHibernate": false // 최대 절전 모드 끄기
},
"drivers": {
  "localFolder": "drivers", // 이 폴더의 .inf 드라이버를 모두 설치
  "useVendorTool": true,    // Dell PC 면 Dell Command Update 사용
  "windowsUpdate": true     // 윈도우 업데이트로 드라이버 설치
},
"misc": {
  "showFileExtensions": true
}
```

※ 실제 JSON 파일에는 `//` 주석을 넣으면 안 됩니다. 위의 주석은 설명용입니다.

변경하고 싶지 않은 항목은 줄을 지우면 해당 설정을 건드리지 않습니다.

## 알아둘 점

- **사용자별 설정**(작업표시줄, 파일 확장자)은 프로그램을 실행한 계정에 적용됩니다. 직원 계정으로 로그인한 상태에서 실행하세요. 직원 계정이 관리자가 아니어서 다른 관리자 계정 암호를 입력해 실행하면, 그 관리자 계정에 적용됩니다.
- **winget** 은 Windows 10(1809 이상)과 11에 기본 포함되어 있습니다. 없다고 나오면 Microsoft Store 에서 "앱 설치 관리자"를 업데이트하세요.
- **Dell** 이 아닌 PC(HP, Lenovo, 조립PC)는 윈도우 업데이트로 드라이버를 설치합니다. 빠지는 드라이버가 있으면 제조사 사이트에서 받아 압축을 풀고 `drivers` 폴더에 넣으세요.
- **고성능 전원 계획**이 없는 최신 노트북에서는 경고만 남기고 기존 계획을 유지합니다.
- 윈도우 업데이트는 PC 상태에 따라 수십 분이 걸릴 수 있습니다. 재부팅한 뒤 한 번 더 실행하면 남은 업데이트가 설치됩니다.
- 회사 백신이 스크립트 실행을 막으면 `pc-setup` 폴더를 예외로 등록하세요.
