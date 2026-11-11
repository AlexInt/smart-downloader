import Foundation

/// 本地播放偏好持久化。单一职责：只负责 UserDefaults 读写，不含任何播放逻辑。
struct PlayerPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isMuted: Bool {
        get { defaults.bool(forKey: Self.mutedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.mutedKey) }
    }

    func liked(for key: String) -> Bool { defaults.bool(forKey: likedKey(key)) }
    func saved(for key: String) -> Bool { defaults.bool(forKey: savedKey(key)) }
    func setLiked(_ value: Bool, for key: String) { defaults.set(value, forKey: likedKey(key)) }
    func setSaved(_ value: Bool, for key: String) { defaults.set(value, forKey: savedKey(key)) }

    /// 用相对 Downloads 的集目录路径做 key，避免不同剧的「第01集」互相串状态
    static func key(for url: URL) -> String {
        let root = DownloadEngine.downloadsDir.standardizedFileURL.path
        let folder = url.deletingLastPathComponent().standardizedFileURL.path
        return folder.hasPrefix(root) ? String(folder.dropFirst(root.count)) : folder
    }

    private static let mutedKey = "DramaPlayer.muted"
    private func likedKey(_ key: String) -> String { "DramaPlayer.liked.\(key)" }
    private func savedKey(_ key: String) -> String { "DramaPlayer.saved.\(key)" }
}
