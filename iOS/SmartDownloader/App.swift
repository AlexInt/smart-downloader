import SwiftUI

@main
struct SmartDownloaderApp: App {
    @StateObject private var manager = DownloadManager()
    /// 启动默认落在「下载」tab（tag=1）；浏览页为 tag=0
    @State private var selectedTab = 1
    /// 启动 splash：盖住冷启动（库扫描/本地服务预启），停留 1.2s 后淡出
    @State private var showSplash = true
    /// 防止 onAppear 重复触发自动冒烟（主线程约定，GCD 版无线程标注）
    private static var autoTestStarted = false
    private static var stallProbeStarted = false

    private static func uptimeMs() -> Int { Int(ProcessInfo.processInfo.systemUptime * 1000) }

    /// 主线程卡顿探针（-perfLog 启用）：100ms 心跳，单次 runloop 间隔 >100ms 打一条。
    /// tab 切换卡时靠它定位主线程被谁占住，与 tabSwitch 时间戳对照判读。
    /// 阈值从 250ms 调细到 100ms：可感知的切换卡顿常在 100–200ms，250ms 会漏报。
    private static func startStallProbeIfNeeded() {
        // 兼容 -perfLog / perfLog 两种写法：曾只匹配无横杠的 "perfLog"，
        // 按文档传 "-perfLog" 时探针静默不启动，tab 切换排查拿不到 mainStall
        let enabled = ProcessInfo.processInfo.arguments.contains { $0 == "-perfLog" || $0 == "perfLog" }
        guard enabled, !stallProbeStarted else { return }
        stallProbeStarted = true
        // Timer 挂在主线程 RunLoop，回调与 last 读写同线程，无需锁
        final class LastBox { var value = ProcessInfo.processInfo.systemUptime }
        let last = LastBox()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            let gap = now - last.value
            last.value = now
            if gap > 0.1 {
                print("PERF_DBG mainStall ms=\(Int(gap * 1000)) t=\(Int(now * 1000))")
            }
        }
    }

    init() {
        // 提前启动本地媒体服务（播放 HLS 文件夹时用）
        DispatchQueue.global().async {
            LocalMediaServer.shared.start { _ in }
        }
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
                // splash 停留 1.2s 后淡出（替代旧 .task + Task.sleep）
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeOut(duration: 0.45)) { showSplash = false }
                }
            }
        }
    }

    /// 设备端自动冒烟（真机蜂窝网络下验证 WAF/下载链路，无需手工操作 UI）：
    /// `devicectl ... launch --console ... <bundle> -autoTestDownload <m3u8URL>` 启动即自动下载，
    /// 状态经 print() 输出到控制台（Xcode 控制台 / devicectl --console 均可见）。
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
        // 主线程 500ms 轮询直至任务结束（替代旧 Task + Task.sleep 循环）
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if case .done = task.state {
                    print("AUTOTEST RESULT: DONE -> \(task.outputURL?.path ?? "?")")
                    return
                }
                if case .failed(let message) = task.state {
                    print("AUTOTEST RESULT: FAILED: \(message)")
                    return
                }
                poll()
            }
        }
        poll()
    }
}
