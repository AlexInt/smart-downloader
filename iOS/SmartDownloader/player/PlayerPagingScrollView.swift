import SwiftUI
import UIKit

/// UIKit 原生纵向分页容器（ZFPlayer / 开源抖音实践）。
/// `UIScrollView.isPagingEnabled` 由 UIKit 独占 pan。
///
/// 卡片是 UIHostingController.rootView，只在 `refreshCards` 时重设；
/// 因此当前页 **与** 播放就绪状态任一变化都必须刷新，否则视频层会一直被
/// `opacity(isActive && isReady ? 1 : 0)` 藏在渐变后面（播放器在播但画面不显示）。
struct PlayerPagingScrollView: UIViewRepresentable {
    let slots: [PlayableEpisode]
    @Binding var currentSort: Int?
    let playback: DramaPlayerViewModel
    let vmCurrentSort: Int?
    /// 播放是否就绪：变化时需要刷新卡片 rootView
    let isReady: Bool
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
        private var lastLoggedY: CGFloat = -999
        private var lastLoggedSize = ""
        private var lastPendingReason = ""
        private var lastLoggedSeek: Double = -1
        /// 本次 seekPan 触摸的起点是否在进度带内（.began 时捕获；带外起点全程不 seek）
        private var seekStartInBand = false
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

        @objc func didSeekPan(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view as? UIScrollView else { return }
            switch pan.state {
            case .began:
                // 起手（约 10pt 位移）即判「拖动先起」，立刻翻转仲裁闸门（VM.beginSeekGesture）。
                // 不能等 .changed 攒够「水平主导 + dx>6」才置位：清屏下进度带不可见，
                // 横滑起点常落在带外（旧代码 shouldBegin 按带内过滤，识别器直接 fail，
                // 一个事件都收不到），斜起手快速转水平的带内快滑同理——长按 0.15s 的
                // perform 都会插进这个空窗误起 2x（闪倍速提示）。慢漂移（走 10pt 超过
                // 0.15s）仍长按先起，2x 不受影响。是否真 seek 由 .changed 按起点在带内判定。
                // location(in: scrollView) 是内容坐标（含 contentOffset），喂 PlayerGesturePolicy
                // 前必须减 contentOffset 换算成屏幕坐标（第一页 offset=0 会掩盖此问题）。
                let y = pan.location(in: view).y - view.contentOffset.y
                seekStartInBand = PlayerGesturePolicy.isInSeekBand(screenY: y, screenSize: view.bounds.size)
                print("PLAYER_DBG [CHECK] seekPan began screenY=\(Int(y)) contentY=\(Int(pan.location(in: view).y)) startInBand=\(seekStartInBand)")
                parent.playback.beginSeekGesture()
            case .changed:
                // 起点在带外的触摸全程不 seek（带外水平滑动无效果），但仲裁闸门照常生效
                guard seekStartInBand else { return }
                let t = pan.translation(in: view)
                guard abs(t.x) > abs(t.y), abs(t.x) > 6 else { return }
                // 同 shouldBegin：内容坐标 → 屏幕坐标（纵向分页 contentOffset.x 恒为 0，防御性换算）
                let x = pan.location(in: view).x - view.contentOffset.x
                let fraction = PlayerGesturePolicy.seekFraction(screenX: x, screenSize: view.bounds.size)
                if abs(fraction - lastLoggedSeek) > 0.05 {
                    lastLoggedSeek = fraction
                    print("PLAYER_DBG [CHECK] seekPan x=\(Int(x)) dx=\(Int(t.x)) dy=\(Int(t.y)) fraction=\(String(format: "%.2f", fraction))")
                }
                parent.playback.seek(fraction: fraction)
            case .ended, .cancelled, .failed:
                // 抬手不补 seek：fraction 取自绝对位置，最后一次 .changed 已到位；
                // 也避免「2x 长按抬手先清了 isFastForwarding → .ended 的 seek 反而穿过闸门」的竞态跳变。
                // 只结束「拖动独占」标记，下一次长按可正常起 2x
                parent.playback.endSeekGesture()
            default: break
            }
        }

        // MARK: 页面管理

        func refreshCardsIfNeeded() {
            let changed = lastRefreshedSort != parent.currentSort || lastRefreshedReady != parent.isReady
            guard !hosts.isEmpty, changed else { return }
            lastRefreshedSort = parent.currentSort
            lastRefreshedReady = parent.isReady
            let current = parent.currentSort
            for slot in parent.slots {
                hosts[slot.sort]?.rootView = parent.makeCard(slot)
            }
            print("PLAYER_DBG [CHECK] refreshCards current=\(current.map(String.init) ?? "nil") isReady=\(parent.isReady) activeHost=\(current.flatMap { hosts[$0] } != nil)")
        }

        func rebuildIfNeeded(in scroll: PagingScrollView) {
            let sorts = parent.slots.map(\.sort)
            guard sorts != builtSorts else { return }
            builtSorts = sorts
            startApplied = false
            lastRefreshedSort = nil
            lastRefreshedReady = nil
            lastPendingReason = ""
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
            let shouldLog = sizeKey != lastLoggedSize
            if shouldLog { lastLoggedSize = sizeKey }
            guard width > 0, height > 0 else {
                if shouldLog { print("PLAYER_DBG [CHECK] layout SKIPPED zero bounds=\(width)x\(height)") }
                return
            }
            for (index, slot) in parent.slots.enumerated() {
                hosts[slot.sort]?.view.frame =
                    CGRect(x: 0, y: CGFloat(index) * height, width: width, height: height)
            }
            scroll.contentSize = CGSize(width: width,
                                        height: height * CGFloat(parent.slots.count))
            if shouldLog {
                let first = hosts[parent.slots.first?.sort ?? -1]?.view.frame ?? .zero
                let last = hosts[parent.slots.last?.sort ?? -1]?.view.frame ?? .zero
                print("PLAYER_DBG [CHECK] layout bounds=\(width)x\(height) contentSize=\(scroll.contentSize) firstFrame=\(first) lastFrame=\(last)")
            }
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
