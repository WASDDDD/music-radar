import UIKit
import WebKit

final class ViewController: UIViewController, WKNavigationDelegate {
    private var webView: WKWebView!
    private let statusLabel = UILabel()
    private let defaultsKey = "musicRadar.serverUrl"
    private let fallbackUrl = "http://192.168.1.8:18772/"
    private let publicUrl = "https://translated-constant-andy-grab.trycloudflare.com/"
    private var triedPublicFallback = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "音乐雷达"
        view.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "刷新", style: .plain, target: self, action: #selector(reload))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "服务器", style: .plain, target: self, action: #selector(editServer))

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self
        webView.backgroundColor = view.backgroundColor
        webView.isOpaque = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        statusLabel.text = "正在连接服务器…"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
        loadServer()
    }

    private var serverUrl: String {
        let v = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return v.isEmpty ? fallbackUrl : v
    }

    private func loadServer() {
        triedPublicFallback = false
        guard let url = URL(string: serverUrl) else { showError("服务器地址格式不正确"); return }
        statusLabel.text = "正在连接服务器…\n" + serverUrl
        statusLabel.isHidden = false
        webView.isHidden = true
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
    }

    private func showError(_ msg: String) {
        statusLabel.text = msg + "\n\n点右上角「服务器」修改地址后重试"
        statusLabel.isHidden = false
        webView.isHidden = true
    }

    private func injectSafeArea() {
        let i = view.safeAreaInsets
        let js = """
        document.documentElement.style.setProperty('--sa-top','0px');
        document.documentElement.style.setProperty('--sa-bottom','\(i.bottom)px');
        document.documentElement.style.setProperty('--sa-left','\(i.left)px');
        document.documentElement.style.setProperty('--sa-right','\(i.right)px');
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc private func reload() { loadServer() }

    @objc private func editServer() {
        let alert = UIAlertController(title: "服务器地址", message: "手机和 iPhone 需在同一 Wi-Fi；也可填公网隧道地址。", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = self.serverUrl
            tf.keyboardType = .URL
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存并刷新", style: .default) { _ in
            var s = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { s = self.fallbackUrl }
            if !s.hasSuffix("/") { s += "/" }
            UserDefaults.standard.set(s, forKey: self.defaultsKey)
            self.loadServer()
        })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusLabel.isHidden = true
        webView.isHidden = false
        injectSafeArea()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError("连接失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let saved = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        if saved.isEmpty && !triedPublicFallback {
            triedPublicFallback = true
            statusLabel.text = "局域网连接失败，尝试公网地址…"
            if let u = URL(string: publicUrl) {
                webView.load(URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
                return
            }
        }
        showError("连接失败：\(error.localizedDescription)")
    }
}
