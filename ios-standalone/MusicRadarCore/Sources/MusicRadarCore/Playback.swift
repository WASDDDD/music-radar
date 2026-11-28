import Foundation

public final class Playback {
    public static let shared = Playback()

    // 递归锁：只在读写内存状态时短暂持有；网络下载与整曲解码都在锁外进行，
    // 避免“一首歌核验卡住时，切歌/并发请求全部串行阻塞”。
    private let lock = NSRecursiveLock()
    public var cacheDir: URL
    private var manifest: [String: [String: Any]] = [:]   // canonKey -> entry
    private var results: [String: [String: Any]] = [:]    // "source:id" -> result
    private var media: [String: MRMediaFile] = [:]        // token -> media
    private var mediaOrder: [String] = []                 // token 插入顺序（限制常驻数量，供淘汰判断“正在播放”）
    private let mediaKeep = 32
    private var inflight: [String: DispatchSemaphore] = [:] // "source:id" -> 进行中的等待信号
    private var waiters: [String: Int] = [:]                // "source:id" -> 等待该请求的并发数（用于广播唤醒）
    private var lastError: [String: MRPlaybackError] = [:]

    /// 音频缓存总容量上限（超出后按修改时间淘汰最旧文件，正在播放的文件永不删除）。
    public var cacheLimitBytes: Int64 = 1200 * 1024 * 1024

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDir = base.appendingPathComponent("MusicRadarAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        loadManifest()
    }

