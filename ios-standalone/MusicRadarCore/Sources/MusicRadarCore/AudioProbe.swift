import Foundation
import AVFoundation

public enum AudioProbe {
    public struct Result {
        public var duration: Double = 0
        public var codec = "unknown"
        public var hasAudio = false
        public var fullDecoded = false
        public var tailDecoded = false
        public var mime = "audio/mpeg"
        public init() {}
    }

    public static func probe(_ url: URL) -> Result {
        var r = Result()
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let sem = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) { sem.signal() }
        if sem.wait(timeout: .now() + 15) == .timedOut { return r }
        var err: NSError?
        let ds = asset.statusOfValue(forKey: "duration", error: &err)
        let ts = asset.statusOfValue(forKey: "tracks", error: &err)
        guard ds == .loaded, ts == .loaded else { return r }
        let seconds = CMTimeGetSeconds(asset.duration)
        r.duration = seconds.isFinite && seconds > 0 ? seconds : 0
        let tracks = asset.tracks(withMediaType: .audio)
        guard let track = tracks.first else { return r }
        r.hasAudio = true
        let ext = url.pathExtension.lowercased()
        if ext == "m4a" || ext == "aac" || ext == "mp4" {
            r.mime = "audio/mp4"
            r.codec = "aac"
        } else if ext == "flac" {
            r.mime = "audio/flac"
            r.codec = "flac"
        } else {
            r.mime = "audio/mpeg"
            r.codec = "mp3"
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsNonInterleaved: false
        ]
        r.fullDecoded = decode(asset: asset, track: track, settings: settings, range: nil)
        if r.duration > 0 {
            let start = max(0, r.duration - 8)
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                    duration: CMTime(seconds: 5, preferredTimescale: 600))
            r.tailDecoded = decode(asset: asset, track: track, settings: settings, range: range)
        }
        return r
    }

    private static func decode(asset: AVAsset, track: AVAssetTrack, settings: [String: Any], range: CMTimeRange?) -> Bool {
        do {
            let reader = try AVAssetReader(asset: asset)
            if let range = range { reader.timeRange = range }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return false }
            reader.add(output)
            guard reader.startReading() else { return false }
            var count = 0
            while reader.status == .reading {
                if output.copyNextSampleBuffer() == nil { break }
                count += 1
                if count > 2_000_000 { break }
            }
            return count > 0 && reader.status == .completed
        } catch { return false }
    }

    /// 根据文件头判断真实容器；用于给缓存文件选正确扩展名（AVFoundation 依赖扩展名嗅探）。
    public static func fileExtension(for data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 12 else { return "mp3" }
        if b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33 { return "mp3" }
        if b[0] == 0xFF && (b[1] & 0xE0) == 0xE0 { return "mp3" }
        if b[0] == 0x66 && b[1] == 0x4C && b[2] == 0x61 && b[3] == 0x43 { return "flac" }
        if b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 { return "m4a" }
        if b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53 { return "ogg" }
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 { return "wav" }
        return "mp3"
    }

    public static func looksLikeAudio(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 12 else { return false }
        if b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33 { return true }
        if b[0] == 0xFF && (b[1] & 0xE0) == 0xE0 { return true }
        if b[0] == 0x66 && b[1] == 0x4C && b[2] == 0x61 && b[3] == 0x43 { return true }
        if b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 { return true }
        if b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53 { return true }
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 { return true }
        return false
    }
}
