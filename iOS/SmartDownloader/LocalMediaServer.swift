import Foundation
import Network

/// 内置本地 HTTP 服务：把沙盒 Downloads 目录以 http://127.0.0.1:<port>/ 暴露给 AVPlayer。
///
/// 为什么需要它：AVFoundation 无法直接播放文件版 m3u8，也无法播放裸 TS 合并文件（iOS 上没有 ffmpeg）。
/// 「本地回环 HTTP + 重写后的播放列表」是 iOS 离线 HLS 播放的标准做法。
/// 可变状态全部收敛在 stateQueue 串行队列上访问，故标注 @unchecked Sendable
final class LocalMediaServer: @unchecked Sendable {
    static let shared = LocalMediaServer()

    private let stateQueue = DispatchQueue(label: "LocalMediaServer.state")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var startContinuation: CheckedContinuation<UInt16, Never>?
    private var started = false
    private var handlers: [ObjectIdentifier: HTTPConnectionHandler] = [:]

    static var rootDirectory: URL { DownloadEngine.downloadsDir }

    /// 启动监听（幂等），返回端口；0 表示启动失败
    func start() async -> UInt16 {
        await withCheckedContinuation { (continuation: CheckedContinuation<UInt16, Never>) in
            stateQueue.async {
                if self.started {
                    continuation.resume(returning: self.port)
                    return
                }
                self.started = true
                self.startContinuation = continuation
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
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.stateQueue.async { self.finishStart(port: listener.port?.rawValue ?? 0) }
                        case .failed:
                            self.stateQueue.async { self.finishStart(port: 0) }
                        default:
                            break
                        }
                    }
                    listener.start(queue: DispatchQueue(label: "LocalMediaServer.connections"))
                } catch {
                    if let continuation = self.startContinuation {
                        self.startContinuation = nil
                        continuation.resume(returning: 0)
                    }
                }
            }
        }
    }

    private func finishStart(port value: UInt16) {
        port = value
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(returning: value)
        }
    }

    /// 生成本地 HLS 文件夹的播放地址
    func playbackURL(forFolder folder: URL) async -> URL {
        let port = await start()
        let encoded = folder.lastPathComponent
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folder.lastPathComponent
        return URL(string: "http://127.0.0.1:\(port)/\(encoded)/playlist.m3u8")
            ?? folder.appendingPathComponent("playlist.m3u8")
    }
}

/// 单连接处理：解析 HTTP GET（支持 Range），回送文件后关闭
/// 单连接的状态只在该连接的回调（同一队列串行回调）中访问，故标注 @unchecked Sendable
final class HTTPConnectionHandler: @unchecked Sendable {
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
