import Foundation

// MARK: - 播放资源模型（纯数据，无行为）

/// 上下滑动播放的一个资源槽位。playlistURL 为 nil 表示该集真实存在但尚未下载。
struct PlayableEpisode: Identifiable, Equatable {
    let sort: Int
    let playlistURL: URL?
    /// 行为数据（进度/点赞/收藏）归属：队列服务构槽位时一次性解析好，
    /// 播放侧不再自己拼键，避免两处规则漂移
    let identity: MediaIdentity
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
    /// 话题标签（剧集页 DOM 收割；下载页入口无元数据时为 nil）
    var tags: String? = nil
    let startSort: Int
    var knownSorts: [Int] = []
    /// 剧集页入口带上的站点/剧 id（行为数据走 episode_id）；
    /// 下载页入口只有剧名，为 nil 时由队列服务按剧名反查
    var target: DramaTarget? = nil
}

/// 滑动方向
enum PlaybackDirection {
    case next
    case previous
}
