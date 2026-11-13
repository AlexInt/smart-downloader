import SwiftUI
import UIKit

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
    let makeCard: (PlayableEpisode) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PagingScrollView {
        let scroll = PagingScrollView()
        scroll.isPagingEnabled = true
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
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
        return scroll
    }

    func updateUIView(_ scroll: PagingScrollView, context: Context) {
        context.coordinator.parent = self
        print("PLAYER_DBG [CHECK] update binding=\(currentSort.map(String.init) ?? "nil") vm=\(vmCurrentSort.map(String.init) ?? "nil") isReady=\(isReady) slots=\(slots.count)")
        context.coordinator.rebuildIfNeeded(in: scroll)
        context.coordinator.refreshCardsIfNeeded()
        context.coordinator.applyStartOffsetIfNeeded(in: scroll)
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
        private var lastLoggedY: CGFloat = -999
        /// 上次实际布局过的几何 key：几何没变时 layoutPages 幂等跳过（防布局回环）
        private var lastLaidSizeKey = ""
        private var lastPendingReason = ""
        private var lastLoggedSeek: Double = -1
        /// 本次拖拽的 scrub 基准进度（.began 时捕获当前播放进度；左缘起手为 nil = 不 seek）
        private var scrubBaseFraction: Double?
        private var edgeBackFired = false

        init(_ parent: PlayerPagingScrollView) {
            self.parent = parent
        }

        // MARK: 离散手势

        // 点按暂停 / 长按倍速已移回卡片内 SwiftUI 手势（见 DramaPlayerView body 末尾），
        // 这里不再挂 UITapGestureRecognizer / UILongPressGestureRecognizer。

        /// 左缘右滑返回：拖过 50pt 即触发（不必等抬手），每次手势只触发一次
        @objc func didEdgePan(_ pan: UIScreenEdgePanGestureRecognizer) {
            guard let view = pan.view else { return }
            switch pan.state {
            case .began:
                edgeBackFired = false
                print("PLAYER_DBG [CHECK] edgePan began")
            case .changed:
                guard !edgeBackFired else { return }
                let dx = pan.translation(in: view).x
                if dx > 50 {
                    edgeBackFired = true
                    print("PLAYER_DBG [CHECK] edgePan dx=\(Int(dx)) > 50 → back")
                    parent.onEdgeBack()
                }
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
            // seekPan 只认横向/斜向滑动：纵向主导的翻页滑动直接拒绝，交给分页滚动。
            // 若不加此方向过滤，seekPan 不限方向、竖滑也 began（cancelsTouchesInView=false）→ 搅乱滚动
            // 对触摸的取消 → 卡片点按手势未被干净取消 → 抬手误判 TAP → 暂停（真机日志实证）。
            // 横向/45° 斜向仍立即 begin，保住「拖动先起」的长按仲裁闸门（斜起手转水平不受影响）。
            guard gestureRecognizer === seekPan,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let t = pan.translation(in: pan.view)
            return abs(t.x) >= abs(t.y)
        }

        @objc func didSeekPan(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view as? UIScrollView else { return }
            switch pan.state {
            case .began:
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
                parent.playback.seek(fraction: fraction)
            case .ended, .cancelled, .failed:
                // 抬手不补 seek：最后一次 .changed 已到位；
                // 也避免「2x 长按抬手先清了 isFastForwarding → .ended 的 seek 反而穿过闸门」的竞态跳变。
                // 只结束「拖动独占」标记，下一次长按可正常起 2x
                scrubBaseFraction = nil
                parent.playback.endSeekGesture()
            default: break
            }
        }

        // MARK: 页面管理

        func refreshCardsIfNeeded() {
            let changed = lastRefreshedSort != parent.currentSort
                || lastRefreshedReady != parent.isReady
                || lastRefreshedToast != parent.activeToast
            guard !hosts.isEmpty, changed else { return }
            lastRefreshedSort = parent.currentSort
            lastRefreshedReady = parent.isReady
            lastRefreshedToast = parent.activeToast
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
            // 旋转后页高变了：旧 contentOffset 落在新网格的错页上（真机实证：竖屏 offset
            // 2622 在横屏页高 402 下落到第 6.5 页，正在播的卡整个在屏外 → 画面消失、声音
            // 继续）。重置一次性标记，让 applyStartOffset 重新落回 currentSort 那一页。
            startApplied = false
            applyStartOffsetIfNeeded(in: scroll)
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
