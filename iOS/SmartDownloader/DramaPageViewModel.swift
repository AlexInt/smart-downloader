import Foundation
import Combine

/// 原生剧集页的 ViewModel（架构评估 P8 拆分）：
/// 剧集数据/下载状态/选择状态与全部编排（缓存优先加载、选集下载、播放入口）都在这里，
/// DramaNativePage 只渲染 + 转发用户意图。
@MainActor
final class DramaPageViewModel: ObservableObject {
    let target: DramaTarget
    private let manager: DownloadManager
    /// 缓存路径打开的页面没有 session：下载/刷新时现建（每集下载前仍会重调接口取新鲜直链）
    private var session: DramaSession?

    @Published private(set) var loading = true
    @Published private(set) var loadError: String?
    @Published private(set) var info: DramaInfo?
    @Published private(set) var downloadedSorts: Set<Int> = []
    /// 未下载集的勾选状态（集 id 维度）；只经 tapEpisode / selectAll / clearSelection 修改
    @Published private(set) var selected: Set<Int> = []
    /// 当前列表是否来自本地缓存（缓存优先，刷新按钮强制更新）
    @Published private(set) var fromCache = false
    /// 触发 .task(id:) 重载的版本号（重试按钮）
    @Published private(set) var reloadID = UUID()
    /// 头部元数据（缓存 + 后台收割）
    @Published private(set) var coverURL: URL?
    @Published private(set) var intro: String?
    /// 话题标签（DOM 收割，空格分隔；P7）
    @Published private(set) var tags: String?
    /// 已下载集点播的播放入口（View 据此 fullScreenCover；View 仅在 onClose 时置 nil）
    @Published var playbackRequest: ImmersivePlaybackRequest?

    init(target: DramaTarget, manager: DownloadManager) {
        self.target = target
        self.manager = manager
    }

    // MARK: - 派生状态

    /// 该剧仍在队列（等待/下载中）的集号。单一事实源是 manager.tasks，
    /// 用计算属性跟随状态变化，不另存状态，避免与队列状态不同步。
    var queuedSorts: Set<Int> {
        guard let info else { return [] }
        return manager.queuedEpisodeSorts(forSeries: info.name)
    }

    /// 可下载且未入队的集（已下载、排队中、付费锁定都排除）
    var selectableEpisodes: [ApiDramaEpisode] {
        guard let info else { return [] }
        let queued = queuedSorts
        return info.episodes.filter {
            $0.playable
                && !downloadedSorts.contains($0.sort)
                && !queued.contains($0.sort)
        }
    }

    /// 头部副标题（展示串派生）
    var headerSubtitle: String {
        guard let info else { return "" }
        let base = "\(fromCache ? "本地缓存 · " : "")共 \(info.episodes.count) 集 · 可下载 \(selectableEpisodes.count) 集"
        var text = downloadedSorts.isEmpty ? base : base + " · 已下载 \(downloadedSorts.count) 集"
        if !queuedSorts.isEmpty { text += " · 排队中 \(queuedSorts.count) 集" }
        return text
    }

    // MARK: - 用户意图

    /// 重试按钮：换 reload 版本号触发 .task(id:) 重新加载
    func reload() { reloadID = UUID() }

    /// ↻ 强制更新：走网络拉取并按集 ID 合并新集（保留下载标记）
    func refresh() async { await fetchAndCache() }

    func selectAll() { selected = Set(selectableEpisodes.map(\.id)) }
    func clearSelection() { selected.removeAll() }

    /// 格子点击意图：已下载 → 播放入口；排队中 → 忽略（不追加任务）；其余切换勾选
    func tapEpisode(_ ep: ApiDramaEpisode) {
        if downloadedSorts.contains(ep.sort) {
            makePlaybackRequest(for: ep)
        } else if queuedSorts.contains(ep.sort) {
            return                       // 已在队列，点击不再追加任务
        } else if selected.contains(ep.id) {
            selected.remove(ep.id)
        } else {
            selected.insert(ep.id)
        }
    }

    /// 提交下载所选：过滤选中集中已排队/已下载的集，立即清空选择防连点二次提交
    func startDownload() {
        guard let info else { return }
        // 缓存路径打开的页面没有 session：现建一个（每集下载前仍会重调接口取新鲜直链）
        let session = self.session ?? DramaSession(target: target)
        self.session = session
        let chosen = info.episodes
            .filter { selected.contains($0.id) && $0.playable
                && !downloadedSorts.contains($0.sort)
                && !queuedSorts.contains($0.sort) }
            .sorted { $0.sort < $1.sort }
        guard !chosen.isEmpty else {
            selected.removeAll()
            return
        }
        // 立即清空选择：连点「下载所选」不会二次提交同一批
        selected.removeAll()
        SeriesDownloadCoordinator.start(target: target, seriesName: info.name,
                                        episodes: chosen, manager: manager, session: session)
    }

    // MARK: - 加载编排

