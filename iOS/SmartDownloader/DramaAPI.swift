import Foundation

// MARK: - 视频资源站剧集接口（站点特有逻辑独立文件，勿混入 Downloader 通用核心）
//
// 与 CLI(video_auto.py) / 冒烟(videocli.swift) 同一套协议：
//   剧集页 URL (https://<站点>/drama/{video|detail}/<剧ID>[/ep-N]/)
//   -> 登录 -> playlet 接口 -> AES-128-CBC 解密响应 -> 剧名 + 全集列表
//   每集下载前重新调接口取新鲜 auth_key 直链（与 CLI 行为一致）。
// 站点地址一律从输入 URL 推导；账号/AES 常量不硬编码、不打印，
// 运行时从随包携带的 video_auto.py 解析（与 videocli 读仓库根文件同一思路）。

/// 剧集页 URL 解析出的下载目标
struct DramaTarget: Identifiable, Hashable {
    let site: String
    let dramaID: String
    var id: String { "\(site)#\(dramaID)" }
    /// 原生剧集页内嵌 webview 加载的详情页地址
    var pageURLString: String { "\(site)/drama/detail/\(dramaID)/" }

    /// 形如 https://<站点>/drama/{video|detail}/<ID>[/ep-N]/；无法识别返回 nil
    static func parse(_ raw: String) -> DramaTarget? {
        guard let comps = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "drama",
              parts[1] == "video" || parts[1] == "detail",
              Int(parts[2]) != nil else { return nil }
        var site = "\(scheme)://\(host)"
        if let port = comps.port { site += ":\(port)" }
        return DramaTarget(site: site, dramaID: parts[2])
    }
}

struct ApiDramaEpisode: Identifiable, Equatable, Codable {
    let id: Int
    let sort: Int
    let playable: Bool
    /// 下载状态与落盘目录名（磁盘对账/下载完成回调写入缓存）
    var downloaded: Bool = false
    var folder: String? = nil
}

struct DramaInfo: Equatable {
    let name: String
    let updateStatus: String?
    let episodes: [ApiDramaEpisode]  // 已按 sort 升序；广告集已剔除
}

/// 一次选集下载的会话：登录一次，之后每集下载前重调接口保证 auth_key 新鲜
@MainActor
final class DramaSession {
    let target: DramaTarget
    private var token = ""
    private var cachedConstants: Constants?

    init(target: DramaTarget) {
        self.target = target
    }

    private struct Constants {
        let username: String
        let password: String
        let aesKey: String
        let aesIV: String
    }

    // MARK: 拉取剧集信息 / 新鲜直链

    func fetchInfo() async throws -> DramaInfo {
        let constants = try self.constants()
        token = (try? await login(constants)) ?? ""
        let data = try await fetchDramaData(constants)
        if ProcessInfo.processInfo.arguments.contains("dumpDramaMeta") {
            Self.dumpMeta(data, target: target)
        }
        guard let name = data["drama_name"] as? String,
              let episodeAll = data["episodeAll"] as? [[String: Any]] else {
            throw DramaError.badResponse
        }
        let episodes = episodeAll
            .filter { !Self.isTrue($0["is_adv"]) }
            .sorted { ($0["sort"] as? Int ?? 0) < ($1["sort"] as? Int ?? 0) }
            .map { ep in
                let access = ep["access"] as? [String: Any]
                return ApiDramaEpisode(id: ep["id"] as? Int ?? 0,
                                    sort: ep["sort"] as? Int ?? 0,
                                    playable: Self.isTrue(access?["can_play"]))
            }
        return DramaInfo(name: name, updateStatus: data["update_status"] as? String, episodes: episodes)
    }

