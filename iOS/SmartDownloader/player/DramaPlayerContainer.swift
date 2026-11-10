import SwiftUI
import AVFoundation

// MARK: - 可播放集与播放请求

/// 磁盘上的一个已下载集。文件系统就是账本：剧目录下含 playlist.m3u8 的子目录即已下载。
struct PlayableEpisode: Identifiable, Equatable {
    let sort: Int
    let playlistURL: URL
    var id: String { playlistURL.path }
}

/// 从原生剧集页 / 剧详情页拉起沉浸式播放页所需的上下文
struct ImmersivePlaybackRequest: Identifiable {
    let id = UUID()
    let seriesName: String
    let intro: String?
    let episodes: [PlayableEpisode]
    let startIndex: Int
}

enum DramaPlaybackLibrary {
    /// 扫描某剧的全部已下载集，按集号升序（与 DownloadManager.downloadedEpisodeFolders 同一命名规则）
    static func episodes(forSeries name: String) -> [PlayableEpisode] {
        let fm = FileManager.default
        let dir = DownloadEngine.seriesDirectory(for: name)
        guard let subs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return subs.compactMap { folder -> PlayableEpisode? in
            let playlist = folder.appendingPathComponent("playlist.m3u8")
            guard fm.fileExists(atPath: playlist.path),
                  let sort = DownloadManager.episodeSort(fromFolderName: folder.lastPathComponent) else { return nil }
            return PlayableEpisode(sort: sort, playlistURL: playlist)
        }
        .sorted { $0.sort < $1.sort }
    }
}

// MARK: - 播放状态（AVPlayer + 时间观察 + 本地互动状态）

