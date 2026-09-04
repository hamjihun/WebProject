# 서버 모니터

> **IMS 서버에 실제 구축하려면 [SETUP-IMS.md](SETUP-IMS.md) 의 0~6단계를 따르세요.** 아래는 내 PC 에서 먼저 확인해 보는 방법입니다.

각 서버에서 CPU / 메모리 / 디스크 / 네트워크 정보를 읽어 **내 PC로 전송**하고,
브라우저에서 확인하는 최소 구성입니다. IMS 연동 전 검증용이며 외부 패키지 설치가 필요 없습니다.

```
[서버 A] agent.sh  ─┐
[서버 B] agent.ps1 ─┼─ HTTP POST ─▶ [내 PC] node server.js (:8787) ─▶ 브라우저 http://localhost:8787
[서버 C] ...       ─┘
```

## 구성 파일

| 파일 | 역할 | 실행 위치 |
|---|---|---|
| `server.js` | 수집기. 데이터를 받아 메모리에 보관하고 화면을 제공 | 내 PC |
| `alerts.js` | 알림 엔진. 임계치 감지, 재알림/복귀/조용 시간, 텔레그램 전송 | (수집기가 사용) |
| `public/index.html` | 대시보드 화면 | (수집기가 서빙) |
| `agent/agent.sh` | Linux 에이전트 (bash + curl) | 각 Linux 서버 |
| `dist/IMS-Monitoring-Agent-Setup.exe` | **Windows 에이전트 설치 프로그램** (프로그램 추가/제거 등록, 트레이 아이콘) | 각 Windows 서버 |
| `agent/win/` | 설치 프로그램 소스 (agent.ps1, tray.ps1, service.ps1, installer.nsi). `build.sh` 로 빌드 | 개발 참고 |
| `agent/agent.ps1` | Windows 에이전트 수동 실행용 (PowerShell 5.1+) | 각 Windows 서버 |
| `agent/install-linux.sh` | Linux 에이전트를 systemd 서비스로 등록 | 각 Linux 서버 |
| `agent/install-windows.ps1` | Windows 에이전트를 작업 스케줄러에 등록 | 각 Windows 서버 |
| `agent/setup-agent.cmd`, `remove-agent.cmd` | 위 등록/제거를 더블클릭으로 실행 (URL/TOKEN 은 파일 안에서 수정) | 각 Windows 서버 |
| `deploy/setup-collector.cmd` | 수집기 등록을 더블클릭으로 실행 (PORT/TOKEN 은 파일 안에서 수정) | IMS 서버 |
| `agent/simulate.js` | 서버 없이 화면 확인용 가짜 데이터 전송기 | 내 PC |
| `deploy/install-collector-*.{ps1,sh}` | 수집기를 IMS 서버에 상시 실행 등록 | IMS 서버 |
| `deploy/nginx.conf`, `apache.conf`, `iis-web.config` | IMS 웹서버에서 `/monitor/` 경로로 프록시하는 설정 예시 | IMS 서버 |
| `deploy/embed-sample.html` | IMS 화면에 삽입하는 예시 (요약 타일 + iframe) | IMS 개발 참고 |

## 1. 내 PC에서 수집기 실행

