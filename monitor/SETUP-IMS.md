# IMS 서버 모니터링 구축 순서

목표: 각 서버의 CPU / 메모리 / 디스크 / 네트워크를 IMS 웹화면에서 본다.
원칙: **새 포트를 외부에 열지 않는다.** 모든 통신은 IMS가 이미 쓰는 주소와 포트(80/443)로 들어온다.

```
[ERP 서버] agent ─┐                       IMS 서버
[MES 서버] agent ─┼─ http(s)://IMS주소/monitor/api/metrics ─▶ IMS 웹서버(IIS/nginx/Apache)
[파일 서버] agent ─┘                                              │  /monitor/ 만 내부로 전달
                                                                  ▼
                                                     수집기 node server.js (127.0.0.1:8787, 외부 접근 불가)
                                                                  ▲
[사용자 브라우저] ── IMS 로그인 → 서버 모니터링 메뉴 (iframe /monitor/) ┘
```

8787 은 IMS 서버 **내부에서만** 쓰는 번호이고 방화벽에 열지 않는다. 사용자도 에이전트도 IMS 주소만 안다.

---

## 0단계. 사전 조사 (반나절)

아래를 표로 정리한다. 이 표가 이후 모든 단계의 입력이다.

| 항목 | 확인 방법 | 예 |
|---|---|---|
| IMS 서버 OS | 원격 접속 후 `winver` / `cat /etc/os-release` | Windows Server 2019 |
| IMS 웹서버 종류 | IIS 관리자가 있으면 IIS. 아니면 `nginx -v`, `httpd -v`, 톰캣 폴더 | IIS 10 |
| IMS 접속 주소 | 사용자가 브라우저에 치는 주소 | http://ims.회사.co.kr 또는 http://192.168.1.50 |
| http 인지 https 인지 | 주소창 자물쇠 | http |
| 모니터링 대상 서버 목록 | 서버명, IP, OS, 역할(ERP/MES/DB/파일/AD), 담당자 | 8대 |
| 서버 대역 → IMS 서버 80/443 통신 가능 여부 | 대상 서버에서 브라우저로 IMS 주소 열어보기 | 가능 |

마지막 항목이 안 되면 네트워크 담당자에게 "서버 대역에서 IMS 서버 80(443) 허용"을 요청한다. 대부분 이미 열려 있다.

---

## 1단계. IMS 서버에 수집기 설치 (1시간)

IMS 서버에 원격 접속해서 진행한다.

1. Node.js LTS 설치. https://nodejs.org 에서 받아 기본값으로 설치. 설치 후 새 터미널에서 `node -v` 확인.
2. `monitor` 폴더를 IMS 서버로 복사. 권장 위치: `C:\ims\monitor` (Windows) / `/opt/ims/monitor` (Linux).
3. 토큰을 하나 정한다. 아무 문자열이나 되며 에이전트도 같은 값을 쓴다. 예: `ilsan-mon-2026`
4. 수집기를 상시 실행으로 등록한다.

   Windows (관리자 PowerShell):
   ```
   cd C:\ims\monitor
   Set-ExecutionPolicy -Scope Process Bypass
   .\deploy\install-collector-windows.ps1 -Token ilsan-mon-2026
   ```
   Linux:
   ```
   cd /opt/ims/monitor
   sudo TOKEN=ilsan-mon-2026 ./deploy/install-collector-linux.sh
   ```
5. 확인. IMS 서버 안에서 브라우저로 `http://127.0.0.1:8787/` 을 열면 빈 대시보드가 뜬다.
   다른 PC에서는 열리지 않는 것이 정상이다 (내부 전용).

---

## 2단계. IMS 웹서버에 /monitor/ 프록시 설정 (30분)

IMS 웹서버가 `/monitor/` 로 오는 요청만 내부 수집기(127.0.0.1:8787)로 넘겨주게 한다.
0단계에서 확인한 웹서버 종류에 맞는 것 하나만 한다.

**IIS**
1. URL Rewrite 와 Application Request Routing(ARR) 모듈을 설치한다. (Microsoft 사이트에서 무료 다운로드, 재부팅 불필요)
2. IIS 관리자 > 서버 노드 > Application Request Routing Cache > 오른쪽 Server Proxy Settings > Enable proxy 체크 > 적용.
3. IMS 사이트의 `web.config` 에 `deploy/iis-web.config` 의 `<rewrite>` 부분을 넣는다. 이미 `<rewrite>` 가 있으면 `<rule>` 만 추가.

**nginx**: `deploy/nginx.conf` 의 `location` 두 개를 IMS `server { }` 블록에 넣고 `nginx -t && nginx -s reload`.

**Apache**: `deploy/apache.conf` 내용을 VirtualHost 에 넣고 재시작. `proxy`, `proxy_http` 모듈 필요.

