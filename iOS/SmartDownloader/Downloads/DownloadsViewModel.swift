import Foundation
import Combine

/// 下载页 ViewModel（架构评估 P10 拆分）：
/// 编辑模式/勾选/批量删除编排与「下载中/已下载」两个区域的派生列表都在这里，
/// DownloadsView 只渲染 + 转发意图。排序偏好持久化由本 VM 接管
///（UserDefaults "DownloadsView.sortOrder"，与剧详情页 SeriesDetailView 的 @AppStorage 共享同一 key）。
/// 主线程约定：本类全部状态只在主线程访问（GCD 版，无线程标注）
final class DownloadsViewModel: ObservableObject {
    private let manager: DownloadManager

    /// 编辑模式：点行勾选（剧行勾选整剧），底部栏全选/批量删除；跨两个区域一起生效
    @Published private(set) var selectionMode = false
    @Published private(set) var selected = Set<UUID>()
    /// 顶部 tab 与内容分页共用同一个 selection，点 tab 或左右滑都会同步
    @Published var page: DownloadPage = .inProgress
    /// 剧行左滑删除整剧前的确认目标（nil = 不弹确认）
    @Published var pendingDeleteSeries: String?
    /// 播放入口（普通模式点击已完成任务 → AVKit sheet，沿用旧行为）
    @Published var playerRequest: PlayerItem?

    /// 排序偏好（init 从 UserDefaults 恢复，修改即落盘）
    @Published var sortOrder: DownloadSortOrder {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "DownloadsView.sortOrder") }
    }
    /// 每部剧的磁盘占用（字节；未计算到的剧不在字典里）：副剧行右侧 label 用
    @Published private(set) var seriesSizes: [String: Int64] = [:]
    /// 剧集区总占用：「已下载顶部：剧集·N部·xx.xGB」用
    @Published private(set) var seriesTotalBytes: Int64 = 0
    /// 上次已计算的全局输入指纹：done 任务 id 集 + 总数没变 → 连 work item 都不排（进度 tick 零成本）
    private var lastSizeSignature = ""
    /// 每剧占用缓存：键 = 剧名，值 = (该剧 done 集 id 指纹, 字节)。
    /// 全局指纹变了也只重扫「有增删的剧」，没动的剧直接复用缓存字节（用户要求 2026-11-13）。
    /// 主线程约定：只在主线程读写（后台只负责扫盘）
    private var seriesSizeCache: [String: (signature: String, bytes: Int64)] = [:]
    private var sizeRecomputeWork: DispatchWorkItem?
    private var managerObservation: AnyCancellable?

    init(manager: DownloadManager) {
        self.manager = manager
        let raw = UserDefaults.standard.string(forKey: "DownloadsView.sortOrder")
        self.sortOrder = raw.flatMap(DownloadSortOrder.init(rawValue:)) ?? .newestFirst
        // 任务的任何变化（新增/完成/删除）都可能改变磁盘占用 → 去抖后重算；
        // 指纹在计算时取最新值，进度 tick（id/done 不变）算完发现指纹相同自然跳过
        managerObservation = manager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleSizeRecompute() }
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
        // 主线程决策：每剧自己的指纹（该集 done 集 id 集）对比缓存——
        // 没增删的剧直接复用缓存字节，只把变了的剧交给后台扫盘
        var reuse: [String: Int64] = [:]
        var toScan: [(name: String, signature: String)] = []
        for (name, eps) in groups {
            let sig = eps.map(\.id.uuidString).sorted().joined(separator: ",")
            if let cached = seriesSizeCache[name], cached.signature == sig {
                reuse[name] = cached.bytes
            } else {
                toScan.append((name, sig))
            }
        }
        // 被删空的剧：缓存条目一并清掉
        seriesSizeCache = seriesSizeCache.filter { groups[$0.key] != nil }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let scanned: [(String, String, Int64)] = toScan.map {
                ($0.name, $0.signature, DiskUsageService.directorySize(DownloadEngine.seriesDirectory(for: $0.name)))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                var sizes = reuse                    // 未变的剧用缓存
                var total = reuse.values.reduce(0, +)
                for (name, sig, bytes) in scanned {
                    sizes[name] = bytes
                    total += bytes
                    self.seriesSizeCache[name] = (signature: sig, bytes: bytes)
                }
                self.seriesSizes = sizes
                self.seriesTotalBytes = total
                print("PLAYER_DBG [Service] diskUsage series=\(sizes.count) total=\(DiskUsageService.formatted(total)) reused=\(reuse.count) scanned=\(scanned.count)")
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

    /// 剧 -> 已落盘的集。组内按创建时间排；剧之间「最新优先」看最近一集、「最早优先」看最早一集。
    var seriesGroups: [(name: String, episodes: [DownloadTask])] {
        let grouped = Dictionary(grouping: manager.tasks.filter { $0.state == .done && $0.seriesName != nil },
                                 by: { $0.seriesName! })
        let groups = grouped.map { (name: $0.key, episodes: sortOrder.order($0.value)) }
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
