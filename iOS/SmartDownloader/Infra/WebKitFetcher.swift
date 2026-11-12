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
// 实现说明:
// - startDownload 发起下载，响应由 WebKit 网络进程落盘到临时文件
// - delegate 回调在主线程；startDownload 与回调之间存在竞态窗口
//   (decideDestination 可能先于 fetch 注册 continuation 执行)，
//   故用 paths/results/waiters 三张表做两阶段握手，回调先行时暂存结果
// - WKDownload 无超时回调，依赖外层 URLSession 先行失败超时兜底；极端挂死需手动重试

@MainActor
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
    /// fetch 注册的等待者
    private var waiters: [ObjectIdentifier: CheckedContinuation<Data, Error>] = [:]

    /// 浏览页创建 WKWebView 时注册，下载请求优先复用它发起
    func setHostWebView(_ view: WKWebView) {
        hostWebView = view
    }

    /// 用 WebKit 网络栈拉取资源（Safari TLS 指纹，可过 WAF）
    func fetch(url: URL, byteRange: DownloadEngine.ByteRange?) async throws -> Data {
        var data = try await start(url: url, byteRange: byteRange)
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

    private func start(url: URL, byteRange: DownloadEngine.ByteRange?) async throws -> Data {
        // 优先复用浏览页的 webview：隐藏 webview 在 iOS 真机上下载会直接 DownloadFailed
        let view: WKWebView
        if let host = hostWebView {
            view = host
        } else {
            view = try ensureWebView()
        }
        var request = URLRequest(url: url)
        for (field, value) in DownloadEngine.browserHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let range = byteRange, let offset = range.offset {
            request.setValue("bytes=\(offset)-\(offset + range.length - 1)",
                             forHTTPHeaderField: "Range")
        }
        // delegate 挂在 WKDownload 上；MainActor 同步段内紧随 startDownload 赋值，
        // 网络往返期间不会与主线程回调交错
        let download = await view.startDownload(using: request)
        download.delegate = self
        let key = ObjectIdentifier(download)
        if let result = results.removeValue(forKey: key) {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            if let result = results.removeValue(forKey: key) {
                continuation.resume(with: result)
            } else {
                waiters[key] = continuation
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
        if let continuation = waiters.removeValue(forKey: key) {
            continuation.resume(with: result)
        } else {
            results[key] = result
        }
    }
}

// WKDownloadDelegate 协议方法为非隔离声明，WebKit 固定在主线程回调
extension WebKitFetcher: WKDownloadDelegate {
    nonisolated func download(_ download: WKDownload,
                              decideDestinationUsing response: URLResponse,
                              suggestedFilename filename: String,
                              completionHandler: @escaping (URL?) -> Void) {
        MainActor.assumeIsolated {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("wkdl_\(UUID().uuidString)_\(filename)")
            paths[ObjectIdentifier(download)] = path
            completionHandler(path)
        }
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        MainActor.assumeIsolated {
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
    }

    nonisolated func download(_ download: WKDownload,
                             didFailWithError error: Error, resumeData: Data?) {
        MainActor.assumeIsolated {
            let key = ObjectIdentifier(download)
            if let path = paths.removeValue(forKey: key) {
                try? FileManager.default.removeItem(at: path)
            }
            finish(key, .failure(error))
        }
    }
}
