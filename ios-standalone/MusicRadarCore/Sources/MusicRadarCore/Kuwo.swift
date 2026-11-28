import Foundation

public enum Kuwo {
    public static let UA = "okhttp/3.10.0"
    private static let urlRegex = try! NSRegularExpression(pattern: "http[^\\s$\"]+", options: [])
    private static let badRegex = try! NSRegularExpression(pattern:
        "ktv|伴奏|伴唱|\\bdj\\b|remix|cover|翻唱|纯音乐|instrumental|铃声|片段|抢听|试听|钢琴|助眠|抖音|精选|\\blive\\b|演唱会|串烧|联唱|组曲|medley|[+＋]",
        options: [.caseInsensitive])

    public static func search(_ name: String, _ artist: String?, pagesize: Int = 30, pn: Int = 0) -> [MRSong] {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return [] }
        let rn = max(1, min(60, pagesize))
        let all = (n + " " + (artist ?? "")).trimmingCharacters(in: .whitespaces)
        var comps = URLComponents(string: "http://search.kuwo.cn/r.s")!
        comps.queryItems = [
            URLQueryItem(name: "client", value: "kt"),
            URLQueryItem(name: "all", value: all),
            URLQueryItem(name: "pn", value: String(max(0, pn))),
            URLQueryItem(name: "rn", value: String(rn)),
            URLQueryItem(name: "uid", value: "794762523"),
            URLQueryItem(name: "ver", value: "kwplayer_ar_9.2.2.1"),
            URLQueryItem(name: "vipver", value: "1"),
            URLQueryItem(name: "show_copyright_off", value: "1"),
            URLQueryItem(name: "newver", value: "1"),
            URLQueryItem(name: "ft", value: "music"),
            URLQueryItem(name: "cluster", value: "0"),
            URLQueryItem(name: "strategy", value: "2012"),
            URLQueryItem(name: "encoding", value: "utf8"),
            URLQueryItem(name: "rformat", value: "json"),
            URLQueryItem(name: "vermerge", value: "1"),
            URLQueryItem(name: "mobi", value: "1")
        ]
        guard let url = comps.url?.absoluteString else { return [] }
        do {
            let r = try Http.get(url, ua: UA, referer: "http://www.kuwo.cn/", timeoutMs: 14000)
            if !r.ok { return [] }
            let text = r.text.replacingOccurrences(of: "'", with: "\"")
            guard let data = text.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["abslist"] as? [[String: Any]] else { return [] }
            return arr.compactMap { o in
                var s = MRSong()
                s.name = o["NAME"] as? String ?? ""
                s.artist = o["ARTIST"] as? String ?? ""
                s.album = o["ALBUM"] as? String ?? ""
                let rid = (o["MUSICRID"] as? String ?? "").replacingOccurrences(of: "MUSIC_", with: "").trimmingCharacters(in: .whitespaces)
                s.id = rid
                s.dur = num(o["DURATION"])
                let pic = o["web_albumpic_short"] as? String ?? ""
                if !pic.isEmpty { s.pic = "https://img1.kuwo.cn/star/albumcover/" + pic }
                return (!s.id.isEmpty && !s.name.isEmpty) ? s : nil
            }
        } catch { return [] }
    }

    public static func playUrl(_ rid: String?) -> String? {
        guard let rid = rid, rid.range(of: "^[0-9]{1,15}$", options: .regularExpression) != nil else { return nil }
        let q = "user=0&corp=kuwo&source=kwplayer_ar_5.1.0.0_B_jiakong_vh.apk&p2p=1&type=convert_url2&sig=0&format=mp3&rid=" + rid
        guard let enc = KuwoCrypto.shared.encryptQuery(q) else { return nil }
        do {
            let r = try Http.get("http://mobi.kuwo.cn/mobi.s?f=kuwo&q=" + Http.urlEncode(enc), ua: UA, referer: "http://www.kuwo.cn/", timeoutMs: 16000)
            if !r.ok { return nil }
            let text = r.text
            let ns = text as NSString
            if let m = urlRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                return ns.substring(with: m.range)
            }
            return nil
        } catch { return nil }
    }

    public static func lyric(_ rid: String?) -> String {
        guard let rid = rid, rid.range(of: "^[0-9]{1,15}$", options: .regularExpression) != nil else { return "" }
        do {
            let r = try Http.get("http://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=\(rid)&httpsStatus=1", ua: UA, referer: "http://www.kuwo.cn/", timeoutMs: 14000)
            if !r.ok { return "" }
            guard let data = r.text.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = obj["data"] as? [String: Any],
                  let list = d["lrclist"] as? [[String: Any]] else { return "" }
            var out = ""
            for o in list {
                let t = num(o["time"])
                var line = o["lineLyric"] as? String ?? ""
                if line.trimmingCharacters(in: .whitespaces) == "//" { line = "" }
                out += "[" + mmss(t) + "]" + line + "\n"
            }
            return out
        } catch { return "" }
    }

    public static func info(_ rid: String?) -> MRSong? {
        guard let rid = rid, rid.range(of: "^[0-9]{1,15}$", options: .regularExpression) != nil else { return nil }
        do {
            let r = try Http.get("http://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=\(rid)&httpsStatus=1", ua: UA, referer: "http://www.kuwo.cn/", timeoutMs: 14000)
            if !r.ok { return nil }
            guard let data = r.text.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = obj["data"] as? [String: Any],
                  let si = d["songinfo"] as? [String: Any] else { return nil }
            var s = MRSong()
            s.id = rid
            s.name = si["songName"] as? String ?? ""
            s.artist = si["artist"] as? String ?? ""
            s.album = si["album"] as? String ?? ""
            s.pic = si["pic"] as? String ?? ""
            s.dur = num(si["duration"])
            return s
        } catch { return nil }
    }

    public static func bad(_ name: String?) -> Bool {
        guard let name = name else { return false }
        let ns = name as NSString
        return badRegex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) != nil
    }

    static func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0 }
        return 0
    }

    static func mmss(_ sec: Double) -> String {
        let s = max(0, sec)
        let m = Int(s) / 60
        let r = s - Double(m * 60)
        return String(format: "%02d:%05.2f", m, r)
    }
}
