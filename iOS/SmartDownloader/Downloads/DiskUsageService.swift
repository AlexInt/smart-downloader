import Foundation

// MARK: - 磁盘占用统计（Service，下载域）

/// 剧集目录 / 单文件的字节占用计算。Service 只做计算不做调度：
/// 目录枚举可能涉及成千个切片文件，调用方必须在后台线程调用；
/// 何时重算（下载完成/移除）由 DownloadsViewModel 的指纹去抖决定。
enum DiskUsageService {
    /// 目录递归字节占用（只统计常规文件的分配大小；目录不存在 = 0）
    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
              let enumerator = fm.enumerator(
                  at: url,
                  includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                  options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.totalFileAllocatedSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// 单文件字节占用（不存在 = 0；散装非 HLS 条目用）
    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true, let size = values?.totalFileAllocatedSize else { return 0 }
        return Int64(size)
    }

    /// 人读格式（file 计数风格：KB/MB/GB 自适应，固定一位小数由系统格式化）
    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
