import Foundation

/// 浏览页快捷站点配置的持久化（Service）：只做 UserDefaults 读写，不含任何业务判断。
/// 存的是 `[QuickLink]` 的 JSON（数组顺序 = 浏览页 label 显示顺序）。
///
/// 「从未配置过」与「配置过但删空」必须区分：靠 key 是否写过（`data(forKey:)` 返回 nil）判断，
/// 不能用 count 判断 —— 否则用户手动删光后下次启动又长回默认项。
struct QuickLinkStore {
    private let defaults: UserDefaults
    private static let storageKey = "Settings.quickLinks"
    /// 「浏览区默认加载」选中的站点 id，独立于列表 JSON 存
    private static let defaultIDKey = "Settings.defaultQuickLinkID"

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

    /// 被选为「浏览区默认加载」的快捷站点 id；nil = 未设默认（回落恢复上次访问页）。
    /// 单独存 id 而不是往 `[QuickLink]` 里塞 isDefault：删条目 / 恢复默认列表时不必维护
    /// 布尔标记，旧版已存的 JSON 也天然兼容、不需要迁移；编辑网址不改 id，下次启动自动跟随新地址。
    var defaultLinkID: UUID? {
        get {
            guard let raw = defaults.string(forKey: Self.defaultIDKey),
                  let id = UUID(uuidString: raw) else { return nil }
            return id
        }
        // defaults 是引用类型，nonmutating set 允许从 `let` 实例写入（同 AppLaunchPreferences）
        nonmutating set {
            if let id = newValue {
                defaults.set(id.uuidString, forKey: Self.defaultIDKey)
            } else {
                defaults.removeObject(forKey: Self.defaultIDKey)
            }
        }
    }

    /// 按 id 在当前列表里解析默认站点的网址（纯查找，无 IO）。
    /// 找不到（条目被删 / 恢复默认列表换了 id）返回 nil，由起始页链路回落，不留悬空地址。
    func defaultURL(in links: [QuickLink]) -> String? {
        guard let id = defaultLinkID else { return nil }
        return links.first { $0.id == id }?.url
    }

    /// 内置默认：仅在用户从未配置时兜底（原 `BrowserView.quickLinks` 硬编码数组搬到这里），
    /// 之后全由设置页增删改，删空也不会恢复。
    static let defaultLinks: [QuickLink] = [
        QuickLink(name: "🍎", url: "https://www.yeguodj.com/"),
    ]
}
