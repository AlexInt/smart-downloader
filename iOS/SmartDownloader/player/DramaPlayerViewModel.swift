import AVFoundation
import Combine

/// 单集播放状态机（ViewModel）。
/// 只暴露可绑定状态与播放意图；播放器实例归 PlaybackPlayerService，偏好归 PlayerPreferences。
/// 主线程约定：本类全部状态只在主线程访问（GCD 版，无线程标注）
final class DramaPlayerViewModel: ObservableObject {
    private let playerService: PlaybackPlayerService
    var player: AVPlayer { playerService.player }

    @Published private(set) var isReady = false
    @Published private(set) var isFastForwarding = false
    /// seek 手势进行中（seekPan 已起手）：「拖动先起」的触摸由 seek 独占，
    /// 长按不得中途插入起 2x —— 与 isFastForwarding 构成双向互斥（谁先起谁独占本次触摸）。
    /// 置位点 = seekPan .began（起手约 10pt 位移），不是首个有效 .changed（见 beginSeekGesture）。
    /// 非渲染状态，故意不用 @Published（避免每次 seek 触发无意义的视图刷新）
    private(set) var isSeekGestureActive = false
    /// 清屏下的瞬态进度 HUD：seek 实际生效时置 true（进度条+时间淡入），抬手后停留
    /// 800ms 再淡出（新 seek 会取消旧的淡出任务）。与 isSeekGestureActive 分开——
    /// 那是手势仲裁闸门（非渲染），这是纯 UI 显示状态，必须 @Published 驱动视图。
    @Published private(set) var isScrubbing = false
    @Published private(set) var currentTimeText = "00:00"
    @Published private(set) var durationText = "00:00"
    @Published private(set) var progress: Double = 0
    @Published private(set) var loadError: String?
    /// spinner 延迟显示：加载超过 800ms 仍未就绪才置 true，预热命中的秒开路径全程无转圈
    /// （800ms 依真机实测定：HIT 就绪 642–871ms、入口 MISS 1008–1177ms，原 300ms 每滑必闪）
    @Published private(set) var isLoadingSlow = false

    @Published var isMuted = false {
        didSet {
            preferences.isMuted = isMuted
            player.isMuted = isMuted
            // 持久化写路径日志：与 init 的读路径日志（VM init muted=）成对，
            // 真机上可完整核对「切换静音 → 落盘 → 重开恢复」链路
            print("PLAYER_DBG [Playback] muted=\(isMuted) → persist + applyPlayer")
        }
    }

