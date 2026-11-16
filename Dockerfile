# 音乐雷达 · 可直接云端部署的容器镜像
# 仅标准库，无第三方依赖。
FROM python:3.12-slim
WORKDIR /app
COPY . /app
RUN mkdir -p /data
ENV HOST=0.0.0.0 \
    PORT=8080 \
    MUSICRADAR_DB=/data/music.sqlite3 \
    PYTHONUNBUFFERED=1
EXPOSE 8080
CMD ["python3", "server.py"]
