import UIKit
import AVFoundation
import Combine

// MARK: - 全屏播放控制器（UIKit + Combine）
//
// 对齐 ZFPlayer / SJVideoPlayer「旋转横屏（rotate）」模式：App 锁竖屏、系统界面不转，
// 「全屏」= 全屏容器 transform 旋转 90° + 等比放大铺满屏幕的连续动画——
// 视频从竖屏内的 letterbox 条「跟随旋转慢慢变大」，退出反向动画。
//
// 职责：
// - 订阅 `playback.$isFullscreen`（Combine），驱动进/出动画；动画期间的最新意图收敛。
// - videoLayer 在 feed surface 与全屏容器之间搬运（AVPlayer 不间断，无重载）。
// - 全屏容器挂在 keyWindow 上（覆盖一切、不随内容滚动），随播放页销毁立即还原。
// 控制层（A-4）挂进全屏容器；进/出触发由姿态服务（A-5）调 VM 意图，本类不自判姿态。

/// 全屏容器：bounds 即横屏坐标空间（旋转后铺满竖屏屏幕），videoLayer 在 layoutSubviews 跟随
final class FullscreenPlayerView: UIView {
    var videoLayer: AVPlayerLayer?
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        videoLayer?.frame = bounds
        onLayout?()
    }
}

final class PlayerFullscreenController: NSObject, UIGestureRecognizerDelegate {
    private let playback: DramaPlayerViewModel
    private unowned let surface: PlayerSurfaceUIView
    private var container: FullscreenPlayerView?
    private var controls: PlayerFullscreenControlsView?
    /// 当前全屏旋转方向（+π/2 / -π/2）：退出动画与控制层安全区映射都要用
    private var rotationAngle: CGFloat = .pi / 2
    private var cancellables = Set<AnyCancellable>()
    private var isAnimating = false
    /// 动画期间的最新意图（连续触发以最后为准，不排队跳变）
    private var pendingTarget: Bool?
    /// 长按松手后的吞单击窗（与卡片 250ms 抑制同机制，全屏态本地持有）
    private var tapSuppressionUntil = Date.distantPast
    /// 本次触摸是否按满 0.15s 真正起过 2x（perform 里置位）
    private var longPressOwnedTouch = false
    private var seekPan: UIPanGestureRecognizer?
    /// 横向 seek 的基准进度（began 时捕获，相对映射：位移/容器宽 = 进度增量）
    private var scrubBaseFraction: Double?

