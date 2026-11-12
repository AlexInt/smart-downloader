import AVFoundation

/// 播放器生命周期 Service：持有唯一常驻的 AVPlayer，负责 item 准备与释放。
/// 依据 ZFPlayer / 开源抖音实践：切集只换 item，绝不在滑动时新建 AVPlayer。
///
/// 相邻集预热池（秒开的关键）：停稳播当前集时，提前为相邻集完成
/// 回环 URL 解析 + m3u8 拉取解析（`asset.load(.isPlayable)`，资产加载 async 岛）；
/// 用户滑过去时 makeItem 直接命中预热资产构建 item，跳过整条清单加载管线。
/// 主线程约定：本类全部状态只在主线程访问（GCD 版，无线程标注）
final class PlaybackPlayerService {
    let player = AVPlayer()

    /// 预热完成的资产：集号 → 已解析过播放清单的 AVURLAsset
    private var preloadedAssets: [Int: AVURLAsset] = [:]
    /// 正在预热的集号（在飞标记）：淘汰/teardown 时移除，回调落地发现已移除即丢弃资产
    ///（asset.load 不响应中途取消，与旧 Task.cancel + isCancelled 语义一致）
    private var preloadingSorts: Set<Int> = []

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
    }

    /// 本地 HLS 回环地址 → AVPlayerItem；未下载或本地服务未启动时回调 nil。
    /// 命中预热池 → 用已解析过清单的资产直接构建 item（秒开路径）。
    /// completion 统一在主线程回调（HIT 路径同步落地，也走 completion）。
    func makeItem(for episode: PlayableEpisode, completion: @escaping (AVPlayerItem?) -> Void) {
        guard let playlist = episode.playlistURL else {
            print("PLAYER_DBG [Service] makeItem FAIL reason=noLocalPlaylist sort=\(episode.sort)")
            completion(nil)
            return
        }
        if let asset = preloadedAssets.removeValue(forKey: episode.sort) {
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 1
            print("PLAYER_DBG [CHECK] makeItem HIT sort=\(episode.sort) pooled=\(preloadedAssets.count)")
            completion(item)
            return
        }
        LocalMediaServer.shared.playbackURL(forFolder: playlist.deletingLastPathComponent()) { url in
            guard url.scheme == "http" else {
                print("PLAYER_DBG [Service] makeItem FAIL reason=localServerNotReady sort=\(episode.sort) url=\(url.absoluteString)")
                completion(nil)
                return
            }
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 1
            print("PLAYER_DBG [Service] makeItem MISS sort=\(episode.sort) url=\(url.absoluteString)")
            completion(item)
        }
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

        // 淘汰在飞标记：迟到的预热回调发现标记没了就丢弃资产（等价旧 task.cancel）
        preloadingSorts.subtract(wantedSorts)
        let evictedAssets = preloadedAssets.keys.filter { !wantedSorts.contains($0) }
        for sort in evictedAssets {
            preloadedAssets[sort] = nil
            print("PLAYER_DBG [Service] preload EVICT sort=\(sort)")
        }

        guard !wanted.isEmpty else { return }
        for episode in wanted
        where preloadedAssets[episode.sort] == nil && !preloadingSorts.contains(episode.sort) {
            preloadingSorts.insert(episode.sort)
            preloadOne(episode)
        }
    }

    /// 只停播放器，保留预热池（例如停在一集未下载的占位页，相邻集仍可能滑回去）。
    func clear() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// 播放页整体退出时用：停播放器 + 清空预热池与在飞标记，不占用任何资源。
    func teardown() {
        clear()
        preloadingSorts.removeAll()
        let count = preloadedAssets.count
        preloadedAssets.removeAll()
        print("PLAYER_DBG [Service] teardown evictedAssets=\(count)")
    }

    // MARK: 私有

    private func preloadOne(_ episode: PlayableEpisode) {
        guard let playlist = episode.playlistURL else {
            preloadingSorts.remove(episode.sort)
            return
        }
        LocalMediaServer.shared.playbackURL(forFolder: playlist.deletingLastPathComponent()) { [weak self] url in
            guard let self else { return }
            guard url.scheme == "http" else {
                print("PLAYER_DBG [Service] preload FAIL reason=localServerNotReady sort=\(episode.sort)")
                self.preloadingSorts.remove(episode.sort)
                return
            }
            let asset = AVURLAsset(url: url)
            // 资产加载 async 岛（与 WebKitFetcher 同原则：Apple 非废弃的加载 API 只有 async load(_:)，
            // loadValuesAsynchronously 已 deprecated）：load(.isPlayable) 完成 m3u8 拉取解析——预热核心收益。
            // @MainActor Task：加载完成后回到主 actor 直接碰预热池状态，其余调度仍全 GCD。
            Task { @MainActor [weak self] in
                let result: Result<Void, Error>
                do {
                    _ = try await asset.load(.isPlayable)
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                // 在飞标记已被淘汰（teardown / 滑走）→ 丢弃，等价旧 Task.isCancelled 检查
                guard let self, self.preloadingSorts.contains(episode.sort) else { return }
                self.preloadingSorts.remove(episode.sort)
                switch result {
                case .success:
                    self.preloadedAssets[episode.sort] = asset
                    print("PLAYER_DBG [Service] preload OK sort=\(episode.sort)")
                case .failure(let error):
                    print("PLAYER_DBG [Service] preload FAIL reason=load sort=\(episode.sort) error=\(error.localizedDescription)")
                }
            }
        }
    }
}