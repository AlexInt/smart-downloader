import UIKit
import AVFoundation

// MARK: - 播放视频承载视图（单例容器）
//
// 唯一渲染视频的 UIView。由 PlayerPagingScrollView.Coordinator 创建并 insertSubview 到
// 分页滚动层（z 序在全部卡片之下），frame 持续对位「活跃卡」：视频随内容滚动/翻页移动，
// 卡片不再各自持有 surface（ZFPlayer「单容器搬家」同思路）。触摸穿透。
//
// 视频层是**可搬运的子层**（不用 layerClass 背板层——view 的背板层不能离开自己的 view）：
// 全屏时整个子层搬到全屏容器，退出时搬回，AVPlayer 不间断（PlayerFullscreenController）。
// App 已锁竖屏：gravity 只按片源方向定（横屏片源 fit / 竖屏片源 fill），
// 不再随持屏方向切换——此前 fit↔fill 二值跳变即「中间条突变全屏」的根因。
/// `AVPlayerLayer` 子类：多接一层「覆盖子层」（切集冻帧），让它跟着自己的 bounds 走。
/// iOS 上 `CALayer.autoresizingMask` 不可用（macOS-only），子层尺寸只能在 layoutSublayers 里铺。
final class VideoPlayerLayer: AVPlayerLayer {
    /// 覆盖子层（切集冻帧层），始终铺满自身 bounds
    weak var overlayLayer: CALayer?

    override func layoutSublayers() {
        super.layoutSublayers()
        syncOverlayFrame()
    }

    /// 视频层 frame/bounds 被外部改写后立即对齐覆盖层（不必等一次布局）
    func syncOverlayFrame() {
        guard let overlay = overlayLayer, overlay.frame != bounds else { return }
        PlayerSurfaceUIView.withoutLayerActions {
            overlay.frame = bounds
        }
    }
}

/// 播放视频承载视图（单例容器）
final class PlayerSurfaceUIView: UIView {
    /// 视频子层：全屏/退出时在 surface 与全屏容器之间搬运
    private(set) lazy var videoLayer: VideoPlayerLayer = {
        let layer = VideoPlayerLayer()
        self.layer.addSublayer(layer)
        return layer
    }()

    var player: AVPlayer? {
        get { videoLayer.player }
        set { videoLayer.player = newValue }
    }

    /// layer 搬走期间的跳过日志只打一次（SwiftUI 每轮 update 都会重设一次，降噪）
    private var loggedAwaySkip = false
    /// 视频首显开关：加载期间藏住条带（渐变盖着不可见），ready 当拍交叉淡入
    private var isVideoRevealed = true

    // MARK: - 切集冻帧层（全屏切集不闪）

    /// 冻帧层：`videoLayer` 的**子层**——随视频层一起搬进/搬出全屏容器、跟着旋转缩放，
    /// 无需全屏控制器参与。初始透明，靠 `holdFreezeFrame` 挂图。
    /// 尺寸由 `VideoPlayerLayer.layoutSublayers` 跟随视频层 bounds（iOS 上
    /// `CALayer.autoresizingMask` 不可用，是 macOS-only）
    private lazy var freezeLayer: CALayer = {
        let layer = CALayer()
        layer.opacity = 0
        layer.contentsGravity = .resizeAspectFill
        videoLayer.overlayLayer = layer
        videoLayer.addSublayer(layer)
        return layer
    }()
    /// 冻帧持有中（持有期间不动 videoLayer.opacity，由冻帧层独占遮挡）
    private var isHoldingFreeze = false
    /// 冻帧最长持有时间：加载失败/超时时兜底放掉，否则永远盖着旧画面
    private var freezeWatchdog: DispatchWorkItem?

