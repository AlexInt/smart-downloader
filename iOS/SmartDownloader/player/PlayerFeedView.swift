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
    /// 竖屏浮层：倍速面板（2026-11-15 起与选集面板同一个半屏 BottomSheet）
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

                    // ── 顶部悬浮条（2026-11-16 用户拍板：顶栏固定不随卡片滚动，
                    //    停稳后数据换当前集；返回/标题/倍速/更多四件从卡片抽离，
                    //    画布坐标与卡片 designOverlay 同源 390×840 contain） ──
                    GeometryReader { geo in
                        topBar
                            .frame(width: DWLayout.designWidth, height: DWLayout.designHeight)
                            .scaleEffect(min(geo.size.width / DWLayout.designWidth,
                                             geo.size.height / DWLayout.designHeight))
                            .frame(width: geo.size.width, height: geo.size.height)
                    }

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

    private var overlays: some View {
        // 弹层高度按容器现量（不要 UIScreen.main：iOS 26 起 deprecated）。
        // 这一层整体 ignoresSafeArea → geo.size 就是整屏，比例才与画布口径一致
        GeometryReader { geo in
            overlaysContent(sheetHeight: geo.size.height * Self.sheetHeightRatio)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func overlaysContent(sheetHeight: CGFloat) -> some View {
        ZStack {
            // 遮罩（两个弹层共用）：点面板外的画面关掉面板，不把这一下透传给下层
            // （否则关面板会顺带暂停/翻页）
            if showRatePanel || showEpisodePanel {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if showRatePanel { showRatePanel = false }
                        if showEpisodePanel { showEpisodePanel = false }
                    }
                    .transition(.opacity)
            }

            // 倍速面板（2026-11-15 用户要求「拉起半屏」）：与选集面板同一个 BottomSheet，
            // 档位与全屏抽屉同源。原先是 300 宽的居中浮层。
            BottomSheet(isPresented: showRatePanel, height: sheetHeight) {
                PlaybackRateSheet(
                    currentRate: vm.playback.playbackRate,
                    onSelect: { rate in
                        vm.playback.setPlaybackRate(rate)
                        showRatePanel = false
                        print("PLAYER_DBG [FeedView] rate sheet select \(rate)× → close")
                    },
                    onClose: { showRatePanel = false }
                )
            }
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(showRatePanel)

            // 选集面板（2026-11-15 用户拍板）：高度 = 屏高 46.5%（原 62% 降 25%），
            // 出现 = 自底部弹出、消失 = 向底部缩短（由 BottomSheet 的贴底高度窗驱动）。
            // **面板本体常驻、只切高度**：用 `if` 插拔的话插入那一帧高度已是满值，
            // 展开动画会被整段吞掉（只剩遮罩淡入），这是原来「弹出感不明显」的原因。
            BottomSheet(isPresented: showEpisodePanel, height: sheetHeight) {
                EpisodePanel(
                    items: vm.episodeItems,
                    current: currentEpisodeIndex,
                    hint: vm.episodeHint,
                    onSelect: { sort in
                        // 点按收口在 VM：先对账磁盘，已下载 → 切集播放；未下载 → 入队下载。
                        // 只有真的切了集才收起面板（下载中留着看进度环与提示）
                        let switched = vm.selectEpisode(sort: sort)
                        print("PLAYER_DBG [FeedView] panel select sort=\(sort) switched=\(switched) → \(switched ? "close" : "keepOpen")")
                        if switched { showEpisodePanel = false }
                    },
                    onClose: { showEpisodePanel = false }
                )
            }
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(showEpisodePanel)
        }
        .animation(.easeInOut(duration: 0.26), value: showRatePanel)
        .animation(.easeInOut(duration: 0.26), value: showEpisodePanel)
    }

    /// 底部弹层占屏高的比例（原选集面板 0.62，2026-11-15 用户要求降低 25% → 0.465；
    /// 倍速改用同一容器后沿用同一比例，「拉起半屏」观感一致）
    private static let sheetHeightRatio: CGFloat = 0.465

    /// 当前集号：选集网格的「当前集」高亮要用真实集号（槽位的 sort 就是集号）
    private var currentEpisodeIndex: Int {
        scrollID ?? vm.currentSort ?? vm.episodeItems.first?.sort ?? 1
    }

    // MARK: - 顶部悬浮条（2026-11-16 从卡片 DramaPlayerView 抽离：顶栏固定不随卡片滚，
    //    停稳后数据换当前集；清屏态常驻语义与原卡片一致。画布坐标同源，勿另造一套）

    private var topBar: some View {
        ZStack(alignment: .topLeading) {
            backButton
                .designFrame(16, 70, 22, 22)
            Text(topTitle)
                .font(DWFont.serif(15, .medium))
                .foregroundStyle(DWColor.overlayInk)
                .lineLimit(1)
                .designFrame(44, 71, 220, 22, alignment: .leading)
                .allowsHitTesting(false)
            rateButton
                .designFrame(272, 68, 54, 26)
            moreButton
                .designFrame(344, 72, 20, 20)
        }
    }

    /// 顶部标题：剧集名 + 第n集（格式与全屏控制层 updateTitle 逐字一致，勿两处分叉）
    private var topTitle: String {
        let name = vm.seriesName.isEmpty ? "" : "\(vm.seriesName)  "
        return "\(name)第\(currentEpisodeIndex)集"
    }

    private var backButton: some View {
        Button { onClose() } label: {
            Image("ic_back")
                .renderingMode(.template)
                .resizable().scaledToFit()
                .foregroundStyle(DWColor.overlayInk)
                .frame(width: 13, height: 13)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回")
    }

    /// 倍速（画布 2:94：54×26，表盘 + 「倍速」12px 纸白）。点按打开倍速面板；
    /// 悬浮条本身就是当前页，不再需要卡片的 isActive 守卫
    private var rateButton: some View {
        Button {
            print("PLAYER_DBG [CHECK] rate button tap → open rate panel rate=\(vm.playback.playbackRate)×")
            showEpisodePanel = false
            showRatePanel = true
        } label: {
            HStack(spacing: 5) {
                OverlayRateGlyph(size: 16, color: DWColor.overlayInk)
                Text(vm.playback.playbackRate == 1.0 ? "倍速" : vm.playback.rateShortText)
                    .font(DWFont.cn(12, .regular))
                    .foregroundStyle(DWColor.overlayInk)
                    .lineLimit(1)
            }
            .frame(width: 54, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("倍速，当前 \(vm.playback.playbackRateText) 倍速")
    }

    /// 更多（画布 2:99：20×20 三点）。清屏入口已在右下角常驻，这里收容「从头播放」
    /// 等补充操作；静音项与右下角静音钮同一状态源（vm.playback.isMuted）
    private var moreButton: some View {
        Menu {
            Button {
                vm.playback.seek(fraction: 0)
                print("PLAYER_DBG [CHECK] more menu → replay from start")
            } label: {
                Label("从头播放", systemImage: "arrow.counterclockwise")
            }
            Button {
                vm.playback.isCleanScreen = true
            } label: {
                Label("清屏模式", systemImage: "rectangle.dashed")
            }
            Button {
                vm.playback.isMuted.toggle()
            } label: {
                Label(vm.playback.isMuted ? "取消静音" : "静音", systemImage: vm.playback.isMuted ? "speaker.slash" : "speaker")
            }
        } label: {
            OverlayMoreGlyph(size: CGSize(width: 20, height: 20), color: DWColor.overlayInk)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多")
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
            hasNextEpisode: vm.hasNext(after: slot.sort),
            isEpisodeAvailable: slot.isAvailable,
            nextEpisodeAvailable: vm.nextIsAvailable(after: slot.sort),
            toastText: vm.currentSort == slot.sort ? vm.toastText : nil,
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
