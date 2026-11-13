import Foundation

// MARK: - 剧集页路由偏好（Service，设置域）

/// 浏览器点进剧集 URL 时走原生剧集页还是 Web 页（用户拍板 2026-11-13）。
/// 默认 false = 原生剧集页；Service 只做读写，无业务判断（AGENTS 第 5 条判据：
/// 删掉 UI 后这个读写仍然成立）。读取方是 BrowserView 的路由判定点，每次事件
/// 现读现判，设置页改动立即生效（无需通知/观察）。
final class DramaRoutePreferences {
    private let defaults: UserDefaults
    private static let useWebKey = "DramaRoute.useWebDramaPage"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// true = 浏览页内直接打开 Web 剧集页（不拦路由、不推原生页）；
    /// false（默认）= 命中剧集 URL 推入原生剧集页
    var useWebDramaPage: Bool {
        get { defaults.bool(forKey: Self.useWebKey) }
        set { defaults.set(newValue, forKey: Self.useWebKey) }
    }
}
