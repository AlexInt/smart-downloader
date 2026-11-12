import Foundation

// MARK: - 剧集档案（Drama 域 Model，纯数据）

struct DramaArchiveRow: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { "\(label)#\(value)" }
}

struct DramaArchiveSection: Identifiable, Equatable {
    let title: String
    let rows: [DramaArchiveRow]
    var id: String { title }
}

/// 把详情接口整包（`api_detail` 解码回 `DramaDetailData`）派生成分组展示行。
/// 纯函数、无 IO：View 只负责渲染，不在 View 里判断「有没有这个字段」。
/// 口径与项目一致：nil / 空值一律如实显示「—」，0 就是 0，空数组写「无」，
/// 绝不编造「每集约 2 分钟」这类没有来源的文案。
enum DramaArchive {

    static func sections(from d: DramaDetailData?, fetchedAt: String?) -> [DramaArchiveSection] {
        guard let d else { return [] }
        var result: [DramaArchiveSection] = []

        func add(_ title: String, _ pairs: [(String, String?)]) {
            let rows = pairs.map { DramaArchiveRow(label: $0.0, value: text($0.1)) }
            guard !rows.isEmpty else { return }
            result.append(DramaArchiveSection(title: title, rows: rows))
        }

        add("数据表现", [
            ("剧集 ID", num(d.videoId)),
            ("详情标题", d.title),
            ("评分", num(d.score)),
            ("播放量", num(d.playCount)),
            ("播放量文案", d.playCountText),
            ("点赞", num(d.likeCount)),
            ("追剧", num(d.chaseCount)),
            ("收藏", num(d.collectCount)),
            ("评论", num(d.commentCount)),
            ("总集数", num(d.episodeCount)),
            ("连载状态码", num(d.serializeStatus)),
            ("连载状态", d.serializeStatusText)
        ])

        add("内容规格", [
            ("分辨率", d.resolution),
            ("画面宽", num(d.videoWidth)),
            ("画面高", num(d.videoHeight)),
            ("画面方向", d.videoOrientation),
            ("原创", num(d.original)),
            ("演员", list(d.actorList)),
            ("标签", list(d.tags)),
            ("简介", d.description),
            ("封面", d.cover),
            ("社交封面", d.socialCover)
        ])

        add("权限与付费", [
            ("内容权限类型", d.contentAccessType),
            ("金币价格", num(d.coinPrice)),
            ("服务端已收藏", yn(d.isCollected)),
            ("服务端已追剧", yn(d.isChased)),
            ("access · 内容类型", d.access?.contentType),
            ("access · 状态", d.access?.state),
            ("access · 可播", yn(d.access?.canPlay)),
            ("access · 可解锁", yn(d.access?.canUnlock)),
            ("access · 原因", d.access?.reason),
            ("access · 下一步", d.access?.nextAction),
            ("access · 试看集数", num(d.access?.trialEpisodeCount)),
            ("access · 金币价", num(d.access?.coinPrice)),
            ("access · 已购", yn(d.access?.isPurchased)),
            ("access · 有效期", num(d.access?.validUntil))
        ])

        add("角标状态", [
            ("热门角标", yn(d.showHotBadge)),
            ("新剧标记", yn(d.showNew)),
            ("完结标记", yn(d.showCompleted)),
            ("热门标记", yn(d.showHot)),
            ("新剧截止时间", num(d.newUntil)),
            ("badge · 文案", d.badge?.text),
            ("badge · 类型", d.badge?.type),
            ("badge · 过期时间", num(d.badge?.expiresAt)),
            ("badge · 服务器时间", num(d.badge?.serverTime)),
            ("App 角标", d.appBadge?.text),
            ("封面角标", d.coverBadge?.text)
        ])

        if let u = d.urge {
            add("催更", [
                ("剧集 ID", num(u.videoId)),
                ("催更日期", u.urgeDate),
                ("今日已催", yn(u.urgedToday)),
                ("催更已启用", yn(u.urgeEnabled)),
                ("当前可催", yn(u.canUrge)),
                ("催更总数", num(u.urgeCount))
            ])
        }

        // 服务端记的进度只存档展示：续播实际走本地 episode_actions（见数据库设计文档）
        add("服务端观看进度", [
            ("当前集 ID", num(d.currentEpisodeId)),
            ("续播集 ID", num(d.continueEpisodeId)),
            ("观看时长(秒)", num(d.playDuration))
        ])

        add("分享与链接", [
            ("分享链接", d.shareUrl),
            ("分享标题", d.shareTitle),
            ("分享封面", d.shareCover),
            ("SEO 标题", d.seo?.title),
            ("SEO 关键词", d.seo?.keywords),
            ("SEO robots", d.seo?.robots),
            ("OG 标题", d.seo?.ogTitle),
            ("OG 图片", d.seo?.ogImage)
        ])

        if let episodes = d.episodes, !episodes.isEmpty {
            let rows = episodes.map { ep -> DramaArchiveRow in
                let candidates: [String?] = [
                    ep.title,
                    ep.resolution.map { "分辨率 \($0)" },
                    ep.duration.map { "时长 \($0)s" },
                    ep.access?.state.map { "权限 \($0)" },
                    ep.access?.canPlay.map { "可播 \($0 ? "是" : "否")" },
                    ep.access?.isTrial.map { "试看 \($0 ? "是" : "否")" },
                    ep.isNew.map { "新集 \($0 ? "是" : "否")" }
                ]
                let parts = candidates.compactMap { $0 }
                return DramaArchiveRow(label: "第 \(ep.sort) 集 · \(ep.id)",
                                       value: parts.joined(separator: " · "))
            }
            result.append(DramaArchiveSection(title: "每集元数据", rows: rows))
        }

        add("本地记录", [
            ("缓存刷新时间", fetchedAt),
            ("推荐剧条数", num(d.relatedList?.count))
        ])

        return result
    }

    // MARK: 格式化（纯函数）

    private static func text(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }

    private static func num(_ value: Int?) -> String {
        value.map(String.init) ?? "—"
    }

    private static func num(_ value: Double?) -> String {
        value.map { String($0) } ?? "—"
    }

    private static func yn(_ value: Bool?) -> String {
        value.map { $0 ? "是" : "否" } ?? "—"
    }

    private static func list(_ value: [String]?) -> String {
        guard let value, !value.isEmpty else { return "无" }
        return value.joined(separator: " / ")
    }
}
