import XCTest
@testable import MusicRadarCore

final class ServerTests: XCTestCase {
    private func get(_ url: String) -> (Int, Data) {
        let sem = DispatchSemaphore(value: 0)
        var code = -1
        var body = Data()
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = 10
        let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
            code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            body = data ?? Data()
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 12)
        return (code, body)
    }

    func testHTTPServerHealthAndPage() throws {
        let server = HTTPServer(port: 18991) { name in
            name == "index.html" ? Data("<html>ok</html>".utf8) : nil
        }
        let port = try server.start()
        defer { server.stop() }
        let (hc, hb) = get("http://127.0.0.1:\(port)/api/health")
        XCTAssertEqual(hc, 200)
        let obj = try JSONSerialization.jsonObject(with: hb) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        XCTAssertEqual(obj?["offline"] as? Bool, true)
        let (pc, pb) = get("http://127.0.0.1:\(port)/index.html")
        XCTAssertEqual(pc, 200)
        XCTAssertEqual(String(data: pb, encoding: .utf8), "<html>ok</html>")
    }
}
