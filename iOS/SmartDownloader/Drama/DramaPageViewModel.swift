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
    /// 封面远程 URL（缓存命中的展示 URL 是本地文件，重试拉取需要记住远程源头）
    private var remoteCoverURL: URL?

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
    /// 封面展示路径（用户拍板 2026-11-13）：按剧集 id 的本地缓存（≤15 天）直接用文件 URL
    /// 不联网；无缓存时远程 URL 兕底展示并后台拉取落盘，成功后切到本地文件；
    /// 拉取失败保留兕底/旧文件。三个赋值点（缓存预填/收割回填/刷新）统一走这里。
    private func applyCover(_ remoteString: String?) {
        guard let remoteString, let remote = URL(string: remoteString) else { return }
        remoteCoverURL = remote
        if let local = DramaCoverCache.validLocalURL(site: target.site, dramaID: target.dramaID) {
            if coverURL != local {
                print("PLAYER_DBG [Entry] cover use cache id=\(target.dramaID)")
                coverURL = local
            }
            return
        }
        if coverURL != remote {
            coverURL = remote
        }
        guard !coverFetchInFlight else {
            print("PLAYER_DBG [Entry] cover fetch SKIP reason=inFlight id=\(target.dramaID)")
            return
        }
        coverFetchInFlight = true
        DramaCoverCache.fetch(site: target.site, dramaID: target.dramaID, remote: remote) { [weak self] local in
            guard let self else { return }
            self.coverFetchInFlight = false
            guard let local else { return }
            self.coverURL = local
            self.coverReloadToken += 1   // 换 id 重建 AsyncImage 指向本地文件
        }
    }

    /// 头部元数据（缓存 + 后台收割）
    @Published private(set) var coverURL: URL?
    @Published private(set) var intro: String?
    /// 话题标签（DOM 收割，空格分隔；P7）
    @Published private(set) var tags: String?
    /// tags 来源（api = 定向提取；nil = 旧缓存）：旧来源自动补采一次的判定依据
    private var tagsSource: String?
    /// 本次访问是否已触发过详情采集（缓存分支与网络分支都会调 harvestIfNeeded）
    private var hasHarvestedThisVisit = false
    /// 上次后台对账时间：同一页面实例 60s 内不重复打下载接口（SWR 节流）
    private var lastRevalidatedAt: Date?
    /// 封面拉取在飞行中标志：三个赋值点先后走到 applyCover，不重复发同一请求
    private var coverFetchInFlight = false
    /// 已下载集点播的播放入口（View 据此 fullScreenCover；View 仅在 onClose 时置 nil）。
    /// didSet 探针：退出播放页的 5.2s 主线程冻结无我们日志，先把「绑定置 nil → fullScreenCover
    /// 收起 → 详情页重现」这条链路的时间戳钉出来，与 stallProbe 的 mainStall 对照判读
    @Published var playbackRequest: ImmersivePlaybackRequest? {
        didSet {
            print("PERF_DBG exit t=\(PERF.ms()) phase=playbackBinding \(oldValue != nil && playbackRequest == nil ? "cleared" : "changed")")
        }
    }

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
        isFavorite = favorites.isFavorite(site: target.site, dramaID: target.dramaID)
        // 每次进剧集页都重抓一次详情（整包落库）：清掉进程内去重标记，
        // 同一次访问内的重复触发仍由 hasHarvestedThisVisit 挡住
        DramaMetaHarvester.harvestedKeys.remove(target.id)
    }

    #if DEBUG
    /// 模拟器视觉验收专用（启动参数 `-dramaPreview`）：不经网络、不读库，
    /// 直接注入一屏固定样本，让纸本版剧集页能一次截全所有区块。
    /// Release 不编译，也不被任何真实业务路径调用。
    func injectPreviewData() {
        loading = false
        loadError = nil
        isFavorite = false
        info = DramaInfo(
            name: "荒岛求生：离队赢家",
            updateStatus: "已完结",
            episodes: (1...30).map {
                ApiDramaEpisode(id: $0, sort: $0, playable: $0 != 7)
            }
        )
        intro = "一场突如其来的海难，把所有人都困在了这座荒岛。资源有限、规则失效，"
            + "被排挤的人反而成了唯一看清局势的人。他带着三个人离开人群，走了一条谁都不敢走的路。"
        tags = "都市 逆袭 已完结"
        downloadedSorts = [2, 8]
        selectedSort = 1
        recommendations = [
            RecommendedDrama(videoID: 9001, title: "渡江 · 山河起甲", cover: nil,
                             tags: ["古装", "权谋"], playCount: 1_260_000,
                             playCountText: "126.0万", serializeStatusText: "已完结",
                             contentAccessType: "free"),
            RecommendedDrama(videoID: 9002, title: "长夜将明", cover: nil,
                             tags: ["悬疑", "年代"], playCount: 862_000,
                             playCountText: "86.2万", serializeStatusText: "已完结",
                             contentAccessType: "vip"),
            RecommendedDrama(videoID: 9003, title: "山南旧事", cover: nil,
                             tags: ["年代", "寻根"], playCount: 421_000,
                             playCountText: "42.1万", serializeStatusText: "连载中",
                             contentAccessType: "free"),
            RecommendedDrama(videoID: 9004, title: "一把破刀，砍到裂土封王", cover: nil,
                             tags: ["热血", "逆袭"], playCount: 2_304_000,
                             playCountText: "230.4万", serializeStatusText: "已完结",
                             contentAccessType: "free")
        ]
        archiveSections = [
            DramaArchiveSection(title: "基础信息", rows: [
                DramaArchiveRow(label: "剧集名称", value: "荒岛求生：离队赢家"),
                DramaArchiveRow(label: "总集数", value: "30 集 · 已完结"),
                DramaArchiveRow(label: "视频规格", value: "1080×1920 · 竖屏"),
                DramaArchiveRow(label: "数据来源", value: "本地留存 · 11月14日")
            ]),
            DramaArchiveSection(title: "互动数据", rows: [
                DramaArchiveRow(label: "播放量", value: "230.4 万"),
                DramaArchiveRow(label: "点赞 / 追剧", value: "18.6 万 / 4.2 万")
            ])
        ]
    }
    #endif

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

    // 「共 N 集」不再单独出文案（选集标题右侧那行已按用户要求删掉），
    // 集数只在下面 hintText 里与「已完结 · 已下载」并列出现一次。

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
        favorites.setFavorite(isFavorite, site: target.site, dramaID: target.dramaID)
        AppHaptics.light()   // 收藏切换：动作确认（行业惯例）
        showToast(isFavorite ? "已加入收藏" : "已取消收藏")
    }

    /// 封面占位「点击重试」：重新走一次封面缓存拉取（有本地旧文件时拉取失败也保留旧图）；
    /// 连远程 URL 都没有时清掉进程内去重，重新收割元数据再回填头部
    func retryCover() {
        guard let remote = remoteCoverURL else {
            DramaMetaHarvester.harvestedKeys.remove(target.id)
            DramaMetaHarvester.harvest(target: target) { [weak self] in
                self?.preloadHeaderFromCache()
            }
            return
        }
        coverReloadToken += 1
        DramaCoverCache.fetch(site: target.site, dramaID: target.dramaID, remote: remote) { [weak self] local in
            guard let self, let local else { return }
            self.coverURL = local
            self.coverReloadToken += 1   // 换 id 重建 AsyncImage，指向本地文件
        }
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

    /// 强制更新：走网络拉取并按集 ID 合并新集（保留下载标记）；详情采集也强制重抓
    /// - Parameters:
    ///   - quiet: 静默刷新。下拉刷新必须用它——`loading` 一置真整页会退回骨架屏，
    ///     海报和页内容当场消失，指示器还悬在上头，等于自己把自己拆了。
    ///     静默模式下网络失败也不撕页面（有内容就只弹提示条）。
    ///   - completion: 拉取结束回调，**带成功布尔**（成功与失败都回）。下拉刷新靠它
    ///     区分「已更新」与「失败」——曾经失败也回调、页面一律演「已更新」，
    ///     网络断了反而告诉用户更新成功，是明确的谎报。
    func refresh(quiet: Bool = false, completion: ((Bool) -> Void)? = nil) {
        fetchAndCache(forceHarvest: true, quiet: quiet, completion: completion)
    }

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
        let requested = selected.count
        let chosen = info.episodes
            .filter { selected.contains($0.id) && $0.playable
                && !downloadedSorts.contains($0.sort)
                && !queuedSorts.contains($0.sort) }
            .sorted { $0.sort < $1.sort }
        guard !chosen.isEmpty else {
            // 修：批量路径选中集全部不可播时原本静默吞掉（chosen 空即清选返回），用户视角是「没反应」
            selected.removeAll()
            if requested > 0 {
                print("PLAYER_DBG [CHECK] startDownload DROP-ALL reason=notPlayable requested=\(requested)")
                showToast("所选 \(requested) 集暂无可下载项（站点未开放或已在队列）")
            }
            return
        }
        // 立即清空选择：连点「下载所选」不会二次提交同一批
        selected.removeAll()
        AppHaptics.light()   // 入队确认：用户动作已被接受（行业惯例轻触）
        if chosen.count < requested {
            // 部分选中集因站点权限/重复被过滤：如实报告，不再静默丢弃
            print("PLAYER_DBG [CHECK] startDownload DROP-PARTIAL requested=\(requested) chosen=\(chosen.count)")
            showToast("已入队 \(chosen.count) 集，\(requested - chosen.count) 集跳过（未开放或已在队列）")
        }
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
            print("PLAYER_DBG [CHECK] tapEpisodeDirect REFUSE reason=notPlayable sort=\(ep.sort) id=\(ep.id)")
            showToast("第 \(ep.sort) 集站点未开放下载")
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
        // 缓存优先（SWR，用户拍板 2026-11-13）：同一剧集第二次打开直接读本地展示，
        // 同时后台拉下载接口对账（revalidateIfNeeded），不再「不点 ↻ 就永远旧」
        if let entry = DramaCache.load(site: target.site, dramaID: target.dramaID),
           let info = DramaCache.dramaInfo(from: entry) {
            self.info = info
            fromCache = true
            applyLibraryState(for: info)
            harvestIfNeeded()
            revalidateIfNeeded()
            loading = false
            return
        }
        fetchAndCache()
    }

    /// SWR 后台对账：进页即用缓存展示，同时拉下载接口（集列表/可播标记/剧名）——
    /// 失败静默保留缓存；成功与内存 info 归一化对比，**有 diff 才落库+刷新**
    /// （无 diff 不写库不重绘）。60s 内存节流防快速进出页打爆接口；↻ 刷新按钮
    /// 走 fetchAndCache(forceHarvest:) 强制路径，不经这里。
    private func revalidateIfNeeded() {
        if let last = lastRevalidatedAt, Date().timeIntervalSince(last) < 60 {
            print("PLAYER_DBG [Entry] revalidate SKIP reason=ttl \(Int(Date().timeIntervalSince(last)))s<60s")
            return
        }
        lastRevalidatedAt = Date()
        print("PLAYER_DBG [Entry] revalidate begin cachedEpisodes=\(info?.episodes.count ?? 0)")
        let session = self.session ?? DramaSession(target: target)
        self.session = session
        session.fetchInfo { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let fresh):
                // 归一化：把本地下载状态并进 fresh，对比才是「远端是否真的有变化」
                //（fresh 自接口来，downloaded/folder 恒为空，不并集则每次都假 diff）
                let merged = self.mergedWithLocalState(fresh)
                guard merged != self.info else {
                    print("PLAYER_DBG [Entry] revalidate NO-DIFF episodes=\(fresh.episodes.count)")
                    return
                }
                let oldSorts = self.info?.episodes.map(\.sort) ?? []
                let newSorts = Set(fresh.episodes.map(\.sort))
                let added = newSorts.subtracting(oldSorts).sorted()
                let removed = Set(oldSorts).subtracting(newSorts).sorted()
                DramaCache.saveInfo(site: self.target.site, dramaID: self.target.dramaID, info: merged)
                self.info = merged
                self.fromCache = false
                self.applyLibraryState(for: merged)
                self.refreshRecommendations()
                print("PLAYER_DBG [CHECK] revalidate UPDATED episodes=\(fresh.episodes.count) added=\(added) removed=\(removed)")
            case .failure(let error):
                print("PLAYER_DBG [Entry] revalidate FAIL keep-cache err=\(error.localizedDescription)")
            }
        }
    }

    /// 把当前内存 info 的下载状态（downloaded/folder，按集 id）并进接口 fresh 数据：
    /// 接口不携本地下载态，直接对比/赋值会把已下载集抹成未下载
    private func mergedWithLocalState(_ fresh: DramaInfo) -> DramaInfo {
        let oldByID = Dictionary(self.info?.episodes.map { ($0.id, $0) } ?? [],
                                 uniquingKeysWith: { a, _ in a })
        let episodes = fresh.episodes.map { ep -> ApiDramaEpisode in
            guard let old = oldByID[ep.id] else { return ep }
            return ApiDramaEpisode(id: ep.id, sort: ep.sort, playable: ep.playable,
                                downloaded: old.downloaded, folder: old.folder)
        }
        return DramaInfo(name: fresh.name, updateStatus: fresh.updateStatus, episodes: episodes)
    }

    /// 缓存里已有的封面/简介/标签先上头部（无网络也能显示）
    func preloadHeaderFromCache() {
        if let entry = DramaCache.load(site: target.site, dramaID: target.dramaID) {
            applyCover(entry.cover)
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
            // 不加触觉：下载完成可能成批到达且用户不在看（用户拍板 2026-11-13 去除）
            showToast("第 \(sort) 集下载完成")
        }
    }

    private func fetchAndCache(forceHarvest: Bool = false,
                               quiet: Bool = false,
                               completion: ((Bool) -> Void)? = nil) {
        if !quiet { loading = true }
        loadError = nil
        print("PLAYER_DBG [Entry] fetch begin quiet=\(quiet) forceHarvest=\(forceHarvest) site=\(target.site) dramaID=\(target.dramaID)")
        let session = DramaSession(target: target)
        self.session = session
        session.fetchInfo { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let info):
                self.info = info
                self.fromCache = false
                self.lastRevalidatedAt = Date()   // 刚与服务器对过账，同实例 60s 内不再重复拉
                DramaCache.saveInfo(site: self.target.site, dramaID: self.target.dramaID, info: info)
                self.applyLibraryState(for: info)
                self.refreshRecommendations()
                self.harvestIfNeeded(force: forceHarvest)
                print("PLAYER_DBG [Entry] fetch OK quiet=\(quiet) name=\(info.name) episodes=\(info.episodes.count)")
                if !quiet { self.loading = false }
                completion?(true)
            case .failure(let error):
                // 有缓存时网络失败不白屏：回退缓存继续用
                let hadMemoryInfo = self.info != nil
                let cached = DramaCache.load(site: self.target.site, dramaID: self.target.dramaID)
                    .flatMap { DramaCache.dramaInfo(from: $0) }
                if let cached {
                    self.info = cached
                    self.fromCache = true
                    self.applyLibraryState(for: cached)
                }
                // 静默刷新（下拉刷新）：页面上已经有内容，不能因为一次网络抖动
                // 就整页换成错误态——只弹一条提示条，用户自己决定要不要再拉。
                // **无条件弹**（旧版只在「无缓存且已有内存内容」时弹，有缓存时静默吞掉，
                // 下拉刷新失败就成了什么都不发生，用户以为刷过了）。
                if quiet, self.info != nil {
                    self.showToast("刷新失败，请稍后重试")
                } else if self.info == nil {
                    self.loadError = error.localizedDescription
                }
                print("PLAYER_DBG [Entry] fetch FAIL quiet=\(quiet) hasCache=\(cached != nil) hadMemoryInfo=\(hadMemoryInfo) error=\(error.localizedDescription)")
                if !quiet { self.loading = false }
                completion?(false)
            }
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

    /// 每次进剧集页的后台采集闸门（用户拍板 2026-11-13）：详情整包 15 天内抓过就不再
    /// 重抓（cover/intro/推荐/档案全在本地库，离线可用）——不再「每次进页都请求」；
    /// 过期或从未抓过才触发；↻ 刷新按钮 force 绕过闸门强制更新。
    /// 同一次访问内只抓一次（缓存分支与网络分支都会调到这里）。
    private func harvestIfNeeded(force: Bool = false) {
        // force（↻ 刷新）先于访问去重判定：force 的语义是绕过全部闸门强制重抓，
        // 曾把 guard 放在 force 判断之前导致 ↻ 的强制采集被 alreadyThisVisit 吞掉（真机日志实证）
        guard !hasHarvestedThisVisit || force else {
            print("PLAYER_DBG [Entry] harvest SKIP reason=alreadyThisVisit")
            return
        }
        hasHarvestedThisVisit = true
        // 15 天新鲜度闸门（用户拍板 2026-11-13）+ 封面文件必须存在：详情再新，
        // 封面从未落盘（CDN 密文拉不到/收割 canvas 未导出）就不能跳过收割 ——
        // 否则缓存路径永远拿不到封面，用户看到的永远是远程密文兕底
        if !force, let fetchedAt = DramaCache.detailFetchedAt(site: target.site, dramaID: target.dramaID) {
            let age = Date().timeIntervalSince(fetchedAt)
            let days = Int(age / 86400)
            let coverOK = DramaCoverCache.validLocalURL(site: target.site, dramaID: target.dramaID) != nil
            if age < DramaCoverCache.maxAge && coverOK {
                print("PLAYER_DBG [Entry] harvest SKIP reason=fresh \(days)d<=15d cover=ok")
                return
            }
            print("PLAYER_DBG [Entry] harvest trigger reason=\(age < DramaCoverCache.maxAge ? "coverMissing" : "stale") \(days)d cover=\(coverOK ? "ok" : "missing")")
        } else {
            print("PLAYER_DBG [Entry] harvest trigger reason=noRecord cover=\(DramaCoverCache.validLocalURL(site: target.site, dramaID: target.dramaID) != nil ? "ok" : "missing")")
        }
        print("PLAYER_DBG [Entry] harvest trigger reason=\(force ? "forceRefresh" : "staleOrMissing") cover=\(coverURL != nil) intro=\(intro != nil) tags=\(tags != nil)")
        DramaMetaHarvester.harvest(target: target) { [weak self] in
            guard let self else { return }
            if let entry = DramaCache.load(site: self.target.site, dramaID: self.target.dramaID) {
                applyCover(entry.cover)
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
