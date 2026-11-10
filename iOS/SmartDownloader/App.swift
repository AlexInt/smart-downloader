import SwiftUI

@main
struct SmartDownloaderApp: App {
    @StateObject private var manager = DownloadManager()

    init() {
        // 提前启动本地媒体服务（播放 HLS 文件夹时用）
        Task.detached { await LocalMediaServer.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                BrowserView(manager: manager)
                    .tabItem { Label("浏览", systemImage: "compass") }
                DownloadsView(manager: manager)
                    .tabItem { Label("下载", systemImage: "arrow.down.circle") }
            }
        }
    }
}
