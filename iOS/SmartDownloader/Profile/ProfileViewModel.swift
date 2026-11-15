import Foundation
import SQLite3
import Combine

/// 「我的」页 ViewModel：聚合 SQLite 三张表的关系查询，产出封面墙数据。
/// View 只渲染；关系口径（历史/收藏/点赞/追更）在这里收口。
/// 主线程约定：全部状态只在主线程访问（与 DramaPageViewModel 一致）。
final class ProfileViewModel: ObservableObject {

    /// 封面墙一张卡：剧身份 + 展示字段 + 该分类的进度文案
    struct Item: Identifiable, Equatable {
        let id: String          // site#dramaID
        let target: DramaTarget
        let name: String
        let coverURL: URL?
        /// 主文案（画布「7集 / 127集」位）：按分类给不同口径
        let progress: String

        static func == (lhs: Item, rhs: Item) -> Bool { lhs.id == rhs.id }
    }

    /// 分类（画布 19:180：历史/收藏/追更/点赞）
    enum Category: String, CaseIterable {
        case history = "历史"
        case favorites = "收藏"
        case chasing = "追更"
        case liked = "点赞"
    }

    /// 观看状态筛选（画布 19:190 胶囊）
    enum WatchFilter: String, CaseIterable {
        case all = "全部"
        case finished = "已看完"
        case unfinished = "未看完"
    }

    @Published private(set) var items: [Item] = []
    @Published var category: Category = .history {
        didSet { reload() }
    }
    @Published var watchFilter: WatchFilter = .all {
        didSet { applyWatchFilter() }
    }

    /// 原始加载结果（全量），watchFilter 在其上二次过滤
    private var allItems: [Item] = []
    /// 剧名 → 是否已看完 的索引（已看完 = 下载集中最后一集 == 缓存总集数）
    private var finishedIndex: [String: Bool] = [:]

    /// 离开页面再回来要重读（收藏/点赞可能在详情页改过）
    func reload() {
        let raw: [Item] = switch category {
        case .history: historyItems()
        case .favorites: favoriteItems()
        case .chasing: chasingItems()
        case .liked: likedItems()
        }
        allItems = raw
        finishedIndex = Dictionary(uniqueKeysWithValues: raw.map { ($0.id, isFinished($0.target)) })
        applyWatchFilter()
    }

    // MARK: - 各分类的数据口径

    /// 历史：有播放进度的剧，按最近观看倒序。「x集 / 总集数」= 看过的最大集号 / 缓存总集数
    private func historyItems() -> [Item] {
        let watches = EpisodeActionsStore.watchedDramas()
        return watches.compactMap { watch in
            guard let entry = DramaCache.load(site: watch.site, dramaID: watch.dramaID),
                  let name = entry.name, let total = entry.episodes.map(\.sort).max() else { return nil }
            return Item(id: "\(watch.site)#\(watch.dramaID)",
                        target: DramaTarget(site: watch.site, dramaID: watch.dramaID),
                        name: name,
                        coverURL: coverURL(site: watch.site, dramaID: watch.dramaID),
                        progress: "\(watch.lastSort)集 / \(total)集")
        }
    }

    /// 收藏：drama_favorites 按收藏时间倒序。文案 = 缓存总集数（「127集」）
    private func favoriteItems() -> [Item] {
        DramaFavorites().favoriteDramas().compactMap { fav in
            guard let entry = DramaCache.load(site: fav.site, dramaID: fav.dramaID),
                  let name = entry.name else { return nil }
            let total = entry.episodes.map(\.sort).max() ?? 0
            return Item(id: "\(fav.site)#\(fav.dramaID)",
                        target: DramaTarget(site: fav.site, dramaID: fav.dramaID),
                        name: name,
                        coverURL: coverURL(site: fav.site, dramaID: fav.dramaID),
                        progress: total > 0 ? "\(total)集" : "")
        }
    }

