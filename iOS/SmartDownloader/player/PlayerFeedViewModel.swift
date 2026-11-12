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

    let playback: DramaPlayerViewModel
    private let playerService = PlaybackPlayerService()
    private var queue: PlaybackQueueService?
    /// 最近一条 toast 的令牌：只有持有当前令牌的任务才有权清除，避免旧任务误清新提示
    private var toastToken = UUID()
    private var toastTask: DispatchWorkItem?
    /// 停稳防抖 WorkItem（150ms）：新滑动取消旧的，只在最后一页切换播放源
    private var settleWork: DispatchWorkItem?
    /// 停稳代际：每次 pageSettled/stop 递增，迟到的加载完成回调按代际丢弃
    private var settleGeneration = 0
    private var configured = false
    private var endToastShown = false

    init() {
        playback = DramaPlayerViewModel(playerService: playerService)
    }

    var seriesName: String { queue?.seriesName ?? "" }
    var intro: String? { queue?.intro }
    var tags: String? { queue?.tags }
    var totalEpisodes: Int { slots.count }

    func configure(request: ImmersivePlaybackRequest) {
        guard !configured else {
            print("PLAYER_DBG [VM] configure SKIP reason=alreadyConfigured series=\(request.seriesName)")
            return
        }
        configured = true
        // 防御性复位：VM 当前按容器生命周期每次新建，但若将来被复用，
        // 上一轮的「已到底」标记不得吞掉本轮的边界提示（评估报告 P2）
        endToastShown = false
        let q = PlaybackQueueService(request: request)
        queue = q
        slots = q.slots
        currentSort = q.current?.sort
        // 进入即预热首集 + 相邻集：与 150ms 停稳防抖并行，首次起播也走 HIT 路径
        if let current = q.current {
            let neighbors = q.neighbors(of: current.sort)
            playerService.preload([current] + neighbors)
            print("PLAYER_DBG [VM] preload entry sort=\(current.sort) neighbors=\(neighbors.map(\.sort))")
        }
        print("PLAYER_DBG [VM] configure series=\(request.seriesName) startSort=\(request.startSort) knownSorts=\(request.knownSorts.count) → slots=\(slots.count) sorts=\(slots.map(\.sort)) current=\(currentSort.map(String.init) ?? "nil")")
    }

    /// 滚动停稳防抖入口（View 的 onAppear/onChange 转发，替代旧 .task(id:) 自动取消）：
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
                // 占位卡已有内联提示，toast 补「去哪下载」的行动指引；优先于到底提示（更有信息量）
                self.showToast("第\(sort)集尚未下载 · 回剧集页下载后可看")
            } else if self.isLast(sort), !self.endToastShown {
                self.endToastShown = true
                self.showToast("已经到底了")
            }
        }
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

    /// 2 秒后自动消失（用户指定）。旧实现 `toastID == id` 在连续提示时可能让清除被跳过，
    /// 表现为 toast 一直挂着；改用「取消旧任务 + 令牌」，且不用 `guard !Task.isCancelled` ——
    /// 即使 sleep 被取消，只要仍是当前令牌就必须把文案清掉。
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

    func stop() {
        print("PLAYER_DBG [VM] stop current=\(currentSort.map(String.init) ?? "nil") slots=\(slots.count)")
        // 停稳防抖与在飞加载一并作废（等价旧 .task 随视图消失自动取消）
        settleWork?.cancel()
        settleWork = nil
        settleGeneration += 1
        // 退出播放页顺手清掉挂着的提示，避免下个页面复用时残留
        toastTask?.cancel()
        toastText = nil
        playback.stop()
        playerService.teardown()
    }
}
