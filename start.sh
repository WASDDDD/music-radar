#!/usr/bin/env bash
# 兼容 proot/bash：直接用  bash start.sh  运行
# 现在由后台守护 watch.sh 负责常驻与自愈；本脚本只需运行一次（或根本不用跑，打开网页即可）。
set -e
cd "$(dirname "$0")"
PORT="${PORT:-18765}"

if ! pgrep -f "bash watch.sh" >/dev/null 2>&1; then
  setsid bash watch.sh >> watch.log 2>&1 < /dev/null &
  sleep 2
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
URL="$(cat current_url.txt 2>/dev/null || echo "http://${IP:-<手机IP>}:$PORT")"
echo "音乐雷达已由后台守护运行："
echo "  本机     http://127.0.0.1:$PORT"
echo "  同一 WiFi $URL"
echo "（守护日志：watch.log / 后端日志：run.log）"
