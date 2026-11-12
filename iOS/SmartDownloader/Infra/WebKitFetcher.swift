import Foundation
import WebKit

// MARK: - WebKit 网络栈兜底通道
//
// 部分视频资源站点的 WAF 按客户端 TLS 指纹掐连接：WKWebView(Safari 栈) 能过，URLSession 在部分
// 真机网络下握手即被 RST，表现为 -1200 "TLS错误导致安全连接失败"。
// App 浏览页(WKWebView)实测可正常加载站点，故下载请求降级走同一网络栈(WKDownload)。
//
// 载体选择（真机实测）：iOS 上脱离视图树、未加载任何内容的隐藏 WKWebView 发起的
// WKDownload 会直接以 "DownloadFailed" 失败（无活跃页面上下文/前台网络会话），
// 因此优先复用浏览页那个真实附加在视图树里的 WKWebView，仅在其不可用时
// 退回隐藏 webview（Mac 冒烟测试场景）。
//
// 实现说明（GCD 版）:
// - fetch 是同步阻塞接口，只允许在后台工作线程调用：主线程发起下载，
//   工作线程用信号量等结果（120s 超时兜底；WKDownload 本身无超时回调）
// - startDownload(using:) 只有 async API（Apple 无 completion 变体），
//   是代码库两处 async 岛之一（另一处：PlaybackPlayerService 资产加载）；拿到 download 对象前 delegate 可能先回调，
//   故 paths/results/waiters 三张表做两阶段握手，回调先行时暂存结果
// - 所有可变状态只在主线程访问（WebKit 固定在主线程回调）

final class WebKitFetcher: NSObject {
    static let shared = WebKitFetcher()

    /// 浏览页真实附加在视图树上的 WKWebView（真机蜂窝网络下被证实可过 WAF）
    private weak var hostWebView: WKWebView?
    /// 备用隐藏 webview（无 host 时的兜底，如 Mac 冒烟测试）
    private var webView: WKWebView?
    /// WKDownload -> 落盘路径（decideDestination 写入）
    private var paths: [ObjectIdentifier: URL] = [:]
    /// 回调先于 fetch 注册时暂存的结果
    private var results: [ObjectIdentifier: Result<Data, Error>] = [:]
    /// fetch 注册的等待者：落地时写入结果箱并 signal 工作线程的信号量
    private var waiters: [ObjectIdentifier: (Result<Data, Error>) -> Void] = [:]

    /// 浏览页创建 WKWebView 时注册，下载请求优先复用它发起（主线程调用）
    func setHostWebView(_ view: WKWebView) {
        hostWebView = view
    }

    /// 用 WebKit 网络栈拉取资源（Safari TLS 指纹，可过 WAF）。
    /// 同步阻塞：只允许在后台工作线程调用，主线程调用会死锁。
    func fetch(url: URL, byteRange: DownloadEngine.ByteRange?) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        // 结果箱：主线程写、工作线程读，先后序由信号量建立；
        // 超时后迟到回调再写箱已无人读取，无害（极端挂死需手动重试）
        var outcome: Result<Data, Error>?
        DispatchQueue.main.async {
            self.start(url: url, byteRange: byteRange) { result in
                outcome = result
                semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + 120) == .success, let result = outcome else {
            throw URLError(.timedOut)
        }
        var data = try result.get()
        if let range = byteRange, range.offset != nil {
            guard data.count >= range.length else {
                throw DownloadError.shortSegment(range.length, data.count)
            }
            if data.count > range.length {
                data = data.prefix(range.length)
            }
        }
        return data
    }

    /// 主线程：发起下载并登记完成回调
    private func start(url: URL, byteRange: DownloadEngine.ByteRange?,
                       completion: @escaping (Result<Data, Error>) -> Void) {
        // 优先复用浏览页的 webview：隐藏 webview 在 iOS 真机上下载会直接 DownloadFailed
        let view: WKWebView
        if let host = hostWebView {
            view = host
        } else {
            do {
                view = try ensureWebView()
            } catch {
                completion(.failure(error))
                return
            }
        }
        var request = URLRequest(url: url)
        for (field, value) in DownloadEngine.browserHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let range = byteRange, let offset = range.offset {
            request.setValue("bytes=\(offset)-\(offset + range.length - 1)",
                             forHTTPHeaderField: "Range")
        }
        // async 岛之一：startDownload(using:) 无 completion 变体（Apple API 限制）。
        // delegate 在拿到 download 的主线程同步段内紧随赋值；此后到 waiter 注册
        // 之间若有回调先行，由 results 暂存表覆盖（注册时先查表）。
        Task { @MainActor in
            let download = await view.startDownload(using: request)
            download.delegate = self
            let key = ObjectIdentifier(download)
            if let result = self.results.removeValue(forKey: key) {
                completion(result)
            } else {
                self.waiters[key] = completion
            }
        }
    }

    /// 备用隐藏 webview：不加入视图树也可发起下载（macOS 冒烟实测可用；iOS 真机不可用）
    private func ensureWebView() throws -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        webView = view
        return view
    }

    private func finish(_ key: ObjectIdentifier, _ result: Result<Data, Error>) {
        if let waiter = waiters.removeValue(forKey: key) {
            waiter(result)
        } else {
            results[key] = result
        }
    }
}

// WKDownloadDelegate 回调固定在主线程（与可变状态同一线程，无需额外同步）
extension WebKitFetcher: WKDownloadDelegate {
    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename filename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("wkdl_\(UUID().uuidString)_\(filename)")
        paths[ObjectIdentifier(download)] = path
        completionHandler(path)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let path = paths.removeValue(forKey: key) else { return }
        do {
            let data = try Data(contentsOf: path)
            guard !data.isEmpty else { throw DownloadError.badStatus(-1) }
            finish(key, .success(data))
        } catch {
            finish(key, .failure(error))
        }
        try? FileManager.default.removeItem(at: path)
    }

    func download(_ download: WKDownload,
                  didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        if let path = paths.removeValue(forKey: key) {
            try? FileManager.default.removeItem(at: path)
        }
        finish(key, .failure(error))
    }
}