import Foundation
import Network

/// 内置本地 HTTP 服务：把沙盒 Downloads 目录以 http://127.0.0.1:<port>/ 暴露给 AVPlayer。
///
/// 为什么需要它：AVFoundation 无法直接播放文件版 m3u8，也无法播放裸 TS 合并文件（iOS 上没有 ffmpeg）。
/// 「本地回环 HTTP + 重写后的播放列表」是 iOS 离线 HLS 播放的标准做法。
/// 可变状态全部收敛在 stateQueue 串行队列上访问（GCD 约定，无线程标注）。
final class LocalMediaServer {
    static let shared = LocalMediaServer()

    private let stateQueue = DispatchQueue(label: "LocalMediaServer.state")
    private var listener: NWListener?
    private var port: UInt16 = 0
    /// 现役端口的跨队列快照（主线程可读）：只给「已构建 URL 是否仍指向现役服务」的校验用
    /// （预热池命中前比对端口）。写入在 stateQueue、读在主线程——短暂不一致可接受且方向安全：
    /// 不一致只会让调用方落到 MISS 重新解析 URL；反过来用旧值才会 HIT 到失效端口。
    private(set) var portSnapshot: UInt16 = 0
    /// 启动中的等待者（可能多个）：ready 时统一回调真实端口
    private var startCompletions: [(UInt16) -> Void] = []
    private var started = false
    private var handlers: [ObjectIdentifier: HTTPConnectionHandler] = [:]

    static var rootDirectory: URL { DownloadEngine.downloadsDir }

    /// 启动监听（幂等），completion 返回端口（0 = 启动失败）；在 stateQueue 上回调。
    /// 已就绪（listener 真的 ready 且 port != 0）直接回真实端口；未就绪时登记等待，ready 时统一回调。
    /// 切勿未就绪就回 port=0：App 预启服务与首次 playbackURL 并发，listener 还没 ready 时
    /// 拼出 http://127.0.0.1:0 会让播放器偶现「无法连接服务器」。
    ///
    /// 健康判据必须带上 listener.state：长期后台后系统会静默回收监听 socket，此时 port
    /// 可能仍是旧值，只看端口会把失效服务当成可用（回前台重连必被拒）。
    func start(completion: @escaping (UInt16) -> Void) {
        stateQueue.async {
            if self.isReadyLocked(), self.port != 0 {
                completion(self.port)
                return
            }
            self.startCompletions.append(completion)
            if self.started { return }   // 正在启动，等 finishStart 统一回调
            self.beginListening()
        }
    }

    /// 强制重建监听（回前台恢复用）：不信任 port / state —— 系统静默回收 socket 后
    /// NWListener.state 可能仍报 ready，但连接已经连不上。cancel 旧 listener 重新 bind，
    /// 端口可能变化，调用方必须用返回的端口重建播放 URL（预热池资产同时作废）。
    func restart(completion: @escaping (UInt16) -> Void) {
        stateQueue.async {
            print("PLAYER_DBG [Server] restart fromPort=\(self.port) state=\(String(describing: self.listener?.state))")
            self.startCompletions.append(completion)
            // 先摘掉引用再 cancel：旧 listener 的 .cancelled 回调据此识别为已替换并忽略
            let old = self.listener
            self.listener = nil
            self.port = 0
            self.portSnapshot = 0
            self.started = false
            old?.cancel()
            self.beginListening()
        }
    }

    /// 仅在 stateQueue 上调用：listener 状态是否真的 ready（State 带关联值，不能用 ==）
    private func isReadyLocked() -> Bool {
        guard let listener else { return false }
        if case .ready = listener.state { return true }
        return false
    }

