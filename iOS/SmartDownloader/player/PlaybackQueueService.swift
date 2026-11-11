import Foundation

// MARK: - 播放资源槽位与拉起请求

/// 上下滑动播放的一个资源槽位。playlistURL 为 nil 表示该集真实存在但尚未下载。
struct PlayableEpisode: Identifiable, Equatable {
    let sort: Int
    let playlistURL: URL?
    var id: String { "\(sort)" }
    var isAvailable: Bool { playlistURL != nil }
}

/// 拉起沉浸式播放页的请求。
/// knownSorts = 调用方已经掌握的全剧集号（剧集页直接持有 info.episodes）；
/// 为空时由 service 反查本地缓存，再退化为「真实已下载的集」。全程不凭空造集号。
struct ImmersivePlaybackRequest: Identifiable {
    let id = UUID()
    let seriesName: String
    let intro: String?
    let startSort: Int
    var knownSorts: [Int] = []
}

// MARK: - 上下滑动资源调度服务

/// 播放页上下滑动的唯一资源调度方，职责：
/// 1. 同步整部剧集数并构建候选槽位（只使用已知的真实集号）
/// 2. 维护当前位置与下滑回溯栈
/// 3. 决定「上滑播什么 / 下滑回到哪里」
///
/// 值类型：容器用 @State 持有，move() 触发视图更新；不持有 AVPlayer，播放交给 DramaPlayerViewModel。
struct PlaybackQueueService {
    enum Direction {
        case next       // 上滑：下一集 / 推荐的下一个资源
        case previous   // 下滑：回到上一个
    }

    let seriesName: String
    let intro: String?

    /// 候选池：按全剧集号升序；只有已知真实存在的集才会出现在这里。
    /// 推荐算法可以从这里挑任意槽位，不必受集号顺序约束。
    private(set) var slots: [PlayableEpisode] = []
    private(set) var current: PlayableEpisode?
    /// 观看历史：推荐算法不按集号顺序时，「下滑」应回到来时的那个，而不是简单 sort-1
    private(set) var history: [PlayableEpisode] = []

    /// 全剧集数，集数标签用，不随推荐顺序变化
    var totalEpisodes: Int { slots.count }
    var hasNext: Bool { nextSlot != nil }
    /// 下一集是否已下载：让底部提示如实告诉用户滑过去能看到什么
    var nextIsAvailable: Bool { nextSlot?.isAvailable ?? false }
    var hasPrevious: Bool {
        !history.isEmpty || current.flatMap { resolvePrevious(from: $0, in: slots) } != nil
    }

    private var nextSlot: PlayableEpisode? {
        current.flatMap { resolveNext(from: $0, in: slots) }
    }

    init(request: ImmersivePlaybackRequest) {
        self.seriesName = request.seriesName
        self.intro = request.intro
        slots = Self.buildSlots(forSeries: request.seriesName, knownSorts: request.knownSorts)
        current = slots.first { $0.sort == request.startSort }
            ?? slots.first { $0.isAvailable }
            ?? slots.first
    }

    /// 上滑 / 下滑的唯一入口。返回是否真的切到了另一个资源；
    /// false = 已到边界（没有更多真实资源），上层据此弹 toast，不静默无响应、也不造槽位。
    @discardableResult
    mutating func move(_ direction: Direction) -> Bool {
        guard let from = current else { return false }
        switch direction {
        case .next:
            guard let target = resolveNext(from: from, in: slots) else { return false }
            history.append(from)
            current = target
            return true
        case .previous:
            if let last = history.popLast() {
                current = last
                return true
            } else if let target = resolvePrevious(from: from, in: slots) {
                current = target
                return true
            }
            return false
        }
    }

    // MARK: - 本地推荐算法接入点 -------------------------------------
    // 当前策略 = 按集号顺序。后续接本地推荐算法只需替换这两个方法：
    // 可读取 slots（全剧候选池）、history（观看历史）、current，
    // 返回任意目标槽位即可改变滑动顺序；容器、播放视图、ViewModel 都无需改动。
    // 返回 nil 表示已到边界，上层弹「已经到底了」toast。
    // 【低优先级待办，本次不做】有全剧集数但只下载 1 集时，上滑仍会切到「尚未下载」的占位页。

    func resolveNext(from: PlayableEpisode, in slots: [PlayableEpisode]) -> PlayableEpisode? {
        slots.first { $0.sort > from.sort }
    }

    func resolvePrevious(from: PlayableEpisode, in slots: [PlayableEpisode]) -> PlayableEpisode? {
        slots.last { $0.sort < from.sort }
    }

    // MARK: - 候选池构建（离线，不联网，不编造集号）

    /// 集号来源优先级：调用方已知的全剧集数 → 本地 SQLite 缓存反查 → 真实已下载的集。
    /// 没有剧集元数据时，我们并不知道这部剧有没有下一集，因此只列真实已下载的集；
    /// 此时只有 1 集就不能滑，如实提示「已是最后一集」，绝不造一个空槽位凑数。
    private static func allSorts(forSeries name: String, known: [Int], downloaded: [Int]) -> [Int] {
        if !known.isEmpty { return known.sorted() }
        let cached = DramaCache.allSorts(forSeriesName: name)
        guard cached.isEmpty else { return cached }
        return downloaded.sorted()
    }

    /// 文件系统是「是否已下载」的账本，集号来自调用方 / DramaCache。
    private static func buildSlots(forSeries name: String, knownSorts: [Int]) -> [PlayableEpisode] {
        let fm = FileManager.default
        let dir = DownloadEngine.seriesDirectory(for: name)
        let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var downloaded: [Int: URL] = [:]
        for folder in subs {
            let playlist = folder.appendingPathComponent("playlist.m3u8")
            guard fm.fileExists(atPath: playlist.path),
                  let sort = DownloadManager.episodeSort(fromFolderName: folder.lastPathComponent) else { continue }
            downloaded[sort] = playlist
        }
        let sorts = allSorts(forSeries: name, known: knownSorts, downloaded: Array(downloaded.keys))
        return sorts
            .map { PlayableEpisode(sort: $0, playlistURL: downloaded[$0]) }
            .sorted { $0.sort < $1.sort }
    }
}
