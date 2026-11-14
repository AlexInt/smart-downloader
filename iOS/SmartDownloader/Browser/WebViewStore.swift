import SwiftUI
import WebKit
import Combine

// 浏览页 ViewModel：从 BrowserView.swift 拆出，逐字迁移不改行为。
// WKWebView 命令通道 + 下载入口编排，独立于 View 文件（AGENTS.md 域内分层）。

/// WKWebView 命令通道：让 SwiftUI 工具栏驱动网页后退/前进/刷新/加载。
/// 页面状态与下载入口锁都是主线程状态（主线程约定，GCD 版无线程标注）。
final class WebViewStore: ObservableObject {
    weak var webView: WKWebView?
    @Published var loadError: String?
    @Published var pageTitle: String?
    /// 页面元数据提取结果（JSON 字符串，原生解析后展示/落盘）
    @Published var pageMetaJSON: String?
    /// 网址栏下方的快捷站点标签（设置页可配置多对 key/value）。
    /// 不在 init 一次性读死：设置页改了之后要能跟上，故由浏览页在 onAppear / 切回时调 `refreshQuickLinks()`。
    @Published private(set) var quickLinks: [QuickLink] = []
    /// 快捷站点读取通道（Service，本 VM 不碰 UserDefaults）
    private let quickLinkStore = QuickLinkStore()

    /// 读取快捷站点配置（启动 + 每次回到浏览 tab 都重读，与设置页保持一致）
    func refreshQuickLinks() {
        let links = quickLinkStore.load()
        if links != quickLinks { quickLinks = links }
    }

    /// 下载入口连点锁（异步取标题期间置位；架构评估 P9 从 View 收纳）
    @Published private(set) var isSubmitting = false

    /// 后退/前进可用性（画布 22:329/331 用墨色与浅灰区分可点与不可点）。
    /// WKWebView 的 canGoBack/canGoForward 不是 KVO 友好的属性，由导航回调统一回写；
    /// 初值 false 与画布一致（起始页两个箭头都是灰的，后退在首次导航后才转墨）。
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    /// 导航状态变化后回写箭头可用性（主线程调用）
    func refreshNavigationState() {
        let back = webView?.canGoBack ?? false
        let forward = webView?.canGoForward ?? false
        if back != canGoBack { canGoBack = back }
        if forward != canGoForward { canGoForward = forward }
    }

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

    /// 下载入口编排：取网页标题作文件名后开始下载（嗅探到的 m3u8 一般带时效签名，尽快开下）。
    /// 取标题是异步的，这个窗口内连点会排多个任务；isSubmitting 把入口锁住；
    /// 同 URL 已有活跃任务时直接忽略（按钮态与 Picker 行均已禁用，这里是最后防线）。
    func beginDownload(from raw: String?, manager: DownloadManager) {
        guard let raw, let url = URL(string: raw),
              url.scheme == "http" || url.scheme == "https" else { return }
        guard !isSubmitting else { return }
        guard !manager.hasActiveTask(forURL: url.absoluteString) else { return }
        isSubmitting = true
        // evaluateJavaScript completion 固定主线程；取到标题后开下并解锁
        if let webView = self.webView {
            webView.evaluateJavaScript("document.title") { [weak self] result, _ in
                let title = result as? String ?? ""
                manager.startDownload(urlString: url.absoluteString, title: title)
                self?.isSubmitting = false
            }
        } else {
            manager.startDownload(urlString: url.absoluteString, title: "")
            isSubmitting = false
        }
    }
}
