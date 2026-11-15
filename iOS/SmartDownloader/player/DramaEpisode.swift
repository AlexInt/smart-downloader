import Foundation

/// 播放页数据模型。
///
/// 设计稿里有一批「短剧内容字段」（剧情字幕、话题标签、音轨署名），本项目的本地 HLS
/// 没有对应数据源。这些字段改为可选，nil 时视图不渲染该元素，避免用虚构剧情文案冒充真实内容。
/// 播放进度与时间由 DramaPlayerViewModel 从 AVPlayer 实时读取，模型里的 preview* 只服务 #Preview。
struct DramaEpisode {
    let account: String
    let title: String
    let caption: String?
    let tags: String?
    let audio: String?
    /// 字幕两行；本地 HLS 无字幕轨时为 nil（字幕条整块隐藏）
    let subtitleLines: (String, String)?
    let episodeIndex: Int
    let episodeTotal: Int

    /// 集数胶囊文案：紧凑数字格式（如 "4/11"）。正常/清屏模式统一使用，
    /// 清屏不隐藏胶囊（始终知道看到哪一集）。
    var compactEpisodeLabel: String {
        "\(episodeIndex)/\(episodeTotal)"
    }

    // 点赞/收藏的「数字」已按用户要求整块移除（2026-11-15）：本地片源没有服务端计数，
    // 早先按集号编的占位数值是假数据，留着只会让人以为是真实互动量。
    // 互动只记录**本地点赞/收藏状态**（EpisodeActionsStore 的 liked / saved 两列），
    // 列表与「我的」页的关系查询仍走那两列，不受影响。

    // 静态稿面值：仅供 #Preview，真实播放一律以 ViewModel 为准
    var previewCurrentTime: String? = nil
    var previewDuration: String? = nil
    var previewProgress: Double = 0
}

extension DramaEpisode {
    /// 由本地已下载剧集构造：剧名来自剧目录、简介/标签来自 DramaCache、集号来自磁盘目录名。
    /// 字幕为 nil —— 没有字幕轨就不占位；无真实标签时回落占位文案
    static func local(seriesName: String, intro: String?, tags: String?, index: Int, total: Int) -> DramaEpisode {
        let trimmed = intro?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DramaEpisode(
            account: "本地已下载",
            title: seriesName,
            caption: (trimmed?.isEmpty == false) ? trimmed : nil,
            tags: (tags?.isEmpty == false) ? tags : "离线播放 · 本地 HLS",
            audio: "原声",
            subtitleLines: nil,
            episodeIndex: index,
            episodeTotal: total
        )
    }
}

#if DEBUG
extension DramaEpisode {
    /// 仅用于 Xcode 预览，文案与设计稿一致；请勿用于线上。
    static let designPreview = DramaEpisode(
        account: "@DramaWave 官方",
        title: "亿万总裁的隐秘继承人",
        caption: "她为救家族嫁给了冷面总裁，他却不知她的身份……",
        tags: "#都市 #甜宠",
        audio: "原声 · DramaWave 剧场",
        subtitleLines: ("你从没告诉我，", "你就是那位总裁……"),
        episodeIndex: 5,
        episodeTotal: 68,
        previewCurrentTime: "00:42",
        previewDuration: "01:48",
        previewProgress: 112.0 / 290.0
    )
}
#endif
