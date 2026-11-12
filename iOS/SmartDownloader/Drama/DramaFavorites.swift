import Foundation

/// 剧集收藏持久化（Service）：只做 UserDefaults 读写，不含业务判断。
/// 与播放页 `PlayerPreferences` 分开：剧集收藏按剧（`site#dramaID`）记，播放偏好按集记，
/// 两者变更理由不同，不要合并成一个大而全的偏好服务。
/// AGENTS.md 架构约定第 5 条：ViewModel 里不得出现 `UserDefaults.standard`。
struct DramaFavorites {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isFavorite(_ targetID: String) -> Bool {
        defaults.bool(forKey: Self.key(for: targetID))
    }

    func setFavorite(_ value: Bool, for targetID: String) {
        defaults.set(value, forKey: Self.key(for: targetID))
    }

    /// 沿用旧 key 前缀，迁移后用户已收藏的剧不会丢
    private static func key(for targetID: String) -> String {
        "DramaDetail.favorite.\(targetID)"
    }
}
