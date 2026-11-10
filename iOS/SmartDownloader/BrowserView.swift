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
                    Label(manager.foundURLs.isEmpty ? "未检测到视频" : "下载视频 (\(manager.foundURLs.count))",
                          systemImage: "arrow.down.circle.fill")
                }
                .disabled(manager.foundURLs.isEmpty)
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
                    Text(found).font(.footnote).lineLimit(2)
                }
            }
            .navigationTitle("选择 m3u8")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// 取网页标题作文件名后开始下载（嗅探到的 m3u8 一般带时效签名，尽快开下）
    private func startDownload(from raw: String?) {
        guard let raw, let url = URL(string: raw),
              url.scheme == "http" || url.scheme == "https" else { return }
        Task { @MainActor in
            var title = ""
            if let webView = store.webView {
                title = (try? await webView.evaluateJavaScript("document.title")) as? String ?? ""
            }
            manager.startDownload(urlString: url.absoluteString, title: title)
        }
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
                NSLog("DRAMAMETA-DOM ===== BEGIN =====")
                for key in d.keys.sorted() {
                    if let arr = d[key] as? [Any] {
                        NSLog("DRAMAMETA-DOM \(key) list len=\(arr.count): \(String(describing: arr.prefix(8)).prefix(500))")
                    } else {
                        NSLog("DRAMAMETA-DOM \(key) = \(String(describing: d[key]).prefix(400))")
                    }
                }
                NSLog("DRAMAMETA-DOM ===== END =====")
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

/// 原生剧集页（纯原生，无网页）：点击剧集路由过来，
/// 头部 = 封面/剧名/简介（缓存 + 后台收割），下方全集 grid：未下载点选下载、已下载 ▶ 播放；
/// 元数据缺失时后台用一次性隐藏 webview 拉网页提取（落库后头部即时更新），右上角 ↻ 强制更新集数
struct DramaNativePage: View {
    let target: DramaTarget
    @ObservedObject var manager: DownloadManager

    @State private var loading = true
    @State private var loadError: String?
    @State private var info: DramaInfo?
    @State private var session: DramaSession?
    @State private var downloadedSorts: Set<Int> = []
    @State private var selected: Set<Int> = []
    /// 已下载集点播：拉起沉浸式竖屏播放页（可上下滑切集）
    @State private var immersivePlayback: ImmersivePlaybackRequest?
    /// 当前列表是否来自本地缓存（缓存优先，刷新按钮强制更新）
    @State private var fromCache = false
    @State private var reloadID = UUID()
    /// 头部元数据（缓存 + 后台收割）
    @State private var coverURL: URL?
    @State private var intro: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("正在获取剧集列表…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(loadError)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("重试") { reloadID = UUID() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let info {
                pageContent(info)
            }
        }
        .navigationTitle(info?.name ?? "剧集页")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .fullScreenCover(item: $immersivePlayback) { request in
            DramaPlayerContainer(request: request)
        }
        .task(id: reloadID) { await load() }
        .onAppear { preloadHeaderFromCache() }
        .onReceive(manager.objectWillChange) { _ in refreshDownloadedSorts() }
    }

    /// 缓存里已有的封面/简介先上头部（无网络也能显示）
    private func preloadHeaderFromCache() {
        if let entry = DramaCache.load(site: target.site, dramaID: target.dramaID) {
            if let cover = entry.cover, let url = URL(string: cover) { coverURL = url }
            if let introText = entry.intro, !introText.isEmpty { intro = introText }
        }
    }

    /// 任一任务状态变化时重算已下载集（下载完成 → 格子即时变 ▶ 播放；仅内存重算，不每 tick 写库）
    private func refreshDownloadedSorts() {
        guard let info else { return }
        downloadedSorts = Set(manager.downloadedEpisodeFolders(forSeries: info.name).keys)
    }

    private func load() async {
        loading = true
        loadError = nil
        selected = []
        // 缓存优先：同一剧集第二次打开直接读本地，不发网络请求（刷新按钮强制更新）
        if let entry = DramaCache.load(site: target.site, dramaID: target.dramaID),
           let info = DramaInfo(entry: entry) {
            self.info = info
            fromCache = true
            await applyLibraryState(for: info, target: target)
            harvestIfNeeded()
            loading = false
            return
        }
        await fetchAndCache()
    }

    /// 强制走网络拉取并落库（刷新按钮）
    private func fetchAndCache() async {
        loading = true
        loadError = nil
        let session = DramaSession(target: target)
        self.session = session
        do {
            let info = try await session.fetchInfo()
            self.info = info
            fromCache = false
            DramaCache.saveInfo(site: target.site, dramaID: target.dramaID, info: info)
            await applyLibraryState(for: info, target: target)
            harvestIfNeeded()
        } catch {
            // 有缓存时网络失败不白屏：回退缓存继续用
            if let entry = DramaCache.load(site: target.site, dramaID: target.dramaID),
               let info = DramaInfo(entry: entry) {
                self.info = info
                fromCache = true
                await applyLibraryState(for: info, target: target)
            } else {
                loadError = error.localizedDescription
            }
        }
        loading = false
    }

    private func applyLibraryState(for info: DramaInfo, target: DramaTarget) async {
        // 先收编旧版散装下载（只搬不删），再算已下载集（磁盘为账本），并对账写回缓存
        manager.collectLegacyEpisodes(forSeries: info.name)
        manager.refreshLibrary()
        let folders = manager.downloadedEpisodeFolders(forSeries: info.name)
        downloadedSorts = Set(folders.keys)
        DramaCache.reconcileDownloaded(site: target.site, dramaID: target.dramaID, folders: folders)
    }

    /// 头部缺封面/简介时：后台隐藏 webview 拉一次剧集页提取元数据（落库后头部即时更新）
    private func harvestIfNeeded() {
        guard coverURL == nil || intro == nil else { return }
        Task {
            await DramaMetaHarvester.harvest(target: target)
            if let entry = DramaCache.load(site: target.site, dramaID: target.dramaID) {
                if let cover = entry.cover, let url = URL(string: cover) { coverURL = url }
                if let introText = entry.intro, !introText.isEmpty { intro = introText }
            }
        }
    }

    private func pageContent(_ info: DramaInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    if let coverURL {
                        AsyncImage(url: coverURL) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Color(uiColor: .systemGray5)
                        }
                        .frame(width: 90, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.name).font(.headline).lineLimit(2)
                        Text(headerSubtitle(info))
                            .font(.caption).foregroundColor(.secondary)
                        if let intro {
                            Text(intro).font(.caption).foregroundColor(.secondary).lineLimit(4)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal)

                HStack {
                    Spacer()
                    Button("全选") { selected = Set(selectableEpisodes.map(\.id)) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(selectableEpisodes.isEmpty)
                    Button("清空") { selected.removeAll() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(selected.isEmpty)
                    Button {
                        Task { await fetchAndCache() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                    ForEach(info.episodes) { ep in
                        episodeCell(ep)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom) {
            Button { startDownload(info) } label: {
                if selected.isEmpty && selectableEpisodes.isEmpty {
                    Label("全部已下载", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                } else {
                    Label("下载所选 (\(selected.count))", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func headerSubtitle(_ info: DramaInfo) -> String {
        let base = "\(fromCache ? "本地缓存 · " : "")共 \(info.episodes.count) 集 · 可下载 \(selectableEpisodes.count) 集"
        return downloadedSorts.isEmpty ? base : base + " · 已下载 \(downloadedSorts.count) 集"
    }

    /// 未下载且可播放的集
    private var selectableEpisodes: [ApiDramaEpisode] {
        info?.episodes.filter { $0.playable && !downloadedSorts.contains($0.sort) } ?? []
    }

    /// 单元格状态：已下载 = 绿勾 ▶，点击直接播放；付费锁定 = 灰锁禁点；选中 = 高亮；其余可点选
    private func episodeCell(_ ep: ApiDramaEpisode) -> some View {
        let isSelected = selected.contains(ep.id)
        let isDownloaded = downloadedSorts.contains(ep.sort)
        return Button {
            if isDownloaded {
                playDownloaded(ep)
            } else if isSelected {
                selected.remove(ep.id)
            } else {
                selected.insert(ep.id)
            }
        } label: {
            Group {
                if isDownloaded {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text(String(format: "第%02d集", ep.sort))
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                    }
                } else {
                    Text(String(format: "第%02d集", ep.sort))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(cellBackground(isSelected: isSelected, isDownloaded: isDownloaded, playable: ep.playable))
            .foregroundStyle(cellForeground(isSelected: isSelected, isDownloaded: isDownloaded, playable: ep.playable))
            .overlay(alignment: .topTrailing) {
                if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .offset(x: 5, y: -5)
                } else if !ep.playable {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .offset(x: 5, y: -5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .disabled(!ep.playable)
    }

    /// 已下载集：拉起沉浸式竖屏播放页，带上该剧全部已下载集以支持上下滑切集。
    /// 简介取自本地 SQLite 缓存（离线可用），不额外发网络请求。
    private func playDownloaded(_ ep: ApiDramaEpisode) {
        guard let info else { return }
        let episodes = DramaPlaybackLibrary.episodes(forSeries: info.name)
        guard let start = episodes.firstIndex(where: { $0.sort == ep.sort }) else { return }
        let intro = DramaCache.load(site: target.site, dramaID: target.dramaID)?.intro
        immersivePlayback = ImmersivePlaybackRequest(
            seriesName: info.name,
            intro: intro,
            episodes: episodes,
            startIndex: start
        )
    }

    private func cellBackground(isSelected: Bool, isDownloaded: Bool, playable: Bool) -> Color {
        if isSelected { return .accentColor }
        if isDownloaded { return .green.opacity(0.12) }
        return playable ? Color(uiColor: .systemGray5) : Color(uiColor: .systemGray6)
    }

    private func cellForeground(isSelected: Bool, isDownloaded: Bool, playable: Bool) -> Color {
        if isSelected { return .white }
        if isDownloaded { return .primary }
        return playable ? .primary : Color(uiColor: .tertiaryLabel)
    }

    private func startDownload(_ info: DramaInfo) {
        // 缓存路径打开的页面没有 session：现建一个（每集下载前仍会重调接口取新鲜直链）
        let session = self.session ?? DramaSession(target: target)
        self.session = session
        let chosen = info.episodes
            .filter { selected.contains($0.id) && $0.playable && !downloadedSorts.contains($0.sort) }
            .sorted { $0.sort < $1.sort }
        guard !chosen.isEmpty else { return }
        SeriesDownloadCoordinator.start(target: target, seriesName: info.name,
                                        episodes: chosen, manager: manager, session: session)
    }
}

// MARK: - 元数据收割器 + 提取 JS

/// 剧集页元数据提取 JS（og:image/标题/简介/图片列表/正文样本），主浏览页与收割器共用
let dramaMetaJS = """
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

/// 一次性隐藏 webview：加载剧集页提取元数据（og:image/标题/简介），落库后释放。
/// 仅在纯原生页缺封面/简介时使用；同一剧每次运行只收割一次。
@MainActor
final class DramaMetaHarvester: NSObject, WKNavigationDelegate {
    static var harvestedKeys: Set<String> = []

    static func harvest(target: DramaTarget) async {
        let key = target.id
        guard !harvestedKeys.contains(key) else { return }
        harvestedKeys.insert(key)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let harvester = DramaMetaHarvester()
            harvester.begin(target: target) {
                continuation.resume()
            }
        }
    }

    private var webView: WKWebView?
    private var pendingTarget: DramaTarget?
    private var finishHandler: (() -> Void)?
    private var finished = false

    private func begin(target: DramaTarget, finish: @escaping () -> Void) {
        pendingTarget = target
        finishHandler = finish
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // 与主浏览页共享登录态
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        view.navigationDelegate = self
        webView = view
        view.load(URLRequest(url: URL(string: target.pageURLString)!))
        // 超时兜底：25 秒后用已拿到的部分数据收尾
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            self?.finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        finishHandler?()
        finishHandler = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // SPA 渲染滞后：轮询提取直到拿到 og/desc 或超时收尾
        Task { [weak self] in
            guard let self, let target = self.pendingTarget else { return }
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let result = try? await webView.evaluateJavaScript(dramaMetaJS) as? String,
                      let d = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] else { continue }
                var update = d
                if let og = d["ogImage"] as? String, !og.isEmpty { update["cover"] = og }
                if let desc = d["desc"] as? String, !desc.isEmpty { update["intro"] = desc }
                if let t = d["title"] as? String, !t.isEmpty { update["page_title"] = t }
                DramaCache.savePageMeta(site: target.site, dramaID: target.dramaID, update: update)
                if !(d["ogImage"] as? String ?? "").isEmpty || !(d["desc"] as? String ?? "").isEmpty { break }
            }
            self.finish()
        }
    }
}

