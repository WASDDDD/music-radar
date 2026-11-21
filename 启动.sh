#!/usr/bin/env bash
set -euo pipefail
for tool in node ffmpeg ffprobe; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '缺少依赖：%s。需要 Node.js 24+ 和 ffmpeg/ffprobe。\n' "$tool" >&2
    exit 1
  fi
done
exec node "$(dirname "$0")/server.mjs"
