import Foundation

// MARK: - 下载页排序偏好（Service，下载域）

/// UserDefaults 读写，无业务判断（AGENTS 第 5 条：原先散在 DownloadsViewModel
/// 的 didSet/init 与 SeriesDetailView 的 @AppStorage 里的持久化收敛到这里）。
/// key 沿用旧值 "DownloadsView.sortOrder"，用户已有偏好不丢。
struct DownloadsSortPreferences {
    private let defaults: UserDefaults
    private static let key = "DownloadsView.sortOrder"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var sortOrder: DownloadSortOrder {
        get {
            defaults.string(forKey: Self.key).flatMap(DownloadSortOrder.init(rawValue:)) ?? .newestFirst
        }
        set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}
