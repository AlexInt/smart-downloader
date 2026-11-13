import SwiftUI
import AVKit

struct PlayerItem: Identifiable {
    let id = UUID()
    let url: URL
    let isHLSFolder: Bool
    /// 行为数据归属：由列表侧解析后带入，AVKit 播放记的位置才能和列表读的是同一条
    let identity: MediaIdentity
}

/// 下载页排列顺序（偏好跨页面共享并持久化）
enum DownloadSortOrder: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst
    /// 容量排序（用户拍板 2026-11-13）：只作用于「已下载」的剧分组维度，
    /// 字节来自磁盘占用缓存（DownloadsViewModel.seriesSizes，未算出当 0）
    case sizeDesc
    case sizeAsc

    var id: String { rawValue }
    var label: String {
        switch self {
        case .newestFirst: return "最新创建优先"
        case .oldestFirst: return "最早创建优先"
        case .sizeDesc: return "容量从大到小"
        case .sizeAsc: return "容量从小到大"
        }
    }
    var icon: String {
        switch self {
        case .newestFirst: return "arrow.down"
        case .oldestFirst: return "arrow.up"
        case .sizeDesc: return "arrow.down.circle"
        case .sizeAsc: return "arrow.up.circle"
        }
    }

    /// 集级排序：容量是「剧分组维度」的排序（见 seriesGroups），
    /// 集内/进行中/散装回退到同方向的时间序（单集容量不在本排序语义内）
    private var effectiveTimeOrder: DownloadSortOrder {
        switch self {
        case .oldestFirst, .sizeAsc: return .oldestFirst
        case .newestFirst, .sizeDesc: return .newestFirst
        }
    }

    /// 按创建时间排；同一时刻用标题/集号兜底，避免顺序抖动
    func order(_ tasks: [DownloadTask]) -> [DownloadTask] {
        let effective = effectiveTimeOrder
        return tasks.sorted { a, b in
            if a.createdAt != b.createdAt {
                return effective == .newestFirst ? a.createdAt > b.createdAt : a.createdAt < b.createdAt
            }
            return a.title < b.title
        }
    }
}

private extension Date {
    /// 列表里显示的创建时间，让排序依据可见（固定格式，不依赖 locale）
    var downloadsListText: String {
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: self)
        return String(format: "%02d/%02d %02d:%02d",
                      c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
}

/// 下载页顶部两个可横滑的区域
enum DownloadPage: Int, Hashable {
    case inProgress = 0
    case completed = 1
}

/// 下载页：顶部「下载中 / 已下载」两个 tab，可点可左右滑。
/// 排序与编辑（批量删除）在工具栏统一控制，两个区域都支持左滑删除。
struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    @StateObject private var vm: DownloadsViewModel
    /// 「播到哪」只读状态：进入页面 / 任务变化 / 播放入口关闭时刷新
    @StateObject private var progressVM = PlaybackProgressViewModel()

