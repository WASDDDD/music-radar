import Foundation

public struct MRHttpResponse {
    public let code: Int
    public let body: Data
    public let contentType: String
    public var text: String { String(data: body, encoding: .utf8) ?? "" }
    public var ok: Bool { code >= 200 && code < 300 }
}

public struct MRSong {
    public var id = ""
    public var name = ""
    public var artist = ""
    public var album = ""
    public var pic = ""
    public var dur: Double = 0
}

public struct MRPlayMeta {
    public var source = ""
    public var id = ""
    public var name = ""
    public var artist = ""
    public var album = ""
    public var pic = ""
    public var expectedDuration: Double = 0
    public var url: String?
    public var urls: [String] = []
    public var unavailable = false
    public var reason = ""
    public var durationTolerance: Double = 0
    public var verifyTitle: String?
    public var verifyArtist: String?
    public var substituted = false
    public var headers: [String: String] = [:]
}

public struct MRPlaybackInput {
    public var source = ""
    public var id = ""
    public var name = ""
    public var artist = ""
}

public struct MRMediaFile {
    public let file: URL
    public let size: Int64
    public let mime: String
}

public struct MRPlaybackError: Error {
    public let message: String
    public let code: String
    public init(_ message: String, _ code: String) {
        self.message = message
        self.code = code
    }
}
