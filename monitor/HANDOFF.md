# 인수인계 (새 세션에서 이 파일부터 읽기)

ILSAN IMS 서버 모니터링. 300인 제조업 사내 서버(Windows Server 2016 위주)의 CPU/메모리/디스크/네트워크를 모아 IMS 옆 화면에서 보고 텔레그램으로 알린다.
사용자는 IT 담당자이며 개발자가 아니다. 설명은 한국어, 단계별로, 명령은 복사해 쓸 수 있게.

## 구성 (모두 이 저장소 `monitor/` 안, 외부 패키지 없음)
| 위치 | 역할 | 실행 위치 |
|---|---|---|
| `server.js` (v1.12.5) | 수집기. Node.js 내장 http. 데이터 수신, 일별 디스크 스냅샷, 상태 스냅샷 `data/state.json`, 카드 순서, 정적 파일 | IMS 서버 192.168.0.9, 포트 **15138**, 작업 스케줄러 `ServerMonitorCollector` |
| `alerts.js` | 알림 엔진. 임계치/지속시간/완충/재알림/복귀/조용시간, 전체·규칙별·서버별(전체 또는 종류별 hostRules) 끄기, 디스크 규칙은 `disk_check_time`(기본 11:30)에 하루 1회 판단, 텔레그램 전송, 월별 로그 `data/alerts-YYYY-MM.log` | (수집기 내부) |
| `public/index.html` | 서버 현황(카드). `UI_VERSION` 상수를 server.js `VERSION` 과 항상 같게 유지 (다르면 화면에 구버전 경고) | 브라우저 |
| `public/common.js` | 상단 탭(renderNav)·포맷 함수·상태 등급(grade)·**알림 소리**(MON.sound: localStorage `mon_sound` {on,dur,vol,quietOn,quietFrom,quietTo,remind}, Web Audio 비프, 🔊 버튼 패널, TV 모드는 오른쪽 아래 버튼, `sound.check(recent)` 를 index/dashboard/pollNav 가 호출). `UI_VERSION` 도 여기 있음 (같이 올릴 것) | 브라우저 |
| `public/dashboard.html` | TV 대시보드 (`?tv=1` 탭 숨김, 위험 시 점멸) | 브라우저 |
| `public/topology.html` | 구성도 편집기 v2. 장비 아이콘 18종(ICONS, stroke SVG), 영역 도형 6종(groups[].kind: rect/round/ellipse/diamond/hex/cloud, color/fill/dash/tpos/fs), 연결 선(links[]: style solid/dashed/dotted, route straight/elbow-v/elbow-h, arrow, width, color, label), 메모(color/bg/fs), 노드(icon/size s·m·l/label/sub/color/nometric), 상자 안 LED 상태등(grade), 속성 패널, 실행취소(undo 스택), 복제, 격자, 화면 끌기·Ctrl+휠 확대, 단축키. 저장은 `PUT /api/topology` → state.json `topology` (서버는 nodes/links/groups/notes 만 보존) | 브라우저 |
| `public/stats.html` | 통계·리포트. 기간(오늘/7일/30일/90일/1년/월)·서버 선택, KPI, CPU·메모리 추이(SVG 직접 그림, 외부 라이브러리 없음), 일별 경고 건수, 가동률, 서버별 요약표, 디스크 증감표(+단일 서버 시 일별 사용량 그래프), 경고 이력. CSV 는 `GET /api/report.csv`, PDF 는 인쇄 스타일(`@media print`, A4 가로) + `window.print()`. 데이터: `data/hourly.json` (host→[{h,n,ca,cx,ma,mx,off}], 366일) 과 daily 스냅샷, 월별 알림 로그 | 브라우저 |
| `agent/win/` | Windows 에이전트 소스: `agent.ps1`(수집), `tray.ps1`(트레이), `service.ps1`(작업 등록; 2012 의 ExecutionTimeLimit 0 무시 버그를 XML 재등록으로 우회, 감시자 작업 `IMSMonitoringAgentWatchdog` 5분마다 XML 등록), `watchdog.ps1`(agent.ps1 프로세스 없거나 status.json 3분 이상 미갱신이면 재시작, agent.log 에 [감시자] 기록), `start.ps1/.vbs`(바탕화면 실행), `installer.nsi`(NSIS), `make-icon.py`(아이콘) | 각 Windows 서버 |
| `dist/IMS-Monitoring-Agent-Setup.exe` (v1.5.8) | 빌드된 설치 파일. `agent/win/build.sh` (makensis) 로 재빌드 | 각 Windows 서버 |
| `agent/linux/` | Linux 에이전트 `ims-agent.sh` + `install.sh`(설치/`ims-agent` 관리 명령: status/name/disks/restart/log/uninstall). 마운트는 DISKS 지정 또는 /boot·snap·docker·1GB 미만 자동 제외. systemd 없는 시스템(시놀로지 DSM)은 /usr/local/ims-agent + nohup + DSM 작업 스케줄러 안내 | 각 Linux 서버, 시놀로지 |
| `agent/esxi/` | ESXi 호스트 에이전트 `ims-agent-esxi.py`(vim-cmd hostsummary 정규식 파싱, esxcli 데이터스토어/NIC) + `install.sh`(busybox sh, 데이터스토어에 설치, local.sh 로 부팅 실행). 실기 검증 전 (2026-09-07) | ESXi 호스트 |
| `deploy/` | 수집기 설치 스크립트(`setup-collector.cmd` 더블클릭 → `install-collector-windows.ps1 -Public -Port 15138`), 프록시 예시, IMS iframe 예시 | IMS 서버 |
| `agent/simulate.js` | 가짜 서버 3대 전송 (테스트용) | 개발 |
| `SETUP-IMS.md`, `README.md` | 사용자용 구축 순서 / 참조 | |
| `docs/IMS-Monitoring-설치매뉴얼.pptx` | 설치·삭제·관리 매뉴얼 PPT (16장). 생성 스크립트는 세션 스크래치에 있었으므로 수정 시 pptxgenjs 로 재작성 필요 | 배포용 |

