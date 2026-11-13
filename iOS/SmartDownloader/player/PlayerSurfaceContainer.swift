import UIKit
import AVFoundation

// MARK: - 播放视频承载视图（单例容器）
//
// 唯一渲染视频的 UIView（layerClass = AVPlayerLayer）。由 PlayerPagingScrollView.Coordinator
// 创建并 insertSubview 到分页滚动层（z 序在全部卡片之下），frame 持续对位「活跃卡」：
// 视频随内容滚动/翻页移动，卡片不再各自持有 surface（ZFPlayer「单容器搬家」同思路）。
// 卡片在视频区透明（渐变占位淡出后露出容器），触摸穿透（isUserInteractionEnabled=false）。
// App 已锁竖屏：gravity 只按片源方向定（横屏片源 fit / 竖屏片源 fill），
// 不再随持屏方向切换——此前 fit↔fill 二值跳变即「中间条突变全屏」的根因。
final class PlayerSurfaceUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