    /// 挂上切集冻帧（全屏路径用）：盖住换 item 期间的黑底。
    /// 无图（快照 MISS / 纯音频）直接跳过 —— 那就退化成原来的「露出黑底」，
    /// 比把一段错误画面盖在屏幕上好。
    func holdFreezeFrame(_ image: UIImage?) {
        guard let image, let cg = image.cgImage else {
            print("PLAYER_DBG [FreezeFrame] hold SKIP reason=noImage (退化为原路径)")
            return
        }
        let layer = freezeLayer
        Self.withoutLayerActions {
            layer.frame = videoLayer.bounds
            layer.contents = cg
            layer.contentsScale = image.scale
            layer.contentsGravity = Self.contentsGravity(for: videoLayer.videoGravity)
            layer.opacity = 1
            layer.removeAnimation(forKey: "freeze.fadeOut")
        }
        isHoldingFreeze = true
        freezeWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.releaseFreezeFrame(reason: "watchdog6s")
        }
        freezeWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        print("PLAYER_DBG [CHECK] freeze HOLD \(cg.width)x\(cg.height) layer=\(layer.frame) gravity=\(videoLayer.videoGravity == .resizeAspect ? "fit" : "fill")")
    }

    /// 放掉冻帧：0.15s 淡出（与新 item 首帧重合），淡完清 contents 释放像素
    func releaseFreezeFrame(reason: String) {
        guard isHoldingFreeze else { return }
        isHoldingFreeze = false
        freezeWatchdog?.cancel()
        freezeWatchdog = nil
        let layer = freezeLayer
        Self.withoutLayerActions {
            layer.opacity = 0
        }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1
        anim.toValue = 0
        anim.duration = 0.15
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "freeze.fadeOut")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.isHoldingFreeze else { return }
            PlayerSurfaceUIView.withoutLayerActions {
                self.freezeLayer.contents = nil
            }
        }
        print("PLAYER_DBG [CHECK] freeze RELEASE reason=\(reason)")
    }

    /// 无动画立刻丢掉冻帧（全屏退出还原：路径本身连续，不需要交叉）
    private func discardFreezeFrame() {
        guard isHoldingFreeze || freezeLayer.contents != nil else { return }
        isHoldingFreeze = false
        freezeWatchdog?.cancel()
        freezeWatchdog = nil
        Self.withoutLayerActions {
            freezeLayer.opacity = 0
            freezeLayer.contents = nil
            freezeLayer.removeAnimation(forKey: "freeze.fadeOut")
        }
    }

    /// UIImage 的层内容重力要跟视频层的 gravity 走，否则 fit 片源会被冻帧裁成 fill
    private static func contentsGravity(for gravity: AVLayerVideoGravity) -> CALayerContentsGravity {
        switch gravity {
        case .resizeAspect: return .resizeAspect
        case .resizeAspectFill: return .resizeAspectFill
        case .resize: return .resize
        default: return .resizeAspect
        }
    }

    /// 新一集开始（isReady 置 false 时调）：藏住条带，等 isReady 翻转后立即交叉淡入。
    /// 幂等：已藏住时不重复写（退页/订阅重复触发都会到这）
    /// freezeFrame：全屏切集时用冻帧盖屏（竖屏传 nil，走原来的藏条带 + 渐变交叉）
    func concealForReveal(freezeFrame: UIImage? = nil) {
        // ── 全屏（视频层已搬离本 view）：没有卡片渐变兜底 ──
        // 原来这里把 videoLayer.opacity 置 0，露出的就是全屏容器的黑底 ——
        // 用户实报「全屏选集切集闪一下」的直接来源。改成：冻住上一帧盖着，
        // **不碰 videoLayer.opacity**（新 item 首帧直接落在冻帧底下）。
        if videoLayer.superlayer !== layer {
            if freezeFrame != nil {
                holdFreezeFrame(freezeFrame)
                print("PLAYER_DBG [CHECK] video conceal FULLSCREEN → holdFreezeFrame")
            } else {
                print("PLAYER_DBG [CHECK] video conceal FULLSCREEN SKIP reason=noFreezeFrame")
            }
            return
        }
        guard !isVideoRevealed || videoLayer.opacity > 0 else { return }
        isVideoRevealed = false
        PlayerSurfaceUIView.withoutLayerActions {
            videoLayer.opacity = 0
            videoLayer.removeAnimation(forKey: "reveal.fadeIn")
        }
        startRevealProbe(phase: "conceal")
        print("PLAYER_DBG [CHECK] video conceal → waitReady")
    }

    /// isReady 翻转时调：立即淡入（与卡片渐变淡出同时起步、同时长 0.15s）——
    /// 交叉渐变：任意时刻「紫色余量 + 视频显示量 ≈ 1」，无黑窗无突现。
    /// 探针实证：上一版延迟 150ms 起手 + 默认 250ms 隐式爬升，与渐变淡完之间
    //开了 ~100ms 全黑窗口（「突然由大到小闪一下」的直接来源）。
    /// 淡入用显式 CABasicAnimation——UIView.animate 对裸子层的 opacity 不产生动画
    ///（子层无 view 代理，曾实际跑的是默认 0.25s 隐式动画，时序不可控）
    func scheduleVideoReveal() {
        // 冻帧持有态（全屏切集）：视频层一直保持 opacity 1，放掉冻帧就是全部动作
        if isHoldingFreeze {
            releaseFreezeFrame(reason: "ready")
            print("PLAYER_DBG [CHECK] video reveal FULLSCREEN → releaseFreezeFrame (no layer fade)")
            return
        }
        guard !isVideoRevealed else { return }
        isVideoRevealed = true
        PlayerSurfaceUIView.withoutLayerActions {
            videoLayer.opacity = 1
        }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0
        anim.toValue = 1
        anim.duration = 0.15
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        videoLayer.add(anim, forKey: "reveal.fadeIn")
        print("PLAYER_DBG [CHECK] video reveal fadeIn (immediate, crossfade with gradient)")
    }

    /// 全屏退出还原时调：强制回到已显示态（全屏路径不经首显机制，退出动画本身连续）
    func markRevealed() {
        isVideoRevealed = true
        discardFreezeFrame()
        PlayerSurfaceUIView.withoutLayerActions {
            videoLayer.opacity = 1
            videoLayer.removeAnimation(forKey: "reveal.fadeIn")
        }
    }

    // MARK: - 首显探针（排障用，排障后保留）
    // 「由大到小闪一下」已两轮未定位：reveal 淡入起手时 layer 的 presentation 状态
    // （首帧是否已提交、frame 是否已落位）没有直接证据。这里用 CADisplayLink 在
    // reveal 窗口内逐帧记录：时间、opacity 的 presentation/model 值、frame、
    // surface frame——一次真机日志即可钉死帧序。
    private var revealProbe: CADisplayLink?
    private var revealProbeStart: CFTimeInterval = 0

    /// 开启探针：re conceal → reveal 淡入结束后自动停（最多 2s 自保）
    func startRevealProbe(phase: String) {
        print("PLAYER_DBG [CHECK] revealProbe phase=\(phase) t=0ms surface=\(frame) layer=\(videoLayer.frame) opacityModel=\(videoLayer.opacity)")
        guard revealProbe == nil else { return }
        revealProbeStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(revealProbeTick(_:)))
        link.add(to: .main, forMode: .common)
        revealProbe = link
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.stopRevealProbe(reason: "timeout2s")
        }
    }

    func stopRevealProbe(reason: String) {
        guard let link = revealProbe else { return }
        link.invalidate()
        revealProbe = nil
        print("PLAYER_DBG [CHECK] revealProbe STOP reason=\(reason)")
    }

    @objc private func revealProbeTick(_ link: CADisplayLink) {
        let ms = Int((CACurrentMediaTime() - revealProbeStart) * 1000)
        // presentation opacity：淡入过程中它才是用户真实看到的值
        let presented = videoLayer.presentation()?.opacity ?? -1
        let pf = videoLayer.presentation()?.frame ?? .null
        print("PLAYER_DBG [CHECK] revealProbe frame t=\(ms)ms opModel=\(videoLayer.opacity) opPresented=\(String(format: "%.2f", presented)) layerFrame=\(videoLayer.frame) presentFrame=\(pf) surface=\(frame)")
        // 淡入完成（model 与 presentation 都到 1）即停
        if videoLayer.opacity >= 1, presented >= 0.99 {
            stopRevealProbe(reason: "fadeInDone")
        }
    }

    var videoGravity: AVLayerVideoGravity {
        get { videoLayer.videoGravity }
        set {
            // 全屏期间 videoLayer 搬在全屏容器里，gravity 由控制器管（fill）：
            // SwiftUI 周期性 updateSurfaceContainer 会重设 surface.videoGravity（fit），
            // 穿透写入会把全屏容器的 fill 改掉（横屏画面突然回缩/出黑边）
            guard videoLayer.superlayer === layer else {
                if !loggedAwaySkip {
                    loggedAwaySkip = true
                    print("PLAYER_DBG [CHECK] surface gravity SET SKIP reason=layerAway wanted=\(newValue == .resizeAspect ? "fit" : "fill")")
                }
                return
            }
            loggedAwaySkip = false
            guard videoLayer.videoGravity != newValue else { return }
            videoLayer.videoGravity = newValue
            print("PLAYER_DBG [CHECK] surface gravity APPLY \(newValue == .resizeAspect ? "fit" : "fill")")
        }
    }

    /// videoLayer 是裸 CALayer（手动 addSublayer 的子层，非 UIView 背板层）：
    /// 直接改 frame 会触发 0.25s 隐式动画——UIView 只关自己背板层的隐式动作，管不到子层。
    /// 进/出全屏时 layer 的 frame 要在两个坐标系间切换，隐式动画让视频「飞一下」
    /// （刚进竖屏 / 横转竖都抖一下的根因）。所有 videoLayer 几何写入统一走这里禁用。
    /// 只影响隐式动画（action 查找），不影响显式 add 的 CAAnimation。
    static func withoutLayerActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 视频子层在自己身上时才跟随布局；被搬走到全屏容器期间由全屏容器管 frame。
        // 值没变不写（滚动期间 bounds 不变，避免无谓写入）
        if videoLayer.superlayer === layer, videoLayer.frame != bounds {
            Self.withoutLayerActions {
                videoLayer.frame = bounds
            }
        }
    }
}
