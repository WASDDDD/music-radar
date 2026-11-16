#!/usr/bin/env bash
# 在 DSH 的 Linux 终端里运行： bash deploy-github.sh https://github.com/你的用户名/仓库名.git
# 会在 /root/workspace/run 下建干净仓库并推送（推到 /sdcard 上 git 不稳，故先复制到运行区）。
set -e
REPO="${1:?用法: bash deploy-github.sh <仓库地址> 例如 https://github.com/你/音乐雷达.git}"
SRC="$(cd "$(dirname "$0")" && pwd)"
RUN="/root/workspace/run/musicradar-repo"
rm -rf "$RUN"; mkdir -p "$RUN"
cp -f "$SRC"/server.py "$SRC"/index.html "$SRC"/commons_provider.py "$SRC"/manifest.webmanifest \
      "$SRC"/icon.svg "$SRC"/requirements.txt "$SRC"/Procfile "$SRC"/Dockerfile \
      "$SRC"/render.yaml "$SRC"/README-部署.md "$SRC"/test_music.py "$SRC"/start.sh "$SRC"/watch.sh "$RUN"/
cd "$RUN"
git init -b main >/dev/null 2>&1 || true
git add -A
git -c user.name="music-radar" -c user.email="music-radar@users.noreply.github.com" commit -m "音乐雷达 web 版" >/dev/null 2>&1 || true
git branch -M main
git remote remove origin >/dev/null 2>&1 || true
git remote add origin "$REPO"
echo "推送中……用户名填 GitHub 用户名，密码处粘贴你的 Personal Access Token（不是登录密码）"
git push -u origin main
