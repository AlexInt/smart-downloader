import SwiftUI

/// DramaWave · 分页播放列表里的单张卡片（中文版 / 墨本）
///
/// 由设计稿「播放页」逐节点映射，坐标基准 390×840（画布 2:11 完整态 / 2:74 清屏态）。
/// - 视频 / 加载渐变 / 压暗遮罩 / 手势层：铺满整屏，不参与设计稿缩放。
/// - 文字 / 按钮 / 图标：留在 390×840 内等比 contain 缩放，控件不会被裁。
/// - 纵向翻页交给系统 ScrollView；本视图的离散手势（点按暂停 / 长按倍速）
///   放卡片自身，Button 天然优先；水平 seek 与左缘返回在 UIKit 层
///   （判定逻辑在 PlayerGesturePolicy）。
/// - 清屏模式（isCleanScreen，本地记住）：「界面信息组」整体淡出，
///   常驻控件保留。清屏入口在右下角（2026-11-15 用户拍板：砍掉「画面适配」，
///   清屏占它的画布位 350 并沿用它的图标；静音紧随其左，在 318）。
///
/// 2026-11-15 按画布 2:11 重做（此前形制漂移，逐项归位）：
/// - 标题：47×22 文字 @(44,71)，15px Noto Serif SC Medium —— 2026-11-15 起内容与
///   全屏一致「剧集名 + 第n集」
/// - 返回：带黑底 44 命中区 → 无底 22×22 @(16,70)，命中区仍是 44（不影响观感）
/// - 新增：倍速 54×26 @(272,68)、更多 20×20 @(344,72)、播放大按钮 56×56 @(167,392)、
///   右下角 24×24 两枚（静音 318 / 清屏 350，清屏沿用原画面适配的图标）、
///   选集胶囊 @(16,770) 宽度按 `episodePillWidth` 推导（现 290）
/// - 进度条：350 宽 3pt @(20,744) → 满宽 390×2 @(0,751) + 朱砂 8×8 圆点
/// - 右侧互动列：44 图标 + 中文标签 → 26 图标 + 数值文字（23.7万 / 1万）
/// - 左下信息：account/剧名/简介三段 → 起始提示 11px / 剧名 19px 衬线 / 热评 11px
struct DramaPlayerView: View {
    let episode: DramaEpisode
    @ObservedObject var playback: DramaPlayerViewModel
    let isActive: Bool
    var onClose: () -> Void = {}
    var hasNextEpisode = false
    var isEpisodeAvailable = true
    var nextEpisodeAvailable = true
    var toastText: String? = nil
    /// 打开倍速面板（竖屏是半屏底部弹层，由 `PlayerFeedView` 承载）
    var onRequestRatePanel: () -> Void = {}
    /// 打开选集面板（画布 19:62 是完整的上墨下纸面板，本轮先给简单版）
    var onRequestEpisodePanel: () -> Void = {}
    /// 长按松手后 250ms 内到达的单击 = 同一次抬手的误触，吞掉。
    /// 真机日志实证：短按 2x 快速松手会被同时认成长按结束和单击
    /// （LONGPRESS ended → TAP → togglePlayback → 误暂停）
    @State private var suppressTapUntil = Date.distantPast

    // MARK: - 布局常量（右下角两枚按钮与选集胶囊的宽度联动）

    /// 静音钮画布位（2026-11-15：从 286 右移到 318，向清屏靠近、间距 32）
    static let muteSlotX: CGFloat = 318
    /// 清屏钮画布位（沿用原「画面适配」的 350，右缘 374 不变）
    static let cleanSlotX: CGFloat = 350
    /// 选集胶囊宽度：一路延伸到静音钮左缘前 12（16…306 → 290）。
    /// 用户要求「选集自动变长」——不再写死数字，按钮位一改这里自动跟着变
    static var episodePillWidth: CGFloat { muteSlotX - 12 - 16 }

