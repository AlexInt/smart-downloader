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
        // 裸 CALayer 写 frame 禁隐式动作（同 PlayerSurfaceUIView.withoutLayerActions 说明）
        if let videoLayer, videoLayer.frame != bounds {
            PlayerSurfaceUIView.withoutLayerActions {
                videoLayer.frame = bounds
            }
        }
        onLayout?()
    }
}

final class PlayerFullscreenController: NSObject, UIGestureRecognizerDelegate {
    private let playback: DramaPlayerViewModel
    private unowned let surface: PlayerSurfaceUIView
    private var container: FullscreenPlayerView?
    private var controls: PlayerFullscreenControlsView?
    /// 当前全屏旋转方向（+π/2 / -π/2）：进/出/转体动画与控制层安全区映射都要用
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
    /// seekPan .changed 的拒绝原因每次手势只打一次（降噪）
    private var seekChangedRejectLogged = false

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
        // 全屏中左右转向切换：触发器判稳后改 VM 旋转角，这里做转体动画；
        // 非全屏时的角度变更由 enter 动画消化（enter 重新读 VM 值）
        playback.$fullscreenRotationAngle
            .dropFirst()
            .removeDuplicates { abs($0 - $1) < 0.01 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] angle in self?.handleRotationChange(angle) }
            .store(in: &cancellables)
    }

    /// 播放页销毁：立即还原 videoLayer 并移除 window 上的全屏容器（无动画）
    func teardown() {
        cancellables.removeAll()
        guard container != nil else {
            print("PLAYER_DBG [Fullscreen] teardown noop reason=neverEntered")
            return
        }
        restoreVideoLayer()
        container?.removeFromSuperview()
        container = nil
        print("PLAYER_DBG [Fullscreen] teardown restored")
    }

    // MARK: 私有

    private func handle(_ full: Bool) {
        guard !isAnimating else {
            pendingTarget = full
            print("PLAYER_DBG [Fullscreen] intent \(full ? "enter" : "exit") DEFERRED reason=animating")
            return
        }
        full ? performEnter() : performExit()
    }

    /// 全屏中旋转角变更（左右转向切换）
    private func handleRotationChange(_ angle: CGFloat) {
        guard playback.isFullscreen else {
            print("PLAYER_DBG [Fullscreen] angle CHANGE IGNORED reason=notFullscreen angle=\(angle == .pi / 2 ? "+π/2" : "-π/2")")
            return
        }
        performReorientation(to: angle)
    }

    /// 全屏视频矩形：与片源同宽高比、长边铺满屏幕长边（横屏片源 → 874×(874/宽高比) 型）。
    /// 旋转 90° 后足迹纵向满屏、横向溢出屏幕两侧（被裁掉 = fill 的轻微裁切）；fill 在
    /// 同宽高比 bounds 上 = 精确铺满，无变形无裁切，分辨率整幅原生。
    /// 片源尺寸未知时退回屏幕转置矩形（fill 旧路径）。
    private static func fullscreenVideoRect(screen: CGSize, videoSize: CGSize) -> CGRect {
        let long = max(screen.width, screen.height)
        let short = min(screen.width, screen.height)
        guard videoSize.width > 0, videoSize.height > 0 else {
            return CGRect(origin: .zero, size: CGSize(width: long, height: short))
        }
        let aspect = videoSize.width / videoSize.height
        return CGRect(origin: .zero, size: CGSize(width: long, height: long / aspect))
    }

    /// 视频当前实际显示带：surface 框内按片源宽高比 fit 的居中矩形（窗口坐标）。
    /// 进/出全屏以它为起点/终点——起点与卡片画面逐像素重合、终点与 restore 后的
    /// fit 显示重合，两端都无裁切突变（「进入竖屏闪一下」的根因即 fill↔fit 跳变）。
    /// 片源尺寸未知（0×0）退回 surface 全框（旧路径）。
    private func videoBandFrame(in window: UIWindow) -> CGRect {
        let surfaceFrame = surface.convert(surface.bounds, to: window)
        let size = playback.videoPixelSize
        guard size.width > 0, size.height > 0 else { return surfaceFrame }
        let scale = min(surfaceFrame.width / size.width, surfaceFrame.height / size.height)
        let band = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: surfaceFrame.midX - band.width / 2,
                      y: surfaceFrame.midY - band.height / 2,
                      width: band.width, height: band.height)
    }

    /// 旋转/缩放分量用 CA 标量关键路径动画（transform.rotation.z / transform.scale.x|y）：
    /// CGAffineTransform 矩阵整体插值是矩阵分量线性变化，旋转中伴随非等比泵缩
    /// （180° 甚至塌缩过零矩阵）；按角度/比例标量插值无此问题。模型值先行落终态，
    /// 动画只负责 presentation，与 UIView.animate 同时长同曲线并行。
    private func addScalarAnimation(_ keyPath: String, from: CGFloat, to: CGFloat,
                                    duration: TimeInterval, on view: UIView) {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer.add(anim, forKey: "fullscreen.\(keyPath)")
    }

    /// 与整体观感一致的缓动（sin 版 easeInOut，首末速度 0）
    private static func easeInOutSine(_ p: Double) -> Double {
        0.5 - cos(p * .pi) / 2
    }

    /// 旋转 + 均匀缩放联合关键帧动画：竖向足迹（旋转矩形的轴对齐包围盒高）按缓动单调插值，
    /// scale 沿途反解 s = targetH / (W·sinθ + H·cosθ)。
    /// 直接对 scale 线性插值时，旋转中段包围盒先缩后胀再缩（W·sinθ 项随角度加速增长、
    /// 跑赢了 scale 的收缩）——视频视觉上「变大再变小」。竖向严格单调不超屏；横向允许
    /// 超出屏幕（与全屏裁切同语义，不可见）。
    private func addRotateAndScaleAnimation(on view: UIView, rotationFrom: CGFloat, rotationTo: CGFloat,
                                            verticalFrom: CGFloat, verticalTo: CGFloat,
                                            duration: TimeInterval) {
        let W = view.bounds.width, H = view.bounds.height
        let steps = 30
        var keyTimes: [NSNumber] = []
        var rotations: [NSNumber] = []
        var scales: [NSNumber] = []
        for i in 0...steps {
            let p = Double(i) / Double(steps)
            let e = Self.easeInOutSine(p)
            let θ = rotationFrom + (rotationTo - rotationFrom) * e
            let targetH = verticalFrom + (verticalTo - verticalFrom) * e
            let denom = W * abs(sin(θ)) + H * abs(cos(θ))
            let s = denom > 0 ? targetH / denom : 1
            keyTimes.append(NSNumber(value: p))
            rotations.append(NSNumber(value: Double(θ)))
            scales.append(NSNumber(value: Double(s)))
        }
        let rot = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rot.values = rotations
        rot.keyTimes = keyTimes
        rot.duration = duration
        rot.calculationMode = .linear   // 分段值已含缓动形状，段间线性即可
        view.layer.add(rot, forKey: "fullscreen.rotation")
        let scl = CAKeyframeAnimation(keyPath: "transform.scale")
        scl.values = scales
        scl.keyTimes = keyTimes
        scl.duration = duration
        scl.calculationMode = .linear
        view.layer.add(scl, forKey: "fullscreen.scale")
    }

    /// 进入：容器 bounds 取「视频横屏整幅矩形」（与片源同宽高比、长边铺满屏幕长边），
    /// fill 恒等 = 精确铺满无裁切无变形；起始 presentation 用均匀 scale 对齐「视频显示带」，
    /// 动画中均匀放大 + 旋转到全幅。起点与卡片画面逐像素重合、全程无不等比变形
    /// （不等比缩放会把 fill 裁切内容压扁，读起来像「扭曲一下就转过去」）、
    /// 模型终态=动画终态（终态帧与 restore 后的 fit 显示逐像素重合，无闪帧）。
    /// 旋转/缩放走 CA 标量关键路径（矩阵整体插值有泵缩伪影）。
    private func performEnter() {
        guard container == nil, let window = surface.window else {
            print("PLAYER_DBG [Fullscreen] enter SKIP reason=noWindowOrAlready")
            return
        }
        isAnimating = true
        rotationAngle = playback.fullscreenRotationAngle
        let band = videoBandFrame(in: window)
        let screenSize = window.bounds.size
        let fullRect = Self.fullscreenVideoRect(screen: screenSize, videoSize: playback.videoPixelSize)
        let s0 = fullRect.width > 0 ? band.width / fullRect.width : 1
        let container = FullscreenPlayerView(frame: fullRect)
        container.backgroundColor = .clear
        container.clipsToBounds = true

        // videoLayer 搬家（唯一宿主切换）：动画前先落位到起点，无空帧。
        // 裸 CALayer 的 frame 写入必须禁隐式动作——否则 0.25s 飞行叠加容器动画（起手抖一下）
        let videoLayer = surface.videoLayer
        PlayerSurfaceUIView.withoutLayerActions {
            videoLayer.removeFromSuperlayer()
            videoLayer.frame = CGRect(origin: .zero, size: fullRect.size)
            videoLayer.videoGravity = .resizeAspectFill   // bounds 与片源同宽高比：fill=精确铺满，无裁切无变形，分辨率整幅原生
            container.layer.addSublayer(videoLayer)
        }
        container.videoLayer = videoLayer

        window.addSubview(container)
        self.container = container

        // 控制层 + 手势：控制层随容器自转（左上角返回 icon 返回竖屏，无独立退出全屏按钮）
        let controls = PlayerFullscreenControlsView(playback: playback)
        controls.frame = container.bounds
        controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controls.localInsets = Self.localInsets(rotationAngle: rotationAngle, windowInsets: window.safeAreaInsets)
        // 动画期间父视图 alpha=0 隐藏，完成时置 1——子控件显隐由控制层自管，
        // 父视图 alpha 不能一直为 0（曾因此整个控制层不可见：返回/清屏/进度条全消失）
        controls.alpha = 0
        controls.onBack = { [weak self] in
            print("PLAYER_DBG [Fullscreen] back icon → exitFullscreen")
            self?.playback.exitFullscreen()
        }
        container.addSubview(controls)
        self.controls = controls
        installGestures(on: container)

        print("PLAYER_DBG [Fullscreen] enter angle=\(rotationAngle == .pi / 2 ? "+π/2" : "-π/2") band=\(band) full=\(fullRect.size) s0=\(String(format: "%.3f", s0)) screen=\(screenSize)")
        // 模型先行落终态：center 起点=显示带中心；scale 动画从带比例 s0 → 1（均匀，无变形）
        container.center = CGPoint(x: band.midX, y: band.midY)
        let duration: TimeInterval = 0.3
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut], animations: {
            container.center = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
        }, completion: { [weak self] _ in
            guard let self else { return }
            self.isAnimating = false
            print("PLAYER_DBG [Fullscreen] enter done")
            self.controls?.alpha = 1
            self.controls?.showTransient()   // 进入全屏后呼出控制层，3s 自动收起
            self.flushPending()
        })
        if playback.videoPixelSize.width > 0 {
            // 联合关键帧：竖向足迹单调插值，消除旋转中段包围盒鼓包（「变大再变小」）
            addRotateAndScaleAnimation(on: container, rotationFrom: 0, rotationTo: rotationAngle,
                                       verticalFrom: band.height, verticalTo: screenSize.height,
                                       duration: duration)
        } else {
            // 片源尺寸未知（videoIsLandscape 下理论不可达）：退回线性标量
            addScalarAnimation("transform.scale", from: s0, to: 1, duration: duration, on: container)
            addScalarAnimation("transform.rotation.z", from: 0, to: rotationAngle, duration: duration, on: container)
        }
        // 模型终态=动画终态（只旋转 scale 1，足迹=全幅矩形）。注意用实际转向角 rotationAngle，
        // 写死 ±π/2 会让另一半转向进全屏内容上下倒置（de08f27 没修干净的那半）
        container.transform = CGAffineTransform(rotationAngle: rotationAngle)
    }

    /// 退出：反向动画回「视频显示带」（均匀 scale 1 → s0 + 旋转回 0）——终点与 restore 后
    /// 的 fit 显示逐像素重合；完成后 videoLayer 搬回 surface。
    private func performExit() {
        guard let container, let window = surface.window else {
            print("PLAYER_DBG [Fullscreen] exit FORCE CLEAN reason=noWindow hadContainer=\(container != nil)")
            container?.removeFromSuperview()
            self.container = nil
            return
        }
        isAnimating = true
        let screenSize = window.bounds.size
        let band = videoBandFrame(in: window)
        let s0 = container.bounds.width > 0 ? band.width / container.bounds.width : 1
        print("PLAYER_DBG [Fullscreen] exit to=\(band) s0=\(String(format: "%.3f", s0))")
        let duration: TimeInterval = 0.3
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut], animations: {
            container.center = CGPoint(x: band.midX, y: band.midY)
            self.controls?.alpha = 0   // 控制层随收缩淡出（完成时 layer 已搬回，父视图随即移除）
        }, completion: { [weak self] _ in
            guard let self else { return }
            self.restoreVideoLayer()
            container.removeFromSuperview()
            self.container = nil
            self.isAnimating = false
            print("PLAYER_DBG [Fullscreen] exit done")
            self.flushPending()
        })
        if playback.videoPixelSize.width > 0 {
            addRotateAndScaleAnimation(on: container, rotationFrom: rotationAngle, rotationTo: 0,
                                       verticalFrom: screenSize.height, verticalTo: band.height,
                                       duration: duration)
        } else {
            addScalarAnimation("transform.rotation.z", from: rotationAngle, to: 0, duration: duration, on: container)
            addScalarAnimation("transform.scale", from: 1, to: s0, duration: duration, on: container)
        }
        // 模型终态=动画终态（scale s0，足迹=显示带）。绝不能落 identity——bounds 是横屏
        // 整幅矩形，identity 足迹撑回整屏宽，动画结束帧与模型帧之间会闪出一次大画面
        //（「回竖屏画面动一下」的根因）
        container.transform = CGAffineTransform(scaleX: s0, y: s0)
    }

    private func restoreVideoLayer() {
        let layer = surface.videoLayer
        // 禁隐式动作 + 先落位再挂回：裸 CALayer 直接改 frame 会 0.25s 飞行
        //（「横转竖抖一下」的根因）；先设 frame/gravity 再 addSublayer，
        // 树里从不存在携带旧坐标系 frame 的中间态
        PlayerSurfaceUIView.withoutLayerActions {
            layer.removeFromSuperlayer()
            layer.frame = surface.bounds
            layer.videoGravity = PlayerPagingScrollView.videoGravity(for: playback)
            surface.layer.addSublayer(layer)
        }
        print("PLAYER_DBG [Fullscreen] restore layer frame=\(surface.bounds) gravity=\(playback.videoIsLandscape ? "fit" : "fill")")
    }

    /// 全屏中左右转向切换：只转体（scale 不变），单段角度动画经 0°——
    /// 内容先回正再转向另一侧，与「翻转手机」的自然预期一致
    private func performReorientation(to newAngle: CGFloat) {
        guard let container, let controls else {
            print("PLAYER_DBG [Fullscreen] flip SKIP reason=noContainerOrControls")
            return
        }
        guard !isAnimating else {
            print("PLAYER_DBG [Fullscreen] flip SKIP reason=animating")
            return
        }
        guard rotationAngle != newAngle else {
            print("PLAYER_DBG [Fullscreen] flip SKIP reason=sameAngle")
            return
        }
        isAnimating = true
        let old = rotationAngle
        rotationAngle = newAngle
        controls.localInsets = Self.localInsets(rotationAngle: newAngle,
                                                windowInsets: container.window?.safeAreaInsets ?? .zero)
        print("PLAYER_DBG [Fullscreen] flip angle=\(old == .pi / 2 ? "+π/2" : "-π/2") → \(newAngle == .pi / 2 ? "+π/2" : "-π/2")")
        let duration: TimeInterval = 0.3
        addScalarAnimation("transform.rotation.z", from: old, to: newAngle, duration: duration, on: container)
        container.transform = CGAffineTransform(rotationAngle: newAngle)   // 模型终态
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.container != nil else {
                print("PLAYER_DBG [Fullscreen] flip END SKIP reason=teardown")
                return
            }
            self.isAnimating = false
            print("PLAYER_DBG [Fullscreen] flip done")
            self.controls?.showTransient()
            self.flushPending()
        }
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
        print("PLAYER_DBG [Fullscreen] gestures installed (tap/longPress/seekPan)")
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // seek 只认横向/斜向主导（保持与卡片同规则；全屏无分页滚动可干扰）
        guard gestureRecognizer === seekPan, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let t = pan.translation(in: pan.view)
        let ok = abs(t.x) >= abs(t.y)
        print("PLAYER_DBG [CHECK] fullscreen seekPan shouldBegin tx=\(Int(t.x)) ty=\(Int(t.y)) → \(ok ? "OK" : "REJECT vertical-dominant")")
        return ok
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
            seekChangedRejectLogged = false
            playback.beginSeekGesture()
            print("PLAYER_DBG [CHECK] fullscreen seekPan began scrubBase=\(String(format: "%.2f", scrubBaseFraction ?? 0))")
        case .changed:
            let t = pan.translation(in: view)
            guard abs(t.x) > abs(t.y), abs(t.x) > 6, let base = scrubBaseFraction else {
                // 降噪：同一次手势里只打一次拒绝原因
                if !seekChangedRejectLogged {
                    seekChangedRejectLogged = true
                    print("PLAYER_DBG [CHECK] fullscreen seekPan changed SKIP tx=\(Int(t.x)) ty=\(Int(t.y)) reason=notHorizontalDominant")
                }
                return
            }
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
            print("PLAYER_DBG [Fullscreen] pending \(pending ? "enter" : "exit") FLUSH → run")
            handle(pending)
        } else {
            print("PLAYER_DBG [Fullscreen] pending \(pending ? "enter" : "exit") DROP reason=stale")
        }
    }
}
