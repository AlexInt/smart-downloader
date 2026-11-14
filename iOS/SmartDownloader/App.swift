import SwiftUI

/// 统一毫秒时钟：ProcessInfo.systemUptime，与 stallProbe 的 t= / tabSwitch t= 同一坐标系，
/// 各处 PERF_DBG 探针用它对齐时间线（排障期先对齐再判读，不各用各的钟）。
/// 顶层 enum（App struct 内嵌套外部文件取不到），module 内可见
enum PERF {
    static func ms() -> Int { Int(ProcessInfo.processInfo.systemUptime * 1000) }
}

@main
struct SmartDownloaderApp: App {
    @StateObject private var manager: DownloadManager
    /// 下载页两个 VM 提升到 App 级（2026-11-14 主线程卡顿修复）：
    /// DownloadsView 挂在 ZStack 的 `if selectedTab == .downloads` 下，切 tab 即销毁重建，
    /// VM 级缓存（磁盘占用 episodeSizeCache / 剧身份 seriesCache）随实例一起丢——
    /// 每次切 tab 都要全量重扫 97 集盘 + 全量 SQLite 读（日志里 episodesReused=0
    /// episodesScanned=97 每次切 tab 重现的直接原因）。App 级持有后缓存跨切换存活，
    /// 重算只扫新增/变更的集，剧身份也只查一次。
    @StateObject private var downloadsVM: DownloadsViewModel
    @StateObject private var progressVM = PlaybackProgressViewModel()
    /// 启动落在哪个 tab 由设置页配置（`AppLaunchPreferences`），Service 内部默认「下载」；
    /// 浏览页必须保持 tag 最小（.browser = 0），它是保活容器的底层
    @State private var selectedTab: MainTab = AppLaunchPreferences().launchTab
    /// 启动 splash：盖住冷启动（库扫描/本地服务预启），停留 1.2s 后淡出
    @State private var showSplash = true
    /// 浏览页推入剧集详情时隐藏自定义 tab bar（详情页沉浸式全屏）
    @State private var browserDetailActive = false
    /// 「我的」页推入二级页（设置页 / 剧集页）时隐藏自定义 tab bar（同一口径）
    @State private var profileDetailActive = false
    /// 键盘可见时收起 tab bar：系统会把底部安全区顶上来，tab bar 会被顶到键盘上方，
    /// 既挡网页内容又白吃一层高度（用户实报 2026-11-14）
    @State private var keyboardVisible = KeyboardObserver.shared.isVisible
    /// 键盘订阅取消闭包（App 生命周期内不用摘，留着便于将来热重载/测试）
    @State private var keyboardCancel: (() -> Void)?
    /// 防止 onAppear 重复触发自动冒烟（主线程约定，GCD 版无线程标注）
    private static var autoTestStarted = false
    private static var stallProbeStarted = false
    #if DEBUG
    /// 剧集页纸本样张（启动参数 `-dramaPreview`）：模拟器点不了/滑不了，
    /// 纸本轨想"看一眼"只能靠这么个入口直接落到目标页。Release 不编译。
    @State private var showDramaPreview = false
    private static var dramaPreviewShown = false
    #endif

    private static func uptimeMs() -> Int { PERF.ms() }

    init() {
        let managerInstance = DownloadManager()
        _manager = StateObject(wrappedValue: managerInstance)
        _downloadsVM = StateObject(wrappedValue: DownloadsViewModel(manager: managerInstance))
        // 提前启动本地媒体服务（播放 HLS 文件夹时用）
        DispatchQueue.global().async {
            LocalMediaServer.shared.start { _ in }
        }
    }

