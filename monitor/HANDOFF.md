# 인수인계 (새 세션에서 이 파일부터 읽기)

ILSAN IMS 서버 모니터링. 300인 제조업 사내 서버(Windows Server 2016 위주)의 CPU/메모리/디스크/네트워크를 모아 IMS 옆 화면에서 보고 텔레그램으로 알린다.
사용자는 IT 담당자이며 개발자가 아니다. 설명은 한국어, 단계별로, 명령은 복사해 쓸 수 있게.

## 구성 (모두 이 저장소 `monitor/` 안, 외부 패키지 없음)
| 위치 | 역할 | 실행 위치 |
|---|---|---|
| `server.js` (v1.7.0) | 수집기. Node.js 내장 http. 데이터 수신, 일별 디스크 스냅샷, 상태 스냅샷 `data/state.json`, 카드 순서, 정적 파일 | IMS 서버 192.168.0.9, 포트 **15138**, 작업 스케줄러 `ServerMonitorCollector` |
| `alerts.js` | 알림 엔진. 임계치/지속시간/완충/재알림/복귀/조용시간, 전체·규칙별·서버별 끄기, 텔레그램 전송, 월별 로그 `data/alerts-YYYY-MM.log` | (수집기 내부) |
| `public/index.html` | 대시보드. `UI_VERSION` 상수를 server.js `VERSION` 과 항상 같게 유지 (다르면 화면에 구버전 경고) | 브라우저 |
| `agent/win/` | Windows 에이전트 소스: `agent.ps1`(수집), `tray.ps1`(트레이), `service.ps1`(작업 등록), `start.ps1/.vbs`(바탕화면 실행), `installer.nsi`(NSIS), `make-icon.py`(아이콘) | 각 Windows 서버 |
| `dist/IMS-Monitoring-Agent-Setup.exe` (v1.3.0) | 빌드된 설치 파일. `agent/win/build.sh` (makensis) 로 재빌드 | 각 Windows 서버 |
| `agent/linux/` | Linux 에이전트 `ims-agent.sh` + `install.sh`(설치/`ims-agent` 관리 명령) | 각 Linux 서버 |
| `deploy/` | 수집기 설치 스크립트(`setup-collector.cmd` 더블클릭 → `install-collector-windows.ps1 -Public -Port 15138`), 프록시 예시, IMS iframe 예시 | IMS 서버 |
| `agent/simulate.js` | 가짜 서버 3대 전송 (테스트용) | 개발 |
| `SETUP-IMS.md`, `README.md` | 사용자용 구축 순서 / 참조 | |

## 운영 사실
- 에이전트 → `http://192.168.0.9:15138/api/metrics` 로 5초마다 POST. 토큰 기본값 `ilsan-mon-2026` (설치 파일과 `deploy/setup-collector.cmd` 에 기본값으로 들어 있음. 저장소가 Public 이라 사용자에게 Private 전환과 토큰 변경을 권고했음).
- 현재 연결된 서버: 사용자 PC(DESKTOP-291F7VR), 그룹웨어 서버, MES 서버, ACE ERP 서버. 텔레그램 봇 연결 완료.
- 업그레이드 절차: `monitor` 폴더 덮어쓰기(`data/` 유지) → `deploy\setup-collector.cmd` 재실행. 설치 스크립트가 기존 node.exe 를 종료함. 화면 오른쪽 위 "수집기 vX" 로 확인.
- 에이전트 업그레이드: 새 Setup.exe 를 다음만 눌러 재설치 (설정 유지). 제거 시 `/api/unregister` 호출로 화면에서 자동 삭제.

## 코드 규약
- 버전 올릴 때 `server.js` VERSION, `index.html` UI_VERSION 동시 수정. 에이전트는 `installer.nsi` VERSION.
- Windows 파일 인코딩: `.ps1`/`.nsi` UTF-8 **BOM** + CRLF, `.cmd`/`.vbs` **CP949** + CRLF (`.gitattributes` 에 `-text`). 수정 후 `sed -i 's/\r$//; s/$/\r/'` 로 CRLF 유지.
- Windows PowerShell 5.1 호환 유지 (PS7 전용 문법 금지). `Get-Counter` 사용 금지 (부팅 직후 멈춤 이슈로 WMI 원시값 사용).
- 커밋은 `claude/server-monitoring-system-u1pues` 브랜치에 푸시. 사용자는 GitHub ZIP 으로 받아 간다.
- 테스트 방법: `node server.js` + `node agent/simulate.js`, 브라우저 검증은 Playwright(전역 설치, `/opt/pw-browsers/chromium`). 포트 8787 잔존 프로세스는 `fuser -k 8787/tcp`.

## API 요약
`POST /api/metrics`(수신, X-Token) · `GET /api/servers` · `GET /api/history?host=` · `GET /api/health`(version) · `POST /api/unregister` · `PUT /api/order` · `POST /api/mute` · `GET /api/alerts` · `GET /api/alerts/log?month=&download=1` · `GET/PUT /api/settings` · `POST /api/alerts/test` · `POST /api/alerts/discover`

## 사용자가 언급한 다음 후보
서비스(SQL Server 등) 생존 감시, 상위 프로세스 Top5, 이벤트 로그 오류 건수, 백업 파일 최신 시각, RAID 물리 디스크 상태(HP 서버, iLO 미연결 → AMS/WBEM 또는 iLO 케이블 연결), NAS 상태(제조사 미확인), IMS 앱 안으로 프록시 통합(15138 제거), 화면 비밀번호/방화벽 대역 제한.
