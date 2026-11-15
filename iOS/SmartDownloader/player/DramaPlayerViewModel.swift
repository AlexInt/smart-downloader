import AVFoundation
import UIKit
import Combine

/// 单集播放状态机（ViewModel）。
/// 只暴露可绑定状态与播放意图；播放器实例归 PlaybackPlayerService，偏好归 PlayerPreferences。
/// 主线程约定：本类全部状态只在主线程访问（GCD 版，无线程标注）
final class DramaPlayerViewModel: ObservableObject {
    private let playerService: PlaybackPlayerService
    var player: AVPlayer { playerService.player }

    @Published private(set) var isReady = false
    /// 切集冻帧（2026-11-15）：换 item **之前**从当前 item 取下的那一帧（UIImage）。
    /// 全屏时视频层搬在全屏容器里、没有卡片加载渐变兜底，`replaceCurrentItem` 那一拍
    /// 会直接露出容器黑底（用户实报「全屏用选集中集数切集时会闪一下」）；
    /// 这帧交给 `PlayerSurfaceUIView` 的冻帧层盖住，新 item 就绪后淡出。
    /// 竖屏不使用它（竖屏原有藏条带 + 渐变交叉淡入是调好的，别合并）。
    @Published private(set) var freezeFrameImage: UIImage?
    private let freezeFrame = PlaybackFreezeFrame()
    @Published private(set) var isFastForwarding = false
    /// seek 手势进行中（seekPan 已起手）：「拖动先起」的触摸由 seek 独占，
    /// 长按不得中途插入起 2x —— 与 isFastForwarding 构成双向互斥（谁先起谁独占本次触摸）。
    /// 置位点 = seekPan .began（起手约 10pt 位移），不是首个有效 .changed（见 beginSeekGesture）。
    /// 非渲染状态，故意不用 @Published（避免每次 seek 触发无意义的视图刷新）
    private(set) var isSeekGestureActive = false
    /// seek 独占的触摸抬手后的吞单击窗口（与卡片长按松手的 250ms 抑制窗同机制）：
    /// seekPan 在 UIKit 层识别且 `cancelsTouchesInView = false`，纯横向滑动时系统分页 pan
    /// 不 begin、触摸全程不被取消，SwiftUI tap 会收到完整触摸序列——抬手即 TAP → 误暂停
    /// （横滑结束大概率暂停的调查结论，2026-11-13）。endSeekGesture 开窗，卡片 onTapGesture 查询。
    /// 非渲染状态，故意不用 @Published。
    private(set) var tapSuppressionDeadline: Date = .distantPast
    /// 清屏下的瞬态进度 HUD：seek 实际生效时置 true（进度条+时间淡入），抬手后停留
    /// 800ms 再淡出（新 seek 会取消旧的淡出任务）。与 isSeekGestureActive 分开——
    /// 那是手势仲裁闸门（非渲染），这是纯 UI 显示状态，必须 @Published 驱动视图。
    @Published private(set) var isScrubbing = false
    @Published private(set) var currentTimeText = "00:00"
    @Published private(set) var durationText = "00:00"
    /// 右侧时长 label 显示剩余时间（负值，如 -01:39）还是总时长；本地持久化（PlayerPreferences）
    @Published private(set) var showRemainingTime = false
    @Published private(set) var remainingTimeText = "-00:00"
    @Published private(set) var progress: Double = 0
    /// 是否正在播（驱动竖屏中央播放/暂停大按钮，画布 19:57）。
    /// 周期回调 0.25s 刷新一次足够（按钮只做显示，动作走 togglePlayback）；
    /// togglePlayback 与 load 里另即时刷新一次，避免点按后按钮要等一个周期才翻面。
    @Published private(set) var isPlaying = false
    @Published private(set) var loadError: String?
    /// spinner 延迟显示：加载超过 800ms 仍未就绪才置 true，预热命中的秒开路径全程无转圈
    /// （800ms 依真机实测定：HIT 就绪 642–871ms、入口 MISS 1008–1177ms，原 300ms 每滑必闪）
    @Published private(set) var isLoadingSlow = false
    /// 当前集视频画面方向：true = 横屏（宽>高）。来源 `AVPlayerItem.presentationSize`
    /// （同步、非废弃 API，HLS 首帧解码后有效）；0×0 = 未知，保持 false 按竖屏处理（维持拉满现状）。
    /// 渲染 gravity 由单例容器统一设置（PlayerPagingScrollView.videoGravity）。
    @Published private(set) var videoIsLandscape = false
    /// 片源像素尺寸（presentationSize）：全屏进/出动画以「视频显示带」（surface 内 fit 的
    /// 居中矩形）为起点/终点，据此换算；0×0 = 未知，退回 surface 全框（旧路径）。
    private(set) var videoPixelSize: CGSize = .zero
    /// 画面适配模式（画布 19:37 按钮）：自动跟随片源方向 / 强制完整 / 强制铺满。
    /// 持久化在本 VM 内存（不进 PlayerPreferences——这是「本次观看」的画面临时口径，
    /// 跨集也不该被记住：新一集方向可能相反，记住旧口径反而每次都错）。
    enum VideoFitMode: String {
        case auto, fit, fill
        var next: VideoFitMode {
            switch self {
            case .auto: return .fit
            case .fit: return .fill
            case .fill: return .auto
            }
        }
        var label: String {
            switch self {
            case .auto: return "自动"
            case .fit: return "完整"
            case .fill: return "铺满"
            }
        }
    }
    @Published private(set) var videoFitMode: VideoFitMode = .auto
    /// 渲染 gravity：受 videoFitMode 覆盖；auto 时沿用原规则（横屏片源 fit、竖屏片源 fill）
    var effectiveVideoGravity: AVLayerVideoGravity {
        switch videoFitMode {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .auto: return videoIsLandscape ? .resizeAspect : .resizeAspectFill
        }
    }
    /// 全屏态（容器 transform 自转，非系统界面旋转）：仅横屏片源可进入，姿态服务（判稳）与
    /// 全屏控制层驱动，Combine 订阅方是 PlayerFullscreenController。
    @Published private(set) var isFullscreen = false
    /// 全屏旋转方向：姿态触发器按设备实际转向给出（重力角 +90° → -π/2，-90° → +π/2），
    /// 保证内容与物理握持一致——写死单方向会让另一半转向的内容上下倒置（返回 icon
    /// 跑到对角、进度条翻到顶部）。控制器进/出动画与控制层安全区映射都用它。
    @Published private(set) var fullscreenRotationAngle: CGFloat = .pi / 2
    /// 全屏锁定（画布 22:31 锁按钮）：锁住后控制层一律不显示，点按也不呼出——
    /// 避免躺着看时误触暂停/退出。非持久化：退出全屏即复位（下次进全屏重新是解锁态）。
    @Published var isFullscreenLocked = false
    /// 自动连播信号（2026-11-14）：单集播完 → PlayerFeedViewModel（持有 queue/slots）
    /// 算出下一集写入这里 → PlayerPagingScrollView 的 Coordinator 订阅并动画翻页 → 置回 nil。
    /// 本类只发播完信号（onPlaybackEnded），不持有队列/槽位知识——下一集计算归 FeedVM，
    /// 加载复用既有停稳管线（pageSettled），不另立加载链路。
    @Published var autoAdvanceSort: Int?
    /// 播完回调（FeedVM 在 init 接线）：didPlayToEnd 且事件对象 === 当前 item 时主线程调用
    var onPlaybackEnded: (() -> Void)?

