# 音乐雷达 iOS 完全独立版

不依赖 Android 手机、电脑或外部后端：App 内置 Swift 本地 HTTP 服务（`127.0.0.1:18772`）与完整前端页面。

## 最新构建

- 构建：GitHub Actions `Build standalone iOS IPA`，run `46142640154`，`** BUILD SUCCEEDED **`
- 测试：Swift Package 6 项全部通过（酷我 DES 向量、文本归一化、网易歌单 100 首分页、酷我搜索、WAV 全长/尾段解码、HTTP 健康与首页）
- IPA：`MusicRadar-standalone-unsigned.ipa`，390534 字节，sha256 `eecb78512cd88b4ec8134d2022b24de54a60935b298f8ebefad1c719f36ce195`
- 目标：arm64，iOS 13+，未签名

## 功能

- 内置完整 Swift 后端：网易/QQ 歌单分页、四源搜索、歌词、酷我 DES 取链、完整音频下载、AVFoundation 全长与尾段解码校验、本地缓存、Range 媒体流、图片代理
- 内置同一套前端 `index.html`（381412 字节）
- App 图标：橙红渐变 + 白色音符（`Assets.xcassets/AppIcon.appiconset`）
- 后台音频：`UIBackgroundModes=audio` + `AVAudioSession .playback`，并对 WKWebView 私有键 `_allowBackgroundMediaPlayback` 做 `responds(to:)` 探测，缺失时安全跳过

## 安装

未签名 IPA 需用 Sideloadly / AltStore 以 Apple ID 自签（免费账号 7 天有效）：

1. 电脑安装 Sideloadly，iPhone 连线；
2. 拖入 IPA，输入 Apple ID，Start；
3. 设置 → 通用 → VPN 与设备管理 信任开发者；
4. iOS 16+ 还需打开 设置 → 隐私与安全性 → 开发者模式。

## 已知边界

- 未做 iPhone 真机自动化测试，实际播放/后台行为需安装后验证。
- 音源仍来自公网，首次播放整首下载并校验，耗时取决于歌曲长度和网络。
- 酷我部分原曲只返回试听片段时会被时长校验拒绝，不会用翻唱冒充。
