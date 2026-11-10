import SwiftUI

@main
struct SmartDownloaderApp: App {
    @StateObject private var manager = DownloadManager()
    @State private var selectedTab = 0
    /// 防止 onAppear 重复触发自动冒烟
    @MainActor private static var autoTestStarted = false

    init() {
        // 提前启动本地媒体服务（播放 HLS 文件夹时用）
        Task.detached { await LocalMediaServer.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                BrowserView(manager: manager, selectedTab: $selectedTab)
                    .tabItem { Label("浏览", systemImage: "safari.fill") }
                    .tag(0)
                DownloadsView(manager: manager)
                    .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                    .tag(1)
            }
            .onAppear { Self.runDeviceAutoTest(manager: manager) }
        }
    }

    /// 设备端自动冒烟（真机蜂窝网络下验证 WAF/下载链路，无需手工操作 UI）：
    /// `devicectl ... launch --console ... <bundle> -autoTestDownload <m3u8URL>` 启动即自动下载，
    /// 状态经 print() 输出到控制台（Xcode 控制台 / devicectl --console 均可见）。
    @MainActor
    private static func runDeviceAutoTest(manager: DownloadManager) {
        guard !autoTestStarted else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-autoTestDownload"), arguments.count > index + 1 else {
            return
        }
        autoTestStarted = true
        let url = arguments[index + 1]
        print("AUTOTEST: 开始自动下载 -> \(url)")
        let task = manager.startDownload(urlString: url, title: "autotest")
        Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if case .done = task.state {
                    print("AUTOTEST RESULT: DONE -> \(task.outputURL?.path ?? "?")")
                    return
                }
                if case .failed(let message) = task.state {
                    print("AUTOTEST RESULT: FAILED: \(message)")
                    return
                }
            }
        }
    }
}