    init(playback: DramaPlayerViewModel, surface: PlayerSurfaceUIView) {
        self.playback = playback
        self.surface = surface
        super.init()
        playback.$isFullscreen
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] full in self?.handle(full) }
            .store(in: &cancellables)
    }

    /// 播放页销毁：立即还原 videoLayer 并移除 window 上的全屏容器（无动画）
    func teardown() {
        cancellables.removeAll()
        guard container != nil else { return }
        restoreVideoLayer()
        container?.removeFromSuperview()
        container = nil
        print("PLAYER_DBG [Fullscreen] teardown restored")
    }

    // MARK: 私有

    private func handle(_ full: Bool) {
        guard !isAnimating else {
            pendingTarget = full
            return
        }
        full ? performEnter() : performExit()
    }

    /// 进入：容器从活跃卡 surface 的窗口 frame 出发，旋转 90° + 放大铺满
    private func performEnter() {
        guard container == nil, let window = surface.window else {
            print("PLAYER_DBG [Fullscreen] enter SKIP reason=noWindowOrAlready")
            return
        }
        isAnimating = true
        let startFrame = surface.convert(surface.bounds, to: window)
        let container = FullscreenPlayerView(frame: startFrame)
        container.backgroundColor = .black
        container.clipsToBounds = true

        // videoLayer 搬家（唯一宿主切换）：动画前先落位到起点，无空帧
        surface.videoLayer.removeFromSuperlayer()
        container.videoLayer = surface.videoLayer
        container.layer.addSublayer(surface.videoLayer)
        surface.videoLayer.frame = container.bounds
        surface.videoLayer.videoGravity = .resizeAspectFill   // 全屏铺满（横屏片源轻微上下裁切）

        window.addSubview(container)
        self.container = container

        // 控制层 + 手势：控制层随容器自转（左上角返回 icon 返回竖屏，无独立退出全屏按钮）
        let controls = PlayerFullscreenControlsView(playback: playback)
        controls.frame = container.bounds
        controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controls.localInsets = Self.localInsets(rotationAngle: rotationAngle, windowInsets: window.safeAreaInsets)
        controls.alpha = 0
        controls.onBack = { [weak self] in
            print("PLAYER_DBG [Fullscreen] back icon → exitFullscreen")
            self?.playback.exitFullscreen()
        }
        container.addSubview(controls)
        self.controls = controls
        installGestures(on: container)

        let screenSize = window.bounds.size
        print("PLAYER_DBG [Fullscreen] enter from=\(startFrame) screen=\(screenSize)")
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut], animations: {
            // bounds 换成横屏尺寸 + 中心居中 + 旋转 90°：旋转后足迹恰好铺满竖屏屏幕
            container.bounds = CGRect(origin: .zero, size: CGSize(width: screenSize.height, height: screenSize.width))
            container.center = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
            container.transform = CGAffineTransform(rotationAngle: .pi / 2)
        }, completion: { [weak self] _ in
            guard let self else { return }
            self.isAnimating = false
            print("PLAYER_DBG [Fullscreen] enter done")
            self.controls?.showTransient()   // 进入全屏后呼出控制层，3s 自动收起
            self.flushPending()
        })
    }

    /// 退出：反向动画回活跃卡 surface 的窗口 frame，完成后 videoLayer 搬回
    private func performExit() {
        guard let container, let window = surface.window else {
            container?.removeFromSuperview()
            self.container = nil
            return
        }
        isAnimating = true
        let targetFrame = surface.convert(surface.bounds, to: window)
        print("PLAYER_DBG [Fullscreen] exit to=\(targetFrame)")
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut], animations: {
            container.transform = .identity
            container.bounds = CGRect(origin: .zero, size: targetFrame.size)
            container.center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        }, completion: { [weak self] _ in
            guard let self else { return }
            self.restoreVideoLayer()
            container.removeFromSuperview()
            self.container = nil
            self.isAnimating = false
            print("PLAYER_DBG [Fullscreen] exit done")
            self.flushPending()
        })
    }

    private func restoreVideoLayer() {
        let layer = surface.videoLayer
        layer.removeFromSuperlayer()
        surface.layer.addSublayer(layer)
        layer.frame = surface.bounds
        layer.videoGravity = PlayerPagingScrollView.videoGravity(for: playback)
    }

    // MARK: 控制层安全区映射（窗口 insets → 旋转后的容器本地坐标）

    /// +π/2：本地 top=窗口 trailing、bottom=leading、left=窗口 top、right=bottom；-π/2 镜像。
    /// 两个横屏方向的窗口 leading/trailing 相等（灵动岛居中），映射后都能避开岛区。
    static func localInsets(rotationAngle: CGFloat, windowInsets: UIEdgeInsets) -> UIEdgeInsets {
        if abs(rotationAngle - .pi / 2) < 0.01 {
            return UIEdgeInsets(top: windowInsets.right, left: windowInsets.top,
                                bottom: windowInsets.left, right: windowInsets.bottom)
        }
        return UIEdgeInsets(top: windowInsets.left, left: windowInsets.bottom,
                            bottom: windowInsets.right, right: windowInsets.top)
    }

    // MARK: 全屏手势（点按暂停 / 长按 2x / 横向相对 seek）
    //
    // 竖屏卡片六条仲裁约束的全屏版（UIKit 原生实现）：
    // ① 拖动先起 → seek 独占：pan .began 即 VM.beginSeekGesture，长按 perform 查闸门；
    // ② 长按先起 → 2x 独占：perform（按满 0.15s）才起 2x，allowableMovement 放开；
    // ③ 长按松手 → 吞单击 250ms；④ 2x 只在 began（perform 等价态）里起；
    // ⑤ seek 抬手不补 seek（VM.endSeekGesture 内含）；⑥ tap 查 VM.seek 闸门与抑制窗。

    private func installGestures(on container: FullscreenPlayerView) {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        container.addGestureRecognizer(tap)

        let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        long.minimumPressDuration = 0.15
        long.allowableMovement = 10_000   // 2x 不靠位移距离撚断（同卡片 maximumDistance 10_000）
        container.addGestureRecognizer(long)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSeekPan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        container.addGestureRecognizer(pan)
        seekPan = pan
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // seek 只认横向/斜向主导（保持与卡片同规则；全屏无分页滚动可干扰）
        guard gestureRecognizer === seekPan, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let t = pan.translation(in: pan.view)
        return abs(t.x) >= abs(t.y)
    }

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        if Date() < tapSuppressionUntil {
            print("PLAYER_DBG [CHECK] fullscreen TAP SKIP reason=justEndedLongPress")
            return
        }
        if Date() < playback.tapSuppressionDeadline {
            print("PLAYER_DBG [CHECK] fullscreen TAP SKIP reason=justEndedSeek")
            return
        }
        if playback.isSeekGestureActive {
            print("PLAYER_DBG [CHECK] fullscreen TAP SKIP reason=seekGestureActive")
            return
        }
        print("PLAYER_DBG [CHECK] fullscreen TAP → togglePlayback")
        playback.togglePlayback()
        controls?.showTransient()
    }

    @objc private func handleLongPress(_ long: UILongPressGestureRecognizer) {
        switch long.state {
        case .began:
            guard !playback.isSeekGestureActive else {
                print("PLAYER_DBG [CHECK] fullscreen LONGPRESS SKIP reason=seeking")
                longPressOwnedTouch = false
                return
            }
            longPressOwnedTouch = true
            print("PLAYER_DBG [CHECK] fullscreen LONGPRESS began → 2x")
            playback.beginFastForward()
            controls?.showTransient()
        case .ended, .cancelled, .failed:
            guard longPressOwnedTouch else { return }
            longPressOwnedTouch = false
            print("PLAYER_DBG [CHECK] fullscreen LONGPRESS ended → 1x")
            playback.endFastForward()
            tapSuppressionUntil = Date().addingTimeInterval(0.25)
        default:
            break
        }
    }

    @objc private func handleSeekPan(_ pan: UIPanGestureRecognizer) {
        guard let view = pan.view else { return }
        switch pan.state {
        case .began:
            scrubBaseFraction = playback.progress
            playback.beginSeekGesture()
            print("PLAYER_DBG [CHECK] fullscreen seekPan began scrubBase=\(String(format: "%.2f", scrubBaseFraction ?? 0))")
        case .changed:
            let t = pan.translation(in: view)
            guard abs(t.x) > abs(t.y), abs(t.x) > 6, let base = scrubBaseFraction else { return }
            let fraction = min(max(base + PlayerGesturePolicy.scrubDelta(translationX: t.x, screenWidth: view.bounds.width), 0), 1)
            print("PLAYER_DBG [CHECK] fullscreen seekPan dx=\(Int(t.x)) fraction=\(String(format: "%.2f", fraction))")
            playback.seek(fraction: fraction)
        case .ended, .cancelled, .failed:
            scrubBaseFraction = nil
            playback.endSeekGesture()   // 内含吞单击窗 + 进度落盘
        default:
            break
        }
    }

    private func flushPending() {
        guard let pending = pendingTarget else { return }
        pendingTarget = nil
        if pending != playback.isFullscreen {
            handle(pending)
        }
    }
}
