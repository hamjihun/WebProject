# 일산 사내 IT 프로젝트 (WebProject)

사내 서버 모니터링·메모/일정 웹앱(IMS 수집기)과 연말 경품 추첨 화면입니다. 외부 패키지 없이 **Node.js 내장 모듈만** 씁니다 (`npm install` 필요 없음).

> 처음 보는 사람·AI 는 이 파일 → `CLAUDE.md`(작업 규칙) → `monitor/HANDOFF.md`(진행 상태·코드 규약·파일 표) 순서로 읽으세요.

## 폴더 구조

| 폴더 | 내용 | 실제 위치 (IMS 서버 192.168.0.9) |
|---|---|---|
| `monitor/` | **IMS 수집기** — 서버 모니터링, 보안 감시, 백업 현황, 메모, 일정, 계정 관리. `server.js` 하나가 포트 15138 에서 화면과 API 를 모두 맡음 | `C:\ims\monitor` |
| `monitor/agent/win/` | **Windows 에이전트** (PowerShell) — 각 서버에서 5초마다 상태를 수집기로 보냄. `installer.nsi` 로 설치 파일 빌드 | 각 서버 `C:\Program Files\IMSMonitoringAgent` |
| `monitor/agent/linux/`, `monitor/agent/esxi/` | 리눅스·시놀로지 NAS·ESXi 에이전트 (sh / python) | 각 장비 |
| `monitor/public/` | 화면 (html + `common.js`). 빌드 과정 없음, 파일 그대로 제공 | |
| `monitor/deploy/` | IMS 서버 설치(`setup-collector.cmd`)·백업 스크립트 | |
| `monitor/dist/` | 빌드된 에이전트 설치 파일(`IMS-Monitoring-Agent-Setup.exe`), `old/` 는 되돌리기용 옛 버전 | |
| `monitor/data/` | 운영 데이터 (계정·설정·이력). **git 에 올리지 않음** | |
| `event/` | **연말 경품 추첨** (`/event`). 수집기가 `../event/event.js` 를 불러 같은 포트로 제공 | `C:\ims\event` |
| `monitor/tools/check.js` | 문법 검사 (커밋 전에 실행) | |
| `client/`, `public/` (맨 위) | 예전 파일 — 지금 작업과 관계없음 | |

## 주요 파일 (monitor/)

| 파일 | 하는 일 |
|---|---|
| `server.js` | HTTP 서버·라우팅·로그인 확인·에이전트 수신(`/api/metrics`)·상태 저장. **VERSION** 이 화면의 `UI_VERSION` 과 같아야 함 |
| `alerts.js` | 알림 판단(CPU·디스크·오프라인·백업·보안)과 텔레그램 전송, 설정 |
| `security.js` | 서버별 보안 이벤트 보관·요약 |
| `agentupd.js` | 에이전트 버전 보관함·일괄 업데이트·되돌리기·종료 비밀번호 |
| `auth.js` | 계정·세션·화면별 권한 |
| `devices.js` | 에이전트 없는 장비 Ping·포트 확인 |
| `memo.js`, `schedule.js` | 메모·일정 앱 |
| `agent/win/agent.ps1` | 에이전트 본체 (수집·전송·자체 보호) — `security.ps1`(보안 감시), `fswatch.ps1`(랜섬웨어 파일 감시), `backup.ps1`/`veeam.ps1`(백업 확인), `selfupdate.ps1`(자동 업데이트), `service.ps1`(설치·제거), `tray.ps1`(트레이 아이콘), `watchdog.ps1`(감시자) |

## 내 PC 에서 실행해 보기

VS Code: **실행 및 디버그(Ctrl+Shift+D) → "수집기 + 모의 에이전트"** → 브라우저 `http://localhost:8787` (처음 계정은 `monitor/README.md` 참고)

터미널:
```
cd monitor
node server.js
node agent/simulate.js      (다른 터미널에서, 가짜 서버 데이터)
```

## 커밋 전 검사

VS Code: **터미널 → 작업 실행 → "문법 검사"** 또는
```
node monitor/tools/check.js
```

## 꼭 지킬 것 (자세한 건 `monitor/HANDOFF.md` 의 "코드 규약")

- **인코딩**: `.ps1`·`.nsi` = UTF-8 **BOM** + CRLF (`agent.ps1` 만 LF), `.cmd`·`.bat`·`.vbs` = **CP949(ANSI)** + CRLF, 나머지 UTF-8. VS Code 설정(`.vscode/settings.json`)이 이대로 열고 저장합니다.
- **PowerShell 5.1** 문법만 (Windows Server 2012~2019 기본). PS7 전용 문법 금지.
- **버전 동시 수정**: 수집기 = `server.js` VERSION + `public/index.html`·`public/common.js` 의 UI_VERSION. 에이전트 = `agent.ps1` `$AgentVersion` + `installer.nsi` VERSION + `security.ps1` `$Ver`, 그리고 설치 파일 다시 빌드.
- **서버를 멈추게 하는 자동 조치 금지** (네트워크 차단, 프로세스 강제 종료, 재부팅 등). 알림만.
- 비밀번호·토큰은 커밋 금지 (`monitor/data/`, `deploy/backup-cred.txt` 는 .gitignore).

## 배포

1. GitHub ZIP 받기 → `monitor` 를 IMS 서버 `C:\ims\monitor` 에, `event` 를 `C:\ims\event` 에 덮어쓰기
2. `C:\ims\monitor\deploy\setup-collector.cmd` 를 관리자 권한으로 실행 (수집기 다시 시작)
3. 에이전트: 서버 모니터링 화면 **⬆ 에이전트** 에서 새 버전 배포 (자동 업데이트, 실패하면 자동 되돌림)
