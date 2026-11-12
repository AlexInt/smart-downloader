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
    /// 已下载集点播的播放入口（View 据此 fullScreenCover；View 仅在 onClose 时置 nil）
    @Published var playbackRequest: ImmersivePlaybackRequest?

    // MARK: 剧集详情页（390×840 设计稿）交互状态

    /// 单选集（设计稿 radiogroup 语义）：点格子只改选中态，播放/下载统一由底部 CTA 触发
    @Published private(set) var selectedSort: Int?
    @Published var isDescriptionExpanded = false
    @Published private(set) var isFavorite = false
    /// 「查看全部 ›」展开的全量选集面板（保留多选下载 / 刷新能力）
    @Published var showAllEpisodes = false
    @Published private(set) var toastText: String?
    private var toastTask: DispatchWorkItem?
    /// 最近一条 toast 的令牌：只有持有当前令牌的任务才有权清除
    private var toastToken = UUID()
    /// 封面重试令牌：换值让 AsyncImage 换 id 重建，重新发起一次图片请求
    @Published private(set) var coverReloadToken = 0
    /// 首次库对账完成前不报「下载完成」，避免进页把已有文件误报成刚下完
    private var initialLibraryApplied = false

    init(target: DramaTarget, manager: DownloadManager) {
        self.target = target
        self.manager = manager
        isFavorite = favorites.isFavorite(target.id)
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

    /// 设计稿 hint 位：保留排版，文案改用真实数据（不编「每集约 2 分钟」这类无来源文案）
    var hintText: String {
        var parts = ["共 \(info?.episodes.count ?? 0) 集"]
        if let status = info?.updateStatus, !status.isEmpty { parts.append(status) }
        if !downloadedSorts.isEmpty { parts.append("已下载 \(downloadedSorts.count) 集") }
        return parts.joined(separator: " · ")
    }

    /// CTA 视觉语义：true = 已可播（红橙渐变 + 白字），false = 需要下载（白底 + 红字）。
    /// 用户要求「需要下载时底部按钮不要是红色」，播放与下载两种动作要一眼可分。
    var ctaIsPlay: Bool {
        guard let sort = selectedSort else { return false }
        return downloadedSorts.contains(sort)
    }

    /// CTA 文案随选中集的真实状态变化：已下载可播、未下载可下、排队中/锁定如实告知
    var ctaTitle: String {
        guard let sort = selectedSort else { return "请选择剧集" }
        if downloadedSorts.contains(sort) { return "播放第 \(sort) 集" }
        if queuedSorts.contains(sort) {
            if case .active(let p) = downloadPhase(for: sort), p > 0.03 {
                return "第 \(sort) 集 · \(Int(p * 100))%"
            }
            return "第 \(sort) 集下载中"
        }
        if let ep = info?.episodes.first(where: { $0.sort == sort }), !ep.playable {
            return "第 \(sort) 集暂不可看"
        }
        return "下载第 \(sort) 集"
    }

    // MARK: - 用户意图（剧集详情页）

    /// 格子单选：只改选中态，不触发下载/播放（设计稿 radiogroup 语义）
    func select(sort: Int) { selectedSort = sort }

    func toggleDescription() { isDescriptionExpanded.toggle() }

    func toggleFavorite() {
        isFavorite.toggle()
        favorites.setFavorite(isFavorite, for: target.id)
        showToast(isFavorite ? "已加入收藏" : "已取消收藏")
    }

    /// 底部 CTA：已下载则播放，未下载且可播则把该集加入下载队列，其余状态如实提示
    func playSelected() {
        guard let info, let sort = selectedSort,
              let ep = info.episodes.first(where: { $0.sort == sort }) else {
            showToast("请先选择剧集")
            return
        }
        if downloadedSorts.contains(sort) {
            makePlaybackRequest(for: ep)
        } else if queuedSorts.contains(sort) {
            showToast("第 \(sort) 集已在下载队列")
        } else if !ep.playable {
            showToast("第 \(sort) 集暂不可看")
        } else {
            selected = [ep.id]
            startDownload()
            showToast("已加入下载队列：第 \(sort) 集")
        }
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

    /// 3 秒后自动消失（用户指定）。旧实现 `guard !Task.isCancelled else { return }`
    /// 会让被取消的任务跳过清除 —— 最后一条 toast 若被取消就永远挂着，这是「不消失」的根因。
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
            print("PLAYER_DBG [VM] drama showToast dismiss reason=timeout3s")
        }
        toastTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
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

    /// 头部缺封面/简介/标签时：后台隐藏 webview 拉一次剧集页提取元数据（落库后头部即时更新）。
    /// tags 纳入触发条件是 P7 采集需要；空串视为缺失 —— 采集失败后可重试
    ///（DramaMetaHarvester.harvestedKeys 只在进程内去重，重进 App 会清空）
    private func harvestIfNeeded() {
        // 空串也算「没有 tags」：旧实现把 "" 写进缓存列，这里误判已缓存 → 永久跳过收割
        let hasTags = !(tags?.isEmpty ?? true)
        // 来源比对：旧缓存（锚点法时代）无 tags_source → 视为不全，进页自动补采一次；
        // 采成功写 api 后恢复缓存优先（零网络）。不用手动开关迁移。
        let hasApiTags = hasTags && tagsSource == "api"
        // -captureDramaMeta：调查期手动强制重采（连 api 来源也重跑）
        let force = ProcessInfo.processInfo.arguments.contains("captureDramaMeta")
        guard force || coverURL == nil || intro == nil || !hasApiTags else {
            print("PLAYER_DBG [Entry] harvest SKIP reason=headerCached cover=\(coverURL != nil) intro=\(intro != nil) tags=\(hasApiTags) source=\(tagsSource ?? "nil")")
            return
        }
        print("PLAYER_DBG [Entry] harvest trigger reason=\(force ? "forcedCapture" : "headerMissing") cover=\(coverURL != nil) intro=\(intro != nil) tags=\(hasApiTags) source=\(tagsSource ?? "nil")")
        DramaMetaHarvester.harvest(target: target) { [weak self] in
            guard let self else { return }
            if let entry = DramaCache.load(site: self.target.site, dramaID: self.target.dramaID) {
                if let cover = entry.cover, let url = URL(string: cover) { self.coverURL = url }
                if let introText = entry.intro, !introText.isEmpty { self.intro = introText }
                self.tags = entry.tags.flatMap { $0.isEmpty ? nil : $0 }
                self.tagsSource = entry.tagsSource
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
