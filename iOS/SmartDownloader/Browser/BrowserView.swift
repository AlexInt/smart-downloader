import SwiftUI
import WebKit

/// 浏览页：WKWebView 加载视频资源网页 + 注入 m3u8 嗅探脚本 + 一键下载按钮
struct BrowserView: View {
    /// 起始页统一由 Browser 域 Service 决策：设置页选中的默认快捷站点 > 上次访问页 > 空白页
    ///（见 Browser/BrowserStartPage.swift，View 层不再碰 UserDefaults）。
    /// 冒烟测试时临时把默认起始页改为 "http://127.0.0.1:8899/test.html"（见 iOS/smoke/ 目录）
    static var initialURLString: String { BrowserStartPage().startURLString }

    /// 快捷站点：地址与显示名都在设置页配置（`QuickLinkStore` 存 key/value 多条），
    /// 站点地址不再写死在代码里；列表超出屏宽可左右滑

    @ObservedObject var manager: DownloadManager
    @Binding var selectedTab: MainTab
    /// 推入剧集详情时置 true，App 据此隐藏自定义 tab bar（保活容器下详情页沉浸式全屏）
    @Binding var detailActive: Bool
    @StateObject private var store = WebViewStore()
    @State private var address = BrowserView.initialURLString == "about:blank" ? "" : BrowserView.initialURLString
    @State private var showPicker = false
    /// 点击剧集（拦截网页路由 / SPA pushState 检测）推入的原生剧集页
    @State private var dramaPageTarget: DramaTarget?
    /// 同一部剧只自动推入一次（SPA 回退后清除，重进会再推）
    @State private var lastAutoDramaKey: String?
    /// 剧集页路由偏好（设置页开关，默认原生）：每次事件现读现判，改动立即生效
    private let routePreferences = DramaRoutePreferences()
    /// 键盘可见时收起底部工具条（App 级 tab bar 同理由 KeyboardObserver 收起）
    @State private var keyboardVisible = KeyboardObserver.shared.isVisible
    @State private var keyboardCancel: (() -> Void)?

