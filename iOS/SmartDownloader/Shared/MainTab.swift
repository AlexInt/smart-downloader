import Foundation

/// 主 tab 定义（纯数据）：App 保活容器的分层、底部 tab bar 的条目、设置页「启动进入」的可选项。
/// 全 App 只有这一处定义，新增 tab 改这里即可（底部 bar 与设置页 Picker 都遍历 allCases）。
///
/// 约束：`.browser` 必须排在第一位 —— WKWebView 常驻 ZStack 底层保活，其余 tab 以不透明背景盖上去
///（AGENTS「iOS 架构约定」第 11 条），所以 rawValue 只用作覆盖顺序，不影响命中测试。
/// 图标以 SF Symbol 名字符串记录，本文件不 import SwiftUI（Model 层约束）。
enum MainTab: Int, CaseIterable, Identifiable {
    case browser = 0
    case downloads = 1
    case settings = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .browser: return "浏览"
        case .downloads: return "下载"
        case .settings: return "我的"
        }
    }

    /// 三个 tab 统一走线稿（画布底栏 22:147/152/157 都是线稿图标）；
    /// 浏览页用 safari（非 fill 版），与「我的」的 person 线稿同重。
    var icon: String {
        switch self {
        case .browser: return "safari"
        case .downloads: return "arrow.down.circle"
        case .settings: return "person"
        }
    }

    /// 自定义底部 tab bar 的预留高度（与 App.mainTabBar 的内边距同步：
    /// VStack(spacing:4){ 图标 22 + 文字 ≈13 + 朱砂点 4，文字与点间距 3 }
    /// + padding(top:10, bottom:6) ≈ 62）。
    /// 分页 TabView 的页面不接收祖先 safeAreaInset 追加的底部安全区（已知传递缺陷），
    /// 下载页列表用它显式补底部安全区；改 bar 内边距时同步此值。
    static let barReservedHeight: CGFloat = 62
}
