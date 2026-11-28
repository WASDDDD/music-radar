import Foundation
import ActivityKit

/// 管理"正在播放"的 Live Activity（灵动岛 + 锁屏）。
/// 播放开始时创建，播放状态/进度变化时更新，停止/清空时结束。
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<MusicRadarAttributes>?
    private var lastSig = ""
    private var lastUpdate = Date.distantPast

    /// 由 ViewController 的 nowPlaying 回调驱动。
    func update(title: String, artist: String, playing: Bool, duration: Double, elapsed: Double) {
        let state = MusicRadarAttributes.ContentState(
            title: title,
            artist: artist,
            playing: playing,
            elapsed: max(0, elapsed),
            duration: max(0, duration),
            updatedAt: Date()
        )

        let sig = "\(title)|\(artist)|\(playing)|\(Int(duration))"

        if let act = activity, act.activityState == .active {
            // 同一首歌且进度变化不大时跳过，避免过高频更新被系统限流。
            if sig == lastSig && Date().timeIntervalSince(lastUpdate) < 2.5 { return }
            lastSig = sig
            lastUpdate = Date()
            Task { try? await act.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }

        let attrs = MusicRadarAttributes(name: "MusicRadar")
        activity = try? Activity.request(
            attributes: attrs,
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
        lastSig = sig
        lastUpdate = Date()
    }

    /// 结束全部实时活动（当前 + 可能残留的）。
    func end() {
        lastSig = ""
        lastUpdate = .distantPast
        if let act = activity {
            activity = nil
            Task { await act.end(nil, dismissalPolicy: .immediate) }
        } else {
            for a in Activity<MusicRadarAttributes>.activities {
                Task { await a.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }
}
