#!/usr/bin/env bash
# IMS 서버(Linux)에 수집기(server.js)를 systemd 서비스로 등록합니다.
# monitor 폴더를 원하는 위치(예: /opt/ims/monitor)에 둔 뒤 root 로 실행:
#   sudo ./deploy/install-collector-linux.sh
#   sudo PORT=8787 TOKEN=비밀값 ./deploy/install-collector-linux.sh
# 제거:  sudo ./deploy/install-collector-linux.sh --uninstall
set -e
SERVICE=monitor-collector
UNIT=/etc/systemd/system/$SERVICE.service
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$1" = "--uninstall" ]; then
  systemctl disable --now $SERVICE 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload
  echo "제거 완료: $SERVICE"; exit 0
fi
[ "$(id -u)" -ne 0 ] && { echo "root 권한이 필요합니다. sudo 로 실행하세요." >&2; exit 1; }
NODE="$(command -v node || true)"
[ -z "$NODE" ] && { echo "node 를 찾을 수 없습니다. Node.js 18 이상을 설치하세요." >&2; exit 1; }

cat > "$UNIT" <<UNIT
[Unit]
Description=Server monitor collector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$ROOT
Environment=PORT=${PORT:-8787}
Environment=TOKEN=${TOKEN:-}
ExecStart=$NODE $ROOT/server.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now $SERVICE
sleep 2
systemctl --no-pager --lines=3 status $SERVICE || true
echo
echo "설치 완료. 화면: http://<이 서버 IP>:${PORT:-8787}/   로그: journalctl -u $SERVICE -f"
echo "방화벽 예: sudo ufw allow ${PORT:-8787}/tcp   또는   sudo firewall-cmd --permanent --add-port=${PORT:-8787}/tcp && sudo firewall-cmd --reload"
