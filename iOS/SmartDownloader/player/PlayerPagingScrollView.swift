import SwiftUI
import UIKit
import AVFoundation
import Combine

/// UIKit 原生纵向分页容器（ZFPlayer / 开源抖音实践）。
/// `UIScrollView.isPagingEnabled` 由 UIKit 独占 pan。
///
/// 卡片是 UIHostingController.rootView，只在 `refreshCards` 时重设；
/// 因此当前页 **与** 播放就绪状态任一变化都必须刷新，否则视频层会一直被
/// `opacity(isActive && isReady ? 1 : 0)` 藏在渐变后面（播放器在播但画面不显示）。
/// toast 文案同理：它按值快照传入卡片（不随 playback 观察），变化时也必须刷新，
/// 否则 dismiss 置 nil 后卡片不重绘，toast 永远收不回（老 bug 根因）。
struct PlayerPagingScrollView: UIViewRepresentable {
    let slots: [PlayableEpisode]
    @Binding var currentSort: Int?
    let playback: DramaPlayerViewModel
    let vmCurrentSort: Int?
    /// 播放是否就绪：变化时需要刷新卡片 rootView
    let isReady: Bool
    /// 当前页 toast 文案：变化时同样需要刷新卡片 rootView（toast 按值传入卡片）
    let activeToast: String?
    /// 左缘右滑返回（fullScreenCover 没有系统边缘返回，自己补）
    var onEdgeBack: () -> Void = {}
    /// 末页再往下滑一格（想看下一集但已无资源、翻不出去）——边界提示的触发点
    ///（用户拍板 2026-11-14：停稳末页不提示，滑出未果才提示）
    /// 左缘返回跟手位移（已退役 2026-11-16）：用户实评「播放器是从底部弹出来的，
    /// 不是从右向左的」——横向跟手与呈现轴错位，且工程量不值。恢复简单版：
    /// 拖过阈值立即触发 onEdgeBack（dismiss 走系统自带的下滑消失动画，方向正确）
    var onPullBeyondEnd: () -> Void = {}
    let makeCard: (PlayableEpisode) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PagingScrollView {
        let scroll = PagingScrollView()
        scroll.isPagingEnabled = true
        scroll.showsVerticalScrollIndicator = false
        // 背景墨色（与加载渐变底 videoBottom/background 同色）：2026-11-16 起 surface
        // 只铺到选集区顶部（画面与选集区上下排布，见 updateSurfaceContainer），底部带
        // 靠这里垫墨，全屏宽、翻页连续；曾经 .clear 是因为 surface 铺满整页看不到它
        scroll.backgroundColor = UIColor(DWColor.background)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = context.coordinator
        scroll.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.layoutPages(in: scroll)
        }
        print("PLAYER_DBG [UIScroll] makeUIView paging=\(scroll.isPagingEnabled) interaction=\(scroll.isUserInteractionEnabled)")

