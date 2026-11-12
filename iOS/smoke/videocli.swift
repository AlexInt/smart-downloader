// 视频资源站 API CLI（仅 macOS 冒烟）：用与 App 完全相同的 URLSession + 浏览器请求头
// 走站点接口，取真实剧集 m3u8 地址，供 coretest 做端到端下载验证。
// 站点地址与剧集 ID 从输入的剧集页 URL 解析，代码内不硬编码站点。
// 账号/AES 常量直接从仓库根目录 video_auto.py 解析，不在此处硬编码、不打印。
// 用法: ./videocli <剧集页URL>
import Foundation

@main
struct VideoCLI {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count > 1,
              let target = parseDramaURL(arguments[1]) else {
            print("用法: ./videocli <剧集页URL>    形如 https://<站点域名>/drama/video/<剧ID>/")
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

        // 登录（失败降级游客）
        var token = ""
        do {
            let response = try apiPost(site: target.site, path: "api/account/login", token: "",
                                            extra: ["username": username, "password": password],
                                            keyString: keyString, ivString: ivString)
            if let data = response["data"] as? [String: Any], let t = data["token"] as? String {
                token = t
                print("LOGIN: ok")
            } else {
                print("LOGIN: guest (响应无 token)")
            }
        } catch {
            print("LOGIN: guest (\(error.localizedDescription))")
        }

        // 剧集数据
        do {
            let decrypted = try apiPost(site: target.site, path: "api/playlet/play", token: token,
                                              extra: ["playlet_id": target.dramaID, "video_id": target.dramaID, "episode_id": "0"],
                                              keyString: keyString, ivString: ivString)
            guard let data = decrypted["data"] as? [String: Any],
                  let dramaName = data["drama_name"] as? String,
                  let episodes = data["episodeAll"] as? [[String: Any]] else {
                print("RESULT: FAIL 响应缺少字段")
                return
            }
            let playable = episodes
                .filter { !isTrue($0["is_adv"]) }
                .filter { isTrue(($0["access"] as? [String: Any])?["can_play"]) }
                .sorted { ($0["sort"] as? Int ?? 0) < ($1["sort"] as? Int ?? 0) }
            guard let episode = playable.first else {
                print("RESULT: FAIL 没有可播放剧集 (共 \(episodes.count) 集)")
                return
            }
            let url = (episode["video_url"] as? String)
                ?? (episode["video_url_h265"] as? String)
                ?? ""
            guard url.hasPrefix("http") else {
                print("RESULT: FAIL 接口未返回播放地址")
                return
            }
            print("DRAMA: \(dramaName) 第 \(episode["sort"] ?? 0) 集")
            print("M3U8: \(url)")
        } catch {
            print("RESULT: FAIL \(error.localizedDescription)")
        }
    }

    // MARK: - 输入解析

    /// 剧集页 URL -> (站点根, 剧 ID)；形如 https://<站点>/drama/{video|detail}/<ID>[/ep-N]/
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

    // MARK: - HTTP

    final class TrustAll: NSObject, URLSessionDelegate {
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

    /// URLSession 同步桥（CLI 冒烟用）：completion 在 URLSession 自有队列回调，
    /// 主线程信号量等待不会死锁；35s 超时兜底
    static func httpData(for request: URLRequest, session: URLSession) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<(Data, URLResponse), Error>?
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                outcome = .failure(error)
            } else if let data, let response {
                outcome = .success((data, response))
            } else {
                outcome = .failure(URLError(.unknown))
            }
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 35) == .success, let result = outcome else {
            task.cancel()
            throw URLError(.timedOut)
        }
        return try result.get()
    }

    static func apiPost(site: String, path: String, token: String, extra: [String: String],
                        keyString: String, ivString: String) throws -> [String: Any] {
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
            throw NSError(domain: "cli", code: -7,
                          userInfo: [NSLocalizedDescriptionKey: "接口地址无效"])
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
        let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)
        let (data, _) = try httpData(for: request, session: session)

        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (envelope["errcode"] as? Int) == 0 else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
            throw NSError(domain: "cli", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "接口错误: \(snippet)"])
        }
        guard let payload = envelope["data"] as? String else {
            throw NSError(domain: "cli", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "响应缺少加密 data 字段"])
        }
        return try decryptPayload(payload, keyString: keyString, ivString: ivString)
    }

    // MARK: - AES 响应解密 (与 video_auto.py 同逻辑: base64(空格还原+) -> AES-128-CBC -> PKCS7 -> JSON)

    static func decryptPayload(_ base64: String, keyString: String, ivString: String) throws -> [String: Any] {
        let cleaned = base64.replacingOccurrences(of: " ", with: "+")
        guard let raw = Data(base64Encoded: cleaned) else {
            throw NSError(domain: "cli", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "data 字段 base64 解码失败"])
        }
        guard let key = keyString.data(using: .utf8), let iv = ivString.data(using: .utf8),
              key.count == 16, iv.count == 16 else {
            throw NSError(domain: "cli", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "AES 密钥长度错误"])
        }
        var plain = try DownloadEngine.aesDecrypt(raw, key: key, iv: iv)
        guard let pad = plain.last, Int(pad) > 0, Int(pad) <= 16, plain.count >= Int(pad) else {
            throw NSError(domain: "cli", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "PKCS7 去填充失败"])
        }
        plain.removeLast(Int(pad))
        guard let json = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw NSError(domain: "cli", code: -6,
                          userInfo: [NSLocalizedDescriptionKey: "解密后不是 JSON"])
        }
        return json
    }

    // MARK: - 工具

    static func sourceConstant(_ name: String, in text: String) -> String? {
        guard let keyRange = text.range(of: name + " = ") else { return nil }
        var rest = text[keyRange.upperBound...]
        if rest.hasPrefix("b") { rest = rest.dropFirst() }  // Python 字节串 b"..."
        guard rest.hasPrefix("\"") else { return nil }
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<end])
    }

    static func isTrue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let int = value as? Int { return int != 0 }
        if let string = value as? String { return string == "1" || string == "true" }
        return false
    }
}