    /// 每集下载前重调接口取新鲜直链（auth_key 有时效）
    func freshVideoURL(for episode: ApiDramaEpisode) async throws -> String {
        let constants = try self.constants()
        let data = try await fetchDramaData(constants)
        guard let episodeAll = data["episodeAll"] as? [[String: Any]],
              let fresh = episodeAll.first(where: { ($0["id"] as? Int) == episode.id && !Self.isTrue($0["is_adv"]) }) else {
            throw DramaError.episodeMissing
        }
        let url = (fresh["video_url"] as? String) ?? (fresh["video_url_h265"] as? String) ?? ""
        guard url.hasPrefix("http") else { throw DramaError.noVideoURL }
        return url
    }

    /// 调查用：启动参数 dumpDramaMeta 时——①完整字段结构写系统日志（idevicesyslog 可采）
    /// ②完整原始 JSON 落盘 Documents/DramaMeta/raw_<剧ID>.json（Finder 文件共享可拷出）
    static func dumpMeta(_ data: [String: Any], target: DramaTarget) {
        NSLog("DRAMAMETA ===== BEGIN =====")
        for key in data.keys.sorted() {
            let v = data[key]!
            if let s = v as? String {
                NSLog("DRAMAMETA \(key) = \(s.prefix(300))")
            } else if let n = v as? NSNumber {
                NSLog("DRAMAMETA \(key) = \(n)")
            } else if let d = v as? [String: Any] {
                NSLog("DRAMAMETA \(key) dict keys=\(d.keys.sorted())")
            } else if let arr = v as? [[String: Any]] {
                NSLog("DRAMAMETA \(key) list len=\(arr.count)")
                if let first = arr.first {
                    for k in first.keys.sorted() {
                        NSLog("DRAMAMETA \(key)[0].\(k) = \(String(describing: first[k]).prefix(220))")
                    }
                }
            } else {
                NSLog("DRAMAMETA \(key) = \(type(of: v))")
            }
        }
        NSLog("DRAMAMETA ===== END =====")

        // 完整原始 JSON 落盘（Finder 文件共享可拷出）
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("DramaMeta", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("raw_\(target.dramaID).json")
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: url)
            NSLog("DRAMAMETA raw 已写入 \(url.lastPathComponent)（\(json.count) 字节）")
        }
    }

    // MARK: 常量解析（随包 video_auto.py，单一事实源在仓库根）

    private func constants() throws -> Constants {
        if let cachedConstants { return cachedConstants }
        guard let url = Bundle.main.url(forResource: "video_auto", withExtension: "py"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let username = Self.sourceConstant("USERNAME", in: source),
              let password = Self.sourceConstant("PASSWORD", in: source),
              let keyString = Self.sourceConstant("AES_KEY", in: source),
              let ivString = Self.sourceConstant("AES_IV", in: source) else {
            throw DramaError.configMissing
        }
        let parsed = Constants(username: username, password: password, aesKey: keyString, aesIV: ivString)
        cachedConstants = parsed
        return parsed
    }

    static func sourceConstant(_ name: String, in text: String) -> String? {
        guard let keyRange = text.range(of: name + " = ") else { return nil }
        var rest = text[keyRange.upperBound...]
        if rest.hasPrefix("b") { rest = rest.dropFirst() }  // Python 字节串 b"..."
        guard rest.hasPrefix("\"") else { return nil }
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<end])
    }

    // MARK: 协议实现（与 videocli.swift 同逻辑）

    private func login(_ constants: Constants) async throws -> String {
        // token 30 天有效：按站点缓存，避免每次开面板都打登录接口（站点 WAF 对高频登录敏感）
        let tokenKey = "DramaAPI.token.\(target.site)"
        if let cached = UserDefaults.standard.string(forKey: tokenKey), !cached.isEmpty {
            print("DRAMA: 使用缓存 token")
            return cached
        }
        let response = try await apiPost(path: "api/account/login", token: "",
                                         extra: ["username": constants.username, "password": constants.password],
                                         constants: constants)
        if let data = response["data"] as? [String: Any], let t = data["token"] as? String {
            UserDefaults.standard.set(t, forKey: tokenKey)
            print("DRAMA: 登录成功")
            return t
        }
        print("DRAMA: 游客模式（响应无 token）")
        return ""
    }

    private func fetchDramaData(_ constants: Constants) async throws -> [String: Any] {
        let decrypted = try await apiPost(path: "api/playlet/play", token: token,
                                          extra: ["playlet_id": target.dramaID,
                                                  "video_id": target.dramaID,
                                                  "episode_id": "0"],
                                          constants: constants)
        guard let data = decrypted["data"] as? [String: Any] else { throw DramaError.badResponse }
        return data
    }

    private func apiPost(path: String, token: String, extra: [String: String],
                         constants: Constants) async throws -> [String: Any] {
        var form = URLComponents()
        var items: [URLQueryItem] = [
            .init(name: "bundleId", value: "com.pwa.mater"),
            .init(name: "version", value: "1.3.2"),
            .init(name: "oauth_type", value: "web"),
            .init(name: "language", value: "zh"),
            .init(name: "via", value: "pwa"),
            .init(name: "oauth_id", value: String(repeating: "a", count: 32)),
            .init(name: "token", value: token),
            .init(name: "trace_id", value: String(repeating: "a", count: 32)),
        ]
        items += extra.map { URLQueryItem(name: $0.key, value: $0.value) }
        form.queryItems = items

        guard let apiURL = URL(string: "\(target.site)/api.php/\(path)") else { throw DramaError.badRequest }
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("\(target.site)/", forHTTPHeaderField: "Origin")
        request.setValue("\(target.site)/", forHTTPHeaderField: "Referer")
        for (field, value) in DownloadEngine.browserHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let session = URLSession(configuration: .ephemeral,
                                 delegate: DownloadEngine.TrustAllSessionDelegate(),
                                 delegateQueue: nil)
        let (data, _) = try await session.data(for: request)

        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (envelope["errcode"] as? Int) == 0 else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
            // 接口错误（含 token 失效）：清缓存，下次开面板重新登录
            UserDefaults.standard.removeObject(forKey: "DramaAPI.token.\(target.site)")
            throw DramaError.apiError(String(snippet))
        }
        guard let payload = envelope["data"] as? String else { throw DramaError.badResponse }
        return try Self.decryptPayload(payload, keyString: constants.aesKey, ivString: constants.aesIV)
    }

    /// base64(空格还原+) -> AES-128-CBC -> PKCS7 去填充 -> JSON（与 video_auto.py 同逻辑）
    static func decryptPayload(_ base64: String, keyString: String, ivString: String) throws -> [String: Any] {
        let cleaned = base64.replacingOccurrences(of: " ", with: "+")
        guard let raw = Data(base64Encoded: cleaned),
              let key = keyString.data(using: .utf8),
              let iv = ivString.data(using: .utf8),
              key.count == 16, iv.count == 16 else { throw DramaError.decryptFailed }
        var plain = try DownloadEngine.aesDecrypt(raw, key: key, iv: iv)
        guard let pad = plain.last, Int(pad) > 0, Int(pad) <= 16, plain.count >= Int(pad) else {
            throw DramaError.decryptFailed
        }
        plain.removeLast(Int(pad))
        guard let json = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw DramaError.decryptFailed
        }
        return json
    }

    /// 捕获模式解密：web 端 detail 响应可能与 App 接口同协议——加密信封
    /// （errcode=0 + data base64）。复用随包常量与 decryptPayload；非信封返回 nil。
    static func decryptCapturedBody(_ body: String) -> [String: Any]? {
        guard let envelope = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              (envelope["errcode"] as? Int) == 0,
              let payload = envelope["data"] as? String,
              let url = Bundle.main.url(forResource: "video_auto", withExtension: "py"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let keyString = sourceConstant("AES_KEY", in: source),
              let ivString = sourceConstant("AES_IV", in: source) else { return nil }
        return try? decryptPayload(payload, keyString: keyString, ivString: ivString)
    }

    static func isTrue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let int = value as? Int { return int != 0 }
        if let string = value as? String { return string == "1" || string == "true" }
        return false
    }
}

