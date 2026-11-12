import Foundation
import Combine

/// 已下载列表的「行为数据」读取状态（ViewModel）：数据由播放页写入 `EpisodeActionsStore`，
/// 本页只读不写。身份解析与播放侧共用 `identity(for:)`，保证「从哪读、写回哪」是同一条记录。
/// 进度是播放页落的，列表自身感知不到变化，刷新时机由调用方给：
/// 进入页面、任务数变化、播放入口（sheet / fullScreenCover）关闭。
/// 主线程约定：状态只在主线程访问（GCD 版，无线程标注）。
final class PlaybackProgressViewModel: ObservableObject {
    /// 本批条目的行为数据：按身份索引（命不中的条目不在表里 = 从未播过、未点赞）
    @Published private(set) var actionsByIdentity: [MediaIdentity: EpisodeActionsStore.Actions] = [:]

    /// 剧名 → 剧身份缓存：同剧只反查一次库；loadedNames 记录「查过的」以免反复查不存在的剧
    private var seriesCache: [String: DramaCache.SeriesIdentity] = [:]
    private var loadedNames = Set<String>()

    /// 重新读取这批已完成条目的行为数据：id 表按剧一次读全，本地表一次读全量
    func refresh(_ tasks: [DownloadTask]) {
        var identities = Set<MediaIdentity>()
        for task in tasks where task.state == .done {
            identities.insert(identity(for: task))
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
        actionsByIdentity = next
        print("PLAYER_DBG [Feed] actionsRefresh identities=\(identities.count) loaded=\(next.count) localRows=\(locals.count)")
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
