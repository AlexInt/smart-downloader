import AVFoundation

/// 播放器生命周期 Service：持有唯一常驻的 AVPlayer，负责 item 准备与释放。
/// 依据 ZFPlayer / 开源抖音实践：切集只换 item，绝不在滑动时新建 AVPlayer。
///
/// 相邻集预热池（秒开的关键）：停稳播当前集时，提前为相邻集完成
/// 回环 URL 解析 + m3u8 拉取解析（`asset.load(.isPlayable)`）；
/// 用户滑过去时 makeItem 直接命中预热资产构建 item，跳过整条清单加载管线。
@MainActor
final class PlaybackPlayerService {
    let player = AVPlayer()

    /// 预热完成的资产：集号 → 已解析过播放清单的 AVURLAsset
    private var preloadedAssets: [Int: AVURLAsset] = [:]
    /// 进行中的预热任务
    private var preloadTasks: [Int: Task<Void, Never>] = [:]

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
    }

    /// 本地 HLS 回环地址 → AVPlayerItem；未下载或本地服务未启动时返回 nil。
    /// 命中预热池 → 用已解析过清单的资产直接构建 item（秒开路径）。
    func makeItem(for episode: PlayableEpisode) async -> AVPlayerItem? {
        guard let playlist = episode.playlistURL else {
            print("PLAYER_DBG [Service] makeItem FAIL reason=noLocalPlaylist sort=\(episode.sort)")
            return nil
        }
        if let asset = preloadedAssets.removeValue(forKey: episode.sort) {
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 1
            print("PLAYER_DBG [CHECK] makeItem HIT sort=\(episode.sort) pooled=\(preloadedAssets.count)")
            return item
        }
        let url = await LocalMediaServer.shared.playbackURL(
            forFolder: playlist.deletingLastPathComponent())
        guard url.scheme == "http" else {
            print("PLAYER_DBG [Service] makeItem FAIL reason=localServerNotReady sort=\(episode.sort) url=\(url.absoluteString)")
            return nil
        }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        print("PLAYER_DBG [Service] makeItem MISS sort=\(episode.sort) url=\(url.absoluteString)")
        return item
    }

    /// 预热一组集（调用方必须传「当前集 + 相邻集」：wanted 里没有当前集，
    /// 它尚未消费的预热资产就会被本轮淘汰掉 —— 曾因此池子全 MISS）。
    /// 只预热已下载的集；已在池里 / 正在预热的集不重复起任务；不在名单里的自动淘汰。
    /// 刚离开的集会作为新当前的邻居被重暖 —— 这是来回滑动（短剧常见）的回滑 HIT 保险，
    /// 代价只是一次回环 m3u8 解析；勿加「跳过正在播的集」过滤（曾因 playingSort
    /// 把刚离开的集剔除出 wanted，回滑必 MISS，已删）。
    func preload(_ episodes: [PlayableEpisode]) {
        let wanted = episodes.filter { $0.isAvailable }
        let wantedSorts = Set(wanted.map(\.sort))

        let evictedTasks = preloadTasks.filter { !wantedSorts.contains($0.key) }
        for (sort, task) in evictedTasks {
            task.cancel()
            preloadTasks[sort] = nil
        }
        let evictedAssets = preloadedAssets.keys.filter { !wantedSorts.contains($0) }
        for sort in evictedAssets {
            preloadedAssets[sort] = nil
            print("PLAYER_DBG [Service] preload EVICT sort=\(sort)")
        }

        guard !wanted.isEmpty else { return }
        for episode in wanted
        where preloadedAssets[episode.sort] == nil && preloadTasks[episode.sort] == nil {
            preloadTasks[episode.sort] = Task { [weak self] in
                await self?.preloadOne(episode)
            }
        }
    }

    /// 只停播放器，保留预热池（例如停在一集未下载的占位页，相邻集仍可能滑回去）。
    func clear() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// 播放页整体退出时用：停播放器 + 清空预热池与任务，不占用任何资源。
    func teardown() {
        clear()
        for (_, task) in preloadTasks { task.cancel() }
        preloadTasks.removeAll()
        let count = preloadedAssets.count
        preloadedAssets.removeAll()
        print("PLAYER_DBG [Service] teardown evictedAssets=\(count)")
    }

    // MARK: 私有

    private func preloadOne(_ episode: PlayableEpisode) async {
        defer { preloadTasks[episode.sort] = nil }
        guard let playlist = episode.playlistURL else { return }
        let url = await LocalMediaServer.shared.playbackURL(
            forFolder: playlist.deletingLastPathComponent())
        guard url.scheme == "http" else {
            print("PLAYER_DBG [Service] preload FAIL reason=localServerNotReady sort=\(episode.sort)")
            return
        }
        let asset = AVURLAsset(url: url)
        do {
            // .isPlayable 会完成 m3u8 的拉取与解析 —— 预热的核心收益
            _ = try await asset.load(.isPlayable)
        } catch {
            print("PLAYER_DBG [Service] preload FAIL reason=load sort=\(episode.sort) error=\(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled else { return }
        preloadedAssets[episode.sort] = asset
        print("PLAYER_DBG [Service] preload OK sort=\(episode.sort)")
    }
}
