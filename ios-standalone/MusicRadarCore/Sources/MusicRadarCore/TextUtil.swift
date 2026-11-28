import Foundation

public enum TextUtil {
    private static let punct = CharacterSet(charactersIn: " \t\n\r·.,，。!?！？、_-")

    public static func toSimp(_ s: String?) -> String {
        guard let s = s, !s.isEmpty else { return "" }
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, "Hant-Hans" as CFString, false)
        return m as String
    }

    public static func normalize(_ s: String?) -> String {
        guard let s = s else { return "" }
        let folded = s.folding(options: [.widthInsensitive, .caseInsensitive], locale: nil).lowercased()
        let scalars = folded.unicodeScalars.filter { !punct.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    public static func fold(_ s: String?) -> String {
        guard let s = s else { return "" }
        var t = s
        if let re = try? NSRegularExpression(pattern: "[\\(（\\[【].*?[\\)）\\]】]", options: []) {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        let all = CharacterSet(charactersIn: "()（）[]【】")
        return String(String.UnicodeScalarView(t.unicodeScalars.filter { !all.contains($0) })).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func looseName(_ a: String?, _ b: String?) -> Bool {
        let x = normalize(fold(toSimp(a))), y = normalize(fold(toSimp(b)))
        if x.isEmpty || y.isEmpty { return false }
        return x == y || x.contains(y) || y.contains(x)
    }

    public static func artistSet(_ s: String?) -> String {
        guard let s = s else { return "" }
        let parts = s.components(separatedBy: CharacterSet(charactersIn: "/、&,，"))
        var seen = Set<String>(), list: [String] = []
        for p in parts {
            let v = normalize(fold(toSimp(p)))
            if !v.isEmpty && !seen.contains(v) { seen.insert(v); list.append(v) }
        }
        return list.sorted().joined(separator: "|")
    }

    public static func firstTok(_ artist: String?) -> String {
        let a = artistSet(artist)
        return a.components(separatedBy: "|").first ?? a
    }

    public static func canonKey(_ name: String?, _ artist: String?) -> String {
        normalize(fold(toSimp(name))) + "::" + artistSet(artist)
    }
}
