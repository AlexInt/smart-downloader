import SwiftUI
import AVFoundation

/// DramaWave · 分页播放列表里的单张卡片（中文版 / 紫色）
///
/// 由设计稿「播放页 · 中文版」逐节点映射，坐标基准 390×840。
/// - 视频 / 加载渐变 / 压暗遮罩 / 手势层：铺满整屏，不参与设计稿缩放。
/// - 文字 / 按钮 / 图标：留在 390×840 内等比 contain 缩放，控件不会被裁。
/// - 纵向翻页交给系统 ScrollView；本视图的手势只处理单击、长按倍速、
///   进度带内水平 seek、边界意图（判定逻辑在 PlayerGesturePolicy）。
struct DramaPlayerView: View {
    let episode: DramaEpisode
    @ObservedObject var playback: DramaPlayerViewModel
    /// 只有当前页绑定播放器；相邻页显示渐变占位
    let player: AVPlayer?
    let isActive: Bool
    var onClose: () -> Void = {}
    var hasNextEpisode = false
    var isEpisodeAvailable = true
    var nextEpisodeAvailable = true
    var toastText: String? = nil
    private var timeText: String {
        playback.isReady ? playback.currentTimeText : (episode.previewCurrentTime ?? "00:00")
    }
    private var durationText: String {
        playback.isReady ? playback.durationText : (episode.previewDuration ?? "00:00")
    }
    private var progressValue: CGFloat {
        CGFloat(playback.isReady ? playback.progress : episode.previewProgress)
    }

