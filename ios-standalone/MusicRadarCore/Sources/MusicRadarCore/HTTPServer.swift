import Foundation
import Network

public final class HTTPServer {
    public typealias AssetProvider = (String) -> Data?

    private let requestedPort: UInt16
    private let assets: AssetProvider
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "musicradar.http", attributes: .concurrent)
    public private(set) var port: UInt16 = 0
    public var version = "2.0-ios"

    public init(port: UInt16 = 18772, assets: @escaping AssetProvider) {
        self.requestedPort = port
        self.assets = assets
    }

    public func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                 port: NWEndpoint.Port(rawValue: requestedPort)!)
        let l = try NWListener(using: params)
        listener = l
        let sem = DispatchSemaphore(value: 0)
        var started = false
        l.stateUpdateHandler = { state in
            switch state {
            case .ready:
                started = true
                sem.signal()
            case .failed, .cancelled:
                sem.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        l.start(queue: queue)
        _ = sem.wait(timeout: .now() + 6)
        guard started, let p = l.port?.rawValue else {
            throw MRPlaybackError("本地服务启动失败", "SERVER")
        }
        port = p
        return p
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buf = buffer
            if let data = data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = buf.subdata(in: 0..<range.lowerBound)
                self.handle(conn, head: head)
                return
            }
            if isComplete || error != nil || buf.count > 64 * 1024 {
                conn.cancel(); return
            }
            self.receive(conn, buffer: buf)
        }
    }

    private func handle(_ conn: NWConnection, head: Data) {
        guard let text = String(data: head, encoding: .utf8) else { conn.cancel(); return }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { conn.cancel(); return }
        let parts = first.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = parts[0]
        let target = parts[1]
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let c = line.firstIndex(of: ":") {
                let k = line[..<c].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        var path = target
        var query = ""
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q]); query = String(target[target.index(after: q)...])
        }
        let params = Self.parseQuery(query)
        route(conn, method: method, path: path, params: params, headers: headers)
    }

    private func route(_ conn: NWConnection, method: String, path: String, params: [String: String], headers: [String: String]) {
        let head = method == "HEAD"
        guard method == "GET" || head else {
            send(conn, 405, "application/json; charset=utf-8", data("{\"error\":\"Method Not Allowed\"}"), head: head)
            return
        }
        if path == "/" || path == "/index.html" {
            let page = assets("index.html") ?? data("<h1>missing index.html</h1>")
            send(conn, 200, "text/html; charset=utf-8", page, head: head); return
        }
        if path == "/favicon.ico" {
            send(conn, 404, "text/plain; charset=utf-8", Data(), head: head); return
        }
        if path == "/api/health" {
            let health: [String: Any] = ["ok": true, "app": "music-radar", "version": version,
                                         "sources": ["netease", "tencent", "kugou", "joox", "kuwo"],
                                         "offline": true, "port": Int(port)]
            sendJSON(conn, 200, health, head: head); return
        }
        if path == "/.netlify/functions/playback" { handlePlayback(conn, params, head); return }
        if path == "/.netlify/functions/search" { handleSearch(conn, params, head); return }
        if path == "/.netlify/functions/lyric" { handleLyric(conn, params, head); return }
        if path == "/.netlify/functions/playlist" { handlePlaylist(conn, params, head); return }
        if path == "/img" { handleImage(conn, params, head); return }
        if path.hasPrefix("/media/") { handleMedia(conn, String(path.dropFirst(7)), headers, head); return }
        send(conn, 404, "application/json; charset=utf-8", data("{\"error\":\"Not Found\"}"), head: head)
    }

    private func handlePlayback(_ conn: NWConnection, _ p: [String: String], _ head: Bool) {
        let source = p["source"] ?? "", id = p["id"] ?? ""
        let name = p["name"] ?? "", artist = p["artist"] ?? ""
        guard ["netease", "tencent", "kugou", "kuwo"].contains(source) else {
            sendJSON(conn, 400, ["error": "不支持的音乐源"], head: head); return
        }
        var input = MRPlaybackInput()
        input.source = source; input.id = id; input.name = name; input.artist = artist
        do {
            let res = try Playback.shared.resolve(input)
            sendJSON(conn, 200, res, head: head)
        } catch let e as MRPlaybackError {
            sendJSON(conn, 422, ["error": e.message], head: head)
        } catch {
            sendJSON(conn, 500, ["error": String(describing: error)], head: head)
        }
    }

    private func handleSearch(_ conn: NWConnection, _ p: [String: String], _ head: Bool) {
        let source = p["source"] ?? "", keyword = p["keyword"] ?? ""
        guard source == "kuwo" else { sendJSON(conn, 400, ["error": "不支持的搜索源"], head: head); return }
        guard !keyword.trimmingCharacters(in: .whitespaces).isEmpty else {
            sendJSON(conn, 400, ["error": "缺少关键词"], head: head); return
        }
        let limit = max(1, min(60, Int(p["limit"] ?? "") ?? 30))
        let page = max(0, Int(p["page"] ?? "") ?? 0)
        let rows = Kuwo.search(keyword, "", pagesize: limit, pn: page)
        let arr: [[String: Any]] = rows.map { s in
            ["id": s.id, "name": s.name, "artist": s.artist, "album": s.album, "pic": s.pic,
             "url": "kuwo://track?id=" + s.id,
             "lrc": "/.netlify/functions/lyric?source=kuwo&id=" + s.id,
             "server": "kuwo", "duration": s.dur]
        }
        sendJSON(conn, 200, arr, head: head)
    }

    private func handleLyric(_ conn: NWConnection, _ p: [String: String], _ head: Bool) {
        let source = p["source"] ?? "", id = p["id"] ?? ""
        let text = (source == "kuwo" && id.range(of: "^[0-9]{1,15}$", options: .regularExpression) != nil) ? Kuwo.lyric(id) : ""
        send(conn, 200, "text/plain; charset=utf-8", data(text), head: head, extra: ["Access-Control-Allow-Origin": "*"])
    }

    private func handlePlaylist(_ conn: NWConnection, _ p: [String: String], _ head: Bool) {
        let server = p["server"] ?? "", id = p["id"] ?? ""
        let offset = Int(p["offset"] ?? "") ?? 0
        guard ["netease", "tencent"].contains(server),
              id.range(of: "^[0-9]{1,16}$", options: .regularExpression) != nil, offset >= 0 else {
            sendJSON(conn, 400, ["error": "无效的歌单参数"], head: head); return
        }
        do {
            let page = try Playlist.readPage(server, id, offset)
            sendJSON(conn, 200, page, head: head)
        } catch let e as MRPlaybackError {
            sendJSON(conn, 502, ["error": e.message], head: head)
        } catch {
            sendJSON(conn, 502, ["error": String(describing: error)], head: head)
        }
    }

    private func handleImage(_ conn: NWConnection, _ p: [String: String], _ head: Bool) {
        let u = p["url"] ?? ""
        guard u.hasPrefix("http://") || u.hasPrefix("https://") else {
            send(conn, 400, "text/plain; charset=utf-8", data("bad url"), head: head); return
        }
        do {
            let r = try Http.get(u, ua: Http.UA, referer: "https://y.qq.com/", timeoutMs: 12000)
            guard r.ok, r.body.count >= 64, r.body.count <= 6 * 1024 * 1024 else {
                send(conn, 502, "text/plain; charset=utf-8", data("upstream code=\(r.code) len=\(r.body.count)"), head: head); return
            }
            let ct = r.contentType.isEmpty ? "image/jpeg" : r.contentType
            send(conn, 200, ct, r.body, head: head,
                 extra: ["Access-Control-Allow-Origin": "*", "Cache-Control": "public, max-age=86400"])
        } catch {
            let msg = (error as? MRPlaybackError)?.message ?? String(describing: error)
            send(conn, 502, "text/plain; charset=utf-8", data("img error: " + msg), head: head)
        }
    }

    private func handleMedia(_ conn: NWConnection, _ token: String, _ headers: [String: String], _ head: Bool) {
        guard let m = Playback.shared.getMedia(token) else {
            send(conn, 404, "text/plain; charset=utf-8", data("Not Found"), head: head); return
        }
        guard let all = try? Data(contentsOf: m.file, options: .mappedIfSafe), !all.isEmpty else {
            send(conn, 404, "text/plain; charset=utf-8", data("Not Found"), head: head); return
        }
        let total = all.count
        var start = 0, end = total - 1
        var partial = false
        if let range = headers["range"], range.hasPrefix("bytes=") {
            let spec = range.dropFirst(6).trimmingCharacters(in: .whitespaces)
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2 {
                if parts[0].isEmpty, let suffix = Int(parts[1]) {
                    start = max(0, total - suffix); partial = true
                } else if let s = Int(parts[0]) {
                    start = s
                    if let e = Int(parts[1]) { end = e }
                    partial = true
                }
            }
        }
        if start < 0 || start > end || start >= total {
            send(conn, 416, "text/plain; charset=utf-8", Data(), head: head,
                 extra: ["Content-Range": "bytes */\(total)"]); return
        }
        if end >= total { end = total - 1 }
        let body = all.subdata(in: start..<(end + 1))
        var extra = ["Accept-Ranges": "bytes", "Content-Length": String(body.count)]
        if partial { extra["Content-Range"] = "bytes \(start)-\(end)/\(total)" }
        send(conn, partial ? 206 : 200, m.mime, body, head: head, extra: extra)
    }

    // MARK: - HTTP helpers

    private func sendJSON(_ conn: NWConnection, _ code: Int, _ obj: Any, head: Bool) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else {
            send(conn, 500, "application/json; charset=utf-8", data("{\"error\":\"json\"}"), head: head); return
        }
        send(conn, code, "application/json; charset=utf-8", d, head: head, extra: ["Cache-Control": "no-store"])
    }

    private func send(_ conn: NWConnection, _ code: Int, _ type: String, _ body: Data,
                      head: Bool, extra: [String: String] = [:]) {
        var header = "HTTP/1.1 \(code) \(Self.reason(code))\r\n"
        header += "Content-Type: \(type)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        for (k, v) in extra { header += "\(k): \(v)\r\n" }
        header += "\r\n"
        conn.send(content: data(header), completion: .contentProcessed { _ in
            if head || body.isEmpty {
                conn.cancel()
            } else {
                conn.send(content: body, completion: .contentProcessed { _ in conn.cancel() })
            }
        })
    }

    static func parseQuery(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            if pair.isEmpty { continue }
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let k = parts.count > 0 ? decode(parts[0]) : ""
            let v = parts.count > 1 ? decode(parts[1]) : ""
            out[k] = v
        }
        return out
    }

    static func decode(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "+", with: " ")
        return t.removingPercentEncoding ?? t
    }

    private func data(_ s: String) -> Data { Data(s.utf8) }

    static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        case 422: return "Unprocessable Entity"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "OK"
        }
    }
}
