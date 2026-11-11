import SwiftUI
import AVFoundation

/// AVPlayerLayer 承载视图。单一职责：把 AVPlayer 的画面渲染到 SwiftUI，不含交互与业务。
struct PlayerSurfaceView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerSurfaceUIView {
        let view = PlayerSurfaceUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false   // 触摸交给 SwiftUI 层
        return view
    }

    func updateUIView(_ uiView: PlayerSurfaceUIView, context: Context) {
        guard uiView.playerLayer.player !== player else { return }
        uiView.playerLayer.player = player
    }
}

final class PlayerSurfaceUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
