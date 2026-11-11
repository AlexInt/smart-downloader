import SwiftUI
import AVFoundation
import Combine

/// 单集播放状态机（ViewModel）。
/// 只暴露可绑定状态与播放意图；播放器实例归 PlaybackPlayerService，偏好归 PlayerPreferences。
@MainActor
final class DramaPlayerViewModel: ObservableObject {
    private let playerService: PlaybackPlayerService
    var player: AVPlayer { playerService.player }

    @Published private(set) var isReady = false
    @Published private(set) var isFastForwarding = false
    /// seek 手势进行中（seekPan 的 .changed 已在寻址）：「拖动先起」的触摸由 seek 独占，
    /// 长按不得中途插入起 2x —— 与 isFastForwarding 构成双向互斥（谁先起谁独占本次触摸）。
    /// 非渲染状态，故意不用 @Published（避免每次 seek 触发无意义的视图刷新）
    private(set) var isSeekGestureActive = false
    @Published private(set) var currentTimeText = "00:00"
    @Published private(set) var durationText = "00:00"
    @Published private(set) var progress: Double = 0
    @Published private(set) var loadError: String?
    /// spinner 延迟显示：加载超过 300ms 仍未就绪才置 true，预热命中的秒开路径全程无转圈
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
    private var spinnerDelayTask: Task<Void, Never>?

    init(playerService: PlaybackPlayerService) {
        self.playerService = playerService
        isMuted = preferences.isMuted
        isCleanScreen = preferences.isCleanScreen
        ensureObserver()
        print("PLAYER_DBG [Playback] VM init muted=\(isMuted) cleanScreen=\(isCleanScreen)")
    }

    /// 滚动停稳后才调用：单播放器常驻，切集只换 item。
    /// 就绪判定为事件驱动（KVO → AsyncStream）：status 一变立刻翻转 isReady，
    /// 无轮询量化误差；4s 看门狗兜底；取消安全（新滑动终止等待并清理观察器）。
    func load(episode: PlayableEpisode) async {
        print("PLAYER_DBG [Playback] load begin sort=\(episode.sort) available=\(episode.isAvailable)")
        endFastForward()
        endSeekGesture()
        loadError = nil
        isReady = false
        resetTimes()
        lastLoggedSecond = -1

        guard let playlist = episode.playlistURL else {
            print("PLAYER_DBG [Playback] load ABORT reason=episodeNotDownloaded sort=\(episode.sort)")
            playerService.clear()
            return
        }
        ensureObserver()

        currentKey = PlayerPreferences.key(for: playlist)
        liked = preferences.liked(for: currentKey)
        saved = preferences.saved(for: currentKey)
        print("PLAYER_DBG [Playback] load prefs key=\(currentKey) liked=\(liked) saved=\(saved)")

        guard let item = await playerService.makeItem(for: episode) else {
            loadError = "本地播放服务启动失败"
            print("PLAYER_DBG [Playback] load FAIL reason=makeItemNil error=\(loadError ?? "")")
            return
        }
        player.replaceCurrentItem(with: item)
        player.isMuted = isMuted
        player.play()
        beginSpinnerDelay()

        let startedAt = ContinuousClock.now
        for await event in Self.statusEvents(for: item, timeout: .seconds(4)) {
            switch event {
            case .ready:
                guard item === player.currentItem else {
                    print("PLAYER_DBG [Playback] status STALE reason=replacedItem sort=\(episode.sort)")
                    return
                }
                isReady = true
                cancelSpinnerDelay()
                // components.seconds 只有整秒，亚秒部分在 attoseconds 里（此前 <1s 全打成 0ms）
                let waited = startedAt.duration(to: .now)
                let waitedMs = Int(waited.components.seconds) * 1000
                    + Int(waited.components.attoseconds / 1_000_000_000_000_000)
                print("PLAYER_DBG [CHECK] load OK sort=\(episode.sort) ready=true waitedMs=\(waitedMs) rate=\(player.rate) control=\(player.timeControlStatus.rawValue)")
                return
            case .failed(let message):
                guard item === player.currentItem else { return }
                loadError = message
                cancelSpinnerDelay()
                print("PLAYER_DBG [Playback] load FAIL reason=itemFailed error=\(message)")
                return
            case .timeout:
                guard item === player.currentItem else { return }
                loadError = "视频加载超时"
                cancelSpinnerDelay()
                print("PLAYER_DBG [Playback] load FAIL reason=watchdogTimeout sort=\(episode.sort)")
                return
            }
        }
        // 走到这里 = 等待被取消（新滑动 / 退出播放页），不翻转任何状态
        print("PLAYER_DBG [Playback] load CANCELLED sort=\(episode.sort)")
    }

    func togglePlayback() {
        let wasPlaying = player.timeControlStatus == .playing
        print("PLAYER_DBG [Playback] togglePlayback wasPlaying=\(wasPlaying) → \(wasPlaying ? "pause" : "play")")
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
        let target = CMTime(seconds: total * ratio, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        syncTime(target)
    }

    /// seekPan 抬手 / 被系统滚动抢占：结束「拖动独占」标记，下一次长按可正常起 2x
    func endSeekGesture() {
        guard isSeekGestureActive else { return }
        isSeekGestureActive = false
        print("PLAYER_DBG [Playback] seekGesture end")
    }

    func stop() {
        print("PLAYER_DBG [Playback] stop")
        isFastForwarding = false
        endSeekGesture()
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

    /// AVPlayerItem.status 的事件流：KVO 即时推送（无轮询量化误差）。
    /// `.initial` 选项让「观察开始前就已 ready」（预热命中）也能立刻收到事件；
    /// 流终止（取消 / return）时自动清理 KVO 观察器与看门狗任务。
    private static func statusEvents(for item: AVPlayerItem, timeout: Duration) -> AsyncStream<StatusEvent> {
        AsyncStream { continuation in
            let observer = item.observe(\.status, options: [.initial, .new]) { item, _ in
                switch item.status {
                case .readyToPlay:
                    continuation.yield(.ready)
                case .failed:
                    continuation.yield(.failed(item.error?.localizedDescription ?? "视频加载失败"))
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                continuation.yield(.timeout)
            }
            continuation.onTermination = { _ in
                observer.invalidate()
                watchdog.cancel()
            }
        }
    }

    /// spinner 延迟显示：300ms 内就绪的加载完全不出现转圈（预热命中的常态）；
    /// 超过 300ms 仍未就绪才置 isLoadingSlow，让卡片显示 spinner。
    private func beginSpinnerDelay() {
        spinnerDelayTask?.cancel()
        isLoadingSlow = false
        spinnerDelayTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            if !self.isReady, self.loadError == nil {
                self.isLoadingSlow = true
                print("PLAYER_DBG [Playback] spinner show reason=notReadyAfter300ms")
            }
        }
    }

    private func cancelSpinnerDelay() {
        spinnerDelayTask?.cancel()
        spinnerDelayTask = nil
        isLoadingSlow = false
    }

    private func ensureObserver() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main,
            using: { [weak self] time in
                MainActor.assumeIsolated { self?.syncTime(time) }
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
