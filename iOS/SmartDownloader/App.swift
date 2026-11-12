import SwiftUI
import Synchronization

@main
struct SmartDownloaderApp: App {
    @StateObject private var manager = DownloadManager()
    /// 启动默认落在「下载」tab（tag=1）；浏览页为 tag=0
    @State private var selectedTab = 1
    /// 启动 splash：盖住冷启动（库扫描/本地服务预启），停留 1.2s 后淡出
    @State private var showSplash = true
    /// 防止 onAppear 重复触发自动冒烟
    @MainActor private static var autoTestStarted = false
    @MainActor private static var stallProbeStarted = false

    private static func uptimeMs() -> Int { Int(ProcessInfo.processInfo.systemUptime * 1000) }

    /// 主线程卡顿探针（-perfLog 启用）：100ms 心跳，单次 runloop 间隔 >250ms 打一条。
    /// tab 切换卡时靠它定位主线程被谁占住，与 tabSwitch 时间戳对照判读。
    @MainActor
    private static func startStallProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("perfLog"), !stallProbeStarted else { return }
        stallProbeStarted = true
        // Timer 回调是 @Sendable，局部可变状态必须显式同步；用 Mutex 表达所有权
        let last = Mutex(ProcessInfo.processInfo.systemUptime)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            let gap = last.withLock { previous -> TimeInterval in
                let delta = now - previous
                previous = now
                return delta
            }
            if gap > 0.25 {
                print("PERF_DBG mainStall ms=\(Int(gap * 1000)) t=\(Int(now * 1000))")
            }
        }
    }

    init() {
        // 提前启动本地媒体服务（播放 HLS 文件夹时用）
        Task.detached { await LocalMediaServer.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                TabView(selection: $selectedTab) {
                    BrowserView(manager: manager, selectedTab: $selectedTab)
                        .tabItem { Label("浏览", systemImage: "safari.fill") }
                        .tag(0)
                    DownloadsView(manager: manager)
                        .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                        .tag(1)
                }
                // 系统 launch screen（渐变图）→ 同色系 splash（logo 呼吸）→ 淡出进 App
                if showSplash {
                    LaunchSplashView()
                        .transition(.opacity)
                        .zIndex(1)
                        // 纯装饰不拦截触摸：splash 期间 tab 点击照常响应
                        //（曾盖住 tab bar 1.2s+淡出，慢机首帧晚 → 点击死区被报「切换卡」）
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: selectedTab) { old, new in
                print("PERF_DBG tabSwitch \(old)->\(new) t=\(Self.uptimeMs())")
            }
            .onAppear {
                Self.runDeviceAutoTest(manager: manager)
                Self.startStallProbeIfNeeded()
            }
            .task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation(.easeOut(duration: 0.45)) { showSplash = false }
            }
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