    /// 建监听并启动（只在 stateQueue 上调用）
    private func beginListening() {
        started = true
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // 仅绑定回环地址，避免监听局域网
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                let handler = HTTPConnectionHandler(connection: connection, root: Self.rootDirectory)
                handler.onFinished = { [weak self, weak handler] in
                    guard let self, let handler else { return }
                    self.stateQueue.async {
                        self.handlers.removeValue(forKey: ObjectIdentifier(handler))
                    }
                }
                self.stateQueue.async {
                    self.handlers[ObjectIdentifier(handler)] = handler
                }
                handler.start()
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                self.stateQueue.async {
                    // 已被 restart 替换的旧 listener：忽略其迟到状态（cancel 会触发 .cancelled）
                    guard self.listener === listener else { return }
                    switch state {
                    case .ready:
                        let value = listener.port?.rawValue ?? 0
                        print("PLAYER_DBG [Server] listener ready port=\(value)")
                        self.finishStart(port: value)
                    case .failed(let error):
                        print("PLAYER_DBG [Server] listener failed error=\(error)")
                        self.finishStart(port: 0)
                    case .cancelled:
                        print("PLAYER_DBG [Server] listener cancelled")
                        self.finishStart(port: 0)
                    case .waiting(let error):
                        print("PLAYER_DBG [Server] listener waiting error=\(error)")
                    default:
                        break
                    }
                }
            }
            listener.start(queue: DispatchQueue(label: "LocalMediaServer.connections"))
            print("PLAYER_DBG [Server] listening start")
        } catch {
            print("PLAYER_DBG [Server] listening FAIL error=\(error)")
            finishStart(port: 0)
        }
    }

    private func finishStart(port value: UInt16) {
        port = value
        portSnapshot = value
        if value == 0 { started = false }   // 失败复位，允许下次 start 重试
        let completions = startCompletions
        startCompletions = []
        for completion in completions { completion(value) }
    }

    /// 生成本地 HLS 文件夹的播放地址；completion 在主线程回调。
    /// 路径必须是相对 root 的完整相对路径：剧集集目录在 Downloads/<剧名>/第NN集/ 下多了一层，
    /// 不能只取 lastPathComponent（在 root 下不存在会 404，且“第01集”跨剧重名）。
    func playbackURL(forFolder folder: URL, completion: @escaping (URL) -> Void) {
        start { port in
            let fallback = folder.absoluteURL.appendingPathComponent("playlist.m3u8")
            // 端口 0 = 服务启动失败：回文件 URL（scheme != http），makeItem 据此报「本地播放服务启动失败」，
            // 避免拼出 http://127.0.0.1:0 让 AVPlayer 报「无法连接服务器」
            guard port != 0 else {
                DispatchQueue.main.async { completion(fallback) }
                return
            }
            let root = Self.rootDirectory.standardizedFileURL
            // absoluteURL：容错相对路径入参（App 内部恒为绝对，冒烟工具可能传相对）
            var cursor = folder.absoluteURL.standardizedFileURL
            var components: [String] = []
            var underRoot = false
            for _ in 0..<16 {
                if cursor.path == root.path { underRoot = true; break }
                guard cursor.path.hasPrefix(root.path + "/") else { break }
                components.insert(cursor.lastPathComponent, at: 0)
                cursor = cursor.deletingLastPathComponent()
            }
            var result = fallback
            if underRoot, !components.isEmpty {
                let encoded = components
                    .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
                    .joined(separator: "/")
                result = URL(string: "http://127.0.0.1:\(port)/\(encoded)/playlist.m3u8") ?? result
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// 单连接处理：解析 HTTP GET（支持 Range），回送文件后关闭
/// 单连接的状态只在该连接的回调（同一队列串行回调）中访问
final class HTTPConnectionHandler {
    private let connection: NWConnection
    private let root: URL
    private var buffer = Data()
    private var fileHandle: FileHandle?
    var onFinished: (() -> Void)?

    init(connection: NWConnection, root: URL) {
        self.connection = connection
        self.root = root
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global())
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let headerRange = self.buffer.firstRange(of: Data("\r\n\r\n".utf8)) {
                let headerData = self.buffer.subdata(in: self.buffer.startIndex..<headerRange.lowerBound)
                guard let header = String(data: headerData, encoding: .utf8) else {
                    self.finish()
                    return
                }
                self.handleRequest(header)
            } else if error == nil && !isComplete {
                self.receive()
            } else {
                self.finish()
            }
        }
    }

    private func handleRequest(_ header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let requestParts = lines.first?.split(separator: " ") ?? []
        guard requestParts.count >= 2, requestParts[0] == "GET",
              let decodedPath = String(requestParts[1]).removingPercentEncoding else {
            respondSimple(status: "405 Method Not Allowed")
            return
        }
        var rangeHeader: String?
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "range" {
                rangeHeader = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }

        let relative = decodedPath.hasPrefix("/") ? String(decodedPath.dropFirst()) : decodedPath
        let fileURL = root.appendingPathComponent(relative).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard fileURL.path.hasPrefix(rootPath + "/"),
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            respondSimple(status: "404 Not Found")
            return
        }
        fileHandle = handle

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let total = (attributes?[.size] as? Int64) ?? 0

        var start: Int64 = 0
        var end: Int64 = total - 1
        var partial = false
        if let rangeHeader {
            let spec = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count >= 1, let a = Int64(bounds[0]) {
                start = max(0, a)
                partial = true
            }
            if bounds.count >= 2, let b = Int64(bounds[1]) {
                end = min(b, total - 1)
            }
            if start > end {
                start = 0
                end = total - 1
                partial = false
            }
        }
        try? handle.seek(toOffset: UInt64(max(0, start)))

        let length = total == 0 ? 0 : end - start + 1
        var headerText = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
        headerText += "Content-Type: \(Self.mime(for: fileURL.path))\r\n"
        headerText += "Content-Length: \(length)\r\n"
        headerText += "Accept-Ranges: bytes\r\n"
        if partial {
            headerText += "Content-Range: bytes \(start)-\(end)/\(total)\r\n"
        }
        headerText += "Connection: close\r\n\r\n"
        connection.send(content: Data(headerText.utf8), completion: .contentProcessed { [weak self] _ in
            self?.sendChunk(remaining: length)
        })
    }

    private func sendChunk(remaining: Int64) {
        guard remaining > 0, let handle = fileHandle else {
            finish()
            return
        }
        let wanted = Int(min(256 * 1024, remaining))
        guard let chunk = try? handle.read(upToCount: wanted), !chunk.isEmpty else {
            finish()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] _ in
            self?.sendChunk(remaining: remaining - Int64(chunk.count))
        })
    }

    private func respondSimple(status: String) {
        let body = Data("\(status)\n".utf8)
        let text = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(text.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func finish() {
        try? fileHandle?.close()
        fileHandle = nil
        connection.cancel()
        onFinished?()
    }

    private static func mime(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "mp4": return "video/mp4"
        case "m4s": return "video/iso.segment"
        default: return "application/octet-stream"
        }
    }
}
