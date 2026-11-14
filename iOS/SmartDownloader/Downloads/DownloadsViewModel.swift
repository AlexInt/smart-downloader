import Foundation
import Combine

/// 下载页 ViewModel（架构评估 P10 拆分）：
/// 编辑模式/勾选/批量删除编排与「下载中/已下载」两个区域的派生列表都在这里，
/// DownloadsView 只渲染 + 转发意图。排序偏好持久化由本 VM 接管
///（UserDefaults "DownloadsView.sortOrder"，与剧详情页 SeriesDetailView 的 @AppStorage 共享同一 key）。
/// 主线程约定：本类全部状态只在主线程访问（GCD 版，无线程标注）
final class DownloadsViewModel: ObservableObject {
    private let manager: DownloadManager
    private var sortPreferences = DownloadsSortPreferences()

    /// 编辑模式：点行勾选（剧行勾选整剧），底部栏全选/批量删除；跨两个区域一起生效
    @Published private(set) var selectionMode = false
    @Published private(set) var selected = Set<UUID>()
    /// 顶部 tab 与内容分页共用同一个 selection，点 tab 或左右滑都会同步
    @Published var page: DownloadPage = .inProgress
    /// 剧行左滑删除整剧前的确认目标（nil = 不弹确认）
    @Published var pendingDeleteSeries: String?
    /// 播放入口（普通模式点击已完成任务 → AVKit sheet，沿用旧行为）
    @Published var playerRequest: PlayerItem?

    /// 排序偏好（持久化走 Service，AGENTS 第 5 条；init 从 Service 恢复，修改即落盘）
    @Published var sortOrder: DownloadSortOrder {
        didSet { sortPreferences.sortOrder = sortOrder }
    }
    /// 每部剧的磁盘占用（字节；未计算到的剧不在字典里）：副剧行右侧 label 用
    @Published private(set) var seriesSizes: [String: Int64] = [:]
    /// 剧集区总占用：「已下载顶部：剧集·N部·xx.xGB」用
    @Published private(set) var seriesTotalBytes: Int64 = 0
    /// 上次已计算的全局输入指纹：done 任务 id 集 + 总数没变 → 连 work item 都不排（进度 tick 零成本）
    private var lastSizeSignature = ""
    /// 每集占用缓存（用户拍板 2026-11-13：按剧 id + 每集 id 键控，不用剧名/任务 UUID）。
    /// 外层键 = 剧 cacheKey（`DramaCache.seriesIdentity` 命中 → "site#dramaID"；无身份退化 "name:<剧名>"），
    /// 内层键 = 每集键（identity 的 episodeIDsBySort 命中 → "ep:<服务端集id>"；无身份退化 "uuid:<任务id>"）。
    /// 集目录/文件下载完成后不可变 → 每集字节永久稳定：新增/删除一集只扫那一个新集，其余全复用。
    /// 主线程约定：只在主线程读写（后台只负责扫盘）；删空的剧条目一并清除
    private var episodeSizeCache: [String: (seriesName: String, episodes: [String: Int64])] = [:]
    private var sizeRecomputeWork: DispatchWorkItem?
    private var managerObservation: AnyCancellable?

