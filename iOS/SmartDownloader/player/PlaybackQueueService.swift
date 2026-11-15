import Foundation

// MARK: - 上下滑动资源调度服务
// 数据类型见 PlaybackModels.swift；本文件只放调度逻辑（单一职责）。

/// 播放页上下滑动的唯一资源调度方，职责：
/// 1. 同步整部剧集数并构建候选槽位（只使用已知的真实集号）
/// 2. 维护当前位置与下滑回溯栈
/// 3. 决定「上滑播什么 / 下滑回到哪里」
///
/// 值类型：容器用 @State 持有，move() 触发视图更新；不持有 AVPlayer，播放交给 DramaPlayerViewModel。
struct PlaybackQueueService {
    let seriesName: String
    let intro: String?
    /// 话题标签（随请求透传给卡片；下载页入口为 nil）
    let tags: String?

    /// 候选池：按全剧集号升序；只有已知真实存在的集才会出现在这里。
    /// 推荐算法可以从这里挑任意槽位，不必受集号顺序约束。
    private(set) var slots: [PlayableEpisode] = []
    /// 本剧一共多少集（详情接口 episode_count / 已缓存最大集号 / 磁盘最大集号取大者）。
    /// 面板要把「没下的集」也列出来，「一共多少集」必须来自剧集元数据，不能只看磁盘。
    private(set) var totalEpisodeCount: Int = 0
    private(set) var current: PlayableEpisode?
    /// 观看历史：推荐算法不按集号顺序时，「下滑」应回到来时的那个，而不是简单 sort-1
    private(set) var history: [PlayableEpisode] = []

    /// 全剧集数，集数标签用，不随推荐顺序变化。
    /// **不直接用 `slots.count`**：站点集号跳号（广告集被剔除等）时槽位会少于
    /// 「本剧一共多少集」，而「选集 · 全 N 集」说的是后者。
    var totalEpisodes: Int { totalEpisodeCount > 0 ? totalEpisodeCount : slots.count }
    var hasNext: Bool { nextSlot != nil }
    /// 下一集是否已下载：让底部提示如实告诉用户滑过去能看到什么
    var nextIsAvailable: Bool { nextSlot?.isAvailable ?? false }
    var hasPrevious: Bool {
        !history.isEmpty || current.flatMap { resolvePrevious(from: $0, in: slots) } != nil
    }

    private var nextSlot: PlayableEpisode? {
        current.flatMap { resolveNext(from: $0, in: slots) }
    }

    /// 全剧集号与站点身份：开播时快照保留，供 refreshAvailability 重跑同一套槽位构建
    private let knownSorts: [Int]
    private let target: DramaTarget?

    init(request: ImmersivePlaybackRequest) {
        self.seriesName = request.seriesName
        self.intro = request.intro
        self.tags = request.tags
        self.knownSorts = request.knownSorts
        self.target = request.target
        let built = Self.buildSlots(forSeries: request.seriesName,
                                    knownSorts: request.knownSorts,
                                    target: request.target)
        slots = built.slots
        totalEpisodeCount = built.total
        current = slots.first { $0.sort == request.startSort }
            ?? slots.first { $0.isAvailable }
            ?? slots.first
    }

    /// 下载完成等磁盘变化后的可用性对账：重扫已下载目录，按集号对位更新槽位的
    /// playlistURL / identity。开播时的快照会让「播放中下完的集」滑过去仍停在
    /// 「尚未下载」占位（真机实证），本方法在每次停稳时由 VM 调用。
    /// 只在内容有变化时返回 true（无变化 = 一次目录列举的成本，不触发 UI 刷新）。
    @discardableResult
    mutating func refreshAvailability() -> Bool {
        let fresh = Self.buildSlots(forSeries: seriesName, knownSorts: knownSorts, target: target)
        var oldBySort: [Int: PlayableEpisode] = [:]
        for slot in slots { oldBySort[slot.sort] = slot }
        var changed = fresh.total != totalEpisodeCount
        var merged: [PlayableEpisode] = []
        for slot in fresh.slots {
            merged.append(slot)
            if let old = oldBySort[slot.sort] {
                if old.playlistURL != slot.playlistURL { changed = true }
            } else {
                changed = true   // 开播后才出现的新集号（只有已下载集入口的槽位）
            }
        }
        guard changed else { return false }
        slots = merged
        totalEpisodeCount = fresh.total
        // current / history 是值拷贝，按集号重新对位到新槽位（观看历史不丢）
        if let sort = current?.sort { current = slots.first { $0.sort == sort } ?? current }
        history = history.map { h in slots.first { $0.sort == h.sort } ?? h }
        print("PLAYER_DBG [CHECK] queueRefresh series=\(seriesName) available=\(slots.filter { $0.isAvailable }.map { $0.sort })")
        return true
    }

