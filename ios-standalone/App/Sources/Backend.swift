import Foundation
import MusicRadarCore

final class Backend {
    static let shared = Backend()
    private(set) var server: HTTPServer?
    private(set) var port: UInt16 = 0
    private var started = false

    private init() {}

    func start() throws -> UInt16 {
        if started { return port }
        let s = HTTPServer(port: 18772) { name in
            guard let url = Bundle.main.url(forResource: "index", withExtension: "html") else { return nil }
            return try? Data(contentsOf: url)
        }
        s.version = "3.0-ios"
        port = try s.start()
        server = s
        started = true
        return port
    }
}