@MainActor
final class DramaPlayerViewModel: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var isReady = false
    @Published private(set) var currentTimeText = "00:00"
    @Published private(set) var durationText = "00:00"
    @Published private(set) var progress: Double = 0
    @Published private(set) var loadError: String?

    /// 点赞/收藏没有账号体系，按「集目录相对路径」存本机；静音是全局播放偏好
    @Published var isMuted = false { didSet { player.isMuted = isMuted } }
    @Published var liked = false { didSet { persist() } }
    @Published var saved = false { didSet { persist() } }

    private var timeObserver: Any?
    private var currentKey = ""

    init() {
        player.actionAtItemEnd = .pause
        ensureObserver()
    }

    /// 切集时重新取本地播放地址（LocalMediaServer 已支持剧集两级路径）
    func load(episode: PlayableEpisode) async {
        ensureObserver()
        loadError = nil
        isReady = false
        resetTimes()

        currentKey = Self.key(for: episode.playlistURL)
        liked = UserDefaults.standard.bool(forKey: "DramaPlayer.liked.\(currentKey)")
        saved = UserDefaults.standard.bool(forKey: "DramaPlayer.saved.\(currentKey)")

        let playback = await LocalMediaServer.shared.playbackURL(
            forFolder: episode.playlistURL.deletingLastPathComponent())
        guard playback.scheme == "http" else {
            loadError = "本地播放服务启动失败"
            return
        }
        let item = AVPlayerItem(url: playback)
        player.replaceCurrentItem(with: item)
        player.isMuted = isMuted
        player.play()

        // 等首帧就绪再显露视频层：加载期间保留设计稿渐变，不闪黑屏（最多等 4 秒）
        for _ in 0..<40 {
            if item.status == .readyToPlay || item.status == .failed { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if item.status == .failed {
            loadError = item.error?.localizedDescription ?? "视频加载失败"
            return
        }
        isReady = true
    }

    func togglePlayback() {
        if player.timeControlStatus == .playing {
            player.pause()
            return
        }
        // 播到结尾后再点一次，从头重播
        if let duration = player.currentItem?.duration,
           CMTimeGetSeconds(duration).isFinite,
           CMTimeGetSeconds(player.currentTime()) >= CMTimeGetSeconds(duration) - 0.2 {
            player.seek(to: .zero)
        }
        player.play()
    }

    /// 进度条拖动/点击：按总时长的比例 seek
    func seek(fraction: Double) {
        guard let item = player.currentItem else { return }
        let total = CMTimeGetSeconds(item.duration)
        guard total.isFinite, total > 0 else { return }
        let ratio = min(max(fraction, 0), 1)
        let target = CMTime(seconds: total * ratio, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        syncTime(target)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        isReady = false
    }

    // MARK: 私有

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
    }

    private func resetTimes() {
        currentTimeText = "00:00"
        durationText = "00:00"
        progress = 0
    }

    private func persist() {
        guard !currentKey.isEmpty else { return }
        UserDefaults.standard.set(liked, forKey: "DramaPlayer.liked.\(currentKey)")
        UserDefaults.standard.set(saved, forKey: "DramaPlayer.saved.\(currentKey)")
    }

    /// 用相对 Downloads 的集目录路径做 key，避免不同剧的「第01集」互相串状态
    private static func key(for url: URL) -> String {
        let root = DownloadEngine.downloadsDir.standardizedFileURL.path
        let folder = url.deletingLastPathComponent().standardizedFileURL.path
        return folder.hasPrefix(root) ? String(folder.dropFirst(root.count)) : folder
    }

    private static func format(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value >= 3600 {
            return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

// MARK: - AVPlayerLayer 承载视图

struct PlayerSurfaceView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerSurfaceUIView {
        let view = PlayerSurfaceUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false   // 触摸交给 SwiftUI 层
        return view
    }

    func updateUIView(_ uiView: PlayerSurfaceUIView, context: Context) {
        guard uiView.playerLayer.player !== player else { return }
        uiView.playerLayer.player = player
    }
}

final class PlayerSurfaceUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

// MARK: - 沉浸式播放容器（fullScreenCover 内容）

/// 负责切集、把本地 HLS 交给 ViewModel、把设计稿视图挂到真实数据上。
/// 散装单集没有「上下滑切集」语义，仍走 DownloadsView 的 AVKit PlayerView。
struct DramaPlayerContainer: View {
    let request: ImmersivePlaybackRequest
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = DramaPlayerViewModel()
    @State private var index: Int
    @State private var dragY: CGFloat = 0

    init(request: ImmersivePlaybackRequest) {
        self.request = request
        let last = max(0, request.episodes.count - 1)
        _index = State(initialValue: min(max(0, request.startIndex), last))
    }

    private var current: PlayableEpisode? {
        guard request.episodes.indices.contains(index) else { return nil }
        return request.episodes[index]
    }

    var body: some View {
        Group {
            if let current {
                DramaPlayerView(
                    episode: .local(seriesName: request.seriesName,
                                    intro: request.intro,
                                    index: current.sort,
                                    total: request.episodes.count),
                    vm: vm,
                    onClose: { dismiss() },
                    hasNextEpisode: index < request.episodes.count - 1
                )
                .offset(y: dragY)
                .gesture(swipeGesture)
                .task(id: current.id) {
                    await vm.load(episode: current)
                }
            } else {
                ZStack {
                    DWColor.background.ignoresSafeArea()
                    VStack(spacing: 12) {
                        Image(systemName: "film")
                            .font(.largeTitle)
                            .foregroundStyle(DWColor.textHint)
                        Text("没有可播放的已下载集")
                            .font(DWFont.cn(13))
                            .foregroundStyle(DWColor.textBody)
                        Button("返回") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .onDisappear { vm.stop() }
    }

    /// 只响应纵向主导的拖动；横向留给进度条 seek
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragY = value.translation.height * 0.35
            }
            .onEnded { value in
                let dy = value.translation.height
                let dx = value.translation.width
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragY = 0 }
                guard abs(dy) > abs(dx), abs(dy) > 60 else { return }
                if dy < 0, index < request.episodes.count - 1 { index += 1 }
                if dy > 0, index > 0 { index -= 1 }
            }
    }
}
