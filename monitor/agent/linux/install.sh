#!/usr/bin/env bash
# IMS Monitoring Agent (Linux) 설치 / 관리 명령
#
# 설치:   sudo ./install.sh --url http://192.168.0.9:15138/api/metrics --token ilsan-mon-2026 [--name "ERP 서버"] [--interval 5] [--insecure]
# 설치 후 관리 (어디서든):
#   ims-agent status            상태 보기
#   ims-agent name "ERP 서버"    모니터링 화면에 표시할 이름 설정 (빈 문자열이면 호스트명)
#   ims-agent disks "/,/data"   화면에 보일 마운트 지정 (빈 문자열이면 자동: /boot, snap 등 시스템 파티션 제외)
#   ims-agent restart|stop|start
#   ims-agent log               실시간 로그
#   ims-agent uninstall         제거 (모니터링 화면에서도 자동으로 빠짐)
set -e
APP=ims-agent; DIR=/opt/ims-agent; CONF_DIR=/etc/ims-agent; CONF=$CONF_DIR/agent.conf
UNIT=/etc/systemd/system/$APP.service; BIN=/usr/local/bin/$APP; STATUS=/var/lib/ims-agent/status.json
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

need_root() { [ "$(id -u)" -eq 0 ] || { echo "root 권한이 필요합니다: sudo $0 $*" >&2; exit 1; }; }
conf_get() { grep -E "^$1=" "$CONF" 2>/dev/null | head -1 | cut -d= -f2-; }
conf_set() { mkdir -p "$CONF_DIR"; touch "$CONF"; if grep -qE "^$1=" "$CONF"; then sed -i "s|^$1=.*|$1=$2|" "$CONF"; else echo "$1=$2" >> "$CONF"; fi; }

cmd_install() {
  need_root "$@"
  URL=""; TOKEN=""; NAME=""; INTERVAL=5; INSECURE=0; DISKS=""

  while [ $# -gt 0 ]; do case "$1" in
    --url) URL="$2"; shift;; --token) TOKEN="$2"; shift;; --name) NAME="$2"; shift;; --interval) INTERVAL="$2"; shift;; --insecure) INSECURE=1;; --disks) DISKS="$2"; shift;;
    *) echo "알 수 없는 옵션: $1" >&2; exit 1;; esac; shift; done
  [ -z "$URL" ] && URL="$(conf_get URL)"; [ -z "$TOKEN" ] && TOKEN="$(conf_get TOKEN)"; [ -z "$NAME" ] && NAME="$(conf_get NAME)"; [ -z "$DISKS" ] && DISKS="$(conf_get DISKS)"
  [ -z "$URL" ] && { echo "--url 이 필요합니다. 예: --url http://192.168.0.9:15138/api/metrics" >&2; exit 1; }
  command -v curl >/dev/null || { echo "curl 이 필요합니다: apt install curl / yum install curl" >&2; exit 1; }
  if ! command -v systemctl >/dev/null; then NOSYSTEMD=1; DIR=/usr/local/ims-agent; fi   # 시놀로지 DSM 등

  mkdir -p "$DIR" "$CONF_DIR" /var/lib/ims-agent
  cp "$SRC_DIR/ims-agent.sh" "$DIR/ims-agent.sh"; chmod +x "$DIR/ims-agent.sh"
  cp "$SRC_DIR/install.sh" "$BIN"; chmod +x "$BIN"
  conf_set URL "$URL"; conf_set TOKEN "$TOKEN"; conf_set INTERVAL "$INTERVAL"; conf_set NAME "$NAME"; conf_set INSECURE "$INSECURE"; conf_set DISKS "$DISKS"
  chmod 600 "$CONF"

  if [ -n "$NOSYSTEMD" ]; then
    nosd_start
    echo "설치 완료 (systemd 없음 → 백그라운드 실행). 전송 주소: $URL"
    echo
    echo "▶ 부팅 시 자동 실행 등록 (시놀로지 DSM):"
    echo "  제어판 → 작업 스케줄러 → 생성 → 트리거된 작업 → 사용자 정의 스크립트"
    echo "  이벤트: 부팅 / 사용자: root / 작업 설정 → 스크립트에 아래 한 줄:"
    echo "    $BIN start"
    cmd_status; return
  fi
  cat > "$UNIT" <<UNIT
