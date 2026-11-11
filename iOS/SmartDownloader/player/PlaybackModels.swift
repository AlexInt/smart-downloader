import Foundation

// MARK: - 播放资源模型（纯数据，无行为）

/// 上下滑动播放的一个资源槽位。playlistURL 为 nil 表示该集真实存在但尚未下载。
struct PlayableEpisode: Identifiable, Equatable {
    let sort: Int
    let playlistURL: URL?
    var id: String { "\(sort)" }
    var isAvailable: Bool { playlistURL != nil }
}

/// 拉起沉浸式播放页的请求。
/// knownSorts = 调用方已经掌握的全剧集号（剧集页直接持有 info.episodes）；
/// 为空时由 service 反查本地缓存，再退化为「真实已下载的集」。全程不凭空造集号。
struct ImmersivePlaybackRequest: Identifiable {
    let id = UUID()
    let seriesName: String
    let intro: String?
    let startSort: Int
    var knownSorts: [Int] = []
}

/// 滑动方向
enum PlaybackDirection {
    case next
    case previous
}
