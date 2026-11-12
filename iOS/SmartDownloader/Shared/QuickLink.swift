import Foundation

/// 浏览页网址栏下方的快捷站点配置项（纯数据，跨 Browser / Settings 两域引用）。
/// `name` 是 label 上显示的文字（设置页语义里的 key），`url` 是点它要访问的网页地址（value）。
/// `id` 随条目持久化，改名不会让 SwiftUI 把它当成新条目（列表 diff 稳定）。
/// 读写归 `QuickLinkStore`（Service），视图层不得自己解析存储。
struct QuickLink: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var url: String

    init(name: String, url: String, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.url = url
    }
}
