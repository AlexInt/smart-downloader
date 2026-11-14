import Foundation
import Combine

/// 已下载列表的「行为数据」读取状态（ViewModel）：数据由播放页写入 `EpisodeActionsStore`，
/// 本页只读不写。身份解析与播放侧共用 `identity(for:)`，保证「从哪读、写回哪」是同一条记录。
/// 进度是播放页落的，列表自身感知不到变化，刷新时机由调用方给：
/// 进入页面、任务数变化、播放入口（sheet / fullScreenCover）关闭。
/// 主线程约定：本类状态只在主线程访问；SQLite 批量读走专用后台串行队列
///（2026-11-14 主线程卡顿修复——identities=97 的刷新曾是主线程 65 次开库读 + 25 次剧身份
/// 查询，tab 切换 mainStall 200–609ms 的直接来源；现在主线程只做快照拷贝与结果发布）。
final class PlaybackProgressViewModel: ObservableObject {
    /// 本批条目的行为数据：按身份索引（命不中的条目不在表里 = 从未播过、未点赞）
    @Published private(set) var actionsByIdentity: [MediaIdentity: EpisodeActionsStore.Actions] = [:]

    /// 剧名 → 剧身份缓存：主线程状态。`identity(for:)` 在行渲染 / 点播时同步调用，靠它保持温热；
    /// 后台批量解析的结果回主线程并进来（后台不直接碰这里的可变状态）
    private var seriesCache: [String: DramaCache.SeriesIdentity] = [:]
    /// 查过的剧名（含查不到的）：同刷内与跨调用防反复 MISS 查询
    private var loadedNames = Set<String>()

    /// SQLite 批量读的专用后台串行队列：读结果统一回主线程发布
    private static let readQueue = DispatchQueue(label: "smartdownloader.progressRead", qos: .userInitiated)
    /// 代际令牌：快速连续 refresh 时，先返回的旧结果按代际丢弃
    private var refreshGeneration = 0

    /// 重新读取这批已完成条目的行为数据：id 表按剧一次读全，本地表一次读全量。
    /// 管线：主线程快照 → 后台逐剧解析身份 + 批量读 → 主线程并回缓存并发布。
    func refresh(_ tasks: [DownloadTask]) {
        let t0 = PERF.ms()
        refreshGeneration += 1
        let generation = refreshGeneration
        struct TaskSnap {
            let id: UUID
            let title: String
            let seriesName: String?
            let outputURL: URL?
        }
        let snapshot = tasks.filter { $0.state == .done }.map {
            TaskSnap(id: $0.id, title: $0.title, seriesName: $0.seriesName, outputURL: $0.outputURL)
        }
        Self.readQueue.async { [weak self] in
            // 局部剧身份缓存：本批内同名剧只查一次库。
            // 查过的名字记进 queriedNames（值字典不能存 nil——赋 nil 即删键，miss 无法占位）
            var localSeries: [String: DramaCache.SeriesIdentity] = [:]
            var queriedNames = Set<String>()
            func resolve(_ name: String) -> DramaCache.SeriesIdentity? {
                if queriedNames.contains(name) { return localSeries[name] }
                let found = DramaCache.seriesIdentity(forSeriesName: name)
                queriedNames.insert(name)
                if let found { localSeries[name] = found }
                return found
            }
            var identities = Set<MediaIdentity>()
            for item in snapshot {
                let series = item.seriesName.flatMap { resolve($0) }
                let sort = DownloadManager.episodeSort(fromFolderName: item.title) ?? 0
                identities.insert(EpisodeActionsStore.identity(
                    series: series, sort: sort, playlistURL: item.outputURL))
            }
            var next: [MediaIdentity: EpisodeActionsStore.Actions] = [:]
            var episodeBatch: [String: [Int: EpisodeActionsStore.Actions]] = [:]
            for identity in identities {
                guard case .episode(let site, let dramaID, let episodeID) = identity else { continue }
                let key = site + "#" + dramaID
                if episodeBatch[key] == nil {
                    episodeBatch[key] = EpisodeActionsStore.episodeActions(site: site, dramaID: dramaID)
                }
                if let value = episodeBatch[key]?[episodeID] { next[identity] = value }
            }
            let locals = EpisodeActionsStore.allLocalActions()
            for identity in identities {
                if case .localPath(let path) = identity, let value = locals[path] { next[identity] = value }
            }
            let identitiesCount = identities.count
            let loadedCount = next.count
            let localCount = locals.count
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard generation == self.refreshGeneration else {
                    print("PLAYER_DBG [Feed] actionsRefresh gen=\(generation) DROPPED reason=superseded ms=\(PERF.ms() - t0)")
                    return
                }
                // 解析结果并回主线程缓存：行渲染 identity(for:) 不再开库；
                // miss 也记进 loadedNames，防主线程同步路径反复查询
                for name in queriedNames {
                    if let series = localSeries[name] { self.seriesCache[name] = series }
                    self.loadedNames.insert(name)
                }
                self.actionsByIdentity = next
                print("PLAYER_DBG [Feed] actionsRefresh gen=\(generation) identities=\(identitiesCount) loaded=\(loadedCount) localRows=\(localCount) ms=\(PERF.ms() - t0) (bg)")
            }
        }
    }

    func actions(for task: DownloadTask) -> EpisodeActionsStore.Actions? {
        guard task.state == .done else { return nil }
        return actionsByIdentity[identity(for: task)]
    }

    /// 列表副行只用进度；点赞/收藏以后要上列表时直接从 `actions(for:)` 取
    func progress(for task: DownloadTask) -> PlaybackProgress? {
        actions(for: task)?.position
    }

    /// 播放侧身份：(剧名, 集号) 能反查到服务端集 id 就走 id 表，
    /// 查不到的（散装 HLS / 普通文件 / 该剧没进过缓存）走本地路径键
    func identity(for task: DownloadTask) -> MediaIdentity {
        EpisodeActionsStore.identity(
            series: task.seriesName.flatMap(seriesIdentity(named:)),
            sort: DownloadManager.episodeSort(fromFolderName: task.title) ?? 0,
            playlistURL: task.outputURL)
    }

    // MARK: 私有

    /// 剧名 → 剧身份（同剧只开一次库；同名多剧由 DramaCache 打 AMBIGUOUS 日志）
    private func seriesIdentity(named name: String) -> DramaCache.SeriesIdentity? {
        if let cached = seriesCache[name] { return cached }
        if loadedNames.contains(name) { return nil }
        loadedNames.insert(name)
        let found = DramaCache.seriesIdentity(forSeriesName: name)
        if let found { seriesCache[name] = found }
        return found
    }
}