## 운영 사실
- 에이전트 → `http://192.168.0.9:15138/api/metrics` 로 5초마다 POST. 토큰 기본값 `ilsan-mon-2026` (설치 파일과 `deploy/setup-collector.cmd` 에 기본값으로 들어 있음. 저장소가 Public 이라 사용자에게 Private 전환과 토큰 변경을 권고했음).
- 현재 연결된 서버: 사용자 PC(DESKTOP-291F7VR), 그룹웨어 서버, MES 서버, ACE ERP 서버. 텔레그램 봇 연결 완료.
- 업그레이드 절차: `monitor` 폴더 덮어쓰기(`data/` 유지) → `deploy\setup-collector.cmd` 재실행. 설치 스크립트가 기존 node.exe 를 종료함. 화면 오른쪽 위 "수집기 vX" 로 확인.
- 디스크 일별 스냅샷(`recordDaily`)은 `disk_check_time` 이후 첫 값으로 고정(`fixed`). 사용자 서버는 새벽 백업으로 300GB 가 생기고 아침에 자동 삭제되므로 그 변동을 제외하려는 것.
- 에이전트 업그레이드: 새 Setup.exe 를 다음만 눌러 재설치 (설정 유지). 제거 시 `/api/unregister` 호출로 화면에서 자동 삭제.

## 코드 규약
- 버전 올릴 때 `server.js` VERSION, `index.html` UI_VERSION 동시 수정. 에이전트는 `installer.nsi` VERSION.
- Windows 파일 인코딩: `.ps1`/`.nsi` UTF-8 **BOM** + CRLF, `.cmd`/`.vbs` **CP949** + CRLF (`.gitattributes` 에 `-text`). 수정 후 `sed -i 's/\r$//; s/$/\r/'` 로 CRLF 유지.
- Windows PowerShell 5.1 호환 유지 (PS7 전용 문법 금지). `Get-Counter` 사용 금지 (부팅 직후 멈춤 이슈로 WMI 원시값 사용).
- 커밋은 `claude/server-monitoring-system-u1pues` 브랜치에 푸시. 사용자는 GitHub ZIP 으로 받아 간다.
- 테스트 방법: `node server.js` + `node agent/simulate.js`, 브라우저 검증은 Playwright(전역 설치, `/opt/pw-browsers/chromium`). 포트 8787 잔존 프로세스는 `fuser -k 8787/tcp`.

