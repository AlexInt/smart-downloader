import Foundation

/// App 启动落在哪个 tab 的持久化（Service）：只读写，不含判断。
/// 读取方是 App.swift（组装根）与 `SettingsViewModel`，两者都通过这个 Service，
/// 不允许在 View / ViewModel 里直接出现 `UserDefaults.standard`（AGENTS「iOS 架构约定」第 5 条）。
struct AppLaunchPreferences {
    private let defaults: UserDefaults
    private static let storageKey = "Settings.launchTab"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 默认落「下载」tab：与设置页出现之前 App.swift 硬编码的 `selectedTab = 1` 行为一致，
    /// 老用户升级后首启体验不变；key 缺失（含写入过非法值）都走这个默认。
    var launchTab: MainTab {
        get {
            guard defaults.object(forKey: Self.storageKey) != nil,
                  let tab = MainTab(rawValue: defaults.integer(forKey: Self.storageKey)) else {
                return .downloads
            }
            return tab
        }
        // defaults 是引用类型，nonmutating set 允许从 `let` 实例写入（同 PlayerPreferences）
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.storageKey) }
    }
}