    var body: some View {
        GeometryReader { geo in
            // UI 层用 contain：宁可留一点相对空隙，也不把返回按钮 / 底部提示裁出屏幕
            let scale = min(geo.size.width / DWLayout.designWidth,
                            geo.size.height / DWLayout.designHeight)

            ZStack(alignment: .topLeading) {
                // ── ① 视频：只有当前页绑定播放器 ───────────────
                PlayerSurfaceView(player: isActive ? player : nil)
                    .opacity(isActive && playback.isReady ? 1 : 0)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)

                // ── ② 加载态渐变：相邻页与加载中都显示 ─────────
                ZStack(alignment: .center) {
                    LinearGradient(stops: [
                        .init(color: DWColor.videoTop, location: 0),
                        .init(color: DWColor.videoMid, location: 0.5),
                        .init(color: DWColor.videoBottom, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                    RadialGradient(stops: [
                        .init(color: DWColor.glowCenter.opacity(0.22), location: 0),
                        .init(color: DWColor.glowEdge.opacity(0), location: 1)
                    ], center: .center, startRadius: 0, endRadius: 175 * scale)
                    .frame(width: geo.size.width, height: geo.size.height * 0.45)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .opacity(isActive && playback.isReady ? 0 : 1)
                .allowsHitTesting(false)

                // ── ③ 上下压暗：按屏幕比例铺满，边缘不留亮框 ──
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.8), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.size.height * 0.24)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.size.height * 0.36)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .allowsHitTesting(false)

                // ── ④ 手势：点按 / 长按上移到 PlayerFeedView 的 ScrollView 同层级。
                //    卡片内不放任何覆盖全屏的手势层，确保系统 pan 不被子视图抢走。 ─

                // ── ⑤ 设计稿 UI 层（390×840，只含文字/按钮/图标） ─
                designOverlay
                    .frame(width: DWLayout.designWidth, height: DWLayout.designHeight)
                    .scaleEffect(scale)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .background(DWColor.background.ignoresSafeArea())
    }

    /// 设计稿节点，坐标一律来自设计文件，勿凭目测调整。
    /// 返回按钮放在最后并抬到最高层级，保证关闭入口一定点得到。
    @ViewBuilder
    private var designOverlay: some View {
        ZStack(alignment: .topLeading) {
            // 顶部集数胶囊
            RoundedRectangle(cornerRadius: DWRadius.chip)
                .fill(.black.opacity(0.45))
                .designFrame(125, 50, 140, 26)
                .allowsHitTesting(false)

            Text(episode.episodeLabel)
                .font(DWFont.cn(12, .medium))
                .foregroundStyle(DWColor.textPrimary)
                .multilineTextAlignment(.center)
                .designFrame(125, 55, 140, 16)
                .allowsHitTesting(false)

            Button { playback.isMuted.toggle() } label: {
                Image("ic_sound")
                    .renderingMode(.template)
                    .resizable().scaledToFit()
                    .foregroundStyle(playback.isMuted ? DWColor.textHint : .white)
                    .frame(width: 26, height: 26)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(329, 41, 44, 44)

            // 剧集字幕（本地 HLS 无字幕轨时整块隐藏）
            if let lines = episode.subtitleLines {
                RoundedRectangle(cornerRadius: DWRadius.subtitle)
                    .fill(.black.opacity(0.32))
                    .designFrame(45, 396, 270, 52)
                    .allowsHitTesting(false)

                Text(lines.0)
                    .font(DWFont.cn(15, .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .designFrame(127, 404, 130, 22)
                    .allowsHitTesting(false)

                Text(lines.1)
                    .font(DWFont.cn(15, .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .designFrame(112, 426, 155, 22)
                    .allowsHitTesting(false)
            }

            // 左下信息区
            Text(episode.account)
                .font(DWFont.cn(14, .bold))
                .foregroundStyle(.white)
                .designFrame(20, 576, 290, 20, alignment: .leading)
                .allowsHitTesting(false)

            Text(episode.title)
                .font(DWFont.cn(16, .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .designFrame(20, 598, 290, 23, alignment: .leading)
                .allowsHitTesting(false)

            if let caption = episode.caption {
                Text(caption)
                    .font(DWFont.cn(12, .regular))
                    .foregroundStyle(DWColor.textBody)
                    .lineSpacing(5)
                    .lineLimit(1)
                    .designFrame(20, 622, 288, 17, alignment: .leading)
                    .allowsHitTesting(false)
            }

            if let tags = episode.tags {
                Text(tags)
                    .font(DWFont.cn(12, .regular))
                    .foregroundStyle(DWColor.textMuted)
                    .designFrame(20, 644, 288, 17, alignment: .leading)
                    .allowsHitTesting(false)
            }

            if let audio = episode.audio {
                Text(audio)
                    .font(DWFont.cn(12, .medium))
                    .foregroundStyle(DWColor.textMuted)
                    .designFrame(20, 676, 290, 17, alignment: .leading)
                    .allowsHitTesting(false)
            }

            if isEpisodeAvailable {
                // 播放进度
                RoundedRectangle(cornerRadius: DWRadius.progress)
                    .fill(.white.opacity(0.30))
                    .designFrame(20, 700, 290, 3)
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: DWRadius.progress)
                    .fill(DWColor.primary)
                    .designFrame(20, 700, 290 * progressValue, 3)
                    .allowsHitTesting(false)

                Text(timeText)
                    .font(DWFont.en(11, .medium))
                    .foregroundStyle(DWColor.textTime)
                    .designFrame(20, 708, 60, 13, alignment: .leading)
                    .allowsHitTesting(false)

                Text(durationText)
                    .font(DWFont.en(11, .medium))
                    .foregroundStyle(DWColor.textTime)
                    .designFrame(254, 708, 56, 13, alignment: .trailing)
                    .allowsHitTesting(false)
            }

            // 进度控制改由 PlayerPagingScrollView 的 UIKit seekPan 处理（与系统 pan 同时识别）。
            // 卡片内不放任何连续手势 —— 之前这个局部 DragGesture 吃掉了全部纵向滑动。

            // 右侧互动栏
            LinearGradient(colors: [DWColor.avatarTop, DWColor.avatarBottom],
                           startPoint: .top, endPoint: .bottom)
                .clipShape(Circle())
                .designFrame(326, 458, 48, 48)
                .allowsHitTesting(false)

            Button { playback.liked.toggle() } label: {
                Image("ic_like")
                    .renderingMode(.template)
                    .resizable().scaledToFit()
                    .foregroundStyle(playback.liked ? DWColor.primary : .white)
                    .frame(width: 30, height: 30)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(325, 538, 44, 44)

            Text("点赞")
                .font(DWFont.cn(11, .medium))
                .foregroundStyle(playback.liked ? DWColor.primary : .white)
                .multilineTextAlignment(.center)
                .designFrame(336, 579, 42, 14)
                .allowsHitTesting(false)

            Button { playback.saved.toggle() } label: {
                Image("ic_save")
                    .renderingMode(.template)
                    .resizable().scaledToFit()
                    .foregroundStyle(playback.saved ? DWColor.gold : .white)
                    .frame(width: 30, height: 30)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(325, 625, 44, 44)

            Text("收藏")
                .font(DWFont.cn(11, .medium))
                .foregroundStyle(playback.saved ? DWColor.gold : .white)
                .multilineTextAlignment(.center)
                .designFrame(336, 666, 42, 14)
                .allowsHitTesting(false)

            // 上滑切集提示
            Image("ic_swipe_up")
                .resizable().scaledToFit()
                .designFrame(145, 800, 18, 18)
                .allowsHitTesting(false)

            Text(hasNextEpisode
                 ? (nextEpisodeAvailable ? "上滑观看下一集" : "下一集尚未下载")
                 : "已是最后一集")
                .font(DWFont.cn(11, .medium))
                .foregroundStyle(DWColor.textSwipe)
                .designFrame(169, 801, 120, 16, alignment: .leading)
                .allowsHitTesting(false)

            // 长按倍速状态提示
            HStack(spacing: 6) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 13, weight: .bold))
                Text("2× 倍速播放")
                    .font(DWFont.cn(13, .semibold))
            }
            .foregroundStyle(DWColor.gold)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
            .opacity(playback.isFastForwarding ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: playback.isFastForwarding)
            .designFrame(95, 300, 200, 34)
            .allowsHitTesting(false)

            // 加载 / 错误态覆盖（仅当前页需要）
            if isActive, let error = playback.loadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(DWColor.gold)
                    Text(error)
                        .font(DWFont.cn(12))
                        .foregroundStyle(DWColor.textBody)
                        .multilineTextAlignment(.center)
                }
                .designFrame(60, 370, 270, 90)
                .allowsHitTesting(false)
            } else if isActive, !playback.isReady {
                if isEpisodeAvailable {
                    ProgressView()
                        .tint(.white)
                        .designFrame(180, 405, 30, 30)
                        .allowsHitTesting(false)
                } else {
                    // 真实存在但未下载的集：不转圈、不假装能播
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle")
                            .font(.title2)
                            .foregroundStyle(DWColor.textHint)
                        Text("该集尚未下载")
                            .font(DWFont.cn(13, .medium))
                            .foregroundStyle(DWColor.textBody)
                        Text("上下滑动浏览其他集")
                            .font(DWFont.cn(11))
                            .foregroundStyle(DWColor.textHint)
                    }
                    .designFrame(60, 355, 270, 100)
                    .allowsHitTesting(false)
                }
            }

            // 返回按钮：放在最后 + 最高层级，确保关闭入口不被任何覆盖层挡住
            Button { onClose() } label: {
                Image("ic_back")
                    .renderingMode(.template)
                    .resizable().scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(8, 44, 44, 44)
            .zIndex(10)

            // 边界 toast：全局组件，本页只决定它落在设计稿的哪个位置
            ToastView(message: toastText)
                .designFrame(95, 350, 200, 36)
                .zIndex(20)
        }
    }
}

// Xcode 15+ / iOS 17+；旧版请改用 PreviewProvider。
#Preview("中文版 · 紫色（静态稿面）") {
    DramaPlayerView(
        episode: .designPreview,
        playback: DramaPlayerViewModel(playerService: PlaybackPlayerService()),
        player: nil,
        isActive: false
    )
}
