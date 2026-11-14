import AVFoundation

/// 播放进度跟踪（Service 能力）：给任意 AVPlayer 装上「记住位置 + 下次续播」。
/// 沉浸式播放页（DramaPlayerViewModel）与下载页 AVKit 播放（PlayerView）共用同一套规则，
/// 避免两处漂移让「列表显示的位置」与「实际续播位置」不一致。
///
/// 写入策略 = 内存攒 + 关键时机落库：1Hz 时间回调只更新内存值，真正写 SQLite 发生在
/// flush（暂停 / 拖完 seek / 切集 / 退出播放页 / 进后台）。SQLite 这边沿用开-用-关连接，
/// 每 5 秒一次会把库写成噪音；代价是异常崩溃最多丢最后一段没 flush 的位置。
/// 数据落在 `EpisodeActionsStore`（episode_actions / local_actions），归属由 `MediaIdentity` 决定。
/// 不 import SwiftUI、不持有视图；一个实例只管一个资源。
/// 主线程约定：attach / resumeIfNeeded / flush / detach 只在主线程调用。
final class PlaybackProgressTracker {
    let identity: MediaIdentity
    /// 续播真正发生时回调（播放页用它闪现进度 HUD），需在 attach 之前设好
    var onResumed: ((PlaybackProgress) -> Void)?
    /// 内存里的最新位置，flush 前不落库
    private(set) var pending: PlaybackProgress?

    private weak var player: AVPlayer?
    private var timeObserver: Any?
    /// 本次是否已处理过续播（时长未就绪时留待下一个有效 tick 再判）
    private var resumeHandled = false

    init(identity: MediaIdentity) {
        self.identity = identity
    }

    deinit {
        flush()
    }

    /// 挂上时间回调（重复调用只装一次）
    func attach(to player: AVPlayer) {
        self.player = player
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.tick(time)
        }
    }

    /// item 就绪后尽早调用：有历史位置就 seek 过去。时长还没拿到时不硬判，
    /// 交给第一个有效 tick 再试（本地 HLS 的 duration 常在 ready 之后才稳定）。
    @discardableResult
    func resumeIfNeeded() -> Bool {
        guard !resumeHandled, let player else { return false }
        let saved = EpisodeActionsStore.actions(for: identity).position
        guard let value = saved, value.seconds > 3, !value.isFinished else {
            resumeHandled = true
            return false
        }
        let total = duration(player)
        guard total > 0 else { return false }
        resumeHandled = true
        // 时长变短（重新下载/换源）或已接近片尾：从头播，不跳到一个错位置
        guard value.seconds < total - 5 else {
            print("PLAYER_DBG [Playback] resume SKIP reason=nearEnd at=\(Int(value.seconds)) total=\(Int(total)) id=\(identity.label)")
            return false
        }
        player.seek(to: CMTime(seconds: value.seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        pending = PlaybackProgress(seconds: value.seconds, total: total)
        print("PLAYER_DBG [CHECK] resume at=\(Int(value.seconds))s total=\(Int(total))s id=\(identity.label)")
        onResumed?(value)
        return true
    }

    /// 关键时机落库：暂停 / 拖完 seek / 进后台。值与上次落库相同就不写库（避免空转）
    func flush() {
        guard let value = current() else { return }
        if let old = pending, abs(old.seconds - value.seconds) >= 0.5 {
            print("PLAYER_DBG [Playback] flush pending(\(Int(old.seconds))s) → 现读(\(Int(value.seconds))s) 同步落库")
        }
        // 现读值回写内存：deinit 时 player 已被 detach 置 nil、只能退 pending，
        // 不同步会把 deinit 的兜底 flush 拉回旧值（seek 后 1 秒内暂停+退出的窄窗口）
        pending = value
        if let lastFlushed, abs(lastFlushed.seconds - value.seconds) < 0.5 { return }
        EpisodeActionsStore.savePosition(seconds: value.seconds, total: value.total, for: identity)
        lastFlushed = value
    }

    /// 摘掉时间回调并落库最后一次位置：切集 / 退出播放页 / 播放视图销毁
    func detach() {
        flush()
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player = nil
    }

    // MARK: 私有

    private var lastFlushed: PlaybackProgress?

    private func tick(_ time: CMTime) {
        guard let player else { return }
        // ready 早于 duration 就绪的场景在这里补一次续播判定（只做一次）
        if !resumeHandled { _ = resumeIfNeeded() }
        let value = CMTimeGetSeconds(time)
        let total = duration(player)
        guard value.isFinite, value >= 0, total > 0 else { return }
        pending = PlaybackProgress(seconds: value, total: total)
    }

    /// 当前可落库的位置：优先现读播放器——pending 只由 1Hz tick 更新，拖完 seek 立即
    /// flush 时它还是拖动前的旧值（2026-11-14 真机实证：拖到 324s 却落库 s=0，覆盖了
    /// 上次的 423/423 完播记录）；player 不可用（detach 后 deinit）或现读无效时退回内存值
    private func current() -> PlaybackProgress? {
        guard let player else { return pending }
        let value = CMTimeGetSeconds(player.currentTime())
        let total = duration(player)
        guard value.isFinite, value >= 0, total > 0 else { return pending }
        return PlaybackProgress(seconds: value, total: total)
    }

    private func duration(_ player: AVPlayer) -> Double {
        let total = CMTimeGetSeconds(player.currentItem?.duration ?? .zero)
        return total.isFinite ? total : 0
    }
}
