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
            HStack(spacing: 8) {
                TextField("输入网址", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .onSubmit { store.load(address) }
                Button("访问") { store.load(address) }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            // 快捷站点标签行（横向滑动，条目由设置页配置）
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.quickLinks) { link in
                        Button {
                            address = link.url
                            store.load(link.url)
                        } label: {
                            Label(link.name, systemImage: "play.tv")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            if let loadError = store.loadError {
                Text("⚠️ 网页加载失败: \(loadError)")
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
            }

            WebViewContainer(manager: manager, store: store, address: $address,
                             onDramaLinkClick: { pushDramaPage($0) },
                             onDramaURLDetected: { detectDrama($0, undoSPA: $1) })

            if !keyboardVisible {
                // 键盘弹起时整行收起：把这 56pt 让给网页输入区（Safari 同行为）。
                // 不收起的话它和 App 级 tab bar 会一起被顶到键盘上方，白占两层高度
                HStack(spacing: 18) {
                    Button { store.goBack() } label: { Image(systemName: "chevron.left") }
                    Button { store.goForward() } label: { Image(systemName: "chevron.right") }
                    Button { store.reload() } label: { Image(systemName: "arrow.clockwise") }
                    Spacer()
                    Button {
                        if manager.foundURLs.count > 1 {
                            showPicker = true
                        } else {
                            store.beginDownload(from: manager.foundURLs.first, manager: manager)
                        }
                    } label: {
                        Label(downloadButtonTitle, systemImage: downloadButtonIcon)
                    }
                    .disabled(manager.foundURLs.isEmpty || store.isSubmitting || singleURLAlreadyQueued)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
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

    private var pickerSheet: some View {
        NavigationStack {
            List(manager.foundURLs, id: \.self) { found in
                Button {
                    showPicker = false
                    store.beginDownload(from: found, manager: manager)
                } label: {
                    HStack(spacing: 8) {
                        Text(found).font(.footnote).lineLimit(2)
                        Spacer(minLength: 0)
                        if manager.hasActiveTask(forURL: found) {
                            Label("已在队列", systemImage: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .disabled(manager.hasActiveTask(forURL: found))
            }
            .navigationTitle("选择 m3u8")
            .navigationBarTitleDisplayMode(.inline)
        }
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

    private var downloadButtonIcon: String {
        singleURLAlreadyQueued ? "checkmark.circle.fill" : "arrow.down.circle.fill"
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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
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

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "sniffer")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "adClean")
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
            print("BROWSER: didCommit \(webView.url?.absoluteString ?? "?")")
            if let current = webView.url?.absoluteString {
                if parent.isPrimaryBrowser {
                    BrowserStartPage().lastVisitedURL = current
                }
                parent.address = current
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