    @Published var isMuted = false {
        didSet {
            preferences.isMuted = isMuted
            player.isMuted = isMuted
            AppHaptics.light()   // 静音切换：用户拍板 2026-11-13（卡片/全屏控制层共用本 didSet，init 恢复不触发）
            // 持久化写路径日志：与 init 的读路径日志（VM init muted=）成对，
            // 真机上可完整核对「切换静音 → 落盘 → 重开恢复」链路
            print("PLAYER_DBG [Playback] muted=\(isMuted) → persist + applyPlayer")
        }
    }

    /// 清屏模式：隐藏界面信息（信息区/进度/互动栏/字幕/上滑提示/压暗），只留视频与常驻控件
    @Published var isCleanScreen = false {
        didSet {
            preferences.isCleanScreen = isCleanScreen
            AppHaptics.light()   // 清屏切换：用户拍板 2026-11-13（卡片/全屏控制层共用本 didSet，init 恢复不触发）
            print("PLAYER_DBG [Playback] cleanScreen=\(isCleanScreen) → persist")
            // 开启清屏（含 init 恢复）时让进度条+时间闪现 1.5s：盲操作前给一次
            // 「带在哪」的空间参照——用户不知道往哪儿按，带外起点整批静默拒绝
            //（真机日志实证）。瞬态反馈，与 seek HUD 同类；init 恢复时触发是
            // 有意的：每次进清屏播放页都提示一次位置。
            if isCleanScreen {
                showScrubHud(reason: "cleanScreenOn")
                isCleanScreenFlashActive = true
                scheduleScrubLinger(ms: 1500)
            }
        }
    }
    /// 点赞 / 收藏：按当前集的服务端 id 落库（EpisodeActionsStore），不再按目录路径记
    @Published var liked = false {
        didSet { writeAction(column: "liked", value: liked) }
    }
    @Published var saved = false {
        didSet { writeAction(column: "saved", value: saved) }
    }

    /// 常驻播放倍速（画布 22:77 六档，2026-11-15 移除 3.0× 后五档）。与长按 2x 是两套语义：
    /// 这是用户选定的基准速率（持久化），长按 2x 是瞬态叠加、松手还原到这里。
    /// 取值口径：AVPlayer.rate 只在「正在播」时才等于倍速；暂停时 rate=0，
    /// 故用本属性记账，applyRate() 负责按当前播放意图下发。
    @Published private(set) var playbackRate: Double = 1.0 {
        didSet {
            preferences.playbackRate = playbackRate
            applyRate()
            print("PLAYER_DBG [Playback] rate=\(playbackRate)× → persist + applyPlayer")
        }
    }
    /// 倍速档位（2026-11-15 用户拍板移除 3.0×，现五档）：2.0 / 1.5 / 1.25 / 1.0 / 0.75
    /// 降序，与全屏抽屉和竖屏弹层同一份列表——两处不要各写一套
    static let rateOptions: [Double] = [2.0, 1.5, 1.25, 1.0, 0.75]
    /// 倍速数字文案（不带「倍速」二字）：2.0 / 1.5 / 1.25 / 1.0 / 0.75。
    /// 做法是先按两位小数格式化再去掉末位的 0——旧实现用
    /// `replacingOccurrences(of: "0$")`（那是正则写法，字符串替换匹配不到字面量 "0$"），
    /// 结果面板里全是「2.00倍速」「1.00×」，与画布 22:77 的文案对不上。
    static func rateText(_ rate: Double) -> String {
        var text = String(format: "%.2f", rate)
        if text.hasSuffix("0") { text.removeLast() }
        return text
    }
    var playbackRateText: String { Self.rateText(playbackRate) }
    /// 顶栏倍速按钮的紧凑文案：默认档显示「倍速」，选过档位后显示「1.5×」
    var rateShortText: String {
        "\(playbackRateText)×"
    }

    private let preferences = PlayerPreferences()
    /// 当前集的播放进度跟踪（落盘 + 下次续播）：随 load 换人，stop 时摘掉
    private var progressTracker: PlaybackProgressTracker?
    private var timeObserver: Any?
    /// 播完通知观察令牌（AVPlayerItem.didPlayToEnd）：object 传 nil——currentItem 随切集
    /// 更换，一次性挂接会失效；「事件对象 === 当前 item」的同一性判定放回调内，deinit 摘除
    private var endItemObserver: Any?
    /// 当前集的行为数据归属；load 成功后才有值（未下载占位卡为 nil）
    private var currentIdentity: MediaIdentity?
    /// 当前加载的集（回前台重建 item 需要完整槽位：playlistURL / identity / sort）
    private var currentEpisode: PlayableEpisode?

