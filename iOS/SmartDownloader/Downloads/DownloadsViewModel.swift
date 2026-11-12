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

    init(manager: DownloadManager) {
        self.manager = manager
        let raw = UserDefaults.standard.string(forKey: "DownloadsView.sortOrder")
        self.sortOrder = raw.flatMap(DownloadSortOrder.init(rawValue:)) ?? .newestFirst
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
