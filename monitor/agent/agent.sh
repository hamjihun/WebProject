#!/usr/bin/env bash
# Linux 서버용 에이전트: CPU/메모리/디스크/네트워크를 읽어서 수집기로 전송합니다.
# 필요한 것: bash, curl (jq 등 추가 패키지 불필요)
#
# 사용법:
#   chmod +x agent.sh
#   ./agent.sh http://192.168.0.10:8787/api/metrics            # 5초 간격
#   INTERVAL=10 TOKEN=비밀값 ./agent.sh http://192.168.0.10:8787/api/metrics
#
# 백그라운드 실행:  nohup ./agent.sh http://... > /var/log/monitor-agent.log 2>&1 &

URL="${1:-${URL:-http://127.0.0.1:8787/api/metrics}}"
INTERVAL="${INTERVAL:-5}"
TOKEN="${TOKEN:-}"
HOST="${HOST:-$(hostname)}"
OS="$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}" || uname -sr )"

read_cpu() { awk '/^cpu /{idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i; print idle, total}' /proc/stat; }
read_net() { awk -F'[: ]+' 'NR>2 && $2!="lo" {rx+=$3; tx+=$11} END{print rx+0, tx+0}' /proc/net/dev; }

read -r prev_idle prev_total < <(read_cpu)
read -r prev_rx prev_tx < <(read_net)
prev_t=$(date +%s)

while true; do
  sleep "$INTERVAL"

  # CPU: 두 샘플 사이의 idle 비율로 계산
  read -r idle total < <(read_cpu)
  d_idle=$((idle - prev_idle)); d_total=$((total - prev_total))
  cpu=0
  [ "$d_total" -gt 0 ] && cpu=$(awk -v i="$d_idle" -v t="$d_total" 'BEGIN{printf "%.1f", (1 - i/t) * 100}')
  prev_idle=$idle; prev_total=$total

  # 메모리 (bytes)
  read -r mem_total mem_avail < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t*1024, a*1024}' /proc/meminfo)
  mem_used=$((mem_total - mem_avail))

  # 네트워크 (bytes/sec)
  now=$(date +%s); dt=$((now - prev_t)); [ "$dt" -lt 1 ] && dt=1
  read -r rx tx < <(read_net)
  net_rx=$(( (rx - prev_rx) / dt )); net_tx=$(( (tx - prev_tx) / dt ))
  prev_rx=$rx; prev_tx=$tx; prev_t=$now

  load1=$(cut -d' ' -f1 /proc/loadavg)
  uptime=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)

  # 디스크: 실제 파일시스템만 (tmpfs, overlay 등 제외)
  disks=$(df -P -B1 -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1 && $1 ~ /^\// {
      printf "%s{\"mount\":\"%s\",\"total\":%s,\"used\":%s}", (n++?",":""), $6, $2, $3 }')

  body=$(printf '{"host":"%s","os":"%s","token":"%s","cpu":%s,"mem_total":%s,"mem_used":%s,"load1":%s,"uptime":%s,"net_rx":%s,"net_tx":%s,"disks":[%s]}' \
    "$HOST" "$OS" "$TOKEN" "$cpu" "$mem_total" "$mem_used" "$load1" "$uptime" "$net_rx" "$net_tx" "$disks")

  if curl -sS -m 5 -o /dev/null -X POST -H 'Content-Type: application/json' -H "X-Token: $TOKEN" --data "$body" "$URL"; then
    echo "$(date '+%F %T') sent cpu=${cpu}% mem=$((mem_used*100/mem_total))%"
  else
    echo "$(date '+%F %T') send failed to $URL" >&2
  fi
done