    /// 顶部标题：与全屏顶栏同一条文案（剧集名 + 第n集，两个空格分隔）
    private var topTitle: String {
        let name = playback.seriesName.isEmpty ? "" : "\(playback.seriesName)  "
        return "\(name)第\(episode.episodeIndex)集"
    }

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
    /// 播放/暂停图标：邻卡一律显示播放三角（不读共享的播放态）
    private var showPauseGlyph: Bool {
        isActive && playback.isPlaying
    }
    /// 进度 HUD 可见性：非清屏常驻；清屏下 seek 进行中（含松手 800ms 停留）或点按后 3s 内显示。
    /// isActive 参与判定：isScrubbing 是当前集的共享状态，邻卡不跟着闪 HUD
    private var isProgressVisible: Bool {
        isActive && (!playback.isCleanScreen || playback.isScrubbing)
    }
    /// 瓣色：点亮点亮态用朱砂（点赞）/ 金色（收藏），与旧版一致
    private var likedTint: Color {
        isActive && playback.liked ? DWColor.overlayCinnabar : DWColor.overlayInk
    }
    private var savedTint: Color {
        isActive && playback.saved ? DWColor.gold : DWColor.overlayInk
    }

    var body: some View {
        GeometryReader { geo in
            // UI 层用 contain：宁可留一点相对空隙，也不把返回按钮 / 底部提示裁出屏幕
            let scale = min(geo.size.width / DWLayout.designWidth,
                            geo.size.height / DWLayout.designHeight)
            // App 已锁竖屏：全屏由播放器容器 transform 自转（PlayerFullscreenController），
            // 卡片不再有横屏分支——勿再加「卡片随系统旋转」类实现（曾致布局振荡/跳变）

            ZStack(alignment: .topLeading) {
                // ── ① 视频：由分页滚动层的单例容器承载（PlayerPagingScrollView.Coordinator），
                //    本卡在视频区透明——容器在卡片之下，加载渐变（②）淡出后露出视频 ──
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

                // ── ③ 上下压暗（画布 2:75 h210 a0.78→0 / 2:76 y470 h286 a0→0.86；
                //    清屏态 2:77 h170 a0.58→0 / 2:78 y660 h96 a0→0.62）。
                //    按屏幕比例铺满，边缘不留亮框；清屏时压暗变浅变窄，只留纯画面感 ──
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(playback.isCleanScreen ? 0.58 : 0.78), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.size.height * (playback.isCleanScreen ? 170.0 / 844 : 210.0 / 844))
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(playback.isCleanScreen ? 0.62 : 0.86)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.size.height * (playback.isCleanScreen ? 96.0 / 844 : 286.0 / 844))
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .allowsHitTesting(false)

                // ── ④ 手势（离散）：点按暂停 / 长按倍速放卡片自身（body 末尾的
                //    onTapGesture / onLongPressGesture）。SwiftUI 手势深度优先解析：
                //    Button（返回/静音/清屏/点赞/收藏）天然优先于卡片手势，点控件
                //    不连带暂停，无需控件区几何判定。连续手势（水平 seek / 左缘返回）
                //    仍在 UIKit 层与系统分页共存 —— 卡片内禁止的只是连续手势。 ─

                // ── ⑤ 控件层：设计稿画布（390×840 contain）。全屏态由全屏容器自带的
                //    PlayerFullscreenControlsView 覆盖（挂 keyWindow，随容器自转） ──
                designOverlay
                    .frame(width: DWLayout.designWidth, height: DWLayout.designHeight)
                    .scaleEffect(scale)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        // 背景透明：视频由滚动层下的单例容器渲染（z 序在卡片之下），卡片只画渐变/压暗/控件
        // 离散手势放卡片内：SwiftUI 深度优先解析，Button 天然优先于卡片手势，
        // 点控件不会再连带触发暂停（无需任何控件区判定）。
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
            // seek 独占的触摸（横滑）抬手：吞掉紧随的单击，否则每次横滑结束大概率误暂停
            //（调查结论：seekPan cancelsTouchesInView=false，纯横滑时触摸不被取消，tap 全程存活）
            if Date() < playback.tapSuppressionDeadline {
                print("PLAYER_DBG [CHECK] TAP SKIP reason=justEndedSeek")
                return
            }
            if playback.isSeekGestureActive {
                print("PLAYER_DBG [CHECK] TAP SKIP reason=seekGestureActive")
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
            print("PLAYER_DBG [CHECK] LONGPRESS ended → \(playback.playbackRate)×")
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

    /// 设计稿节点，坐标一律来自设计文件（画布 2:11 完整态 / 2:74 清屏态），勿凭目测调整。
    /// 分两组：清屏模式下「界面信息组」整体淡出；常驻控件（返回/集数/倍速/更多 +
    /// 右下角清屏/静音）与瞬态反馈（倍速/加载/错误/toast）保留。
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

                    // 右侧互动衬底（画布 2:207 90×190 @(300,520)，横向渐变 a0→0.52）
                    LinearGradient(
                        stops: [
                            .init(color: Color(hex: "#0F1212").opacity(0), location: 0),
                            .init(color: Color(hex: "#0F1212").opacity(0.52), location: 1)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .designFrame(300, 520, 90, 190)
                    .allowsHitTesting(false)

                    // 右侧互动列（画布 2:106 44×150 @(328,545)，竖向 VERTICAL gap 32）
                    // 收藏在上、点赞在下；图标 26 + 5 间距 + 数值 10px
                    rightActionColumn
                        .designFrame(328, 545, 44, 150)

                    // 左下信息（画布 2:123 290×110 @(20,618)，竖向 VERTICAL gap 9）
                    bottomInfoBlock
                        .designFrame(20, 618, 290, 110, alignment: .topLeading)
                }
                .transition(.opacity)
            }

            // ── 进度 HUD：非清屏常驻；清屏下 seek 瞬态显示（松手停留 800ms 淡出） ──
            if isEpisodeAvailable {
                progressHud
            }

            // ── 常驻控件：清屏模式下保留 ──────────────────────────────

            // 返回（画布 2:91 22×22 @(16,70)，无底色，箭头 6.5×13）
            backButton
                .designFrame(16, 70, 22, 22)
                .frame(width: 22, height: 22)
                .zIndex(10)

            // 标题（2026-11-15 用户要求与全屏一致）：剧集名 + 第n集。
            // 格式与 `PlayerFullscreenControlsView.updateTitle` 逐字相同（两个空格分隔、第n集不空格），
            // 两处不要各写一套文案。宽度到 264（倍速钮左缘前 8），长剧名截断
            Text(topTitle)
                .font(DWFont.serif(15, .medium))
                .foregroundStyle(DWColor.overlayInk)
                .lineLimit(1)
                .designFrame(44, 71, 220, 22, alignment: .leading)
                .allowsHitTesting(false)

            // 倍速（画布 2:94 54×26 @(272,68)：16 表盘 + 5 间距 + 12px「倍速」）
            // 2026-11-15 用户要求「更多左边增加倍速」：清屏态下 返回/标题/更多 都还在，
            // 唯独这里被藏起来 → 清屏态就没有倍速入口了，故取消清屏态隐藏，常驻
            rateButton
                .designFrame(272, 68, 54, 26)

            // 更多（画布 2:99 20×20 @(344,72)，三点 2.8 圆点，竖向 gap 6）
            moreButton
                .designFrame(344, 72, 20, 20)

            // 播放/暂停大按钮（画布 19:57 56×56 @(167,392)）
            // 只在暂停时出现：播放中盖一个大三角会挡住画面（设计稿是静帧，故画了实心三角）
            if isEpisodeAvailable, isActive, !showPauseGlyph, playback.isReady {
                playButton
                    .designFrame(167, 392, 56, 56)
            }

            // ── 右下角：静音 / 清屏（2026-11-15 用户拍板：去掉「画面适配」，清屏占它原来的
            //    画布位、并沿用它的图标；静音向右靠近清屏，间距与原来三枚时的节奏一致）──
            // 清屏（画布 19:37 位 350，图标 = 原「画面适配」那个描边方 + 两枚角标）
            cleanScreenButton
                .designFrame(Self.cleanSlotX, 776, 24, 24)

            // 静音（放清屏左侧，间距 32）
            muteButton
                .designFrame(Self.muteSlotX, 776, 24, 24)

            // 选集胶囊（画布 2:130 326×38 r8 @(16,770)）
            // 清屏态画布 2:74 保留它（2:161）——清屏仍要知道「在看全多少集」
            //
            // 宽度不再写死（2026-11-15 用户要求「选集自动变长」）：右下角砍掉一枚按钮、
            // 静音右移到 318 后，胶囊一路延伸到静音钮左缘前 12 → 290（原 258）。
            // 按钮位改了这里会自动跟着变，别再填魔法数字。
            episodePill
                .designFrame(16, 770, Self.episodePillWidth, 38)

            // 长按倍速状态提示（瞬态反馈，清屏时保留）
            fastForwardCapsule
                .designFrame(95, 300, 200, 34)

            // 加载 / 错误态覆盖（仅当前页需要；瞬态功能反馈，清屏时保留）
            if isActive, let error = playback.loadError {
                loadErrorHint(error)
                    .designFrame(60, 370, 270, 90)
            } else if isActive, !playback.isReady {
                if isEpisodeAvailable {
                    // 800ms 内就绪的加载不显示转圈：预热命中的秒开路径应当无感（阈值依真机实测定）
                    if playback.isLoadingSlow {
                        loadingSpinner
                            .designFrame(180, 405, 30, 30)
                    }
                } else {
                    // 真实存在但未下载的集：不转圈、不假装能播
                    notDownloadedHint
                        .designFrame(60, 355, 270, 100)
                }
            }

            // 边界 toast：全局组件，本页只决定它落在设计稿的哪个位置
            ToastView(message: toastText)
                .designFrame(95, 350, 200, 36)
                .zIndex(20)
        }
    }

