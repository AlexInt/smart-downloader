import Darwin
import Foundation
import Combine
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
    var url: String
    @Published var title: String
    /// 所属剧名（选集下载时非空；nil = 散装单条目）。落盘到 Downloads/<剧名>/<集>/
    let seriesName: String?
    @Published var state: TaskState = .waiting
    @Published var current = 0
    @Published var total = 0
    @Published var outputURL: URL?
    /// true: outputURL 指向本地 HLS 文件夹内的 playlist.m3u8，播放需经内置本地 HTTP 服务
    var isHLSFolder = false
    /// 启动时扫描本地目录得到的历史条目（无下载过程）
    var isFromLibrary = false

    init(url: String, title: String, seriesName: String? = nil) {
        self.url = url
        self.title = title
        self.seriesName = seriesName
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
    /// 转发每个任务的状态变化，驱动下载页分区实时重算（否则完成任务要重启才换区）
    private var stateCancellables: Set<AnyCancellable> = []

    init() { loadLibrary() }

    /// 嗅探脚本回传的 m3u8 地址（去重、限量）
    func recordFound(urlString: String) {
        guard urlString.hasPrefix("http"), urlString.lowercased().contains(".m3u8") else { return }
        guard !foundURLs.contains(urlString) else { return }
        foundURLs.append(urlString)
        if foundURLs.count > 20 { foundURLs.removeFirst(foundURLs.count - 20) }
    }

    @discardableResult
    func startDownload(urlString: String, title rawTitle: String, seriesName: String? = nil) -> DownloadTask {
        let base = DownloadEngine.sanitizeTitle(rawTitle) ?? DownloadEngine.timestampName()
        let task = DownloadTask(url: urlString, title: base, seriesName: seriesName)
        register(task)
        run(task)
        return task
    }

    /// 登记（插入列表头部，不启动）
    func register(_ task: DownloadTask) {
        tasks.insert(task, at: 0)
        observeTaskState(task)
    }

    /// 任务内部状态（进度/完成/失败）变化时转发本管理器的 objectWillChange：
    /// 分区归属依赖任务 state，不转发则完成后要重启 App 才换区
    private func observeTaskState(_ task: DownloadTask) {
        task.objectWillChange
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
            .store(in: &stateCancellables)
    }

    /// 启动已登记任务；onFinish 在任务结束（成功/失败）后于主线程回调（多集调度依赖它接力）
    func run(_ task: DownloadTask, onFinish: (@MainActor () -> Void)? = nil) {
        Task { @MainActor in
            await DownloadEngine().run(task: task)
            onFinish?()
        }
    }

    func task(withID id: UUID) -> DownloadTask? { tasks.first { $0.id == id } }
    func containsTask(id: UUID) -> Bool { tasks.contains { $0.id == id } }

    /// 多集调度用：登记一个等待中的集任务（不启动，由 SeriesDownloadCoordinator 统一调度）
    func registerEpisode(title: String, seriesName: String) -> DownloadTask {
        let task = DownloadTask(url: "", title: title, seriesName: seriesName)
        tasks.insert(task, at: 0)
        observeTaskState(task)
        return task
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

    /// 删除单个任务及其沙盒文件/文件夹（按任务对象，剧详情页左滑删除用）
    func remove(_ task: DownloadTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        delete(at: IndexSet(integer: index))
    }

    /// 删除整部剧：移除其全部任务条目与剧目录（剧详情页用户主动触发）
    func deleteSeries(_ seriesName: String) {
        let dirs = Set(tasks.filter { $0.seriesName == seriesName }.compactMap { task -> URL? in
            guard let playlist = task.outputURL else { return nil }
            // playlist 位于 .../<剧名>/<集>/playlist.m3u8
            return playlist.deletingLastPathComponent().deletingLastPathComponent()
        })
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        tasks.removeAll { $0.seriesName == seriesName }
    }

    /// 选集面板「已下载」检测：文件系统就是账本（不引入数据库）。
    /// 剧目录下含 playlist.m3u8 的子目录算已下载，集号从目录名（第NN集[ (n) ]）解析；
    /// 残缺目录（无 playlist.m3u8，下载中断产物）不算已下载，可重下。
    func downloadedEpisodeSorts(forSeries rawSeriesName: String) -> Set<Int> {
        let fm = FileManager.default
        let seriesDir = DownloadEngine.seriesDirectory(for: rawSeriesName)
        guard let subs = try? fm.contentsOfDirectory(at: seriesDir, includingPropertiesForKeys: nil) else { return [] }
        var sorts = Set<Int>()
        for sub in subs {
            guard fm.fileExists(atPath: sub.appendingPathComponent("playlist.m3u8").path) else { continue }
            if let sort = Self.episodeSort(fromFolderName: sub.lastPathComponent) {
                sorts.insert(sort)
            }
        }
        return sorts
    }

    /// 旧版散装下载收编：把顶层「标题含剧名+第N集」的旧文件夹搬进 Downloads/<剧名>/第NN集/。
    /// 只搬不删（move/rename，数据不丢）；搬完后正常两级扫描即可识别为已下载集。
    /// 在选集面板拿到剧名后调用，幂等：搬过一次后不再有匹配项。
    func collectLegacyEpisodes(forSeries rawSeriesName: String) {
        let fm = FileManager.default
        let seriesDir = DownloadEngine.seriesDirectory(for: rawSeriesName)
        guard let normalized = DownloadEngine.sanitizeTitle(rawSeriesName),
              let entries = try? fm.contentsOfDirectory(at: DownloadEngine.downloadsDir,
                                                        includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory,
                  entry.lastPathComponent != seriesDir.lastPathComponent,
                  fm.fileExists(atPath: entry.appendingPathComponent("playlist.m3u8").path),
                  let sort = Self.legacyEpisodeSort(folderName: entry.lastPathComponent,
                                                    seriesName: normalized) else { continue }
            do {
                try fm.createDirectory(at: seriesDir, withIntermediateDirectories: true)
                let base = String(format: "第%02d集", sort)
                let name = DownloadEngine.uniqueFolderName(base: base, in: seriesDir)
                try fm.moveItem(at: entry, to: seriesDir.appendingPathComponent(name, isDirectory: true))
                print("LIBRARY: 收编旧下载 \(entry.lastPathComponent) -> \(name)")
            } catch {
                print("LIBRARY: 收编失败 \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// 重扫沙盒库（收编后调用，让下载页的剧集/散装分组立即反映磁盘现状）
    func refreshLibrary() {
        tasks.removeAll { $0.isFromLibrary }
        loadLibrary()
    }

    /// 目录名 -> 集号：第01集 / 第01集(1)（重下防覆盖后缀）；不匹配返回 nil
    static func episodeSort(fromFolderName name: String) -> Int? {
        guard name.hasPrefix("第") else { return nil }
        let body = name.dropFirst()
        guard let range = body.range(of: "集") else { return nil }
        let digits = body[..<range.lowerBound]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// 旧版散装文件夹名 -> 集号：要求含剧名且含「第N集」数字段（页面标题清理营销词后的形态，如 "剧名 第03集"）
    static func legacyEpisodeSort(folderName: String, seriesName: String) -> Int? {
        guard folderName.contains(seriesName) else { return nil }
        guard let start = folderName.range(of: "第")?.upperBound else { return nil }
        guard let end = folderName[start...].firstIndex(of: "集") else { return nil }
        let digits = folderName[start..<end]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// 启动时扫描沙盒（两级）:
    ///   Downloads/<标题>/playlist.m3u8      -> 散装条目
    ///   Downloads/<剧名>/<集>/playlist.m3u8 -> 剧目条目（seriesName = 剧目录名）
    ///   Downloads/*.mp4 等单文件            -> 散装条目
    private func loadLibrary() {
        let fm = FileManager.default
        let dir = DownloadEngine.downloadsDir
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        func makeHLSTask(title: String, playlist: URL, series: String?) -> DownloadTask {
            let task = DownloadTask(url: "", title: title, seriesName: series)
            task.state = .done
            task.outputURL = playlist
            task.isHLSFolder = true
            task.isFromLibrary = true
            return task
        }
        for entry in entries.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                let playlist = entry.appendingPathComponent("playlist.m3u8")
                if fm.fileExists(atPath: playlist.path) {
                    // 散装 HLS 条目
                    tasks.append(makeHLSTask(title: entry.lastPathComponent, playlist: playlist, series: nil))
                    continue
                }
                // 剧目录：其下每个含 playlist.m3u8 的子目录算一集
                guard let subs = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) else { continue }
                for ep in subs.filter({ fm.fileExists(atPath: $0.appendingPathComponent("playlist.m3u8").path) })
                              .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    tasks.append(makeHLSTask(title: ep.lastPathComponent,
                                             playlist: ep.appendingPathComponent("playlist.m3u8"),
                                             series: entry.lastPathComponent))
                }
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

    /// 剧目录：选集下载落盘与「已下载」检测共用同一命名规则（sanitize 后的剧名）
    static func seriesDirectory(for rawSeriesName: String) -> URL {
        downloadsDir.appendingPathComponent(sanitizeTitle(rawSeriesName) ?? rawSeriesName, isDirectory: true)
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

            // 选集下载落到 Downloads/<剧名>/<集>/，散装仍是 Downloads/<标题>/
            let parentDir = task.seriesName.map { Self.seriesDirectory(for: $0) } ?? Self.downloadsDir
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            let folderName = Self.uniqueFolderName(base: task.title, in: parentDir)
            let folder = parentDir.appendingPathComponent(folderName, isDirectory: true)
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
            // 连接层失败几乎必然是网络路径被 CDN/WAF 拦截（蜂窝网络下常见），
            // 此时网页内视频同样播不出来，客户端无解，给出可操作提示
            if Self.isConnectionLevelError(error) {
                message += "；当前网络无法连接该视频源（蜂窝网络下常见，网页内视频也会同样卡住），请换 WiFi 或开启 VPN 后重试"
            }
            await setTask(task) { $0.state = .failed(message) }
        }
    }

    private func setTask(_ task: DownloadTask, _ mutate: @MainActor (DownloadTask) -> Void) async {
        await MainActor.run {
            mutate(task)
            // print 到 stdout：Xcode 控制台 / devicectl --console 可见，便于真机日志定位
            print("DL[\(task.title)]: \(task.state) \(task.current)/\(task.total)")
        }
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
        // 该域名已证实需 IP 直连（域名连接被网络侧 RST），直接走，省去每次必败的常规连接
        if let host = url.host, ipDirectHosts.contains(host),
           let data = try? await fetchIPDirect(url, byteRange: byteRange) {
            return data
        }
        var lastError: Error = DownloadError.badStatus(-1)
        for attempt in 0...retries {
            do {
                let (request, expectedLength) = makeRequest(url: url, byteRange: byteRange)
                let (payload, response) = try await SharedSession.session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw DownloadError.badStatus(http.statusCode)
                }
                return try trimToRange(payload, expected: expectedLength)
            } catch {
                lastError = error
                if isConnectionLevelError(error) {
                    print("DL[\(url.host ?? "")]: URLSession 连接层错误(\(error.localizedDescription))")
                    // 先试 IP 直连（域名 SNI 被网络侧 RST 时有效），再试 WebKit（客户端 TLS 指纹被拦时有效）
                    if let host = url.host,
                       let data = try? await fetchIPDirect(url, byteRange: byteRange) {
                        ipDirectHosts.insert(host)
                        print("DL[\(host)]: ✅ IP 直连成功，该域名后续请求直接走 IP")
                        return data
                    }
                    print("DL[\(url.host ?? "")]: IP 直连也失败，尝试 WebKit 兜底…")
                    do {
                        let data = try await fetchViaWebKit(url, byteRange: byteRange)
                        preferWebKit = true
                        print("DL[\(url.host ?? "")]: ✅ WebKit 兜底成功，后续请求直接走 WebKit")
                        return data
                    } catch {
                        print("DL[\(url.host ?? "")]: ⚠️ WebKit 兜底也失败: \(error.localizedDescription)")
                    }
                }
                if attempt == retries { throw lastError }
                let delay = min(20.0, pow(2.0, Double(attempt + 1)))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError
    }

    private static func makeRequest(url: URL, byteRange: ByteRange?) -> (URLRequest, Int?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (field, value) in browserHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        var expectedLength: Int?
        if let range = byteRange, let offset = range.offset {
            request.setValue("bytes=\(offset)-\(offset + range.length - 1)",
                             forHTTPHeaderField: "Range")
            expectedLength = range.length
        }
        return (request, expectedLength)
    }

    /// 服务器忽略 Range 返回全量时截取所需前缀；不足则报错
    private static func trimToRange(_ payload: Data, expected: Int?) throws -> Data {
        guard let expected else { return payload }
        guard payload.count >= expected else {
            throw DownloadError.shortSegment(expected, payload.count)
        }
        return payload.count > expected ? Data(payload.prefix(expected)) : payload
    }

    // MARK: IP 直连（绕过基于域名/SNI 的网络侧拦截）
    //
    // 蜂窝网络下运营商/防火墙可能按 ClientHello 中的 SNI 域名掐连接（握手期间 RST，
    // 所有客户端无一幸免，网页内视频同样播不出）。对策：域名解析成 IP 后直接连 IP
    // （URL 用 IP 时 TLS 层不携带 SNI），Host 头置原域名供 CDN 路由正确站点；
    // 证书与 IP 不匹配由 TrustAllSessionDelegate 兜底。
    // 若拦截是按目的 IP 进行的（而非域名），此法同样无效，自然降级到 WebKit/报错。

    /// 已证实 IP 直连可用的域名（sticky）
    nonisolated(unsafe) static var ipDirectHosts: Set<String> = []
    /// 域名 -> [IP] 解析缓存（进程内）
    nonisolated(unsafe) static var dnsCache: [String: [String]] = [:]

    private static func isLiteralIP(_ host: String) -> Bool {
        var v4 = in_addr(); var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    /// 解析域名（getaddrinfo 为阻塞调用，放后台线程；优先 IPv4），成功后缓存
    static func resolveHost(_ host: String) async -> [String] {
        if let cached = dnsCache[host], !cached.isEmpty { return cached }
        let ips: [String] = await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
            defer { freeaddrinfo(first) }
            var all: [String] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let node = cursor {
                defer { cursor = node.pointee.ai_next }
                guard let sa = node.pointee.ai_addr else { continue }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if sa.pointee.sa_family == sa_family_t(AF_INET) {
                    var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    if inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                        all.append(String(cString: buffer))
                    }
                } else if sa.pointee.sa_family == sa_family_t(AF_INET6) {
                    var addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                    if inet_ntop(AF_INET6, &addr.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                        all.append(String(cString: buffer))
                    }
                }
            }
            let ipv4 = all.filter { !$0.contains(":") }
            return ipv4.isEmpty ? all : ipv4
        }.value
        if !ips.isEmpty { dnsCache[host] = ips }
        return ips
    }

    /// IP 直连：URL 换成 IP（无 SNI），Host 头置原域名；逐个尝试解析出的 IP（最多 3 个）
    static func fetchIPDirect(_ url: URL, byteRange: ByteRange?) async throws -> Data {
        guard let host = url.host, !isLiteralIP(host) else {
            throw DownloadError.badStatus(-3)
        }
        let ips = await resolveHost(host)
        guard !ips.isEmpty else {
            throw DownloadError.badStatus(-3)  // DNS 解析不到 IP
        }
        var lastIPError: Error = DownloadError.badStatus(-3)
        for ip in ips.prefix(3) {
            guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            comps.host = ip.contains(":") ? "[\(ip)]" : ip
            guard let ipURL = comps.url else { continue }
            do {
                var (request, expectedLength) = makeRequest(url: ipURL, byteRange: byteRange)
                request.setValue(host, forHTTPHeaderField: "Host")
                let (payload, response) = try await SharedSession.session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw DownloadError.badStatus(http.statusCode)
                }
                return try trimToRange(payload, expected: expectedLength)
            } catch {
                lastIPError = error
                continue  // 该 IP 不行，换下一个
            }
        }
        throw lastIPError
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

    /// 去掉浏览器标题里的站点后缀与营销词（如 "某剧 第1集在线观看 - 某站" -> "某剧 第1集"）
    static func cleanTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 末尾 " - 站点名" / " | 站点名"：尾部不含数字（集数）时视为站名丢弃
        if let range = text.range(of: #"\s*[-–—|｜]\s*[^-–—|｜]{1,20}$"#, options: .regularExpression) {
            let tail = String(text[range])
            if tail.rangeOfCharacter(from: .decimalDigits) == nil {
                text.removeSubrange(range)
            }
        }
        // 常见营销词
        for word in ["免费在线观看", "在线观看", "高清在线", "免费播放"] {
            text = text.replacingOccurrences(of: word, with: "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitizeTitle(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let cleaned = cleanTitle(raw)
        guard !cleaned.isEmpty else { return nil }
        let scalars = cleaned.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "._- ".unicodeScalars.contains($0)
        }
        var text = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: " ", with: "_")
        // 压缩清理后残留的分隔符（"标题_-_" -> "标题"）
        text = text.replacingOccurrences(of: #"[_\-]{2,}"#, with: "_", options: .regularExpression)
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
