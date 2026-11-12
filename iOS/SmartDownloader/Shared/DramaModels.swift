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

/// 单集下载阶段（剧集格子边缘进度环的数据源，纯数据无行为）。
/// 状态由 `DramaPageViewModel` 从磁盘账本 + `DownloadTask.state/current/total` 派生。
enum EpisodeDownloadPhase: Equatable {
    case idle                   // 未下载：无边缘
    case queued                 // 已入队：淡色轨道
    case active(Double)         // 下载中：0...1 逐渐闭环
    case done                   // 完成：闭环 + 内部打勾
    case failed(String)         // 失败：红环
}
