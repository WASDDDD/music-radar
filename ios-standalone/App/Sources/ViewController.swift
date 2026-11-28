import UIKit
import WebKit
import AVFoundation
import MediaPlayer
import MusicRadarCore

/// 弱引用转发，避免 WKUserContentController 强持有 ViewController 形成环。
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(uc, didReceive: message)
    }
}

final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let port: UInt16
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    private var webView: WKWebView!

    // 锁屏 / 控制中心 / 耳机键
    private var remoteConfigured = false
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var artworkLoading: Set<String> = []

    init(port: UInt16) {
        self.port = port
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 旧版本可能留下 Live Activity：启动时清掉，避免锁屏残留空卡片。
        LiveActivityManager.shared.end()
        title = "音乐雷达"
        view.backgroundColor = UIColor(red: 0.035, green: 0.043, blue: 0.07, alpha: 1)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "刷新", style: .plain, target: self, action: #selector(reload))

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        // 允许 WKWebView 在 App 进入后台后继续播放音频（私有键，先探测避免 KVC 崩溃）
        if cfg.preferences.responds(to: NSSelectorFromString("set_allowBackgroundMediaPlayback:")) {
            cfg.preferences.setValue(true, forKey: "_allowBackgroundMediaPlayback")
        }
        // 注入原生桥：页面里的 window.MRHost 会推送到锁屏/控制中心
        cfg.userContentController.addUserScript(WKUserScript(
            source: ViewController.hostBridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        cfg.userContentController.add(WeakScriptHandler(self), name: "mrHost")

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.isOpaque = false
        wv.backgroundColor = view.backgroundColor
        view.addSubview(wv)
        wv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            wv.topAnchor.constraint(equalTo: view.topAnchor),
            wv.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        webView = wv
        load()

        configureAudioSession()
        setupRemoteCommands()
        NotificationCenter.default.addObserver(self, selector: #selector(configureAudioSession),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(configureAudioSession),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(configureAudioSession),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(configureAudioSession),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            // 音频会话失败不阻塞页面
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        configureAudioSession()
        UIApplication.shared.beginReceivingRemoteControlEvents()
        // 回到前台后把当前状态重新推给锁屏（例如从后台被系统短暂挂起）
        webView?.evaluateJavaScript("try{ if(window.__mrRestoreNative) window.__mrRestoreNative(); }catch(e){}", completionHandler: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pushInsets()
    }

    private func load() {
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        webView.load(URLRequest(url: url))
    }

    @objc private func reload() {
        webView.reload()
    }

    private func pushInsets() {
        let insets = view.safeAreaInsets
        let js = "document.documentElement.style.setProperty('--sa-top','\(insets.top)px');" +
                 "document.documentElement.style.setProperty('--sa-bottom','\(insets.bottom)px');" +
                 "document.documentElement.style.setProperty('--sa-left','\(insets.left)px');" +
                 "document.documentElement.style.setProperty('--sa-right','\(insets.right)px');"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushInsets()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "加载失败", message: error.localizedDescription + "\n请点右上角刷新重试", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    // MARK: - 原生桥：页面 → 锁屏/控制中心

    private static let hostBridgeJS = """
    (function(){
      if (window.MRHost) { return; }
      function send(o){ try { window.webkit.messageHandlers.mrHost.postMessage(o); } catch(e){} }
      window.MRHost = {
        updateFull: function(t,a,p,c,d,pos,l){ send({op:'updateFull',title:t||'',artist:a||'',playing:!!p,cover:c||'',dur:d||0,pos:pos||0,liked:l?1:0}); },
        update: function(t,a,p){ send({op:'update',title:t||'',artist:a||'',playing:!!p}); },
        idle: function(){ send({op:'idle'}); }
      };
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "mrHost", let body = message.body as? [String: Any] else { return }
        let op = body["op"] as? String ?? ""
        if op == "idle" {
            updateNowPlaying(title: "", artist: "", playing: false, cover: "",
                             duration: 0, position: 0, clear: true)
            return
        }
        let title = body["title"] as? String ?? ""
        let artist = body["artist"] as? String ?? ""
        let playing = (body["playing"] as? NSNumber)?.boolValue ?? false
        let cover = body["cover"] as? String ?? ""
        let dur = (body["dur"] as? NSNumber)?.doubleValue ?? 0   // 毫秒
        let pos = (body["pos"] as? NSNumber)?.doubleValue ?? 0   // 毫秒
        if title.isEmpty && artist.isEmpty && !playing {
            updateNowPlaying(title: "", artist: "", playing: false, cover: "",
                             duration: 0, position: 0, clear: true)
            return
        }
        updateNowPlaying(title: title, artist: artist, playing: playing, cover: cover,
                         duration: dur / 1000.0, position: pos / 1000.0, clear: false)
    }

    private func updateNowPlaying(title: String, artist: String, playing: Bool,
                                  cover: String, duration: Double, position: Double, clear: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        if clear {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            LiveActivityManager.shared.end()
            return
        }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title.isEmpty ? "音乐雷达" : title
        if !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, position)
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        if let art = artworkCache[cover] {
            info[MPMediaItemPropertyArtwork] = art
        } else if !cover.isEmpty {
            loadArtwork(cover)
        }
        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused

        // 灵动岛交给系统 Now Playing（MediaSession/MPNowPlayingInfoCenter）展示，避免自建 Live Activity 与系统卡片重复。
    }

    private func resolveCoverURL(_ raw: String) -> URL? {
        if raw.isEmpty { return nil }
        if raw.hasPrefix("data:") { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return URL(string: raw) }
        if raw.hasPrefix("/") { return URL(string: "http://127.0.0.1:\(port)\(raw)") }
        // 相对 CDN 路径（如 //y.gtimg.cn/...）
        if raw.hasPrefix("//") { return URL(string: "https:" + raw) }
        return URL(string: raw)
    }

    private func loadArtwork(_ cover: String) {
        guard !artworkLoading.contains(cover), artworkCache[cover] == nil else { return }
        guard let url = resolveCoverURL(cover) else { return }
        artworkLoading.insert(cover)
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self else { return }
            self.artworkLoading.remove(cover)
            guard let data = data, let image = UIImage(data: data), image.size.width > 1 else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.artworkCache[cover] = artwork
            // 若当前仍是同一封面，补进 nowPlayingInfo
            if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }.resume()
    }

    // MARK: - 锁屏/耳机键 → 页面

    private func setupRemoteCommands() {
        guard !remoteConfigured else { return }
        remoteConfigured = true
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.isEnabled = true
        c.playCommand.addTarget { [weak self] _ in
            self?.eval("window.__mrNativeToggle && window.__mrNativeToggle('play')")
            return .success
        }
        c.pauseCommand.isEnabled = true
        c.pauseCommand.addTarget { [weak self] _ in
            self?.eval("window.__mrNativeToggle && window.__mrNativeToggle('pause')")
            return .success
        }
        c.togglePlayPauseCommand.isEnabled = true
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.eval("window.__mrNativeToggle && window.__mrNativeToggle()")
            return .success
        }
        c.nextTrackCommand.isEnabled = true
        c.nextTrackCommand.addTarget { [weak self] _ in
            self?.eval("window.__mrNativeNext && window.__mrNativeNext()")
            return .success
        }
        c.previousTrackCommand.isEnabled = true
        c.previousTrackCommand.addTarget { [weak self] _ in
            self?.eval("window.__mrNativePrev && window.__mrNativePrev()")
            return .success
        }
        c.changePlaybackPositionCommand.isEnabled = true
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let ms = Int(e.positionTime * 1000.0)
            self?.eval("window.__mrNativeSeek && window.__mrNativeSeek(\(ms))")
            return .success
        }
        // 未使用的命令关掉，避免控制中心出现无效按钮
        c.skipBackwardCommand.isEnabled = false
        c.skipForwardCommand.isEnabled = false
        c.seekBackwardCommand.isEnabled = false
        c.seekForwardCommand.isEnabled = false
        c.ratingCommand.isEnabled = false
    }

    private func eval(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("try{ \(js); }catch(e){}", completionHandler: nil)
        }
    }
}