## API 요약
`POST /api/metrics`(수신, X-Token) · `GET /api/servers` · `GET /api/history?host=` · `GET /api/health`(version) · `POST /api/unregister` · `PUT /api/order` · `POST /api/mute` · `GET /api/alerts` · `GET /api/alerts/log?month=&download=1` · `GET/PUT /api/settings` · `POST /api/alerts/test` · `POST /api/alerts/discover` · `GET /api/hourly?host=&days=` · `GET/PUT /api/topology` · `GET /api/stats?days=|month=YYYY-MM|from=&to=`(서버별 series/가동률/디스크 증감 + 알림 로그 집계 `alerts.countEvents`) · `GET /api/report.csv?(같은 파라미터)`

## 진행 상태
- 2026-09-14 (11): USB 3차는 파일 수정 시각(xcopy 가 원본 시각 유지)이 아니라 **복사 시각** 기준 — ScanFolder 가 `copied_time`(최대 CreationTime) 반환, usb.copied_time / done_time 중 최신을 카드·표·대시보드·알림에 사용. agent.ps1 이 전송 직전 현재 드라이브 목록에 없으면 usb.connected=false. 에이전트 1.5.8, 수집기 1.12.5. 실기: ACE ERP 카드에 1차·3차 줄 정상 표시 확인. Veeam 카드는 0/7 성공(7개로 늘었으나 성공 0 → 이름 중복/None 의심, diag 줄 확인 필요).
- 2026-09-14 (10): usb-done.ps1 에 3번째 인자 Tool(robocopy|xcopy) 추가 — 사용자 bat 은 xcopy(/d 날짜필터, 로그를 USB\백업\날짜\ACE_ERP_DB_OK.txt 에 기록, RemoveDrive.exe 로 분리, USB 라벨 ERP_Bcakup). xcopy 는 0 만 정상(1=새 파일 없음). 에이전트 1.5.7.
- 2026-09-14 (9): USB 가 3분 만에 자동 분리되는 환경 대응 (에이전트 1.5.6, 수집기 1.12.4). agent.ps1 이 5초마다 드라이브 문자 집합을 비교해 새 드라이브(C:/D: 외)가 나타나면 4분간 20초마다 `backup.ps1 -ForceUsb` 실행. `usb-done.ps1 <robocopy코드> [경로]` 를 bat 에서 robocopy 직후(분리 전) 호출하면 `usb-done.json`(time/code/ok/newest/count/free) 기록 → backup.ps1 이 usb 에 done_time/done_code/done_ok 로 합침. UI: 3차 줄·표에 "복사 완료/실패 시각 (robocopy 코드)", alerts: `H|backup|usbfail`(done_ok=false), 경과 시간은 max(newest_time, done_time). 설치 경로 `C:\Program Files\IMSMonitoringAgent\usb-done.ps1`.
- 2026-09-14 (8): 실기 결과 — USB(E:\DBBackup)가 SQL 폴더 후보(E:\DBBackup)로 잡혀 1차로 표시되고, 15:20 테스트는 USB 시간대(07-10) 밖이라 3차 미인식. 에이전트 1.5.5: SQL 폴더 후보를 C:/D: 로 한정, USB 후보 = USB 인터페이스(InterfaceType/PNPDeviceID USBSTOR) + 이동식 + C:/D: 외 드라이브 중 backup|bak|db 폴더가 있는 것; 드라이브 감지는 항상, 폴더 훑기는 시간대 안 또는 새 드라이브 또는 1시간 경과 시(`usb-state.json` last_scan). 라벨 "1차 백업(SQL)/2차 백업(Veeam)/3차 백업(USB)". 알림 설정 화면 재구성(알림 사용 → 받을 알림 종류 체크 6개 / 백업 알림 기준 / 서버 응답 없음 알림 / 방해 금지 시간), USB 시간대는 time 입력 2개(rUsbFrom/rUsbTo → usb_window). 수집기 1.12.3.
- 2026-09-14 (7): 에이전트 1.5.4 — payload `agent:{version,veeam,backup,paths}` 동봉(agent.ps1 `$AgentVersion` 상수, installer VERSION 과 같이 올릴 것), 팝업 `bkDiag()` 가 버전·백업 폴더 감지·첫 결과 대기·Veeam 진단 문자열을 표시. veeam.ps1 에 `[Veeam.Backup.Core.CBackupSession]::GetAll()`, `CBackupJob::GetAll()`, `Get-VBREPSession`, `Get-VBRBackup`(체인 JobName) 추가, diag 를 json 으로 보내 화면에 표시. 수집기 1.12.2. 사용자 보고: ACE ERP 카드에 백업 줄 안 뜸(1.5.3 설치 여부 불명), Veeam 카드 0/1 (Windows Agent Backup 4개가 여전히 안 잡힘 → diag 줄로 확인 예정).
- 2026-09-14 (6): backup.ps1 치명 버그 수정 — `$out`(결과)와 `$Out`(파일 경로)가 같은 변수라 backup.json 이 저장되지 않았음 → `$result` 로 변경. 에이전트 1.5.3. **PowerShell 검증 환경**: `/opt/pwsh/pwsh`(PowerShell 7, 세션 컨테이너에 설치)로 `Parser::ParseFile` 문법 검사와 `ProgramData=... pwsh -File backup.ps1 -ConfPath` 실행 테스트 가능 (WMI/레지스트리 부분은 Linux 에서 catch 로 건너뜀). 새 세션에서는 다시 설치 필요 (GitHub 릴리스 tar.gz).
- 2026-09-14 (5): USB 확인 시간대 `rules.usb_window`(기본 07:00-10:00) — `/api/metrics` 응답에 `agent:{usb_window}` 로 내려보내고 agent.ps1 이 `%ProgramData%\IMSMonitoringAgent\remote.conf`(USB_HOURS=) 에 저장, backup.ps1 은 agent.conf USB_HOURS > remote.conf > 기본 순으로 읽어 시간대 밖이면 USB 를 살피지 않음. 이 경로(수집기→에이전트 설정 전달)는 앞으로 다른 설정에도 재사용 가능. 에이전트 1.5.2, 수집기 1.12.1.
- 2026-09-14 (4): **3단계 백업 감시** (에이전트 1.5.0, 수집기 1.12.0). `agent/win/backup.ps1`(5분마다 별도 프로세스, `-ConfPath agent.conf`): 백업 폴더 자동 감지(D:\DBBackup, D:\DB_BACKUP, E:\DBBackup, C:\DBBackup 또는 agent.conf `BACKUP_PATH=a;b`) → 최신 .bak/.trn 등 파일·개수·용량, SQL msdb(레지스트리 Instance Names 로 인스턴스 찾아 Integrated Security, `SQL=0` 으로 끔) DB별 전체/차등/로그 마지막 시각, USB(Win32_DiskDrive InterfaceType=USB → 논리 드라이브, 또는 DriveType=2 4GB↑, `USB=E:` 지정 가능; backup/bak/db 이름 폴더 우선) 최신 파일·용량을 `usb-state.json` 에 보관해 빠진 뒤에도 마지막 값 전송. payload `backups.files[]/sql{instance,error,dbs[]}/usb{}` (Veeam jobs/repos 와 병합). alerts.js: `hoursSince(from,now,skipWeekend)`, rules `usb_max_hours`(30), `backup_skip_weekend`(true); 규칙 키 `H|backup|sql:경로`, `db:이름`(전체 백업 maxH×7), `usb`, `usbfree`(10% 미만). UI: 카드 단계별 줄(1차 SQL/2차 Veeam/3차 USB), 팝업 표, 대시보드 백업 현황에 단계 행, 설정에 USB 허용 시간·주말 제외. 사용자 환경: SQL 유지 관리 계획 → D:\DBBackup (ERP 부산/김해, ACE ERP), D:\DB_BACKUP\GWareNet10 (그룹웨어); USB 는 bat robocopy 로 하루 1회(주말 제외) 1시간쯤 꽂았다 뺌. 실기 검증 전.
- 2026-09-14 (3): `rules.backup_check_time`(기본 08:00) — 백업 규칙은 그 시각에 하루 1회 판단 (`dailyDue(kind,t)` 로 disk_check_time 과 공용화). 알림 설정에 "백업 점검 시각" 입력. 수집기 1.11.1.
- 2026-09-14 (2): 실기 결과 — 사용자 Veeam 작업은 전부 Windows Agent Backup 5개 + Linux Agent Policy 1개. Get-VBRJob 에는 안 잡히고 Result 가 배열로 와서 "Success Success…" 표시됨 → veeam.ps1 1.4.1: Get-VBRBackupSession + Get-VBRComputerBackupJobSession 세션을 JobName 별로 묶어 작업 목록을 만들고(정의는 Get-VBRJob/Get-VBRComputerBackupJob 에서 type/enabled/next 만 보강), Str() 로 첫 토큰만 사용, agent.log 에 `[Veeam] 작업 정의 VM=… 에이전트=…, 세션 …` 진단 줄 기록, json 에 diag. 팝업 백업 표 제목에 서버별 백업 알림 켜기/끄기 버튼(hostRules.backup).
- 2026-09-14: **Veeam 백업 모니터링** (에이전트 1.4.0, 수집기 1.11.0). `agent/win/veeam.ps1`(Veeam.Backup.PowerShell 모듈/스냅인, Get-VBRJob+Get-VBRBackupSession, Get-VBRComputerBackupJob, Get-VBRBackupRepository → `%ProgramData%\IMSMonitoringAgent\veeam.json`)을 agent.ps1 이 Veeam 설치 폴더가 있을 때만 10분마다 별도 프로세스로 실행하고 payload `backups:{time,error,jobs[{name,type,enabled,result,state,progress,start,end,ok_end,duration,size,next}],repos[{name,total,free}]}` 로 동봉. server.js `normalizeBackups`(repos 에 pct 추가). alerts.js 규칙 `backup`: rules.backup_on/backup_warn/backup_max_hours(26) — 실패·경고, 성공 없음(ok_end 기준), 저장소 사용률(rules.disk 기준); hostRules 에 backup 추가. UI: 카드 `.bk` 요약줄, 팝업 `bkTable`, 대시보드 3행 c4×3(저장장치/소진 임박/백업 현황), 알림 설정 체크·시간, 통계 byRule.backup. 사용자 환경: Veeam 11.0.0.837, 백업 작업 5개 + NAS 로 백업 복사 1개. 실기 검증 전.
- 2026-09-10 (3): 상단 탭에 ⛶ 전체화면 버튼(requestFullscreen), 음성 알림 발음 변환 `toSpeech`(WORDS 약자 사전 + 알파벳 낱자 한글, 사용자 사전 `snd.dict` "ERP=이알피" 줄 단위, 🔊 패널 텍스트 영역).
- 2026-09-10 (2): 오프라인 유예 `rules.offline_grace`(분; check() opts.grace → 이벤트 delivery 'held', 유예 내 복구면 skipped+이력, 지나면 새 id 로 재푸시 후 전송), 알림 소리 종류 `snd.mode` beep/voice/both(speechSynthesis ko-KR, "서버이름 규칙" 읽기, held 이벤트는 무음), 에이전트 1.3.2 수집 지연 로그(30초↑ 또는 전송 3초↑ 시 단계별 초). ACE ERP 서버 새벽 3:55~4:20 응답 없음 원인은 메모리 95% + 새벽 작업으로 WMI 수집 지연으로 판단.
- 2026-09-10: 브라우저 알림 소리(지속 시간·방해 금지) 추가, 에이전트 1.3.1(감시자·2012 시간제한 버그), 구성도 편집기 v2, 통계·리포트 완료. 사용자에게 제안한 다음 후보: 서비스·포트 감시, 백업 확인, 아침 요약 텔레그램, 보안 이벤트(원격 접속/로그인 실패/미끼 파일/섀도 복사본 삭제/레지스트리 스냅샷).
4개 탭(대시보드·구성도·서버 현황·통계·리포트) 모두 구현 완료 (2026-09-07, v1.10.0). 통계 화면은 실서버 데이터가 며칠 쌓인 뒤 사용자 검토 예정. 테스트 데이터 생성 스크립트 예: hourly.json 에 host→[{h,n,ca,cx,ma,mx,off}] 60일치, `alerts-YYYY-MM.log` 에 `[YYYY-MM-DD HH:MM:SS] 경고\t이름 (host)\t메시지\t텔레그램 전송` 줄을 넣고 `STATE_FILE/HOURLY_FILE/SETTINGS_FILE` 환경변수로 수집기를 띄운다.

## 사용자가 언급한 다음 후보
서비스(SQL Server 등) 생존 감시, 상위 프로세스 Top5, 이벤트 로그 오류 건수, 백업 파일 최신 시각, RAID 물리 디스크 상태(HP 서버, iLO 미연결 → AMS/WBEM 또는 iLO 케이블 연결), NAS: 시놀로지는 리눅스 에이전트로 가능(디스크 건강은 미지원), ipTIME 은 에이전트 불가 → Windows 에이전트에 SHARES(UNC 공유폴더 응답/용량을 별도 카드로 올림) 기능 추가가 후보, IMS 앱 안으로 프록시 통합(15138 제거), 화면 비밀번호/방화벽 대역 제한.