        // 只挂「连续」手势：水平 seek 与左缘返回必须与系统分页 pan 共存，所以留在 UIKit 层。
        // 点按暂停 / 长按倍速是离散手势，已放回卡片内用 SwiftUI 手势（深度优先解析，
        // Button 天然优先于卡片手势，点控件不连带暂停，无需控件区判定表）。
        let seekPan = UIPanGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.didSeekPan(_:)))
        seekPan.cancelsTouchesInView = false
        seekPan.delegate = context.coordinator
        scroll.addGestureRecognizer(seekPan)
        context.coordinator.seekPan = seekPan

        // 左缘右滑返回：fullScreenCover 不带系统边缘返回手势，自己补一个
        let edgePan = UIScreenEdgePanGestureRecognizer(target: context.coordinator,
                                                       action: #selector(Coordinator.didEdgePan(_:)))
        edgePan.edges = .left
        edgePan.cancelsTouchesInView = false
        edgePan.delegate = context.coordinator
        scroll.addGestureRecognizer(edgePan)
        context.coordinator.edgePan = edgePan
        print("PLAYER_DBG [CHECK] gestures installed count=\(scroll.gestureRecognizers?.count ?? 0)")

        // 视频承载容器（单例）：唯一视频子层宿主，z 序在全部卡片之下（卡片视频区透明），
        // frame 对位活跃卡（内容坐标）——滚动/翻页时视频随内容移动，卡片不再各自持有 surface。
        let surface = PlayerSurfaceUIView()
        surface.player = playback.player
        surface.videoGravity = Self.videoGravity(for: playback)
        surface.backgroundColor = .clear
        surface.isUserInteractionEnabled = false
        scroll.insertSubview(surface, at: 0)
        context.coordinator.surfaceView = surface
        // 首显机制：进页/切集时条带先藏（渐变盖着，用户不可见），ready 后延迟 150ms 淡入
        //（与卡片渐变淡出错开，消「渐变退了底下还是黑的、条带啪地出现」）
        surface.concealForReveal()
        // gravity 即时跟随片源方向：不等下一次 SwiftUI update——ready 翻转后首帧可能
        // 先于 update 提交渲染，fill→fit 跳变即「刚进竖屏画面抖一下」。
        // @Published 在赋值调用栈内同步发出，直接 sink 当场落 gravity，早于任何渲染提交
        //（注意用 sink 参数而不是读属性：@Published 发出时属性还是旧值）
        context.coordinator.gravityCancellable = playback.$videoIsLandscape
            .sink { [weak surface] landscape in
                surface?.videoGravity = landscape ? .resizeAspect : .resizeAspectFill
            }
        // 画面适配按钮（画布 19:37）：用户手动切了 自动/完整/铺满 时立即重落 gravity，
        // 与片源方向同一即时通道（不等 SwiftUI update，避免按钮点了画面不动）
        context.coordinator.fitModeCancellable = playback.$videoFitMode
            .sink { [weak surface, weak playback] _ in
                guard let playback else { return }
                surface?.videoGravity = playback.effectiveVideoGravity
            }
        // isReady 订阅：翻转 false（新一集开始）藏住条带；翻转 true（item ready）延迟 150ms
        // 淡入——与卡片渐变淡出错开，交叉过渡无黑屏空档（渐变退完前条带已在淡入）
        context.coordinator.readyCancellable = playback.$isReady
            .removeDuplicates()
            .sink { [weak surface, weak playback] ready in
                if ready {
                    surface?.scheduleVideoReveal()
                } else {
                    // 全屏时把切集冻帧一并递过去（无图走原路径）：全屏没有卡片渐变兜底
                    surface?.concealForReveal(freezeFrame: playback?.freezeFrameImage)
                }
            }
        // 冻帧兜底释放：加载失败/无资源时 VM 把 freezeFrameImage 置 nil（不会有 ready），
        // 冻帧不能继续盖着旧画面。非 nil 变化不在这里处理 —— 挂载由 isReady=false 那条链走
        context.coordinator.freezeCancellable = playback.$freezeFrameImage
            .removeDuplicates()
            .dropFirst()
            .sink { [weak surface] image in
                guard image == nil else { return }
                surface?.releaseFreezeFrame(reason: "cleared")
            }
        // 自动连播：单集播完 → FeedVM 置 autoAdvanceSort → 这里动画滚到下一页并把信号
        // 置回 nil。翻页后的 currentSort 回写靠 scrollViewDidEndScrollingAnimation → report
        // → scrollID → schedulePageSettle → pageSettled（预热池/autoplay 全复用既有管线）。
        // 用户触摸打断动画则走 didEndDragging 既有管线接管，本 sink 不再干预
        context.coordinator.autoAdvanceCancellable = playback.$autoAdvanceSort
            .removeDuplicates()
            .sink { [weak coordinator = context.coordinator, weak scroll] sort in
                guard let coordinator, let scroll, let sort else { return }
                print("PLAYER_DBG [CHECK] autoAdvance consume sort=\(sort)")
                coordinator.scrollToSort(sort, in: scroll, animated: true, reason: "autoAdvance")
                coordinator.parent.playback.autoAdvanceSort = nil
            }
        // 全屏控制器：订阅 isFullscreen，容器 transform 自转（锁竖屏下的全屏实现）
        context.coordinator.fullscreenController = PlayerFullscreenController(playback: playback, surface: surface)
        print("PLAYER_DBG [UIScroll] fullscreen controller installed surface=\(surface.bounds)")
        #if DEBUG
        // 冻帧样张（`-playerFreezePreview`）：全屏后手动挂一次冻帧，看它铺得对不对。
        // 模拟器无法点选集切集，只能定点验证这一层；6s 看门狗会自己放掉
        if PlayerPreviewFlags.enabled, PlayerPreviewFlags.freezePreview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak surface, weak playback] in
                guard let surface, let playback else { return }
                let image = playback.debugFreezeSnapshot()
                print("PLAYER_DBG [Preview] freezePreview hold size=\(image?.size ?? .zero) fullscreen=\(playback.isFullscreen)")
                surface.holdFreezeFrame(image)
            }
        }
        #endif
        return scroll
    }

    func updateUIView(_ scroll: PagingScrollView, context: Context) {
        context.coordinator.parent = self
        print("PLAYER_DBG [CHECK] update binding=\(currentSort.map(String.init) ?? "nil") vm=\(vmCurrentSort.map(String.init) ?? "nil") isReady=\(isReady) slots=\(slots.count)")
        context.coordinator.rebuildIfNeeded(in: scroll)
        context.coordinator.refreshCardsIfNeeded()
        context.coordinator.applyStartOffsetIfNeeded(in: scroll)
        context.coordinator.updateSurfaceContainer(in: scroll)
    }

    static func dismantleUIView(_ uiView: PagingScrollView, coordinator: Coordinator) {
        // 播放页销毁：全屏容器挂在 keyWindow 上，必须显式还原，否则泄漏在 window 上
        print("PERF_DBG exit t=\(PERF.ms()) phase=pagingDismantle begin")
        // 兜底恢复系统 pan：手势若走异常路径（如视图被中途移除收不到结束回调）
        // 漏了 unlock，也不能把「系统 pan 被禁」带出本页面
        coordinator.unlockSystemPan(uiView, reason: "dismantle")
        coordinator.fullscreenController?.teardown()
        coordinator.gravityCancellable = nil
        coordinator.readyCancellable = nil
        coordinator.autoAdvanceCancellable = nil
        coordinator.freezeCancellable = nil
        coordinator.surfaceView?.stopRevealProbe(reason: "dismantle")
        print("PERF_DBG exit t=\(PERF.ms()) phase=pagingDismantle done")
    }

    /// 渲染 gravity：横屏片源完整显示（fit）、竖屏片源拉满（fill）。App 已锁竖屏，
    /// 不再随持屏方向切换（旧 fit↔fill 二值跳变即「中间条突变全屏」的根因）。
    /// presentationSize 未知（0×0）时 videoIsLandscape=false，按竖屏 fill 处理。
    /// 画面适配按钮（画布 19:37）的覆盖口径统一由 VM.effectiveVideoGravity 给。
    static func videoGravity(for playback: DramaPlayerViewModel) -> AVLayerVideoGravity {
        playback.effectiveVideoGravity
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: PlayerPagingScrollView
        var seekPan: UIPanGestureRecognizer?
        var edgePan: UIScreenEdgePanGestureRecognizer?
        private var builtSorts: [Int] = []
        private var hosts: [Int: UIHostingController<AnyView>] = [:]
        private var startApplied = false
        private var lastRefreshedSort: Int?
        private var lastRefreshedReady: Bool?
        private var lastRefreshedToast: String?
        /// 槽位可用性指纹（sort:isAvailable 列表）：播放中下载完成会把占位页变成可播卡，
        /// 但 currentSort/isReady/toast 都可能不变 —— 不跟踪这个维度，卡片永远不重绘（真机实证）
        private var lastRefreshedSlotsKey = ""
        private var lastLoggedY: CGFloat = -999
        /// 上次实际布局过的几何 key：几何没变时 layoutPages 幂等跳过（防布局回环）
        private var lastLaidSizeKey = ""
        /// 视频承载容器（唯一视频子层宿主），makeUIView 创建、z 序在卡片之下
        var surfaceView: PlayerSurfaceUIView?
        /// 全屏控制器（容器 transform 自转 + isFullscreen 订阅），随滚动层销毁时 teardown
        var fullscreenController: PlayerFullscreenController?
        /// 片源方向 → surface gravity 的即时订阅（不等 SwiftUI update，防 fill→fit 首帧跳变）
        var gravityCancellable: AnyCancellable?
        /// isReady → 视频条带延迟首显（与卡片渐变淡出错开，防黑屏空档/突现）
        var readyCancellable: AnyCancellable?
        /// 画面适配（自动/完整/铺满）→ 立即重落 videoGravity
        var fitModeCancellable: AnyCancellable?
        /// 自动连播：playback.autoAdvanceSort → 动画滚动到下一页（信号消费后置回 nil）
        var autoAdvanceCancellable: AnyCancellable?
        /// 切集冻帧被丢弃（加载失败/无资源）→ 立刻放掉冻帧层
        var freezeCancellable: AnyCancellable?
        private var lastPendingReason = ""
        private var lastLoggedSeek: Double = -1
        /// 本次拖拽的 scrub 基准进度（.began 时捕获当前播放进度；左缘起手为 nil = 不 seek）
        private var scrubBaseFraction: Double?
        private var edgeDragStarted = false
        /// 横向手势独占期间系统分页 pan 的锁定标志：幂等开关，防重复禁用/漏恢复
        ///（seekPan 与 edgePan 都会 lock，两者结束顺序不定，unlock 幂等保护）
        private var systemPanLocked = false

        init(_ parent: PlayerPagingScrollView) {
            self.parent = parent
        }

        // MARK: 离散手势

        // 点按暂停 / 长按倍速已移回卡片内 SwiftUI 手势（见 DramaPlayerView body 末尾），
        // 这里不再挂 UITapGestureRecognizer / UILongPressGestureRecognizer。

        // MARK: 系统 pan 独占（横滑上下晃动修复 2026-11-14）

        /// 横向手势（seekPan / edgePan）起手时独占本次触摸：禁用系统分页 pan。
        /// 根因：横滑时人手必有纵向分量，系统 pan 对纵向可滚方向启动阈值极低（几 pt），
        /// 一旦 begin 即锁纵向驱动 contentOffset —— 横滑全程页面跟着手的 y 分量上下晃
        ///（用户实报「每次左右滑动都会上下晃动」）；y 累计 >15% 屏高或松手 velocity.y>0.3
        /// 还会被 scrollViewWillEndDragging 误判翻页。纵向滑动不受影响：seekPan 被
        /// 方向过滤拒绝（shouldBegin），系统 pan 独占切集。「先起者独占本次触摸」
        /// 从 2x↔seek 延伸到 seek↔scroll（同一仲裁哲学）。恢复时机：横向手势
        /// 全部结束分支 + dismantle 兜底。
        private func lockSystemPan(in scroll: UIScrollView, reason: String) {
            guard !systemPanLocked else {
                print("PLAYER_DBG [CHECK] panLock SKIP reason=alreadyLocked by=\(reason)")
                return
            }
            systemPanLocked = true
            scroll.panGestureRecognizer.isEnabled = false
            // 系统 pan 启动阈值更低，常在 seekPan .began（~10pt）之前抢先 begin 并拖走
            // 纵向位移——禁用即 cancel 它，随后立即归位当前页，消掉起手瞬间的弹跳。
            // 归位目标用 currentSort 对应页而非 round(y/h)：滚动 delegate 已被禁，
            // round 出的页可能与实际活跃页不一致
            realignToCurrentPage(in: scroll)
            print("PLAYER_DBG [CHECK] panLock ON by=\(reason) y=\(Int(scroll.contentOffset.y))")
        }

        func unlockSystemPan(_ scroll: UIScrollView, reason: String) {
            guard systemPanLocked else { return }
            systemPanLocked = false
            scroll.panGestureRecognizer.isEnabled = true
            print("PLAYER_DBG [CHECK] panLock OFF by=\(reason) y=\(Int(scroll.contentOffset.y))")
        }

        /// 左缘右滑返回：拖过 50pt 即触发（不必等抬手），每次手势只触发一次。
        /// 2026-11-16 回退到简单版：跟手平移被否（呈现轴是纵向、退出动画本就是
        /// 系统下滑消失），阈值触发即退最直接
        @objc func didEdgePan(_ pan: UIScreenEdgePanGestureRecognizer) {
            guard let view = pan.view else { return }
            switch pan.state {
            case .began:
                edgeBackFired = false
                // 左缘起手同样独占本次触摸：横滑返回期间系统 pan 的纵向响应同样会让页面上下晃
                if let scroll = view as? UIScrollView { lockSystemPan(in: scroll, reason: "edgePan") }
                print("PLAYER_DBG [CHECK] edgePan began")
            case .changed:
                guard !edgeBackFired else { return }
                let dx = pan.translation(in: view).x
                if dx > 50 {
                    edgeBackFired = true
                    print("PLAYER_DBG [CHECK] edgePan dx=\(Int(dx)) > 50 → back")
                    parent.onEdgeBack()
                }
            case .ended, .cancelled, .failed:
                // 结束分支必须恢复系统 pan：漏恢复 = 播放页永久无法滑动（泄漏 lock）
                if let scroll = view as? UIScrollView { unlockSystemPan(scroll, reason: "edgePan") }
            default: break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // seekPan / edgePan 都要能与系统滚动 pan 共存
            gestureRecognizer === seekPan || other === seekPan
                || gestureRecognizer === edgePan || other === edgePan
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // seekPan 只认横向主导滑动：纵向 / 45°（x≤y）直接拒绝，交给分页滚动。
            // 若不加此方向过滤，seekPan 不限方向、竖滑也 began（cancelsTouchesInView=false）→ 搅乱滚动
            // 对触摸的取消 → 卡片点按手势未被干净取消 → 抬手误判 TAP → 暂停（真机日志实证）。
            // 45°（x==y）交给系统 pan：纵向分量显著，切集更符合意图；起手后转水平的快滑
            // 不受影响——.began 的 panLock 会 cancel 系统 pan 并归位，seekPan 自己累计的
            // 位移在 x>y 的那一刻照样 begin（先起者独占的系统侧抢占）。
            guard gestureRecognizer === seekPan,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let t = pan.translation(in: pan.view)
            return abs(t.x) > abs(t.y)
        }

        @objc func didSeekPan(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view as? UIScrollView else { return }
            switch pan.state {
            case .began:
                // 横向主导起手即独占本次触摸：禁用系统分页 pan（横滑上下晃动修复）。
                // 放 .began 而非 shouldBegin：此刻系统 pan 即便已 begin 也只拖走极小
                // 位移，realign 归位后视觉几乎无感
                lockSystemPan(in: view, reason: "seekPan")
                // 起手（约 10pt 位移）即判「拖动先起」，立刻翻转仲裁闸门（VM.beginSeekGesture）。
                // 不能等 .changed 攒够「水平主导 + dx>6」才置位：斜起手快速转水平的快滑、
                // 清屏下的横滑，都会给长按 0.15s 的 perform 留出插空窗误起 2x（闪倍速提示）。
                // 慢漂移（走 10pt 超过 0.15s）仍长按先起，2x 不受影响。
                // 捕获 scrub 基准：相对映射（拖动位移/屏宽 = 进度增量，一屏宽≈全片时长），
                // 起点无关 —— 横向 seek 全屏有效，无命中带（2026-11-11 用户拍板方案 A）。
                // 左缘 30pt 保留给返回手势（edgePan），从那里起手不 seek。
                let x = pan.location(in: view).x
                if x < 30 {
                    scrubBaseFraction = nil
                    print("PLAYER_DBG [CHECK] seekPan began x=\(Int(x)) reason=leftEdgeGuard → no scrub")
                } else {
                    scrubBaseFraction = parent.playback.progress
                    print("PLAYER_DBG [CHECK] seekPan began x=\(Int(x)) scrubBase=\(String(format: "%.2f", scrubBaseFraction ?? 0))")
                }
                parent.playback.beginSeekGesture()
            case .changed:
                let t = pan.translation(in: view)
                guard abs(t.x) > abs(t.y), abs(t.x) > 6 else { return }
                guard let base = scrubBaseFraction else { return }
                let fraction = min(max(base + PlayerGesturePolicy.scrubDelta(translationX: t.x, screenWidth: view.bounds.width), 0), 1)
                if abs(fraction - lastLoggedSeek) > 0.05 {
                    lastLoggedSeek = fraction
                    print("PLAYER_DBG [CHECK] seekPan dx=\(Int(t.x)) dy=\(Int(t.y)) fraction=\(String(format: "%.2f", fraction)) base=\(String(format: "%.2f", base))")
                }
                // 2026-11-16 手势 A 档：拖动中不实时 seek（行业全如此），只挂目标预览；
                // 松手才真正 seek（commitScrubThenEndGesture），拖动中目标时间由
                // HUD 上的气泡跟随（DramaPlayerView.progressHud）
                parent.playback.scrubPreview(fraction: fraction)
            case .ended, .cancelled, .failed:
                // 结束分支分两路（2026-11-16 手势 A 档）：.ended 提交暂存目标（seek 落稳
                // 后 flush 进度）；.cancelled/.failed 只丢弃不 seek（切集/来电打断）。
                // 旧注释「抬手不补 seek」对应的实时 seek 路线已退役——现在抬手恰恰
                // 是唯一一次 seek，且不再有「2x 抬手清 isFastForwarding → .ended 的
                // seek 穿过闸门」的竞态：2x 独占期间预览根本不置位（scrubPreview guard）。
                scrubBaseFraction = nil
                if pan.state == .ended {
                    parent.playback.commitScrubThenEndGesture()
                } else {
                    parent.playback.cancelScrubThenEndGesture()
                }
                unlockSystemPan(view, reason: "seekPan")
            default: break
            }
        }

        // MARK: 页面管理

        func refreshCardsIfNeeded() {
            let slotsKey = parent.slots.map { "\($0.sort):\($0.isAvailable ? 1 : 0)" }.joined(separator: ",")
            let changed = lastRefreshedSort != parent.currentSort
                || lastRefreshedReady != parent.isReady
                || lastRefreshedToast != parent.activeToast
                || lastRefreshedSlotsKey != slotsKey
            guard !hosts.isEmpty, changed else { return }
            lastRefreshedSort = parent.currentSort
            lastRefreshedReady = parent.isReady
            lastRefreshedToast = parent.activeToast
            lastRefreshedSlotsKey = slotsKey
            let current = parent.currentSort
            for slot in parent.slots {
                hosts[slot.sort]?.rootView = parent.makeCard(slot)
            }
            print("PLAYER_DBG [CHECK] refreshCards current=\(current.map(String.init) ?? "nil") isReady=\(parent.isReady) toast=\(parent.activeToast ?? "nil") activeHost=\(current.flatMap { hosts[$0] } != nil)")
        }

        func rebuildIfNeeded(in scroll: PagingScrollView) {
            let sorts = parent.slots.map(\.sort)
            guard sorts != builtSorts else { return }
            builtSorts = sorts
            startApplied = false
            lastRefreshedSort = nil
            lastRefreshedReady = nil
            lastRefreshedToast = nil
            lastRefreshedSlotsKey = ""
            lastPendingReason = ""
            lastLaidSizeKey = ""   // 强制下方的 layoutPages 真正落 frame（新 host 还没排过）
            print("PLAYER_DBG [CHECK] rebuild sorts=\(sorts) count=\(sorts.count)")

            hosts.values.forEach { $0.view.removeFromSuperview() }
            hosts.removeAll()
            for slot in parent.slots {
                let host = UIHostingController(rootView: parent.makeCard(slot))
                host.view.backgroundColor = .clear
                scroll.addSubview(host.view)
                hosts[slot.sort] = host
            }
            layoutPages(in: scroll)
        }

        func layoutPages(in scroll: PagingScrollView) {
            let width = scroll.bounds.width
            let height = scroll.bounds.height
            let sizeKey = "\(Int(width))x\(Int(height))x\(parent.slots.count)"
            let geometryChanged = sizeKey != lastLaidSizeKey
            guard width > 0, height > 0 else {
                if geometryChanged {
                    lastLaidSizeKey = sizeKey
                    print("PLAYER_DBG [CHECK] layout SKIPPED zero bounds=\(width)x\(height)")
                }
                return
            }
            // 几何没变就不重写：layoutSubviews 每个布局 pass 都进来，旧实现无条件重写全部
            // 页面 frame + contentSize——布局过程中改自身可滚动属性会再触发一轮布局，
            // 旋转后与 SwiftUI 桥接的布局回合互相踢（真机实证 bounds 在 402x874 ↔ 874x402
            // 每 ~2s 振荡）。幂等化斩断这条反馈腿。
            guard geometryChanged else { return }
            lastLaidSizeKey = sizeKey
            for (index, slot) in parent.slots.enumerated() {
                hosts[slot.sort]?.view.frame =
                    CGRect(x: 0, y: CGFloat(index) * height, width: width, height: height)
            }
            scroll.contentSize = CGSize(width: width,
                                        height: height * CGFloat(parent.slots.count))
            let first = hosts[parent.slots.first?.sort ?? -1]?.view.frame ?? .zero
            let last = hosts[parent.slots.last?.sort ?? -1]?.view.frame ?? .zero
            print("PLAYER_DBG [CHECK] layout bounds=\(width)x\(height) contentSize=\(scroll.contentSize) firstFrame=\(first) lastFrame=\(last)")
            // 几何变化（App 已锁竖屏，正常只剩首次布局）后把当前页顶对齐视口兜底；
            // 一次性首屏定位仍走 applyStartOffsetIfNeeded。
            realignToCurrentPage(in: scroll)
            updateSurfaceContainer(in: scroll)
        }

        /// 视频容器对位活跃卡 + gravity 跟随片源方向（updateUIView 与几何变化后都会调）。
        /// 2026-11-16 布局改版：画面只铺到**选集胶囊顶部**（画布 y=770），底部带（70 画布
        /// 单位）独立墨色 —— 画面与选集区上下排布，不再铺到屏幕底（用户实报「画面底部拉到
        /// 屏幕底部」）。胶囊 y 在 DramaPlayerView 画布里，胶囊挪位这里要跟。
        /// 画布纵向居中（scaleEffect 默认 center）：带顶屏幕 y = (页高−840×scale)/2 + 770×scale。
        /// 全屏不受影响：videoLayer 搬运的「视频显示带」基于 surface bounds，自动适配。
        func updateSurfaceContainer(in scroll: PagingScrollView) {
            guard let surface = surfaceView else { return }
            surface.videoGravity = PlayerPagingScrollView.videoGravity(for: parent.playback)
            let width = scroll.bounds.width
            let height = scroll.bounds.height
            guard width > 0, height > 0, let current = parent.currentSort,
                  let index = parent.slots.firstIndex(where: { $0.sort == current }) else { return }
            let frame = CGRect(x: 0, y: CGFloat(index) * height, width: width, height: Self.surfaceHeight(in: scroll))
            if surface.frame != frame {
                print("PLAYER_DBG [CHECK] surface frame → \(frame)")
                surface.frame = frame
            }
        }

    /// 画面区高度（页内）：选集胶囊顶部（画布 y=770）以上 + 画布纵向居中偏移。
    static func surfaceHeight(in scroll: UIScrollView) -> CGFloat {
        surfaceHeight(width: scroll.bounds.width, height: scroll.bounds.height)
    }

    /// 画面区高度（页内）：选集胶囊顶部（画布 y=770）以上 + 画布纵向居中偏移。
    /// 纯函数版供 DramaPlayerView 的全屏按钮定位共用（同口径，勿复制公式）
    static func surfaceHeight(width: CGFloat, height: CGFloat) -> CGFloat {
        guard width > 0, height > 0 else { return height }
        let scale = min(width / DWLayout.designWidth, height / DWLayout.designHeight)
        let canvasTop = (height - DWLayout.designHeight * scale) / 2
        return canvasTop + 770 * scale
    }

        /// 几何变化后把 currentSort 那一页同步顶对齐视口。
        /// 参数放宽为 UIScrollView：panLock 归位也从这里走（didSeekPan 手里只有 UIScrollView 类型）
        private func realignToCurrentPage(in scroll: UIScrollView) {
            guard let start = parent.currentSort,
                  let index = parent.slots.firstIndex(where: { $0.sort == start }) else {
                print("PLAYER_DBG [CHECK] realignOffset SKIP reason=noCurrentSort")
                return
            }
            let offset = CGFloat(index) * scroll.bounds.height
            let oldY = scroll.contentOffset.y
            guard abs(oldY - offset) > 1 else { return }
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            print("PLAYER_DBG [CHECK] realignOffset sort=\(start) y=\(Int(oldY))→\(Int(offset))")
        }

        /// 连播翻页：动画滚到目标 sort 对应页（页面 frame 已随 slots 布好，不等 SwiftUI update）。
        /// 结束回写由 scrollViewDidEndScrollingAnimation 接管——realign 的 animated=false
        /// 不触发那条 delegate，无串扰。
        func scrollToSort(_ sort: Int, in scroll: UIScrollView, animated: Bool, reason: String) {
            guard let index = parent.slots.firstIndex(where: { $0.sort == sort }) else {
                print("PLAYER_DBG [CHECK] scrollTo SKIP reason=noSlot sort=\(sort) by=\(reason)")
                return
            }
            let height = scroll.bounds.height
            guard height > 0 else {
                print("PLAYER_DBG [CHECK] scrollTo SKIP reason=zeroBounds sort=\(sort) by=\(reason)")
                return
            }
            let target = CGPoint(x: 0, y: CGFloat(index) * height)
            print("PLAYER_DBG [CHECK] scrollTo sort=\(sort) index=\(index) y=\(Int(target.y)) animated=\(animated) by=\(reason)")
            scroll.setContentOffset(target, animated: animated)
        }

        func applyStartOffsetIfNeeded(in scroll: PagingScrollView) {
            guard !startApplied else { return }
            var reason = ""
            if parent.currentSort == nil { reason = "currentSort=nil" }
            else if scroll.bounds.height <= 0 { reason = "boundsH=0" }
            else if scroll.contentSize.height < scroll.bounds.height { reason = "contentSize not ready" }
            guard reason.isEmpty else {
                if reason != lastPendingReason {
                    lastPendingReason = reason
                    print("PLAYER_DBG [CHECK] startOffset PENDING reason=\(reason)")
                }
                return
            }
            guard let start = parent.currentSort,
                  let index = parent.slots.firstIndex(where: { $0.sort == start }) else { return }
            startApplied = true
            let offset = CGFloat(index) * scroll.bounds.height
            print("PLAYER_DBG [CHECK] startOffset APPLY start=\(start) index=\(index) expectedY=\(Int(offset))")
            DispatchQueue.main.async {
                scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                let actual = scroll.contentOffset.y
                print("PLAYER_DBG [CHECK] startOffset APPLIED actualY=\(Int(actual)) expectedY=\(Int(offset)) → \(abs(actual - offset) < 2 ? "OK" : "FAIL")")
            }
        }

        // MARK: 滚动

        func scrollViewWillEndDragging(_ scrollView: UIScrollView,
                                       withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            let height = scrollView.bounds.height
            guard height > 0 else { return }
            let currentIndex = Int(round(scrollView.contentOffset.y / height))
            let proposed = targetContentOffset.pointee.y
            let delta = proposed - CGFloat(currentIndex) * height
            var nextIndex = currentIndex
            let triggered = abs(delta) > height * 0.15 || abs(velocity.y) > 0.3
            if triggered {
                nextIndex = currentIndex + ((delta > 0 || velocity.y > 0) ? 1 : -1)
            }
            // 末页边界提示触发点（用户拍板 2026-11-14）：在末页滑动方向朝向下一集、
            // 且翻页判定成立（有位移/有速度），但目标页超出最后页——「想看下一集
            // 但已无资源，滑出未果」。此时才弹「已经到底了」，停稳末页本身不提示。
            // 轻拖不触发（triggered=false），回弹误触被 clamp 判定天然排除。
            if triggered, nextIndex > parent.slots.count - 1 {
                print("PLAYER_DBG [CHECK] pullBeyondEnd idx=\(currentIndex) delta=\(Int(delta)) vY=\(String(format: "%.2f", velocity.y)) slots=\(parent.slots.count)")
                parent.onPullBeyondEnd()
            }
            nextIndex = max(0, min(parent.slots.count - 1, nextIndex))
            let targetY = CGFloat(nextIndex) * height
            let overridden = abs(targetY - proposed) > 1
            print("PLAYER_DBG [CHECK] willEndDragging y=\(Int(scrollView.contentOffset.y)) proposed=\(Int(proposed)) vY=\(String(format: "%.2f", velocity.y)) delta=\(Int(delta)) currentIdx=\(currentIndex) nextIdx=\(nextIndex) triggered=\(triggered) override=\(overridden) targetY=\(Int(targetY))")
            if overridden { targetContentOffset.pointee.y = targetY }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let y = scrollView.contentOffset.y
            guard abs(y - lastLoggedY) > 100 else { return }
            lastLoggedY = y
            print("PLAYER_DBG [UIScroll] didScroll y=\(Int(y)) dragging=\(scrollView.isDragging) decel=\(scrollView.isDecelerating)")
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            let height = scrollView.bounds.height
            let y = scrollView.contentOffset.y
            let index = height > 0 ? Int(round(y / height)) : -1
            let aligned = height > 0 && abs(y - CGFloat(index) * height) < 2
            print("PLAYER_DBG [CHECK] endDecel y=\(Int(y)) index=\(index) aligned=\(aligned)")
            report(scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            print("PLAYER_DBG [CHECK] endDrag y=\(Int(scrollView.contentOffset.y)) willDecel=\(decelerate)")
            if !decelerate { report(scrollView) }
        }

        /// 程序化 setContentOffset(animated:) 的结束回调（animated=false 不触发，realign 无串扰）。
        /// 目前唯一来源是连播动画——用户拖拽走 endDragging/endDecelerating。
        /// 连播滚完必须回写 currentSort：否则 scrollID 不变、schedulePageSettle 不触发、
        /// 下一集永远不加载（连播管线复用的关键接点）
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            print("PLAYER_DBG [CHECK] endScrollingAnimation y=\(Int(scrollView.contentOffset.y))")
            report(scrollView)
        }

        private func report(_ scroll: UIScrollView) {
            guard scroll.bounds.height > 0 else {
                print("PLAYER_DBG [CHECK] report SKIPPED boundsH=0")
                return
            }
            let index = Int(round(scroll.contentOffset.y / scroll.bounds.height))
            guard index >= 0, index < parent.slots.count else {
                print("PLAYER_DBG [CHECK] report OUT_OF_RANGE index=\(index) slots=\(parent.slots.count)")
                return
            }
            let sort = parent.slots[index].sort
            print("PLAYER_DBG [CHECK] report index=\(index) → sort=\(sort) bindingBefore=\(parent.currentSort.map(String.init) ?? "nil") vm=\(parent.vmCurrentSort.map(String.init) ?? "nil")")
            parent.currentSort = sort
        }
    }
}

/// bounds 变化后重新排布每一页，避免 SwiftUI 首帧给不出尺寸
final class PagingScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
