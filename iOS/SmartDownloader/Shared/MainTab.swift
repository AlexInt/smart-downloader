import Foundation

/// 主 tab 定义（纯数据）：App 保活容器的分层、底部 tab bar 的条目、设置页「启动进入」的可选项。
/// 全 App 只有这一处定义，新增 tab 改这里即可（底部 bar 与设置页 Picker 都遍历 allCases）。
///
/// 约束：`.browser` 必须排在第一位 —— WKWebView 常驻 ZStack 底层保活，其余 tab 以不透明背景盖上去
///（AGENTS「iOS 架构约定」第 8 条），所以 rawValue 只用作覆盖顺序，不影响命中测试。
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
        case .settings: return "设置"
        }
    }

    /// iOS 26 符号集没有 compass，浏览页用 safari.fill
    var icon: String {
        switch self {
        case .browser: return "safari.fill"
        case .downloads: return "arrow.down.circle"
        case .settings: return "gearshape"
        }
    }
}