    var body: some View {
        NavigationStack {
        VStack(spacing: 0) {
            addressRow
            quickLinkRow

            if let loadError = store.loadError {
                errorLine(loadError)
            }

            // ③ 内容区：WKWebView 本体（外部页面配色不可控，纸本轨只保证周边与占位是同色系）
            WebViewContainer(manager: manager, store: store, address: $address,
                             onDramaLinkClick: { pushDramaPage($0) },
                             onDramaURLDetected: { detectDrama($0, undoSPA: $1) })
                .background(DWColor.paperCanvas)

            if !keyboardVisible {
                // 键盘弹起时整行收起：把这 54pt 让给网页输入区（Safari 同行为）。
                // 不收起的话它和 App 级 tab bar 会一起被顶到键盘上方，白占两层高度
                bottomBar
            }
        }
        // App 层 tab bar 是 safeAreaInset 注入的，但系统只把它自带的 34pt 底部安全区
        // 算进内容区，栏本身 62pt 的实高不会传下来——不在这里显式补，VStack 的底边会
        // 落在屏幕底减 34 处，底部工具条整行被 tab bar 盖住（2026-11-14 实机排障）。
        // 与下载页 / 我的页同一口径（DownloadsView.swift:125 / ProfileView.swift:33）。
        .safeAreaPadding(.bottom, MainTab.barReservedHeight)
        .background(DWColor.paper)
        // 浏览页不占导航条空间；推入的原生剧集页自行 .toolbar(.visible) 恢复
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $dramaPageTarget) { target in
            DramaNativePage(target: target, manager: manager)
        }
        }
        .sheet(isPresented: $showPicker) {
            pickerSheet
        }
        .onChange(of: selectedTab) { _, tab in
            // 切到其它 Tab 时退回首页：回来不再停留在剧集页（下载任务不受影响）
            if tab != .browser {
                dramaPageTarget = nil
                lastAutoDramaKey = nil
            } else {
                // 设置页可能改过快捷站点，回浏览页时重读
                store.refreshQuickLinks()
                // 保活容器下浏览页常驻，onAppear 只在启动触发一次；
                // 回到浏览页时补一次剧集页自动推入（保持每次进入浏览页都推入）
                if let target = DramaTarget.parse(address) {
                    detectDrama(target, undoSPA: false)
                }
            }
        }
        .onChange(of: dramaPageTarget) { _, target in
            detailActive = (target != nil)
        }
        .onChange(of: address) { _, newValue in
            if let target = DramaTarget.parse(newValue) {
                detectDrama(target, undoSPA: false)
            } else {
                // 离开剧集页后清除去重标记：再次进入同一部剧会重新推入
                lastAutoDramaKey = nil
            }
        }
        .onAppear {
            store.refreshQuickLinks()
            // 保活容器下浏览页启动即渲染（可能仍在其它 tab）：只在浏览页活跃时自动推入
            if selectedTab == .browser, let target = DramaTarget.parse(address) { detectDrama(target, undoSPA: false) }
            // 键盘显隐 → 底部工具条收起/恢复（浏览页常驻，onAppear 只触发一次）
            if keyboardCancel == nil {
                keyboardCancel = KeyboardObserver.shared.observe { visible in
                    print("BROWSER: keyboard=\(visible) → bottomBar \(visible ? "hidden" : "shown")")
                    keyboardVisible = visible
                }
            }
        }
    }

    // MARK: - ① 地址栏行（画布 22:296，h52 / pad 10 / gap 8）

    /// 输入框 34 高 + 访问按钮 54×34，两侧各留 9 → 行高 52（画布 22:296 固定 52）
    private var addressRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                PaperLockShape()
                    .stroke(DWColor.paperInkSub,
                            style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    .frame(width: 12, height: 12)

                TextField("", text: $address,
                          prompt: Text("输入网址").foregroundStyle(DWColor.paperFaint))
                    .font(DWFont.cn(12))
                    .foregroundStyle(DWColor.paperInk)
                    .tint(DWColor.paperCinnabar)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .submitLabel(.go)
                    .onSubmit { store.load(address) }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DWColor.paperField))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(DWColor.paperFieldLine.opacity(0.8), lineWidth: 1)
            }

            Button {
                store.load(address)
            } label: {
                Text("访问")
                    .font(DWFont.cn(12, .medium))
                    .foregroundStyle(DWColor.paper)
                    .frame(width: 54, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DWColor.paperInk))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(height: 52)
    }

    // MARK: - ② 快捷站点行（画布 22:304，h44 / pad 10 / gap 8，横向可滑）

    private var quickLinkRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.quickLinks) { link in
                    Button {
                        address = link.url
                        store.load(link.url)
                    } label: {
                        HStack(spacing: 4) {
                            PaperScreenShape()
                                .stroke(DWColor.paperIcon,
                                        style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                                .frame(width: 12, height: 12)
                            Text(link.name)
                                .font(DWFont.cn(10, .medium))
                                .foregroundStyle(DWColor.paperInk)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DWColor.paperField))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(DWColor.paperFieldLine.opacity(0.9), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                // 22:320 行尾「›」：站点过多时提示还能继续右滑，跟着列表一起滑走
                Text("›")
                    .font(DWFont.en(14))
                    .foregroundStyle(DWColor.paperInkSub)
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .frame(height: 44)
    }

    // MARK: - ④ 底部工具栏（画布 22:327，h54 / pad 10 / gap 18）

    /// 后退/前进是 20×20 命中框里的 1pt 线稿；不可点时转纸本最弱一档（画布 22:331）。
    /// 刷新不走 navGlyph：画布 22:332 是**实心填充**形（见 PaperReloadShape 注释），
    /// 用 .stroke 描一遍会得到一圈细线，与设计稿的粗弧带完全不是一个东西。
    private var bottomBar: some View {
        HStack(spacing: 18) {
            navGlyph(PaperChevronShape(pointsLeft: true), size: CGSize(width: 6.5, height: 13),
                     xOffset: -0.75, enabled: store.canGoBack) { store.goBack() }
            navGlyph(PaperChevronShape(pointsLeft: false), size: CGSize(width: 6.5, height: 13),
                     xOffset: 0.75, enabled: store.canGoForward) { store.goForward() }
            reloadGlyph

            Spacer(minLength: 0)

            Button {
                if manager.foundURLs.count > 1 {
                    showPicker = true
                } else {
                    store.beginDownload(from: manager.foundURLs.first, manager: manager)
                }
            } label: {
                HStack(spacing: 6) {
                    PaperBadgeArrowShape()
                        .stroke(DWColor.paper,
                                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                        .frame(width: 14, height: 14)
                    Text(downloadButtonTitle)
                        .font(DWFont.cn(11, .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(DWColor.paper)
                .frame(width: 132, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(canDownload ? DWColor.paperInk : DWColor.paperLineIdle))
            }
            .buttonStyle(.plain)
            .disabled(!canDownload)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(height: 54)
        // 网页底色千奇百怪（这页是白底、下一页可能是深色），工具栏必须自带纸底，
        // 否则网页内容会从图标背后透出来
        .background(DWColor.paper)
        // 与 App 级 tab bar 同一条发丝线：下面贴着网页时靠它分界
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DWColor.paperHairline)
                .frame(height: 0.5)
        }
    }

    /// 刷新（画布 22:332）：实心填充形，20×20 就是画布原始坐标，不要再套 frame 缩放
    private var reloadGlyph: some View {
        Button { store.reload() } label: {
            PaperReloadShape()
                .fill(DWColor.paperInk)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 后退/前进：20×20 命中框里的 1pt 线稿，不可点时转纸本最弱一档（画布 22:331）。
    ///
    /// `size` 是**中心线框**（画布节点对描边图元报的就是几何框，不是墨迹框）：6.5×13 加
    /// 1.2 描边后墨迹约 7.7×14.2，与设计稿实测的 8.0×14.5（含抗锯齿）对得上。
    /// `xOffset` 是设计稿的光学居中：两个箭头各向外偏 0.75（后退中心线 x=6、前进 x=7.5，
    /// 而框心居中会是 6.75）——去掉这 0.75 与画布做像素 diff 会整条笔画错位。
    private func navGlyph<S: Shape>(_ shape: S, size: CGSize, xOffset: CGFloat = 0, enabled: Bool,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            shape
                .stroke(enabled ? DWColor.paperInk : DWColor.paperFaint,
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .frame(width: size.width, height: size.height)
                .offset(x: xOffset)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func errorLine(_ message: String) -> some View {
        Text(message)
            .font(DWFont.cn(11))
            .foregroundStyle(DWColor.paperCinnabar)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DWLayout.pageEdge)
            .padding(.bottom, 6)
    }

    private var canDownload: Bool {
        !manager.foundURLs.isEmpty && !store.isSubmitting && !singleURLAlreadyQueued
    }

    /// 检测到剧集页 URL：推入原生剧集页；SPA pushState 无法取消，undoSPA 时回退网页到列表页。
    /// 设置页「打开 Web 剧集页」开启时不推（网页自己展示），也不回退——让网页停在剧集页
    private func detectDrama(_ target: DramaTarget, undoSPA: Bool) {
        guard !routePreferences.useWebDramaPage else {
            print("BROWSER: 检测到剧集页 -> \(target.id) SKIP 推原生页（Web 剧集页模式）")
            return
        }
        // 保活容器下浏览页常驻底层：非浏览 tab（如启动时在下载/设置 tab）不自动推入，
        // 避免详情页盖住其它页；回到浏览 tab 时由 onChange(of: selectedTab) 补推
        guard selectedTab == .browser else { return }
        guard lastAutoDramaKey != target.id else { return }
        lastAutoDramaKey = target.id
        dramaPageTarget = target
        print("BROWSER: 检测到剧集页 -> \(target.id) 推入原生剧集页")
        if undoSPA, store.webView?.canGoBack == true {
            store.webView?.goBack()
        }
    }

    /// 用户点击剧集链接（路由已在 decidePolicy 取消）：每次点击都推入原生剧集页
    private func pushDramaPage(_ target: DramaTarget) {
        dramaPageTarget = target
        print("BROWSER: 点击剧集 -> \(target.id) 推入原生剧集页")
    }

    /// m3u8 候选面板：同一页嗅到多条流时让用户挑一条。
    /// 纸本语言（衬线标题 + 细线 + 朱砂勾），不用系统 List 的灰底圆角块
    private var pickerSheet: some View {
        VStack(spacing: 0) {
            Text("选择 m3u8")
                .font(DWFont.serif(17, .medium))
                .foregroundStyle(DWColor.paperInk)
                .frame(maxWidth: .infinity)
                .frame(height: 56)

            Rectangle().fill(DWColor.paperDivider).frame(height: 1)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(manager.foundURLs, id: \.self) { found in
                        let queued = manager.hasActiveTask(forURL: found)
                        Button {
                            showPicker = false
                            store.beginDownload(from: found, manager: manager)
                        } label: {
                            HStack(spacing: 10) {
                                Text(found)
                                    .font(DWFont.cn(11))
                                    .foregroundStyle(queued ? DWColor.paperLineIdle : DWColor.paperInk)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if queued {
                                    Text("已在队列")
                                        .font(DWFont.cn(10))
                                        .foregroundStyle(DWColor.paperInkSub)
                                } else {
                                    PaperChevronShape(pointsLeft: false)
                                        .stroke(DWColor.paperLineIdle,
                                                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                                        .frame(width: 6, height: 11)
                                }
                            }
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(queued)

                        Rectangle()
                            .fill(DWColor.paperRule)
                            .frame(height: 1)
                    }
                }
                .padding(.horizontal, DWLayout.edge)
            }

            Spacer(minLength: 0)
        }
        .background(DWColor.paper.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var singleURLAlreadyQueued: Bool {
        guard manager.foundURLs.count == 1, let url = manager.foundURLs.first else { return false }
        return manager.hasActiveTask(forURL: url)
    }

    private var downloadButtonTitle: String {
        if manager.foundURLs.isEmpty { return "未检测到视频" }
        if store.isSubmitting { return "正在添加…" }
        if singleURLAlreadyQueued { return "已在下载队列" }
        return "下载视频 (\(manager.foundURLs.count))"
    }
}

struct WebViewContainer: UIViewRepresentable {
    @ObservedObject var manager: DownloadManager
    @ObservedObject var store: WebViewStore
    @Binding var address: String
    /// 用户点击剧集链接（路由已在 decidePolicy 取消后回调，每次点击必回调）
    var onDramaLinkClick: (DramaTarget) -> Void = { _ in }
    /// URL 变为剧集页（SPA pushState 或提交完成）时回调 (target, undoSPA)
    var onDramaURLDetected: (DramaTarget, Bool) -> Void = { _, _ in }
    /// 主浏览页 = true：注册 WebKit 兕底宿主 + 持久化最后访问页；剧集内嵌页 = false
    var isPrimaryBrowser = true
    /// 起始加载地址；nil = 主浏览页恢复上次访问页
    var initialURL: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = config.userContentController
        // 与 mac_app/sniffer.js 同源逻辑：Hook XHR/fetch + performance 历史 + DOM 扫描
        controller.addUserScript(
            WKUserScript(source: SnifferScript.source,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        controller.add(context.coordinator, name: "sniffer")
        // 广告弹窗清理：删除/候选经 adClean 消息回传原生日志，靠日志调优词表
        controller.addUserScript(
            WKUserScript(source: AdCleanerScript.source,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        controller.add(context.coordinator, name: "adClean")

        // 滑动网页收键盘：SPA 在内部容器滚动时 keyboardDismissMode 不生效，
        // 改由页面手势上报（见 KeyboardDismissScript）
        controller.addUserScript(
            WKUserScript(source: KeyboardDismissScript.source,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        controller.add(context.coordinator, name: "keyboardDismiss")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        // 键盘弹出后，下滑网页即可把键盘带走（Safari 同行为）。用 .interactive 而不是
        // .onDrag：键盘跟手一起下落，松手没过半会弹回，手感更接近系统网页；
        // 键盘收起时 KeyboardObserver 会自动把 tab bar / 底部工具条恢复
        webView.scrollView.keyboardDismissMode = .interactive
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        store.webView = webView
        let startURLString = initialURL ?? BrowserView.initialURLString
        print("BROWSER: 初始加载 -> \(startURLString)")
        // SPA 站点用 pushState 换页时不会触发 didCommit：KVO 跟踪主帧 URL，
        // 地址栏与剧集页路由检测才能跟上
        context.coordinator.urlObservation = webView.observe(\.url, options: [.new]) { [weak coordinator = context.coordinator] view, _ in
            // WKWebView.url KVO 固定主线程回调
            guard let coordinator else { return }
            let current = view.url?.absoluteString ?? ""
            print("BROWSER: url -> \(current)")
            // URL 变成剧集页（SPA pushState 或提交）：回调宿主决策（推原生页/回退列表）
            if let target = DramaTarget.parse(current) {
                coordinator.parent.onDramaURLDetected(target, !view.isLoading)
            }
            coordinator.parent.address = current
        }
        // WebKit 兜底通道宿主仅主浏览页注册（剧集内嵌 webview 不抢宿主）
        if isPrimaryBrowser {
            WebKitFetcher.shared.setHostWebView(webView)
        }
        if let first = URL(string: startURLString) {
            webView.load(URLRequest(url: first))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // WebKit 在某些加载阶段会把 scrollView 的 keyboardDismissMode 重置，
        // 每次更新补一次（文档本身可滚的站点靠它，内部容器滚动靠 KeyboardDismissScript）
        if uiView.scrollView.keyboardDismissMode != .interactive {
            uiView.scrollView.keyboardDismissMode = .interactive
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "sniffer")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "adClean")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "keyboardDismiss")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: WebViewContainer
        private var lastMainURL: URL?
        /// 剧集页路由偏好：决策时现读 UserDefaults，设置页改动立即生效
        private let routePreferences = DramaRoutePreferences()
        private var provisionalRetries = 0
        /// 主帧 URL KVO（SPA pushState 换页不触发 didCommit，靠它同步地址栏/剧集页检测）
        var urlObservation: NSKeyValueObservation?
        /// 起始页（默认站点或上次访问页）尚未成功 commit 过；首次加载失败则清掉上次访问页记录
        private var isInitialLoad = true
        init(_ parent: WebViewContainer) { self.parent = parent }

        // JS -> 原生：嗅探到 m3u8（消息回调固定在主线程）；adClean = 广告清理回传
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "adClean", let text = message.body as? String {
                print("BROWSER: adClean \(text)")
                return
            }
            if message.name == "keyboardDismiss" {
                // 页面里滑动带走键盘。两种键盘都要收：
                //  ① 网页输入框拉起的（第一响应者在 WKWebView 内部）→ endEditing
                //  ② 原生地址栏 TextField 拉起的（第一响应者不在 webview）→ 全局 resign
                // 两者都尝试，幂等且成本极低；无键盘时不打日志也不做无用功。
                let kind = (message.body as? String) ?? "?"
                let keyboardOn = KeyboardObserver.shared.isVisible
                let webView = parent.store.webView
                let dismissed = webView?.endEditing(true) ?? false
                if keyboardOn {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
                print("BROWSER: keyboardDismiss from \(kind) keyboardOn=\(keyboardOn) webEndEditing=\(dismissed)")
                return
            }
            guard message.name == "sniffer", let urlString = message.body as? String else { return }
            parent.manager.recordFound(urlString: urlString)
            if let current = parent.store.webView?.url?.absoluteString {
                parent.address = current
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame?.isMainFrame == true {
                lastMainURL = navigationAction.request.url
                // 用户点击剧集链接：路由到原生剧集页，网页本体不加载该页。
                // 「打开 Web 剧集页」开启时不拦截，网页正常加载剧集页
                if navigationAction.navigationType == .linkActivated,
                   let target = DramaTarget.parse(navigationAction.request.url?.absoluteString ?? "") {
                    if routePreferences.useWebDramaPage {
                        print("BROWSER: 点击剧集 -> \(target.id) 放行（Web 剧集页模式）")
                        decisionHandler(.allow)
                        return
                    }
                    parent.onDramaLinkClick(target)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            provisionalRetries = 0
            isInitialLoad = false
            parent.store.loadError = nil
            // 前进/后退箭头可用性跟着导航栈走（画布 22:329/331）
            parent.store.refreshNavigationState()
            print("BROWSER: didCommit \(webView.url?.absoluteString ?? "?")")
            if let current = webView.url?.absoluteString {
                if parent.isPrimaryBrowser {
                    BrowserStartPage().lastVisitedURL = current
                }
                parent.address = current
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.store.refreshNavigationState()
            webView.evaluateJavaScript("document.title") { result, _ in
                guard let title = result as? String, !title.isEmpty else { return }
                self.parent.store.pageTitle = title
            }
            // 调查：提取页面元数据（og:image/标题/简介/图片列表），立即 + 3秒后（SPA 渲染滞后）各一次
            extractMeta(webView, delay: 0)
            extractMeta(webView, delay: 3)
        }

        /// 调查用：从 DOM 提取短剧元数据，写入 store（页面头部展示 + DramaMeta 落盘）并写系统日志
        func extractMeta(_ webView: WKWebView, delay: Double) {
            let js = """
            (function(){
              var q = function(sel){ var el = document.querySelector(sel); return el ? (el.content || el.src || el.getAttribute('content') || '') : ''; };
              var imgs = [];
              var nodes = document.querySelectorAll('img');
              for (var i = 0; i < nodes.length && i < 40; i++) { var s = nodes[i].currentSrc || nodes[i].src; if (s) imgs.push(s); }
              return JSON.stringify({
                url: location.href,
                title: document.title || '',
                ogImage: q('meta[property="og:image"]') || q('meta[name="twitter:image"]'),
                ogTitle: q('meta[property="og:title"]'),
                keywords: q('meta[name="keywords"]'),
                desc: q('meta[name="description"]') || q('meta[property="og:description"]'),
                imgs: imgs,
                text: (document.body.innerText || '').replace(/\\s+/g,' ').slice(0, 500)
              });
            })()
            """
            let extract = { [weak self] in
                webView.evaluateJavaScript(js) { result, _ in
                    guard let self,
                          let result = result as? String,
                          let data = result.data(using: .utf8),
                          (try? JSONSerialization.jsonObject(with: data)) != nil else { return }
                    self.parent.store.pageMetaJSON = result
                    // 调查收敛（2026-11-11）：DRAMAMETA-DOM 逐 key 的 NSLog 双份输出删除——
                    // 动态串被统一日志 <private> 脱敏看不到内容，纯噪音；字段内容看落盘文件
                    //（harvest_<site>_<dramaID>.json，见 DramaMetaHarvester）
                    print("BROWSER: extractMeta ok delay=\(delay) bytes=\(result.count)")
                }
            }
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: extract)
            } else {
                extract()
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            // TLS 被担/网络抖动时自动重试（WAF 拦截有时是间歇性的）
            let code = (error as NSError).code
            let retryable: Set<Int> = [
                NSURLErrorSecureConnectionFailed,   // -1200 TLS/安全连接失败
                NSURLErrorNetworkConnectionLost,    // -1005
                NSURLErrorTimedOut,                 // -1001
                NSURLErrorCannotConnectToHost,      // -1004
                NSURLErrorNotConnectedToInternet,   // -1009 蜂窝网络瞬断
            ]
            if retryable.contains(code), provisionalRetries < 2, let url = lastMainURL {
                provisionalRetries += 1
                parent.store.loadError = "连接被重置，自动重试 \(provisionalRetries)/2…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    webView.load(URLRequest(url: url))
                }
                return
            }
            // 起始页首次加载就失败：清掉「上次访问页」记录，避免回落路径反复卡在同一坏地址。
            // 默认站点是用户在设置里显式选的，不自动取消（静默改设置更糟），只在提示里让用户去检查。
            if isInitialLoad && parent.isPrimaryBrowser {
                isInitialLoad = false
                BrowserStartPage().lastVisitedURL = nil
                parent.store.loadError = "\(error.localizedDescription)（起始页无法打开，请到设置检查默认站点或直接输入网址）"
                print("BROWSER: 起始页加载失败，已重置上次访问页记录")
                return
            }
            parent.store.loadError = error.localizedDescription
            print("BROWSER: 加载失败 code=\((error as NSError).code) url=\(lastMainURL?.absoluteString ?? "?") msg=\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.store.loadError = error.localizedDescription
            print("BROWSER: 加载失败(后段) code=\((error as NSError).code) url=\(webView.url?.absoluteString ?? "?") msg=\(error.localizedDescription)")
        }
    }

}
