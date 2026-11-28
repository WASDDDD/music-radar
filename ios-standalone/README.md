# 音乐雷达 iOS 完全独立版

- `MusicRadarCore/`：Swift Package，内置 HTTP 服务、网易/QQ/酷狗/酷我解析、酷我 DES、AVFoundation 音频完整性核验与缓存。
- `App/`：iOS 应用壳，启动本地服务并加载内置 `index.html`，不依赖任何外部设备。

构建：GitHub Actions `Build standalone iOS IPA`（macos-latest）产出未签名 IPA。