    func load() async {
        loading = true
        loadError = nil
        selected = []
        // 缓存优先：同一剧集第二次打开直接读本地，不发网络请求（刷新按钮强制更新）
        if let entry = DramaCache.load(site: target.site, dramaID: target.dramaID),
           let info = DramaInfo(entry: entry) {
            self.info = info
            fromCache = true
            await applyLibraryState(for: info)
            harvestIfNeeded()
            loading = false
            return
        }
        await fetchAndCache()
    }

    /// 缓存里已有的封面/简介/标签先上头部（无网络也能显示）
    func preloadHeaderFromCache() {
        if let entry = DramaCache.load(site: target.site, dramaID: target.dramaID) {
            if let cover = entry.cover, let url = URL(string: cover) { coverURL = url }
            if let introText = entry.intro, !introText.isEmpty { intro = introText }
            // 空串 = 采集失败，不是「已缓存」：归 nil 才能让 harvestIfNeeded 继续收割
            tags = entry.tags.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// 任一任务状态变化时重算已下载集（下载完成 → 格子即时变 ▶ 播放；仅内存重算，不每 tick 写库）
    func refreshDownloadedSorts() {
        guard let info else { return }
        downloadedSorts = Set(manager.downloadedEpisodeFolders(forSeries: info.name).keys)
    }

    private func fetchAndCache() async {
        loading = true
        loadError = nil
        let session = DramaSession(target: target)
        self.session = session
        do {
            let info = try await session.fetchInfo()
            self.info = info
            fromCache = false
            DramaCache.saveInfo(site: target.site, dramaID: target.dramaID, info: info)
            await applyLibraryState(for: info)
            harvestIfNeeded()
        } catch {
            // 有缓存时网络失败不白屏：回退缓存继续用
            if let entry = DramaCache.load(site: target.site, dramaID: target.dramaID),
               let info = DramaInfo(entry: entry) {
                self.info = info
                fromCache = true
                await applyLibraryState(for: info)
            } else {
                loadError = error.localizedDescription
            }
        }
        loading = false
    }

    private func applyLibraryState(for info: DramaInfo) async {
        // 先收编旧版散装下载（只搬不删），再算已下载集（磁盘为账本），并对账写回缓存
        manager.collectLegacyEpisodes(forSeries: info.name)
        manager.refreshLibrary()
        let folders = manager.downloadedEpisodeFolders(forSeries: info.name)
        downloadedSorts = Set(folders.keys)
        DramaCache.reconcileDownloaded(site: target.site, dramaID: target.dramaID, folders: folders)
    }

    /// 头部缺封面/简介/标签时：后台隐藏 webview 拉一次剧集页提取元数据（落库后头部即时更新）。
    /// tags 纳入触发条件是 P7 采集需要；空串视为缺失 —— 采集失败后可重试
    ///（DramaMetaHarvester.harvestedKeys 只在进程内去重，重进 App 会清空）
    private func harvestIfNeeded() {
        // 空串也算「没有 tags」：旧实现把 "" 写进缓存列，这里误判已缓存 → 永久跳过收割
        let hasTags = !(tags?.isEmpty ?? true)
        // -captureDramaMeta：请求拦截调查期强制收割补采样本（绕过头部缓存判定）
        let force = ProcessInfo.processInfo.arguments.contains("captureDramaMeta")
        guard force || coverURL == nil || intro == nil || !hasTags else {
            print("PLAYER_DBG [Entry] harvest SKIP reason=headerCached cover=\(coverURL != nil) intro=\(intro != nil) tags=\(hasTags)")
            return
        }
        print("PLAYER_DBG [Entry] harvest trigger reason=\(force ? "forcedCapture" : "headerMissing") cover=\(coverURL != nil) intro=\(intro != nil) tags=\(hasTags)")
        Task {
            await DramaMetaHarvester.harvest(target: target)
            if let entry = DramaCache.load(site: target.site, dramaID: target.dramaID) {
                if let cover = entry.cover, let url = URL(string: cover) { coverURL = url }
                if let introText = entry.intro, !introText.isEmpty { intro = introText }
                tags = entry.tags.flatMap { $0.isEmpty ? nil : $0 }
            }
        }
    }

    /// 已下载集：拉起沉浸式竖屏播放页。全剧集数同步与滑动调度交给 PlaybackQueueService。
    /// 简介取自本地 SQLite 缓存（离线可用），不额外发网络请求。
    private func makePlaybackRequest(for ep: ApiDramaEpisode) {
        guard let info else {
            print("PLAYER_DBG [Entry] playDownloaded ABORT reason=infoNil ep=\(ep.sort)")
            return
        }
        let intro = DramaCache.load(site: target.site, dramaID: target.dramaID)?.intro
        print("PLAYER_DBG [Entry] playDownloaded ep=\(ep.sort) series=\(info.name) knownSorts=\(info.episodes.count) site=\(target.site) dramaID=\(target.dramaID) intro=\(intro == nil ? "nil" : "yes")")
        playbackRequest = ImmersivePlaybackRequest(
            seriesName: info.name,
            intro: intro,
            tags: tags,
            startSort: ep.sort,
            knownSorts: info.episodes.map(\.sort)   // 剧集页已持有全剧集数，直接同步给调度 service
        )
    }
}
