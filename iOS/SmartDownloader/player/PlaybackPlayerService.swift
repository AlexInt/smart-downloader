import AVFoundation

/// 播放器生命周期 Service：持有唯一常驻的 AVPlayer，负责 item 准备与释放。
/// 依据 ZFPlayer / 开源抖音实践：切集只换 item，绝不在滑动时新建 AVPlayer。
@MainActor
final class PlaybackPlayerService {
    let player = AVPlayer()

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
    }

    /// 本地 HLS 回环地址 → AVPlayerItem；未下载或本地服务未启动时返回 nil
    func makeItem(for episode: PlayableEpisode) async -> AVPlayerItem? {
        guard let playlist = episode.playlistURL else {
            print("PLAYER_DBG [Service] makeItem FAIL reason=noLocalPlaylist sort=\(episode.sort)")
            return nil
        }
        let url = await LocalMediaServer.shared.playbackURL(
            forFolder: playlist.deletingLastPathComponent())
        guard url.scheme == "http" else {
            print("PLAYER_DBG [Service] makeItem FAIL reason=localServerNotReady sort=\(episode.sort) url=\(url.absoluteString)")
            return nil
        }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        print("PLAYER_DBG [Service] makeItem OK sort=\(episode.sort) url=\(url.absoluteString)")
        return item
    }

    func clear() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
