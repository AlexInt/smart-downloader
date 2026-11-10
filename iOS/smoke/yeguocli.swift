// 野果 API CLI（仅 macOS 冒烟）：用与 App 完全相同的 URLSession + 浏览器请求头走站点接口，
// 取真实剧集 m3u8 地址，供 coretest 做端到端下载验证。
// 账号/AES 常量直接从仓库根目录 yeguo_auto.py 解析，不在此处硬编码、不打印。
// 用法: ./yeguocli [剧集ID]
import Foundation

@main
struct YeguoCLI {
    static func main() async {
        let sourceURL = URL(fileURLWithPath: "../../yeguo_auto.py")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8),
              let username = sourceConstant("USERNAME", in: source),
              let password = sourceConstant("PASSWORD", in: source),
              let keyString = sourceConstant("AES_KEY", in: source),
              let ivString = sourceConstant("AES_IV", in: source) else {
            print("RESULT: FAIL 无法从 yeguo_auto.py 解析常量")
            return
        }
        let dramaID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "3445"

        // 登录（失败降级游客）
        var token = ""
        do {
            let response = try await apiPost("api/account/login", token: "",
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
            let decrypted = try await apiPost("api/playlet/play", token: token,
                                              extra: ["playlet_id": dramaID, "video_id": dramaID, "episode_id": "0"],
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

    static func apiPost(_ path: String, token: String, extra: [String: String],
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

        var request = URLRequest(url: URL(string: "https://www.yeguodj.com/api.php/\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.yeguodj.com/", forHTTPHeaderField: "Origin")
        request.setValue("https://www.yeguodj.com/", forHTTPHeaderField: "Referer")
        for (field, value) in DownloadEngine.browserHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)
        let (data, _) = try await session.data(for: request)

        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (envelope["errcode"] as? Int) == 0 else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
            throw NSError(domain: "yeguo", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "接口错误: \(snippet)"])
        }
        guard let payload = envelope["data"] as? String else {
            throw NSError(domain: "yeguo", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "响应缺少加密 data 字段"])
        }
        return try decryptPayload(payload, keyString: keyString, ivString: ivString)
    }

    // MARK: - AES 响应解密 (与 yeguo_auto.py 同逻辑: base64(空格还原+) -> AES-128-CBC -> PKCS7 -> JSON)

    static func decryptPayload(_ base64: String, keyString: String, ivString: String) throws -> [String: Any] {
        let cleaned = base64.replacingOccurrences(of: " ", with: "+")
        guard let raw = Data(base64Encoded: cleaned) else {
            throw NSError(domain: "yeguo", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "data 字段 base64 解码失败"])
        }
        guard let key = keyString.data(using: .utf8), let iv = ivString.data(using: .utf8),
              key.count == 16, iv.count == 16 else {
            throw NSError(domain: "yeguo", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "AES 密钥长度错误"])
        }
        var plain = try DownloadEngine.aesDecrypt(raw, key: key, iv: iv)
        guard let pad = plain.last, Int(pad) > 0, Int(pad) <= 16, plain.count >= Int(pad) else {
            throw NSError(domain: "yeguo", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "PKCS7 去填充失败"])
        }
        plain.removeLast(Int(pad))
        guard let json = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw NSError(domain: "yeguo", code: -6,
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
