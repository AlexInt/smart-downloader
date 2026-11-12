import SwiftUI
import AVFoundation

/// DramaWave · 分页播放列表里的单张卡片（中文版 / 紫色）
///
/// 由设计稿「播放页 · 中文版」逐节点映射，坐标基准 390×840。
/// - 视频 / 加载渐变 / 压暗遮罩 / 手势层：铺满整屏，不参与设计稿缩放。
/// - 文字 / 按钮 / 图标：留在 390×840 内等比 contain 缩放，控件不会被裁。
/// - 纵向翻页交给系统 ScrollView；本视图的离散手势（点按暂停 / 长按倍速）
///   放卡片自身，Button 天然优先；水平 seek 与左缘返回在 UIKit 层
///   （判定逻辑在 PlayerGesturePolicy）。
/// - 清屏模式（isCleanScreen，本地记住）：「界面信息组」整体淡出，
///   常驻控件（静音/清屏/返回）与瞬态反馈（倍速/加载/错误/toast）保留。
///   进度条+时间是唯一例外：清屏下 seek 仍生效，拖动时瞬态淡入（松手 800ms 淡出）。
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
    /// 长按松手后 250ms 内到达的单击 = 同一次抬手的误触，吞掉。
    /// 真机日志实证：短按 2x 快速松手会被同时认成长按结束和单击
    /// （LONGPRESS ended → TAP → togglePlayback → 误暂停）
    @State private var suppressTapUntil = Date.distantPast
    /// 本次触摸是否按满 0.15s 真正起过 2x（perform 里置位）：只有它才需要在
    /// 抬手时吞松手误触；未起 2x 的触摸（快速滑动/普通点按）抬手不动作
    @State private var longPressOwnedTouch = false
    /// 相邻卡片（isActive=false）一律回落到静态稿面值：播放进度是当前集的共享状态，
    /// 邻卡若直接读会显示成「别人集的时间/进度」（待办 #3 状态显示隔离）
    private var timeText: String {
        (isActive && playback.isReady) ? playback.currentTimeText : (episode.previewCurrentTime ?? "00:00")
    }
    private var durationText: String {
        guard isActive && playback.isReady else { return episode.previewDuration ?? "00:00" }
        return playback.showRemainingTime ? playback.remainingTimeText : playback.durationText
    }
    private var progressValue: CGFloat {
        CGFloat((isActive && playback.isReady) ? playback.progress : episode.previewProgress)
    }
    /// 进度 HUD 可见性：非清屏常驻；清屏下 seek 进行中（含松手 800ms 停留）或点按后 3s 内显示。
    /// isActive 参与判定：isScrubbing 是当前集的共享状态，邻卡不跟着闪 HUD
    private var isProgressVisible: Bool {
        isActive && (!playback.isCleanScreen || playback.isScrubbing)
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
                    .animation(.easeOut(duration: 0.15), value: playback.isReady)
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
                .animation(.easeOut(duration: 0.15), value: playback.isReady)
                .allowsHitTesting(false)

                // ── ③ 上下压暗：按屏幕比例铺满，边缘不留亮框；
                //    清屏时一并淡出，只留纯画面 ──
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
                .opacity(playback.isCleanScreen ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: playback.isCleanScreen)
                .allowsHitTesting(false)

                // ── ④ 手势（离散）：点按暂停 / 长按倍速放卡片自身（body 末尾的
                //    onTapGesture / onLongPressGesture）。SwiftUI 手势深度优先解析：
                //    Button（返回/静音/清屏/点赞/收藏）天然优先于卡片手势，点控件
                //    不连带暂停，无需控件区几何判定。连续手势（水平 seek / 左缘返回）
                //    仍在 UIKit 层与系统分页共存 —— 卡片内禁止的只是连续手势。 ─

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
        // 离散手势放卡片内：SwiftUI 深度优先解析，Button 天然优先于卡片手势，
        // 点静音/清屏/点赞/收藏/返回不会再连带触发暂停（无需任何控件区判定）。
        // 长按 2x 与水平 seek 的冲突仲裁 = 「先起者独占本次触摸」（真机日志实证）：
        //   ① 拖动先起 → seek 独占：seekPan 一旦起手（约 10pt 位移）VM 即置
        //      isSeekGestureActive（PlayerPagingScrollView .began → beginSeekGesture），
        //      perform 起手前查它——判定点勿放首个有效 .changed：清屏下进度带不可见，
        //      横滑起点常落在带外（识别器曾按带内过滤 begin，收不到事件），斜起手
        //      转水平的快滑同理，0.15s 的 perform 会插进空窗误起 2x（2026-11-11 又修）
        //   ② 长按先起 → 2x 独占：2x 期间 seek 全跳过（VM.seek guard isFastForwarding）；
        //      maximumDistance 放开到 10_000 —— 2x 不靠位移距离掐断（原 40pt：按住 2x
        //      手一漂就掉回 1x），漂移中的误 seek 由 ①② 闸门挡住
        //   ③ 短按 2x 快速松手 → 同一次抬手还会被认成单击，误暂停（250ms 抑制窗吞掉）
        //   ④ 2x 只能在 perform（按满 0.15s）里起，勿放 pressing(true)：pressing 在触摸
        //      落下瞬间即回调（先于任何位移判定），放那里每次快速滑动都误触 2x（2026-11-11 修）
        .contentShape(Rectangle())
        .onTapGesture {
            if Date() < suppressTapUntil {
                print("PLAYER_DBG [CHECK] TAP SKIP reason=justEndedLongPress")
                return
            }
            print("PLAYER_DBG [CHECK] TAP → togglePlayback")
            playback.togglePlayback()
        }
        .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 10_000, pressing: { pressing in
            // pressing 只做收尾；起 2x 在 perform（按满 0.15s 才回调）。
            // pressing(true) 在触摸落下瞬间即回调，曾把起 2x 放在这里，
            // 导致所有快速滑动（含纵向翻页）都被误判成长按 → 闪 2x。
            guard !pressing else { return }
            defer { longPressOwnedTouch = false }
            // 未起过 2x 的触摸（快速滑动/点按被取消）抬手不动作、不打日志
            guard longPressOwnedTouch else { return }
            print("PLAYER_DBG [CHECK] LONGPRESS ended → 1x")
            playback.endFastForward()
            suppressTapUntil = Date().addingTimeInterval(0.25)
        }, perform: {
            // 起手：按满 0.15s 才走到这里 —— 快速滑动（抬手早于 0.15s、或被
            // 纵向分页 pan 提前取消 touchesCancelled）根本进不来
            guard !playback.isSeekGestureActive else {
                print("PLAYER_DBG [CHECK] LONGPRESS SKIP reason=seeking")
                return
            }
            longPressOwnedTouch = true
            print("PLAYER_DBG [CHECK] LONGPRESS began → 2x")
            playback.beginFastForward()
        })
    }

    /// 设计稿节点，坐标一律来自设计文件，勿凭目测调整。
    /// 分两组：清屏模式下「界面信息组」整体淡出；常驻控件（静音/清屏/返回）与
    /// 瞬态反馈（倍速/加载/错误/toast）保留。返回按钮放在最后并抬到最高层级。
    @ViewBuilder
    private var designOverlay: some View {
        ZStack(alignment: .topLeading) {
            // ── 界面信息组：清屏模式下整体淡出，只留纯画面 ────────────
            if !playback.isCleanScreen {
                Group {
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

                    // 左下信息区（整体下移，贴近底部；进度条与「上滑」提示间距收紧）
                    Text(episode.account)
                        .font(DWFont.cn(14, .bold))
                        .foregroundStyle(.white)
                        .designFrame(20, 620, 290, 20, alignment: .leading)
                        .allowsHitTesting(false)

                    Text(episode.title)
                        .font(DWFont.cn(16, .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .designFrame(20, 642, 290, 23, alignment: .leading)
                        .allowsHitTesting(false)

                    if let caption = episode.caption {
                        Text(caption)
                            .font(DWFont.cn(12, .regular))
                            .foregroundStyle(DWColor.textBody)
                            .lineSpacing(5)
                            .lineLimit(1)
                            .designFrame(20, 666, 288, 17, alignment: .leading)
                            .allowsHitTesting(false)
                    }

                    if let tags = episode.tags {
                        Text(tags)
                            .font(DWFont.cn(12, .regular))
                            .foregroundStyle(DWColor.textMuted)
                            .designFrame(20, 688, 288, 17, alignment: .leading)
                            .allowsHitTesting(false)
                    }

                    if let audio = episode.audio {
                        Text(audio)
                            .font(DWFont.cn(12, .medium))
                            .foregroundStyle(DWColor.textMuted)
                            .designFrame(20, 720, 290, 17, alignment: .leading)
                            .allowsHitTesting(false)
                    }

                    // 进度条 + 时间已拆到独立的 progressHud（清屏下 seek 瞬态显示），
                    // 进度控制仍由 PlayerPagingScrollView 的 UIKit seekPan 处理。

                    // 右侧互动栏
                    LinearGradient(colors: [DWColor.avatarTop, DWColor.avatarBottom],
                                   startPoint: .top, endPoint: .bottom)
                        .clipShape(Circle())
                        .designFrame(326, 458, 48, 48)
                        .allowsHitTesting(false)

                    // 点赞/收藏按集记忆（PlayerPreferences.key）：邻卡读到的都是当前集的状态，
                    // 显示会错标 —— 邻卡强制未点亮态、动作不落账（待办 #3 状态显示隔离）
                    Button {
                        guard isActive else { return }
                        playback.liked.toggle()
                    } label: {
                        Image("ic_like")
                            .renderingMode(.template)
                            .resizable().scaledToFit()
                            .foregroundStyle(isActive && playback.liked ? DWColor.primary : .white)
                            .frame(width: 30, height: 30)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .designFrame(325, 538, 44, 44)

                    // 文字框与按钮框同宽同位：中心对齐 icon 垂直中轴（此前右偏 10pt）
                    Text("点赞")
                        .font(DWFont.cn(11, .medium))
                        .foregroundStyle(isActive && playback.liked ? DWColor.primary : .white)
                        .multilineTextAlignment(.center)
                        .designFrame(325, 579, 44, 14)
                        .allowsHitTesting(false)

                    Button {
                        guard isActive else { return }
                        playback.saved.toggle()
                    } label: {
                        Image("ic_save")
                            .renderingMode(.template)
                            .resizable().scaledToFit()
                            .foregroundStyle(isActive && playback.saved ? DWColor.gold : .white)
                            .frame(width: 30, height: 30)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .designFrame(325, 625, 44, 44)

                    Text("收藏")
                        .font(DWFont.cn(11, .medium))
                        .foregroundStyle(isActive && playback.saved ? DWColor.gold : .white)
                        .multilineTextAlignment(.center)
                        .designFrame(325, 666, 44, 14)
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
                }
                .transition(.opacity)
            }

            // ── 进度 HUD：非清屏常驻；清屏下 seek 瞬态显示（松手停留 800ms 淡出） ──
            // seek 是对（清屏时看不见的）进度带操作，必须有可见反馈；只出进度条+时间，
            // 不出整个界面信息组——与倍速提示同属瞬态反馈，不破坏清屏「只看画面」的克制。
            if isEpisodeAvailable {
                progressHud
            }

            // ── 常驻控件：清屏模式下保留 ──────────────────────────────

            // 集数胶囊：紧凑「4/11」常驻，清屏不隐藏（始终知道看到哪一集）。
            // 56 宽水平居中（(390-56)/2=167），顶栏四元素（返回/胶囊/清屏/静音）不拥挤
            RoundedRectangle(cornerRadius: DWRadius.chip)
                .fill(.black.opacity(0.45))
                .designFrame(167, 50, 56, 26)
                .allowsHitTesting(false)

            Text(episode.compactEpisodeLabel)
                .font(DWFont.en(12, .medium))
                .foregroundStyle(DWColor.textPrimary)
                .multilineTextAlignment(.center)
                .designFrame(167, 55, 56, 16)
                .allowsHitTesting(false)

            // 静音（状态本地记住）
            // 静音/清屏是全局偏好，但仅当前卡可操作：邻卡半遮挡状态下误触易困惑
            Button {
                guard isActive else { return }
                playback.isMuted.toggle()
            } label: {
                ZStack {
                    Image("ic_sound")
                        .renderingMode(.template)
                        .resizable().scaledToFit()
                        .foregroundStyle(playback.isMuted ? DWColor.textHint : .white)
                        .frame(width: 26, height: 26)
                    // 素材库无独立静音图标：静音时叠加金色斜线表达（icon 同时变灰）
                    if playback.isMuted {
                        Capsule()
                            .fill(DWColor.gold)
                            .frame(width: 36, height: 2.5)
                            .rotationEffect(.degrees(45))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(329, 41, 44, 44)

            // 清屏（状态本地记住）：隐藏界面信息只看画面。
            // 矩形+斜线与静音图标同一视觉语言：激活时描边变灰 + 金色斜线
            Button {
                guard isActive else { return }
                playback.isCleanScreen.toggle()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(playback.isCleanScreen ? DWColor.textHint : .white,
                                      lineWidth: 1.8)
                        .frame(width: 21, height: 16)
                    if playback.isCleanScreen {
                        Capsule()
                            .fill(DWColor.gold)
                            .frame(width: 27, height: 2.2)
                            .rotationEffect(.degrees(45))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(277, 41, 44, 44)

            // 长按倍速状态提示（瞬态反馈，清屏时保留）
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
            // isActive：isFastForwarding 是当前集的共享状态，邻卡不跟着显示 2x 胶囊
            .opacity(isActive && playback.isFastForwarding ? 1 : 0)
            .animation(.easeIn(duration: 0.1), value: playback.isFastForwarding)
            .designFrame(95, 300, 200, 34)
            .allowsHitTesting(false)

            // 加载 / 错误态覆盖（仅当前页需要；瞬态功能反馈，清屏时保留）
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
                    // 800ms 内就绪的加载不显示转圈：预热命中的秒开路径应当无感（阈值依真机实测定）
                    if playback.isLoadingSlow {
                        ProgressView()
                            .tint(.white)
                            .designFrame(180, 405, 30, 30)
                            .allowsHitTesting(false)
                    }
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
        .animation(.easeInOut(duration: 0.2), value: playback.isCleanScreen)
    }

    /// 进度条 + 时间：从「界面信息组」拆出的独立 HUD——清屏下其余界面信息全隐，
    /// 唯它瞬态出现：seek 拖动时进度跟随手指（抬手 800ms 淡出），点按暂停/播放也展示（3s 无操作淡出）。
    @ViewBuilder
    private var progressHud: some View {
        // 播放进度：宽度 350，左右边距对称（各 20）
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: DWRadius.progress)
                .fill(.white.opacity(0.30))
                .designFrame(20, 744, 350, 3)
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: DWRadius.progress)
                .fill(DWColor.primary)
                .designFrame(20, 744, 350 * progressValue, 3)
                .allowsHitTesting(false)

            Text(timeText)
                .font(DWFont.en(11, .medium))
                .foregroundStyle(DWColor.textTime)
                .designFrame(20, 752, 60, 13, alignment: .leading)
                .allowsHitTesting(false)

            // 右侧时长 label：点按切换 总时长 ↔ 剩余时间（负值），状态本地持久化。
            // Button 深度优先于卡片点按手势——点它只切时间显示，不连带暂停；
            //  hit 区括到 24pt 高便于点按，仅 HUD 可见时可点（避免清屏隐藏态误触）
            Button {
                playback.toggleTimeDisplay()
            } label: {
                Text(durationText)
                    .font(DWFont.en(11, .medium))
                    .foregroundStyle(DWColor.textTime)
                    .frame(width: 56, height: 24, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(314, 746, 56, 24, alignment: .trailing)
            .allowsHitTesting(isProgressVisible)
        }
        .opacity(isProgressVisible ? 1 : 0)
        // 从底部上升 + 由浅变深：隐藏态下偏 12pt，显示时归零，与透明度共用同一动画
        .offset(y: isProgressVisible ? 0 : 12)
        .animation(.easeInOut(duration: 0.2), value: isProgressVisible)
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
