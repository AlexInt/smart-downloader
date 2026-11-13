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

    var videoGravity: AVLayerVideoGravity {
        get { videoLayer.videoGravity }
        set { videoLayer.videoGravity = newValue }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 视频子层在自己身上时才跟随布局；被搬走到全屏容器期间由全屏容器管 frame
        if videoLayer.superlayer === layer {
            videoLayer.frame = bounds
        }
    }
}