**톰캣만 있고 앞에 웹서버가 없는 경우**: 톰캣은 프록시 기능이 약하므로 IMS 서버에 nginx 를 하나 앞에 두거나, 이 단계를 건너뛰고 수집기를 `-Public` 으로 설치해 8787 을 직접 연다. (임시 방편, 3단계 주소도 `:8787` 로)

확인: 다른 PC 브라우저에서 `http://IMS주소/monitor/` 를 열면 대시보드가 뜬다. `http://IMS주소/monitor/api/health` 는 `{"ok":true,...}` 를 보여준다.

---

## 3단계. 첫 서버 한 대에 에이전트 설치 (30분)

가장 덜 중요한 서버부터. 에이전트는 읽기만 하고 서버에 아무것도 바꾸지 않는다.

**Windows 서버**: `agent\agent.ps1` 과 `agent\install-windows.ps1` 을 `C:\monitor\` 에 복사. 관리자 PowerShell:
```
cd C:\monitor
Set-ExecutionPolicy -Scope Process Bypass
.\install-windows.ps1 -Url http://IMS주소/monitor/api/metrics -Token ilsan-mon-2026
```
https 이고 사설 인증서면 `-SkipCertCheck` 추가.

**Linux 서버**: `agent/agent.sh` 와 `agent/install-linux.sh` 를 복사.
```
chmod +x install-linux.sh
sudo TOKEN=ilsan-mon-2026 ./install-linux.sh http://IMS주소/monitor/api/metrics
```
https 이고 사설 인증서면 앞에 `INSECURE=1` 추가.

확인: `http://IMS주소/monitor/` 에 그 서버 카드가 뜬다. 서버를 재부팅해도 다시 뜨면 등록 완료.

문제가 생기면 서버에서 직접 확인:
- Windows: `Invoke-WebRequest http://IMS주소/monitor/api/health` → 응답 오면 네트워크와 프록시는 정상, 토큰이나 스크립트 문제.
- Linux: `curl http://IMS주소/monitor/api/health`
- 응답이 없으면 2단계 프록시 또는 네트워크 방화벽 문제.

---

## 4단계. 나머지 서버 확장 (서버당 10분)

3단계를 서버마다 반복한다. 0단계 표에 설치일과 결과를 적어 둔다.
DB 서버 등 중요한 서버는 업무 시간 외에 하고, 설치 직후 5분간 CPU 에 영향이 없는지 본다 (에이전트 자체 부하는 1% 미만).

---

## 5단계. IMS 메뉴에 붙이기 (IMS 개발, 1~2시간)

IMS 에 "서버 모니터링" 메뉴를 하나 만들고 페이지에 한 줄 넣는다.
```html
<iframe src="/monitor/?embed=1&theme=light" style="width:100%;height:720px;border:0"></iframe>
```
IMS 로그인한 사용자만 이 메뉴에 들어오므로 권한은 IMS 체계를 그대로 쓴다.
IMS 스타일로 요약 숫자만 보여주고 싶으면 `deploy/embed-sample.html` 처럼 `/monitor/api/servers` 를 호출해 직접 그린다.

이 단계까지가 **1차 오픈**이다.

---

## 6단계. 운영 보강 (1차 오픈 후)

- **임계치 알림**: CPU/디스크 90% 이상 또는 오프라인 시 담당자에게 메일/알림톡. 수집기에 추가 예정.
- **장기 이력 보관**: 현재는 최근 1시간 + 재시작 대비 스냅샷. 월 단위 추이가 필요하면 IMS DB 에 저장하는 방법 B 로 전환.
- **방법 B (IMS 안으로 흡수)**: IMS 애플리케이션에 `POST /api/metrics` 수신과 테이블을 추가하면 Node 수집기가 필요 없어진다. 에이전트는 전송 주소만 바꾸면 된다.
- **모니터링 서버 자체 감시**: IMS 서버가 죽으면 이 화면도 죽는다. 외부에서 IMS 를 ping 하는 간단한 체크를 하나 둔다.

---

## 체크리스트

- [ ] 0. 조사표 작성 (IMS OS / 웹서버 / 주소 / 대상 서버 목록)
- [ ] 1. IMS 서버에 Node.js + 수집기 설치, 내부에서 127.0.0.1:8787 확인
- [ ] 2. 웹서버 /monitor/ 프록시, 외부 PC 에서 IMS주소/monitor/ 확인
- [ ] 3. 첫 서버 에이전트 설치, 재부팅 후에도 카드 표시 확인
- [ ] 4. 나머지 서버 확장
- [ ] 5. IMS 메뉴에 iframe 추가, 1차 오픈
- [ ] 6. 알림 / 이력 보관 / 방법 B 검토
