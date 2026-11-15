import SwiftUI

/// 播放页容器：纵向翻页交给 UIKit 原生 `UIScrollView.isPagingEnabled`
/// （见 PlayerPagingScrollView），SwiftUI 侧只负责数据、当前页与停稳后切换播放源。
///
/// 叠层面板（倍速 / 选集）由本层承载而不是卡片内部：
/// 面板是整页级的浮层（清屏态的遮罩要盖住所有卡片），放卡片里会随分页滚走；
/// 卡片只发「请求打开」的意图，具体呈现与自己的状态归这里管。
struct PlayerFeedView: View {
    @ObservedObject var vm: PlayerFeedViewModel
    var onClose: () -> Void
    /// 当前页只由分页容器回写，避免与 VM 的 @Published 形成反馈环
    @State private var scrollID: Int?
    /// 竖屏浮层：倍速面板（画布只给了横屏抽屉，竖屏用居中墨本浮层——用户拍板）
    @State private var showRatePanel = false
    /// 竖屏浮层：选集面板（先做简单版，画布完整版 19:62 留待后续）
    @State private var showEpisodePanel = false

    var body: some View {
        Group {
            if vm.slots.isEmpty {
                emptyState
            } else {
                ZStack {
                    PlayerPagingScrollView(
                        slots: vm.slots,
                        currentSort: $scrollID,
                        playback: vm.playback,
                        vmCurrentSort: vm.currentSort,
                        isReady: vm.playbackReady,
                        activeToast: vm.toastText,
                        onEdgeBack: onClose,
                        onPullBeyondEnd: { vm.pulledBeyondEnd() },
                        makeCard: { slot in AnyView(card(for: slot)) }
                    )
                    .ignoresSafeArea()

                    // 叠层面板（盖在分页之上，禁掉下层手势）
                    overlays
                }
                // 停稳防抖收在 VM（schedulePageSettle）：快滑时旧 WorkItem 取消，
                // 只在最后一页切换播放源
                .onAppear { vm.schedulePageSettle(sort: scrollID) }
                .onChange(of: scrollID) { _, new in vm.schedulePageSettle(sort: new) }
                // slots 就绪后把 UIKit 分页定位到用户点的那一集（只做一次）
                .onChange(of: vm.slots.count, initial: true) { _, count in
                    print("PLAYER_DBG [FeedView] slotsCount=\(count) scrollID=\(scrollID.map(String.init) ?? "nil") vmCurrent=\(vm.currentSort.map(String.init) ?? "nil")")
                    guard count > 0, scrollID == nil else { return }
                    scrollID = vm.currentSort
                    print("PLAYER_DBG [FeedView] initial scrollID set=\(scrollID.map(String.init) ?? "nil")")
                }
                .onAppear {
                    print("PLAYER_DBG [FeedView] appear slots=\(vm.slots.count)")
                }
            }
        }
        .background(DWColor.background.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // 进后台是落库的关键时机之一（用户可能直接划掉 App，内存值不落盘就丢），
            // 同时记下播放意图：无 background audio 权限，进程挂起后播放器连接必断
            vm.playback.applicationDidEnterBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // 回前台恢复：本地回环服务可能已被系统回收、item 可能已 failed——
            // VM 判断需要时重启服务并重建 item（连接仍健康则只恢复播放，不打断画面）
            vm.playback.applicationWillEnterForeground()
        }
        #if DEBUG
        // 样张：竖屏两态（完整 / 清屏）与两个浮层的定帧入口，见 PlayerPreviewEntry.swift
        .onAppear {
            guard PlayerPreviewFlags.enabled else { return }
            print("PLAYER_DBG [Preview] vertical apply clean=\(PlayerPreviewFlags.cleanScreen) panel=\(PlayerPreviewFlags.verticalPanel ?? "nil")")
            // 显式双向赋值：清屏是持久化偏好，上一次样张（或用户）开过就会带进来，
            // 只写 true 不写 false 会让「完整态」样张永远截到清屏画面
            if vm.playback.isCleanScreen != PlayerPreviewFlags.cleanScreen {
                vm.playback.isCleanScreen = PlayerPreviewFlags.cleanScreen
            }
            // 浮层等一帧：slots/currentSort 先落定，面板里的「当前集」才对
            if let panel = PlayerPreviewFlags.verticalPanel {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if panel == "rate" { showRatePanel = true } else { showEpisodePanel = true }
                }
            }
        }
        // 全屏必须等 isReady：enterFullscreen 内部会拦「未就绪 + 竖屏片源」
        .onReceive(vm.playback.$isReady.removeDuplicates()) { ready in
            guard PlayerPreviewFlags.enabled, PlayerPreviewFlags.fullscreen, ready else { return }
            guard !Self.previewFullscreenFired else { return }
            Self.previewFullscreenFired = true
            print("PLAYER_DBG [Preview] ready → auto enterFullscreen")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                vm.playback.enterFullscreen(rotationAngle: .pi / 2)
            }
        }
        #endif
    }

    #if DEBUG
    /// 样张只进一次全屏（isReady 每次切集都会翻转，重复进会打架）
    private static var previewFullscreenFired = false
    #endif

    // MARK: - 叠层面板

    @ViewBuilder
    private var overlays: some View {
        ZStack {
            if showRatePanel {
                // 遮罩：点它关闭面板（不透传手势给下层，避免顺带暂停/翻页）
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { showRatePanel = false }
                    .transition(.opacity)

                PlaybackRatePanel(currentRate: vm.playback.playbackRate) { rate in
                    vm.playback.setPlaybackRate(rate)
                    showRatePanel = false
                    print("PLAYER_DBG [FeedView] rate panel select \(rate)× → close")
                }
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            }

            if showEpisodePanel {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { showEpisodePanel = false }
                    .transition(.opacity)
            }

            // 选集面板（2026-11-15 用户拍板）：高度 = 屏高 46.5%（原 62% 降 25%），
            // 出现 = 自底部弹出、消失 = 向底部缩短（由 BottomSheet 的贴底高度窗驱动）。
            // **面板本体常驻、只切高度**：用 `if` 插拔的话插入那一帧高度已是满值，
            // 展开动画会被整段吞掉（只剩遮罩淡入），这是原来「弹出感不明显」的原因。
            BottomSheet(isPresented: showEpisodePanel,
                        height: UIScreen.main.bounds.height * Self.episodePanelHeightRatio) {
                EpisodePanel(
                    total: currentEpisodeTotal,
                    current: currentEpisodeIndex,
                    onSelect: { index in
                        showEpisodePanel = false
                        jumpToEpisode(index)
                    },
                    onClose: { showEpisodePanel = false }
                )
            }
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(showEpisodePanel)
        }
        .animation(.easeInOut(duration: 0.22), value: showRatePanel)
        .animation(.easeInOut(duration: 0.26), value: showEpisodePanel)
    }

    /// 选集面板占屏高的比例（原 0.62，2026-11-15 用户要求降低 25% → 0.465）
    private static let episodePanelHeightRatio: CGFloat = 0.465

    /// 当前集的「第几集 / 共几集」：选集网格要用真实集号（槽位的 sort 就是集号）
    private var currentEpisodeIndex: Int {
        scrollID ?? vm.currentSort ?? 1
    }

    private var currentEpisodeTotal: Int {
        max(vm.totalEpisodes, 1)
    }

    /// 选集跳转：走既有分页管线，不自己加载。
    /// 复用 autoAdvanceSort 通道（Coordinator 订阅后动画翻页 → 停稳 → pageSettled
    /// → 预热池/autoplay 全套规则照旧生效），与「播完自动连播」同一条路，
    /// 避免另开一条「直接 load」的旁路造成两套加载语义。
    private func jumpToEpisode(_ index: Int) {
        guard index != currentEpisodeIndex else {
            print("PLAYER_DBG [FeedView] jump SKIP reason=sameEpisode sort=\(index)")
            return
        }
        guard vm.slots.contains(where: { $0.sort == index }) else {
            print("PLAYER_DBG [FeedView] jump SKIP reason=noSlot sort=\(index)")
            return
        }
        print("PLAYER_DBG [FeedView] jump sort=\(index) via autoAdvanceSort")
        vm.playback.autoAdvanceSort = index
    }

    @ViewBuilder
    private func card(for slot: PlayableEpisode) -> some View {
        DramaPlayerView(
            episode: .local(seriesName: vm.seriesName,
                            intro: vm.intro,
                            tags: vm.tags,
                            index: slot.sort,
                            total: vm.totalEpisodes),
            playback: vm.playback,
            isActive: vm.currentSort == slot.sort,
            onClose: onClose,
            hasNextEpisode: vm.hasNext(after: slot.sort),
            isEpisodeAvailable: slot.isAvailable,
            nextEpisodeAvailable: vm.nextIsAvailable(after: slot.sort),
            toastText: vm.currentSort == slot.sort ? vm.toastText : nil,
            onRequestRatePanel: {
                print("PLAYER_DBG [FeedView] open rate panel rate=\(vm.playback.playbackRate)×")
                showEpisodePanel = false
                showRatePanel = true
            },
            onRequestEpisodePanel: {
                print("PLAYER_DBG [FeedView] open episode panel current=\(currentEpisodeIndex)")
                showRatePanel = false
                showEpisodePanel = true
            }
        )
    }

    private var emptyState: some View {
        ZStack {
            DWColor.background.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "film")
                    .font(.largeTitle)
                    .foregroundStyle(DWColor.textHint)
                Text("没有可播放的剧集")
                    .font(DWFont.cn(13))
                    .foregroundStyle(DWColor.textBody)
                Button("返回") { onClose() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
