# 音乐雷达 · 部署成「任意设备都能用」的公网服务

目标：后端只在一个地方长期托管，手机/电脑/平板打开同一个网址即可使用，**不需要在每台设备上跑服务**。

后端是纯 Python 3 标准库 + SQLite，单文件服务，部署很简单。下面按「最省事」到「最可控」给几种方式。

---

## 方案 A：Render 免费托管（推荐，免费、无需信用卡）

1. 注册 https://render.com ，用 GitHub 登录。
2. 新建一个 GitHub 仓库，把本目录所有文件传上去（`server.py / index.html / commons_provider.py / manifest.webmanifest / icon.svg / render.yaml ...`）。
3. 在 Render 选 **New → Blueprint**，选中该仓库（会自动读取 `render.yaml`）。
   或选 **New → Web Service**，Runtime 选 Python，Start Command 填：
   `python3 server.py --host 0.0.0.0 --port $PORT`
4. 部署完成后，Render 给你一个 `https://xxxx.onrender.com` 的公网地址，任何设备打开即可。
5. 手机浏览器打开该地址 → 菜单里「添加到主屏幕」，就像个 App。

注意事项：
- 免费实例**闲置一段时间会休眠**，下次打开有约 30 秒冷启动，之后正常。
- 免费实例的文件系统是**临时的**：`music.sqlite3` 里的日/周/月榜历史在重新部署后会清空，会从当天重新累计。若要长期保留榜单，升级付费磁盘或改用外部数据库（告诉我就行，我可以改）。
- 公开地址意味着别人也能访问，如需加访问口令，告诉我，我给后端加一层简单密码。

## 方案 B：Docker / 自建 VPS

任何能跑 Docker 的服务器 / NAS / 旧电脑：
```bash
docker build -t music-radar .
docker run -d -p 8080:8080 --restart unless-stopped \
  -v /你的目录/data:/data --name music-radar music-radar
```
访问 `http://服务器IP:8080`。带 `--restart unless-stopped` 开机自启；数据挂在 `/data` 持久化。
也可以直接 `python3 server.py --host 0.0.0.0 --port 8080`（设 `MUSICRADAR_DB` 指到你的数据盘）。

## 方案 C：Fly.io / Koyeb（可免费档，需账号，Fly 可能要绑卡）

同样用本目录的 `Dockerfile`，`fly launch` 后 `fly deploy`，拿到 `https://xxx.fly.dev`。把 `MUSICRADAR_DB` 指到挂载卷即可持久化。

## 方案 D：家里一台常开设备 + 免费内网穿透（仍是一台设备托管）

如果你有常开的电脑/NAS，可以在这台上跑服务，再用 **Cloudflare Tunnel**（`cloudflared tunnel --url http://localhost:8080`）拿到一个公网 `https://....trycloudflare.com` 地址。
优点：数据在自己手里、免费；缺点：依赖家里那台设备开机。

---

## 环境变量

| 变量 | 作用 | 默认 |
|---|---|---|
| `HOST` | 监听地址 | 127.0.0.1（云端/Docker 用 0.0.0.0） |
| `PORT` | 监听端口 | 8765（多数平台会注入 PORT） |
| `MUSICRADAR_DB` | SQLite 数据库路径 | 程序目录下 music.sqlite3 |

## 本地运行（和以前一样）

```bash
python3 server.py --host 0.0.0.0 --port 18765
```

---

### 一句话结论
想「任意设备用、不靠本机跑服务」，就把这个目录传到 GitHub，用 Render 蓝图一键部署，拿到一个固定公网网址即可。需要我把它改成带访问密码、或改成用外部数据库持久化榜单，直接说。
