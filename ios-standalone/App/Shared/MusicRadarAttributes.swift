import Foundation
import ActivityKit

/// 灵动岛 / 锁屏实时活动（Live Activity）共享模型。
/// 同时被 App 目标与 MusicRadarWidget 扩展目标编译，保证两端类型一致。
struct MusicRadarAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var playing: Bool
        var elapsed: Double   // 秒
        var duration: Double  // 秒
        var updatedAt: Date
    }

    /// 静态属性（活动生命周期内不变）。
    var name: String
}
