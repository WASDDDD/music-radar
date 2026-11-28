import SwiftUI
import WidgetKit
import ActivityKit

private let mrAccent = Color(red: 0.20, green: 0.84, blue: 0.55)
private let mrBg = Color(red: 0.035, green: 0.043, blue: 0.07)

/// 灵动岛 + 锁屏 实时活动配置。
struct MusicRadarLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MusicRadarAttributes.self) { context in
            LockRow(state: context.state)
                .padding(14)
                .activityBackgroundTint(mrBg)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ArtBadge(size: 46)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PlayBadge(playing: context.state.playing, size: 34)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title.isEmpty ? "音乐雷达" : context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.artist.isEmpty ? " " : context.state.artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    BarRow(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "music.note")
                    .foregroundColor(mrAccent)
            } compactTrailing: {
                Image(systemName: context.state.playing ? "waveform" : "pause.fill")
                    .foregroundColor(mrAccent)
            } minimal: {
                Image(systemName: context.state.playing ? "music.note" : "pause.fill")
                    .foregroundColor(mrAccent)
            }
        }
    }
}

private struct ArtBadge: View {
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LinearGradient(
                colors: [mrAccent.opacity(0.95), Color(red: 0.10, green: 0.45, blue: 0.85)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundColor(.white)
            )
    }
}

private struct PlayBadge: View {
    var playing: Bool
    var size: CGFloat
    var body: some View {
        Image(systemName: playing ? "pause.fill" : "play.fill")
            .font(.system(size: size * 0.6, weight: .semibold))
            .foregroundColor(mrAccent)
            .frame(width: size, height: size)
    }
}

private struct LockRow: View {
    let state: MusicRadarAttributes.ContentState
    var body: some View {
        HStack(spacing: 12) {
            ArtBadge(size: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title.isEmpty ? "音乐雷达" : state.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(state.artist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                BarRow(state: state)
            }
            PlayBadge(playing: state.playing, size: 40)
        }
    }
}

private struct BarRow: View {
    let state: MusicRadarAttributes.ContentState
    var body: some View {
        VStack(spacing: 4) {
            if state.playing && state.duration > 1 {
                ProgressView(timerInterval: startDate...endDate, countsDown: false)
                    .tint(mrAccent)
            } else {
                ProgressView(value: ratio)
                    .tint(mrAccent)
            }
            HStack {
                Text(fmt(state.elapsed))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(fmt(max(0, state.duration)))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var ratio: Double {
        state.duration > 0 ? min(1, max(0, state.elapsed / state.duration)) : 0
    }
    private var startDate: Date { state.updatedAt.addingTimeInterval(-state.elapsed) }
    private var endDate: Date { startDate.addingTimeInterval(max(1, state.duration)) }
    private func fmt(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

@main
struct MusicRadarWidgetBundle: WidgetBundle {
    var body: some Widget {
        MusicRadarLiveActivity()
    }
}
