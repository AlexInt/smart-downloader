import SwiftUI
import AVFoundation

/// DramaWave · 竖屏上下滑动播放页（中文版 / 紫色）
///
/// 由设计稿「播放页 · 中文版」逐节点映射，坐标基准 390×840，等比缩放适配任意机型。
/// 接入态说明：
/// - 视频层换成真实 AVPlayerLayer（本地 HLS 经 LocalMediaServer 回环播放）；设计稿渐变保留为
///   视频加载中 / 无画面时的底，不破坏稿面质感。
/// - 假状态栏移除，交由系统状态栏；顶部按钮中心点仍对齐设计稿坐标，仅把点击热区扩到 44×44。
/// - 字幕条在无字幕轨时隐藏；其余稿面字段由 DramaEpisode 提供，nil 不渲染。
/// - 播放/暂停、静音、点赞、收藏、进度 seek 由 DramaPlayerViewModel 驱动；上下滑切集由容器层处理。
/// - 所有纯展示元素加 allowsHitTesting(false)，让下层的单击播放/暂停热区正常工作。
struct DramaPlayerView: View {
    let episode: DramaEpisode
    @ObservedObject var vm: DramaPlayerViewModel
    var onClose: () -> Void = {}
    var hasNextEpisode = false

    private var timeText: String {
        vm.isReady ? vm.currentTimeText : (episode.previewCurrentTime ?? "00:00")
    }
    private var durationText: String {
        vm.isReady ? vm.durationText : (episode.previewDuration ?? "00:00")
    }
    private var progressValue: CGFloat {
        CGFloat(vm.isReady ? vm.progress : episode.previewProgress)
    }