    /// 右侧互动列（画布 2:106）：收藏（星形）在上、点赞（心形）在下。
    /// 每组只有 26×26 描边图标（数值已按用户要求移除，只记本地状态不报数），整列 44 宽、两组间 32。
    private var rightActionColumn: some View {
        VStack(spacing: 32) {
            // 收藏
            Button {
                guard isActive else { return }
                playback.saved.toggle()
            } label: {
                OverlayStarGlyph(size: 26, color: savedTint)
                    .frame(width: 44, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.saved ? "取消收藏" : "收藏")

            // 点赞
            Button {
                guard isActive else { return }
                playback.liked.toggle()
            } label: {
                OverlayHeartGlyph(size: 26, color: likedTint)
                    .frame(width: 44, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.liked ? "取消点赞" : "点赞")
        }
        .frame(width: 44, height: 150, alignment: .top)
    }

    /// 左下信息（画布 2:123）：起始提示 11px → 剧名 19px 衬线 → 热评 11px，gap 9。
    private var bottomInfoBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            // 起始提示（2:124「从第 1 集开始看」11px 纸白）
            Text("从第 1 集开始看")
                .font(DWFont.cn(11, .regular))
                .foregroundStyle(DWColor.overlayInk)

            // 剧名（2:125 19px Noto Serif SC Medium 纸白，单行）
            Text(episode.title)
                .font(DWFont.serif(19, .medium))
                .foregroundStyle(DWColor.overlayInk)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 热评（2:126 11px 次级色）：本地数据没有热评时退回简介，再没有就整行不占位
            if let caption = episode.caption ?? episode.tags {
                Text("热评  \(caption)")
                    .font(DWFont.cn(11, .regular))
                    .foregroundStyle(DWColor.overlayInkSub)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 290, alignment: .leading)
    }

    /// 进度条 + 时间（画布 2:127 / 2:129）：满宽 390×2 @(0,751) 轨道 + 已播段 +
    /// 朱砂 8×8 当前点（点垂直居中在轨道上：y 751-3=748，8 高 → 748+4=752 中点对齐 752）。
    /// 清屏下瞬态出现：seek 拖动时进度跟随手指（抬手 800ms 淡出），点按暂停/播放也展示（3s 无操作淡出）。
    @ViewBuilder
    private var progressHud: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(DWColor.overlayTrack.opacity(0.30))
                .designFrame(0, 751, 390, 2)
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 1)
                .fill(DWColor.overlayTrack)
                .designFrame(0, 751, 390 * progressValue, 2)
                .allowsHitTesting(false)