enum DramaError: LocalizedError {
    case configMissing
    case badRequest
    case badResponse
    case apiError(String)
    case episodeMissing
    case noVideoURL
    case decryptFailed

    var errorDescription: String? {
        switch self {
        case .configMissing: return "站点配置缺失（App 包内未找到 video_auto.py）"
        case .badRequest: return "接口地址无效"
        case .badResponse: return "接口响应缺少字段"
        case .apiError(let snippet): return "接口错误: \(snippet)"
        case .episodeMissing: return "接口未返回该集信息"
        case .noVideoURL: return "接口未返回播放地址"
        case .decryptFailed: return "响应解密失败"
        }
    }
}

// MARK: - 多集下载调度
//
// 选集下载的队列：每集下载前重调接口取新鲜直链；同时最多 2 个集任务在跑
// （每个任务内部仍 6 并发切片），其余排队「等待中」。用户删掉的等待任务自动跳过。

@MainActor
final class SeriesDownloadCoordinator {
    static let maxConcurrentEpisodes = 2
    /// 保活：进行中的调度器（全部集结束/被删光后自动移除）
    private static var active: [SeriesDownloadCoordinator] = []

    private struct Plan {
        let episode: ApiDramaEpisode
        let taskID: UUID
    }

    private let session: DramaSession
    private let manager: DownloadManager
    private var pending: [Plan] = []
    private var running = 0