    var body: some View {
        GeometryReader { geo in
            // 设计画幅等比缩放，保证任意机型上元素相对关系不被破坏。
            let scale = min(geo.size.width / DWLayout.designWidth,
                            geo.size.height / DWLayout.designHeight)

            ZStack(alignment: .topLeading) {
                // ── 底：设计稿渐变（VideoBg 三色标 + 中央打光） ───
                LinearGradient(stops: [
                    .init(color: DWColor.videoTop, location: 0),
                    .init(color: DWColor.videoMid, location: 0.5),
                    .init(color: DWColor.videoBottom, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .designFrame(0, 0, 390, 840)
                .allowsHitTesting(false)

                RadialGradient(stops: [
                    .init(color: DWColor.glowCenter.opacity(0.22), location: 0),
                    .init(color: DWColor.glowEdge.opacity(0), location: 1)
                ], center: .center, startRadius: 0, endRadius: 175)
                .designFrame(45, 170, 300, 350)
                .allowsHitTesting(false)

                // ── 真实视频层 ──────────────────────────────
                PlayerSurfaceView(player: vm.player)
                    .opacity(vm.isReady ? 1 : 0)
                    .designFrame(0, 0, 390, 840)
                    .allowsHitTesting(false)

                // 单击播放/暂停；按住画面约 0.25s 进入 2× 倍速，松手恢复 1×。
                // 手指移出 40pt（改为上下滑切集）时 pressing 也会给 false，倍速自动解除。
                Color.clear
                    .designFrame(0, 0, 390, 840)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 40,
                                        pressing: { pressing in
                                            if !pressing { vm.endFastForward() }
                                        }) {
                                            vm.beginFastForward()
                                        }
                    .onTapGesture { vm.togglePlayback() }

                // ── 上下压暗，保证白字对比 ───────────────────
                LinearGradient(colors: [.black.opacity(0.8), .clear],
                               startPoint: .top, endPoint: .bottom)
                .designFrame(0, 0, 390, 200)
                .allowsHitTesting(false)

                LinearGradient(colors: [.clear, .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                .designFrame(0, 540, 390, 300)
                .allowsHitTesting(false)

                // ── 顶部栏 ──────────────────────────────────
                Button { onClose() } label: {
                    Image("ic_back")
                        .renderingMode(.template)
                        .resizable().scaledToFit()
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .frame(width: 44, height: 44)   // 热区 44×44，视觉仍居中于 (18,54,24,24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .designFrame(8, 44, 44, 44)

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

                Button { vm.isMuted.toggle() } label: {
                    Image("ic_sound")
                        .renderingMode(.template)
                        .resizable().scaledToFit()
                        .foregroundStyle(vm.isMuted ? DWColor.textHint : .white)
                        .frame(width: 26, height: 26)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .designFrame(329, 41, 44, 44)

                // ── 剧集字幕（本地 HLS 无字幕轨时整块隐藏） ──
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

                // ── 左下信息区 ──────────────────────────────
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
                        .lineSpacing(5)          // 设计稿 lineHeight 17px / 字号 12px
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

                // ── 播放进度 ────────────────────────────────
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

                // seek 热区：视觉坐标不变，向下扩展便于触摸
                Color.clear
                    .designFrame(20, 690, 290, 24)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        vm.seek(fraction: Double(min(max(0, value.location.x / 290), 1)))
                    })

                // ── 右侧互动栏 ──────────────────────────────
                LinearGradient(colors: [DWColor.avatarTop, DWColor.avatarBottom],
                               startPoint: .top, endPoint: .bottom)
                    .clipShape(Circle())
                    .designFrame(326, 458, 48, 48)
                    .allowsHitTesting(false)

                Button { vm.liked.toggle() } label: {
                    Image("ic_like")
                        .renderingMode(.template)
                        .resizable().scaledToFit()
                        .foregroundStyle(vm.liked ? DWColor.primary : .white)
                        .frame(width: 30, height: 30)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .designFrame(325, 538, 44, 44)

                Text("点赞")
                    .font(DWFont.cn(11, .medium))
                    .foregroundStyle(vm.liked ? DWColor.primary : .white)
                    .multilineTextAlignment(.center)
                    .designFrame(336, 579, 42, 14)
                    .allowsHitTesting(false)

                Button { vm.saved.toggle() } label: {
                    Image("ic_save")
                        .renderingMode(.template)
                        .resizable().scaledToFit()
                        .foregroundStyle(vm.saved ? DWColor.gold : .white)
                        .frame(width: 30, height: 30)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .designFrame(325, 625, 44, 44)

                Text("收藏")
                    .font(DWFont.cn(11, .medium))
                    .foregroundStyle(vm.saved ? DWColor.gold : .white)
                    .multilineTextAlignment(.center)
                    .designFrame(336, 666, 42, 14)
                    .allowsHitTesting(false)

                // ── 上滑切集提示 ────────────────────────────
                Image("ic_swipe_up")
                    .resizable().scaledToFit()
                    .designFrame(145, 800, 18, 18)
                    .allowsHitTesting(false)

                Text(hasNextEpisode ? "上滑观看下一集" : "已是最后一集")
                    .font(DWFont.cn(11, .medium))
                    .foregroundStyle(DWColor.textSwipe)
                    .designFrame(169, 801, 120, 16, alignment: .leading)
                    .allowsHitTesting(false)

                // ── 长按倍速状态提示（不占设计稿节点） ───────
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
                .opacity(vm.isFastForwarding ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: vm.isFastForwarding)
                .designFrame(95, 300, 200, 34)
                .allowsHitTesting(false)

                // ── 加载 / 错误态覆盖（不占设计稿坐标） ──────
                if let error = vm.loadError {
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
                } else if !vm.isReady {
                    ProgressView()
                        .tint(.white)
                        .designFrame(180, 405, 30, 30)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: DWLayout.designWidth, height: DWLayout.designHeight)
            .clipShape(RoundedRectangle(cornerRadius: DWRadius.screen))
            .scaleEffect(scale)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(DWColor.background.ignoresSafeArea())
    }
}

// Xcode 15+ / iOS 17+；旧版请改用 PreviewProvider。
#Preview("中文版 · 紫色（静态稿面）") {
    DramaPlayerView(episode: .designPreview, vm: DramaPlayerViewModel())
}
