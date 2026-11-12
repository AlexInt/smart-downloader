import Foundation

/// 本地播放偏好持久化（Service）：只存「播放器全局开关」——静音 / 清屏 / 时长 label 口径。
/// 单一职责：只负责 UserDefaults 读写，不含任何播放逻辑。
///
/// 每一集自己的数据（点赞 / 收藏 / 上次播到哪）不在这里：那些要按
/// (site, drama_id, episode_id) 建关系、后续还要加字段，归 `EpisodeActionsStore`（SQLite）。
struct PlayerPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isMuted: Bool {
        get { defaults.bool(forKey: Self.mutedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.mutedKey) }
    }

    /// 清屏模式：隐藏界面信息只看画面
    var isCleanScreen: Bool {
        get { defaults.bool(forKey: Self.cleanScreenKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.cleanScreenKey) }
    }

    /// 进度条右侧时长 label：显示剩余时间（负值）还是总时长
    var showRemainingTime: Bool {
        get { defaults.bool(forKey: Self.showRemainingTimeKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.showRemainingTimeKey) }
    }

    private static let mutedKey = "DramaPlayer.muted"
    private static let cleanScreenKey = "DramaPlayer.cleanScreen"
    private static let showRemainingTimeKey = "DramaPlayer.showRemainingTime"
}