Node.js 18 이상이 설치되어 있어야 합니다. (https://nodejs.org)

```
cd monitor
node server.js
```

브라우저에서 http://localhost:8787 을 엽니다.
아직 서버가 없다면 다른 터미널에서 가짜 데이터를 보내 화면을 확인할 수 있습니다.

```
node agent/simulate.js
```

옵션은 환경 변수로 줍니다.

| 변수 | 기본값 | 설명 |
|---|---|---|
| `PORT` | 8787 | 수신 포트 |
| `BIND` | 0.0.0.0 | 수신 주소. IMS 웹서버 뒤에 둘 때는 `127.0.0.1` (설치 스크립트 기본값) |
| `TOKEN` | (없음) | 설정하면 에이전트도 같은 값을 보내야 수신 |
| `HISTORY` | 720 | 서버당 보관 포인트 수 (5초 간격 = 1시간) |
| `OFFLINE_AFTER` | 90 | 이 시간(초) 동안 데이터가 없으면 오프라인 표시 |
| `LOG_FILE` | (없음) | 지정하면 수신 데이터를 JSON Lines 파일로도 기록 |
| `STATE_FILE` | `data/state.json` | 재시작 대비 스냅샷 파일. 빈 값이면 저장 안 함 |
| `SAVE_EVERY` | 30 | 스냅샷 저장 간격(초) |
| `SETTINGS_FILE` | `data/settings.json` | 알림 설정 파일. 알림 로그는 같은 폴더에 `alerts-YYYY-MM.log` 로 월별 기록 |

예: `set TOKEN=abc123 && node server.js` (Windows CMD) / `TOKEN=abc123 node server.js` (Linux)

**내 PC 방화벽**에서 8787 포트 인바운드를 허용해야 서버에서 접속할 수 있습니다.
Windows: 관리자 PowerShell 에서
`New-NetFirewallRule -DisplayName "ServerMonitor" -Direction Inbound -Protocol TCP -LocalPort 8787 -Action Allow`

## 2. 각 서버에 에이전트 실행

내 PC의 IP가 `192.168.0.10` 이라고 가정합니다. (`ipconfig` / `ip a` 로 확인)

### Linux

```
scp agent/agent.sh user@server:/opt/
ssh user@server
chmod +x /opt/agent.sh
/opt/agent.sh http://192.168.0.10:8787/api/metrics
```

동작이 확인되면 설치 스크립트로 systemd 서비스 등록 (부팅 시 자동 시작, 죽으면 재시작):

```
sudo ./install-linux.sh http://192.168.0.10:8787/api/metrics
journalctl -u monitor-agent -f        # 로그 확인
sudo ./install-linux.sh --uninstall   # 제거
```

### Windows

에이전트 파일을 서버에 복사한 뒤 PowerShell 에서:

```
Set-ExecutionPolicy -Scope Process Bypass
.\agent.ps1 -Url http://192.168.0.10:8787/api/metrics
```

동작이 확인되면 설치 스크립트로 작업 스케줄러에 등록 (관리자 PowerShell, `agent.ps1` 과 같은 폴더에서):

```
.\install-windows.ps1 -Url http://192.168.0.10:8787/api/metrics
.\install-windows.ps1 -Uninstall     # 제거
```

작업 스케줄러에 `ServerMonitorAgent` 이름으로 등록되며 시스템 시작 시 SYSTEM 계정으로 실행됩니다.

두 에이전트 모두 `-Interval` / `INTERVAL` (초), `-Token` / `TOKEN` 옵션을 지원합니다.

## 3. 화면 설명

- 서버별 카드에 CPU, 메모리, 디스크 사용률이 표시됩니다. 75% 이상 노랑, 90% 이상 빨강.
- 카드를 클릭하면 팝업으로 드라이브별 **전일 / 7일 / 30일 대비 증가량**, 하루 평균, 예상 소진일 표와 CPU/메모리 추이가 뜹니다. 닫기 버튼, 바깥 클릭, Esc 로 닫힙니다. 남은 용량이 90일 안에 소진될 것으로 예상되면 카드에도 경고가 붙습니다. 일별 스냅샷은 수집 시작일부터 쌓이므로 7일·30일 값은 시간이 지나면서 채워집니다.
- 에이전트 트레이 메뉴 "이름 설정"으로 정한 표시 이름이 카드 제목으로 나오고 호스트명은 그 아래 줄에 작게 표시됩니다.
- 카드 왼쪽 위 ⠿ 를 잡고 **드래그**하면 순서가 바뀌고 수집기에 저장되어 모든 PC 에서 같은 순서로 보입니다. 팝업의 "◀ 앞으로 / 뒤로 ▶" 버튼으로도 옮길 수 있습니다.
- 팝업의 "목록에서 삭제"로 카드를 지울 수 있습니다. 에이전트가 아직 실행 중이면 다음 전송 때 다시 나타나고, 서버에서 에이전트를 제거하면 자동으로 목록에서 빠집니다.
- 🔔 알림 버튼에서 텔레그램 봇과 임계치를 설정합니다. 경고가 있으면 상단에 빨간 배너가 뜨고 카드에 ⚠ 가 붙습니다. 설정 방법은 [SETUP-IMS.md](SETUP-IMS.md) 의 "알림 설정" 참고.
- 헤더 오른쪽에 수집기 버전이 표시됩니다. 업그레이드 후 버전이 안 바뀌면 예전 프로세스가 남아 있는 것입니다.
- 90초 동안 데이터가 없으면 카드 전체가 **빨간색**으로 바뀌고 "오프라인" 배지가 붙습니다.
- 카드를 클릭하면 아래에 최근 CPU / 메모리 추이 그래프가 나타납니다.
- 5초마다 자동 갱신됩니다.

## 4. 데이터 형식 (IMS 연동 시 참고)

에이전트가 보내는 JSON:

```json
{
  "host": "ERP-DB01", "os": "Windows Server 2019", "token": "",
  "cpu": 35.2,
  "mem_total": 68719476736, "mem_used": 34359738368,
  "uptime": 1036800, "net_rx": 120000, "net_tx": 45000,
  "disks": [ { "mount": "C:", "total": 214748364800, "used": 128849018880 } ]
}
```

수집기가 제공하는 API:

| 경로 | 설명 |
|---|---|
| `POST /api/metrics` | 에이전트 수신 |
| `POST /api/unregister` | 목록에서 호스트 제거 (`{"host":"..."}`), 에이전트 제거 시 자동 호출 |
| `PUT /api/order` | 카드 순서 저장 (`{"order":["호스트",...]}`) |
| `GET /api/alerts` | 현재 경고와 최근 알림 이력 (기본 10건, `?n=`) |
| `GET /api/alerts/log` | 월별 알림 로그 텍스트 (`?month=YYYY-MM`, `?download=1` 이면 파일 다운로드) |
| `GET/PUT /api/settings` | 알림 설정 (텔레그램, 임계치, 조용 시간). 토큰은 마스킹되어 반환 |
| `POST /api/alerts/test` | 텔레그램 테스트 전송 |
| `POST /api/alerts/discover` | 봇에게 말을 건 대화 목록에서 채팅 ID 찾기 |
| `GET /api/servers` | 전체 서버 최신 상태 |
| `GET /api/history?host=이름` | 해당 서버의 CPU/메모리 추이 |

나중에 IMS에 붙일 때는 IMS 쪽에서 `GET /api/servers` 를 호출해 그리거나,
에이전트의 전송 주소만 IMS의 API로 바꾸면 됩니다.

## 5. IMS 서버에 올리기 (방법 A: 수집기를 IMS 옆에 띄우기)

IMS 코드를 고치지 않고 붙이는 방법입니다. 수집기는 IMS 서버에서 별도 프로세스로 돌고, IMS 화면은 그 API를 호출하거나 iframe 으로 삽입합니다.

1. `monitor` 폴더를 IMS 서버로 복사합니다. (예: `C:\ims\monitor` 또는 `/opt/ims/monitor`)
2. Node.js 18 이상을 IMS 서버에 설치합니다.
3. 상시 실행 등록 (부팅 시 자동 시작, 죽으면 재시작):
   - Windows (관리자 PowerShell): `.\deploy\install-collector-windows.ps1 -Token 비밀값`
   - Linux: `sudo TOKEN=비밀값 ./deploy/install-collector-linux.sh`
   - `http://IMS서버IP:8787/` 에서 화면이 뜨면 성공입니다.
4. 에이전트 전송 주소를 IMS 서버로 바꿔 재설치합니다. `-Url http://IMS서버IP:8787/api/metrics -Token 비밀값`
5. IMS 웹서버에서 `/monitor/` 경로를 8787 로 넘겨주는 프록시를 설정합니다. (`deploy/nginx.conf`, `apache.conf`, `iis-web.config` 참고)
   이렇게 하면 사용자는 IMS 포트만 쓰고, 8787 은 서버 대역에서 에이전트가 보낼 때만 쓰입니다.
6. IMS 화면에 삽입합니다. `deploy/embed-sample.html` 참고.
   - iframe: `<iframe src="/monitor/?embed=1&theme=light"></iframe>` (`embed=1` 헤더 숨김, `theme=light` 밝은 배경, `refresh=10` 갱신 초)
   - 또는 IMS 화면에서 `/monitor/api/servers` 를 호출해 IMS 스타일로 직접 그리기

**방법 B (정식)**: IMS 애플리케이션에 `POST /api/metrics` 수신 API 와 DB 테이블을 추가하고 에이전트 전송 주소만 그리로 바꿉니다.
에이전트가 보내는 JSON 형식은 아래 4절과 같습니다.

## 알아둘 점

- 데이터는 메모리에 두고 30초마다 `data/state.json` 에 스냅샷을 저장하므로 재시작해도 최근 이력이 유지됩니다. 장기 보관은 `LOG_FILE` 또는 방법 B의 DB 저장을 쓰세요.
- 사내망 전용입니다. 인터넷에 노출하지 마시고, 여러 사람이 쓰기 시작하면 `TOKEN` 을 설정하세요.
