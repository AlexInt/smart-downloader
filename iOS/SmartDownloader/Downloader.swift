import Foundation
import CommonCrypto

// MARK: - 状态与错误

enum TaskState: Equatable {
    case waiting
    case parsing
    case downloading
    case saving
    case done
    case failed(String)
}

enum DownloadError: LocalizedError {
    case badStatus(Int)
    case notMediaPlaylist
    case emptySegments
    case missingKey
    case decryptFailed(Int32)
    case shortSegment(Int, Int)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "HTTP 状态码 \(code)"
        case .notMediaPlaylist: return "不是有效的 m3u8 媒体播放列表"
        case .emptySegments: return "播放列表中没有切片"
        case .missingKey: return "解密密钥下载失败"
        case .decryptFailed(let status): return "AES 解密失败 (CCCrypt=\(status))"
        case .shortSegment(let expected, let got): return "切片下载不完整 (期望 \(expected) 字节, 实得 \(got))"
        }
    }
}

final class DownloadTask: ObservableObject, Identifiable {
    let id = UUID()
    let url: String
    @Published var title: String
    @Published var state: TaskState = .waiting
    @Published var current = 0
    @Published var total = 0
    @Published var outputURL: URL?
    /// true: outputURL 指向本地 HLS 文件夹内的 playlist.m3u8，播放需经内置本地 HTTP 服务
    var isHLSFolder = false
    /// 启动时扫描本地目录得到的历史条目（无下载过程）
    var isFromLibrary = false

    init(url: String, title: String) {
        self.url = url
        self.title = title
    }

    var displayName: String {
        guard let url = outputURL else { return "" }
        return isHLSFolder ? url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent
    }
}

// MARK: - 下载管理（UI 层状态）

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var tasks: [DownloadTask] = []
    @Published private(set) var foundURLs: [String] = []

    init() { loadLibrary() }

    /// 嗅探脚本回传的 m3u8 地址（去重、限量）
    func recordFound(urlString: String) {
        guard urlString.hasPrefix("http"), urlString.lowercased().contains(".m3u8") else { return }
        guard !foundURLs.contains(urlString) else { return }
        foundURLs.append(urlString)
        if foundURLs.count > 20 { foundURLs.removeFirst(foundURLs.count - 20) }
    }

    func startDownload(urlString: String, title rawTitle: String) {
        let base = DownloadEngine.sanitizeTitle(rawTitle) ?? DownloadEngine.timestampName()
        let task = DownloadTask(url: urlString, title: base)
        tasks.insert(task, at: 0)
        Task {
            await DownloadEngine().run(task: task)
        }
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            let task = tasks[index]
            if let url = task.outputURL {
                // HLS 条目删除整个文件夹，文件条目删除文件
                let target = task.isHLSFolder ? url.deletingLastPathComponent() : url
                try? FileManager.default.removeItem(at: target)
            }
        }
        for index in offsets.sorted(by: >) where index < tasks.count {
            tasks.remove(at: index)
        }
    }

    /// 启动时扫描沙盒: HLS 文件夹(含 playlist.m3u8) + 单独的 mp4/m4v/mov 文件
    private func loadLibrary() {
        let fm = FileManager.default
        let dir = DownloadEngine.downloadsDir
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                let playlist = entry.appendingPathComponent("playlist.m3u8")
                guard fm.fileExists(atPath: playlist.path) else { continue }
                let task = DownloadTask(url: "", title: entry.lastPathComponent)
                task.state = .done
                task.outputURL = playlist
                task.isHLSFolder = true
                task.isFromLibrary = true
                tasks.append(task)
            } else if ["mp4", "m4v", "mov"].contains(entry.pathExtension.lowercased()) {
                let task = DownloadTask(url: "", title: entry.deletingPathExtension().lastPathComponent)
                task.state = .done
                task.outputURL = entry
                task.isFromLibrary = true
                tasks.append(task)
            }
        }
    }
}

// MARK: - 下载核心（Swift 版 M3U8Downloader）

