import Foundation

/// 资源文件的播放进度快照（纯数据，跨 player / Downloads 两域引用）。
/// 播放页写入 `EpisodeActionsStore` 的 position 两列，已下载列表读取展示「播到哪」。
/// total 为 0 表示时长尚未取到：此时 fraction 记 0、不判「看完」，避免把未知当进度。
struct PlaybackProgress: Equatable {
    var seconds: Double
    var total: Double

    var fraction: Double { total > 0 ? min(max(seconds / total, 0), 1) : 0 }

    /// 距片尾 5 秒内算看完：列表显示「已看完」，续播直接从头播
    var isFinished: Bool { total > 0 && seconds >= total - 5 }

    /// 列表副行文案：03:12 / 12:30
    var text: String {
        PlaybackProgress.timeText(seconds) + " / " + PlaybackProgress.timeText(total)
    }

    static func timeText(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value >= 3600 {
            return String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
