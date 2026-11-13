import SwiftUI
import AVFoundation

/// AVPlayerLayer 承载视图。单一职责：把 AVPlayer 的画面渲染到 SwiftUI，不含交互与业务。
struct PlayerSurfaceView: UIViewRepresentable {
    let player: AVPlayer?
    /// 渲染缩放模式：片源与持屏方向一致 = fill 拉满，错配 = fit 完整显示（黑边）。
    /// 由调用方（DramaPlayerView.surfaceGravity）按 VM 的 videoIsLandscape 与屏幕几何计算。
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> PlayerSurfaceUIView {
        let view = PlayerSurfaceUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false   // 触摸交给 SwiftUI 层
        return view
    }

    func updateUIView(_ uiView: PlayerSurfaceUIView, context: Context) {
        // player 与 gravity 都可能单独变化（旋转/换集）：各自幂等赋值，不做跳过优化
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        uiView.playerLayer.videoGravity = videoGravity
    }
}

final class PlayerSurfaceUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
