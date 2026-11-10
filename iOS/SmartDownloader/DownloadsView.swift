import SwiftUI
import AVKit

struct PlayerItem: Identifiable {
    let id = UUID()
    let url: URL
    let isHLSFolder: Bool
}

/// 下载页：正在下载队列 + 剧集（按剧名目录分组）/ 散装条目；
/// 点击已完成条目直接播放，左滑删除（同时删沙盒文件/文件夹）
struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    @State private var playerItem: PlayerItem?

    /// 未完成任务（等待/解析/下载中/失败）
    private var activeTasks: [DownloadTask] { manager.tasks.filter { $0.state != .done } }
    /// 散装已完成条目（不属于任何剧）
    private var standaloneItems: [DownloadTask] {
        manager.tasks.filter { $0.state == .done && $0.seriesName == nil }
    }
    /// 剧 -> 已落盘的集（按集名排序）
    private var seriesGroups: [(name: String, episodes: [DownloadTask])] {
        Dictionary(grouping: manager.tasks.filter { $0.state == .done && $0.seriesName != nil },
                   by: { $0.seriesName! })
            .map { (name: $0.key, episodes: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            Group {
                if manager.tasks.isEmpty {
                    ContentUnavailableView(
                        "暂无下载",
                        systemImage: "arrow.down.circle",
                        description: Text("去「浏览」页打开视频网页：播放页点「下载视频」，剧集页自动弹面板选集下载"))
                } else {
                    List {
                        if !activeTasks.isEmpty {
                            Section("正在下载") {
                                ForEach(activeTasks) { task in
                                    TaskRow(task: task)
                                }
                                .onDelete { manager.delete(at: globalOffsets($0, in: activeTasks)) }
                            }
                        }
                        if !seriesGroups.isEmpty {
                            Section("剧集") {
                                ForEach(seriesGroups, id: \.name) { group in
                                    NavigationLink {
                                        SeriesDetailView(manager: manager, seriesName: group.name)
                                    } label: {
                                        seriesRow(group)
                                    }
                                }
                            }
                        }
                        if !standaloneItems.isEmpty {
                            Section("已下载") {
                                ForEach(standaloneItems) { task in
                                    TaskRow(task: task)
                                        .contentShape(Rectangle())
                                        .onTapGesture { playIfDone(task) }
                                }
                                .onDelete { manager.delete(at: globalOffsets($0, in: standaloneItems)) }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $playerItem) { item in
            PlayerView(item: item)
        }
    }

    private func seriesRow(_ group: (name: String, episodes: [DownloadTask])) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill").foregroundColor(.purple)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name).lineLimit(1)
                Text("已下载 \(group.episodes.count) 集").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func playIfDone(_ task: DownloadTask) {
        if task.state == .done, let url = task.outputURL {
            playerItem = PlayerItem(url: url, isHLSFolder: task.isHLSFolder)
        }
    }

    /// 左滑删除的局部下标 -> manager.tasks 全局下标
    private func globalOffsets(_ offsets: IndexSet, in subset: [DownloadTask]) -> IndexSet {
        IndexSet(offsets.compactMap { offset in
            manager.tasks.firstIndex { $0.id == subset[offset].id }
        })
    }
}

/// 剧详情页：该剧全部集（含下载中的），点集播放，左滑删单集，右上角删全剧
struct SeriesDetailView: View {
    @ObservedObject var manager: DownloadManager
    let seriesName: String
    @State private var playerItem: PlayerItem?
    @State private var confirmDelete = false

    private var episodes: [DownloadTask] {
        manager.tasks
            .filter { $0.seriesName == seriesName }
            .sorted { $0.title < $1.title }
    }

    var body: some View {
        List {
            ForEach(episodes) { task in
                TaskRow(task: task, showSeries: false)
                    .contentShape(Rectangle())
                    .onTapGesture { playIfDone(task) }
            }
            .onDelete { offsets in
                for offset in offsets { manager.remove(episodes[offset]) }
            }
        }
        .listStyle(.insetGrouped)
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
        .sheet(item: $playerItem) { item in
            PlayerView(item: item)
        }
    }

    private func playIfDone(_ task: DownloadTask) {
        if task.state == .done, let url = task.outputURL {
            playerItem = PlayerItem(url: url, isHLSFolder: task.isHLSFolder)
        }
    }
}

struct TaskRow: View {
    @ObservedObject var task: DownloadTask
    /// 队列行是否附剧名前缀（剧详情页内不需要）
    var showSeries = true

    private var rowTitle: String {
        if showSeries, let series = task.seriesName { return "\(series) · \(task.title)" }
        return task.title
    }

    var body: some View {
        HStack(spacing: 12) {
            stateIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(rowTitle)
                    .lineLimit(1)
                detailLine
            }
            Spacer()
        }
        .padding(.vertical, 2)
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
            Text(task.isFromLibrary ? "本地文件" : "已保存到 \(task.displayName)")
                .font(.caption).foregroundColor(.secondary)
        case .failed(let message):
            Text("失败: \(message)").font(.caption).foregroundColor(.red)
        }
    }
}

/// 播放：HLS 文件夹 -> 内置本地 HTTP 服务 + AVPlayer 原生 HLS；普通文件 -> 直接播
struct PlayerView: View {
    let item: PlayerItem
    @State private var player: AVPlayer?
    @State private var loadError: String?

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
        .task {
            var url = item.url
            if item.isHLSFolder {
                let playback = await LocalMediaServer.shared.playbackURL(
                    forFolder: item.url.deletingLastPathComponent())
                guard playback.scheme == "http" else {
                    loadError = "本地播放服务启动失败"
                    return
                }
                url = playback
            }
            let avPlayer = AVPlayer(url: url)
            player = avPlayer
            avPlayer.play()
        }
    }
}
