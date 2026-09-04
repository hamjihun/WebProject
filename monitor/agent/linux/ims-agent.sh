#!/usr/bin/env bash
# IMS Monitoring Agent (Linux)
# CPU / 메모리 / 디스크 / 네트워크를 읽어 수집기로 보냅니다. 필요한 것: bash, curl
# 설정: /etc/ims-agent/agent.conf (URL, TOKEN, INTERVAL, NAME, INSECURE)  ← install.sh 가 만듦
# 상태: /var/lib/ims-agent/status.json,  로그: journalctl -u ims-agent
CONF="${CONF:-/etc/ims-agent/agent.conf}"
STATE_DIR="${STATE_DIR:-/var/lib/ims-agent}"
mkdir -p "$STATE_DIR" 2>/dev/null

load_conf() {
  URL="${URL:-}"; TOKEN="${TOKEN:-}"; INTERVAL="${INTERVAL:-5}"; NAME="${NAME:-}"; INSECURE="${INSECURE:-0}"
  if [ -f "$CONF" ]; then
    while IFS='=' read -r k v; do
      k="$(echo "$k" | tr -d '[:space:]')"; v="${v%$'\r'}"
      case "$k" in URL) URL="$v";; TOKEN) TOKEN="$v";; INTERVAL) INTERVAL="$v";; NAME) NAME="$v";; INSECURE) INSECURE="$v";; esac
    done < "$CONF"
  fi
}
load_conf
[ -n "$1" ] && URL="$1"           # 인자로 URL 을 주면 우선
[ -z "$URL" ] && { echo "전송 주소(URL)가 없습니다. $CONF 를 확인하세요." >&2; exit 1; }
[ "${INTERVAL:-5}" -ge 2 ] 2>/dev/null || INTERVAL=5
CURL_OPTS=""; [ "$INSECURE" = "1" ] && CURL_OPTS="-k"
HOST="${HOST:-$(hostname)}"
OS="$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}" || uname -sr )"

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
write_status() {   # ok, error, cpu, mem_pct
  printf '{"ok":%s,"time":"%s","error":"%s","host":"%s","name":"%s","url":"%s","cpu":%s,"mem_pct":%s,"interval":%s}\n' \
    "$1" "$(date -Is)" "$(json_str "$2")" "$(json_str "$HOST")" "$(json_str "$NAME")" "$(json_str "$URL")" "${3:-0}" "${4:-0}" "$INTERVAL" \
    > "$STATE_DIR/status.json.tmp" 2>/dev/null && mv -f "$STATE_DIR/status.json.tmp" "$STATE_DIR/status.json" 2>/dev/null
}
read_cpu() { awk '/^cpu /{idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i; print idle, total}' /proc/stat; }
read_net() { awk -F'[: ]+' 'NR>2 && $2!="lo" {rx+=$3; tx+=$11} END{print rx+0, tx+0}' /proc/net/dev; }

echo "$(date '+%F %T') 에이전트 시작: $HOST -> $URL (간격 ${INTERVAL}초)"
write_status false "시작 중" 0 0
read -r prev_idle prev_total < <(read_cpu)
read -r prev_rx prev_tx < <(read_net)
prev_t=$(date +%s); fail=0

while true; do
  sleep "$INTERVAL"
  load_conf   # 이름/설정 변경을 바로 반영

  read -r idle total < <(read_cpu)
  d_idle=$((idle - prev_idle)); d_total=$((total - prev_total)); cpu=0
  [ "$d_total" -gt 0 ] && cpu=$(awk -v i="$d_idle" -v t="$d_total" 'BEGIN{printf "%.1f", (1 - i/t) * 100}')
  prev_idle=$idle; prev_total=$total

  read -r mem_total mem_avail < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t*1024, a*1024}' /proc/meminfo)
  mem_used=$((mem_total - mem_avail)); mem_pct=$(( mem_total > 0 ? mem_used * 100 / mem_total : 0 ))

  now=$(date +%s); dt=$((now - prev_t)); [ "$dt" -lt 1 ] && dt=1
  read -r rx tx < <(read_net)
  net_rx=$(( (rx - prev_rx) / dt )); net_tx=$(( (tx - prev_tx) / dt ))
  prev_rx=$rx; prev_tx=$tx; prev_t=$now

  load1=$(cut -d' ' -f1 /proc/loadavg)
  uptime=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)
  disks=$(df -P -B1 -x tmpfs -x devtmpfs -x squashfs -x overlay -x fuse.lxcfs 2>/dev/null | awk 'NR>1 && $1 ~ /^\// {
      printf "%s{\"mount\":\"%s\",\"total\":%s,\"used\":%s}", (n++?",":""), $6, $2, $3 }')

  body=$(printf '{"host":"%s","name":"%s","os":"%s","token":"%s","cpu":%s,"mem_total":%s,"mem_used":%s,"load1":%s,"uptime":%s,"net_rx":%s,"net_tx":%s,"disks":[%s]}' \
    "$(json_str "$HOST")" "$(json_str "$NAME")" "$(json_str "$OS")" "$(json_str "$TOKEN")" "$cpu" "$mem_total" "$mem_used" "$load1" "$uptime" "$net_rx" "$net_tx" "$disks")

  if err=$(curl -sS $CURL_OPTS -m 5 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "X-Token: $TOKEN" --data "$body" "$URL" 2>&1) && [ "$err" = "200" ]; then
    write_status true "" "$cpu" "$mem_pct"
    [ "$fail" -gt 0 ] && echo "$(date '+%F %T') 전송 복구 (cpu=${cpu}% mem=${mem_pct}%)"
    fail=0
  else
    fail=$((fail + 1))
    case "$err" in 401) msg="토큰 불일치 (401)";; 000|"") msg="연결 실패: $err";; *) msg="응답 $err";; esac
    write_status false "$msg" 0 0
    if [ "$fail" -le 3 ] || [ $((fail % 60)) -eq 0 ]; then echo "$(date '+%F %T') 전송 실패 ($fail 회): $msg" >&2; fi
  fi
done