    /// 上滑 / 下滑的唯一入口。返回是否真的切到了另一个资源；
    /// false = 已到边界（没有更多真实资源），上层据此弹 toast，不静默无响应、也不造槽位。
    @discardableResult
    mutating func move(_ direction: PlaybackDirection) -> Bool {
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

    /// 分页模式下按可见页同步当前位置（保留观看历史，供后续推荐算法读取）。
    /// 与 move() 的区别：不产生新的滑动目标，只是告知 service 用户停在了哪一集。
    mutating func select(sort: Int) {
        guard let target = slots.first(where: { $0.sort == sort }),
              current?.sort != sort else { return }
        if let current { history.append(current) }
        if history.count > 50 { history.removeFirst() }
        current = target
    }

    /// 调度顺序上与某集相邻的槽位（上一位 + 下一位），供相邻集预热使用。
    /// 刻意走 resolveNext / resolvePrevious：推荐算法换序后预热目标自动跟随，无需另改。
    /// 是否已下载由调用方过滤（预热 Service 只预热 isAvailable 的集）。
    func neighbors(of sort: Int) -> [PlayableEpisode] {
        guard let current = slots.first(where: { $0.sort == sort }) else { return [] }
        var result: [PlayableEpisode] = []
        if let prev = resolvePrevious(from: current, in: slots) { result.append(prev) }
        if let next = resolveNext(from: current, in: slots) { result.append(next) }
        return result
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

    /// 行为数据身份：target 直达优先，没有才按剧名反查（同名多剧会有歧义日志）
    private static func resolveIdentity(name: String, target: DramaTarget?) -> DramaCache.SeriesIdentity? {
        if let target, let byTarget = DramaCache.seriesIdentity(site: target.site, dramaID: target.dramaID) {
            return byTarget
        }
        return DramaCache.seriesIdentity(forSeriesName: name)
    }

    // MARK: - 候选池构建（离线，不联网，不编造集号）

    /// 一次构建的产物：槽位 + 本剧总集数（两者都来自同一份集号推导，避免口径漂移）
    private struct SlotBuild {
        var slots: [PlayableEpisode]
        var total: Int
    }

    /// 集号来源：调用方已知的全剧集数 ∪ 本地 SQLite 缓存的每集记录 ∪ 真实已下载集，
    /// 再按「本剧总集数」把中间缺失的集号补齐。
    ///
    /// 为什么要补齐（用户实报 2026-11-15）：某剧 11 集只下了第 7~11 集，面板就只剩
    /// 5 格、1~6 整段消失，用户根本点不到「没下的集」。根因是只把「已知 + 缓存 + 磁盘」
    /// 取并集——三个来源都不含 1~6 时就没有任何一格。总集数只能从剧集元数据拿：
    /// 详情接口的 `episode_count`（下载页入口唯一可离线得知的总集数）/ 已缓存最大集号 /
    /// 磁盘最大集号，取最大者作为上界，`1…上界` 里没有槽位的集号全部补成「未下载」。
    /// 站点未开放的集补出来也无害：点它会走「站点未开放」提示，比从面板上消失好。
    private static func allSorts(forSeries name: String, known: [Int], downloaded: [Int]) -> [Int] {
        let cached = DramaCache.allSorts(forSeriesName: name)
        let declared = DramaCache.episodeTotal(forSeriesName: name) ?? 0
        var set = Set(known)
        set.formUnion(cached)
        set.formUnion(downloaded)
        let upper = max(declared, set.max() ?? 0)
        let before = set.count
        if upper > 0 {
            for sort in 1...upper where !set.contains(sort) { set.insert(sort) }
        }
        let merged = set.sorted()
        print("PLAYER_DBG [Service] allSorts series=\(name) known=\(known.count) "
              + "cached=\(cached.count) disk=\(downloaded.count) declaredTotal=\(declared) "
              + "upper=\(upper) padded=\(merged.count - before) merged=\(merged.count) "
              + "head=\(Array(merged.prefix(12)))")
        return merged
    }

    /// 文件系统是「是否已下载」的账本，集号来自调用方 / DramaCache（不足时按总集数补齐）。
    /// 行为数据身份（进度/点赞/收藏）在这里一次算清：剧集页入口带 target 直达 (site, drama_id)，
    /// 下载页入口只有剧名则按名反查；集号查不到服务端 id 的（散装、缓存缺失）退化成本地路径，
    /// 宁可退回路径键也不猜一个 id 把数据挂到别的集上。
    private static func buildSlots(forSeries name: String, knownSorts: [Int], target: DramaTarget?) -> SlotBuild {
        let fm = FileManager.default
        let dir = DownloadEngine.seriesDirectory(for: name)
        let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var downloaded: [Int: URL] = [:]
        var unparsedFolders: [String] = []
        for folder in subs {
            let playlist = folder.appendingPathComponent("playlist.m3u8")
            guard fm.fileExists(atPath: playlist.path) else { continue }
            guard let sort = DownloadManager.episodeSort(fromFolderName: folder.lastPathComponent) else {
                unparsedFolders.append(folder.lastPathComponent)
                continue
            }
            downloaded[sort] = playlist
        }
        let sorts = allSorts(forSeries: name, known: knownSorts, downloaded: Array(downloaded.keys))
        let available = sorts.filter { downloaded[$0] != nil }
        let series = resolveIdentity(name: name, target: target)
        let idsBySort = series?.episodeIDsBySort ?? [:]
        print("PLAYER_DBG [Service] buildSlots series=\(name) dir=\(dir.lastPathComponent) "
              + "slots=\(sorts.count) available=\(available) "
              + "diskFolders=\(Array(downloaded.keys).sorted()) unparsed=\(unparsedFolders.prefix(5)) "
              + "identity=\(series.map { "\($0.site)#\($0.dramaID)" } ?? "nil") idMatched=\(idsBySort.count)")
        let slots = sorts
            .map { sort in
                let playlist = downloaded[sort]
                return PlayableEpisode(sort: sort, playlistURL: playlist,
                                       identity: EpisodeActionsStore.identity(series: series, sort: sort,
                                                                              playlistURL: playlist))
            }
            .sorted { $0.sort < $1.sort }
        // 总集数 = 集号上界与槽位数取大者（集号从 0 起或跳号时以格数为准）
        return SlotBuild(slots: slots, total: max(sorts.last ?? 0, slots.count))
    }
}
