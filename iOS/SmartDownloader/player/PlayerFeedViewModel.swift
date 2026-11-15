import SwiftUI
import Combine

/// 分页播放页 ViewModel：列表数据源、当前页、边界 toast、停稳后切换播放源。
/// 不含 UIKit / AVFoundation 对象；资源调度委托 PlaybackQueueService。
/// 主线程约定：本类全部状态只在主线程访问（GCD 版，无线程标注）
final class PlayerFeedViewModel: ObservableObject {
    @Published private(set) var slots: [PlayableEpisode] = []
    /// 与系统分页的 scrollPosition 双向绑定
    @Published var currentSort: Int?
    @Published private(set) var toastText: String?
    /// 当前页播放是否已就绪：驱动容器刷新卡片 rootView，让视频层显露出来
    @Published private(set) var playbackReady = false
    /// 选集面板格子（真实集号 + 下载态 + 站点可播）：2026-11-15 起面板不再按 1…total 编号
    @Published private(set) var episodeItems: [EpisodePanelItem] = []
    /// 面板一次性提示（下载已入队 / 站点未开放 / 已在下载中…），2.4s 后自动清空
    @Published private(set) var episodeHint: String?

    let playback: DramaPlayerViewModel
    private let playerService = PlaybackPlayerService()
    private let panelService = EpisodePanelService()
    private var queue: PlaybackQueueService?
    /// 播放请求带的站点身份（下载页入口为 nil，服务里按剧名反查）
    private var playbackTarget: DramaTarget?
    /// 下载管理器：面板下载态跟着它实时刷新；预览宿主可能没注入
    private var manager: DownloadManager?
    private var managerCancellable: AnyCancellable?
    /// 面板刷新去抖（下载进度变化很密，0.25s 内合并成一次）
    private var panelRefreshWork: DispatchWorkItem?
    /// 面板提示令牌：旧任务不得清掉新提示
    private var hintToken = UUID()
    private var hintTask: DispatchWorkItem?
    /// 最近一条 toast 的令牌：只有持有当前令牌的任务才有权清除，避免旧任务误清新提示
    private var toastToken = UUID()
    private var toastTask: DispatchWorkItem?
    /// 停稳防抖 WorkItem（150ms）：新滑动取消旧的，只在最后一页切换播放源
    private var settleWork: DispatchWorkItem?
    /// 停稳代际：每次 pageSettled/stop 递增，迟到的加载完成回调按代际丢弃
    private var settleGeneration = 0
    private var configured = false
    private var endToastShown = false
    /// 姿态判稳触发器（横屏片源稳定转横自动进全屏），configure 创建、stop 停止
    private var orientationTrigger: PlayerOrientationTrigger?

    init() {
        playback = DramaPlayerViewModel(playerService: playerService)
        // 连播接线（2026-11-14）：播完信号 → 本类算下一集（持有 queue/slots）→
        // 置 playback.autoAdvanceSort 交给滚动层动画翻页 → 复用既有停稳管线加载。
        // 本类不直接 load：翻页照常走分页容器，refreshAvailability/预热池/autoplay 全在 pageSettled
        playback.onPlaybackEnded = { [weak self] in self?.playbackDidEnd() }
    }

    var seriesName: String { queue?.seriesName ?? "" }
    var intro: String? { queue?.intro }
    var tags: String? { queue?.tags }
    var totalEpisodes: Int { slots.count }