/// 流程: 解析 m3u8(多级选流) -> 预取 AES 密钥 -> 并发切片下载+解密(逐个落盘)
///       -> 保存为本地 HLS 文件夹(重写播放列表, 去掉 KEY 行)。
/// 播放走内置本地 HTTP 服务 + AVPlayer 原生 HLS（AVFoundation 无法播裸 TS，也无法直接播文件版 m3u8）。
/// 任一切片重试后仍失败则整个任务失败（不做缺洞合并）。
final class DownloadEngine {
    static let maxConcurrency = 6

    static var downloadsDir: URL {
        // 冒烟测试可用环境变量重定向输出目录，避免写入用户目录
        if let custom = ProcessInfo.processInfo.environment["SMARTDOWNLOADER_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    // MARK: 主流程

    func run(task: DownloadTask) async {
        await setTask(task) { $0.state = .parsing }
        do {
            guard let startURL = URL(string: task.url), startURL.scheme != nil else {
                throw DownloadError.notMediaPlaylist
            }

            var playlistURL = startURL
            var text = try await Self.fetchText(playlistURL)

            // 多级播放列表：逐层选最高带宽子列表（最多 3 层）
            for _ in 0..<3 {
                if let best = Self.bestVariantURI(in: text) {
                    playlistURL = URL(string: best, relativeTo: playlistURL)?.absoluteURL ?? playlistURL
                    text = try await Self.fetchText(playlistURL)
                } else {
                    break
                }
            }

            let playlist = try Self.parseMediaPlaylist(text: text, base: playlistURL)
            guard !playlist.segments.isEmpty else { throw DownloadError.emptySegments }

            await setTask(task) {
                $0.total = playlist.segments.count
                $0.state = .downloading
            }

            // 预取解密密钥（整个播放列表通常共用一把）
            var keys: [String: Data] = [:]
            for keyString in playlist.keyURLs {
                guard let keyURL = URL(string: keyString) else { continue }
                keys[keyString] = try await Self.fetchData(keyURL)
            }

            // fMP4 初始化段 (EXT-X-MAP)
            var initData: Data?
            if let mapURL = playlist.initURL {
                initData = try await Self.fetchData(mapURL)
            }

            // 切片先落盘到临时目录，避免长视频内存峰值
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("dl_" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let segments = playlist.segments
            var finished = 0
            while finished < segments.count {
                let end = min(finished + Self.maxConcurrency, segments.count)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for index in finished..<end {
                        let segment = segments[index]
                        group.addTask {
                            try await Self.processSegment(segment, index: index,
                                                          tempDir: tempDir, keys: keys)
                        }
                    }
                    try await group.waitForAll()
                }
                finished = end
                let done = finished
                await setTask(task) { $0.current = done }
            }

            // ---- 保存为本地 HLS 文件夹 ----
            await setTask(task) { $0.state = .saving }
            let isTS = Self.isTSStream(tempDir: tempDir, hasInit: initData != nil)

            try FileManager.default.createDirectory(at: Self.downloadsDir, withIntermediateDirectories: true)
            let folderName = Self.uniqueFolderName(base: task.title, in: Self.downloadsDir)
            let folder = Self.downloadsDir.appendingPathComponent(folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let ext = isTS ? "ts" : "m4s"
            for index in 0..<segments.count {
                let source = tempDir.appendingPathComponent(Self.tempSegName(index))
                let destination = folder.appendingPathComponent(Self.finalSegName(index, ext: ext))
                try FileManager.default.moveItem(at: source, to: destination)
            }
            if !isTS, let initData {
                try initData.write(to: folder.appendingPathComponent("init.mp4"))
            }
            let playlistText = Self.buildLocalPlaylist(segments: segments, isTS: isTS)
            let playlistURL2 = folder.appendingPathComponent("playlist.m3u8")
            try playlistText.write(to: playlistURL2, atomically: true, encoding: .utf8)

            await setTask(task) {
                $0.state = .done
                $0.outputURL = playlistURL2
                $0.isHLSFolder = true
            }
        } catch {
            var message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let host = URL(string: task.url)?.host { message += " (\(host))" }
            await setTask(task) { $0.state = .failed(message) }
        }
    }

    private func setTask(_ task: DownloadTask, _ mutate: @MainActor (DownloadTask) -> Void) async {
        await MainActor.run { mutate(task) }
    }

    // MARK: 网络会话（个人使用：信任所有证书，允许自签名/过期证书站点）

    /// 部分视频资源站点的 WAF 会拦截非浏览器请求：默认 URLSession 头会被 RST 并报成
    /// “A TLS error caused the secure connection to fail.”（-1200）。
    /// 实测同一 TLS 栈换浏览器请求头即可通过，所有请求统一伪装成 Safari。
    static let browserHeaders: [(String, String)] = [
        ("User-Agent",
         "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 "
         + "(KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"),
        ("Accept", "*/*"),
        ("Accept-Language", "zh-CN,zh;q=0.9"),
    ]

    final class TrustAllSessionDelegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    private enum SharedSession {
        static let session: URLSession = {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 600
            return URLSession(configuration: config, delegate: TrustAllSessionDelegate(), delegateQueue: nil)
        }()
    }

    // MARK: WebKit 兜底（WAF 按 TLS 指纹掐 URLSession 连接时降级，成功后 sticky）

    /// 冒烟测试强制走 WebKit 通道（验证兜底链路用）
    static let forceWebKit = ProcessInfo.processInfo.environment["SMARTDOWNLOADER_FORCE_WEBKIT"] == "1"
    /// 一旦 WebKit 兜底成功即置位，后续请求跳过注定失败的 URLSession
    nonisolated(unsafe) static var preferWebKit = false

    /// 连接层错误：WAF TLS 指纹拦截的典型表现（握手被 RST / 无法建连），值得降级
    private static func isConnectionLevelError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .secureConnectionFailed, .networkConnectionLost, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private static func fetchViaWebKit(_ url: URL, byteRange: ByteRange?) async throws -> Data {
        try await WebKitFetcher.shared.fetch(url: url, byteRange: byteRange)
    }

    static func fetchData(_ url: URL, retries: Int = 3, byteRange: ByteRange? = nil) async throws -> Data {
        if forceWebKit || preferWebKit {
            return try await fetchViaWebKit(url, byteRange: byteRange)
        }
        var lastError: Error = DownloadError.badStatus(-1)
        for attempt in 0...retries {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                for (field, value) in Self.browserHeaders {
                    request.setValue(value, forHTTPHeaderField: field)
                }
                var expectedLength: Int?
                if let range = byteRange, let offset = range.offset {
                    request.setValue("bytes=\(offset)-\(offset + range.length - 1)",
                                     forHTTPHeaderField: "Range")
                    expectedLength = range.length
                }
                let (payload, response) = try await SharedSession.session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw DownloadError.badStatus(http.statusCode)
                }
                var data = payload
                if let expected = expectedLength {
                    // 服务器忽略 Range 时可能返回全量，截取所需前缀；不足则报错
                    guard data.count >= expected else {
                        throw DownloadError.shortSegment(expected, data.count)
                    }
                    if data.count > expected {
                        data = data.prefix(expected)
                    }
                }
                return data
            } catch {
                lastError = error
                // 连接层错误(WAF TLS 指纹拦截的典型表现): 立即降级 WebKit 网络栈，成功后 sticky
                if isConnectionLevelError(error),
                   let data = try? await fetchViaWebKit(url, byteRange: byteRange) {
                    preferWebKit = true
                    return data
                }
                if attempt == retries { throw lastError }
                let delay = min(20.0, pow(2.0, Double(attempt + 1)))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError
    }

    static func fetchText(_ url: URL) async throws -> String {
        let data = try await fetchData(url)
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    // MARK: m3u8 解析

    struct ByteRange {
        var length: Int
        var offset: Int?
    }

    struct ParsedSegment {
        let url: URL
        let keyURL: URL?
        let iv: Data?
        var byteRange: ByteRange?
        var duration: Double = 0
    }

    struct ParsedPlaylist {
        var segments: [ParsedSegment] = []
        var keyURLs: Set<String> = []
        var initURL: URL?
    }

    /// 在 master 播放列表中取最高 BANDWIDTH 的子列表地址；媒体列表返回 nil
    static func bestVariantURI(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        var best: (bandwidth: Int, uri: String)?
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                var probe = index + 1
                while probe < lines.count {
                    let next = lines[probe].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty { probe += 1; continue }
                    if next.hasPrefix("#") { break }
                    let bandwidth = Self.bandwidth(of: line)
                    if best == nil || bandwidth > best!.bandwidth {
                        best = (bandwidth, next)
                    }
                    break
                }
            }
            index += 1
        }
        return best?.uri
    }

    private static func bandwidth(of line: String) -> Int {
        guard let range = line.range(of: #"BANDWIDTH=(\d+)"#, options: .regularExpression) else { return 0 }
        return Int(line[range].dropFirst("BANDWIDTH=".count)) ?? 0
    }

    static func parseMediaPlaylist(text: String, base: URL) throws -> ParsedPlaylist {
        var result = ParsedPlaylist()
        var mediaSequence = 0
        var currentKey: URL?
        var currentIV: Data?
        var index = 0
        var pendingByteRange: ByteRange?
        var pendingDuration: Double?
        // BYTERANGE 缺省 offset 时，接续同 URI 上一段的结束位置 (RFC 8216)
        var uriOffsets: [String: Int] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)
                    .trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                if line.contains("METHOD=NONE") {
                    currentKey = nil
                    currentIV = nil
                } else if let uri = Self.quotedValue(after: "URI", in: line) {
                    currentKey = URL(string: uri, relativeTo: base)?.absoluteURL
                    currentIV = Self.hexIV(in: line)
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = Self.quotedValue(after: "URI", in: line) {
                    result.initURL = URL(string: uri, relativeTo: base)?.absoluteURL
                }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingByteRange = Self.parseByteRange(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count)
                let firstField = value.split(separator: ",").first ?? ""
                pendingDuration = Double(firstField.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#") {
                continue
            } else {
                guard let segmentURL = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                // 规范缺省 IV = 该切片的 media sequence number（修正 Python 版全 0 的 bug）
                let iv = currentIV ?? Self.sequenceIV(mediaSequence + index)
                var byteRange = pendingByteRange
                if byteRange != nil {
                    let uriKey = segmentURL.absoluteString
                    let offset = byteRange!.offset ?? uriOffsets[uriKey] ?? 0
                    byteRange!.offset = offset
                    uriOffsets[uriKey] = offset + byteRange!.length
                }
                let segment = ParsedSegment(url: segmentURL, keyURL: currentKey, iv: iv,
                                            byteRange: byteRange, duration: pendingDuration ?? 0)
                result.segments.append(segment)
                if let key = currentKey { result.keyURLs.insert(key.absoluteString) }
                index += 1
                pendingByteRange = nil
                pendingDuration = nil
            }
        }
        return result
    }

    /// 读取属性 URI="..." 的引号值（URL 可能含逗号，不能用逗号切分）
    private static func quotedValue(after key: String, in line: String) -> String? {
        guard let keyRange = line.range(of: key + "=\"") else { return nil }
        let rest = line[keyRange.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<end])
    }

    /// 解析 #EXT-X-BYTERANGE:<n>[@<o>]
    private static func parseByteRange(_ raw: Substring) -> ByteRange? {
        let parts = raw.split(separator: "@")
        guard let length = Int(parts[0].trimmingCharacters(in: .whitespaces)), length > 0 else { return nil }
        var offset: Int?
        if parts.count > 1 {
            offset = Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return ByteRange(length: length, offset: offset)
    }

    /// 读取 IV=0x... 十六进制 IV
    private static func hexIV(in line: String) -> Data? {
        guard let range = line.range(of: "IV=0x") else { return nil }
        var hex = ""
        for char in line[range.upperBound...] {
            if char.isHexDigit { hex.append(char) } else { break }
        }
        return Self.parseHexIV(hex)
    }

    /// 十六进制字符串 -> 16 字节 IV（不足 128 位按规范左补零）
    private static func parseHexIV(_ rawHex: String) -> Data? {
        var hex = rawHex.lowercased()
        guard !hex.isEmpty else { return nil }
        if hex.count % 2 == 1 { hex = "0" + hex }
        var bytes = [UInt8]()
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            guard let byte = UInt8(hex[cursor..<next], radix: 16) else { return nil }
            bytes.append(byte)
            cursor = next
        }
        guard bytes.count <= 16 else { return nil }
        while bytes.count < 16 { bytes.insert(0, at: 0) }
        return Data(bytes)
    }

    /// media sequence number -> 16 字节大端 IV
    static func sequenceIV(_ sequence: Int) -> Data {
        var data = Data(repeating: 0, count: 8)
        let value = UInt64(max(0, sequence)).bigEndian
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        return data
    }

    // MARK: 切片处理

    static func processSegment(_ segment: ParsedSegment, index: Int,
                               tempDir: URL, keys: [String: Data]) async throws {
        var data = try await fetchData(segment.url, byteRange: segment.byteRange)
        if let keyURL = segment.keyURL {
            guard let key = keys[keyURL.absoluteString] else { throw DownloadError.missingKey }
            let iv = segment.iv ?? Data(repeating: 0, count: 16)
            data = try aesDecrypt(data, key: key, iv: iv)
        }
        try data.write(to: tempDir.appendingPathComponent(tempSegName(index)), options: .atomic)
    }

    static func tempSegName(_ index: Int) -> String {
        String(format: "seg_%06d.bin", index)
    }

    static func finalSegName(_ index: Int, ext: String) -> String {
        String(format: "seg_%06d.%@", index, ext)
    }

    /// AES-128-CBC 原始解密（无填充；与现网可用行为一致，尾部填充字节由 HLS 播放层忽略）
    static func aesDecrypt(_ input: Data, key: Data, iv: Data) throws -> Data {
        let blockSize = kCCBlockSizeAES128
        guard input.count % blockSize == 0, !key.isEmpty, iv.count == blockSize else {
            throw DownloadError.decryptFailed(-1)
        }
        var output = Data(count: input.count)
        var moved = 0
        var status: CCCryptorStatus = CCCryptorStatus(kCCSuccess)
        let outputCapacity = output.count
        output.withUnsafeMutableBytes { (outPtr: UnsafeMutableRawBufferPointer) in
            input.withUnsafeBytes { (inPtr: UnsafeRawBufferPointer) in
                key.withUnsafeBytes { (keyPtr: UnsafeRawBufferPointer) in
                    iv.withUnsafeBytes { (ivPtr: UnsafeRawBufferPointer) in
                        status = CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(0), // CBC 模式，无填充
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, input.count,
                            outPtr.baseAddress, outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw DownloadError.decryptFailed(status) }
        output.count = moved
        return output
    }

    // MARK: 本地 HLS 文件夹

    /// 首切片 0x47 同步字节判定 TS 流；有 init 段 (EXT-X-MAP) 则视为 fMP4
    static func isTSStream(tempDir: URL, hasInit: Bool) -> Bool {
        guard !hasInit else { return false }
        guard let handle = try? FileHandle(forReadingFrom: tempDir.appendingPathComponent(tempSegName(0))) else {
            return false
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1)) ?? Data()
        return head.first == 0x47
    }

    /// 生成本地播放列表：切片已解密，无 KEY 行；文件名指向本地文件
    static func buildLocalPlaylist(segments: [ParsedSegment], isTS: Bool) -> String {
        let maxDuration = segments.map(\.duration).max() ?? 0
        let target = max(1, Int(maxDuration.rounded(.up)))
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-PLAYLIST-TYPE:VOD",
        ]
        if !isTS {
            lines.append(#"#EXT-X-MAP:URI="init.mp4""#)
        }
        let ext = isTS ? "ts" : "m4s"
        for (index, segment) in segments.enumerated() {
            let duration = String(format: "%.5f", max(0.001, segment.duration))
            lines.append("#EXTINF:\(duration),")
            lines.append("seg_\(String(format: "%06d", index)).\(ext)")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: 文件名

    static func sanitizeTitle(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let scalars = raw.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "._- ".unicodeScalars.contains($0)
        }
        var text = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: " ", with: "_")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        if text.count > 80 { text = String(text.prefix(80)) }
        return text.isEmpty ? nil : text
    }

    static func timestampName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    static func uniqueFolderName(base: String, in dir: URL) -> String {
        var candidate = base
        var counter = 1
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = "\(base)(\(counter))"
            counter += 1
        }
        return candidate
    }
}
