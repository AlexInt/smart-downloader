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
            DramaWebPage(target: target, manager: manager)
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

/// 原生剧集页：点击剧集路由过来（网页本体不加载剧集页，主页停留不变），
/// 内嵌 webview 加载剧集页（保留封面/简介/登录态内容），进入即弹选集面板；
/// 页内再点其它剧集继续推入新的原生剧集页
struct DramaWebPage: View {
    let target: DramaTarget
    @ObservedObject var manager: DownloadManager
    @StateObject private var store = WebViewStore()
    @State private var address: String
    /// 页内再点击其它剧集：继续推入原生剧集页
    @State private var nestedTarget: DramaTarget?
    @State private var pickerTarget: DramaTarget?

    init(target: DramaTarget, manager: DownloadManager) {
        self.target = target
        self.manager = manager
        _address = State(initialValue: target.pageURLString)
    }

    var body: some View {
        VStack(spacing: 0) {
            WebViewContainer(manager: manager, store: store, address: $address,
                             onDramaLinkClick: { nestedTarget = $0 },
                             onDramaURLDetected: { t, undo in
                                 guard t.id != target.id else { return }
                                 nestedTarget = t
                                 if undo, store.webView?.canGoBack == true {
                                     store.webView?.goBack()
                                 }
                             },
                             isPrimaryBrowser: false,
                             initialURL: target.pageURLString)
            HStack {
                Spacer()
                Button { pickerTarget = target } label: {
                    Label("选集", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .navigationTitle(store.pageTitle ?? "剧集页")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $nestedTarget) { nested in
            DramaWebPage(target: nested, manager: manager)
        }
        .sheet(item: $pickerTarget) { t in
            DramaPickerSheet(target: t, manager: manager)
        }
        .onAppear { pickerTarget = target }  // 进入即弹选集面板
    }
}

/// 剧集选集面板（原生剧集页进入时自动弹出的半屏 sheet）：
/// grid 展示全集；已下载的集打绿勾且不可点（文件系统就是账本，开面板时扫剧目录）；
/// 全选只选未下载的可播集，多选/单选后一次排队下载，落到 Downloads/<剧名>/第NN集/
struct DramaPickerSheet: View {
    let target: DramaTarget
    @ObservedObject var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var loading = true
    @State private var loadError: String?
    @State private var info: DramaInfo?
    @State private var session: DramaSession?
    @State private var downloadedSorts: Set<Int> = []
    @State private var selected: Set<Int> = []
    @State private var playerItem: PlayerItem?
    @State private var reloadID = UUID()

    /// 未下载且可播放的集
    private var selectableEpisodes: [DramaEpisode] {
        info?.episodes.filter { $0.playable && !downloadedSorts.contains($0.sort) } ?? []
    }

    var body: some View {
        NavigationStack {
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
                    pickerGrid(info)
                }
            }
            .navigationTitle("选集下载")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .sheet(item: $playerItem) { item in
            PlayerView(item: item)
        }
        .task(id: reloadID) { await load() }
    }

    private func load() async {
        loading = true
        loadError = nil
        selected = []
        let session = DramaSession(target: target)
        self.session = session
        do {
            let info = try await session.fetchInfo()
            self.info = info
            // 先收编旧版散装下载（只搬不删），再算已下载集，两者都能打勾
            manager.collectLegacyEpisodes(forSeries: info.name)
            manager.refreshLibrary()
            downloadedSorts = manager.downloadedEpisodeSorts(forSeries: info.name)
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func pickerGrid(_ info: DramaInfo) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("《\(info.name)》").font(.headline).lineLimit(1)
                    Text(headerSubtitle(info))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("全选") { selected = Set(selectableEpisodes.map(\.id)) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(selectableEpisodes.isEmpty)
                Button("清空") { selected.removeAll() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(selected.isEmpty)
            }
            .padding(.horizontal)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                    ForEach(info.episodes) { ep in
                        episodeCell(ep)
                    }
                }
                .padding(.horizontal)
            }

            Button {
                startDownload(info)
            } label: {
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
            .padding(.bottom, 6)
        }
    }

    private func headerSubtitle(_ info: DramaInfo) -> String {
        let base = "共 \(info.episodes.count) 集 · 可下载 \(selectableEpisodes.count) 集"
        return downloadedSorts.isEmpty ? base : base + " · 已下载 \(downloadedSorts.count) 集"
    }

    /// 单元格状态：已下载 = 绿勾，点击直接播放；付费锁定 = 灰锁禁点；选中 = 高亮；其余可点选
    private func episodeCell(_ ep: DramaEpisode) -> some View {
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

    /// 已下载集：从剧目录找该集的 playlist.m3u8，拉起播放器（本地 HTTP 服务已支持剧集两级路径）
    private func playDownloaded(_ ep: DramaEpisode) {
        guard let info else { return }
        let fm = FileManager.default
        let seriesDir = DownloadEngine.seriesDirectory(for: info.name)
        guard let subs = try? fm.contentsOfDirectory(at: seriesDir, includingPropertiesForKeys: nil) else { return }
        let playlist = subs
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("playlist.m3u8").path)
                    && DownloadManager.episodeSort(fromFolderName: $0.lastPathComponent) == ep.sort
            }
            .map { $0.appendingPathComponent("playlist.m3u8") }
            .first
        guard let playlist else { return }
        playerItem = PlayerItem(url: playlist, isHLSFolder: true)
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
        guard let session else { return }
        let chosen = info.episodes
            .filter { selected.contains($0.id) && $0.playable && !downloadedSorts.contains($0.sort) }
            .sorted { $0.sort < $1.sort }
        guard !chosen.isEmpty else { return }
        SeriesDownloadCoordinator.start(target: target, seriesName: info.name,
                                        episodes: chosen, manager: manager, session: session)
        dismiss()
    }
}