    init(manager: DownloadManager) {
        self.manager = manager
        _vm = StateObject(wrappedValue: DownloadsViewModel(manager: manager))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("下载区域", selection: $vm.page) {
                    Text("下载中").tag(DownloadPage.inProgress)
                    Text("已下载").tag(DownloadPage.completed)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                TabView(selection: $vm.page) {
                    inProgressPage
                        .tag(DownloadPage.inProgress)
                    completedPage
                        .tag(DownloadPage.completed)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // 自定义 tab bar 在 App 层用 safeAreaInset 注入，但 paging TabView 的页面
            // 不接收祖先追加的底部安全区（已知传递缺陷）→ 列表满屏时最后一行被 bar 盖住。
            // 这里按 bar 实高显式补底部安全区（MainTab.barReservedHeight 与 bar 内边距同步）。
            .safeAreaPadding(.bottom, MainTab.barReservedHeight)
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !manager.tasks.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("排列顺序", selection: $vm.sortOrder) {
                                ForEach(DownloadSortOrder.allCases) { order in
                                    Label(order.label, systemImage: order.icon).tag(order)
                                }
                            }
                        } label: {
                            Label("排序", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(vm.selectionMode ? "完成" : "编辑") {
                            vm.toggleEditMode()
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if vm.selectionMode {
                    HStack {
                        Button(vm.allSelected ? "全不选" : "全选") { vm.toggleSelectAll() }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("删除所选 (\(vm.selected.count))", role: .destructive) {
                            vm.deleteSelected()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.selected.isEmpty)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .confirmationDialog(
                "删除《\(vm.pendingDeleteSeries ?? "")》全部集及其文件？",
                isPresented: Binding(
                    get: { vm.pendingDeleteSeries != nil },
                    set: { if !$0 { vm.cancelDeleteSeries() } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除全剧", role: .destructive) {
                    vm.confirmDeleteSeries()
                }
                Button("取消", role: .cancel) { vm.cancelDeleteSeries() }
            }
        }
        .sheet(item: $vm.playerRequest, onDismiss: { progressVM.refresh(manager.tasks) }) { item in
            PlayerView(item: item)
        }
        .onAppear { progressVM.refresh(manager.tasks) }
        .onChange(of: manager.tasks.count) { _, _ in progressVM.refresh(manager.tasks) }
    }

    /// 左页：进行中（等待/解析/下载/保存/失败），左滑删除任务
    @ViewBuilder
    private var inProgressPage: some View {
        if vm.activeTasks.isEmpty {
            ContentUnavailableView(
                "暂无进行中的下载",
                systemImage: "arrow.down.circle",
                description: Text("去「浏览」页打开视频网页播放，或在剧集页选集下载"))
        } else {
            List {
                Section {
                    ForEach(vm.activeTasks) { task in
                        sectionRow(task: task)
                    }
                    .onDelete { manager.delete(at: vm.globalOffsets($0, in: vm.activeTasks)) }
                } header: {
                    Text("共 \(vm.activeTasks.count) 个任务 · 按创建时间排列")
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    /// 右页：已下载。剧集分组可进二级页 / 排序 / 删整剧，散装单条放在下方
    @ViewBuilder
    private var completedPage: some View {
        if vm.seriesGroups.isEmpty && vm.standaloneItems.isEmpty {
            ContentUnavailableView(
                "还没有下载完的内容",
                systemImage: "square.stack.3d.up",
                description: Text("下载完成后，剧集和单条视频会出现在这里，可排序、可删除"))
        } else {
            List {
                if !vm.seriesGroups.isEmpty {
                    Section {
                        ForEach(vm.seriesGroups, id: \.name) { group in
                            if vm.selectionMode {
                                seriesSelectionRow(group)
                            } else {
                                NavigationLink {
                                    SeriesDetailView(manager: manager, seriesName: group.name)
                                } label: {
                                    seriesRow(group)
                                }
                            }
                        }
                        .onDelete { offsets in
                            guard !vm.selectionMode else { return }
                            if let index = offsets.first, vm.seriesGroups.indices.contains(index) {
                                vm.pendingDeleteSeries = vm.seriesGroups[index].name
                            }
                        }
                    } header: {
                        Text(seriesHeaderText)
                    } footer: {
                        Text("左滑删除整剧，点进剧名可逐集管理")
                    }
                }
                if !vm.standaloneItems.isEmpty {
                    Section("其他下载") {
                        ForEach(vm.standaloneItems) { task in
                            sectionRow(task: task)
                        }
                        .onDelete { manager.delete(at: vm.globalOffsets($0, in: vm.standaloneItems)) }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func seriesRow(_ group: (name: String, episodes: [DownloadTask])) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill").foregroundColor(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).lineLimit(1)
                Text(seriesSubtitle(group)).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            // 右侧磁盘占用：后台枚举完成后出现（用户拍板 2026-11-13），未算出时不占位
            if let sizeText = vm.seriesSizeText(group.name) {
                Text(sizeText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        // 行高压缩（用户拍板 2026-11-13）：行内上下 padding 清零，交给 List 自身行内边距
        .padding(.vertical, 0)
    }

    /// 剧集区标题：部数 + 总占用（总占用未算出/为 0 时只显部数）
    private var seriesHeaderText: String {
        var text = "剧集 · \(vm.seriesGroups.count) 部"
        if vm.seriesTotalBytes > 0 {
            text += " · \(DiskUsageService.formatted(vm.seriesTotalBytes))"
        }
        return text
    }

    /// 剧行副标题带上时间，让「最新/最早优先」的排序依据可见
    private func seriesSubtitle(_ group: (name: String, episodes: [DownloadTask])) -> String {
        let times = group.episodes.map(\.createdAt)
        let key = vm.sortOrder == .newestFirst ? times.max() : times.min()
        let base = "已下载 \(group.episodes.count) 集"
        guard let key else { return base }
        return base + " · \(key.downloadsListText)"
    }

    /// 编辑模式下整行点击=勾选（Button(.plain)，不用 onTapGesture 以免与 List 手势冲突）；普通模式点击=播放
    @ViewBuilder
    private func sectionRow(task: DownloadTask) -> some View {
        if vm.selectionMode {
            Button {
                vm.toggleSelection(task.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: vm.selected.contains(task.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(vm.selected.contains(task.id) ? .blue : .secondary)
                    TaskRow(task: task, progress: progressVM.progress(for: task))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            TaskRow(task: task, progress: progressVM.progress(for: task))
                .contentShape(Rectangle())
                .onTapGesture { vm.handleTap(task, identity: progressVM.identity(for: task)) }
        }
    }

    /// 编辑模式下剧行点击=勾选整剧（该剧全部已下载集）
    private func seriesSelectionRow(_ group: (name: String, episodes: [DownloadTask])) -> some View {
        let allIn = vm.seriesAllSelected(group)
        return Button {
            vm.toggleSeriesSelection(group)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: allIn ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(allIn ? .blue : .secondary)
                seriesRow(group)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 剧详情页：该剧全部集（含下载中的），点集播放，左滑删单集，右上角删全剧
struct SeriesDetailView: View {
    @ObservedObject var manager: DownloadManager
    let seriesName: String
    @State private var playerItem: PlayerItem?
    /// 剧集点播走沉浸式播放页；playerItem 仅作非 HLS 文件夹的 AVKit 回退
    @State private var immersivePlayback: ImmersivePlaybackRequest?
    @State private var confirmDelete = false
    /// 「播到哪」只读状态：进入本页 / 播放入口关闭时刷新
    @StateObject private var progressVM = PlaybackProgressViewModel()
    /// 与下载页共用同一个排序偏好，两个页面的先后顺序一致
    @AppStorage("DownloadsView.sortOrder") private var sortOrder: DownloadSortOrder = .newestFirst

    private var episodes: [DownloadTask] {
        sortOrder.order(manager.tasks.filter { $0.seriesName == seriesName })
    }

    var body: some View {
        List {
            ForEach(episodes) { task in
                TaskRow(task: task, showSeries: false, progress: progressVM.progress(for: task))
                    .contentShape(Rectangle())
                    .onTapGesture { playIfDone(task) }
            }
            .onDelete { offsets in
                for offset in offsets { manager.remove(episodes[offset]) }
            }
        }
        .listStyle(.insetGrouped)
        // 同 DownloadsView：二级页的 List 同样吃不到 App 层 tab bar 的追加安全区
        .safeAreaPadding(.bottom, MainTab.barReservedHeight)
        .navigationTitle(seriesName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { confirmDelete = true } label: {
                    Image(systemName: "trash").foregroundColor(.red)
                }
            }
        }
        .confirmationDialog(
            "删除《\(seriesName)》全部 \(episodes.count) 集及其文件？",
            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除全剧", role: .destructive) { manager.deleteSeries(seriesName) }
        }
        .sheet(item: $playerItem, onDismiss: { refreshProgress() }) { item in
            PlayerView(item: item)
        }
        .fullScreenCover(item: $immersivePlayback, onDismiss: { refreshProgress() }) { request in
            DramaPlayerContainer(request: request, onClose: { immersivePlayback = nil })
        }
        .onAppear { refreshProgress() }
    }

    /// 播放进度由播放页落盘，本页只在进入与播放入口关闭时重新读取
    private func refreshProgress() {
        progressVM.refresh(episodes)
    }

    /// 剧集内点播：优先沉浸式竖屏播放页（可上下滑切集）；非 HLS 文件夹回退 AVKit。
    /// 全剧集数同步与滑动调度交给 PlaybackQueueService，这里只说明剧名与起始集号。
    private func playIfDone(_ task: DownloadTask) {
        guard task.state == .done, let url = task.outputURL else {
            print("PLAYER_DBG [Entry] playIfDone SKIP state=\(task.state) output=\(task.outputURL == nil ? "nil" : "yes")")
            return
        }
        guard task.isHLSFolder else {
            print("PLAYER_DBG [Entry] playIfDone → AVKit fallback (non-HLS) title=\(task.title)")
            playerItem = PlayerItem(url: url, isHLSFolder: false, identity: progressVM.identity(for: task))
            return
        }
        let sort = DownloadManager.episodeSort(fromFolderName: task.title) ?? 1
        print("PLAYER_DBG [Entry] playIfDone series=\(seriesName) title=\(task.title) parsedSort=\(sort) knownSorts=0 (rely on cache)")
        immersivePlayback = ImmersivePlaybackRequest(
            seriesName: seriesName,
            intro: nil,
            startSort: sort
        )
    }
}

struct TaskRow: View {
    @ObservedObject var task: DownloadTask
    /// 队列行是否附剧名前缀（剧详情页内不需要）
    var showSeries = true
    /// 播放到哪儿（播放域写入，列表只读展示）；nil = 从未播放
    var progress: PlaybackProgress? = nil

    private var rowTitle: String {
        if showSeries, let series = task.seriesName { return "\(series) · \(task.title)" }
        return task.title
    }

    var body: some View {
        HStack(spacing: 12) {
            stateIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle)
                    .lineLimit(1)
                detailLine
            }
            Spacer()
        }
        // 行高压缩（用户拍板 2026-11-13，与剧行同口径）：行内上下 padding 清零
        .padding(.vertical, 0)
    }

    @ViewBuilder private var stateIcon: some View {
        switch task.state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
        default:
            Image(systemName: "arrow.down.circle").foregroundColor(.blue)
        }
    }

    @ViewBuilder private var detailLine: some View {
        switch task.state {
        case .waiting:
            Text("等待中…").font(.caption).foregroundColor(.secondary)
        case .parsing:
            Text("解析播放列表…").font(.caption).foregroundColor(.secondary)
        case .downloading:
            if task.total > 0 {
                ProgressView(value: Double(task.current), total: Double(task.total))
                Text("下载中 \(task.current)/\(task.total) (\(Int(Double(task.current) / Double(task.total) * 100))%)")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ProgressView()
            }
        case .saving:
            Text("保存文件…").font(.caption).foregroundColor(.secondary)
        case .done:
            let base = task.isFromLibrary ? "本地文件" : "已保存到 \(task.displayName)"
            Text("\(base) · \(task.createdAt.downloadsListText)")
                .font(.caption).foregroundColor(.secondary)
            if let progress { playbackLine(progress) }
        case .failed(let message):
            Text("失败: \(message)").font(.caption).foregroundColor(.red)
        }
    }

    /// 已完成条目的播放进度：薄进度条 + 时间（看完只给文字）
    @ViewBuilder
    private func playbackLine(_ progress: PlaybackProgress) -> some View {
        if progress.isFinished {
            Label("已看完", systemImage: "checkmark.seal")
                .font(.caption2).foregroundColor(.secondary)
        } else {
            HStack(spacing: 6) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 110)
                Text("播至 \(progress.text)")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }
}

/// 播放：HLS 文件夹 -> 内置本地 HTTP 服务 + AVPlayer 原生 HLS；普通文件 -> 直接播
struct PlayerView: View {
    let item: PlayerItem
    @State private var player: AVPlayer?
    @State private var loadError: String?
    /// 进度跟踪：AVKit 播放入口也要记住位置，否则从下载页播的条目永远显示「未播放」
    @State private var progressTracker: PlaybackProgressTracker?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea(edges: .bottom)
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(loadError)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ProgressView("准备播放…")
            }
        }
        .onAppear {
            let start: (URL) -> Void = { url in
                let avPlayer = AVPlayer(url: url)
                // key 用本地文件路径（HLS 实际播放走回环 http 地址，两者不能混用）
                let tracker = PlaybackProgressTracker(identity: item.identity)
                tracker.attach(to: avPlayer)
                progressTracker = tracker
                player = avPlayer
                avPlayer.play()
            }
            if item.isHLSFolder {
                // playbackURL completion 固定主线程
                LocalMediaServer.shared.playbackURL(forFolder: item.url.deletingLastPathComponent()) { playback in
                    guard playback.scheme == "http" else {
                        loadError = "本地播放服务启动失败"
                        return
                    }
                    start(playback)
                }
            } else {
                start(item.url)
            }
        }
        .onDisappear {
            progressTracker?.detach()
            progressTracker = nil
        }
    }
}