    func configure(request: ImmersivePlaybackRequest, manager: DownloadManager? = nil) {
        guard !configured else {
            print("PLAYER_DBG [VM] configure SKIP reason=alreadyConfigured series=\(request.seriesName)")
            return
        }
        configured = true
        // 防御性复位：VM 当前按容器生命周期每次新建，但若将来被复用，
        // 上一轮的「已到底」标记不得吞掉本轮的边界提示（评估报告 P2）
        endToastShown = false
        self.manager = manager
        playbackTarget = request.target
        let q = PlaybackQueueService(request: request)
        queue = q
        slots = q.slots
        currentSort = q.current?.sort
        // 全屏控制层要的元信息（顶栏剧名集数 / 选集抽屉全集数）：本类持有队列知识，
        // 播放 VM 不持有——一次性注入，避免播放侧自己反查
        playback.seriesName = q.seriesName
        playback.episodeTotal = q.slots.count
        // 选集面板（2026-11-15）：格子由本类装配后推进播放 VM 的 subject，
        // 点按也统一收口到 selectEpisode（持有队列/下载知识的是本类，不是播放 VM）
        playback.onEpisodeSelected = { [weak self] sort in
            self?.selectEpisode(sort: sort) ?? false
        }
        observeDownloads(manager)
        refreshEpisodePanel(reason: "configure")
        // 进入即预热首集 + 相邻集：与 150ms 停稳防抖并行，首次起播也走 HIT 路径
        if let current = q.current {
            let neighbors = q.neighbors(of: current.sort)
            playerService.preload([current] + neighbors)
            print("PLAYER_DBG [VM] preload entry sort=\(current.sort) neighbors=\(neighbors.map(\.sort))")
        }
        print("PLAYER_DBG [VM] configure series=\(request.seriesName) startSort=\(request.startSort) knownSorts=\(request.knownSorts.count) → slots=\(slots.count) sorts=\(slots.map(\.sort)) current=\(currentSort.map(String.init) ?? "nil") manager=\(manager != nil)")
        // 姿态触发：设备稳定转横自动进全屏（仅横屏片源），稳定回竖自动退出
        let trigger = PlayerOrientationTrigger(playback: playback)
        trigger.start()
        orientationTrigger = trigger
    }