    // MARK: 供全屏控制层读的剧集元信息（本类不持有队列知识，由 PlayerFeedViewModel 注入）

    /// 剧名（横屏顶栏 22:16 与竖屏 2:123 用）
    var seriesName: String = ""
    /// 全集数（选集抽屉网格用）
    var episodeTotal: Int = 0
    /// 当前集号（未加载时为 nil）
    var currentEpisodeIndex: Int? { currentEpisode?.sort }
    /// 进后台那一刻是否在播：回前台只续「用户期望在播」的状态，不替已暂停的用户点播放
    private var wasPlayingBeforeBackground = false
    /// item 网络失败自动重试过的集号（每集最多一次；就绪即清空）——防「失败→重建→再失败」死循环
    private var autoRetriedSorts: Set<Int> = []
    /// 用户播放意图（不跟随系统中断态）：load(autoplay:) / togglePlayback 维护。
    /// item 失败自动重试沿用它，避免「用户暂停着，重试却把画面自动播起来」
    private var userWantsPlayback = false
    /// 回填本集已存状态期间置位： didSet 不能把刚读出来的值再写回库
    private var isRestoringActions = false
    private var lastLoggedSeek: Double = -1
    private var lastLoggedSecond = -1
    private var spinnerDelayWork: DispatchWorkItem?
    private var scrubLingerWork: DispatchWorkItem?
    /// 加载代际：每次 load/stop 递增；KVO/看门狗/makeItem 回调捕获代际，
    /// 过期一律丢弃（防快滑/退出后迟到事件翻转状态）
    private var loadGeneration = 0
    private var statusWatch: StatusWatch?
    /// 清屏位置参照闪现进行中：闪现与 seek 残影是两种瞬态——切集的 load() 清残影时
    /// 不得把开屏闪现一并吞掉（真机日志实证：cleanScreenOn 闪现被 load 截短，无 linger1500ms 收尾）
    private var isCleanScreenFlashActive = false

