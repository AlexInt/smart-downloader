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

/// 选集面板的一格（2026-11-15）。
/// 集号一律是**真实集号**（队列槽位的 sort），不是数组下标；
/// 下载态来自磁盘账本 + 下载任务，playable 来自剧集缓存——与剧集页选集区同一套口径：
/// 已下载 → 点即播；未下载且可播 → 点即下载；站点未开放 → 如实提示。
struct EpisodePanelItem: Identifiable, Equatable {
    let sort: Int
    var phase: EpisodeDownloadPhase
    /// 站点是否开放该集（剧集缓存缺失时为 true：让点击走「缺元数据」提示，而不是假灰）
    var playable: Bool
    var id: Int { sort }
    var isDownloaded: Bool {
        if case .done = phase { return true }
        return false
    }
}

/// 选集面板的一次完整快照：格子 + 一次性提示。
/// 提示显示在面板标题位置（竖屏弹层与全屏抽屉同一个位置），2.4s 后自动清空。
struct EpisodePanelState: Equatable {
    var items: [EpisodePanelItem] = []
    var hint: String? = nil
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

// MARK: - 清晰度标签（纯函数，无 IO）

/// 片源像素尺寸 → 全屏底栏的清晰度文案。
/// 口径：按**短边**（横屏片源的高、竖屏片源的宽）折算，因为「1080P / 720P」说的就是短边；
/// 2160 以上统一叫「4K」（行业惯例），其余如实给 `1080P` / `720P` / `540P` …
/// 未知尺寸给 "—"（页面在 isReady 之前不会进全屏，正常看不到这个兜底）。
enum VideoQualityLabel {
    static func text(for size: CGSize) -> String {
        let shortSide = min(size.width, size.height)
        guard shortSide > 0 else { return "—" }
        if shortSide >= 2000 { return "4K" }
        return "\(Int(shortSide.rounded()))P"
    }
}
