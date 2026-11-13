import Foundation

/// 浏览区起始页决策 + 「上次访问页」持久化（Browser 域 Service：只做读写与纯决策）。
///
/// 优先级：**默认快捷站点 > 上次访问页 > 空白页**。
/// 默认站点由 `QuickLinkStore.resolvedDefaultID(in:)` 解析：用户从没点过设置页的圆圈时
/// **自动选中列表第一项**，显式取消后才回落到「恢复上次访问页」。
/// 按 `QuickLink.id` 查当前列表，所以编辑网址后下次启动自动跟随新地址、
/// 显式选中的条目被删后不猜别的站点，不留悬空地址。
///
/// 抽到这里之后 `BrowserView` / `WebViewContainer.Coordinator` 不再直接碰 UserDefaults
/// （AGENTS.md「iOS 架构约定」第 5 条：View 层不得出现 `UserDefaults.standard`）。
struct BrowserStartPage {
    /// 保持旧 key 字符串不变：老用户已保存的上次访问页不能因为这次改动丢失
    static let lastPageKey = "BrowserView.lastPageURL"

    private let defaults: UserDefaults
    private let linkStore: QuickLinkStore

    init(defaults: UserDefaults = .standard, linkStore: QuickLinkStore = QuickLinkStore()) {
        self.defaults = defaults
        self.linkStore = linkStore
    }

    /// 上次成功 commit 的主帧地址；起始页首次加载失败时由 Coordinator 清空
    var lastVisitedURL: String? {
        get { defaults.string(forKey: Self.lastPageKey) }
        // defaults 是引用类型，nonmutating set 允许从 `let` 实例写入
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Self.lastPageKey)
            } else {
                defaults.removeObject(forKey: Self.lastPageKey)
            }
        }
    }

    /// 浏览区下次加载的起始页。
    /// App 用 ZStack 保活容器，WKWebView 只在冷启动 `makeUIView` 一次，
    /// 所以「下次加载」= 下次 App 启动；切回浏览 tab 只改可见性、不重载，避免打断正在看的页面。
    var startURLString: String {
        if let home = linkStore.defaultURL(in: linkStore.load()), !home.isEmpty {
            return home
        }
        return lastVisitedURL ?? "about:blank"
    }
}