    /// 滚动停稳防抖入口（View 的 onAppear/onChange 转发）：
    /// 150ms 内新滑动取消旧 WorkItem，只在最后一页切换播放源
    func schedulePageSettle(sort: Int?) {
        print("PLAYER_DBG [CHECK] feedTask start scrollID=\(sort.map(String.init) ?? "nil") vmBefore=\(currentSort.map(String.init) ?? "nil")")
        settleWork?.cancel()
        guard let sort else { return }
        currentSort = sort
        let work = DispatchWorkItem { [weak self] in
            self?.pageSettled(sort: sort)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 滚动停稳后才切换播放源，避免快滑反复 replaceCurrentItem
    func pageSettled(sort: Int) {
        print("PLAYER_DBG [VM] pageSettled begin sort=\(sort)")
        // 播放期间可能有集刚下载完成：停稳时先对账磁盘再取槽位，
        // 否则开播时的快照会让刚下完的集继续显示「尚未下载」占位（真机实证）
        if queue?.refreshAvailability() == true, let refreshed = queue {
            slots = refreshed.slots
        }
        // 磁盘刚对过账：面板格子同步刷新（不再重复扫盘），「播放中刚下完的集」立刻可点
        refreshEpisodePanel(reason: "pageSettled", scanDisk: false)
        guard let slot = slots.first(where: { $0.sort == sort }) else {
            print("PLAYER_DBG [VM] pageSettled NO SLOT sort=\(sort)")
            return
        }
        settleGeneration += 1
        let generation = settleGeneration
        queue?.select(sort: sort)
        // 相邻集预热与当前集加载并行：在用户滑过去之前把 m3u8 管线提前跑完（秒开关键）。
        // wanted 必须带上当前集：上一轮为本集预热的资产不能被本轮邻居预热淘汰
        //（此前只报邻居，真机日志实证每次 makeItem 都 MISS，池子形同虚设）
        preloadNeighbors(of: sort, current: slot)
        // 先置 false 让卡片回到加载态，load 完成后再置 true 触发一次刷新显露视频层
        playbackReady = false
        playback.load(episode: slot) { [weak self] in
            guard let self, generation == self.settleGeneration else {
                print("PLAYER_DBG [VM] pageSettled CANCELLED sort=\(sort)（新滑动接管）")
                return
            }
            self.playbackReady = self.playback.isReady
            print("PLAYER_DBG [CHECK] pageSettled done sort=\(sort) isLast=\(self.isLast(sort)) slots=\(self.slots.count) current=\(self.currentSort.map(String.init) ?? "nil") ready=\(self.playbackReady)")
            if !slot.isAvailable {
                // 待办 #4：滑到未下载集给引导提示（不改 resolve 语义：全剧集数可滑、胶囊 4/11 不变）。
                // 占位卡已有内联提示，toast 补「去哪下载」的行动指引
                self.showToast("第\(sort)集尚未下载 · 回剧集页下载后可看")
            }
            // 「已经到底了」不再在停稳末页时提示（用户拍板 2026-11-14）：
            // 改为末页再滑一次（想看下一集但已无资源）才提示，见 pulledBeyondEnd()
        }
    }

    // MARK: - 选集面板（2026-11-15）

    /// 面板数据刷新：集号来自队列槽位（真实集号），下载态来自磁盘 + 下载任务。
    /// `scanDisk` = 先对账磁盘（页面停稳/下载完成时都要，避免面板显示过期可用性）。
    func refreshEpisodePanel(reason: String, scanDisk: Bool = true) {
        guard let queue else {
            print("PLAYER_DBG [VM] panel refresh SKIP reason=noQueue source=\(reason)")
            return
        }
        if scanDisk, self.queue?.refreshAvailability() == true, let refreshed = self.queue {
            slots = refreshed.slots
        }
        let items = panelService.items(slots: slots, seriesName: queue.seriesName,
                                       target: playbackTarget, manager: manager)
        if items != episodeItems {
            episodeItems = items
            print("PLAYER_DBG [CHECK] panel refresh source=\(reason) cells=\(items.count) "
                  + "downloaded=\(items.filter(\.isDownloaded).map(\.sort)) "
                  + "pending=\(items.filter { $0.phase != .idle && !$0.isDownloaded }.map(\.sort))")
        }
        publishEpisodePanel()
    }

    /// 点面板里的一格：先对账磁盘，已下载 → 切集播放；未下载 → 入队下载。
    /// 返回 true = 面板可以收起（真的切了集，或点的就是当前集）；
    /// false = 留在面板里（下载已入队 / 站点未开放 / 缺元数据，靠进度环与标题提示反馈）。
    @discardableResult
    func selectEpisode(sort: Int) -> Bool {
        print("PLAYER_DBG [CHECK] selectEpisode sort=\(sort) current=\(currentSort.map(String.init) ?? "nil") cells=\(episodeItems.count)")
        if sort == currentSort {
            // 点的是当前集：不切集，但把面板/抽屉收起来（否则用户点了没反应，会反复点）
            print("PLAYER_DBG [CHECK] selectEpisode SKIP reason=sameEpisode sort=\(sort) → close")
            return true
        }
        if self.queue?.refreshAvailability() == true, let refreshed = self.queue {
            slots = refreshed.slots
            refreshEpisodePanel(reason: "selectEpisode", scanDisk: false)
        }
        guard let slot = slots.first(where: { $0.sort == sort }) else {
            print("PLAYER_DBG [CHECK] selectEpisode SKIP reason=noSlot sort=\(sort)")
            setEpisodeHint("第\(sort)集不在本剧集数中", reason: "noSlot")
            return false
        }
        if slot.isAvailable {
            print("PLAYER_DBG [CHECK] selectEpisode → play sort=\(sort) via autoAdvanceSort")
            playback.autoAdvanceSort = sort
            return true
        }
        guard let manager else {
            print("PLAYER_DBG [CHECK] selectEpisode SKIP reason=noManager sort=\(sort)")
            setEpisodeHint("第\(sort)集尚未下载", reason: "noManager")
            return false
        }
        if let item = episodeItems.first(where: { $0.sort == sort }) {
            switch item.phase {
            case .queued, .active:
                print("PLAYER_DBG [CHECK] selectEpisode SKIP reason=downloading sort=\(sort)")
                setEpisodeHint("第\(sort)集正在下载", reason: "alreadyQueued")
                return false
            case .idle, .failed, .done:
                break   // failed 可重试；done 但磁盘还没就绪 → 交给 requestDownload 再判
            }
            if !item.playable {
                print("PLAYER_DBG [CHECK] selectEpisode REFUSE reason=notPlayable sort=\(sort)")
                setEpisodeHint("第\(sort)集站点未开放下载", reason: "notPlayable")
                AppHaptics.warning()
                return false
            }
        }
        switch panelService.requestDownload(sort: sort, seriesName: seriesName,
                                            target: playbackTarget, manager: manager) {
        case .queued(let queuedSort):
            AppHaptics.light()
            setEpisodeHint("已加入下载队列：第\(queuedSort)集", reason: "queued")
            scheduleEpisodePanelRefresh()
        case .alreadyQueued(let s):
            setEpisodeHint("第\(s)集正在下载", reason: "alreadyQueued")
        case .notPlayable(let s):
            AppHaptics.warning()
            setEpisodeHint("第\(s)集站点未开放下载", reason: "notPlayable")
        case .missingMetadata, .missingTarget:
            setEpisodeHint("缺少剧集信息，请回剧集页下载", reason: "missingMetadata")
        }
        return false
    }

    /// 下载任务状态变化 → 面板去抖刷新（进度很密，0.25s 合并一次）
    private func observeDownloads(_ manager: DownloadManager?) {
        managerCancellable = nil
        guard let manager else {
            print("PLAYER_DBG [VM] panel observe DISABLED reason=noManager")
            return
        }
        managerCancellable = manager.objectWillChange
            // objectWillChange 在状态变更**之前**发出：切到下一轮 runloop 再读才是新值
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.scheduleEpisodePanelRefresh() }
        print("PLAYER_DBG [VM] panel observe manager=ON")
    }

    private func scheduleEpisodePanelRefresh() {
        panelRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshEpisodePanel(reason: "downloads")
        }
        panelRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 面板提示（标题位置显示）：新提示顶掉旧的，2.4s 后按令牌清除
    private func setEpisodeHint(_ text: String, reason: String) {
        hintTask?.cancel()
        let token = UUID()
        hintToken = token
        episodeHint = text
        print("PLAYER_DBG [VM] panel hint=\(text) reason=\(reason)")
        publishEpisodePanel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hintToken == token else { return }
            self.episodeHint = nil
            print("PLAYER_DBG [VM] panel hint clear reason=timeout2.4s")
            self.publishEpisodePanel()
        }
        hintTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    /// 面板状态同步给播放 VM 的专用通道（全屏抽屉订阅它，不碰 objectWillChange）
    private func publishEpisodePanel() {
        playback.episodePanelSubject.send(EpisodePanelState(items: episodeItems, hint: episodeHint))
    }

    /// 预热「当前集 + 调度顺序上相邻的集」（走 PlaybackQueueService 的推荐接入点，算法换序自动跟随）
    private func preloadNeighbors(of sort: Int, current: PlayableEpisode) {
        guard let queue else { return }
        let neighbors = queue.neighbors(of: sort)
        playerService.preload([current] + neighbors)
        print("PLAYER_DBG [VM] preloadNeighbors of=\(sort) wanted=\(([current] + neighbors).map(\.sort))")
    }

    func hasNext(after sort: Int) -> Bool {
        guard let i = slots.firstIndex(where: { $0.sort == sort }) else { return false }
        return i + 1 < slots.count
    }

    func nextIsAvailable(after sort: Int) -> Bool {
        guard let i = slots.firstIndex(where: { $0.sort == sort }),
              i + 1 < slots.count else { return false }
        return slots[i + 1].isAvailable
    }

    func isFirst(_ sort: Int) -> Bool { slots.first?.sort == sort }
    func isLast(_ sort: Int) -> Bool { slots.last?.sort == sort }

    /// 末页再滑一次（想看下一集但已无资源、翻不出去）时才提示「已经到底了」。
    /// 用户拍板 2026-11-14：停稳末页本身不算信号（旧实现在 pageSettled 里停稳即提示），
    /// 与抖音行为一致——末页停留是正常状态，滑出未果才是用户在问「还有没有」。
    /// 触发源：PlayerPagingScrollView 的 scrollViewWillEndDragging 检测「想往后翻一格
    /// 但被 clamp 在末页」。一次会话只提示一次（endToastShown）。
    func pulledBeyondEnd() {
        guard !endToastShown else {
            print("PLAYER_DBG [CHECK] pullBeyondEnd SKIP reason=alreadyShown")
            return
        }
        endToastShown = true
        AppHaptics.warning()   // 上滑到最后一集再滑一次仍翻不出去：到达边界（行业惯例警示触）
        showToast("已经到底了")
        print("PLAYER_DBG [CHECK] pullBeyondEnd → toast「已经到底了」")
    }

    /// 单集播完（DramaPlayerViewModel 的 didPlayToEnd 信号）→ 自动连播下一集。
    /// 职责边界：本方法只算下一集并置信号（playback.autoAdvanceSort）——动画翻页归
    /// PlayerPagingScrollView 的 Coordinator，加载复用 pageSettled（refreshAvailability /
    /// 预热池 / autoplay 全在既有管线里，连播下一集大概率 HIT 预热池秒开）。
    /// 末集播完不跳（hasNext false，停在末帧）；下一集未下载照常跳占位页
    ///（pageSettled 自带「尚未下载」toast）；拖 seek 到片尾触发连播视为合理。
    func playbackDidEnd() {
        guard let current = currentSort else {
            print("PLAYER_DBG [CHECK] playbackDidEnd SKIP reason=noCurrentSort")
            return
        }
        guard hasNext(after: current), let i = slots.firstIndex(where: { $0.sort == current }) else {
            print("PLAYER_DBG [CHECK] playbackDidEnd SKIP reason=lastEpisode sort=\(current)")
            return
        }
        let next = slots[i + 1]
        print("PLAYER_DBG [VM] playbackDidEnd current=\(current) → autoAdvance=\(next.sort) available=\(next.isAvailable)")
        playback.autoAdvanceSort = next.sort
    }

    /// 2 秒后自动消失（用户指定）。取消旧 WorkItem + UUID 令牌：连续提示时旧任务
    /// 因令牌不匹配不会误清新提示，最后一条只要令牌仍匹配就必须无条件清掉（不留永久挂着的 toast）。
    func showToast(_ text: String) {
        toastTask?.cancel()
        let token = UUID()
        toastToken = token
        toastText = text
        print("PLAYER_DBG [VM] showToast text=\(text) current=\(currentSort.map(String.init) ?? "nil")")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.toastText = nil
            print("PLAYER_DBG [VM] showToast dismiss reason=timeout2s")
        }
        toastTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// 关键时机落库（View 在 App 进后台时转发）：内存里攒的位置写进行为数据表
    func flushProgress() {
        playback.flushProgress()
    }

    func stop() {
        print("PLAYER_DBG [VM] stop current=\(currentSort.map(String.init) ?? "nil") slots=\(slots.count)")
        // 姿态触发随播放页销毁停止
        orientationTrigger?.stop()
        orientationTrigger = nil
        // 停稳防抖与在飞加载一并作废
        settleWork?.cancel()
        settleWork = nil
        settleGeneration += 1
        // 面板刷新/提示一并停掉，并清空共享状态（下一个播放页重新装配）
        panelRefreshWork?.cancel()
        panelRefreshWork = nil
        hintTask?.cancel()
        hintTask = nil
        managerCancellable = nil
        episodeItems = []
        episodeHint = nil
        publishEpisodePanel()
        // 退出播放页顺手清掉挂着的提示，避免下个页面复用时残留
        toastTask?.cancel()
        toastText = nil
        playback.stop()
        playerService.teardown()
    }
}
