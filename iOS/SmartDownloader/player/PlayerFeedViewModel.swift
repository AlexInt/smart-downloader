import SwiftUI
import Combine

/// 分页播放页 ViewModel：列表数据源、当前页、边界 toast、停稳后切换播放源。
/// 不含 UIKit / AVFoundation 对象；资源调度委托 PlaybackQueueService。
@MainActor
final class PlayerFeedViewModel: ObservableObject {
    @Published private(set) var slots: [PlayableEpisode] = []
    /// 与系统分页的 scrollPosition 双向绑定
    @Published var currentSort: Int?
    @Published private(set) var toastText: String?
    /// 当前页播放是否已就绪：驱动容器刷新卡片 rootView，让视频层显露出来
    @Published private(set) var playbackReady = false

    let playback: DramaPlayerViewModel
    private let playerService = PlaybackPlayerService()
    private var queue: PlaybackQueueService?
    private var toastID = 0
    private var configured = false
    private var endToastShown = false

    init() {
        playback = DramaPlayerViewModel(playerService: playerService)
    }

    var seriesName: String { queue?.seriesName ?? "" }
    var intro: String? { queue?.intro }
    var totalEpisodes: Int { slots.count }

    func configure(request: ImmersivePlaybackRequest) {
        guard !configured else {
            print("PLAYER_DBG [VM] configure SKIP reason=alreadyConfigured series=\(request.seriesName)")
            return
        }
        configured = true
        let q = PlaybackQueueService(request: request)
        queue = q
        slots = q.slots
        currentSort = q.current?.sort
        print("PLAYER_DBG [VM] configure series=\(request.seriesName) startSort=\(request.startSort) knownSorts=\(request.knownSorts.count) → slots=\(slots.count) sorts=\(slots.map(\.sort)) current=\(currentSort.map(String.init) ?? "nil")")
    }

    /// 滚动停稳后（由 .task(id:) 防抖调用）才切换播放源，避免快滑反复 replaceCurrentItem
    func pageSettled(sort: Int) async {
        print("PLAYER_DBG [VM] pageSettled begin sort=\(sort)")
        guard let slot = slots.first(where: { $0.sort == sort }) else {
            print("PLAYER_DBG [VM] pageSettled NO SLOT sort=\(sort)")
            return
        }
        queue?.select(sort: sort)
        // 先置 false 让卡片回到加载态，load 完成后再置 true 触发一次刷新显露视频层
        playbackReady = false
        await playback.load(episode: slot)
        playbackReady = playback.isReady
        print("PLAYER_DBG [CHECK] pageSettled done sort=\(sort) isLast=\(isLast(sort)) slots=\(slots.count) current=\(currentSort.map(String.init) ?? "nil") ready=\(playbackReady)")
        if isLast(sort), !endToastShown {
            endToastShown = true
            showToast("已经到底了")
        }
    }

    func hasNext(after sort: Int) -> Bool {
        guard let i = slots.firstIndex(where: { $0.sort == sort }) else { return false }
        return i + 1 < slots.count
    }

    func nextIsAvailable(after sort: Int) -> Bool {
        guard let i = slots.firstIndex(where: { $0.sort == sort }),
              i + 1 < slots.count else { return false }
        return slots[i + 1].isAvailable
    }

    func isFirst(_ sort: Int) -> Bool { slots.first?.sort == sort }
    func isLast(_ sort: Int) -> Bool { slots.last?.sort == sort }

    func showToast(_ text: String) {
        toastID += 1
        let id = toastID
        toastText = text
        print("PLAYER_DBG [VM] showToast id=\(id) text=\(text) current=\(currentSort.map(String.init) ?? "nil")")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toastID == id {
                toastText = nil
                print("PLAYER_DBG [VM] showToast dismiss id=\(id)")
            }
        }
    }

    func stop() {
        print("PLAYER_DBG [VM] stop current=\(currentSort.map(String.init) ?? "nil") slots=\(slots.count)")
        playback.stop()
        playerService.clear()
    }
}
