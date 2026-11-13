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

    /// 用户是否**手动操作过**默认圆圈。必须区分三种状态，不能只用一个 nil：
    /// - key 不存在 = 从没点过 → 自动选中列表第一项
    /// - key 存在但为空串 = 点过又取消 → 显式「无默认」，回落恢复上次访问页
    /// - key 存在且为合法 UUID = 显式选中该项
    /// 所以取消时写空串而不是 `removeObject`（上一版删 key 会把「显式取消」误判成「从没配置」）。
    var hasConfiguredDefault: Bool { defaults.object(forKey: Self.defaultIDKey) != nil }

    /// 显式选中的站点 id；nil = 显式取消（或 key 不存在）。
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
                defaults.set("", forKey: Self.defaultIDKey)
            }
        }
    }

    /// 解析「当前生效的默认站点 id」（纯规则，无 IO）：
    /// 从没点过 → 第一项；显式取消 → nil；显式选中但条目已被删 → nil（不猜、不落到别的站）。
    func resolvedDefaultID(in links: [QuickLink]) -> UUID? {
        if !hasConfiguredDefault { return links.first?.id }
        guard let id = defaultLinkID else { return nil }
        return links.contains { $0.id == id } ? id : nil
    }

    /// 按生效 id 在当前列表里取网址（纯查找，无 IO）。
    /// 找不到返回 nil，由起始页链路回落「恢复上次访问页」，不留悬空地址。
    func defaultURL(in links: [QuickLink]) -> String? {
        guard let id = resolvedDefaultID(in: links) else { return nil }
        return links.first { $0.id == id }?.url
    }

    /// 内置默认：仅在用户从未配置时兜底（原 `BrowserView.quickLinks` 硬编码数组搬到这里），
    /// 之后全由设置页增删改，删空也不会恢复。
    static let defaultLinks: [QuickLink] = [
        QuickLink(name: "🍎", url: "https://www.yeguodj.com/"),
    ]
}
