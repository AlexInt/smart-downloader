import SwiftUI
import AVFoundation

/// DramaWave · 竖屏上下滑动播放页（中文版 / 紫色）
///
/// 由设计稿「播放页 · 中文版」逐节点映射，坐标基准 390×840。
/// 分层原则（解决黑边 / 控件被裁 / 手势互相吃掉）：
/// - 视频、加载渐变、压暗遮罩、手势层：铺满整屏（ignoresSafeArea），不参与设计稿缩放。
/// - 文字 / 按钮 / 图标：留在 390×840 画幅内等比 contain 缩放，控件不会被裁掉。
/// - 所有手势集中在同一个全屏层并用 simultaneousGesture 组合，按钮在其上层正常响应。
/// - 46pt 屏幕圆角是设计稿模拟手机外框用的，运行时不裁，否则四角出现黑角。
struct DramaPlayerView: View {
    let episode: DramaEpisode
    @ObservedObject var vm: DramaPlayerViewModel
    var onClose: () -> Void = {}
    var hasNextEpisode = false
    /// 当前集是否已下载；未下载时显示占位而不是加载圈
    var isEpisodeAvailable = true
    /// 下一集是否已下载：底部提示据此说明滑过去能看到什么
    var nextEpisodeAvailable = true
    /// 到边界时的短暂提示（由容器在 move 返回 false 时设置）
    var toastText: String? = nil
    /// 切集回调：手势在本视图内识别，由容器改变当前集
    var onNextEpisode: () -> Void = {}
    var onPreviousEpisode: () -> Void = {}

    @State private var dragY: CGFloat = 0
    /// 本次按压已触发过长按倍速：松手时不能当作「单击暂停」
    @State private var longPressFired = false

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
            // UI 层用 contain：宁可留一点相对空隙，也不把返回按钮 / 底部提示裁出屏幕
            let scale = min(geo.size.width / DWLayout.designWidth,
                            geo.size.height / DWLayout.designHeight)

            ZStack(alignment: .topLeading) {
                // ── ① 视频：铺满整屏，不随设计稿缩放（黑边根因） ─
                PlayerSurfaceView(player: vm.player)
                    .opacity(vm.isReady ? 1 : 0)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)

                // ── ② 加载态渐变：铺满整屏，视频就绪后淡出 ─────
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
                .opacity(vm.isReady ? 0 : 1)
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

                // ── ④ 全屏手势层：单击 / 长按 / 上下滑都在这一层 ─
                // 独占的 .gesture 会被子视图吃掉，所以这里统一用 simultaneousGesture。
                Color.clear
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 40,
                                        pressing: { pressing in
                                            if !pressing { vm.endFastForward() }
                                        }) {
                                            longPressFired = true
                                            vm.beginFastForward()
                                        }
                    // 单击 / 上下滑切集 / 带内水平调进度全部交给同一个拖拽手势按方向判定，
                    // 不再与其它独占手势竞争（避免上滑误暂停、上下滑误调进度）。
                    .simultaneousGesture(makePanGesture(screenSize: geo.size, scale: scale))

                // ── ⑤ 设计稿 UI 层（390×840，只含文字/按钮/图标） ─
                designOverlay
                    .frame(width: DWLayout.designWidth, height: DWLayout.designHeight)
                    .scaleEffect(scale)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .offset(y: dragY)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .background(DWColor.background.ignoresSafeArea())
    }

    /// 唯一的全屏手势，按方向分流，避免多个手势互相抢判定：
    /// - 起点落在进度条上下各 60pt 的带内、且水平主导 → 左右滑动调进度
    /// - 纵向主导且 >60pt → 上下滑切集（任何情况下都不碰进度）
    /// - 位移 <12pt → 单击暂停/播放（长按倍速松手除外）
    /// 进度条设计稿坐标 y=700、x=20..310，按 UI 层的 contain 缩放换算到屏幕坐标。
    private func makePanGesture(screenSize: CGSize, scale: CGFloat) -> some Gesture {
        let drawnWidth = DWLayout.designWidth * scale
        let drawnHeight = DWLayout.designHeight * scale
        let offsetX = (screenSize.width - drawnWidth) / 2
        let offsetY = (screenSize.height - drawnHeight) / 2
        let bandTop = offsetY + (700 - 60) * scale
        let bandBottom = offsetY + (700 + 60) * scale
        let barLeft = offsetX + 20 * scale
        let barWidth = 290 * scale

        return DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let inSeekBand = value.startLocation.y >= bandTop
                    && value.startLocation.y <= bandBottom

                // 只有「起点在进度带内 + 水平主导」才调进度
                if inSeekBand, abs(dx) > abs(dy), abs(dx) > 6 {
                    let ratio = (value.location.x - barLeft) / barWidth
                    vm.seek(fraction: Double(min(max(0, ratio), 1)))
                    return
                }
                if abs(dy) > abs(dx) { dragY = dy * 0.35 }
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragY = 0 }

                let inSeekBand = value.startLocation.y >= bandTop
                    && value.startLocation.y <= bandBottom
                // 本次是调进度：不再当成单击或切集
                if inSeekBand, abs(dx) > abs(dy), abs(dx) > 6 {
                    longPressFired = false
                    return
                }

                if abs(dx) < 12, abs(dy) < 12 {
                    let wasLongPress = longPressFired
                    longPressFired = false
                    if !wasLongPress { vm.togglePlayback() }
                    return
                }
                longPressFired = false
                guard abs(dy) > 60, abs(dy) > abs(dx) else { return }
                if dy < 0 { onNextEpisode() } else { onPreviousEpisode() }
            }
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

            // 进度控制已并入全屏 panGesture：只在进度条上下各 60 的带内响应水平滑动，
            // 避免这里的独占手势抢走上下滑切集、或按下即按绝对 x 误跳进度。

            // 右侧互动栏
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
            .opacity(vm.isFastForwarding ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: vm.isFastForwarding)
            .designFrame(95, 300, 200, 34)
            .allowsHitTesting(false)

            // 加载 / 错误态覆盖
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
                if isEpisodeAvailable {
                    ProgressView()
                        .tint(.white)
                        .designFrame(180, 405, 30, 30)
                        .allowsHitTesting(false)
                } else {
                    // 全剧集号里的未下载槽位：不转圈、不假装能播，明示状态且仍可上下滑
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
                    .frame(width: 44, height: 44)   // 热区 44×44，视觉仍居中于 (18,54,24,24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(8, 44, 44, 44)
            .zIndex(10)

            // 边界 toast：没有更多真实资源时短暂提示，不造任何槽位
            Text(toastText ?? "")
                .font(DWFont.cn(13, .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.black.opacity(0.72), in: Capsule())
                .opacity(toastText == nil ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: toastText)
                .designFrame(95, 350, 200, 36)
                .allowsHitTesting(false)
                .zIndex(20)
        }
    }
}

// Xcode 15+ / iOS 17+；旧版请改用 PreviewProvider。
#Preview("中文版 · 紫色（静态稿面）") {
    DramaPlayerView(episode: .designPreview, vm: DramaPlayerViewModel())
}
