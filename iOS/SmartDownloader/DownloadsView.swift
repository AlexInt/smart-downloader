import SwiftUI
import AVKit

struct PlayerItem: Identifiable {
    let id = UUID()
    let url: URL
    let isHLSFolder: Bool
}

/// 下载列表：进度实时刷新，点击已完成条目直接播放，左滑删除（同时删沙盒文件/文件夹）
struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    @State private var playerItem: PlayerItem?

    var body: some View {
        NavigationStack {
            Group {
                if manager.tasks.isEmpty {
                    ContentUnavailableView("暂无下载",
                                           systemImage: "arrow.down.circle",
                                           description: Text("去「浏览」页打开视频网页，点击「下载视频」"))
                } else {
                    List {
                        ForEach(manager.tasks) { task in
                            TaskRow(task: task)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if task.state == .done, let url = task.outputURL {
                                        playerItem = PlayerItem(url: url, isHLSFolder: task.isHLSFolder)
                                    }
                                }
                        }
                        .onDelete { manager.delete(at: $0) }
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
}

struct TaskRow: View {
    @ObservedObject var task: DownloadTask

    var body: some View {
        HStack(spacing: 12) {
            stateIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
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
