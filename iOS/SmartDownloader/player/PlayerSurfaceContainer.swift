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
    /// 视频首显开关：isReady 翻转后不立即上屏，等 layer 首帧提交（~150ms）再淡入——
    /// 渐变淡出与 AVPlayerLayer 首帧提交是两个异步事件，直接对齐会露出「渐变退了底下
    /// 还是黑的，条带啪地出现」；错开并交叉淡入，两个顺序都不会黑屏
    private var isVideoRevealed = true
    /// 首显淡入工作项
    private var revealWork: DispatchWorkItem?

    /// 新一集开始（isReady 置 false 时调）：藏住条带，等 isReady 翻转后延迟淡入
    func concealForReveal() {
        revealWork?.cancel()
        isVideoRevealed = false
        PlayerSurfaceUIView.withoutLayerActions {
            videoLayer.opacity = 0
        }
        print("PLAYER_DBG [CHECK] video conceal → waitFirstFrame")
    }

    /// isReady 翻转时调：150ms 后淡入（等 AVPlayerLayer 首帧提交，与渐变淡出错开）
    func scheduleVideoReveal() {
        guard !isVideoRevealed else { return }
        revealWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.videoLayer.superlayer === self.layer else { return }
            self.isVideoRevealed = true
            print("PLAYER_DBG [CHECK] video reveal fadeIn (firstFrameDelay)")
            UIView.animate(withDuration: 0.15, animations: {
                self.videoLayer.opacity = 1
            })
        }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 全屏退出还原时调：强制回到已显示态（全屏路径不经首显机制，退出动画本身连续）
    func markRevealed() {
        revealWork?.cancel()
        isVideoRevealed = true
        PlayerSurfaceUIView.withoutLayerActions {
            videoLayer.opacity = 1
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
