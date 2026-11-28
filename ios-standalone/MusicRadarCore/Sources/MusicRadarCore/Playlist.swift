import Foundation

public enum Playlist {
    static let meting = "https://api.qijieya.cn/meting/"
    static let pageSize = 100

    static func getJson(_ url: String, _ referer: String) throws -> [String: Any] {
        let r = try Http.get(url, ua: "Mozilla/5.0", referer: referer, timeoutMs: 18000)
        guard r.ok else { throw MRPlaybackError("平台接口 HTTP \(r.code)", "UPSTREAM") }
        guard let data = r.text.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MRPlaybackError("平台返回格式错误", "UPSTREAM")
        }
        return obj
    }

    static func link(_ server: String, _ type: String, _ id: String) -> String {
        meting + "?server=\(server)&type=\(type)&id=" + Http.urlEncode(id)
    }

    static func track(_ server: String, _ song: [String: Any]) throws -> [String: Any] {
        let id = server == "netease" ? str(song["id"]) : first(str(song["mid"]), str(song["songmid"]))
        if id.isEmpty { throw MRPlaybackError("平台返回曲目缺少 ID", "UPSTREAM") }
        var o: [String: Any] = [:]
        o["id"] = id
        let name = first(str(song["name"]), str(song["songname"]), str(song["title"]))
        o["name"] = name.isEmpty ? "未知曲目" : name
        var artists = song["ar"] as? [[String: Any]]
        if artists == nil { artists = song["artists"] as? [[String: Any]] }
        if artists == nil { artists = song["singer"] as? [[String: Any]] }
        o["artist"] = (artists ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
        o["url"] = link(server, "url", id)
        o["lrc"] = link(server, "lrc", id)
        var pic = ""
        if let album = (song["al"] as? [String: Any]) ?? (song["album"] as? [String: Any]) {
            pic = str(album["picUrl"])
            let mid = first(str(album["mid"]), str(song["albummid"]))
            if pic.isEmpty && !mid.isEmpty { pic = "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(mid).jpg" }
        }
        o["pic"] = pic
        return o
    }

    public static func readPage(_ server: String, _ id: String, _ offset: Int) throws -> [String: Any] {
        if server == "netease" {
            let body = try getJson("https://music.163.com/api/v6/playlist/detail?id=\(id)&n=100000&s=0", "https://music.163.com/")
            guard (body["code"] as? Int ?? -1) == 200,
                  let p = body["playlist"] as? [String: Any],
                  let trackIds = p["trackIds"] as? [[String: Any]] else {
                throw MRPlaybackError("网易云歌单不可读取，请检查是否公开", "UPSTREAM")
            }
            let total = p["trackCount"] as? Int ?? trackIds.count
            if total < 0 || trackIds.count != total {
                throw MRPlaybackError("网易云未返回完整曲目 ID，无法确认完整歌单", "UPSTREAM")
            }
            let end = min(trackIds.count, offset + pageSize)
            var ids: [String] = []
            if offset < end {
                for i in offset..<end {
                    let one = str(trackIds[i]["id"])
                    if !one.isEmpty { ids.append(one) }
                }
            }
            var songList = (p["tracks"] as? [[String: Any]]) ?? []
            let missing = ids.contains { want in
                !songList.contains { str($0["id"]) == want }
            }
            if missing {
                let c = "[" + ids.map { "{\"id\":\"\($0)\"}" }.joined(separator: ",") + "]"
                let idsArr = "[" + ids.map { "\"\($0)\"" }.joined(separator: ",") + "]"
                let detail = try getJson("https://music.163.com/api/v3/song/detail?c=" + Http.urlEncode(c) + "&ids=" + Http.urlEncode(idsArr),
                                         "https://music.163.com/")
                guard (detail["code"] as? Int ?? -1) == 200, let ds = detail["songs"] as? [[String: Any]] else {
                    throw MRPlaybackError("网易云曲目信息读取失败", "UPSTREAM")
                }
                songList = ds
            }
            var byId: [String: [String: Any]] = [:]
            for s in songList { byId[str(s["id"])] = s }
            var items: [[String: Any]] = []
            for one in ids {
                if let s = byId[one] {
                    items.append(try track(server, s))
                } else {
                    items.append(["id": one, "name": "暂不可用曲目 \(one)", "artist": "平台未返回曲目信息",
                                  "url": link(server, "url", one), "lrc": link(server, "lrc", one), "pic": ""])
                }
            }
            return ["title": p["name"] as? String ?? id, "total": total, "items": items,
                    "nextOffset": offset + ids.count, "complete": offset + ids.count >= total]
        }
        if server == "tencent" {
            let param: [String: Any] = ["disstid": Int64(id) ?? 0, "song_begin": offset, "song_num": pageSize, "onlysonglist": 1]
            let query: [String: Any] = [
                "comm": ["ct": 24, "cv": 0],
                "req_0": ["module": "music.srfDissInfo.aiDissInfo", "method": "uniform_get_Dissinfo", "param": param]
            ]
            let data = try JSONSerialization.data(withJSONObject: query)
            let text = String(data: data, encoding: .utf8) ?? "{}"
            let body = try getJson("https://u.y.qq.com/cgi-bin/musicu.fcg?data=" + Http.urlEncode(text), "https://y.qq.com/")
            guard (body["code"] as? Int ?? -1) == 0,
                  let r0 = body["req_0"] as? [String: Any], (r0["code"] as? Int ?? -1) == 0,
                  let d = r0["data"] as? [String: Any], (d["code"] as? Int ?? -1) == 0,
                  let songlist = d["songlist"] as? [[String: Any]] else {
                throw MRPlaybackError("QQ 歌单不可读取，请检查是否公开", "UPSTREAM")
            }
            let dirinfo = d["dirinfo"] as? [String: Any]
            let total = dirinfo?["songnum"] as? Int ?? (d["total_song_num"] as? Int ?? -1)
            if total < 0 { throw MRPlaybackError("QQ 未返回歌单总数，无法确认完整歌单", "UPSTREAM") }
            var items: [[String: Any]] = []
            for s in songlist { items.append(try track(server, s)) }
            return ["title": dirinfo?["title"] as? String ?? id, "total": total, "items": items,
                    "nextOffset": offset + items.count, "complete": offset + items.count >= total]
        }
        throw MRPlaybackError("无效的歌单参数", "PARAM")
    }

    static func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    static func first(_ vals: String...) -> String {
        for v in vals where !v.isEmpty { return v }
        return ""
    }
}