    init(playerService: PlaybackPlayerService) {
        self.playerService = playerService
        isMuted = preferences.isMuted
        isCleanScreen = preferences.isCleanScreen
        showRemainingTime = preferences.showRemainingTime
        // 恢复常驻倍速：直接写字段不走 didSet 之外的重活——init 阶段 player 还没 item，
        // applyRate 会因为没在播而什么都不做（load 时会按 playbackRate 重新下发）
        // 3.0× 已于 2026-11-15 移出档位：老用户存过 3.0 时回落到 1.0，避免面板里没有任何
        // 一行是高亮的（「当前倍速」与选项表对不上）
        let storedRate = preferences.playbackRate
        if Self.rateOptions.contains(storedRate) {
            playbackRate = storedRate
        } else {
            playbackRate = 1.0
            print("PLAYER_DBG [Playback] restore rate=\(storedRate)× notInOptions → fallback 1.0")
        }
        ensureObserver()
        // 播完观察（自动连播信号源）：通知线程不定，回主线程判「事件对象 === 当前 item」
        // 再碰状态（GCD 约定）——同一性判定天然过滤旧 item 的迟到事件（防快滑/切集竞态）
        endItemObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: nil
        ) { [weak self] note in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let item = note.object as? AVPlayerItem,
                      item === self.player.currentItem else {
                    print("PLAYER_DBG [Playback] itemDidPlayToEnd SKIP reason=staleItem")
                    return
                }
                print("PLAYER_DBG [Playback] itemDidPlayToEnd sort=\(self.currentEpisode?.sort ?? -1) → signal onPlaybackEnded")
                self.onPlaybackEnded?()
            }
        }
        print("PLAYER_DBG [Playback] VM init muted=\(isMuted) cleanScreen=\(isCleanScreen) remaining=\(showRemainingTime)")
    }

    /// 滚动停稳后才调用：单播放器常驻，切集只换 item。
    /// 就绪判定为事件驱动（KVO 直挂 + 主线程判定）：status 一变立刻翻转 isReady，
    /// 无轮询量化误差；4s 看门狗兜底；取消安全（代际令牌使迟到事件失效）。
    /// autoplay = false 用于「回前台重建」：只恢复画面与位置，不替已暂停的用户继续播。
    /// completion 在加载落地（就绪/失败/超时/取消）后于主线程回调。
    func load(episode: PlayableEpisode, autoplay: Bool = true, completion: (() -> Void)? = nil) {
        print("PLAYER_DBG [Playback] load begin sort=\(episode.sort) available=\(episode.isAvailable) autoplay=\(autoplay)")
        // 先把上一集的位置落盘再换 item：detach 后旧跟踪器不再碰播放器
        progressTracker?.detach()
        progressTracker = nil
        loadGeneration += 1
        let generation = loadGeneration
        statusWatch?.invalidate()
        statusWatch = nil
        endFastForward()
        endSeekGesture()
        hideScrubHudNow()
        loadError = nil
        // 切集前先冻住当前画面：此刻 player.currentItem 还是旧 item（已 ready、正在显示），
        // 从它的 AVPlayerItemVideoOutput 同步拷一帧（已解码帧，~1-5ms，主线程无感）。
        // 必须在 isReady=false 之前取——sink 一收到 false 就要拿这帧去盖屏。
        freezeFrameImage = freezeFrame.snapshot(of: player)
        isReady = false
        resetTimes()
        lastLoggedSecond = -1

        guard episode.playlistURL != nil else {
            print("PLAYER_DBG [Playback] load ABORT reason=episodeNotDownloaded sort=\(episode.sort)")
            currentEpisode = nil
            // 不会有 ready 了：冻帧必须立刻放掉，否则旧画面会盖在新页面上一段时间
            clearFreezeFrame(reason: "abort")
            playerService.clear()
            completion?()
            return
        }
        ensureObserver()

        currentEpisode = episode
        currentIdentity = episode.identity
        isRestoringActions = true
        let stored = EpisodeActionsStore.actions(for: episode.identity)
        liked = stored.liked
        saved = stored.saved
        isRestoringActions = false
        let storedPosition = stored.position.map { "\(Int($0.seconds))s/\(Int($0.total))s" } ?? "nil"
        print("PLAYER_DBG [Playback] load actions id=\(episode.identity.label) liked=\(liked) saved=\(saved) position=\(storedPosition)")

        // 进度跟踪：归属直接用槽位算好的 identity（有服务端 id 走 id，没有走本地路径），
        // 挂在常驻 player 上，切集时随 load 开头 detach
        let tracker = PlaybackProgressTracker(identity: episode.identity)
        tracker.onResumed = { [weak self] value in self?.handleResumed(value) }
        tracker.attach(to: player)
        progressTracker = tracker

        playerService.makeItem(for: episode) { [weak self] item in
            guard let self, generation == self.loadGeneration else {
                print("PLAYER_DBG [Playback] load CANCELLED sort=\(episode.sort)")
                completion?()
                return
            }
            guard let item else {
                self.loadError = "本地播放服务启动失败"
                print("PLAYER_DBG [Playback] load FAIL reason=makeItemNil error=\(self.loadError ?? "")")
                completion?()
                return
            }
            self.player.replaceCurrentItem(with: item)
            // 新 item 挂视频输出：下一次切集才有「当前显示帧」可取（要在起播前挂上，
            // 否则起播后头几帧不入输出）。attach 只挂新 item，旧 item 随替换释放
            self.freezeFrame.attach(to: item)
            self.player.isMuted = self.isMuted
            self.userWantsPlayback = autoplay
            if autoplay {
                // 先落倍速再 play：play() 会把 rate 拨回 1.0，顺序反了则新一集从 1x 起步
                self.player.play()
                self.player.rate = Float(self.playbackRate)
                print("PLAYER_DBG [Playback] load applyRate=\(self.playbackRate)×")
            } else {
                print("PLAYER_DBG [Playback] load holdPaused sort=\(episode.sort) reason=autoplay=false")
            }
            self.beginSpinnerDelay()
            self.watchStatus(item: item, episode: episode, generation: generation,
                             startedAt: Date(), completion: completion)
        }
    }

    /// 丢弃当前冻帧（不会有 ready 的失败分支调：旧画面不能继续盖在新内容上）。
    /// Published 变化由 PlayerPagingScrollView 订阅 → surface.releaseFreezeFrame
    private func clearFreezeFrame(reason: String) {
        guard freezeFrameImage != nil else { return }
        freezeFrameImage = nil
        print("PLAYER_DBG [FreezeFrame] clear reason=\(reason)")
    }

    #if DEBUG
    /// 样张验收用（`-playerFreezePreview`）：与切集时同一条取帧路径，只是不换 item
    func debugFreezeSnapshot() -> UIImage? {
        freezeFrame.snapshot(of: player)
    }
    #endif

    func togglePlayback() {
        // 等待缓冲态也算「在播」：此时点按应当是「暂停」，否则会再下发一次 play()，
        // 图标毫无反应（用户会觉得点不动）——与 refreshIsPlaying 同一口径。
        let wasPlaying = player.timeControlStatus != .paused
        print("PLAYER_DBG [Playback] togglePlayback wasPlaying=\(wasPlaying) control=\(player.timeControlStatus.rawValue) → \(wasPlaying ? "pause" : "play")")
        // 点按（暂停/播放）也展示进度 HUD，3s 无其他操作后淡出（用户指定，清屏下尤其需要）。
        // 放 early return 之前，暂停/播放两条路径都触发；其他操作（seek/再点按/切集）会重置或清掉它
        showScrubHud(reason: "tap")
        scheduleScrubLinger(ms: 3000)
        if wasPlaying {
            player.pause()
            userWantsPlayback = false
            isPlaying = false
            // 暂停点就是用户看到的位置，不等 5 秒边界立即落盘
            progressTracker?.flush()
            return
        }
        // 片尾态不复活（用户拍板 2026-11-14）：播完停在末帧，点按不得从头重播——
        // 旧实现此处 seek(.zero)+play()，末集播完误点一下整集从头放（真机日志实证）。
        // 非 last 集的播完窗口由自动连播接管（~1s 内滚走），片尾停留态实际只有末集，
        // 故不做 last 判定（播放 VM 也不持有队列知识）。重看走横向 seek 拖离片尾，
        // 拖回正片区间后点按恢复正常播放语义
        if let item = player.currentItem {
            let total = CMTimeGetSeconds(item.duration)
            let now = CMTimeGetSeconds(player.currentTime())
            if total.isFinite, total > 0, now >= total - 0.2 {
                print("PLAYER_DBG [Playback] togglePlayback SKIP reason=atEnd at=\(Int(now))/\(Int(total))")
                return
            }
        }
        userWantsPlayback = true
        // 同理先 play 再落倍速：play() 内置把 rate 拨回 1.0，暂停期间选过 1.5 档的话
        // 这里不补一次就又回 1x 了
        player.play()
        player.rate = Float(playbackRate)
        isPlaying = true
    }

    /// 关键时机之一：App 进后台时由视图层转发调用，把内存里攒的位置先落库
    func flushProgress() {
        guard let progressTracker else { return }
        progressTracker.flush()
        print("PLAYER_DBG [Playback] progressFlush reason=external")
    }

    // MARK: 前后台生命周期（回前台恢复）

    /// App 进后台：本 App 无 background audio 权限，系统会挂起进程、播放器连接随之断开。
    /// 记录「进后台前是否在播」并主动暂停 + 落盘进度（回前台只续用户期望的播放状态）。
    func applicationDidEnterBackground() {
        wasPlayingBeforeBackground = player.timeControlStatus == .playing
        userWantsPlayback = wasPlayingBeforeBackground
        if wasPlayingBeforeBackground {
            player.pause()
        }
        progressTracker?.flush()
        print("PLAYER_DBG [Lifecycle] background wasPlaying=\(wasPlayingBeforeBackground) item=\(itemStatusDescription())")
    }

    /// App 回前台：本地回环服务可能已被系统回收（监听 socket 失效、端口号却还是旧值），
    /// item 也可能在后台期间连接全失败进入 .failed（错误文案即系统本地化的「无法连接服务器」）。
    /// 两种情况都要重建：重启服务（端口可能变化）→ 作废预热池 → 新 URL 重建 item → 续播原位。
    /// 连接仍健康时只恢复播放，不打断画面。
    func applicationWillEnterForeground() {
        let status = player.currentItem?.status ?? .unknown
        print("PLAYER_DBG [Lifecycle] foreground item=\(itemStatusDescription()) rate=\(player.rate) control=\(player.timeControlStatus.rawValue) loadError=\(loadError ?? "nil") wasPlaying=\(wasPlayingBeforeBackground)")
        guard let episode = currentEpisode else {
            print("PLAYER_DBG [Lifecycle] foreground SKIP reason=noCurrentEpisode")
            return
        }
        let needsRebuild = player.currentItem == nil || status == .failed || loadError != nil
        guard needsRebuild else {
            if wasPlayingBeforeBackground, player.timeControlStatus != .playing {
                player.play()
                // 回前台续播同样要还原常驻倍速（play() 会把 rate 拨回 1.0）
                player.rate = Float(playbackRate)
                print("PLAYER_DBG [Lifecycle] foreground resumeOnly rate=\(player.rate) targetRate=\(playbackRate)×")
            }
            return
        }
        rebuildCurrentItem(episode: episode, autoplay: wasPlayingBeforeBackground, reason: "foreground")
    }

    /// 本地服务重启 + item 重建（前后台恢复 / item 网络失败自动重试共用）。
    /// restart 会在 stateQueue 上回调端口，回主线程再 load（load 只碰主线程状态）。
    /// 端口稳定（固定端口生效）时保留预热池——资产 URL 仍指向同一服务，重建可直接
    /// 走秒开 HIT；只有端口真的变了（首选端口被占用回退到系统分配）才作废旧 URL。
    private func rebuildCurrentItem(episode: PlayableEpisode, autoplay: Bool, reason: String) {
        let position = player.currentTime().seconds
        let oldPort = LocalMediaServer.shared.portSnapshot
        print("PLAYER_DBG [Lifecycle] rebuild begin reason=\(reason) sort=\(episode.sort) at=\(String(format: "%.1f", position.isFinite ? position : 0))s autoplay=\(autoplay) oldPort=\(oldPort)")
        LocalMediaServer.shared.restart { [weak self] port in
            DispatchQueue.main.async {
                guard let self else { return }
                print("PLAYER_DBG [Lifecycle] rebuild serverPort=\(port)")
                if port != oldPort {
                    self.playerService.invalidatePreloaded()
                    print("PLAYER_DBG [Lifecycle] portChanged old=\(oldPort) new=\(port) → invalidatePool")
                } else {
                    print("PLAYER_DBG [Lifecycle] portStable port=\(port) → keepPreloaded")
                }
                // 进度跟踪器会按库里已 flush 的位置续播（进后台时与暂停时都落过盘）
                self.load(episode: episode, autoplay: autoplay)
            }
        }
    }

    private func itemStatusDescription() -> String {
        guard let item = player.currentItem else { return "nil" }
        switch item.status {
        case .unknown: return "unknown"
        case .readyToPlay: return "ready"
        case .failed: return "failed(\(item.error?.localizedDescription ?? "?"))"
        @unknown default: return "unknown"
        }
    }

    /// 点按右侧时长 label：总时长 ↔ 剩余时间（负值）切换，本地持久化（PlayerPreferences）
    func toggleTimeDisplay() {
        showRemainingTime.toggle()
        preferences.showRemainingTime = showRemainingTime
        print("PLAYER_DBG [Playback] timeDisplay → \(showRemainingTime ? "remaining" : "duration")")
    }

    // MARK: 全屏（容器 transform 自转，无系统界面旋转）

    /// 进入全屏：仅横屏片源 + 已就绪有效（竖屏片源转横只会得到细竖条，不动作）。
    /// rotationAngle 由姿态触发器按设备实际转向给出（±π/2），控制器与控制层安全区共用。
    func enterFullscreen(rotationAngle: CGFloat) {
        guard videoIsLandscape, isReady, !isFullscreen else {
            print("PLAYER_DBG [Fullscreen] enterIntent SKIP videoIsLandscape=\(videoIsLandscape) isReady=\(isReady) already=\(isFullscreen)")
            return
        }
        fullscreenRotationAngle = rotationAngle
        isFullscreen = true
        print("PLAYER_DBG [Fullscreen] enterIntent OK angle=\(rotationAngle == .pi / 2 ? "+π/2" : "-π/2")")
    }

    /// 退出全屏（姿态回竖稳 / 控制层返回 icon）
    func exitFullscreen() {
        guard isFullscreen else {
            print("PLAYER_DBG [Fullscreen] exitIntent SKIP reason=notFullscreen")
            return
        }
        isFullscreen = false
        print("PLAYER_DBG [Fullscreen] exitIntent OK")
    }

    /// 全屏中左右转向切换：仅更新旋转方向（触发器判稳后调用），
    /// 控制器订阅后做转体动画；写死单方向会让另一侧内容上下颠倒
    func rotateFullscreen(to angle: CGFloat) {
        guard isFullscreen, fullscreenRotationAngle != angle else {
            print("PLAYER_DBG [Fullscreen] rotate SKIP fullscreen=\(isFullscreen) sameAngle=\(fullscreenRotationAngle == angle)")
            return
        }
        print("PLAYER_DBG [Fullscreen] rotate to=\(angle == .pi / 2 ? "+π/2" : "-π/2")")
        fullscreenRotationAngle = angle
    }

    func seek(fraction: Double) {
        isSeekGestureActive = true
        guard !isFastForwarding else {
            // 「长按先起」的触摸由 2x 独占：按住 2x 期间指头在进度带内漂移不得 seek
            if abs(fraction - lastLoggedSeek) > 0.05 {
                lastLoggedSeek = fraction
                print("PLAYER_DBG [Playback] seek SKIP reason=fastForwarding fraction=\(String(format: "%.2f", fraction))")
            }
            return
        }
        guard let item = player.currentItem else {
            print("PLAYER_DBG [Playback] seek SKIP reason=noItem fraction=\(String(format: "%.2f", fraction))")
            return
        }
        let total = CMTimeGetSeconds(item.duration)
        guard total.isFinite, total > 0 else {
            print("PLAYER_DBG [Playback] seek SKIP reason=badDuration total=\(total)")
            return
        }
        let ratio = min(max(fraction, 0), 1)
        if abs(ratio - lastLoggedSeek) > 0.05 {
            lastLoggedSeek = ratio
            print("PLAYER_DBG [CHECK] seek fraction=\(String(format: "%.2f", ratio)) total=\(Int(total))")
        }
        showScrubHud(reason: "seek")
        let target = CMTime(seconds: total * ratio, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        syncTime(target)
    }

    /// seekPan 起手（约 10pt 位移）即翻转仲裁闸门：「拖动先起」的判定点不能等
    /// .changed 攒够「水平主导 + dx>6」——清屏下进度带不可见，横滑起点常落在带外
    /// （识别器曾按带内过滤 begin，收不到任何事件），斜起手快速转水平同理；长按
    /// 0.15s 的 perform 会插进这个空窗误起 2x（闪倍速提示）。慢漂移起手慢于 0.15s，
    /// 长按仍先起，2x 不受影响。此时尚未真正 seek，不动 isScrubbing。
    func beginSeekGesture() {
        guard !isSeekGestureActive else { return }
        isSeekGestureActive = true
    }

    /// seekPan 抬手 / 被系统滚动抢占：结束「拖动独占」标记，下一次长按可正常起 2x
    func endSeekGesture() {
        guard isSeekGestureActive else { return }
        isSeekGestureActive = false
        // seek 独占过的触摸抬手：开吞单击窗，吞掉 SwiftUI tap 在横滑抬手时的误触发
        //（不设窗则每次横滑结束大概率误暂停，调查结论见 tapSuppressionDeadline 注释）
        tapSuppressionDeadline = Date().addingTimeInterval(0.25)
        scheduleScrubLinger()
        // 拖完就落盘：拖到片尾直接退出也应当记住位置（未起手势时为空操作）
        progressTracker?.flush()
        print("PLAYER_DBG [Playback] seekGesture end")
    }

    func stop() {
        print("PLAYER_DBG [Playback] stop")
        // 退出前把本集位置落盘（趁 item 还在），再拆观察器与播放器
        progressTracker?.detach()
        progressTracker = nil
        loadGeneration += 1
        statusWatch?.invalidate()
        statusWatch = nil
        isFastForwarding = false
        isFullscreen = false   // 播放页销毁：全屏态复位（容器由 Coordinator.dismantle 显式还原）
        endSeekGesture()
        isCleanScreenFlashActive = false
        hideScrubHudNow()
        cancelSpinnerDelay()
        playerService.clear()
        // 冻帧输出随 item 释放，引用一并清（退页后不该再持有一张全屏尺寸的图）
        freezeFrame.detach()
        freezeFrameImage = nil
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        isReady = false
        print("PERF_DBG exit t=\(PERF.ms()) phase=vmStopDone (observers detached, player cleared)")
    }

    deinit {
        // 播完通知观察随 VM 释放摘除（object: nil 的令牌式观察必须显式移除）
        if let endItemObserver {
            NotificationCenter.default.removeObserver(endItemObserver)
        }
        // 退出探针：fullScreenCover 销毁时机 = VM（连带 AVPlayer）释放点。
        // 5.2s 冻结疑似落在 deinit 前后（AVFoundation 远端 teardown / SwiftUI 收尾），
        // 时间戳与 mainStall 对照即可钉出冻结段归属
        print("PERF_DBG exit t=\(PERF.ms()) phase=playerVMDeinit thread=\(Thread.isMainThread ? "main" : "bg")")
    }

    func beginFastForward() {
        // 等待缓冲态也允许起 2x：AVPlayer 会把它记为目标倍速，缓冲好后按 2x 恢复
        let status = player.timeControlStatus
        guard isReady, !isFastForwarding,
              status == .playing || status == .waitingToPlayAtSpecifiedRate else {
            print("PLAYER_DBG [Playback] beginFastForward SKIP ready=\(isReady) already=\(isFastForwarding) control=\(status.rawValue)")
            return
        }
        isFastForwarding = true
        player.rate = 2.0
        AppHaptics.light()   // 长按 2x 起手确认（行业惯例：动作确认给轻触；退出回 1x 不加，避免双震）
        print("PLAYER_DBG [CHECK] fastForward → 2x control=\(status.rawValue)")
    }

    func endFastForward() {
        guard isFastForwarding else { return }
        isFastForwarding = false
        // 只要不是用户主动暂停（如片尾 actionAtItemEnd），一律把目标倍速拨回常驻倍速。
        // 此前只在 .playing 时才置回：缓冲等待态(.waitingToPlayAtSpecifiedRate)被漏掉，
        // 手松开后缓冲恢复播放仍是 2x —— 即用户反馈的「松手没有立即变回 1 倍速」。
        // 还原目标是 playbackRate（用户选的档位）而非写死 1.0：选了 1.5 倍速后长按 2x，
        // 松手应回 1.5 而不是跌回 1.0。
        if player.timeControlStatus != .paused {
            player.rate = Float(playbackRate)
        }
        print("PLAYER_DBG [CHECK] fastForward → \(playbackRate)× control=\(player.timeControlStatus.rawValue)")
    }

    /// 切换常驻倍速（倍速抽屉点选）。正在播则立即生效；暂停中只记账，
    /// 恢复播放时由 applyRate 下发（AVPlayer 在 rate=0 时设 rate 会直接开播，不能盲设）。
    func setPlaybackRate(_ rate: Double) {
        guard Self.rateOptions.contains(rate) else {
            print("PLAYER_DBG [Playback] setRate SKIP reason=notInOptions rate=\(rate)")
            return
        }
        guard rate != playbackRate else {
            print("PLAYER_DBG [Playback] setRate SKIP reason=same rate=\(rate)")
            return
        }
        playbackRate = rate
        AppHaptics.light()   // 档位切换确认，与静音/清屏同一手势语言
    }

    /// 画面适配按钮（画布 19:37）：自动 → 完整 → 铺满 三档循环。
    /// 与 PlayerPagingScrollView 的 gravity sink 联动——那边订阅 videoFitMode 即时落 gravity。
    func cycleVideoGravity() {
        let next = videoFitMode.next
        print("PLAYER_DBG [Playback] fitMode \(videoFitMode.label) → \(next.label) landscape=\(videoIsLandscape)")
        videoFitMode = next
        AppHaptics.light()
    }

    /// 按当前播放意图下发倍速：只在「本该在播」时设 rate（暂停中设 rate 会强制开播）。
    /// 长按 2x 期间的临时 2x 优先——此时不动，等 endFastForward 统一还原。
    private func applyRate() {
        guard !isFastForwarding else {
            print("PLAYER_DBG [Playback] applyRate SKIP reason=fastForwarding")
            return
        }
        guard userWantsPlayback, player.timeControlStatus != .paused else {
            print("PLAYER_DBG [Playback] applyRate DEFER reason=notPlaying rate=\(playbackRate)")
            return
        }
        player.rate = Float(playbackRate)
        print("PLAYER_DBG [Playback] applyRate → \(playbackRate)×")
    }


    // MARK: 私有

    /// item 就绪事件：ready / failed / 超时兜底
    fileprivate enum StatusEvent {
        case ready
        case failed(String)
        case timeout
    }

    /// 单次加载的 KVO 观察器 + 看门狗（按次持有：settle 只清理本次的，
    /// 不误伤新 load 安装的观察器）
    private final class StatusWatch {
        var observer: NSKeyValueObservation?
        var watchdog: DispatchWorkItem?
        func invalidate() {
            observer?.invalidate()
            observer = nil
            watchdog?.cancel()
            watchdog = nil
        }
    }

    /// AVPlayerItem.status 就绪观察：KVO 即时推送（无轮询量化误差）。
    /// `.initial` 选项让「观察开始前就已 ready」（预热命中）也能立刻收到事件；
    /// 4s 看门狗兜底；任一事件落地即清理观察器与看门狗。
    /// 代际 + item 同一性双保险：新滑动/退出后迟到事件不得翻转状态。
    private func watchStatus(item: AVPlayerItem, episode: PlayableEpisode, generation: Int,
                             startedAt: Date, completion: (() -> Void)?) {
        let watch = StatusWatch()
        statusWatch = watch
        let settle: (StatusEvent) -> Void = { [weak self] event in
            watch.invalidate()
            defer { completion?() }
            guard let self, generation == self.loadGeneration else {
                print("PLAYER_DBG [Playback] load CANCELLED sort=\(episode.sort)")
                return
            }
            guard item === self.player.currentItem else {
                print("PLAYER_DBG [Playback] status STALE reason=replacedItem sort=\(episode.sort)")
                return
            }
            switch event {
            case .ready:
                self.isReady = true
                self.autoRetriedSorts.removeAll()
                self.cancelSpinnerDelay()
                self.refreshVideoOrientation(reason: "ready")
                // 就绪即尝试续播（时长未稳时跟踪器会在首个 tick 再试一次）
                _ = self.progressTracker?.resumeIfNeeded()
                let waitedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                print("PLAYER_DBG [CHECK] load OK sort=\(episode.sort) ready=true waitedMs=\(waitedMs) rate=\(self.player.rate) control=\(self.player.timeControlStatus.rawValue)")
            case .failed(let message):
                self.loadError = message
                self.cancelSpinnerDelay()
                print("PLAYER_DBG [Playback] load FAIL reason=itemFailed error=\(message)")
                // 网络类失败（本地服务被系统回收 / 切网）重建一次：重启服务 → 新端口 → 新 URL。
                // 每集只重试一次，就绪即清空；重试仍失败就保持错误提示（不无限重试）
                if !self.autoRetriedSorts.contains(episode.sort) {
                    self.autoRetriedSorts.insert(episode.sort)
                    self.rebuildCurrentItem(episode: episode, autoplay: self.userWantsPlayback,
                                            reason: "itemFailed")
                } else {
                    // 重试也失败：冻帧不能继续盖着旧画面（不会有 ready 了）
                    self.clearFreezeFrame(reason: "itemFailedFinal")
                }
            case .timeout:
                self.loadError = "视频加载超时"
                self.cancelSpinnerDelay()
                self.clearFreezeFrame(reason: "timeout")
                print("PLAYER_DBG [Playback] load FAIL reason=watchdogTimeout sort=\(episode.sort)")
            }
        }
        watch.observer = item.observe(\.status, options: [.initial, .new]) { item, _ in
            // KVO 回调线程不定，统一回主线程判定（状态只碰主线程）
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay: settle(.ready)
                case .failed: settle(.failed(item.error?.localizedDescription ?? "视频加载失败"))
                default: break
                }
            }
        }
        let watchdog = DispatchWorkItem { settle(.timeout) }
        watch.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: watchdog)
    }

    /// spinner 延迟显示：800ms 内就绪的加载完全不出现转圈（预热命中的常态）；
    /// 超过 800ms 仍未就绪才置 isLoadingSlow，让卡片显示 spinner。
    private func beginSpinnerDelay() {
        spinnerDelayWork?.cancel()
        isLoadingSlow = false
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.isReady, self.loadError == nil {
                self.isLoadingSlow = true
                print("PLAYER_DBG [Playback] spinner show reason=notReadyAfter800ms")
            }
        }
        spinnerDelayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func cancelSpinnerDelay() {
        spinnerDelayWork?.cancel()
        spinnerDelayWork = nil
        isLoadingSlow = false
    }

    // MARK: 清屏瞬态进度 HUD

    /// HUD 淡入：seek 实际生效（拖动中每次 .changed 续命）/ 开启清屏时的位置参照闪现
    private func showScrubHud(reason: String) {
        scrubLingerWork?.cancel()
        scrubLingerWork = nil
        guard !isScrubbing else { return }
        isScrubbing = true
        print("PLAYER_DBG [Playback] scrub show reason=\(reason) clean=\(isCleanScreen)")
    }

    /// HUD 停留一段时间再淡出；seek 抬手默认 800ms，清屏参照闪现 1500ms
    private func scheduleScrubLinger(ms: Int = 800) {
        guard isScrubbing else { return }
        scrubLingerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isScrubbing else { return }
            self.isScrubbing = false
            self.isCleanScreenFlashActive = false
            print("PLAYER_DBG [Playback] scrub hide reason=linger\(ms)ms")
        }
        scrubLingerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
    }

    /// 切集 / 退出：立即清除 seek 残影，不留 800ms 残影。
    /// 开屏清屏闪现（isCleanScreenFlashActive）不是残影，不在此清——否则被 load 截短（日志实证）
    private func hideScrubHudNow() {
        guard !isCleanScreenFlashActive else {
            print("PLAYER_DBG [Playback] scrub hide SKIP reason=cleanScreenFlash")
            return
        }
        scrubLingerWork?.cancel()
        scrubLingerWork = nil
        isScrubbing = false
    }

    /// 点赞 / 收藏写库：回填期间与还没有身份（未下载占位卡）时都不写
    private func writeAction(column: String, value: Bool) {
        guard !isRestoringActions, let currentIdentity else { return }
        if column == "liked" {
            EpisodeActionsStore.setLiked(value, for: currentIdentity)
        } else {
            EpisodeActionsStore.setSaved(value, for: currentIdentity)
        }
        print("PLAYER_DBG [Playback] action \(column)=\(value) id=\(currentIdentity.label) → persist")
    }

    /// 续播落地：立即刷新时间文案，并闪现进度 HUD 1.5s 让用户看到「从哪继续」
    private func handleResumed(_ value: PlaybackProgress) {
        syncTime(CMTime(seconds: value.seconds, preferredTimescale: 600))
        showScrubHud(reason: "resume")
        scheduleScrubLinger(ms: 1500)
    }

    private func ensureObserver() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main,
            using: { [weak self] time in
                self?.syncTime(time)   // queue: .main 已保证主线程
            }
        )
    }

    private func syncTime(_ time: CMTime) {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return }
        currentTimeText = Self.format(seconds)
        // 播放/暂停态跟着周期回调走：中央大按钮（画布 19:57）与横屏暂停双竖条靠它驱动
        refreshIsPlaying()
        let total = CMTimeGetSeconds(player.currentItem?.duration ?? .zero)
        guard total.isFinite, total > 0 else { return }
        durationText = Self.format(total)
        remainingTimeText = "-" + Self.format(max(0, total - seconds))
        progress = min(max(seconds / total, 0), 1)
        refreshVideoOrientation(reason: "tick")
        // 每 2 秒确认一次播放器确实在推进，区分「没播」和「画面没刷新」
        let second = Int(seconds)
        if second % 2 == 0, second != lastLoggedSecond {
            lastLoggedSecond = second
            print("PLAYER_DBG [CHECK] playbackTime=\(second)s rate=\(player.rate) control=\(player.timeControlStatus.rawValue)")
        }
    }

    private func resetTimes() {
        // 新 item 方向未知：先按竖屏（fill 现状），presentationSize 就绪后由 refreshVideoOrientation 修正
        videoIsLandscape = false
        videoPixelSize = .zero
        currentTimeText = "00:00"
        durationText = "00:00"
        remainingTimeText = "-00:00"
        progress = 0
        isPlaying = false
    }

    /// 播放/暂停态同步（@Published 只在真正翻转时赋值，避免每 0.25s 触发无意义刷新）
    ///
    /// 「在播」判定必须把 `waitingToPlayAtSpecifiedRate`（缓冲等待）算在内：只看
    /// `== .playing` 的话，蜂窝/弱网每遇一次缓冲就翻成 false、恢复后翻回 true，
    /// 中部大按钮与横屏暂停双竖条的图标就会**自己来回刷**（2026-11-15 用户实报
    /// 「点击暂停和播放时 icon 一直在刷」）。等待态在语义上就是「用户要它播」。
    private func refreshIsPlaying() {
        let playing = player.timeControlStatus != .paused
        guard playing != isPlaying else { return }
        print("PLAYER_DBG [Playback] isPlaying \(isPlaying) → \(playing) control=\(player.timeControlStatus.rawValue)")
        isPlaying = playing
    }

    /// 片源方向刷新：presentationSize 有效（宽高 > 0）才更新，未知不动。
    /// 读取点 = ready 与 0.25s 周期回调；横屏片源在竖屏持机要 fit 完整显示（用户要求：不统一竖屏拉满）。
    private func refreshVideoOrientation(reason: String) {        let size = player.currentItem?.presentationSize ?? .zero
        guard size.width > 0, size.height > 0 else { return }
        videoPixelSize = size
        let landscape = size.width > size.height
        guard landscape != videoIsLandscape else { return }
        videoIsLandscape = landscape
        print("PLAYER_DBG [Playback] videoOrientation landscape=\(landscape) size=\(Int(size.width))x\(Int(size.height)) reason=\(reason)")
    }

    private static func format(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value >= 3600 {
            return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
