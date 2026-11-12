import Foundation

// MARK: - 下载领域模型（跨域共享的纯数据）
//
// 从 Downloader.swift 抽出：TaskState / DownloadError 被下载页、剧集页、浏览页多处引用，
// 不该住在 1029 行的下载核心里。本文件无 IO、不 import SwiftUI；
// TaskState.isFinished 只是纯派生计算属性，不算行为。

enum TaskState: Equatable {
    case waiting
    case parsing
    case downloading
    case saving
    case done
    case failed(String)
}

extension TaskState {
    /// 已结束（成功/失败）的任务不再算「活跃下载」，允许同 URL 主动重试
    var isFinished: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }
}

enum DownloadError: LocalizedError {
    case badStatus(Int)
    case notMediaPlaylist
    case emptySegments
    case missingKey
    case decryptFailed(Int32)
    case shortSegment(Int, Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cancelled: return "已手动删除"
        case .badStatus(let code): return "HTTP 状态码 \(code)"
        case .notMediaPlaylist: return "不是有效的 m3u8 媒体播放列表"
        case .emptySegments: return "播放列表中没有切片"
        case .missingKey: return "解密密钥下载失败"
        case .decryptFailed(let status): return "AES 解密失败 (CCCrypt=\(status))"
        case .shortSegment(let expected, let got): return "切片下载不完整 (期望 \(expected) 字节, 实得 \(got))"
        }
    }
}
