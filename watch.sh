#!/usr/bin/env bash
# 音乐雷达 · 后台守护进程
# 作用：自动拉起后端、崩溃后自动重启、持续写入当前可访问地址 current_url.txt
# 启动：setsid bash watch.sh >/dev/null 2>&1 &     （或直接双击 start.sh 由它带起）
cd "$(dirname "$0")" || exit 1

PORT="${PORT:-18765}"
PY="python3"
STATUS="http://127.0.0.1:${PORT}/api/status"

# 单实例锁
LOCK="/tmp/musicradar-watch.lock"
exec 9>"$LOCK" || exit 1
flock -n 9 || { echo "[watch] already running"; exit 0; }

health() {
  "$PY" - "$STATUS" >/dev/null 2>&1 <<'PYEOF'
import sys, urllib.request
urllib.request.urlopen(sys.argv[1], timeout=3)
PYEOF
}

echo "[watch] start $(date '+%F %T') pid=$$" >> watch.log
while :; do
  if [ -f .paused ]; then
    # 已暂停：不自动拉起后端（由「启动」开关恢复）
    :
  elif ! health; then
    echo "[watch] $(date '+%F %T') 后端无响应，拉起中" >> watch.log
    nohup "$PY" -B server.py --host 0.0.0.0 --port "$PORT" >> run.log 2>&1 &
    echo $! > run.pid
    sleep 4
  fi
  IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -z "$IP" ] && IP="127.0.0.1"
  printf 'http://%s:%s\n' "$IP" "$PORT" > current_url.txt
  sleep 10
done
