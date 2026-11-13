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
final class PlayerSurfaceUIView: UIView {
    /// 视频子层：全屏/退出时在 surface 与全屏容器之间搬运
    private(set) lazy var videoLayer: AVPlayerLayer = {
        let layer = AVPlayerLayer()
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

    /// 新一集开始（isReady 置 false 时调）：藏住条带，等 isReady 翻转后立即交叉淡入。
    /// 幂等：已藏住时不重复写（退页/订阅重复触发都会到这）
    func concealForReveal() {
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