[Unit]
Description=IMS Monitoring Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$DIR/ims-agent.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now $APP >/dev/null
  systemctl restart $APP
  sleep 3
  echo "설치 완료. 전송 주소: $URL"
  cmd_status
}

# systemd 가 없을 때 (시놀로지 등): nohup 으로 실행
[ -d /usr/local/ims-agent ] && [ ! -d /opt/ims-agent ] && DIR=/usr/local/ims-agent
PIDF=/var/run/ims-agent.pid
nosd_running() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }
nosd_start() { nosd_stop; nohup "$DIR/ims-agent.sh" >> /var/log/ims-agent.log 2>&1 & echo $! > "$PIDF"; sleep 3; }
nosd_stop() { if nosd_running; then kill "$(cat "$PIDF")" 2>/dev/null; fi; rm -f "$PIDF"; pkill -f "$DIR/ims-agent.sh" 2>/dev/null || true; }

cmd_status() {
  if command -v systemctl >/dev/null; then
    if systemctl is-active --quiet $APP 2>/dev/null; then echo "서비스: 실행 중"; else echo "서비스: 중지됨"; fi
  else
    if nosd_running; then echo "에이전트: 실행 중 (PID $(cat "$PIDF"))"; else echo "에이전트: 중지됨 ('$BIN start' 로 시작)"; fi
  fi
  echo "설정: $CONF  (이름: '$(conf_get NAME)', 주소: $(conf_get URL))"
  if [ -f "$STATUS" ]; then
    echo "마지막 상태: $(cat "$STATUS")"
  else echo "상태 파일 없음 (아직 시작 전)"; fi
}
cmd_name() { need_root; conf_set NAME "$1"; echo "표시 이름: '${1:-(호스트명)}' - 5초 안에 화면에 반영됩니다"; }
cmd_disks() { need_root; conf_set DISKS "$1"; echo "표시 마운트: '${1:-(자동)}' - 5초 안에 화면에 반영됩니다. 현재 마운트 목록: $(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1 && $1 ~ /^\// {printf "%s ", $6}')"; }
cmd_uninstall() {
  need_root
  URL="$(conf_get URL)"; TOKEN="$(conf_get TOKEN)"
  if [ -n "$URL" ]; then
    curl -s -m 5 -X POST -H 'Content-Type: application/json' --data "{\"host\":\"$(hostname)\",\"token\":\"$TOKEN\"}" "${URL%/api/metrics}/api/unregister" >/dev/null 2>&1 && echo "수집기 목록에서 제거 요청 완료" || echo "수집기 알림 실패 (무시)"
  fi
  if command -v systemctl >/dev/null; then systemctl disable --now $APP 2>/dev/null || true; rm -f "$UNIT"; systemctl daemon-reload; else nosd_stop; fi
  rm -rf "$DIR" "$CONF_DIR" /var/lib/ims-agent "$BIN"
  echo "제거 완료"
}

case "${1:-}" in
  ""|--url|--token|--name|--interval|--insecure) cmd_install "$@";;
  install) shift; cmd_install "$@";;
  status) cmd_status;;
  name) cmd_name "${2:-}";;
  disks) cmd_disks "${2:-}";;
  restart|stop|start) need_root
    if command -v systemctl >/dev/null; then systemctl "$1" $APP && echo "$1 완료"
    else case "$1" in start|restart) nosd_start;; stop) nosd_stop;; esac; echo "$1 완료"; fi;;
  log) if command -v systemctl >/dev/null; then journalctl -u $APP -f; else tail -f /var/log/ims-agent.log; fi;;
  uninstall|remove) cmd_uninstall;;
  *) sed -n '2,12p' "$0"; exit 1;;
esac