    /// 追更：缓存里「连载中」的剧（update_status 非完结），按最近抓取倒序。
    /// 口径如实：追更意图目前只有站点的连载状态可依，用户自建的追更列表还不存在。
    private func chasingItems() -> [Item] {
        guard let db = DramaDatabase.open() else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = """
        SELECT site, drama_id, name, update_status, cover, fetched_at FROM drama_cache
        WHERE update_status IS NOT NULL AND update_status != ''
          AND update_status NOT LIKE '%完结%' AND update_status NOT LIKE '%全%'
        ORDER BY fetched_at DESC;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            DramaDatabase.fail(db, "chasing read"); return []
        }
        defer { sqlite3_finalize(stmt) }
        var result: [Item] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let site = DramaDatabase.text(stmt, 0) ?? ""
            let dramaID = DramaDatabase.text(stmt, 1) ?? ""
            let name = DramaDatabase.text(stmt, 2) ?? ""
            let status = DramaDatabase.text(stmt, 3) ?? ""
            let target = DramaTarget(site: site, dramaID: dramaID)
            result.append(Item(id: "\(site)#\(dramaID)",
                               target: target,
                               name: name,
                               coverURL: coverURL(site: site, dramaID: dramaID),
                               progress: status))
        }
        return result
    }

    /// 点赞：episode_actions 里点过赞的剧，按最近点赞倒序。文案 = 缓存总集数
    private func likedItems() -> [Item] {
        EpisodeActionsStore.likedDramas().compactMap { like in
            guard let entry = DramaCache.load(site: like.site, dramaID: like.dramaID),
                  let name = entry.name else { return nil }
            let total = entry.episodes.map(\.sort).max() ?? 0
            return Item(id: "\(like.site)#\(like.dramaID)",
                        target: DramaTarget(site: like.site, dramaID: like.dramaID),
                        name: name,
                        coverURL: coverURL(site: like.site, dramaID: like.dramaID),
                        progress: total > 0 ? "\(total)集" : "")
        }
    }

    // MARK: - 观看状态过滤

    /// 已看完 = 剧的最后一集已下载（sort 最大集 downloaded=1）。
    /// 没下载任何集但看过结尾的情形这里判不了，如实归入「未看完」。
    private func isFinished(_ target: DramaTarget) -> Bool {
        guard let entry = DramaCache.load(site: target.site, dramaID: target.dramaID),
              let lastSort = entry.episodes.map(\.sort).max(),
              let last = entry.episodes.first(where: { $0.sort == lastSort }) else { return false }
        return last.downloaded
    }

    private func applyWatchFilter() {
        guard watchFilter != .all else {
            items = allItems
            return
        }
        let wantFinished = watchFilter == .finished
        items = allItems.filter { (finishedIndex[$0.id] ?? false) == wantFinished }
    }

    // MARK: - 封面

    /// 封面展示路径：本地缓存（≤15 天）优先，远程 URL 兜底（与 DramaPageViewModel 同口径）
    private func coverURL(site: String, dramaID: String) -> URL? {
        if let local = DramaCoverCache.validLocalURL(site: site, dramaID: dramaID) {
            return local
        }
        guard let entry = DramaCache.load(site: site, dramaID: dramaID),
              let remote = entry.cover, !remote.isEmpty else { return nil }
        return URL(string: remote)
    }

    // MARK: - 空态文案

    var emptyMessage: String {
        switch category {
        case .history: return "还没有观看记录"
        case .favorites: return "还没有收藏的剧"
        case .chasing: return "没有连载中的剧"
        case .liked: return "还没有点赞过的剧"
        }
    }

    /// 封面墙卡片统计行的状态文案（与分类 tab 同源，只做如实展示，不猜）
    var statusText: String {
        switch category {
        case .history: return "观看中"
        case .favorites: return "已收藏"
        case .chasing: return "连载中"
        case .liked: return "已点赞"
        }
    }
}
