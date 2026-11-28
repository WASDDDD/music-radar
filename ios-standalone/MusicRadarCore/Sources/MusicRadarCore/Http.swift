import Foundation

public enum Http {
    public static let UA = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    public static func get(_ url: String, ua: String = UA, referer: String? = nil, timeoutMs: Int = 16000) throws -> MRHttpResponse {
        guard let u = URL(string: url) else { throw MRPlaybackError("无效的地址", "PARAM") }
        var req = URLRequest(url: u)
        req.timeoutInterval = Double(timeoutMs) / 1000.0
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        if let referer = referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        req.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let sem = DispatchSemaphore(value: 0)
        var result: Result<MRHttpResponse, Error>?
        let task = session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { result = .failure(err); return }
            guard let http = resp as? HTTPURLResponse else {
                result = .failure(MRPlaybackError("无 HTTP 响应", "UPSTREAM")); return
            }
            result = .success(MRHttpResponse(code: http.statusCode, body: data ?? Data(),
                                             contentType: http.value(forHTTPHeaderField: "Content-Type") ?? ""))
        }
        task.resume()
        if sem.wait(timeout: .now() + Double(timeoutMs) / 1000.0 + 3) == .timedOut {
            task.cancel()
            throw MRPlaybackError("请求超时", "UPSTREAM")
        }
        guard let r = result else { throw MRPlaybackError("请求失败", "UPSTREAM") }
        return try r.get()
    }

    public static func download(_ url: String, ua: String = UA, referer: String? = nil,
                                timeoutMs: Int = 45000, maxBytes: Int = 40 * 1024 * 1024) throws -> Data {
        guard let u = URL(string: url) else { throw MRPlaybackError("无效的音频地址", "UNAVAILABLE") }
        var req = URLRequest(url: u)
        req.timeoutInterval = Double(timeoutMs) / 1000.0
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        if let referer = referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        let task = session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { result = .failure(err); return }
            guard let http = resp as? HTTPURLResponse else {
                result = .failure(MRPlaybackError("无 HTTP 响应", "UPSTREAM")); return
            }
            guard (200..<300).contains(http.statusCode) else {
                result = .failure(MRPlaybackError("音频文件 HTTP \(http.statusCode)", "UNAVAILABLE")); return
            }
            let d = data ?? Data()
            if d.count > maxBytes {
                result = .failure(MRPlaybackError("音频文件超过上限", "INVALID_AUDIO")); return
            }
            result = .success(d)
        }
        task.resume()
        if sem.wait(timeout: .now() + Double(timeoutMs) / 1000.0 + 5) == .timedOut {
            task.cancel()
            throw MRPlaybackError("音频下载超时", "UPSTREAM")
        }
        guard let r = result else { throw MRPlaybackError("音频下载失败", "UPSTREAM") }
        return try r.get()
    }

    public static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    public static func joinQuery(_ params: [String: String]) -> String {
        params.map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }.joined(separator: "&")
    }
}
