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

/// 全屏容器：bounds 即横屏坐标空间（旋转后铺满竖屏屏幕），videoLayer 在 layoutSubviews 跟随。
/// 打开选集抽屉时视频要缩到画布 22:76 的 560×302 @(56,44)（r2 圆角），故视频矩形可由外部覆盖。
final class FullscreenPlayerView: UIView {
    var videoLayer: VideoPlayerLayer?
    var onLayout: (() -> Void)?
    /// 视频层矩形（容器本地坐标）。nil = 铺满 bounds（全屏常态 / 倍速抽屉态）
    var videoLayoutRect: CGRect? {
        didSet { setNeedsLayout() }
    }
    /// 视频层圆角（画布 22:76 r2；常态 0）
    var videoCornerRadius: CGFloat = 0 {
        didSet {
            guard videoCornerRadius != oldValue else { return }
            videoLayer?.masksToBounds = videoCornerRadius > 0
            videoLayer?.cornerRadius = videoCornerRadius
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let target = videoLayoutRect ?? bounds
        // 裸 CALayer 写 frame 禁隐式动作（同 PlayerSurfaceUIView.withoutLayerActions 说明）
        if let videoLayer, videoLayer.frame != target {
            PlayerSurfaceUIView.withoutLayerActions {
                videoLayer.frame = target
                videoLayer.cornerRadius = videoCornerRadius
                videoLayer.masksToBounds = videoCornerRadius > 0
            }
        }
        // 冻帧覆盖层跟着视频层铺满（切集冻帧在换 item 期间盖住黑底）
        videoLayer?.syncOverlayFrame()
        onLayout?()
    }

    /// 视频矩形切换（画布 22:73 选集抽屉态：缩为 560×302 @(56,44) r2）。
    /// 裸 CALayer 的 frame 写入被禁了隐式动作，故动画要显式补 position/bounds/cornerRadius 三条。
    func setVideoRect(_ rect: CGRect?, cornerRadius: CGFloat, animated: Bool) {
        let old = videoLayer?.frame
        videoLayoutRect = rect
        videoCornerRadius = cornerRadius
        let new = rect ?? bounds
        guard let layer = videoLayer else { return }
        PlayerSurfaceUIView.withoutLayerActions {
            layer.frame = new
            layer.cornerRadius = cornerRadius
            layer.masksToBounds = cornerRadius > 0
        }
        layer.syncOverlayFrame()
        guard animated, let old, old != new else { return }
        let duration: TimeInterval = 0.26
        let curve = CAMediaTimingFunction(name: .easeInEaseOut)
        let pos = CABasicAnimation(keyPath: "position")
        pos.fromValue = CGPoint(x: old.midX, y: old.midY)
        let bnd = CABasicAnimation(keyPath: "bounds")
        bnd.fromValue = CGRect(origin: .zero, size: old.size)
        let rad = CABasicAnimation(keyPath: "cornerRadius")
        rad.fromValue = 0
        for anim in [pos, bnd, rad] as [CABasicAnimation] {
            anim.duration = duration
            anim.timingFunction = curve
            layer.add(anim, forKey: "drawer.\(anim.keyPath ?? "x")")
        }
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
    /// 静音期间音量手势的拒绝日志同样每次手势只打一条（同降噪口径）
    private var mutedVolumeSkipLogged = false
    /// 本手势的轴向锁定（2026-11-16 手势 A 档）：首个 ≥6pt 主导方向定轴，
    /// 全程不换——横向 = seek 预览，纵向 = 左半亮度 / 右半音量。
    /// nil = 还没定（起手 <6pt 的微动）
    private var panAxisLocked: PanAxis?
    enum PanAxis: String { case horizontal, vertical }
    /// 当前打开的右侧抽屉（画布 22:72 倍速 / 22:73 选集，同时只允许一个）
    private(set) var openDrawer: FullscreenDrawerKind?
    private var drawerPanel: FullscreenDrawerPanel?
    /// 选集抽屉态的黑色底（画布 22:73 底 #000000 + 视频缩为 560×302）
    private var drawerBackdrop: UIView?
    /// 抽屉态的压暗层（画布 22:75 覆盖 a0.28，只在倍速抽屉态；选集态用纯黑底）
    private var drawerDim: UIView?
    #if DEBUG
    /// 样张钩子令牌（仅 Debug，见 PlayerPreviewEntry.swift 的说明）
    private var previewObservers: [NSObjectProtocol] = []
    private var previewPinTimer: Timer?
    #endif

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
        // 切集（含自动连播、选集抽屉跳转）后刷新顶栏剧名集数与互动数值：
        // item 就绪即元信息跟着换，不用另立切集通知（翻页 → pageSettled → load → isReady）
        playback.$isReady
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                guard ready else { return }
                self?.refreshEpisodeMeta()
            }
            .store(in: &cancellables)
        // 选集面板数据：FeedVM 装配后推进 subject（真实集号 + 下载态 + 提示）。
        // 只在抽屉打开时消费，**不要改挂 objectWillChange**——那会让每次进度 tick 重绘抽屉
        playback.episodePanelSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.applyEpisodePanelState(state) }
            .store(in: &cancellables)
        // 锁定态翻转：立刻重算控件可见性（锁上时全部收起，只剩解锁钮）
        playback.$isFullscreenLocked
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locked in
                print("PLAYER_DBG [Fullscreen] locked=\(locked)")
                self?.controls?.refreshLockState()
            }
            .store(in: &cancellables)
    }

    /// 播放页销毁：立即还原 videoLayer 并移除 window 上的全屏容器（无动画）
    func teardown() {
        cancellables.removeAll()
        guard container != nil else {
            print("PLAYER_DBG [Fullscreen] teardown noop reason=neverEntered")
            return
        }
        // 抽屉随容器一起销毁：先摘掉面板与缩小的视频矩形，避免 restoreVideoLayer 拿到被改的层
        dismissDrawer(animated: false)
        restoreVideoLayer()
        container?.removeFromSuperview()
        container = nil
        #if DEBUG
        previewTeardown()
        #endif
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
        // 抽屉挂着转体：面板与视频缩矩形都按新方向重排，否则会甩到屏幕外
        if openDrawer != nil {
            print("PLAYER_DBG [Fullscreen] angle CHANGE → close drawer first")
            dismissDrawer(animated: false)
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
        // ── 新回调接线（画布 22:1 的更多 / 倍速 / 选集 / 下一集 / 清晰度）──
        controls.onMore = { [weak self, weak controls] source in
            self?.presentMoreMenu(from: source, anchorView: controls)
        }
        controls.onRateTapped = { [weak self] in
            self?.presentDrawer(.rate)
        }
        controls.onEpisodeTapped = { [weak self] in
            self?.presentDrawer(.episodes)
        }
        controls.onQualityTapped = { [weak self] in
            // 本地 HLS 只有单一路径清晰度：不做假选项，给一句说明
            print("PLAYER_DBG [Fullscreen] quality tap → toast reason=singleVariant")
            self?.showControlsToast("本地片源只有原始清晰度")
        }
        container.addSubview(controls)
        self.controls = controls
        installGestures(on: container)
        // 音量桥挂进窗口树（2026-11-16 手势 A 档：竖滑右半调音量靠 MPVolumeView；
        // 随容器销毁，下次进全屏重新挂）
        PlayerBrightnessVolume.shared.attachVolumeBridge(to: container)
        // 顶栏剧名/集数与互动数值：进入时注入一次，切集时由 refreshEpisodeMeta 刷新
        refreshEpisodeMeta()

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
            #if DEBUG
            self.previewApplyAfterEnter()
            #endif
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
            dismissDrawer(animated: false)
            container?.removeFromSuperview()
            self.container = nil
            return
        }
        // 抽屉挂着直接退全屏：先撤抽屉（含视频缩矩形复原），否则退出动画起点是缩小的画面
        if openDrawer != nil {
            dismissDrawer(animated: false)
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
        // 树里从不存在携带旧坐标系 frame 的中间态。全屏路径不经首显机制：
        // opacity 强制归 1（进全屏前若处于首显隐藏态，退出后不能留在隐藏）
        PlayerSurfaceUIView.withoutLayerActions {
            layer.removeFromSuperlayer()
            layer.frame = surface.bounds
            layer.videoGravity = PlayerPagingScrollView.videoGravity(for: playback)
            layer.opacity = 1
            surface.layer.addSublayer(layer)
        }
        surface.markRevealed()
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

    // MARK: 顶栏/互动元信息（进入全屏与切集时刷新）

    /// 画布 22:16「剧名  第8集」+ 22:52/22:63 互动数值。
    /// 切集不在本类发起（走分页管线），故这里既在进入时注入，也在自动连播后按
    /// playback.$isReady 再刷一次——item 换好、元信息跟随，不用另开切集通知
    private func refreshEpisodeMeta() {
        guard let controls else { return }
        let index = playback.currentEpisodeIndex ?? 1
        controls.updateTitle(series: playback.seriesName, index: index)
        print("PLAYER_DBG [Fullscreen] meta series=\(playback.seriesName) index=\(index) total=\(playback.episodeTotal)")
    }

    // MARK: 右侧抽屉（画布 22:72 倍速 / 22:73 选集）

    /// 打开抽屉：同时只允许一个，重复点同一按钮则收起（切换语义）
    private func presentDrawer(_ kind: FullscreenDrawerKind) {
        guard let container else {
            print("PLAYER_DBG [Fullscreen] drawer SKIP reason=noContainer kind=\(kind)")
            return
        }
        if openDrawer == kind {
            print("PLAYER_DBG [Fullscreen] drawer toggle OFF kind=\(kind) reason=sameButton")
            dismissDrawer(animated: true)
            return
        }
        // 换抽屉：先撤旧的（不带动画，避免两层同时飞）
        if openDrawer != nil { dismissDrawer(animated: false) }
        print("PLAYER_DBG [Fullscreen] drawer open kind=\(kind) video=\(kind == .episodes ? "shrunk560x302" : "full")")
        openDrawer = kind

        let geo = currentGeometry()
        // 控件收起（抽屉有自己的关闭动作；解锁钮也不叠在抽屉上）
        controls?.hideTransient()

        switch kind {
        case .rate:
            // 画布 22:72：视频满屏 + 22:75 压暗层 #0B0C0E a0.28
            let dim = UIView(frame: container.bounds)
            dim.backgroundColor = DWUIColor.drawerDim.withAlphaComponent(0.28)
            dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            dim.alpha = 0
            // 压暗层在视频之上、面板之下：点它只关抽屉，不穿透去暂停
            let tap = UITapGestureRecognizer(target: self, action: #selector(drawerDimTapped))
            dim.addGestureRecognizer(tap)
            container.addSubview(dim)
            drawerDim = dim
            UIView.animate(withDuration: 0.2) { dim.alpha = 1 }

            let panel = RateDrawerPanel()
            panel.currentRate = playback.playbackRate
            panel.onSelect = { [weak self] rate in
                guard let self else { return }
                self.playback.setPlaybackRate(rate)
                self.controls?.keepVisible()
                // 选中即关（与竖屏浮层同语义）
                self.dismissDrawer(animated: true)
            }
            installDrawerPanel(panel, in: container, frame: geo.drawerFrame)

        case .episodes:
            // 画布 22:73：整体底 #000000，视频缩为 560×302 @(56,44) r2
            let backdrop = UIView(frame: container.bounds)
            backdrop.backgroundColor = .black
            backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            backdrop.alpha = 0
            let tap = UITapGestureRecognizer(target: self, action: #selector(drawerDimTapped))
            backdrop.addGestureRecognizer(tap)
            // 必须插到最底层：videoLayer 是直接 addSublayer 挂在 container.layer 上的，
            // 普通 addSubview 会排在它之上 —— 黑底把缩小后的视频整块糊掉
            //（模拟器样张实证：选集抽屉态左侧一片纯黑，看不到任何画面）
            container.insertSubview(backdrop, at: 0)
            drawerBackdrop = backdrop
            UIView.animate(withDuration: 0.2) { backdrop.alpha = 1 }
            container.setVideoRect(geo.shrunkVideoFrame, cornerRadius: 2, animated: true)

            // 面板数据来自 FeedVM 推给播放 VM 的专用通道（真实集号 + 下载态 + 提示），
            // 打开时取当前快照，之后由 episodePanelSubject 热更新（见 init 里的订阅）
            let state = playback.episodePanelSubject.value
            let panel = EpisodeDrawerPanel()
            panel.apply(state: state, current: drawerCurrentSort(state))
            panel.onSelect = { [weak self] sort in
                guard let self else { return }
                // 点按收口在 FeedVM：已下载 → 切集（true，收起抽屉）；
                // 未下载 → 入队下载 / 提示（false，抽屉留着看进度环与标题提示）
                let switched = self.playback.onEpisodeSelected?(sort) ?? false
                print("PLAYER_DBG [CHECK] drawerSelect sort=\(sort) switched=\(switched) → \(switched ? "close" : "keepOpen")")
                self.controls?.keepVisible()
                if switched { self.dismissDrawer(animated: true) }
            }
            panel.onClose = { [weak self] in
                self?.dismissDrawer(animated: true)
            }
            installDrawerPanel(panel, in: container, frame: geo.drawerFrame)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak panel] in
                panel?.revealCurrent()   // panel 本就是 EpisodeDrawerPanel?，无需 as? 再包一层
            }
        }
    }

    /// 抽屉「当前集」：播放器当前集优先，未加载时退到面板第一格
    private func drawerCurrentSort(_ state: EpisodePanelState) -> Int {
        playback.currentEpisodeIndex ?? state.items.first?.sort ?? 1
    }

    /// 面板快照热更新：只在选集抽屉打开时下发（下载进度/提示变化不重绘其它界面）
    private func applyEpisodePanelState(_ state: EpisodePanelState) {
        guard openDrawer == .episodes, let panel = drawerPanel as? EpisodeDrawerPanel else { return }
        let current = drawerCurrentSort(state)
        print("PLAYER_DBG [CHECK] drawerPanel apply cells=\(state.items.count) current=\(current) hint=\(state.hint ?? "nil")")
        panel.apply(state: state, current: current)
    }

    /// 面板挂载 + 右侧滑入动画。面板带 transform 不能 setFrame（会经逆变换重设 bounds），
    /// 故先用 frame 落位，动画只改 center
    private func installDrawerPanel(_ panel: FullscreenDrawerPanel,
                                    in container: FullscreenPlayerView,
                                    frame: CGRect) {
        panel.frame = frame
        let target = panel.center
        container.addSubview(panel)
        drawerPanel = panel
        // 从右侧屏外滑入：起手中心右移一个面板宽
        let offscreen = CGPoint(x: target.x + frame.width, y: target.y)
        if let layer = panel.layer as CALayer? {
            panel.center = offscreen
            let pos = CABasicAnimation(keyPath: "position.x")
            pos.fromValue = offscreen.x
            pos.toValue = target.x
            pos.duration = 0.26
            pos.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pos, forKey: "drawer.slideIn")
        }
        panel.center = target
    }

    /// 收起抽屉：面板飞出 + 视频矩形复原 + 压暗/黑底淡出
    private func dismissDrawer(animated: Bool) {
        let wasKind = openDrawer
        openDrawer = nil
        let panel = drawerPanel
        drawerPanel = nil
        let dim = drawerDim
        drawerDim = nil
        let backdrop = drawerBackdrop
        drawerBackdrop = nil
        guard wasKind != nil else { return }
        print("PLAYER_DBG [Fullscreen] drawer close kind=\(String(describing: wasKind)) animated=\(animated)")

        let finish = { [weak self] in
            panel?.removeFromSuperview()
            dim?.removeFromSuperview()
            backdrop?.removeFromSuperview()
            self?.container?.setVideoRect(nil, cornerRadius: 0, animated: false)
            self?.controls?.keepVisible()
        }
        guard animated, let panel else {
            finish()
            return
        }
        UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseInOut], animations: {
            panel.center = CGPoint(x: panel.center.x + panel.bounds.width, y: panel.center.y)
            panel.alpha = 0
            dim?.alpha = 0
            backdrop?.alpha = 0
        }, completion: { _ in finish() })
        // 视频矩形同时回弹（显式 CA 动画，裸 layer 禁了隐式动画）
        container?.setVideoRect(nil, cornerRadius: 0, animated: true)
    }

    private func currentGeometry() -> FullscreenLayoutGeometry {
        FullscreenLayoutGeometry(containerSize: container?.bounds.size ?? .zero,
                                 localInsets: Self.localInsets(rotationAngle: rotationAngle,
                                                               windowInsets: container?.window?.safeAreaInsets ?? .zero),
                                 screenSize: container?.window?.bounds.size ?? .zero)
    }

    @objc private func drawerDimTapped() {
        print("PLAYER_DBG [Fullscreen] drawer dim tap → close")
        dismissDrawer(animated: true)
    }

    // MARK: 更多菜单 / 下一集 / 提示

    private func presentMoreMenu(from source: UIView, anchorView: UIView?) {
        guard let host = controls ?? anchorView else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        // 下一集：原底栏左侧位置已改为播放/暂停（用户 2026-11-15），功能移到这里不丢
        sheet.addAction(UIAlertAction(title: "下一集", style: .default) { [weak self] _ in
            print("PLAYER_DBG [Fullscreen] menu next episode")
            self?.advanceToNextEpisode()
        })
        sheet.addAction(UIAlertAction(title: playback.isCleanScreen ? "退出清屏" : "清屏模式",
                                      style: .default) { [weak self] _ in
            self?.playback.isCleanScreen.toggle()
            print("PLAYER_DBG [Fullscreen] menu cleanScreen=\(self?.playback.isCleanScreen ?? false)")
        })
        sheet.addAction(UIAlertAction(title: playback.isMuted ? "取消静音" : "静音",
                                      style: .default) { [weak self] _ in
            self?.playback.isMuted.toggle()
            print("PLAYER_DBG [Fullscreen] menu muted=\(self?.playback.isMuted ?? false)")
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        // iPad / 横屏安全：popover 需要 sourceView，否则 iPad 上崩溃
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = source
            pop.sourceRect = source.bounds
            pop.permittedArrowDirections = []
        }
        host.window?.rootViewController?.presentedTop().present(sheet, animated: true)
        controls?.keepVisible()
    }

    private func advanceToNextEpisode() {
        let current = playback.currentEpisodeIndex ?? 0
        let total = max(playback.episodeTotal, 1)
        guard current > 0, current < total else {
            print("PLAYER_DBG [Fullscreen] next SKIP reason=noNext current=\(current) total=\(total)")
            showControlsToast("已经是最后一集")
            return
        }
        print("PLAYER_DBG [Fullscreen] next episode \(current) → \(current + 1) via autoAdvanceSort")
        playback.autoAdvanceSort = current + 1
        controls?.keepVisible()
    }

    private func showControlsToast(_ text: String) {
        guard let container else { return }
        let label = UILabel()
        label.text = text
        label.font = PlayerFullscreenControlsView.sansFont(13, weight: .regular)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.backgroundColor = DWUIColor.ratePanel.withAlphaComponent(0.92)
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.alpha = 0
        label.sizeToFit()
        let maxW = container.bounds.width * 0.5
        var size = label.bounds.size
        size.width = min(size.width + 32, maxW)
        size.height = max(size.height + 16, 36)
        let geo = currentGeometry()
        label.frame = CGRect(x: (container.bounds.width - size.width) / 2,
                             y: geo.Y(150),
                             width: size.width, height: size.height)
        container.addSubview(label)
        UIView.animate(withDuration: 0.16, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.24, delay: 1.4, animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
    }

    // MARK: 全屏手势（点按暂停 / 长按 2x / 横向相对 seek / 纵向亮度音量）
    //
    // 竖屏卡片六条仲裁约束的全屏版（UIKit 原生实现）：
    // ① 拖动先起 → seek 独占：pan .began 即 VM.beginSeekGesture，长按 perform 查闸门；
    // ② 长按先起 → 2x 独占：perform（按满 0.15s）才起 2x，allowableMovement 放开；
    //    2x 独占期间纵向漂移同样不调亮度/音量（handleSeekPan vertical 分支 guard）
    // ③ 长按松手 → 吞单击 250ms；④ 2x 只在 began（perform 等价态）里起；
    // ⑤ 松手才 seek（2026-11-16 手势 A 档）：拖动中只挂预览，.ended 提交（VM 内
    //    seek 落稳后 flush 进度）、.cancelled/.failed 丢弃；⑥ tap 查 VM.seek 闸门与抑制窗。

    private func installGestures(on container: FullscreenPlayerView) {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        container.addGestureRecognizer(tap)

        let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        long.minimumPressDuration = 0.15
        long.allowableMovement = 44
        // 识别前最大位移 44pt（2026-11-16 真机实证：放开到 10_000 时，连续横滑「松手
        // commit → 再按住」之间 >0.15s 的自然停顿必起 2x——旧闸门已关、新 pan 未达 10pt
        // 阈值，无拦截。收紧后：起步快（0.15s 内滑出 >44pt）长按 fail、横滑接管；起步慢
        // （按住不动）正常起 2x；allowableMovement 只约束识别前，2x 起来后指头漂移照样
        // 不中断，旧语义保留
        long.delegate = self
        container.addGestureRecognizer(long)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSeekPan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        container.addGestureRecognizer(pan)
        seekPan = pan
        print("PLAYER_DBG [Fullscreen] gestures installed (tap/longPress/seekPan)")
    }

    /// 落在控件上的触摸不交给容器手势：否则点「更多/锁/倍速」会连带触发容器 tap 的暂停。
    /// 只排除 UIControl 及其子视图（glyph/label），压暗层与空白区照常落给容器手势。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard let hit = touch.view else { return true }
        // 抽屉打开期间：压暗层 / 黑底自己带 tap（关抽屉），容器手势必须放掉这一下 ——
        // 两边都收到同一个触摸会变成「关掉抽屉又顺手暂停」（2026-11-15 用户要求
        // 点播放区也能收起面板，这条是它的防重入前提）
        if let dim = drawerDim, hit === dim {
            print("PLAYER_DBG [CHECK] fullscreen gesture SKIP reason=drawerDimOwnTap")
            return false
        }
        if let backdrop = drawerBackdrop, hit === backdrop {
            print("PLAYER_DBG [CHECK] fullscreen gesture SKIP reason=drawerBackdropOwnTap")
            return false
        }
        // 抽屉面板本体（含面板空白处）交给容器 tap → 关抽屉；面板里的 UIControl
        // （集数格 / 档位行 / 关闭按钮）下面照旧拒绝，保证点格子只选集不关面板
        guard let controls else { return true }
        var node: UIView? = hit
        while let cur = node, cur !== controls {
            if cur is UIControl {
                print("PLAYER_DBG [CHECK] fullscreen gesture REJECT reason=onControl \(type(of: cur))")
                return false
            }
            node = cur.superview
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 抽屉打开期间：只放行点按（点播放区 / 面板空白处 = 收起抽屉，用户 2026-11-15 要求）；
        // 拖拽与长按一律不接——点面板/网格不该顺带暂停视频或起 seek/2x
        if openDrawer != nil {
            guard gestureRecognizer is UITapGestureRecognizer else {
                print("PLAYER_DBG [CHECK] fullscreen gesture REJECT reason=drawerOpen")
                return false
            }
            print("PLAYER_DBG [CHECK] fullscreen gesture ALLOW reason=drawerOpenTapOnly")
            return true
        }
        // 锁定态：除「点按呼出解锁钮」外一切手势不接——不 seek、不起 2x（行业做法：
        // 锁定后手里握着的机器不该因为误触改进度，2026-11-15 用户拍板）
        if playback.isFullscreenLocked, !(gestureRecognizer is UITapGestureRecognizer) {
            print("PLAYER_DBG [CHECK] fullscreen gesture REJECT reason=locked")
            return false
        }
        // seekPan 全向接住（2026-11-16 手势 A 档）：横向主导 = seek 预览，
        // 纵向主导 = 左半亮度 / 右半音量（此前纵向直接 REJECT，全屏竖滑完全空手）。
        // 注意坐标口径：容器自转 ±90° 后本地 x = 视频横轴 = 持横屏用户的「左右」，
        // 本地 y 主导即用户感知的「竖滑」。轴的归属在 .changed 里按主导方向锁定。
        guard gestureRecognizer === seekPan, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let t = pan.translation(in: pan.view)
        print("PLAYER_DBG [CHECK] fullscreen seekPan shouldBegin tx=\(Int(t.x)) ty=\(Int(t.y)) → OK（轴向 .changed 锁定）")
        return true
    }

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        // 抽屉打开时点播放区（或面板空白处）= 收起抽屉，不动播放状态
        // （2026-11-15 用户要求：全屏选集面板弹出后点播放区也要能关掉）
        if let open = openDrawer {
            print("PLAYER_DBG [CHECK] fullscreen TAP drawer=\(open) → close drawer only")
            dismissDrawer(animated: true)
            return
        }
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
        // 锁定态（画布 22:31）：点按只做一件事——呼出解锁钮。不暂停、不切换控件层
        if playback.isFullscreenLocked {
            print("PLAYER_DBG [CHECK] fullscreen TAP locked → reveal unlock only")
            controls?.showTransient()
            return
        }
        // 清屏态（控件全收起）：第一下点按只呼出控件，不暂停/播放。
        // 否则「想点一下调出控件」会把正看着的片子停掉 —— 2026-11-15 用户实报。
        if controls?.isChromeVisible != true {
            print("PLAYER_DBG [CHECK] fullscreen TAP chrome=hidden → reveal controls only")
            controls?.showTransient()
            return
        }
        print("PLAYER_DBG [CHECK] fullscreen TAP chrome=visible → togglePlayback")
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
            mutedVolumeSkipLogged = false
            panAxisLocked = nil            // 每次手势重新锁轴（首个 ≥6pt 主导方向定轴）
            playback.beginSeekGesture()
            print("PLAYER_DBG [CHECK] fullscreen seekPan began scrubBase=\(String(format: "%.2f", scrubBaseFraction ?? 0))")
        case .changed:
            let t = pan.translation(in: view)
            // 轴锁定（2026-11-16 手势 A 档）：首个 ≥6pt 的主导方向定轴，全程不换——
            // 行业做法；不锁的话 seek 拖动稍微带点纵向就窜到亮度/音量，来回横跳
            if panAxisLocked == nil {
                guard abs(t.x) > 6 || abs(t.y) > 6 else { return }
                panAxisLocked = abs(t.x) >= abs(t.y) ? .horizontal : .vertical
                print("PLAYER_DBG [CHECK] fullscreen seekPan axis=\(panAxisLocked!.rawValue) tx=\(Int(t.x)) ty=\(Int(t.y))")
            }
            switch panAxisLocked! {
            case .horizontal:
                guard abs(t.x) > 6, let base = scrubBaseFraction else { return }
                let fraction = min(max(base + PlayerGesturePolicy.scrubDelta(translationX: t.x, screenWidth: view.bounds.width), 0), 1)
                print("PLAYER_DBG [CHECK] fullscreen seekPan dx=\(Int(t.x)) fraction=\(String(format: "%.2f", fraction))")
                // 2026-11-16 手势 A 档：拖动中不实时 seek（行业全如此），只挂目标预览；
                // 松手 commitScrubThenEndGesture 才真正 seek
                playback.scrubPreview(fraction: fraction)
            case .vertical:
                // 2x 先起独占本次触摸（与 seek 同一条仲裁哲学）：按住 2x 期间的纵向
                // 漂移不得调亮度/音量，否则「长按看片 + 手漂」会悄悄改系统亮度
                guard !playback.isFastForwarding else { return }
                // 左半亮度 / 右半音量：本地 x 即视频横轴（持横屏用户的左右），
                // 锁轴那一刻定边，手势中途不换（防跨中线时亮度音量突然互换）
                let sideLeft = pan.location(in: view).x < view.bounds.width / 2
                let window = view.window
                let total = max(view.bounds.height, 1)
                if sideLeft {
                    let current = PlayerBrightnessVolume.shared.brightness(in: window)
                    let target = min(max(current - t.y / total, 0), 1)   // 上滑增亮、下滑减亮
                    PlayerBrightnessVolume.shared.setBrightness(target, in: window)
                    controls?.showAdjustFeedback("亮度 \(Int(target * 100))%")
                } else {
                    // 静音时不响应音量手势（2026-11-16 用户拍板）：系统音量变了也听不到，
                    // 浮层刷新一个「听不见的值」反而困惑——先解除静音（静音钮/更多菜单）再调；
                    // 同一条手势内只打一条拒绝日志
                    guard !playback.isMuted else {
                        if !mutedVolumeSkipLogged {
                            mutedVolumeSkipLogged = true
                            print("PLAYER_DBG [CHECK] fullscreen volume SKIP reason=muted")
                        }
                        return
                    }
                    let current = CGFloat(PlayerBrightnessVolume.shared.volume)
                    let target = min(max(current - t.y / total, 0), 1)   // 上滑增音、下滑减音
                    PlayerBrightnessVolume.shared.setVolume(Float(target))
                    controls?.showAdjustFeedback("音量 \(Int(target * 100))%")
                }
                print("PLAYER_DBG [CHECK] fullscreen adjust side=\(sideLeft ? "brightness" : "volume") ty=\(Int(t.y))")
            }
        case .ended, .cancelled, .failed:
            let wasEnded = pan.state == .ended
            scrubBaseFraction = nil
            panAxisLocked = nil
            // .ended 提交暂存目标（seek 落稳后 flush）；打断路径只丢弃不 seek
            if wasEnded {
                playback.commitScrubThenEndGesture()
            } else {
                playback.cancelScrubThenEndGesture()
            }
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

#if DEBUG
// MARK: - 样张钩子（仅 Debug）

// 模拟器点不了也转不了屏，横屏三张稿（22:1 / 22:72 / 22:73）只能靠启动参数定帧。
// 正式路径一行都不改：全部由 PlayerPreviewFlags 门控，Release 整段不编译。
extension PlayerFullscreenController {
    /// 进入全屏动画结束后调（performEnter 的 completion 里）
    func previewApplyAfterEnter() {
        guard PlayerPreviewFlags.enabled else { return }
        if PlayerPreviewFlags.locked {
            // 锁定态视觉定帧：锁上后只应剩「解锁」一枚（配 -playerPinControls 保活）
            playback.isFullscreenLocked = true
            print("PLAYER_DBG [Preview] locked forced isFullscreenLocked=\(playback.isFullscreenLocked)")
        }
        if PlayerPreviewFlags.paused, playback.isPlaying {
            // 定帧「暂停态」：点一次暂停，图标应翻成播放三角（中部与底栏同拍）
            playback.togglePlayback()
            print("PLAYER_DBG [Preview] paused forced isPlaying=\(playback.isPlaying)")
        }
        if PlayerPreviewFlags.pinControls {
            controls?.showTransient()
            previewPinTimer?.invalidate()
            // 3s 自动收起会截到空屏：每 2s 重置一次计时
            previewPinTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.controls?.showTransient()
            }
        }
        guard let name = PlayerPreviewFlags.drawer else { return }
        let kind: FullscreenDrawerKind = (name == "episodes" || name == "episode") ? .episodes : .rate
        print("PLAYER_DBG [Preview] auto open drawer kind=\(kind)")
        // 等一帧再开：面板滑入动画需要容器已完成布局
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.presentDrawer(kind)
        }
    }

    /// 控制器释放时停掉钉控件计时器（teardown 已清 cancellables，这里补 Timer）
    func previewTeardown() {
        previewPinTimer?.invalidate()
        previewPinTimer = nil
    }
}
#endif

// MARK: - 呈现用的顶层控制器

extension UIViewController {
    /// ActionSheet / Alert 必须挂在最顶层已呈现控制器上，否则
    /// 「Attempt to present ... which is already presenting」静默失败
    func presentedTop() -> UIViewController {
        if let presented = presentedViewController {
            return presented.presentedTop()
        }
        if let nav = self as? UINavigationController, let top = nav.visibleViewController {
            return top.presentedTop()
        }
        if let tab = self as? UITabBarController, let top = tab.selectedViewController {
            return top.presentedTop()
        }
        return self
    }
}
