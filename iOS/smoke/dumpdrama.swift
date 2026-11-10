// 短剧元数据调查工具（仅 macOS）：完整输出 playlet/play 接口解密响应，
// 并抓剧集页/首页 HTML 检查可解析的元数据（封面/简介/标题等）。
// 账号/AES 常量直接从仓库根 video_auto.py 解析，不在此处硬编码、不打印。
// 用法: ./dumpdrama <剧集页URL>
import Foundation

@main
struct DumpDrama {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count > 1,
              let target = parseDramaURL(arguments[1]) else {
            print("用法: ./dumpdrama <剧集页URL>")
            return
        }

        let sourceURL = URL(fileURLWithPath: "../../video_auto.py")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8),
              let username = sourceConstant("USERNAME", in: source),
              let password = sourceConstant("PASSWORD", in: source),
              let keyString = sourceConstant("AES_KEY", in: source),
              let ivString = sourceConstant("AES_IV", in: source) else {
            print("RESULT: FAIL 无法从 video_auto.py 解析常量")
            return
        }

        var token = ""
        if let response = try? await apiPost(site: target.site, path: "api/account/login", token: "",
                                             extra: ["username": username, "password": password],
                                             keyString: keyString, ivString: ivString),
           let data = response["data"] as? [String: Any], let t = data["token"] as? String {
            token = t
            print("LOGIN: ok")
        } else {
            print("LOGIN: guest")
        }

        do {
            let decrypted = try await apiPost(site: target.site, path: "api/playlet/play", token: token,
                                              extra: ["playlet_id": target.dramaID, "video_id": target.dramaID, "episode_id": "0"],
                                              keyString: keyString, ivString: ivString)
            let json = try JSONSerialization.data(withJSONObject: decrypted, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: json, encoding: .utf8) ?? ""
            let outDir = URL(fileURLWithPath: "out", isDirectory: true)
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let outFile = outDir.appendingPathComponent("dumpdrama_\(target.dramaID).json")
            try? text.write(to: outFile, atomically: true, encoding: .utf8)
            print("===== PLAYLET/PLAY 解密响应（完整已存 \(outFile.path)，stdout 截取 9000 字）=====")
            print(String(text.prefix(9000)))
        } catch {
            print("API FAIL: \(error.localizedDescription)")
        }

        await dumpHTML(url: "\(target.site)/drama/detail/\(target.dramaID)/", label: "剧集页")
        await dumpHTML(url: "\(target.site)/", label: "首页")
    }

    // MARK: - HTML 检查

    /// 正则捕获组 1 列表（Swift5 模式下不用裸正则字面量）
    static func captures(_ text: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { m in m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : nil }
    }

    static func dumpHTML(url: String, label: String) async {
        guard let u = URL(string: url) else { return }
        var request = URLRequest(url: u)
        for (field, value) in DownloadEngine.browserHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let session = URLSession(configuration: .ephemeral,
                                 delegate: DownloadEngine.TrustAllSessionDelegate(),
                                 delegateQueue: nil)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let html = String(data: data, encoding: .utf8) ?? ""
            print("\n===== HTML[\(label)] status=\(status) len=\(html.count) =====")
            let og = html.range(of: "og:image") != nil
            let coverCount = html.range(of: "cover", options: .caseInsensitive) != nil
            let imgs = captures(html, "src=\"([^\"]+\\.(?:jpg|jpeg|png|webp)[^\"]*)\"")
            let dramaIds = Set(captures(html, "/drama/(?:video|detail)/(\\d+)") )
            print("og:image 出现: \(og) | 'cover' 出现: \(coverCount) | img src 数: \(imgs.count) | 剧集ID 数: \(dramaIds.count)")
            print("img src 样例: \(Array(imgs.prefix(5)))")
            print("剧集ID 样例: \(Array(dramaIds.sorted().prefix(8)))")
            print("HTML 前 800 字: \(html.prefix(800))")
        } catch {
            print("HTML[\(label)] FAIL: \(error.localizedDescription)")
        }
    }

    // MARK: - 输入解析（与 videocli 同逻辑）

    static func parseDramaURL(_ raw: String) -> (site: String, dramaID: String)? {
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
        return (site, parts[2])
    }

    // MARK: - HTTP / AES（与 videocli 同逻辑）

    static func apiPost(site: String, path: String, token: String, extra: [String: String],
                        keyString: String, ivString: String) async throws -> [String: Any] {
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

        guard let apiURL = URL(string: "\(site)/api.php/\(path)") else {
            throw NSError(domain: "dump", code: -7, userInfo: [NSLocalizedDescriptionKey: "接口地址无效"])
        }
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("\(site)/", forHTTPHeaderField: "Origin")
        request.setValue("\(site)/", forHTTPHeaderField: "Referer")
        for (field, value) in DownloadEngine.browserHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let session = URLSession(configuration: .ephemeral,
                                 delegate: DownloadEngine.TrustAllSessionDelegate(),
                                 delegateQueue: nil)
        let (data, _) = try await session.data(for: request)

        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (envelope["errcode"] as? Int) == 0 else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw NSError(domain: "dump", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "接口错误: \(snippet)"])
        }
        guard let payload = envelope["data"] as? String else {
            throw NSError(domain: "dump", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "响应缺少加密 data 字段"])
        }
        return try decryptPayload(payload, keyString: keyString, ivString: ivString)
    }

    static func decryptPayload(_ base64: String, keyString: String, ivString: String) throws -> [String: Any] {
        let cleaned = base64.replacingOccurrences(of: " ", with: "+")
        guard let raw = Data(base64Encoded: cleaned),
              let key = keyString.data(using: .utf8), let iv = ivString.data(using: .utf8),
              key.count == 16, iv.count == 16 else {
            throw NSError(domain: "dump", code: -3, userInfo: [NSLocalizedDescriptionKey: "解密参数错误"])
        }
        var plain = try DownloadEngine.aesDecrypt(raw, key: key, iv: iv)
        guard let pad = plain.last, Int(pad) > 0, Int(pad) <= 16, plain.count >= Int(pad) else {
            throw NSError(domain: "dump", code: -4, userInfo: [NSLocalizedDescriptionKey: "PKCS7 去填充失败"])
        }
        plain.removeLast(Int(pad))
        guard let json = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw NSError(domain: "dump", code: -5, userInfo: [NSLocalizedDescriptionKey: "解密后不是 JSON"])
        }
        return json
    }

    static func sourceConstant(_ name: String, in text: String) -> String? {
        guard let keyRange = text.range(of: name + " = ") else { return nil }
        var rest = text[keyRange.upperBound...]
        if rest.hasPrefix("b") { rest = rest.dropFirst() }
        guard rest.hasPrefix("\"") else { return nil }
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<end])
    }
}
