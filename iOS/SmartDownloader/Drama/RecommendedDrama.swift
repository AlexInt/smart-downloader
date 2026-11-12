import Foundation

// MARK: - 为你推荐卡片（Drama 域 Model，纯数据无 IO）

/// 一部推荐剧，来自 `drama_related` 快照（详情接口 `related_list`）。
/// Service（`DramaCache.relatedDramas`）只负责读库与保序，展示文案由 View 派生，
/// 这里不拼 UI 字符串、不 import SwiftUI（AGENTS.md Model 约定）。
struct RecommendedDrama: Identifiable, Equatable {
    let videoID: Int
    let title: String?
    let cover: String?
    let tags: [String]
    let playCount: Int
    let playCountText: String?
    let serializeStatusText: String?
    /// free / vip … 站点原值；只做展示判定，不参与下载权限裁决
    let contentAccessType: String?

    var id: Int { videoID }

    /// 接口没给标题时不编造剧名，用 id 兜底（与「集数绝不造槽位」同一口径）
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "剧集 \(videoID)"
    }

    /// 播放量文案优先用站点给的文本（如「16W」），没有才回落到原始数字
    var displayPlayCount: String {
        if let text = playCountText, !text.isEmpty { return text }
        return playCount > 0 ? "\(playCount)" : "—"
    }

    /// 封面左上角角标：连载状态优先，VIP 内容补在后面（两者都来自接口，不猜）
    var displayBadge: String? {
        let status = serializeStatusText.flatMap { $0.isEmpty ? nil : $0 }
        let isVIP = contentAccessType?.lowercased() == "vip"
        switch (status, isVIP) {
        case (let s?, true): return "\(s) · VIP"
        case (let s?, false): return s
        case (nil, true): return "VIP"
        case (nil, false): return nil
        }
    }
}
