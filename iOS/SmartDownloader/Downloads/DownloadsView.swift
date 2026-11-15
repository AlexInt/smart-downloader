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

extension Date {
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

/// 已下载 → 剧集的推入路由（String 不是 Identifiable，包一层给 navigationDestination(item:)）
private struct SeriesRoute: Identifiable, Hashable {
    let name: String
    var id: String { name }
}

/// 下载页（画布 2:2「下载页 · 纸本」/ 19:272「已下载」/ 34:1「已下载 · 编辑模式」）。
///
/// 纸本轨：宣纸底 + 衬线分段（选中项压一条 44×2 朱砂短线）+ 细线，行内是
/// 60×82 封面 + 剧名 + 说明 + 2pt 进度轨道，右侧 26 的圆形动作按钮。
/// 顶部不再是系统 `Picker(.segmented)` + `List(.insetGrouped)`：分段与分组头都是自绘，
/// 列表仍用 `List`（保住左滑删除），只把系统外观全部抹掉（plain / 透明背景 / 隐分隔线）。
struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    /// VM 由 App 层注入（StateObject 所有权在 App）：本视图随 tab 切换销毁重建，
    /// 缓存型 VM 不能在这里创建（否则每次切 tab 全量重扫盘 + 全量 SQLite 读）
    @ObservedObject var vm: DownloadsViewModel
    @ObservedObject var progressVM: PlaybackProgressViewModel

    /// 取消下载的确认目标（下载中的圆形按钮是破坏性操作，先弹一次确认）
    @State private var pendingCancel: DownloadTask?
    /// 已下载 → 剧集二级页
    @State private var pushedSeries: SeriesRoute?
    /// `-downloadsSeries` 只消费一次
    @State private var debugSeriesPushed = false

    init(manager: DownloadManager, vm: DownloadsViewModel, progressVM: PlaybackProgressViewModel) {
        self.manager = manager
        self.vm = vm
        self.progressVM = progressVM
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                segmentedHeader

                TabView(selection: $vm.page) {
                    inProgressPage
                        .tag(DownloadPage.inProgress)
                    completedPage
                        .tag(DownloadPage.completed)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if vm.selectionMode { editBar }
            }
            .background(DWColor.paper.ignoresSafeArea())
            // 自定义 tab bar 在 App 层用 safeAreaInset 注入，但 paging TabView 的页面
            // 不接收祖先追加的底部安全区（已知传递缺陷）→ 列表满屏时最后一行被 bar 盖住。
            // 这里按 bar 实高显式补底部安全区（MainTab.barReservedHeight 与 bar 内边距同步）。
            .safeAreaPadding(.bottom, MainTab.barReservedHeight)
            // 设计稿没有系统导航栏：分段头就是页头
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $pushedSeries) { route in
                SeriesDetailView(manager: manager, seriesName: route.name)
            }
            .confirmationDialog(
                "删除《\(vm.pendingDeleteSeries ?? "")》全部集及其文件？",
                isPresented: Binding(
                    get: { vm.pendingDeleteSeries != nil },
                    set: { if !$0 { vm.cancelDeleteSeries() } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除全剧", role: .destructive) { vm.confirmDeleteSeries() }
                Button("取消", role: .cancel) { vm.cancelDeleteSeries() }
            }
            .confirmationDialog(
                "取消这个下载？",
                isPresented: Binding(
                    get: { pendingCancel != nil },
                    set: { if !$0 { pendingCancel = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingCancel
            ) { task in
                Button("取消下载", role: .destructive) {
                    manager.remove(task)
                    pendingCancel = nil
                }
                Button("继续下载", role: .cancel) { pendingCancel = nil }
            } message: { task in
                Text("《\(task.seriesName.map { "\($0) · " } ?? "")\(task.title)》已下载的分片会被删除。")
            }
        }
        .sheet(item: $vm.playerRequest, onDismiss: { progressVM.refresh(manager.tasks) }) { item in
            PlayerView(item: item)
        }
        .onAppear {
            progressVM.refresh(manager.tasks)
            pushDebugSeriesIfNeeded()
        }
        .onChange(of: manager.tasks.count) { _, _ in progressVM.refresh(manager.tasks) }
    }

    /// Debug 专用启动参数 `-downloadsSeries <剧名>`：模拟器点不了海报卡，
    /// 直接推入该剧详情页（验证同集去重后「一集只有一条记录」）。Release 不编译。
    private func pushDebugSeriesIfNeeded() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-downloadsSeries"), arguments.count > index + 1,
              !debugSeriesPushed else { return }
        debugSeriesPushed = true
        let name = arguments[index + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let episodes = manager.tasks.filter { $0.seriesName == name }
            print("DOWNLOAD_DBG [CHECK] debug push series=\(name) exists=\(!episodes.isEmpty) "
                  + "episodes=\(episodes.map { "\($0.title):\($0.state)" })")
            pushedSeries = SeriesRoute(name: name)
        }
        #endif
    }

    // MARK: - 分段头（画布 2:29 分段与细线）

    /// 分段：标签间距 26、文字 fs14 衬线、选中项下方压一条 44×2 朱砂短线（未选中留空位），
    /// 分段下面 8 处一张通栏细线。左右边距 22（画布 2:7 内容区）。
    private var segmentedHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 26) {
                segment("下载中 \(vm.activeTasks.count)", selected: vm.page == .inProgress) {
                    vm.page = .inProgress
                }
                segment("已下载 \(completedCount)", selected: vm.page == .completed) {
                    vm.page = .completed
                }
                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(DWColor.paperTrack)
                .frame(height: 1)
        }
        .padding(.horizontal, DWLayout.pageEdge)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // 画布 2:31 是纵向布局、交叉轴左对齐：短线从文字左边起，比文字短
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(DWFont.serif(14, selected ? .medium : .regular))
                    .foregroundStyle(selected ? DWColor.paperInk : DWColor.paperInkSub)
                Rectangle()
                    .fill(selected ? DWColor.paperCinnabar : Color.clear)
                    .frame(width: 44, height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: selected)
    }

