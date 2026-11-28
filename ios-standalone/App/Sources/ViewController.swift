import UIKit
import WebKit
import AVFoundation
import MusicRadarCore

final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let port: UInt16
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    private var webView: WKWebView!

    init(port: UInt16) {
        self.port = port
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "音乐雷达"
        view.backgroundColor = UIColor(red: 0.035, green: 0.043, blue: 0.07, alpha: 1)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "刷新", style: .plain, target: self, action: #selector(reload))

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
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

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // 音频会话失败不阻塞页面
        }
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
}
