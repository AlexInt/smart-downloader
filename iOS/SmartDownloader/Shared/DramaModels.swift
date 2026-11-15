import Foundation

// MARK: - 剧集域模型（跨域共享的纯数据）
//
// 从 DramaAPI.swift 抽出：这 4 个类型被 Drama/、player/、Downloads/ 多处引用，
// 不该住在站点接口 Service 文件里 —— View 为了拿一个数据结构而依赖接口文件是概念反向依赖。
// 本文件只放类型定义与纯函数解析（无 IO、无状态），不 import SwiftUI（AGENTS.md Model 约定）。

/// 剧集页 URL 解析出的下载目标
struct DramaTarget: Identifiable, Hashable {
    let site: String
    let dramaID: String
    var id: String { "\(site)#\(dramaID)" }
    /// 原生剧集页内嵌 webview 加载的详情页地址
    var pageURLString: String { "\(site)/drama/detail/\(dramaID)/" }

    /// 形如 https://<站点>/drama/{video|detail}/<ID>[/ep-N]/；无法识别返回 nil。
    /// 纯函数解析（字符串 → 值），不做任何 IO，属于值类型自带的构造能力。
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

/// 一段可播放资源的「行为数据归属」标识（纯数据）。
/// 对得上服务端集 id 就走 (site, drama_id, episode_id)：重新下载、改目录、改名都不丢历史；
/// 对不上的（散装 HLS / 普通文件 / 磁盘收编的历史条目）退化为相对下载根目录的资源路径。
/// 行为数据本体在 `EpisodeActionsStore`（SQLite），本类型只回答「这条记录属于谁」。
enum MediaIdentity: Hashable {
    case episode(site: String, dramaID: String, episodeID: Int)
    /// 相对下载根目录的资源文件路径（HLS 为 `<目录>/playlist.m3u8`）
    case localPath(String)

    /// 日志用短句：不把整条绝对路径喷进 console，但足够定位到哪集
    var label: String {
        switch self {
        case .episode(let site, let dramaID, let episodeID):
            return "ep@\(site)#\(dramaID)/\(episodeID)"
        case .localPath(let path):
            return "local\(path)"
        }
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

enum DramaError: LocalizedError {
    case configMissing
    case badRequest
    case badResponse
    case apiError(String)
    case episodeMissing
    case noVideoURL
    case decryptFailed
    /// 站点返回的不是接口数据（WAF 拦截页 / 网关错误页 / 空响应 / 合法 JSON 但不是对象）。
    /// **必须带状态码与响应片段**：系统给的那句「未能读取数据，因为它的格式不正确」
    /// 只说现象不给证据，用户和我们都没法判断到底是拦截、超时还是站点改了协议。
    case badBody(status: Int, contentType: String?, bytes: Int, snippet: String)

    var errorDescription: String? {
        switch self {
        case .configMissing: return "站点配置缺失（App 包内未找到 video_auto.py）"
        case .badRequest: return "接口地址无效"
        case .badResponse: return "接口响应缺少字段"
        case .apiError(let snippet): return "接口错误: \(snippet)"
        case .episodeMissing: return "接口未返回该集信息"
        case .noVideoURL: return "接口未返回播放地址"
        case .decryptFailed: return "响应解密失败"
        case .badBody(let status, let contentType, _, _):
            return "站点返回的不是接口数据（HTTP \(status)，\(contentType ?? "无 Content-Type")）"
        }
    }

    /// 排障详情（多行）：错误态详情块与日志共用一份，避免两处口径漂移。
    var diagnostic: String {
        switch self {
        case .badBody(let status, let contentType, let bytes, let snippet):
            return [
                "HTTP 状态：\(status)",
                "Content-Type：\(contentType ?? "无")",
                "响应长度：\(bytes) 字节",
                "响应片段：\(snippet)",
            ].joined(separator: "\n")
        case .apiError(let snippet):
            return "接口返回：\(snippet)"
        default:
            return errorDescription ?? ""
        }
    }
}

/// 单集下载阶段（剧集格子边缘进度环的数据源，纯数据无行为）。
/// 状态由 `DramaPageViewModel` 从磁盘账本 + `DownloadTask.state/current/total` 派生。
enum EpisodeDownloadPhase: Equatable {
    case idle                   // 未下载：无边缘
    case queued                 // 已入队：淡色轨道
    case active(Double)         // 下载中：0...1 逐渐闭环
    case done                   // 完成：闭环 + 内部打勾
    case failed(String)         // 失败：红环
}
