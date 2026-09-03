#!/usr/bin/env bash
# Linux 서버: 에이전트를 /opt/monitor 에 복사하고 systemd 서비스로 등록합니다.
# agent.sh 와 같은 폴더에 두고 root 로 실행:
#   sudo TOKEN=비밀값 ./install-linux.sh http://ims.회사도메인/monitor/api/metrics
#   sudo INSECURE=1 TOKEN=비밀값 ./install-linux.sh https://...   # 사설 인증서일 때
# 제거:  sudo ./install-linux.sh --uninstall
set -e

SERVICE=monitor-agent
DIR=/opt/monitor
UNIT=/etc/systemd/system/$SERVICE.service

if [ "$1" = "--uninstall" ]; then
  systemctl disable --now $SERVICE 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload
  echo "제거 완료: $SERVICE"
  exit 0
fi

URL="$1"
[ -z "$URL" ] && { echo "사용법: sudo $0 http://<PC IP>:8787/api/metrics" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] && { echo "root 권한이 필요합니다. sudo 로 실행하세요." >&2; exit 1; }
command -v curl >/dev/null || { echo "curl 이 필요합니다. (apt install curl / yum install curl)" >&2; exit 1; }

mkdir -p "$DIR"
cp "$(dirname "$0")/agent.sh" "$DIR/agent.sh"
chmod +x "$DIR/agent.sh"

cat > "$UNIT" <<UNIT
[Unit]
Description=Server monitor agent ($URL)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=URL=$URL
Environment=INTERVAL=${INTERVAL:-5}
Environment=TOKEN=${TOKEN:-}
Environment=INSECURE=${INSECURE:-0}
ExecStart=$DIR/agent.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now $SERVICE
sleep 2
systemctl --no-pager --lines=3 status $SERVICE || true
echo
echo "설치 완료. 로그 보기: journalctl -u $SERVICE -f"
echo "확인: 수집기 화면에 $(hostname) 카드가 나타나는지 보세요."
