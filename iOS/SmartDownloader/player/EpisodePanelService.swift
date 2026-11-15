import Foundation

// MARK: - 选集面板数据服务
//
// 面板的集号只有一个来源：播放队列槽位（`PlaybackQueueService.slots` 的 sort 就是真实集号）。
// 本服务只做两件事：
//   1. 把「槽位 + 磁盘 + 下载任务 + 剧集缓存」拼成每一格的状态（`EpisodePanelItem`）；
//   2. 把「点了未下载的格」变成一次真实的单集下载请求（复用 SeriesDownloadCoordinator）。
//
// 判据（Service）：不 import SwiftUI、不用 @Published、不反向依赖 ViewModel——
// 删掉播放页 UI 后这套逻辑仍然成立。
// 主线程约定：只在主线程访问（GCD 版，无线程标注）。

final class EpisodePanelService {

    /// 单集下载请求的结果：VM 据此拼提示文案（Service 不碰 UI 文案）。
    enum DownloadRequestResult: Equatable {
        case queued(Int)
        case alreadyQueued(Int)
        case notPlayable(Int)
        case missingMetadata
        case missingTarget
    }

    /// 剧集缓存（同一 target 只查一次库；播放页生命周期内剧集元数据不会变）
    private var cachedKey: String?
    private var cachedEntry: DramaCache.Entry?
    /// 站点会话（每集下载前仍会重调接口取新鲜直链，会话只承载登录态与常量）
    private var session: DramaSession?
    private var sessionTarget: DramaTarget?

    // MARK: - 格子数据装配

    /// 按队列槽位顺序生成面板格子。**槽位即真实集号，不按 1…total 编号**：
    /// 只下了第 10~12 集或挑了第 3、7 集时，面板显示的就是这些集号。
    func items(slots: [PlayableEpisode], seriesName: String, target: DramaTarget?,
               manager: DownloadManager?) -> [EpisodePanelItem] {
        let entry = loadEntry(seriesName: seriesName, target: target)
        var playableBySort: [Int: Bool] = [:]
        for episode in entry?.episodes ?? [] { playableBySort[episode.sort] = episode.playable }
        let items = slots.map { slot in
            EpisodePanelItem(
                sort: slot.sort,
                phase: phase(sort: slot.sort, available: slot.isAvailable,
                             seriesName: seriesName, manager: manager),
                playable: playableBySort[slot.sort] ?? true
            )
        }
        print("PLAYER_DBG [Service] panelItems series=\(seriesName) cells=\(items.count) "
              + "sorts=\(items.map(\.sort)) "
              + "downloaded=\(items.filter(\.isDownloaded).map(\.sort)) "
              + "playable=\(items.filter(\.playable).count) cachedPlayable=\(playableBySort.count)")
        return items
    }

    /// 单集下载阶段：磁盘是「已完成」的账本，进行中状态取自 DownloadTask 的
    /// state / current / total（与 `DramaPageViewModel.downloadPhase` 同一口径）。
    func phase(sort: Int, available: Bool, seriesName: String,
               manager: DownloadManager?) -> EpisodeDownloadPhase {
        if available { return .done }
        guard let manager else { return .idle }
        let title = String(format: "第%02d集", sort)
        // tasks 头插：first 即该集最新任务（重试时旧的失败任务排后面）
        guard let task = manager.tasks.first(where: {
            $0.seriesName == seriesName && $0.title == title
        }) else { return .idle }
        switch task.state {
        case .done:
            return .done
        case .failed(let message):
            return .failed(message)
        case .waiting:
            return .queued
        case .parsing, .saving:
            return .active(0.03)   // 解析/保存阶段还没切片进度，给一点可见起点
        case .downloading:
            let ratio = task.total > 0 ? Double(task.current) / Double(task.total) : 0.03
            return .active(min(max(ratio, 0.03), 0.99))
        }
    }

    // MARK: - 单集下载

    /// 点「未下载的格」→ 真正入队一集（最多 2 集并行、每集下载前重取直链，全走既有调度）。
    /// 站点未开放 / 缺元数据都如实返回，让 VM 给提示，不静默吞掉。
    func requestDownload(sort: Int, seriesName: String, target: DramaTarget?,
                         manager: DownloadManager) -> DownloadRequestResult {
        if manager.queuedEpisodeSorts(forSeries: seriesName).contains(sort) {
            print("PLAYER_DBG [CHECK] panelDownload SKIP reason=alreadyQueued sort=\(sort)")
            return .alreadyQueued(sort)
        }
        guard let resolved = resolveTarget(seriesName: seriesName, target: target) else {
            print("PLAYER_DBG [CHECK] panelDownload MISS reason=noTarget sort=\(sort) series=\(seriesName)")
            return .missingTarget
        }
        guard let episode = loadEntry(seriesName: seriesName, target: resolved)?
            .episodes.first(where: { $0.sort == sort }) else {
            print("PLAYER_DBG [CHECK] panelDownload MISS reason=noEpisode sort=\(sort) "
                  + "site=\(resolved.site)#\(resolved.dramaID)")
            return .missingMetadata
        }
        guard episode.playable else {
            print("PLAYER_DBG [CHECK] panelDownload REFUSE reason=notPlayable sort=\(sort) id=\(episode.id)")
            return .notPlayable(sort)
        }
        let session: DramaSession
        if let existing = self.session, sessionTarget == resolved {
            session = existing
        } else {
            session = DramaSession(target: resolved)
            self.session = session
            sessionTarget = resolved
        }
        SeriesDownloadCoordinator.start(target: resolved, seriesName: seriesName,
                                        episodes: [episode], manager: manager, session: session)
        print("PLAYER_DBG [CHECK] panelDownload queued sort=\(sort) "
              + "site=\(resolved.site)#\(resolved.dramaID) id=\(episode.id)")
        return .queued(sort)
    }

    // MARK: - 剧集缓存 / 站点身份

    /// 站点身份：请求里带的 target 优先，没有才按剧名反查（下载页入口只有剧名）
    private func resolveTarget(seriesName: String, target: DramaTarget?) -> DramaTarget? {
        if let target { return target }
        guard let identity = DramaCache.seriesIdentity(forSeriesName: seriesName) else { return nil }
        return DramaTarget(site: identity.site, dramaID: identity.dramaID)
    }

    /// 剧集缓存（含每集 id / playable）：同一 target 只查一次库
    private func loadEntry(seriesName: String, target: DramaTarget?) -> DramaCache.Entry? {
        let key = target?.id ?? "name:\(seriesName)"
        if cachedKey == key { return cachedEntry }
        var entry: DramaCache.Entry?
        if let target {
            entry = DramaCache.load(site: target.site, dramaID: target.dramaID)
        }
        if entry == nil, let identity = DramaCache.seriesIdentity(forSeriesName: seriesName) {
            entry = DramaCache.load(site: identity.site, dramaID: identity.dramaID)
        }
        cachedKey = key
        cachedEntry = entry
        print("PLAYER_DBG [Service] panelEntry key=\(key) episodes=\(entry?.episodes.count ?? 0) "
              + "playable=\(entry?.episodes.filter(\.playable).count ?? 0)")
        return entry
    }
}