    private init(session: DramaSession, manager: DownloadManager) {
        self.session = session
        self.manager = manager
    }

    /// 选集下载入口：登记全部集任务（等待中）后开始调度；集按 sort 升序排队。
    /// 已在队列中的集直接剔除，连点「下载所选」也不会重复建任务 / 重复起调度器。
    static func start(target: DramaTarget, seriesName: String,
                      episodes: [ApiDramaEpisode], manager: DownloadManager, session: DramaSession) {
        let queued = manager.queuedEpisodeSorts(forSeries: seriesName)
        var seen = Set<Int>()
        let fresh = episodes
            .filter { !queued.contains($0.sort) && seen.insert($0.sort).inserted }
            .sorted { $0.sort < $1.sort }
        guard !fresh.isEmpty else { return }

        let coordinator = SeriesDownloadCoordinator(session: session, manager: manager)
        for ep in fresh.reversed() {  // tasks 头插，反序插入使「正在下载」列表保持升序
            let task = manager.registerEpisode(title: String(format: "第%02d集", ep.sort),
                                               seriesName: seriesName)
            coordinator.pending.append(Plan(episode: ep, taskID: task.id))
        }
        active.append(coordinator)
        coordinator.pump()
    }

    private func pump() {
        while running < Self.maxConcurrentEpisodes, !pending.isEmpty {
            let plan = pending.removeFirst()
            guard let task = manager.task(withID: plan.taskID), task.state == .waiting else {
                continue  // 用户已删掉该等待任务，直接跳过
            }
            running += 1
            Task { @MainActor in
                do {
                    let url = try await session.freshVideoURL(for: plan.episode)
                    guard manager.containsTask(id: plan.taskID) else {
                        finishOne()  // 取到直链前任务被删
                        return
                    }
                    task.url = url
                    manager.run(task) { [weak self] in
                        // 下载完成：该集"已下载 + 落盘目录名"记入缓存
                        if task.state == .done, let self,
                           let folder = task.outputURL?.deletingLastPathComponent().lastPathComponent {
                            DramaCache.markDownloaded(site: self.session.target.site,
                                                      dramaID: self.session.target.dramaID,
                                                      episodeID: plan.episode.id,
                                                      folder: folder)
                        }
                        self?.finishOne()
                    }
                } catch {
                    task.state = .failed("获取第\(plan.episode.sort)集地址失败: \(error.localizedDescription)")
                    finishOne()
                }
            }
        }
    }

    private func finishOne() {
        running -= 1
        if pending.isEmpty, running == 0 {
            Self.active.removeAll { $0 === self }
        } else {
            pump()
        }
    }
}
