import Foundation
import Combine

/// 原生剧集页的 ViewModel（架构评估 P8 拆分）：
/// 剧集数据/下载状态/选择状态与全部编排（缓存优先加载、选集下载、播放入口）都在这里，
/// DramaNativePage 只渲染 + 转发用户意图。
/// 主线程约定：本类全部状态只在主线程访问（GCD 版，无线程标注）
final class DramaPageViewModel: ObservableObject {
    let target: DramaTarget
    private let manager: DownloadManager
    /// 收藏持久化交给 Service（AGENTS.md 第 5 条：VM 不直接写 UserDefaults）
    private let favorites = DramaFavorites()
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
    /// 触发 onChange 重载的版本号（重试按钮）
    @Published private(set) var reloadID = UUID()
    /// 头部元数据（缓存 + 后台收割）
    @Published private(set) var coverURL: URL?
    @Published private(set) var intro: String?
    /// 话题标签（DOM 收割，空格分隔；P7）
    @Published private(set) var tags: String?
    /// tags 来源（api = 定向提取；nil = 旧缓存）：旧来源自动补采一次的判定依据
    private var tagsSource: String?
    /// 本次访问是否已触发过详情采集（缓存分支与网络分支都会调 harvestIfNeeded）
    private var hasHarvestedThisVisit = false
    /// 已下载集点播的播放入口（View 据此 fullScreenCover；View 仅在 onClose 时置 nil）
    @Published var playbackRequest: ImmersivePlaybackRequest?

    // MARK: 剧集详情页（390×840 设计稿）交互状态

    /// 单选集（设计稿 radiogroup 语义）：点格子只改选中态，播放/下载统一由底部 CTA 触发
    @Published private(set) var selectedSort: Int?
    @Published var isDescriptionExpanded = false
    @Published private(set) var isFavorite = false
    /// 「查看全部 ›」内联展开 13 集以后的额外集（设计稿 all-open 语义，不再是 sheet）
    @Published var showAllEpisodesInline = false
    @Published private(set) var toastText: String?
    private var toastTask: DispatchWorkItem?
    /// 最近一条 toast 的令牌：只有持有当前令牌的任务才有权清除
    private var toastToken = UUID()
    /// 封面重试令牌：换值让 AsyncImage 换 id 重建，重新发起一次图片请求
    @Published private(set) var coverReloadToken = 0
    /// 首次库对账完成前不报「下载完成」，避免进页把已有文件误报成刚下完
    private var initialLibraryApplied = false

    // MARK: 「为你推荐」与「剧集档案」（数据全部来自本地 SQLite，离线可用）

    /// 推荐剧快照，按接口 position 保序；详情整包抓取完成后刷新
    @Published private(set) var recommendations: [RecommendedDrama] = []
    /// 详情整包派生的分组展示行（View 只渲染，不碰原始 DTO）
    @Published private(set) var archiveSections: [DramaArchiveSection] = []
    /// 点击推荐卡片要推入的新剧集页；View 只置位，导航由组装根挂 destination
    @Published var recommendedTarget: DramaTarget?

    init(target: DramaTarget, manager: DownloadManager) {
        self.target = target
        self.manager = manager
        isFavorite = favorites.isFavorite(target.id)
        // 每次进剧集页都重抓一次详情（整包落库）：清掉进程内去重标记，
        // 同一次访问内的重复触发仍由 hasHarvestedThisVisit 挡住
        DramaMetaHarvester.harvestedKeys.remove(target.id)
    }

    // MARK: - 派生状态

    /// 该剧仍在队列（等待/下载中）的集号。单一事实源是 manager.tasks，
    /// 用计算属性跟随状态变化，不另存状态，避免与队列状态不同步。
    var queuedSorts: Set<Int> {
        guard let info else { return [] }
        return manager.queuedEpisodeSorts(forSeries: info.name)
    }

