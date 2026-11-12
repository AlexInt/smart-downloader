import SwiftUI

// MARK: - 沉浸式播放容器（fullScreenCover 内容）

/// 组装根：只注入依赖，不含任何业务逻辑。
/// 分层：PlaybackQueueService / PlaybackPlayerService / PlayerPreferences（Service）
/// → DramaPlayerViewModel / PlayerFeedViewModel（ViewModel）
/// → PlayerFeedView / DramaPlayerView / Components/ToastView（View）。
struct DramaPlayerContainer: View {
    let request: ImmersivePlaybackRequest
    /// 显式关闭：把外层 fullScreenCover(item:) 的绑定置 nil，比只调 dismiss() 可靠
    var onClose: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @StateObject private var feedVM = PlayerFeedViewModel()

    var body: some View {
        PlayerFeedView(vm: feedVM, onClose: {
            print("PLAYER_DBG [Container] onClose → clearBinding + dismiss")
            onClose()
            dismiss()
        })
            .onAppear {
                print("PLAYER_DBG [Container] appear series=\(request.seriesName)")
                print("PLAYER_DBG [Container] appear → configure")
                feedVM.configure(request: request)
            }
            .onDisappear {
                print("PLAYER_DBG [Container] disappear → stop")
                feedVM.stop()
            }
    }
}
