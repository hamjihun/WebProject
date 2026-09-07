#!/bin/sh
# IMS Monitoring Agent 설치 (VMware ESXi 호스트용). ESXi 셸(SSH)에서 root 로 실행.
#   ./install.sh --url http://192.168.0.9:15138/api/metrics --token ilsan-mon-2026 --name "가상화 서버"
#   (설치 폴더 직접 지정)  ./install.sh --dir /vmfs/volumes/datastore1 --url ... --token ... --name ...
#   ./install.sh status | name "이름" | restart | stop | log | uninstall
# 설치 위치: 첫 번째 VMFS 데이터스토어의 ims-agent 폴더 (재부팅 후에도 유지)
# 부팅 시 자동 실행: /etc/rc.local.d/local.sh 에 시작 줄 추가
SRC="$(cd "$(dirname "$0")" && pwd)"
LOCAL_SH=/etc/rc.local.d/local.sh
MARK="# ims-agent"

# --dir /vmfs/volumes/데이터스토어명  으로 설치 폴더를 직접 지정할 수 있음
IMS_DIR=""; prev=""
for a in "$@"; do [ "$prev" = "--dir" ] && IMS_DIR="$a/ims-agent"; prev="$a"; done
writable() { mkdir -p "$1" 2>/dev/null && touch "$1/.w" 2>/dev/null && rm -f "$1/.w"; }
find_dir() {
  if [ -n "$IMS_DIR" ]; then writable "$IMS_DIR" || { echo "$IMS_DIR 에 쓸 수 없습니다" >&2; exit 1; }; echo "$IMS_DIR"; return; fi
  if [ -f /etc/ims-agent.dir ]; then d=$(cat /etc/ims-agent.dir); if writable "$d"; then echo "$d"; return; fi; fi
  # 실제 데이터스토어(VMFS-5/6, 마운트됨)만 후보로. OSDATA(VMFS-L) 등 시스템 볼륨 제외
  for mp in $(esxcli --formatter=csv --format-param=fields="Mount Point,Type,Mounted" storage filesystem list 2>/dev/null | awk -F, 'NR>1 && $2 ~ /^VMFS-[56]/ && tolower($3)=="true" {print $1}') $(ls -d /vmfs/volumes/datastore* 2>/dev/null); do
    d="$mp/ims-agent"
    if writable "$d"; then echo "$d"; return; fi
  done
  echo "쓸 수 있는 데이터스토어를 찾지 못했습니다. ./install.sh --dir /vmfs/volumes/데이터스토어명 --url ... 으로 지정하세요" >&2
  echo "데이터스토어 목록: $(ls /vmfs/volumes/ 2>/dev/null | tr '\n' ' ')" >&2
  exit 1
}
DIR=$(find_dir) || exit 1; CONF=$DIR/agent.conf; PIDF=/var/run/ims-agent.pid; LOG=$DIR/agent.log
conf_get() { grep "^$1=" "$CONF" 2>/dev/null | head -1 | cut -d= -f2-; }
conf_set() { touch "$CONF"; if grep -q "^$1=" "$CONF"; then sed -i "s|^$1=.*|$1=$2|" "$CONF"; else echo "$1=$2" >> "$CONF"; fi; }
running() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }
start() { stop; nohup /bin/python "$DIR/ims-agent-esxi.py" >> "$LOG" 2>&1 & echo $! > "$PIDF"; sleep 3; }
stop() { running && kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"; pkill -f ims-agent-esxi.py 2>/dev/null; true; }
status() {
  if running; then echo "에이전트: 실행 중 (PID $(cat "$PIDF"))"; else echo "에이전트: 중지됨"; fi
  echo "폴더: $DIR   이름: '$(conf_get NAME)'   주소: $(conf_get URL)"
  [ -f "$DIR/status.json" ] && echo "마지막 상태: $(cat "$DIR/status.json")"
}
install() {
  URL=""; TOKEN=""; NAME=""; INTERVAL=5; INSECURE=0
  while [ $# -gt 0 ]; do case "$1" in
    --url) URL="$2"; shift;; --token) TOKEN="$2"; shift;; --name) NAME="$2"; shift;; --interval) INTERVAL="$2"; shift;; --insecure) INSECURE=1;; --dir) shift;;
    *) echo "알 수 없는 옵션: $1" >&2; exit 1;; esac; shift; done
  [ -z "$URL" ] && URL="$(conf_get URL)"; [ -z "$TOKEN" ] && TOKEN="$(conf_get TOKEN)"; [ -z "$NAME" ] && NAME="$(conf_get NAME)"
  [ -z "$URL" ] && { echo "--url 이 필요합니다" >&2; exit 1; }
  [ -x /bin/python ] || { echo "/bin/python 이 없습니다 (ESXi 6.5 이상 필요)" >&2; exit 1; }
  mkdir -p "$DIR"; echo "$DIR" > /etc/ims-agent.dir
  cp "$SRC/ims-agent-esxi.py" "$DIR/"; cp "$SRC/install.sh" "$DIR/ims-agent"; chmod +x "$DIR/ims-agent-esxi.py" "$DIR/ims-agent"
  conf_set URL "$URL"; conf_set TOKEN "$TOKEN"; conf_set INTERVAL "$INTERVAL"; conf_set NAME "$NAME"; conf_set INSECURE "$INSECURE"
  # 부팅 시 자동 실행 (local.sh 의 'exit 0' 앞에 추가)
  if ! grep -q "$MARK" "$LOCAL_SH" 2>/dev/null; then
    sed -i "s|^exit 0|$MARK\n[ -x $DIR/ims-agent ] \&\& $DIR/ims-agent start\nexit 0|" "$LOCAL_SH"
    grep -q "$MARK" "$LOCAL_SH" || printf '%s\n[ -x %s/ims-agent ] && %s/ims-agent start\n' "$MARK" "$DIR" "$DIR" >> "$LOCAL_SH"
  fi
  start
  echo "설치 완료. 전송 주소: $URL"
  echo "관리 명령: $DIR/ims-agent status|name|restart|stop|log|uninstall"
  status
}
uninstall() {
  URL="$(conf_get URL)"; TOKEN="$(conf_get TOKEN)"
  [ -n "$URL" ] && /bin/python -c "
import json,sys
try:
  from urllib.request import Request,urlopen
except ImportError:
  from urllib2 import Request,urlopen
u='${URL%/api/metrics}/api/unregister'
try: urlopen(Request(u,data=json.dumps({'host':'$(hostname)','token':'$TOKEN'}).encode(),headers={'Content-Type':'application/json'}),timeout=5).read(); print('수집기 목록에서 제거 요청 완료')
except Exception as e: print('수집기 알림 실패 (무시):',e)"
  stop
  sed -i "/$MARK/,+1d" "$LOCAL_SH" 2>/dev/null
  rm -rf "$DIR" /etc/ims-agent.dir
  echo "제거 완료"
}
case "${1:-}" in
  ""|--url|--token|--name|--interval|--insecure|--dir) install "$@";;
  install) shift; install "$@";;
  status) status;;
  name) conf_set NAME "${2:-}"; echo "표시 이름: '${2:-(호스트명)}' - 5초 안에 화면 반영";;
  start|restart) start; status;;
  stop) stop; echo "중지 완료";;
  log) tail -f "$LOG";;
  uninstall|remove) uninstall;;
  *) sed -n '2,6p' "$0"; exit 1;;
esac
