import Foundation

/// 浏览页快捷站点配置的持久化（Service）：只做 UserDefaults 读写，不含任何业务判断。
/// 存的是 `[QuickLink]` 的 JSON（数组顺序 = 浏览页 label 显示顺序）。
///
/// 「从未配置过」与「配置过但删空」必须区分：靠 key 是否写过（`data(forKey:)` 返回 nil）判断，
/// 不能用 count 判断 —— 否则用户手动删光后下次启动又长回默认项。
struct QuickLinkStore {
    private let defaults: UserDefaults
    private static let storageKey = "Settings.quickLinks"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [QuickLink] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let links = try? JSONDecoder().decode([QuickLink].self, from: data) else {
            return Self.defaultLinks
        }
        return links
    }

    func save(_ links: [QuickLink]) {
        guard let data = try? JSONEncoder().encode(links) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// 内置默认：仅在用户从未配置时兜底（原 `BrowserView.quickLinks` 硬编码数组搬到这里），
    /// 之后全由设置页增删改，删空也不会恢复。
    static let defaultLinks: [QuickLink] = [
        QuickLink(name: "🍎", url: "https://www.yeguodj.com/"),
    ]
}