    init(manager: DownloadManager) {
        self.manager = manager
        self.sortOrder = sortPreferences.sortOrder
        // 任务的任何变化（新增/完成/删除）都可能改变磁盘占用 → 去抖后重算；
        // 指纹在计算时取最新值，进度 tick（id/done 不变）算完发现指纹相同自然跳过
        managerObservation = manager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleSizeRecompute() }
        // 首次计算不能只挂在 objectWillChange 上：页面安静（无任务变化、无进度 tick）时
        // objectWillChange 永远不来，已下载列表永远不出数字（用户反馈 2026-11-13）——
        // init 即排一次；全局指纹去重保证后续不重复算
        scheduleSizeRecompute()
    }

    // MARK: - 磁盘占用统计

    /// 去抖 500ms：批量删除/连续完成只算一次；主线程先算全局指纹，
    /// **没变化直接 return（不排 work item、不碰磁盘）**——缓存命中零成本
    private func scheduleSizeRecompute() {
        let signature = Self.sizeSignature(manager.tasks)
        guard signature != lastSizeSignature else { return }
        sizeRecomputeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recomputeSizes() }
        sizeRecomputeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 全局指纹 = done 任务 id 集 + 任务总数；新增/完成/删除都会变，进度 tick 不会变
    private static func sizeSignature(_ tasks: [DownloadTask]) -> String {
        let doneIDs = tasks.filter { $0.state == .done }.map(\.id.uuidString).sorted()
        return "\(doneIDs.joined(separator: ","))#\(tasks.count)"
    }

    private func recomputeSizes() {
        let signature = Self.sizeSignature(manager.tasks)
        guard signature != lastSizeSignature else {
            print("PLAYER_DBG [Service] diskUsage SKIP reason=sameSignature tasks=\(manager.tasks.count)")
            return
        }
        lastSizeSignature = signature
        let groups = Dictionary(grouping: manager.tasks.filter { $0.state == .done && $0.seriesName != nil },
                                by: { $0.seriesName! })
        // 主线程决策：剧身份 → cacheKey → 每集键对比缓存，只有缓存里没有的集才扫盘。
        // 身份解析（SQLite 主线程读）每剧一次，失败退化剧名键控 + 任务 UUID 集键
        struct SeriesPlan {
            let cacheKey: String
            let name: String
            var reuse: [String: Int64]                                  // 每集键 → 缓存字节
            var toScan: [(key: String, url: URL, isFolder: Bool)]       // 缓存没有的集
        }
        var plans: [SeriesPlan] = []
        for (name, eps) in groups {
            let identity = DramaCache.seriesIdentity(forSeriesName: name)
            let cacheKey = identity.map { "\($0.site)#\($0.dramaID)" } ?? "name:\(name)"
            let cached = episodeSizeCache[cacheKey]?.episodes ?? [:]
            var reuse: [String: Int64] = [:]
            var toScan: [(key: String, url: URL, isFolder: Bool)] = []
            for task in eps {
                let sort = DownloadManager.episodeSort(fromFolderName: task.title) ?? 0
                let episodeKey = identity?.episodeIDsBySort[sort].map { "ep:\($0)" } ?? "uuid:\(task.id.uuidString)"
                if let bytes = cached[episodeKey] {
                    reuse[episodeKey] = bytes
                } else if let out = task.outputURL {
                    toScan.append((episodeKey, task.isHLSFolder ? out.deletingLastPathComponent() : out, task.isHLSFolder))
                }
            }
            plans.append(SeriesPlan(cacheKey: cacheKey, name: name, reuse: reuse, toScan: toScan))
        }
        // 被删空的剧：缓存条目一并清除（按 seriesName 对位）
        episodeSizeCache = episodeSizeCache.filter { groups[$0.value.seriesName] != nil }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let scanned: [(cacheKey: String, episodeKey: String, bytes: Int64)] = plans.flatMap { plan in
                plan.toScan.map { item in
                    (plan.cacheKey, item.key,
                     item.isFolder ? DiskUsageService.directorySize(item.url) : DiskUsageService.fileSize(item.url))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                var sizesBySeries: [String: Int64] = [:]
                var total: Int64 = 0
                var reusedCount = 0
                var scannedCount = 0
                for plan in plans {
                    var episodes = plan.reuse
                    reusedCount += episodes.count
                    for item in scanned where item.cacheKey == plan.cacheKey {
                        episodes[item.episodeKey] = item.bytes
                        scannedCount += 1
                    }
                    self.episodeSizeCache[plan.cacheKey] = (seriesName: plan.name, episodes: episodes)
                    let seriesTotal = episodes.values.reduce(0, +)
                    sizesBySeries[plan.name] = seriesTotal
                    total += seriesTotal
                }
                self.seriesSizes = sizesBySeries
                self.seriesTotalBytes = total
                print("PLAYER_DBG [Service] diskUsage series=\(sizesBySeries.count) total=\(DiskUsageService.formatted(total)) episodesReused=\(reusedCount) episodesScanned=\(scannedCount)")
            }
        }
    }

    /// 某剧的人读占用；未计算到（后台枚举未完成）返回 nil，视图不显示占位
    func seriesSizeText(_ name: String) -> String? {
        guard let bytes = seriesSizes[name] else { return nil }
        return DiskUsageService.formatted(bytes)
    }

    // MARK: - 派生列表

    /// 未完成任务（等待/解析/下载中/失败）
    var activeTasks: [DownloadTask] {
        sortOrder.order(manager.tasks.filter { $0.state != .done })
    }

    /// 散装已完成条目（不属于任何剧）
    var standaloneItems: [DownloadTask] {
        sortOrder.order(manager.tasks.filter { $0.state == .done && $0.seriesName == nil })
    }

    /// 剧 -> 已落盘的集。组内按创建时间排；剧之间：
    /// 容量排序按磁盘占用缓存字节（未算出当 0，后台算完自动重排），
    /// 时间排序「最新优先」看最近一集、「最早优先」看最早一集。
    var seriesGroups: [(name: String, episodes: [DownloadTask])] {
        let grouped = Dictionary(grouping: manager.tasks.filter { $0.state == .done && $0.seriesName != nil },
                                 by: { $0.seriesName! })
        let groups = grouped.map { (name: $0.key, episodes: sortOrder.order($0.value)) }
        if sortOrder == .sizeDesc || sortOrder == .sizeAsc {
            let ascending = sortOrder == .sizeAsc
            return groups.sorted { a, b in
                let sa = seriesSizes[a.name] ?? 0
                let sb = seriesSizes[b.name] ?? 0
                if sa != sb { return ascending ? sa < sb : sa > sb }
                return a.name < b.name
            }
        }
        return groups.sorted { a, b in
            let timesA = a.episodes.map(\.createdAt)
            let timesB = b.episodes.map(\.createdAt)
            let keyA = sortOrder == .newestFirst ? timesA.max() : timesA.min()
            let keyB = sortOrder == .newestFirst ? timesB.max() : timesB.min()
            if let keyA, let keyB, keyA != keyB {
                return sortOrder == .newestFirst ? keyA > keyB : keyA < keyB
            }
            return a.name < b.name
        }
    }

    // MARK: - 编辑与删除编排

    func toggleEditMode() {
        if selectionMode { selected.removeAll() }
        selectionMode.toggle()
    }

    func toggleSelection(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    var allSelected: Bool {
        !manager.tasks.isEmpty && selected.count == manager.tasks.count
    }

    func toggleSelectAll() {
        if allSelected { selected.removeAll() } else { selected = Set(manager.tasks.map(\.id)) }
    }

    func deleteSelected() {
        manager.deleteTasks(ids: selected)
        selected.removeAll()
        if manager.tasks.isEmpty { selectionMode = false }
    }

    func cancelDeleteSeries() { pendingDeleteSeries = nil }

    func confirmDeleteSeries() {
        if let name = pendingDeleteSeries { manager.deleteSeries(name) }
        pendingDeleteSeries = nil
    }

    /// 左滑删除的局部下标 -> manager.tasks 全局下标
    func globalOffsets(_ offsets: IndexSet, in subset: [DownloadTask]) -> IndexSet {
        IndexSet(offsets.compactMap { offset in
            manager.tasks.firstIndex { $0.id == subset[offset].id }
        })
    }

    // MARK: - 勾选与播放

    /// 编辑模式下剧行是否整剧全选（勾选标记用）
    func seriesAllSelected(_ group: (name: String, episodes: [DownloadTask])) -> Bool {
        Set(group.episodes.map(\.id)).isSubset(of: selected)
    }

    /// 编辑模式下剧行点击 = 勾选/取消整剧（该剧全部已下载集）
    func toggleSeriesSelection(_ group: (name: String, episodes: [DownloadTask])) {
        let ids = Set(group.episodes.map(\.id))
        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
    }

    /// 普通模式点击任务行：已完成 → 播放（AVKit sheet，散装/进行中沿用旧行为）。
    /// identity 由调用方从列表侧解析带入（View → 自己的 VM → Service），
    /// 这样「AVKit 播的位置」与「列表显示的位置」必然落在同一条记录上。
    func handleTap(_ task: DownloadTask, identity: MediaIdentity) {
        guard task.state == .done, let url = task.outputURL else { return }
        playerRequest = PlayerItem(url: url, isHLSFolder: task.isHLSFolder, identity: identity)
    }
}