    /// 主线程卡顿探针：20ms 心跳，单次 runloop 间隔 >100ms 打一条（真实卡顿）。
    /// tab 切换卡时靠它定位主线程被谁占住，与 tabSwitch 时间戳对照判读。
    /// 心跳必须远小于阈值：否则正常调度抖动就超阈、刷屏假阳性（100ms 心跳配 100ms 阈值会
    /// 每个心跳误报 ms=100）；20ms 心跳下正常 gap≈20ms，>100ms 才是真卡顿。
    /// Debug 默认开启（真机排障无需记参数）；Release 仍需 -perfLog 显式启用。
    private static func startStallProbeIfNeeded() {
        // 曾靠 -perfLog 门控，但多次复测都没传参/没启用，拿不到 mainStall——改为 Debug 常开。
        // 兼容 -perfLog / perfLog 两种写法（横杠与否都可能传）
        #if DEBUG
        let enabled = true
        #else
        let enabled = ProcessInfo.processInfo.arguments.contains { $0 == "-perfLog" || $0 == "perfLog" }
        #endif
        guard enabled, !stallProbeStarted else { return }
        stallProbeStarted = true
        // 自检日志：日志开头有这行即证明探针已启用
        print("PERF_DBG stallProbe enabled heartbeat=20ms threshold=100ms")
        // Timer 挂在主线程 RunLoop，回调与 last 读写同线程，无需锁
        final class LastBox { var value = ProcessInfo.processInfo.systemUptime }
        let last = LastBox()
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            let gap = now - last.value
            last.value = now
            if gap > 0.1 {
                print("PERF_DBG mainStall ms=\(Int(gap * 1000)) t=\(Int(now * 1000))")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // 保活容器：浏览页常驻底层（WKWebView 一直在窗口内可见，不触发离屏挂起/图层回收），
                // 下载页按需以不透明背景盖上去。切 tab 只改可见性、不藏 WKWebView → 切回零唤醒卡顿。
                //（旧 SwiftUI TabView 会藏起非活跃 tab，WKWebView 离屏被回收，切回唤醒阻塞主线程 300ms–1s）
                ZStack {
                    BrowserView(manager: manager, selectedTab: $selectedTab,
                                detailActive: $browserDetailActive)
                        .allowsHitTesting(selectedTab == .browser)
                    if selectedTab == .downloads {
                        DownloadsView(manager: manager, vm: downloadsVM, progressVM: progressVM)
                            .background(DWColor.paper.ignoresSafeArea())
                    }
                    if selectedTab == .settings {
                        // 「我的」页（画布 19:63 纸本）：封面墙聚合历史/收藏/追更/点赞，
                        // 设置降为二级页（身份行齿轮推入）。改了快捷站点/启动 tab，
                        // 都在下次切回浏览页或冷启动时生效
                        ProfileView(manager: manager, detailActive: $profileDetailActive)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if !browserDetailActive && !profileDetailActive && !keyboardVisible {
                        mainTabBar
                    }
                }
                // 纸底统一在容器上铺满（2026-11-14）：三页都是宣纸底，各页再各自
                // `.background(...ignoresSafeArea())` 会把顶部安全区一起吃掉，
                // 页面自身的根视图于是多拿到一个状态栏高度、底边溢出到 tab bar 后面
                //（浏览页底部工具条整行被 tab bar 盖住，就是这么丢的）
                .background(DWColor.paper.ignoresSafeArea())
                #if DEBUG
                .fullScreenCover(isPresented: $showDramaPreview) {
                    DramaPreviewHost(manager: manager)
                }
                #endif
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
                // 「我的」页离开时它会被 ZStack 销毁（if selectedTab == .settings），
                // path 随之丢失但 detailActive 是 App 级状态——不复位会让 tab bar 永久隐藏
                if new != .settings && profileDetailActive {
                    print("PROFILE_DBG tabSwitch 离开我的页 → 复位 tabBar")
                    profileDetailActive = false
                }
            }
            .onAppear {
                Self.runDeviceAutoTest(manager: manager)
                Self.startStallProbeIfNeeded()
                // 键盘显隐 → tab bar 收起/恢复（Service 统一入口，View 只做可见性）
                if keyboardCancel == nil {
                    keyboardCancel = KeyboardObserver.shared.observe { visible in
                        print("UI_DBG tabBar keyboard=\(visible) → \(visible ? "hidden" : "shown")")
                        keyboardVisible = visible
                    }
                }
                // splash 停留 1.2s 后淡出
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeOut(duration: 0.45)) { showSplash = false }
                }
                #if DEBUG
                // 样张要在 splash 之后弹，否则截到的是启动图盖住的样子
                if ProcessInfo.processInfo.arguments.contains("-dramaPreview"),
                   !Self.dramaPreviewShown {
                    Self.dramaPreviewShown = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showDramaPreview = true
                    }
                }
                #endif
            }
        }
    }

    /// 自定义底部 tab bar（替代系统 TabView 的 tab bar，配合保活容器）
    /// 视觉与配色都在 `MainTabBar` 里。
    private var mainTabBar: some View {
        MainTabBar(selectedTab: $selectedTab)
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
        // 主线程 500ms 轮询直至任务结束
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

// MARK: - 底部标签栏

/// 底部标签栏（画布 19:225 / 22:157）：图标 22 + 文字 fs10 + 朱砂选中点 4×4。
///
/// 2026-11-14 起全 App 只剩**纸本单轨**（浏览/下载/我的三页都改成了宣纸底，
/// 见画布 22:284 / 2:2 / 19:63），因此栏底恒为纸，不再跟系统外观走：
/// 原先「深色外观下栏压墨」的双轨规则在这三页都变纸之后只会造成一屏里深浅两截。
/// 页面色值都是写死的十六进制，深色外观下同样是宣纸底，故栏也必须恒纸。
struct MainTabBar: View {
    @Binding var selectedTab: MainTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases) { tab in
                item(tab)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        // 栏底铺到屏幕底边（否则 Home 指示条那条会露出页面底色）
        .background(DWColor.paper.ignoresSafeArea(edges: .bottom))
        // 纸本轨加一条发丝线：下面是白底网页时靠它分界
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DWColor.paperHairline)
                .frame(height: 0.5)
        }
        .background {
            GeometryReader { geo in
                Color.clear.onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        print("UI_DBG tabBar frame=\(geo.frame(in: .global)) safeBottom=\(geo.safeAreaInsets.bottom)")
                    }
                }
            }
        }
    }

    private func item(_ tab: MainTab) -> some View {
        let selected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 22, weight: selected ? .medium : .regular))
                    .frame(height: 22)
                Text(tab.title)
                    .font(.system(size: 10, weight: selected ? .medium : .regular))
                // 画布 22:162：朱砂选中点 4×4；未选中也占位，否则选中态文字会上下跳
                Circle()
                    .fill(selected ? DWColor.paperCinnabar : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(selected ? DWColor.paperInk : DWColor.paperInkSub)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
