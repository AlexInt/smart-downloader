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
            print("PERF_DBG exit t=\(PERF.ms()) phase=onClose (clearBinding + dismiss)")
            onClose()
            dismiss()
        })
            .onAppear {
                print("PLAYER_DBG [Container] appear series=\(request.seriesName)")
                print("PLAYER_DBG [Container] appear → configure")
                feedVM.configure(request: request)
            }
            .onDisappear {
                print("PERF_DBG exit t=\(PERF.ms()) phase=containerDisappear (feedVM.stop begin)")
                feedVM.stop()
                print("PERF_DBG exit t=\(PERF.ms()) phase=containerDisappearDone (feedVM.stop returned)")
            }
    }
}
