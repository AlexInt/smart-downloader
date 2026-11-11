import SwiftUI
import WebKit

/// 浏览页：WKWebView 加载视频资源网页 + 注入 m3u8 嗅探脚本 + 一键下载按钮
struct BrowserView: View {
    /// 站点地址不写入代码：记住上次访问页面，启动时直接恢复
    static let lastPageKey = "BrowserView.lastPageURL"
    /// 冒烟测试时临时把默认起始页改为 "http://127.0.0.1:8899/test.html"（见 iOS/smoke/ 目录）
    static var initialURLString: String {
        UserDefaults.standard.string(forKey: lastPageKey) ?? "about:blank"
    }

    /// 快捷站点标签：点击直达；地址栏仍可输入任意 URL
    static let quickLinks: [(name: String, url: String)] = [
        ("🍎", "https://www.yeguodj.com/"),
    ]

    @ObservedObject var manager: DownloadManager
    @Binding var selectedTab: Int
    @StateObject private var store = WebViewStore()
    @State private var address = BrowserView.initialURLString == "about:blank" ? "" : BrowserView.initialURLString
    @State private var showPicker = false
    /// 点击剧集（拦截网页路由 / SPA pushState 检测）推入的原生剧集页
    @State private var dramaPageTarget: DramaTarget?
    /// 同一部剧只自动推入一次（SPA 回退后清除，重进会再推）
    @State private var lastAutoDramaKey: String?

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

            // 快捷站点标签行
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.quickLinks, id: \.name) { link in
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

            HStack(spacing: 18) {
                Button { store.goBack() } label: { Image(systemName: "chevron.left") }
                Button { store.goForward() } label: { Image(systemName: "chevron.right") }
                Button { store.reload() } label: { Image(systemName: "arrow.clockwise") }
                Spacer()
                Button {
                    if manager.foundURLs.count > 1 {
                        showPicker = true
                    } else {
                        startDownload(from: manager.foundURLs.first)
                    }
                } label: {
                    Label(downloadButtonTitle, systemImage: downloadButtonIcon)
                }
                .disabled(manager.foundURLs.isEmpty || isSubmitting || singleURLAlreadyQueued)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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
            if tab != 0 {
                dramaPageTarget = nil
                lastAutoDramaKey = nil
            }
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
            if let target = DramaTarget.parse(address) { detectDrama(target, undoSPA: false) }
        }
    }

    /// 检测到剧集页 URL：推入原生剧集页；SPA pushState 无法取消，undoSPA 时回退网页到列表页
    private func detectDrama(_ target: DramaTarget, undoSPA: Bool) {
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
                    startDownload(from: found)
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

    /// 取网页标题作文件名后开始下载（嗅探到的 m3u8 一般带时效签名，尽快开下）
    private func startDownload(from raw: String?) {
        guard let raw, let url = URL(string: raw),
              url.scheme == "http" || url.scheme == "https" else { return }
        // 取标题是异步的，这个窗口内连点会排多个任务；用 isSubmitting 把入口锁住
        guard !isSubmitting else { return }
        guard !manager.hasActiveTask(forURL: url.absoluteString) else { return }
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            var title = ""
            if let webView = store.webView {
                title = (try? await webView.evaluateJavaScript("document.title")) as? String ?? ""
            }
            manager.startDownload(urlString: url.absoluteString, title: title)
        }
    }

    /// 异步取标题期间的连点锁
    @State private var isSubmitting = false

    private var singleURLAlreadyQueued: Bool {
        guard manager.foundURLs.count == 1, let url = manager.foundURLs.first else { return false }
        return manager.hasActiveTask(forURL: url)
    }

    private var downloadButtonTitle: String {
        if manager.foundURLs.isEmpty { return "未检测到视频" }
        if isSubmitting { return "正在添加…" }
        if singleURLAlreadyQueued { return "已在下载队列" }
        return "下载视频 (\(manager.foundURLs.count))"
    }

    private var downloadButtonIcon: String {
        singleURLAlreadyQueued ? "checkmark.circle.fill" : "arrow.down.circle.fill"
    }
}

