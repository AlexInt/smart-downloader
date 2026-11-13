import Foundation
import Combine

/// 设置页 ViewModel：可绑定状态（启动 tab / 快捷站点列表 / 编辑器草稿）+ 意图方法。
/// 持久化全部下沉到 Service（`QuickLinkStore` / `AppLaunchPreferences`），本类不出现 UserDefaults。
/// 主线程约定：状态只在主线程访问（GCD 版，无线程标注）。
final class SettingsViewModel: ObservableObject {
    /// 启动进入的 tab：改动即落盘，下次冷启动生效（当前会话不跳 tab，避免浏览页被掀掉）
    @Published var launchTab: MainTab {
        didSet { launchPreferences.launchTab = launchTab }
    }

    /// 浏览页网址栏下方的快捷站点，数组顺序即 label 显示顺序；改完由浏览页切回时重新读取
    @Published private(set) var links: [QuickLink]

    /// **当前生效**的默认站点 id（用于 UI 勾选态）：
    /// 用户从没点过圆圈时自动等于列表第一项，显式取消后为 nil。
    /// 与存储里的 `QuickLinkStore.defaultLinkID`（显式选择）不是一回事，勿混用。
    @Published private(set) var defaultLinkID: UUID?

    /// 编辑器草稿：非 nil 即弹出新增/编辑 sheet，取消或完成都置回 nil
    @Published var draft: QuickLink?
    /// 草稿来源是否为「新增」：决定编辑器标题和是否给删除入口
    @Published private(set) var draftIsNew = false
    /// 浏览器点进剧集页走 Web 页还是原生页（用户拍板 2026-11-13 默认原生）：
    /// 改动即落盘，浏览页路由判定每次现读现判，立即生效
    @Published var useWebDramaPage: Bool {
        didSet { routePreferences.useWebDramaPage = useWebDramaPage }
    }

    private let linkStore = QuickLinkStore()
    private let launchPreferences = AppLaunchPreferences()
    private let routePreferences = DramaRoutePreferences()

    init() {
        // init 内的赋值不触发 didSet，不会把刚读出来的值再写回去
        self.launchTab = launchPreferences.launchTab
        self.links = linkStore.load()
        self.useWebDramaPage = routePreferences.useWebDramaPage
        // 从没点过圆圈时，这里解析出的就是列表第一项（UI 第一行的圆圈直接是选中态）
        self.defaultLinkID = linkStore.resolvedDefaultID(in: links)
    }

    // MARK: - 默认加载站点

    func isDefault(_ link: QuickLink) -> Bool { defaultLinkID == link.id }

    /// 单选：点别的直接覆盖，点已默认的那条 = 显式取消（回落恢复上次访问页）。
    /// 「显式取消」和「从没点过」必须分开：后者会自动选中第一项。
    func toggleDefault(_ link: QuickLink) {
        let next: UUID? = defaultLinkID == link.id ? nil : link.id
        defaultLinkID = next
        linkStore.defaultLinkID = next
    }

    /// 列表变化后重算生效默认：
    /// - 从没配置过 → 自动跟随新的第一项；
    /// - 显式选中的条目被删 → 清成「显式无默认」，避免以后列表变化又冒出一个默认；
    /// - 显式取消 / 选中项仍在 → 保持。
    private func refreshEffectiveDefault() {
        if linkStore.hasConfiguredDefault,
           let id = linkStore.defaultLinkID,
           !links.contains(where: { $0.id == id }) {
            linkStore.defaultLinkID = nil
        }
        defaultLinkID = linkStore.resolvedDefaultID(in: links)
    }

    // MARK: - 意图

    func beginAdd() {
        draftIsNew = true
        draft = QuickLink(name: "", url: "")
    }

    func beginEdit(_ link: QuickLink) {
        draftIsNew = false
        draft = link
    }

    /// 完成编辑：清洗输入后写回列表并落盘。空 key / 空 value 视为无效，直接忽略（视图侧已禁用按钮）。
    func commitDraft(name rawName: String, url rawURL: String) {
        guard var draft else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = Self.normalizedURL(rawURL)
        guard !name.isEmpty, !url.isEmpty else { return }
        draft.name = name
        draft.url = url
        if let index = links.firstIndex(where: { $0.id == draft.id }) {
            links[index] = draft
        } else {
            links.append(draft)
        }
        persistLinks()
        // 列表从空变非空时，从没配置过的用户应自动把新增的第一项当默认
        refreshEffectiveDefault()
        self.draft = nil
    }

    /// 编辑器内删除当前条目（左滑删除走 `remove(_:)`）
    func deleteDraft() {
        guard let draft else { return }
        remove(draft)
        self.draft = nil
    }

    func remove(_ link: QuickLink) {
        links.removeAll { $0.id == link.id }
        persistLinks()
        refreshEffectiveDefault()
    }

    /// 恢复内置默认列表（用户删空/改乱后的一键回退入口）。
    /// 注意 defaultLinks 每次构造都是新 UUID，恢复后旧的默认 id 必然失效。
    func restoreDefaults() {
        links = QuickLinkStore.defaultLinks
        persistLinks()
        refreshEffectiveDefault()
    }

    // MARK: - 私有

    private func persistLinks() {
        linkStore.save(links)
    }

    /// value 补全协议：与浏览页 `WebViewStore.load` 同规则，缺前缀时按 https 访问，
    /// 存下来的就是能直接加载的完整地址。
    static func normalizedURL(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return text.lowercased().hasPrefix("http") ? text : "https://" + text
    }
}