    private func loadManifest() {
        let f = cacheDir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: f),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
        // 迁移：历史条目存的是绝对路径，重装/重签名后容器 UUID 改变会全部失效；
        // 统一改为只存文件名（相对 cacheDir），让缓存可跨重装复用。
        var migrated = false
        for (k, stored) in obj {
            var e = stored
            if let p = e["file"] as? String, p.contains("/") {
                e["file"] = (p as NSString).lastPathComponent
                migrated = true
            }
            manifest[k] = e
        }
        if migrated { saveManifest() }
    }

    private func saveManifest() {
        guard let data = try? JSONSerialization.data(withJSONObject: manifest) else { return }
        try? data.write(to: cacheDir.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func fileURL(_ entry: [String: Any]) -> URL? {
        guard let name = entry["file"] as? String, !name.isEmpty else { return nil }
        let url = cacheDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 记录 token 并限制常驻数量（调用时须已持有 lock）。
    private func recordMedia(_ token: String) {
        mediaOrder.append(token)
        while mediaOrder.count > mediaKeep {
            let old = mediaOrder.removeFirst()
            if old != token { media.removeValue(forKey: old) }
        }
    }

    // MARK: - Official sources

    private func json(_ url: String, headers: [String: String]? = nil) throws -> [String: Any] {
        let ua = headers?["User-Agent"] ?? Http.UA
        let ref = headers?["Referer"] ?? "https://y.qq.com/"
        let r = try Http.get(url, ua: ua, referer: ref, timeoutMs: 16000)
        guard r.ok else { throw MRPlaybackError("上游 HTTP \(r.code)", "UPSTREAM") }
        guard let data = r.text.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MRPlaybackError("上游返回格式错误", "UPSTREAM")
        }
        return obj
    }

    private func qq(_ module: String, _ method: String, _ param: [String: Any]) throws -> [String: Any] {
        let body: [String: Any] = [
            "comm": ["uin": 0, "format": "json", "ct": 24, "cv": 0],
            "req_0": ["module": module, "method": method, "param": param]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        let d = try json("https://u.y.qq.com/cgi-bin/musicu.fcg?data=" + Http.urlEncode(text))
        guard let r0 = d["req_0"] as? [String: Any], (r0["code"] as? Int ?? -1) == 0,
              let dd = r0["data"] as? [String: Any] else {
            throw MRPlaybackError("QQ 官方接口暂时不可用", "UPSTREAM")
        }
        return dd
    }

    public func official(_ source: String, _ id: String) throws -> MRPlayMeta {
        if source == "tencent" {
            guard id.range(of: "^[a-zA-Z0-9]{8,20}$", options: .regularExpression) != nil else {
                throw MRPlaybackError("无效的 QQ 歌曲标识", "PARAM")
            }
            let d0 = try qq("music.pf_song_detail_svr", "get_song_detail_yqq", ["song_mid": id])
            guard let t = d0["track_info"] as? [String: Any] else {
                throw MRPlaybackError("QQ 未返回曲目资料", "UPSTREAM")
            }
            var m = MRPlayMeta()
            m.source = source; m.id = id
            m.name = t["title"] as? String ?? (t["name"] as? String ?? "")
            if let singers = t["singer"] as? [[String: Any]] {
                m.artist = singers.compactMap { $0["name"] as? String }.joined(separator: "/")
            }
            if let album = t["album"] as? [String: Any] {
                m.album = album["title"] as? String ?? (album["name"] as? String ?? "")
            }
            m.expectedDuration = num(t["interval"])
            let file = t["file"] as? [String: Any]
            var mediaMid = file?["media_mid"] as? String ?? ""
            if mediaMid.isEmpty { mediaMid = id + id }
            let guid = String(Int64(1_000_000_000 + Double.random(in: 0...8_000_000_000)))
            let p2: [String: Any] = [
                "uin": "0",
                "filename": ["M500" + mediaMid + ".mp3"],
                "guid": guid,
                "songmid": [id],
                "songtype": [0],
                "ctx": 0
            ]
            let d1 = try qq("music.vkey.GetVkey", "UrlGetVkey", p2)
            let mids = d1["midurlinfo"] as? [[String: Any]]
            let purl = mids?.first?["purl"] as? String ?? ""
            if purl.isEmpty {
                m.unavailable = true
                m.reason = "QQ 当前账号未获得这首歌的完整播放地址"
                return m
            }
            var base = "https://isure.stream.qqmusic.qq.com/"
            if let sip = d1["sip"] as? [String] {
                for (i, s) in sip.enumerated() {
                    if s.hasPrefix("https://") { base = s; break }
                    if i == 0 && !s.isEmpty { base = s }
                }
            }
            m.url = absUrl(purl, base)
            return m
        }
        if source == "kugou" {
            guard id.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil else {
                throw MRPlaybackError("无效的酷狗歌曲标识", "PARAM")
            }
            let d = try json("https://m.kugou.com/api/v1/song/get_song_info?hash=\(id)&cmd=playInfo")
            var m = MRPlayMeta()
            m.source = source; m.id = id
            m.name = d["songName"] as? String ?? (d["songname"] as? String ?? "")
            m.artist = d["singerName"] as? String ?? (d["singername"] as? String ?? "")
            m.album = d["album_name"] as? String ?? ""
            m.expectedDuration = num(d["timeLength"])
            if m.expectedDuration <= 0, let extra = d["extra"] as? [String: Any] {
                m.expectedDuration = num(extra["128timelength"]) / 1000.0
            }
            var url = d["url"] as? String ?? ""
            if url.isEmpty, let bu = d["backup_url"] as? [String] {
                url = bu.first(where: { $0.hasPrefix("http") }) ?? ""
            }
            if url.isEmpty {
                m.unavailable = true
                m.reason = d["error"] as? String ?? "酷狗未提供完整播放地址"
                return m
            }
            m.url = url
            return m
        }
        if source == "netease" {
            guard id.range(of: "^[0-9]{1,18}$", options: .regularExpression) != nil else {
                throw MRPlaybackError("无效的网易歌曲标识", "PARAM")
            }
            let ids = "[\"\(id)\"]"
            let d = try json("https://music.163.com/api/song/detail?id=\(id)&ids=" + Http.urlEncode(ids))
            guard let songs = d["songs"] as? [[String: Any]], let t = songs.first else {
                throw MRPlaybackError("网易未返回曲目资料", "UPSTREAM")
            }
            var m = MRPlayMeta()
            m.source = source; m.id = id
            m.name = t["name"] as? String ?? ""
            let ar = (t["artists"] as? [[String: Any]]) ?? (t["ar"] as? [[String: Any]]) ?? []
            m.artist = ar.compactMap { $0["name"] as? String }.joined(separator: "/")
            if let al = (t["album"] as? [String: Any]) ?? (t["al"] as? [String: Any]) {
                m.album = al["name"] as? String ?? ""
            }
            let dt = num(t["duration"]) > 0 ? num(t["duration"]) : num(t["dt"])
            m.expectedDuration = dt / 1000.0
            m.urls = ["https://api.qijieya.cn/meting/?server=netease&type=url&id=\(id)",
                      "https://api.injahow.cn/meting/?server=netease&type=url&id=\(id)"]
            m.url = m.urls.first
            return m
        }
        if source == "kuwo" {
            guard id.range(of: "^[0-9]{1,15}$", options: .regularExpression) != nil else {
                throw MRPlaybackError("无效的酷我歌曲标识", "PARAM")
            }
            let info = Kuwo.info(id)
            var m = MRPlayMeta()
            m.source = source; m.id = id
            if let info = info {
                m.name = info.name; m.artist = info.artist; m.album = info.album
                m.pic = info.pic; m.expectedDuration = info.dur
            }
            guard let u = Kuwo.playUrl(id) else {
                m.unavailable = true
                m.reason = "酷我未提供完整播放地址"
                return m
            }
            m.url = u
            m.headers["User-Agent"] = Kuwo.UA
            m.headers["Referer"] = "https://www.kuwo.cn/"
            return m
        }
        throw MRPlaybackError("不支持的音乐源", "PARAM")
    }

    private func absUrl(_ purl: String, _ base: String) -> String {
        if purl.hasPrefix("http") { return purl }
        var b = base
        if !b.hasSuffix("/") { b += "/" }
        if let baseURL = URL(string: b), let u = URL(string: purl, relativeTo: baseURL) { return u.absoluteString }
        return b + purl
    }

    // MARK: - Download & verify

    public func download(_ meta: MRPlayMeta) throws -> [String: Any] {
        guard let url = meta.url, !url.isEmpty, url.hasPrefix("http") else {
            throw MRPlaybackError("没有可用的完整音频地址", "UNAVAILABLE")
        }
        let ua = meta.headers["User-Agent"] ?? Http.UA
        let ref = meta.headers["Referer"] ?? "https://y.qq.com/"
        let data = try Http.download(url, ua: ua, referer: ref, timeoutMs: 45000, maxBytes: 40 * 1024 * 1024)
        guard data.count >= 4096 else { throw MRPlaybackError("上游返回空文件或错误内容", "INVALID_AUDIO") }
        let token = Self.randomToken()
        let ext = AudioProbe.fileExtension(for: data)
        let fileName = "\(token).\(ext)"
        let file = cacheDir.appendingPathComponent(fileName)
        try data.write(to: file, options: .atomic)
        let info = AudioProbe.probe(file)
        if !info.hasAudio || info.duration < 10 {
            try? FileManager.default.removeItem(at: file)
            throw MRPlaybackError("文件不是可播放歌曲", "INVALID_AUDIO")
        }
        let tol = meta.durationTolerance > 0 ? meta.durationTolerance : max(4, meta.expectedDuration * 0.025)
        if meta.expectedDuration <= 0 && meta.verifyTitle == nil {
            try? FileManager.default.removeItem(at: file)
            throw MRPlaybackError("音频时长与原曲不符，已拒绝试听或错误版本", "DURATION_MISMATCH")
        }
        if meta.expectedDuration > 0 && abs(info.duration - meta.expectedDuration) > tol {
            try? FileManager.default.removeItem(at: file)
            throw MRPlaybackError("音频时长与原曲不符，已拒绝试听或错误版本", "DURATION_MISMATCH")
        }
        if !info.fullDecoded {
            try? FileManager.default.removeItem(at: file)
            throw MRPlaybackError("音频无法完整解码", "INVALID_AUDIO")
        }
        if !info.tailDecoded {
            try? FileManager.default.removeItem(at: file)
            throw MRPlaybackError("音频尾段无法解码", "INVALID_AUDIO")
        }
        let mime = info.mime.hasPrefix("audio/") ? info.mime : "audio/mpeg"
        var entry: [String: Any] = [
            "file": fileName, "size": data.count, "mime": mime,
            "duration": info.duration, "expectedDuration": meta.expectedDuration,
            "source": meta.source, "id": meta.id, "name": meta.name,
            "artist": meta.artist, "album": meta.album, "codec": info.codec,
            "substituted": meta.substituted
        ]
        let ck = TextUtil.canonKey(meta.name, meta.artist)
        lock.lock()
        media[token] = MRMediaFile(file: file, size: Int64(data.count), mime: mime)
        recordMedia(token)
        if !ck.isEmpty { manifest[ck] = entry; saveManifest() }
        lock.unlock()
        evictIfNeeded()
        entry["verifiedFull"] = true
        entry["fullDecoded"] = true
        entry["tailDecoded"] = true
        entry["url"] = "/media/" + token
        return entry
    }

    private func serveFromCache(_ entry: [String: Any]) -> [String: Any]? {
        guard let path = fileURL(entry) else { return nil }
        let token = Self.randomToken()
        lock.lock()
        media[token] = MRMediaFile(file: path,
                                   size: Int64(num(entry["size"])), mime: entry["mime"] as? String ?? "audio/mpeg")
        recordMedia(token)
        lock.unlock()
        var res = entry
        res["verifiedFull"] = true
        res["fullDecoded"] = true
        res["tailDecoded"] = true
        res["url"] = "/media/" + token
        res["cached"] = true
        return res
    }

    // MARK: - 缓存容量管理（LRU 近似：按修改时间淘汰最旧）

    private func evictIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let active = Set(media.values.map { $0.file.standardizedFileURL.path })
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for u in items where u.lastPathComponent != "manifest.json" {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(v?.fileSize ?? 0)
            let date = v?.contentModificationDate ?? Date.distantPast
            total += size
            files.append((u, size, date))
        }
        guard total > cacheLimitBytes else { return }
        files.sort { $0.date < $1.date }
        var removedNames = Set<String>()
        for f in files {
            if total <= cacheLimitBytes { break }
            if active.contains(f.url.standardizedFileURL.path) { continue }
            if (try? fm.removeItem(at: f.url)) != nil {
                total -= f.size
                removedNames.insert(f.url.lastPathComponent)
            }
        }
        if !removedNames.isEmpty {
            var stale: [String] = []
            for (k, e) in manifest {
                if let name = e["file"] as? String, removedNames.contains(name) {
                    stale.append(k)
                }
            }
            for k in stale { manifest[k] = nil }
            if !stale.isEmpty { saveManifest() }
        }
    }

    // MARK: - Alternative sources

    private let gdBase = "http://music-api.gdstudio.xyz/api.php"
    private let gdBad = try! NSRegularExpression(pattern: "伴奏|DJ|降調|降调|絕對|绝对|彈唱|弹唱|翻唱|remix|instrumental|0\\.8x|阿卓", options: [.caseInsensitive])

    private func gd(_ params: [String: String], tries: Int) -> Any? {
        var last: Any?
        for i in 0..<tries {
            do {
                let r = try Http.get(gdBase + "?" + Http.joinQuery(params), ua: "Mozilla/5.0", referer: nil, timeoutMs: 30000)
                if r.ok {
                    let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.hasPrefix("["), let data = t.data(using: .utf8),
                       let a = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        if !a.isEmpty { return a }
                        last = a
                    } else if let data = t.data(using: .utf8),
                              let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if !(o["url"] as? String ?? "").isEmpty { return o }
                        last = o
                    }
                }
            } catch {}
            if i < tries - 1 { Thread.sleep(forTimeInterval: 1.5) }
        }
        return last
    }

    private func metingSearch(_ server: String, _ keyword: String) -> [[String: Any]]? {
        do {
            let u = "https://api.qijieya.cn/meting/?server=\(server)&type=search&id=" + Http.urlEncode(keyword) + "&limit=8&page=1"
            let r = try Http.get(u, ua: Http.UA, referer: "https://api.qijieya.cn/", timeoutMs: 16000)
            guard r.ok else { return nil }
            let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("["), let data = t.data(using: .utf8) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        } catch { return nil }
    }

    private func metingId(_ row: [String: Any]) -> String {
        let id = row["id"] as? String ?? (row["id"].map { "\($0)" } ?? "")
        if !id.isEmpty { return id }
        let url = row["url"] as? String ?? ""
        if let r = url.range(of: "id=") {
            let rest = url[r.upperBound...]
            return String(rest.split(separator: "&").first ?? "")
        }
        return ""
    }

    private func durationHint(_ name: String, _ artist: String) -> Double {
        let rows = Kuwo.search(name, artist, pagesize: 30, pn: 0)
        let firstTok = TextUtil.firstTok(artist)
        var cand: [Double] = []
        for r in rows {
            if r.dur <= 0 || Kuwo.bad(r.name) { continue }
            if !TextUtil.looseName(r.name, name) { continue }
            if !firstTok.isEmpty && !TextUtil.artistSet(r.artist).contains(firstTok) { continue }
            cand.append(r.dur)
        }
        if cand.isEmpty { return 0 }
        cand.sort()
        return cand[cand.count / 2]
    }

    private func alternative(_ meta: MRPlayMeta, _ input: MRPlaybackInput) -> [String: Any]? {
        let name = !meta.name.isEmpty ? meta.name : input.name
        let artist = !meta.artist.isEmpty ? meta.artist : input.artist
        if name.isEmpty || artist.isEmpty || meta.expectedDuration <= 0 { return nil }

        // 1) Netease search -> meting
        var cands: [(String, String, String)] = []
        do {
            let d = try json("https://music.163.com/api/search/get?s=" + Http.urlEncode(name + " " + artist) + "&type=1&limit=8")
            if let res = d["result"] as? [String: Any], let songs = res["songs"] as? [[String: Any]] {
                for t in songs {
                    let idv = t["id"].map { "\($0)" } ?? ""
                    let art = (t["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: "/")
                    cands.append((idv, t["name"] as? String ?? "", art))
                }
            }
        } catch {}
        if cands.isEmpty, let arr = metingSearch("netease", name + " " + artist) {
            for t in arr {
                cands.append((metingId(t), t["name"] as? String ?? "", t["artist"] as? String ?? ""))
            }
        }
        for t in cands where !t.0.isEmpty {
            if TextUtil.normalize(t.1) != TextUtil.normalize(name) { continue }
            if TextUtil.artistSet(t.2) != TextUtil.artistSet(artist) { continue }
            for host in ["https://api.qijieya.cn/meting/", "https://api.injahow.cn/meting/"] {
                var m = MRPlayMeta()
                m.source = "netease"; m.id = t.0; m.name = t.1; m.artist = t.2
                m.url = host + "?server=netease&type=url&id=" + t.0
                m.expectedDuration = meta.expectedDuration
                m.substituted = true
                if let r = try? download(m) { return r }
            }
        }

        // 2) QQ / Kugou
        for source in ["tencent", "kugou"] where source != meta.source {
            guard let rows = metingSearch(source, name + " " + artist) else { continue }
            for row in rows {
                if TextUtil.normalize(row["name"] as? String ?? "") != TextUtil.normalize(name) { continue }
                if TextUtil.artistSet(row["artist"] as? String ?? "") != TextUtil.artistSet(artist) { continue }
                let id = metingId(row)
                if id.isEmpty { continue }
                if let cand = try? official(source, id), !cand.unavailable,
                   TextUtil.normalize(cand.name) == TextUtil.normalize(name),
                   TextUtil.artistSet(cand.artist) == TextUtil.artistSet(artist),
                   abs(cand.expectedDuration - meta.expectedDuration) <= max(4, meta.expectedDuration * 0.025) {
                    var c = cand
                    c.expectedDuration = meta.expectedDuration
                    c.substituted = true
                    if let r = try? download(c) { return r }
                }
            }
        }

        // 3) Joox via GD Studio
        let inTok = TextUtil.artistSet(artist).split(separator: "|").map(String.init)
        if !inTok.isEmpty {
            let p = ["types": "search", "source": "joox", "name": name + " " + artist, "count": "30", "pages": "1"]
            if let list = gd(p, tries: 4) as? [[String: Any]] {
                var cand: [[String: Any]] = []
                for r in list {
                    let rid = r["id"] as? String ?? ""
                    if rid.isEmpty || !TextUtil.looseName(r["name"] as? String, name) { continue }
                    let ar = (r["artist"] as? [String] ?? []).joined(separator: "/")
                    let rt = TextUtil.artistSet(ar).split(separator: "|").map(String.init)
                    if !inTok.allSatisfy({ rt.contains($0) }) { continue }
                    let nm = r["name"] as? String ?? ""
                    let ns = nm as NSString
                    if gdBad.firstMatch(in: nm, range: NSRange(location: 0, length: ns.length)) != nil { continue }
                    cand.append(r)
                }
                for row in cand.prefix(3) {
                    for br in ["320", "128"] {
                        let up = ["types": "url", "source": "joox", "id": row["id"] as? String ?? "", "br": br]
                        guard let obj = gd(up, tries: 2) as? [String: Any], let link = obj["url"] as? String, !link.isEmpty else { continue }
                        var m = MRPlayMeta()
                        m.source = "joox"; m.id = row["id"] as? String ?? ""
                        m.name = row["name"] as? String ?? ""
                        m.artist = (row["artist"] as? [String] ?? []).joined(separator: "/")
                        m.album = row["album"] as? String ?? ""
                        m.url = link
                        m.headers["User-Agent"] = "Mozilla/5.0"
                        m.headers["Referer"] = "https://www.joox.com/"
                        m.expectedDuration = meta.expectedDuration
                        m.durationTolerance = max(10, meta.expectedDuration * 0.05)
                        m.verifyTitle = name; m.verifyArtist = artist
                        m.substituted = true
                        if let r = try? download(m) { return r }
                        break
                    }
                }
            }
        }

        // 4) Kuwo fallback
        let rows = Kuwo.search(name, artist, pagesize: 30, pn: 0)
        let exp = meta.expectedDuration
        let ktol = exp > 0 ? max(8, exp * 0.05) : 0
        let firstTok = TextUtil.firstTok(artist)
        var cand: [MRSong] = []
        for r in rows {
            if r.id.isEmpty || Kuwo.bad(r.name) { continue }
            if !TextUtil.looseName(r.name, name) { continue }
            if !firstTok.isEmpty && !TextUtil.artistSet(r.artist).contains(firstTok) { continue }
            if exp > 0 && (r.dur <= 0 || abs(r.dur - exp) > ktol) { continue }
            cand.append(r)
        }
        cand.sort { exp > 0 ? abs($0.dur - exp) < abs($1.dur - exp) : $0.dur > $1.dur }
        for row in cand.prefix(3) {
            guard let u = Kuwo.playUrl(row.id) else { continue }
            var m = MRPlayMeta()
            m.source = "kuwo"; m.id = row.id; m.name = row.name; m.artist = row.artist
            m.url = u
            m.headers["User-Agent"] = Kuwo.UA
            m.headers["Referer"] = "https://www.kuwo.cn/"
            m.expectedDuration = exp > 0 ? exp : row.dur
            m.durationTolerance = ktol > 0 ? ktol : 8
            m.substituted = true
            if let r = try? download(m) { return r }
        }
        return nil
    }

    // MARK: - Resolve（single-flight：同曲并发只做一次，不同曲并行）

    public func resolve(_ input: MRPlaybackInput) throws -> [String: Any] {
        let key = "\(input.source):\(input.id)"
        let ck = (!input.name.isEmpty && !input.artist.isEmpty) ? TextUtil.canonKey(input.name, input.artist) : ""

        lock.lock()
        if !ck.isEmpty, let entry = manifest[ck], let hit = serveFromCache(entry) {
            lock.unlock()
            return hit
        }
        if let cached = results[key] {
            lock.unlock()
            return cached
        }
        if let sem = inflight[key] {
            // 同一首歌已有请求在算：登记为等待者，等它算完（广播唤醒所有等待者）。
            waiters[key, default: 0] += 1
            lock.unlock()
            _ = sem.wait(timeout: .now() + 150)
            lock.lock()
            if let cached = results[key] { lock.unlock(); return cached }
            let err = lastError[key] ?? MRPlaybackError("未找到可用音源", "RIGHTS_REQUIRED")
            lock.unlock()
            throw err
        }
        let sem = DispatchSemaphore(value: 0)
        inflight[key] = sem
        lock.unlock()

        let finish: (Result<[String: Any], Error>) -> Void = { r in
            self.lock.lock()
            switch r {
            case .success(let value):
                self.results[key] = value
                self.lastError[key] = nil
            case .failure(let error):
                self.results[key] = nil
                self.lastError[key] = error as? MRPlaybackError ?? MRPlaybackError(String(describing: error), "UNAVAILABLE")
            }
            self.inflight[key] = nil
            let n = self.waiters[key] ?? 0
            self.waiters[key] = nil
            self.lock.unlock()
            // 广播：每个等待者一次信号量 +1
            for _ in 0..<n { sem.signal() }
        }

        do {
            let value = try computeResolve(input)
            finish(.success(value))
            return value
        } catch let e as MRPlaybackError {
            finish(.failure(e))
            throw e
        } catch {
            finish(.failure(error))
            throw error
        }
    }

    /// 在锁外执行真正的取源/下载/核验（网络与解码都不持锁）。
    private func computeResolve(_ input: MRPlaybackInput) throws -> [String: Any] {
        var meta: MRPlayMeta
        var failure: MRPlaybackError?
        do {
            meta = try official(input.source, input.id)
        } catch {
            let hint = (!input.name.isEmpty && !input.artist.isEmpty) ? durationHint(input.name, input.artist) : 0
            meta = MRPlayMeta()
            meta.source = input.source; meta.id = input.id
            meta.name = input.name; meta.artist = input.artist
            meta.expectedDuration = hint
            meta.unavailable = true
            let msg = (error as? MRPlaybackError)?.message ?? String(describing: error)
            meta.reason = String(msg.prefix(80))
            failure = error as? MRPlaybackError ?? MRPlaybackError(msg, "UNAVAILABLE")
        }
        if !input.name.isEmpty && !input.artist.isEmpty {
            let hint = durationHint(input.name, input.artist)
            if hint > 0 && (meta.expectedDuration <= 0 || meta.expectedDuration < hint * 0.75) {
                meta.expectedDuration = hint
            }
        }
        if !meta.unavailable {
            var urls: [String] = []
            if !meta.urls.isEmpty { urls = meta.urls } else if let u = meta.url { urls = [u] }
            for u in urls {
                var one = meta
                one.url = u
                do {
                    return try download(one)
                } catch {
                    failure = error as? MRPlaybackError ?? MRPlaybackError(String(describing: error), "UNAVAILABLE")
                }
            }
        }
        if let alt = alternative(meta, input) {
            return alt
        }
        if let f = failure { throw f }
        let reason = meta.reason.isEmpty ? "未找到可用音源" : meta.reason
        throw MRPlaybackError(reason + "；未找到歌手、曲名和时长一致的免费完整音源", "RIGHTS_REQUIRED")
    }

    public func getMedia(_ token: String?) -> MRMediaFile? {
        guard let token = token, token.range(of: "^[a-f0-9]{36}$", options: .regularExpression) != nil else { return nil }
        lock.lock(); defer { lock.unlock() }
        return media[token]
    }

    private static func randomToken() -> String {
        let chars = Array("0123456789abcdef")
        return String((0..<36).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    private func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }
}
