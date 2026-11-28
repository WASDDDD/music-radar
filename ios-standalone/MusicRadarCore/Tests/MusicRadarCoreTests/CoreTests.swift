import XCTest
import AVFoundation
@testable import MusicRadarCore

final class CoreTests: XCTestCase {
    func testKuwoDESVector() {
        let q = "user=0&corp=kuwo&source=kwplayer_ar_5.1.0.0_B_jiakong_vh.apk&p2p=1&type=convert_url2&sig=0&format=mp3&rid=228908"
        let expected = "3HxQnWXTNdQ6RbicYxLOyHAu64fVpKoBz43BshH4RFaGBPBi+8dZdGuvz4Hu9TAfA75CH9prKR/wLP/IiYIvJoWxgCvU/gETNIqiGvqcuuscRcbgESVmpm7oNjCqzuWEIZJuWAS1Zw6vdYHlcEZ102pjSIhT5B3R"
        XCTAssertEqual(KuwoCrypto.shared.encryptQuery(q), expected)
    }

    func testTextUtils() {
        XCTAssertEqual(TextUtil.normalize("  晴天 (Live) "), "晴天(live)")
        XCTAssertEqual(TextUtil.canonKey("海屿你", "马也_Crabbit"), "海屿你::马也crabbit")
        XCTAssertTrue(TextUtil.looseName("春涧（空灵女声版）", "春涧"))
    }

    func testPlaylistNetease() throws {
        let page = try Playlist.readPage("netease", "3778678", 0)
        XCTAssertEqual(page["title"] as? String, "热歌榜")
        XCTAssertEqual((page["items"] as? [[String: Any]])?.count, 100)
        XCTAssertEqual(page["complete"] as? Bool, false)
        XCTAssertEqual(page["nextOffset"] as? Int, 100)
    }

    func testKuwoSearch() {
        let rows = Kuwo.search("晴天", "周杰伦", pagesize: 5, pn: 0)
        XCTAssertFalse(rows.isEmpty)
        guard let first = rows.first(where: { $0.name.contains("晴天") && $0.dur > 200 }) else {
            XCTFail("no 晴天"); return
        }
        XCTAssertEqual(first.id, "228908")
    }

    func testAudioProbeGeneratedWav() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mr-test-tone.wav")
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let sr = 44100
        for sec in 0..<15 {
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sr))!
            buf.frameLength = AVAudioFrameCount(sr)
            let p = buf.floatChannelData![0]
            for i in 0..<sr {
                p[i] = Float(sin(2.0 * Double.pi * 440.0 * Double(sec * sr + i) / Double(sr)) * 0.2)
            }
            try file.write(from: buf)
        }
        let r = AudioProbe.probe(url)
        XCTAssertTrue(r.hasAudio)
        XCTAssertEqual(r.duration, 15.0, accuracy: 0.25)
        XCTAssertTrue(r.fullDecoded)
        XCTAssertTrue(r.tailDecoded)
    }
}