            // 朱砂当前点 8×8 r4：跟着已播段末端走（画布是 116 处，即 118/390 的进度位置）
            Circle()
                .fill(DWColor.overlayCinnabar)
                .frame(width: 8, height: 8)
                .position(x: 390 * progressValue, y: 752)
                .allowsHitTesting(false)

            // 时间行（2026-11-15 用户要求「播放时长与剧集长度移到进度条上部」）：
            // 画布 2:11 只有轨道与圆点，没有时间文字，这里按用户要求补在轨道上方——
            // 当前时间靠左缘 20、总时长靠右缘 370，与轨道两端对齐（原来贴在轨道下方，
            // 会被选集胶囊挤在 756…768 的窄缝里）
            Text(timeText)
                .font(DWFont.en(11, .medium))
                .foregroundStyle(DWColor.overlayInkSub)
                .designFrame(20, 731, 60, 14, alignment: .leading)
                .allowsHitTesting(false)

            Text(durationText)
                .font(DWFont.en(11, .medium))
                .foregroundStyle(DWColor.overlayInkSub)
                .designFrame(310, 731, 60, 14, alignment: .trailing)
                .allowsHitTesting(false)
        }
        .opacity(isProgressVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isProgressVisible)
    }

    // MARK: - 控件

    /// 返回（画布 2:91：22×22 无底色，箭头 6.5×13 描边 1.8 纸白）
    /// 命中区仍是 44×44（贴在 22 的视觉框上向外扩），不动观感但好点
    private var backButton: some View {
        Button { onClose() } label: {
            Image("ic_back")
                .renderingMode(.template)
                .resizable().scaledToFit()
                .foregroundStyle(DWColor.overlayInk)
                .frame(width: 13, height: 13)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回")
    }

    /// 倍速（画布 2:94：54×26，HORIZONTAL gap 5，表盘 16 + 「倍速」12px 纸白）
    /// 点按打开倍速面板（横竖屏共用一套档位）
    private var rateButton: some View {
        Button {
            guard isActive else { return }
            print("PLAYER_DBG [CHECK] rate button tap → open rate panel")
            onRequestRatePanel()
        } label: {
            HStack(spacing: 5) {
                OverlayRateGlyph(size: 16, color: DWColor.overlayInk)
                Text(playback.playbackRate == 1.0 ? "倍速" : playback.rateShortText)
                    .font(DWFont.cn(12, .regular))
                    .foregroundStyle(DWColor.overlayInk)
                    .lineLimit(1)
            }
            .frame(width: 54, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("倍速，当前 \(playback.playbackRateText) 倍速")
    }

    /// 更多（画布 2:99：20×20 三点）。收容清屏以外的次要入口。
    /// 目前承载「清屏模式的另一处入口」不需要——清屏已在右下角常驻；
    /// 这里只做「重看本集」「上滑下一集提示」这类补充操作，避免成为死按钮。
    private var moreButton: some View {
        Menu {
            Button {
                guard isActive else { return }
                playback.seek(fraction: 0)
                print("PLAYER_DBG [CHECK] more menu → replay from start")
            } label: {
                Label("从头播放", systemImage: "arrow.counterclockwise")
            }
            Button {
                guard isActive else { return }
                playback.isCleanScreen = true
            } label: {
                Label("清屏模式", systemImage: "rectangle.dashed")
            }
            Button {
                guard isActive else { return }
                playback.isMuted.toggle()
            } label: {
                Label(playback.isMuted ? "取消静音" : "静音", systemImage: playback.isMuted ? "speaker.slash" : "speaker")
            }
        } label: {
            OverlayMoreGlyph(size: CGSize(width: 20, height: 20), color: DWColor.overlayInk)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多")
    }

    /// 播放/暂停大按钮（画布 19:57：56×56 实心白三角 27.7×26.4 @(13,14.8)）
    private var playButton: some View {
        Button {
            guard isActive else { return }
            playback.togglePlayback()
        } label: {
            ZStack {
                OverlayPlayGlyph(size: 27.7, color: .white)
                    .offset(x: 13 - (56 - 27.7) / 2)
            }
            .frame(width: 56, height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.isPlaying ? "暂停" : "播放")
    }

    /// 清屏（用户要求放右下角）：图标沿用原「画面适配」那枚（`OverlayFitGlyph`，描边方 +
    /// 两枚角标）——2026-11-15 用户拍板「画面适配的 icon 就是新的清屏 icon」。
    /// 清屏中图标转金（与点赞/收藏同一「点亮即金」语义），不再画 45° 斜线。
    /// `videoFitMode` 偏好与 `cycleVideoGravity()` 仍留在 VM（gravity 仍按片源方向自动定），
    /// 只是不再有手动入口
    private var cleanScreenButton: some View {
        Button {
            guard isActive else { return }
            playback.isCleanScreen.toggle()
        } label: {
            OverlayFitGlyph(size: 24, color: playback.isCleanScreen ? DWColor.gold : .white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.isCleanScreen ? "退出清屏" : "清屏")
    }

    /// 静音（用户要求放清屏旁）：图标与全屏音量钮同一套几何（`OverlayVolumeGlyph`，无钮底），
    /// 静音态多一道白斜线——不再用素材 `ic_sound` + 金色斜线（2026-11-15 用户要求两处一致）
    private var muteButton: some View {
        Button {
            guard isActive else { return }
            playback.isMuted.toggle()
        } label: {
            OverlayVolumeGlyph(size: 44, muted: playback.isMuted, color: .white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.isMuted ? "取消静音" : "静音")
    }

    /// 选集胶囊（画布 2:130：326×38 r8 #22262A，SPACE_BETWEEN，pl/pr 16）
    /// 左：「选集 · 全 N 集 · 免费观看」12px Noto Serif SC；右：14×14 朝上 V 形
    private var episodePill: some View {
        Button {
            guard isActive else { return }
            print("PLAYER_DBG [CHECK] episode pill tap → open episode panel")
            onRequestEpisodePanel()
        } label: {
            HStack(spacing: 0) {
                Text("选集 · 全 \(episode.episodeTotal) 集 · 免费观看")
                    .font(DWFont.serif(12, .regular))
                    .foregroundStyle(DWColor.overlayInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
                OverlayChevronGlyph(size: 14, color: DWColor.overlayInk, pointsUp: true)
            }
            .padding(.horizontal, 16)
            // 宽度与调用方的 designFrame 同源（`episodePillWidth`）：只有一处写死就会
            // 出现「外层给 290、内层还是 258，胶囊缩在框里」的错位（2026-11-15 实测踩到）
            .frame(width: Self.episodePillWidth, height: 38)
            .background(DWColor.overlayChip,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选集，共 \(episode.episodeTotal) 集")
    }

    /// 长按倍速提示（瞬态反馈，清屏时保留；位置由调用方决定）
    private var fastForwardCapsule: some View {
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
        .allowsHitTesting(false)
    }

    /// 加载失败提示（瞬态反馈，清屏时保留）
    private func loadErrorHint(_ error: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(DWColor.gold)
            Text(error)
                .font(DWFont.cn(12))
                .foregroundStyle(DWColor.textBody)
                .multilineTextAlignment(.center)
        }
        .allowsHitTesting(false)
    }

    /// 加载转圈：800ms 内就绪的加载不显示（预热命中的秒开路径应当无感）
    private var loadingSpinner: some View {
        ProgressView()
            .tint(.white)
            .allowsHitTesting(false)
    }

    /// 未下载占位（真实存在但尚未下载的集：不转圈、不假装能播）
    private var notDownloadedHint: some View {
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
        .allowsHitTesting(false)
    }
}

// Xcode 15+ / iOS 17+；旧版请改用 PreviewProvider。
#Preview("墨本 · 完整态（静态稿面）") {
    DramaPlayerView(
        episode: .designPreview,
        playback: DramaPlayerViewModel(playerService: PlaybackPlayerService()),
        isActive: false
    )
}