    /// 单集下载阶段：磁盘是「已完成」的账本，进行中状态取自 DownloadTask 的
    /// state / current / total。manager 会转发每个任务的 objectWillChange，
    /// 详情页 onReceive 触发刷新时这里读到的就是实时进度。
    func downloadPhase(for sort: Int) -> EpisodeDownloadPhase {
        if downloadedSorts.contains(sort) { return .done }
        guard let info else { return .idle }
        let title = String(format: "第%02d集", sort)
        // tasks 是头插，first 即该集最新任务（重试时旧的失败任务排后面）
        guard let task = manager.tasks.first(where: {
            $0.seriesName == info.name && $0.title == title
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

    /// 设计稿 3 个标签胶囊。tags 是 API/DOM 提取的空格分隔串；无数据返回空数组（不造假标签）
    var tagChips: [String] {
        guard let tags, !tags.isEmpty else { return [] }
        return Array(tags.split(separator: " ").map(String.init).prefix(3))
    }

    var episodeCountText: String { "共 \(info?.episodes.count ?? 0) 集" }

    /// 前 12 集固定主屏，其余每 6 集一行内联展开（设计稿 13–68 集 = 10 行 × 56pt）
    var extraEpisodeRows: Int {
        guard let info else { return 0 }
        return (max(0, info.episodes.count - 12) + 5) / 6
    }

    var hasExtraEpisodes: Bool { extraEpisodeRows > 0 }

    /// 设计稿 hint 位：保留排版，文案改用真实数据（不编「每集约 2 分钟」这类无来源文案）
    var hintText: String {
        var parts = ["共 \(info?.episodes.count ?? 0) 集"]
        if let status = info?.updateStatus, !status.isEmpty { parts.append(status) }
        if !downloadedSorts.isEmpty { parts.append("已下载 \(downloadedSorts.count) 集") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 用户意图（主屏格子直点，已移除底部 CTA）

    func toggleDescription() { isDescriptionExpanded.toggle() }

    func toggleFavorite() {
        isFavorite.toggle()
        favorites.setFavorite(isFavorite, for: target.id)
        showToast(isFavorite ? "已加入收藏" : "已取消收藏")
    }

    /// 封面占位「点击重试」：有 URL 时换 token 让 AsyncImage 重建；
    /// 连 URL 都没有时清掉进程内去重，重新收割元数据再回填头部
    func retryCover() {
        guard coverURL != nil else {
            DramaMetaHarvester.harvestedKeys.remove(target.id)
            DramaMetaHarvester.harvest(target: target) { [weak self] in
                self?.preloadHeaderFromCache()
            }
            return
        }
        coverReloadToken += 1
    }

    /// 2 秒后自动消失（用户指定）。取消旧 WorkItem + UUID 令牌：连续提示时旧任务
    /// 因令牌不匹配不会误清新提示，最后一条只要令牌仍匹配就必须无条件清掉（不留永久挂着的 toast）。
    func showToast(_ text: String) {
        toastTask?.cancel()
        let token = UUID()
        toastToken = token
        toastText = text
        print("PLAYER_DBG [VM] drama showToast text=\(text)")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.toastToken == token else {
                print("PLAYER_DBG [VM] drama showToast dismiss SKIP reason=staleToken")
                return
            }
            self.toastText = nil
            print("PLAYER_DBG [VM] drama showToast dismiss reason=timeout2s")
        }
        toastTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// 重试按钮：换 reload 版本号触发 onChange 重新加载
    func reload() { reloadID = UUID() }

    /// ↻ 强制更新：走网络拉取并按集 ID 合并新集（保留下载标记）
    func refresh() { fetchAndCache() }

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

    // MARK: - 格子直点 / 批量 / 推荐跳转

    /// 主屏选集格子直点（设计稿语义，取代原「单选 + 底部 CTA」）：
    /// 已下载→播放；下载中/排队→取消；未下载且可播→直接下载该集；锁定→如实提示。
    /// 「查看全部」面板仍用 tapEpisode 的多选语义，两条路径互不干扰。
    func tapEpisodeDirect(_ ep: ApiDramaEpisode) {
        if downloadedSorts.contains(ep.sort) {
            selectedSort = ep.sort
            makePlaybackRequest(for: ep)
        } else if queuedSorts.contains(ep.sort) {
            cancelDownload(sort: ep.sort)
        } else if !ep.playable {
            showToast("第 \(ep.sort) 集暂不可看")
        } else {
            selectedSort = ep.sort
            selected = [ep.id]
            startDownload()
            showToast("已加入下载队列：第 \(ep.sort) 集")
        }
    }

    /// 设计稿「下载全部」：把全部可下且未入队的集一次交给 SeriesDownloadCoordinator
    ///（仍是最多 2 集并行、每集下载前重取新鲜直链），不绕过现有调度。
    func downloadAll() {
        guard let info else { return }
        let pending = info.episodes.filter {
            $0.playable && !downloadedSorts.contains($0.sort) && !queuedSorts.contains($0.sort)
        }
        guard !pending.isEmpty else {
            showToast("没有可下载的剧集")
            return
        }
        selected = Set(pending.map(\.id))
        startDownload()
        showToast("已加入下载队列：\(pending.count) 集")
    }

    /// 取消单集下载：复用 DownloadManager.remove —— 它置 isCancelled、删半成品、
    /// 清行为数据并移出队列；引擎在切片间隙检查 isCancelled 后收尾。
    /// setTask 直接持有 task 对象（不查 tasks 数组），任务移出后回写仍安全。
    private func cancelDownload(sort: Int) {
        guard let info else { return }
        let title = String(format: "第%02d集", sort)
        guard let task = manager.tasks.first(where: {
            $0.seriesName == info.name && $0.title == title && !$0.state.isFinished
        }) else {
            showToast("第 \(sort) 集不在下载队列")
            return
        }
        manager.remove(task)
        showToast("已取消第 \(sort) 集下载")
    }

    /// 推荐卡片点击：站点地址从当前页 target 推导，代码内不硬编码站点（AGENTS.md 第 2 条）。
    /// 只置位，导航由 DramaNativePage 挂的 navigationDestination 负责。
    func openRecommendation(_ item: RecommendedDrama) {
        let next = DramaTarget(site: target.site, dramaID: String(item.videoID))
        print("PLAYER_DBG [Entry] reco tap -> \(next.id) title=\(item.displayTitle)")
        recommendedTarget = next
    }

    /// 推荐与档案都读本地 SQLite：drama_related 快照 + api_detail 整包解码，离线可用。
    /// 进页先读一次（有缓存即可显示），详情收割完成后再读一次拿最新字段。
    func refreshRecommendations() {
        recommendations = DramaCache.relatedDramas(site: target.site, dramaID: target.dramaID)
        let fetchedAt = DramaCache.load(site: target.site, dramaID: target.dramaID)?.fetchedAt
        archiveSections = DramaArchive.sections(
            from: DramaCache.detailData(site: target.site, dramaID: target.dramaID),
            fetchedAt: fetchedAt)
        print("PLAYER_DBG [Entry] reco refresh count=\(recommendations.count) archiveSections=\(archiveSections.count)")
    }

    // MARK: - 加载编排

    func load() {
        loading = true
        loadError = nil
        selected = []
        // 缓存优先：同一剧集第二次打开直接读本地，不发网络请求（刷新按钮强制更新）
        if let entry = DramaCache.load(site: target.site, dramaID: target.dramaID),
           let info = DramaCache.dramaInfo(from: entry) {
            self.info = info
            fromCache = true
            applyLibraryState(for: info)
            harvestIfNeeded()
            loading = false
            return
        }
        fetchAndCache()
    }

    /// 缓存里已有的封面/简介/标签先上头部（无网络也能显示）
    func preloadHeaderFromCache() {
        if let entry = DramaCache.load(site: target.site, dramaID: target.dramaID) {
            if let cover = entry.cover, let url = URL(string: cover) { coverURL = url }
            if let introText = entry.intro, !introText.isEmpty { intro = introText }
            // 空串 = 采集失败，不是「已缓存」：归 nil 才能让 harvestIfNeeded 继续收割
            tags = entry.tags.flatMap { $0.isEmpty ? nil : $0 }
            tagsSource = entry.tagsSource
        }
        // 有缓存就先亮出推荐与档案，不等后台收割
        refreshRecommendations()
    }

    /// 任一任务状态变化时重算已下载集；新落盘的集给一条完成 toast（下载提示）。
    /// 只做内存比对，不每 tick 写库。
    func refreshDownloadedSorts() {
        guard let info else { return }
        let fresh = Set(manager.downloadedEpisodeFolders(forSeries: info.name).keys)
        let newlyDone = fresh.subtracting(downloadedSorts)
        downloadedSorts = fresh
        if initialLibraryApplied, let sort = newlyDone.min() {
            showToast("第 \(sort) 集下载完成")
        }
    }

    private func fetchAndCache() {
        loading = true
        loadError = nil
        let session = DramaSession(target: target)
        self.session = session
        session.fetchInfo { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let info):
                self.info = info
                self.fromCache = false
                DramaCache.saveInfo(site: self.target.site, dramaID: self.target.dramaID, info: info)
                self.applyLibraryState(for: info)
                self.refreshRecommendations()
                self.harvestIfNeeded()
            case .failure(let error):
                // 有缓存时网络失败不白屏：回退缓存继续用
                if let entry = DramaCache.load(site: self.target.site, dramaID: self.target.dramaID),
                   let info = DramaCache.dramaInfo(from: entry) {
                    self.info = info
                    self.fromCache = true
                    self.applyLibraryState(for: info)
                } else {
                    self.loadError = error.localizedDescription
                }
            }
            self.loading = false
        }
    }

    private func applyLibraryState(for info: DramaInfo) {
        // 先收编旧版散装下载（只搬不删），再算已下载集（磁盘为账本），并对账写回缓存
        manager.collectLegacyEpisodes(forSeries: info.name)
        manager.refreshLibrary()
        let folders = manager.downloadedEpisodeFolders(forSeries: info.name)
        downloadedSorts = Set(folders.keys)
        DramaCache.reconcileDownloaded(site: target.site, dramaID: target.dramaID, folders: folders)
        ensureSelection(for: info)
        initialLibraryApplied = true
    }

    /// 详情页默认选中集：优先第一个已下载（可直接播），否则第一集。刷新换集后若旧选中集
    /// 已不在列表里也重新落位。无「上次观看」数据源，不编造续播集号。
    private func ensureSelection(for info: DramaInfo) {
        if let sort = selectedSort, info.episodes.contains(where: { $0.sort == sort }) { return }
        selectedSort = info.episodes.first { downloadedSorts.contains($0.sort) }?.sort
            ?? info.episodes.first?.sort
    }

    /// 每次进剧集页都后台抓一次详情接口并整包落库（不再只在缺封面/简介时抓）：
    /// 播放量/点赞数/推荐剧/服务端观看进度这些字段只有重抓才会更新。
    /// 同一次访问内只抓一次（缓存分支与网络分支都会调到这里）。
    private func harvestIfNeeded() {
        guard !hasHarvestedThisVisit else {
            print("PLAYER_DBG [Entry] harvest SKIP reason=alreadyThisVisit")
            return
        }
        hasHarvestedThisVisit = true
        print("PLAYER_DBG [Entry] harvest trigger reason=pageEntry cover=\(coverURL != nil) intro=\(intro != nil) tags=\(tags != nil)")
        DramaMetaHarvester.harvest(target: target) { [weak self] in
            guard let self else { return }
            if let entry = DramaCache.load(site: self.target.site, dramaID: self.target.dramaID) {
                if let cover = entry.cover, let url = URL(string: cover) { self.coverURL = url }
                if let introText = entry.intro, !introText.isEmpty { self.intro = introText }
                self.tags = entry.tags.flatMap { $0.isEmpty ? nil : $0 }
                self.tagsSource = entry.tagsSource
            }
            // 详情整包这时才落库，推荐剧 / 档案字段在此刷新为最新值
            self.refreshRecommendations()
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
            knownSorts: info.episodes.map(\.sort),   // 剧集页已持有全剧集数，直接同步给调度 service
            target: target                            // 站点/剧 id 直达，行为数据不靠剧名猜
        )
    }
}