    private var completedCount: Int {
        vm.seriesGroups.count + vm.standaloneItems.count
    }

    // MARK: - 左页：下载中（画布 2:38 下载中分组）

    @ViewBuilder
    private var inProgressPage: some View {
        if vm.activeTasks.isEmpty {
            paperEmpty(title: "暂无进行中的下载",
                       hint: "去「浏览」页打开视频网页，或在剧集页选集下载")
        } else {
            List {
                ForEach(vm.activeTasks) { task in
                    inProgressRow(task)
                        .paperListRow()
                }
                // 左滑删除沿用系统语义（行内圆形按钮是「取消」，手势是快速通道）
                .onDelete { manager.delete(at: vm.globalOffsets($0, in: vm.activeTasks)) }
            }
            .paperList()
        }
    }

    /// 下载中的一行：封面 60×82 + 剧名/说明/进度轨道（gap 9）+ 右侧 26 的圆形按钮。
    /// 行高锁 82（封面高度），信息块 hug 内容后垂直居中 —— 与画布 2:40 的分布一致。
    private func inProgressRow(_ task: DownloadTask) -> some View {
        HStack(spacing: 14) {
            PaperCover(title: task.seriesName ?? task.title,
                       url: task.seriesName.flatMap { vm.seriesCovers[$0] })

            VStack(alignment: .leading, spacing: 9) {
                Text(task.seriesName ?? task.title)
                    .font(DWFont.serif(15, .medium))
                    .foregroundStyle(DWColor.paperInk)
                    .lineLimit(1)

                Text(progressDetail(task))
                    .font(DWFont.cn(11))
                    .foregroundStyle(isFailed(task) ? DWColor.paperCinnabar : DWColor.paperIcon)
                    .lineLimit(1)

                PaperProgressBar(fraction: progressFraction(task))
            }

            if isFailed(task) {
                // 失败行给「重试」：圆环 + 刷新箭头，与取消按钮同一形状语言。
                // 刷新图元是实心填充形（画布 22:332），必须 .fill——用 .stroke 会得到
                // 「一条弧带的轮廓」，13pt 下糊成一团。
                circleButton(stroke: DWColor.paperInkSub) {
                    PaperReloadShape()
                        .fill(DWColor.paperIcon)
                        .frame(width: 13, height: 13)
                } action: {
                    manager.run(task)
                }
            } else {
                circleButton(stroke: DWColor.paperInkSub) {
                    PaperXShape()
                        .stroke(DWColor.paperIcon,
                                style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .frame(width: 10, height: 10)
                } action: {
                    pendingCancel = task
                }
            }
        }
        .frame(height: 82)
    }

    private func isFailed(_ task: DownloadTask) -> Bool {
        if case .failed = task.state { return true }
        return false
    }

    private func progressFraction(_ task: DownloadTask) -> Double {
        guard task.total > 0 else { return 0 }
        return Double(task.current) / Double(task.total)
    }

    /// 「第 N 集 · 68%」：容量只有落盘后才算得出（磁盘占用缓存），下载中只报集号与百分比
    private func progressDetail(_ task: DownloadTask) -> String {
        let episode: String
        if task.seriesName != nil {
            let sort = DownloadManager.episodeSort(fromFolderName: task.title) ?? 0
            episode = "第 \(sort) 集"
        } else {
            // 散装任务没有集号；这里再报一次标题会和上一行完全重复
            episode = "单文件"
        }
        switch task.state {
        case .waiting: return "等待中"
        case .parsing: return "解析播放列表…"
        case .saving: return "保存文件…"
        case .downloading:
            guard task.total > 0 else { return "\(episode) · 下载中" }
            return "\(episode) · \(Int(progressFraction(task) * 100))%"
        case .failed(let message): return "失败 · \(message)"
        case .done: return "已保存"
        }
    }

    // MARK: - 右页：已下载（画布 19:272 / 34:1；2026-11-15 起改为双列海报卡）

    /// 已下载列表一个卡片：剧分组或散装单条。两类的点击/勾选语义不同，
    /// 统一成一个枚举让网格按同一顺序（先剧、后散装）排布。
    private enum CompletedCard: Identifiable {
        case series(name: String, episodes: [DownloadTask])
        case standalone(DownloadTask)

        var id: String {
            switch self {
            case .series(let name, _): return "series:\(name)"
            case .standalone(let task): return "task:\(task.id.uuidString)"
            }
        }
    }

    private var completedCards: [CompletedCard] {
        vm.seriesGroups.map { .series(name: $0.name, episodes: $0.episodes) }
            + vm.standaloneItems.map(CompletedCard.standalone)
    }

    @ViewBuilder
    private var completedPage: some View {
        if vm.seriesGroups.isEmpty && vm.standaloneItems.isEmpty {
            paperEmpty(title: "还没有下载完的内容",
                       hint: "下载完成后，剧集和单条视频会出现在这里")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    seriesHeaderRow
                    // 三列海报卡组件与剧集页推荐 / 「我的」封面墙共用（Components/PosterGrid.swift），
                    // 一行 3 张（2026-11-15 用户拍板），字号走 `compact` 档
                    PosterGrid(items: completedCards, columns: 3) { card in
                        completedCard(card)
                    }
                }
                .padding(.horizontal, DWLayout.pageEdge)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// 已下载卡片：剧卡点击进剧详情（编辑模式勾选整剧），散装卡点击播放（编辑模式勾选单条）。
    /// 剧卡长按给「删除全剧」（原来靠 List 左滑，改网格后保留同一能力）。
    @ViewBuilder
    private func completedCard(_ card: CompletedCard) -> some View {
        switch card {
        case .series(let name, let episodes):
            let group = (name: name, episodes: episodes)
            Button {
                if vm.selectionMode {
                    vm.toggleSeriesSelection(group)
                } else {
                    pushedSeries = SeriesRoute(name: name)
                }
            } label: {
                PosterCardView(
                    model: seriesCardModel(name: name, episodes: episodes),
                    selection: vm.selectionMode ? vm.seriesAllSelected(group) : nil,
                    compact: true
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                if !vm.selectionMode {
                    Button(role: .destructive) {
                        vm.pendingDeleteSeries = name
                    } label: {
                        Label("删除全剧", systemImage: "trash")
                    }
                }
            }
        case .standalone(let task):
            Button {
                if vm.selectionMode {
                    vm.toggleSelection(task.id)
                } else {
                    vm.handleTap(task, identity: progressVM.identity(for: task))
                }
            } label: {
                PosterCardView(
                    model: standaloneCardModel(task),
                    selection: vm.selectionMode ? vm.selected.contains(task.id) : nil,
                    compact: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// 剧卡数据：剧名 + 「全 N 集 · 占用 · 时间」+ 可离线播放（推荐卡同一套三行文字块）
    private func seriesCardModel(name: String, episodes: [DownloadTask]) -> PosterCardModel {
        PosterCardModel(
            id: "series:\(name)",
            title: name,
            subtitle: seriesSubtitle((name: name, episodes: episodes)),
            stat: "可离线播放",
            cover: coverSource(vm.seriesCovers[name])
        )
    }

    /// 散装卡数据：标题 + 本地文件时间 + 可离线播放
    private func standaloneCardModel(_ task: DownloadTask) -> PosterCardModel {
        PosterCardModel(
            id: "task:\(task.id.uuidString)",
            title: task.title,
            subtitle: "本地文件 · \(task.createdAt.downloadsListText)",
            stat: "可离线播放"
        )
    }

    /// 本地封面文件 → 共享卡片的封面来源（无图退纸本占位）
    private func coverSource(_ url: URL?) -> PosterCoverSource {
        guard let url else { return .none }
        return url.isFileURL ? .local(url) : .remote(url)
    }

    /// 分组头（画布 30:38 / 34:22）：左边统计，右边「编辑 + 排序」；
    /// 编辑模式下右边换成单个「完成」，统计换成已选部数。
    private var seriesHeaderRow: some View {
        HStack(spacing: 0) {
            Text(seriesStatText)
                .font(DWFont.cn(10))
                .foregroundStyle(DWColor.paperInkSub)

            Spacer(minLength: 8)

            if vm.selectionMode {
                Button("完成") { vm.toggleEditMode() }
                    .font(DWFont.cn(13, .medium))
                    .foregroundStyle(DWColor.paperInk)
                    .buttonStyle(.plain)
            } else {
                HStack(spacing: 12) {
                    iconButton {
                        PaperPencilShape()
                            .stroke(DWColor.paperIcon,
                                    style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                            .frame(width: 14.6, height: 14.6)
                    } action: {
                        vm.toggleEditMode()
                    }

                    Menu {
                        Picker("排列顺序", selection: $vm.sortOrder) {
                            ForEach(DownloadSortOrder.allCases) { order in
                                Label(order.label, systemImage: order.icon).tag(order)
                            }
                        }
                    } label: {
                        PaperSortShape()
                            .stroke(DWColor.paperIcon,
                                    style: StrokeStyle(lineWidth: 1, lineCap: .round))
                            .frame(width: 12, height: 7)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .frame(height: 22)
    }

    private var seriesStatText: String {
        if vm.selectionMode {
            let selectedSeries = vm.seriesGroups.filter { vm.seriesAllSelected($0) }.count
            return "已选 \(selectedSeries) 部剧 · 共 \(vm.seriesGroups.count) 部"
        }
        var text = "\(vm.seriesGroups.count) 部剧"
        if vm.seriesTotalBytes > 0 {
            text += " · \(DiskUsageService.formatted(vm.seriesTotalBytes))"
        }
        return text
    }

    /// 剧行说明（画布 19:310「全 32 集 · 1.1 GB · 昨日 21:40」）：集数 + 占用 + 时间
    private func seriesSubtitle(_ group: (name: String, episodes: [DownloadTask])) -> String {
        var parts = ["全 \(group.episodes.count) 集"]
        if let sizeText = vm.seriesSizeText(group.name) { parts.append(sizeText) }
        let times = group.episodes.map(\.createdAt)
        if let key = vm.sortOrder == .newestFirst ? times.max() : times.min() {
            parts.append(key.downloadsListText)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 编辑工具条（画布 34:84）

    private var editBar: some View {
        HStack(spacing: 0) {
            Button(vm.allSelected ? "全不选" : "全选") { vm.toggleSelectAll() }
                .font(DWFont.cn(13, .medium))
                .foregroundStyle(DWColor.paperInkSub)
                .buttonStyle(.plain)

            Spacer(minLength: 8)

            Button {
                vm.deleteSelected()
            } label: {
                Text("删除所选 (\(vm.selected.count))")
                    .font(DWFont.cn(12, .medium))
                    .foregroundStyle(DWColor.paper)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Capsule().fill(vm.selected.isEmpty
                                               ? DWColor.paperLineIdle
                                               : DWColor.paperCinnabar))
            }
            .buttonStyle(.plain)
            .disabled(vm.selected.isEmpty)
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
        .background(DWColor.paperChipIdle)
        .overlay(alignment: .top) {
            Rectangle().fill(DWColor.paperHairline).frame(height: 0.5)
        }
    }

    // MARK: - 行内小部件

    private func circleButton<Glyph: View>(stroke: Color,
                                           @ViewBuilder glyph: () -> Glyph,
                                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(stroke, lineWidth: 1).frame(width: 22, height: 22)
                glyph()
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconButton<Glyph: View>(@ViewBuilder glyph: () -> Glyph,
                                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            glyph()
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func paperEmpty(title: String, hint: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(DWFont.serif(14, .medium))
                .foregroundStyle(DWColor.paperInkSub)
            Text(hint)
                .font(DWFont.cn(11))
                .foregroundStyle(DWColor.paperFaint)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, DWLayout.pageEdge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 纸本列表外观

private extension View {
    /// 列表行统一外观：透明行底 + 隐分隔线 + 左右 22 边距 + 上下 6（相邻行 → 12 的节奏）
    func paperRow(vertical: CGFloat = 6) -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: vertical, leading: DWLayout.pageEdge,
                                      bottom: vertical, trailing: DWLayout.pageEdge))
            .padding(.vertical, 0)
    }

    /// 分组内相邻行。实测 `.listRowInsets(top: 0, bottom: 0)` 时相邻行**紧贴**
    ///（封面块之间只隔 0.5pt 描边，没有 List 自己的 12），所以要多大间距直接给一半：
    /// 相邻两行的 bottom + top 相加 = 目标间距（已下载列表 5pt，见 `completedCellSpacing`）。
    func paperListRow(vertical: CGFloat = 0) -> some View {
        paperRow(vertical: vertical)
    }

    /// 列表容器统一外观：抹掉系统 plain 的分组留白与白底，露出宣纸
    func paperList() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
    }
}

// MARK: - 封面 / 进度条

/// 剧集封面（画布 19:307 60×82 r5）：本地缓存文件优先，无图用纸本占位（首字衬线）
struct PaperCover: View {
    let title: String
    let url: URL?

    var body: some View {
        Group {
            if let url, url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url, !url.isFileURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 60, height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(DWColor.paperRule, lineWidth: 0.5)
        }
    }

    private var fallback: some View {
        ZStack {
            DWColor.paperChipIdle
            // 无封面时的兜底：首字压在纸块上（没有图也不该空成一块死灰）。
            // 字号取 16 而不是 22——22 在 60×82 里像占位符，16 + 一点字距更像书脊烫印
            Text(String(title.prefix(1)))
                .font(DWFont.serif(16))
                .tracking(1)
                .foregroundStyle(DWColor.paperLineIdle)
        }
    }
}

/// 2pt 进度轨道（画布 2:45 轨道 #C4C7C3 + 2:46 已完成段 #35393B）
struct PaperProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(DWColor.paperTrack)
                Rectangle()
                    .fill(DWColor.paperTrackFill)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 2)
    }
}

// MARK: - 剧详情页

/// 剧详情页：该剧全部集（含下载中的），点集播放，左滑删单集，右上角删全剧。
/// 画布未覆盖此页，沿用纸本语言（宣纸底 + 衬线标题 + 细线行），与列表页同一套行样式。
struct SeriesDetailView: View {
    @ObservedObject var manager: DownloadManager
    let seriesName: String
    @State private var playerItem: PlayerItem?
    /// 剧集点播走沉浸式播放页；playerItem 仅作非 HLS 文件夹的 AVKit 回退
    @State private var immersivePlayback: ImmersivePlaybackRequest?
    @State private var confirmDelete = false
    /// 「播到哪」只读状态：进入本页 / 播放入口关闭时刷新
    @StateObject private var progressVM = PlaybackProgressViewModel()
    /// 与下载页共用同一个排序偏好（Service 读取，AGENTS 第 5 条：View 不碰 UserDefaults/@AppStorage；
    /// 推入期间偏好不会变化，进入时读一次即可）
    @State private var sortOrder: DownloadSortOrder = .newestFirst

    init(manager: DownloadManager, seriesName: String) {
        self.manager = manager
        self.seriesName = seriesName
        _sortOrder = State(initialValue: DownloadsSortPreferences().sortOrder)
    }

    private var episodes: [DownloadTask] {
        sortOrder.order(manager.tasks.filter { $0.seriesName == seriesName })
    }

    var body: some View {
        List {
            ForEach(episodes) { task in
                TaskRow(task: task, showSeries: false, progress: progressVM.progress(for: task))
                    .paperListRow()
                    .contentShape(Rectangle())
                    .onTapGesture { playIfDone(task) }
            }
            .onDelete { offsets in
                for offset in offsets { manager.remove(episodes[offset]) }
            }
        }
        .paperList()
        .background(DWColor.paper.ignoresSafeArea())
        .safeAreaPadding(.bottom, MainTab.barReservedHeight)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(DWColor.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(seriesName)
                    .font(DWFont.serif(17, .medium))
                    .foregroundStyle(DWColor.paperInk)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { confirmDelete = true } label: {
                    Text("删除全剧")
                        .font(DWFont.cn(13))
                        .foregroundStyle(DWColor.paperCinnabar)
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
            DramaPlayerContainer(request: request, manager: manager,
                                 onClose: { immersivePlayback = nil })
        }
        .onAppear { refreshProgress() }
    }

    /// 播放进度由播放页落盘，本页只在进入与播放入口关闭时重新读取
    private func refreshProgress() {
        progressVM.refresh(episodes)
    }

    /// 剧集内点播：优先沉浸式竖屏播放页（可上下滑切集）；非 HLS 文件夹回退 AVKit。
    /// 全剧集数同步与滑动调度交给 PlaybackQueueService，这里只说明剧名与起始集号。
    /// 未完成的条目：失败点一下重试（直链仍在就重跑），其余状态只打日志。
    private func playIfDone(_ task: DownloadTask) {
        guard task.state == .done, let url = task.outputURL else {
            print("PLAYER_DBG [Entry] playIfDone SKIP state=\(task.state) output=\(task.outputURL == nil ? "nil" : "yes") title=\(task.title)")
            if case .failed = task.state, !task.url.isEmpty {
                print("PLAYER_DBG [Entry] playIfDone → retry failed title=\(task.title)")
                manager.run(task)
            }
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

/// 剧详情页的单集行（纸本版）：剧名 + 状态/进度说明，左侧状态点改成线稿圆环
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

            VStack(alignment: .leading, spacing: 6) {
                Text(rowTitle)
                    .font(DWFont.serif(14, .medium))
                    .foregroundStyle(DWColor.paperInk)
                    .lineLimit(1)
                detailLine
            }

            Spacer(minLength: 0)
        }
        .frame(height: 56)
    }

    @ViewBuilder private var stateIcon: some View {
        switch task.state {
        case .done:
            ZStack {
                Circle().stroke(DWColor.paperInkSub, lineWidth: 1).frame(width: 16, height: 16)
                PaperCheckShape()
                    .stroke(DWColor.paperIcon,
                            style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 6.6, height: 4.6)
            }
            .frame(width: 18, height: 18)
        case .failed:
            ZStack {
                Circle().stroke(DWColor.paperCinnabar, lineWidth: 1).frame(width: 16, height: 16)
                PaperXShape()
                    .stroke(DWColor.paperCinnabar, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .frame(width: 8, height: 8)
            }
            .frame(width: 18, height: 18)
        default:
            ZStack {
                Circle().stroke(DWColor.paperInkSub, lineWidth: 1).frame(width: 16, height: 16)
                PaperBadgeArrowShape()
                    .stroke(DWColor.paperIcon, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    .frame(width: 10, height: 10)
                    .clipShape(Circle())
            }
            .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder private var detailLine: some View {
        switch task.state {
        case .waiting:
            subText("等待中…")
        case .parsing:
            subText("解析播放列表…")
        case .downloading:
            if task.total > 0 {
                PaperProgressBar(fraction: Double(task.current) / Double(task.total))
                    .frame(width: 120)
                subText("下载中 \(task.current)/\(task.total) (\(Int(Double(task.current) / Double(task.total) * 100))%)")
            } else {
                subText("下载中…")
            }
        case .saving:
            subText("保存文件…")
        case .done:
            let base = task.isFromLibrary ? "本地文件" : "已保存到 \(task.displayName)"
            subText("\(base) · \(task.createdAt.downloadsListText)")
            if let progress { playbackLine(progress) }
        case .failed(let message):
            Text("失败: \(message)")
                .font(DWFont.cn(11))
                .foregroundStyle(DWColor.paperCinnabar)
                .lineLimit(1)
        }
    }

    private func subText(_ text: String) -> some View {
        Text(text)
            .font(DWFont.cn(11))
            .foregroundStyle(DWColor.paperInkSub)
            .lineLimit(1)
    }

    /// 已完成条目的播放进度：薄进度条 + 时间（看完只给文字）
    @ViewBuilder
    private func playbackLine(_ progress: PlaybackProgress) -> some View {
        if progress.isFinished {
            Text("已看完")
                .font(DWFont.cn(10))
                .foregroundStyle(DWColor.paperFaint)
        } else {
            HStack(spacing: 6) {
                PaperProgressBar(fraction: progress.fraction)
                    .frame(width: 90)
                Text("播至 \(progress.text)")
                    .font(DWFont.cn(10))
                    .foregroundStyle(DWColor.paperFaint)
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