/// WKWebView 命令通道：让 SwiftUI 工具栏驱动网页后退/前进/刷新/加载
final class WebViewStore: ObservableObject {
    weak var webView: WKWebView?
    @Published var loadError: String?
    @Published var pageTitle: String?
    /// 页面元数据提取结果（JSON 字符串，原生解析后展示/落盘）
    @Published var pageMetaJSON: String?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func load(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard let url = URL(string: text) else { return }
        webView?.load(URLRequest(url: url))
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
            WKUserScript(source: Self.snifferScript,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        controller.add(context.coordinator, name: "sniffer")

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
            MainActor.assumeIsolated {
                guard let coordinator else { return }
                let current = view.url?.absoluteString ?? ""
                print("BROWSER: url -> \(current)")
                // URL 变成剧集页（SPA pushState 或提交）：回调宿主决策（推原生页/回退列表）
                if let target = DramaTarget.parse(current) {
                    coordinator.parent.onDramaURLDetected(target, !view.isLoading)
                }
                coordinator.parent.address = current
            }
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
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: WebViewContainer
        private var lastMainURL: URL?
        private var provisionalRetries = 0
        /// 主帧 URL KVO（SPA pushState 换页不触发 didCommit，靠它同步地址栏/剧集页检测）
        var urlObservation: NSKeyValueObservation?
        /// 启动时恢复的“上次页面”尚未成功 commit 过；首次加载失败则重置起始页，避免冷启动反复卡在同一坏地址
        private var isInitialRestoreLoad = true
        init(_ parent: WebViewContainer) { self.parent = parent }

        // JS -> 原生：嗅探到 m3u8（消息回调固定在主线程）
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "sniffer", let urlString = message.body as? String else { return }
            MainActor.assumeIsolated {
                parent.manager.recordFound(urlString: urlString)
                if let current = parent.store.webView?.url?.absoluteString {
                    parent.address = current
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame?.isMainFrame == true {
                lastMainURL = navigationAction.request.url
                // 用户点击剧集链接：路由到原生剧集页，网页本体不加载该页
                if navigationAction.navigationType == .linkActivated,
                   let target = DramaTarget.parse(navigationAction.request.url?.absoluteString ?? "") {
                    parent.onDramaLinkClick(target)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                provisionalRetries = 0
                isInitialRestoreLoad = false
                parent.store.loadError = nil
                print("BROWSER: didCommit \(webView.url?.absoluteString ?? "?")")
                if let current = webView.url?.absoluteString {
                    if parent.isPrimaryBrowser {
                        UserDefaults.standard.set(current, forKey: BrowserView.lastPageKey)
                    }
                    parent.address = current
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.title") { result, _ in
                guard let title = result as? String, !title.isEmpty else { return }
                MainActor.assumeIsolated { self.parent.store.pageTitle = title }
            }
            // 调查：提取页面元数据（og:image/标题/简介/图片列表），立即 + 3秒后（SPA 渲染滞后）各一次
            extractMeta(webView, delay: 0)
            extractMeta(webView, delay: 3)
        }

        /// 调查用：从 DOM 提取短剧元数据，写入 store（页面头部展示 + DramaMeta 落盘）并写系统日志
        func extractMeta(_ webView: WKWebView, delay: Double) {
            Task { [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
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
                    desc: q('meta[name="description"]') || q('meta[property="og:description"]'),
                    imgs: imgs,
                    text: (document.body.innerText || '').replace(/\\s+/g,' ').slice(0, 500)
                  });
                })()
                """
                guard let self,
                      let result = try? await webView.evaluateJavaScript(js) as? String,
                      let d = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] else { return }
                self.parent.store.pageMetaJSON = result
                // 调查收敛（2026-11-11）：DRAMAMETA-DOM 逐 key 的 NSLog 双份输出删除——
                // 动态串被统一日志 <private> 脱敏看不到内容，纯噪音；字段内容看落盘文件
                //（harvest_<site>_<dramaID>.json，见 DramaMetaHarvester）
                print("BROWSER: extractMeta ok delay=\(delay) bytes=\(result.count)")
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            MainActor.assumeIsolated {
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
                // 启动恢复的页面首次加载就失败：清掉保存的起始页，下次冷启动不再卡在同一地址
                if isInitialRestoreLoad && parent.isPrimaryBrowser {
                    isInitialRestoreLoad = false
                    UserDefaults.standard.removeObject(forKey: BrowserView.lastPageKey)
                    parent.store.loadError = "\(error.localizedDescription)（上次页面无法打开，已重置起始页，请重新访问）"
                    print("BROWSER: 初始恢复页加载失败，已重置保存的起始页")
                    return
                }
                parent.store.loadError = error.localizedDescription
                print("BROWSER: 加载失败 code=\((error as NSError).code) url=\(lastMainURL?.absoluteString ?? "?") msg=\(error.localizedDescription)")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                parent.store.loadError = error.localizedDescription
                print("BROWSER: 加载失败(后段) code=\((error as NSError).code) url=\(webView.url?.absoluteString ?? "?") msg=\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 嗅探脚本（移植自 mac_app/sniffer.js，去掉悬浮工具栏，改走 messageHandlers 回传）

    private static let snifferScript = #"""
    (function () {
      if (window.__m3u8SnifferLoaded) return;
      window.__m3u8SnifferLoaded = true;

      var seen = {};

      function isM3u8(u) {
        try { return /\.m3u8(\?|#|$)/i.test(String(u)); } catch (e) { return false; }
      }

      function record(u) {
        if (!u) return;
        u = String(u);
        if (!isM3u8(u)) return;
        if (seen[u]) return;
        seen[u] = 1;
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sniffer) {
            window.webkit.messageHandlers.sniffer.postMessage(u);
          }
        } catch (e) {}
      }

      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        try { record(url); } catch (e) {}
        return origOpen.apply(this, arguments);
      };

      if (window.fetch) {
        var origFetch = window.fetch;
        window.fetch = function (input) {
          try { record(typeof input === 'string' ? input : (input && input.url)); } catch (e) {}
          return origFetch.apply(this, arguments);
        };
      }

      try {
        var entries = performance.getEntriesByType('resource');
        for (var i = 0; i < entries.length; i++) record(entries[i].name);
      } catch (e) {}

      function scanDom() {
        try {
          var nodes = document.querySelectorAll('video, source');
          for (var i = 0; i < nodes.length; i++) {
            var s = nodes[i].src || nodes[i].getAttribute('src');
            if (s) record(s);
          }
        } catch (e) {}
      }
      scanDom();
      try {
        new MutationObserver(scanDom).observe(document.documentElement, { childList: true, subtree: true });
      } catch (e) {}
    })();
    """#
}
