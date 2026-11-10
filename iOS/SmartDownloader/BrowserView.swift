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

    @ObservedObject var manager: DownloadManager
    @StateObject private var store = WebViewStore()
    @State private var address = BrowserView.initialURLString == "about:blank" ? "" : BrowserView.initialURLString
    @State private var showPicker = false

    var body: some View {
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
            .padding(.vertical, 6)

            if let loadError = store.loadError {
                Text("⚠️ 网页加载失败: \(loadError)")
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
            }

            WebViewContainer(manager: manager, store: store, address: $address)

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
        .sheet(isPresented: $showPicker) {
            pickerSheet
        }
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
        // WebKit 兜底通道优先复用这个真实 webview 发起下载（真机蜂窝网络下唯一可过 WAF 的网络栈）
        WebKitFetcher.shared.setHostWebView(webView)
        if let first = URL(string: BrowserView.initialURLString) {
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
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                provisionalRetries = 0
                parent.store.loadError = nil
                if let current = webView.url?.absoluteString {
                    UserDefaults.standard.set(current, forKey: BrowserView.lastPageKey)
                    parent.address = current
                }
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
                parent.store.loadError = error.localizedDescription
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                parent.store.loadError = error.localizedDescription
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
