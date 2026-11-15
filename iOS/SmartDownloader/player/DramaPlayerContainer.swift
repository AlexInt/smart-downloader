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
            // 播放页沉浸式：隐藏状态栏（用户 2026-11-15 要求）。
            // App 锁竖屏、横屏靠容器自转，系统状态栏仍按竖屏画在屏幕一侧，
            // 与旋转后的画面叠在一起（「15:46 / 5G / 89%」压在视频上）。
            .statusBarHidden(true)
    }
}