    /// 清屏模式：隐藏界面信息（信息区/进度/互动栏/字幕/上滑提示/压暗），只留视频与常驻控件
    @Published var isCleanScreen = false {
        didSet {
            preferences.isCleanScreen = isCleanScreen
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
    @Published var liked = false {
        didSet { preferences.setLiked(liked, for: currentKey) }
    }
    @Published var saved = false {
        didSet { preferences.setSaved(saved, for: currentKey) }
    }

    private let preferences = PlayerPreferences()
    private var timeObserver: Any?
    private var currentKey = ""
    private var lastLoggedSeek: Double = -1
    private var lastLoggedSecond = -1
    private var spinnerDelayWork: DispatchWorkItem?
    private var scrubLingerWork: DispatchWorkItem?
    /// 加载代际：每次 load/stop 递增；KVO/看门狗/makeItem 回调捕获代际，
    /// 过期一律丢弃（等价旧 Task 取消，防快滑/退出后迟到事件翻转状态）
    private var loadGeneration = 0
    private var statusWatch: StatusWatch?
    /// 清屏位置参照闪现进行中：闪现与 seek 残影是两种瞬态——切集的 load() 清残影时
    /// 不得把开屏闪现一并吞掉（真机日志实证：cleanScreenOn 闪现被 load 截短，无 linger1500ms 收尾）
    private var isCleanScreenFlashActive = false

    init(playerService: PlaybackPlayerService) {
        self.playerService = playerService
        isMuted = preferences.isMuted
        isCleanScreen = preferences.isCleanScreen
        ensureObserver()
        print("PLAYER_DBG [Playback] VM init muted=\(isMuted) cleanScreen=\(isCleanScreen)")
    }

    /// 滚动停稳后才调用：单播放器常驻，切集只换 item。
    /// 就绪判定为事件驱动（KVO 直挂 + 主线程判定）：status 一变立刻翻转 isReady，
    /// 无轮询量化误差；4s 看门狗兜底；取消安全（代际令牌使迟到事件失效）。
    /// completion 在加载落地（就绪/失败/超时/取消）后于主线程回调。
    func load(episode: PlayableEpisode, completion: (() -> Void)? = nil) {
        print("PLAYER_DBG [Playback] load begin sort=\(episode.sort) available=\(episode.isAvailable)")
        loadGeneration += 1
        let generation = loadGeneration
        statusWatch?.invalidate()
        statusWatch = nil
        endFastForward()
        endSeekGesture()
        hideScrubHudNow()
        loadError = nil
        isReady = false
        resetTimes()
        lastLoggedSecond = -1

        guard let playlist = episode.playlistURL else {
            print("PLAYER_DBG [Playback] load ABORT reason=episodeNotDownloaded sort=\(episode.sort)")
            playerService.clear()
            completion?()
            return
        }
        ensureObserver()

        currentKey = PlayerPreferences.key(for: playlist)
        liked = preferences.liked(for: currentKey)
        saved = preferences.saved(for: currentKey)
        print("PLAYER_DBG [Playback] load prefs key=\(currentKey) liked=\(liked) saved=\(saved)")

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
            self.player.isMuted = self.isMuted
            self.player.play()
            self.beginSpinnerDelay()
            self.watchStatus(item: item, episode: episode, generation: generation,
                             startedAt: Date(), completion: completion)
        }
    }

    func togglePlayback() {
        let wasPlaying = player.timeControlStatus == .playing
        print("PLAYER_DBG [Playback] togglePlayback wasPlaying=\(wasPlaying) → \(wasPlaying ? "pause" : "play")")
        // 点按（暂停/播放）也展示进度 HUD，3s 无其他操作后淡出（用户指定，清屏下尤其需要）。
        // 放 early return 之前，暂停/播放两条路径都触发；其他操作（seek/再点按/切集）会重置或清掉它
        showScrubHud(reason: "tap")
        scheduleScrubLinger(ms: 3000)
        if wasPlaying {
            player.pause()
            return
        }
        if let duration = player.currentItem?.duration,
           CMTimeGetSeconds(duration).isFinite,
           CMTimeGetSeconds(player.currentTime()) >= CMTimeGetSeconds(duration) - 0.2 {
            player.seek(to: .zero)
        }
        player.play()
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
        scheduleScrubLinger()
        print("PLAYER_DBG [Playback] seekGesture end")
    }

    func stop() {
        print("PLAYER_DBG [Playback] stop")
        loadGeneration += 1
        statusWatch?.invalidate()
        statusWatch = nil
        isFastForwarding = false
        endSeekGesture()
        isCleanScreenFlashActive = false
        hideScrubHudNow()
        cancelSpinnerDelay()
        playerService.clear()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        isReady = false
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
        print("PLAYER_DBG [CHECK] fastForward → 2x control=\(status.rawValue)")
    }

    func endFastForward() {
        guard isFastForwarding else { return }
        isFastForwarding = false
        // 只要不是用户主动暂停（如片尾 actionAtItemEnd），一律把目标倍速拨回 1x。
        // 此前只在 .playing 时才置回：缓冲等待态(.waitingToPlayAtSpecifiedRate)被漏掉，
        // 手松开后缓冲恢复播放仍是 2x —— 即用户反馈的「松手没有立即变回 1 倍速」。
        if player.timeControlStatus != .paused {
            player.rate = 1.0
        }
        print("PLAYER_DBG [CHECK] fastForward → 1x control=\(player.timeControlStatus.rawValue)")
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
                self.cancelSpinnerDelay()
                let waitedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                print("PLAYER_DBG [CHECK] load OK sort=\(episode.sort) ready=true waitedMs=\(waitedMs) rate=\(self.player.rate) control=\(self.player.timeControlStatus.rawValue)")
            case .failed(let message):
                self.loadError = message
                self.cancelSpinnerDelay()
                print("PLAYER_DBG [Playback] load FAIL reason=itemFailed error=\(message)")
            case .timeout:
                self.loadError = "视频加载超时"
                self.cancelSpinnerDelay()
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
        let total = CMTimeGetSeconds(player.currentItem?.duration ?? .zero)
        guard total.isFinite, total > 0 else { return }
        durationText = Self.format(total)
        progress = min(max(seconds / total, 0), 1)
        // 每 2 秒确认一次播放器确实在推进，区分「没播」和「画面没刷新」
        let second = Int(seconds)
        if second % 2 == 0, second != lastLoggedSecond {
            lastLoggedSecond = second
            print("PLAYER_DBG [CHECK] playbackTime=\(second)s rate=\(player.rate) control=\(player.timeControlStatus.rawValue)")
        }
    }

    private func resetTimes() {
        currentTimeText = "00:00"
        durationText = "00:00"
        progress = 0
    }

    private static func format(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value >= 3600 {
            return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
