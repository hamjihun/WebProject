#!/usr/bin/env bash
# IMS Monitoring Agent (Linux) 설치 / 관리 명령
#
# 설치:   sudo ./install.sh --url http://192.168.0.9:15138/api/metrics --token ilsan-mon-2026 [--name "ERP 서버"] [--interval 5] [--insecure]
# 설치 후 관리 (어디서든):
#   ims-agent status            상태 보기
#   ims-agent name "ERP 서버"    모니터링 화면에 표시할 이름 설정 (빈 문자열이면 호스트명)
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
  URL=""; TOKEN=""; NAME=""; INTERVAL=5; INSECURE=0
  while [ $# -gt 0 ]; do case "$1" in
    --url) URL="$2"; shift;; --token) TOKEN="$2"; shift;; --name) NAME="$2"; shift;; --interval) INTERVAL="$2"; shift;; --insecure) INSECURE=1;;
    *) echo "알 수 없는 옵션: $1" >&2; exit 1;; esac; shift; done
  [ -z "$URL" ] && URL="$(conf_get URL)"; [ -z "$TOKEN" ] && TOKEN="$(conf_get TOKEN)"; [ -z "$NAME" ] && NAME="$(conf_get NAME)"
  [ -z "$URL" ] && { echo "--url 이 필요합니다. 예: --url http://192.168.0.9:15138/api/metrics" >&2; exit 1; }
  command -v curl >/dev/null || { echo "curl 이 필요합니다: apt install curl / yum install curl" >&2; exit 1; }
  command -v systemctl >/dev/null || { echo "systemd 가 없는 시스템입니다. ims-agent.sh 를 직접 백그라운드로 실행하세요." >&2; exit 1; }

  mkdir -p "$DIR" "$CONF_DIR" /var/lib/ims-agent
  cp "$SRC_DIR/ims-agent.sh" "$DIR/ims-agent.sh"; chmod +x "$DIR/ims-agent.sh"
  cp "$SRC_DIR/install.sh" "$BIN"; chmod +x "$BIN"
  conf_set URL "$URL"; conf_set TOKEN "$TOKEN"; conf_set INTERVAL "$INTERVAL"; conf_set NAME "$NAME"; conf_set INSECURE "$INSECURE"
  chmod 600 "$CONF"

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

cmd_status() {
  if systemctl is-active --quiet $APP 2>/dev/null; then echo "서비스: 실행 중"; else echo "서비스: 중지됨"; fi
  echo "설정: $CONF  (이름: '$(conf_get NAME)', 주소: $(conf_get URL))"
  if [ -f "$STATUS" ]; then
    echo "마지막 상태: $(cat "$STATUS")"
  else echo "상태 파일 없음 (아직 시작 전)"; fi
}
cmd_name() { need_root; conf_set NAME "$1"; echo "표시 이름: '${1:-(호스트명)}' - 5초 안에 화면에 반영됩니다"; }
cmd_uninstall() {
  need_root
  URL="$(conf_get URL)"; TOKEN="$(conf_get TOKEN)"
  if [ -n "$URL" ]; then
    curl -s -m 5 -X POST -H 'Content-Type: application/json' --data "{\"host\":\"$(hostname)\",\"token\":\"$TOKEN\"}" "${URL%/api/metrics}/api/unregister" >/dev/null 2>&1 && echo "수집기 목록에서 제거 요청 완료" || echo "수집기 알림 실패 (무시)"
  fi
  systemctl disable --now $APP 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload
  rm -rf "$DIR" "$CONF_DIR" /var/lib/ims-agent "$BIN"
  echo "제거 완료"
}

case "${1:-}" in
  ""|--url|--token|--name|--interval|--insecure) cmd_install "$@";;
  install) shift; cmd_install "$@";;
  status) cmd_status;;
  name) cmd_name "${2:-}";;
  restart|stop|start) need_root; systemctl "$1" $APP && echo "$1 완료";;
  log) journalctl -u $APP -f;;
  uninstall|remove) cmd_uninstall;;
  *) sed -n '2,12p' "$0"; exit 1;;
esac
