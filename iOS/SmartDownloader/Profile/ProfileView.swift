import SwiftUI

/// 「我的」页（画布 19:63「我的 · 纸本」，390×844）：
/// 宣纸底浅色域，与详情/播放页的墨本轨（深底）是并行的两套视觉。
/// 结构：身份行 → 分类 tab → 筛选胶囊行 → 封面墙（3 列 wrap）。
/// View 只渲染与转发意图；数据口径在 ProfileViewModel，关系查询在 Service 层。
struct ProfileView: View {
    @ObservedObject var manager: DownloadManager
    /// 导航栈非空（推入设置页 / 剧集页）时置 true，App 据此隐藏自定义 tab bar
    ///（与浏览页推剧集详情同一口径，保持「二级页沉浸式全屏」一致）
    @Binding var detailActive: Bool
    @StateObject private var viewModel = ProfileViewModel()
    /// 导航路径用「值驱动」而不是散落的 isActive 标志：`path.isEmpty` 就是
    /// 「是否在二级页」的唯一事实来源，不用给每个入口各记一个布尔
    @State private var path: [ProfileRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 10) {
                    coverWall           // 19:200 封面墙 / 空态
                }
                .padding(.top, 10)
                .padding(.horizontal, DWLayout.edge)
            }
            .background(DWColor.paper.ignoresSafeArea())
            // 底部避让（用户实报 2026-11-14：tab bar 遮挡封面墙最后一行）：
            // 自定义 tab bar 是 App 层 `safeAreaInset(edge: .bottom)` 注入的，**不进
            // NavigationStack 内的页面**（模拟器 402×874 实测：修复前 contentInsets.bottom
            // 只有 34 的家区，ScrollView 内容区一直画到 840，而 bar 占 794…840 → 重叠 46pt）。
            // 按 bar 实高显式补一次，与下载页 `safeAreaPadding` 同一口径；另 +15 是用户要求
            // 的呼吸间距（列表末行与 bar 之间再留 15pt）。
            .safeAreaPadding(.bottom, MainTab.barReservedHeight + Self.bottomGap)
            // 底部避让诊断（开发即埋日志，排障期保留）：contentInsets 是 ScrollView 实际
            // 生效的内容内缩（安全区 + safeAreaPadding）。期望 bottom = 34 + 47 + 15 = 96；
            // 若哪天变成 47/34，说明传递行为变了（或 bar 内边距改了没同步 barReservedHeight）
            .onScrollGeometryChange(for: EdgeInsets.self) { geo in
                geo.contentInsets
            } action: { _, insets in
                print("PROFILE_DBG insets top=\(insets.top) bottom=\(insets.bottom) barReserved=\(MainTab.barReservedHeight) gap=\(Self.bottomGap)")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)   // 画布无导航条：身份行即顶栏
            // 顶栏区（身份行 + 分类 tab + 筛选胶囊）钉在 ScrollView 之上，不随封面墙上滑消失
            //（用户要求 2026-11-14）。用 safeAreaInset 而不是塞进 ScrollView 内容里：
            // 前者是布局级固定，后者得靠 sticky header 技巧且滚动时会露出内容。
            .safeAreaInset(edge: .top, spacing: 0) { pinnedHeader }
            // 二级页由路径值驱动：设置页（画布 24:43）/ 剧集详情页
            .navigationDestination(for: ProfileRoute.self) { route in
                switch route {
                case .settings:
                    SettingsView()
                case .drama(let target):
                    DramaNativePage(target: target, manager: manager)
                }
            }
            .onAppear { viewModel.reload() }
        }
        .preferredColorScheme(.light)   // 纸本轨锁浅色：域级分工，不影响其它页
        // 二级页进出 → App 隐藏/恢复自定义 tab bar（push 动画期间同步，避免 bar 压在新页上）
        .onChange(of: path.isEmpty) { _, empty in
            print("PROFILE_DBG path \(empty ? "回到根页" : "进入二级页 depth=\(path.count)") → tabBar \(empty ? "shown" : "hidden")")
            detailActive = !empty
        }
        .onAppear {
            // tab 被销毁重建（切走再切回）时把隐藏状态复位，防 bar 永久消失
            detailActive = !path.isEmpty
        }
    }

    // MARK: - 钉住的顶栏区（19:89 身份行 + 19:180 分类 tab + 19:190 筛选胶囊）

    /// 这三段在画布上是连续的一块，一起做成**固定区**（`safeAreaInset(edge: .top)`），
    /// 封面墙上滑时它们不动（用户要求 2026-11-14：「分类与筛选不应随着上滑而看不见」）。
    /// 纸底不透明：滚动内容从下方穿过时不可见，避免半透明叠字。
    private var pinnedHeader: some View {
        VStack(spacing: 10) {
            identityRow
            categoryTabs
            filterRow
        }
        .padding(.horizontal, DWLayout.edge)
        .padding(.bottom, 8)                 // 与封面墙之间留白（滚动时纸底同色，视觉上是一条静止的分隔带）
        .background(DWColor.paper)
    }

    // MARK: - 身份行（19:89，高 56）

    private var identityRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(DWColor.paperIcon)     // 19:90 头像 #5A5F60，圆角 17=直径/2
                .frame(width: 34, height: 34)
            Text("沉浸")                     // 19:91 昵称
                .font(DWFont.serif(16, .medium))
                .foregroundStyle(DWColor.paperInk)
            Spacer(minLength: 0)
            Button {
                // 夜间模式切换待接全局主题（纸本/墨本双轨尚未贯穿全 App），先占位
            } label: {
                Image(systemName: "moon")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(DWColor.paperIcon)
                    .frame(width: 20, height: 20)
            }
            .accessibilityLabel("夜间模式")
            NavigationLink(value: ProfileRoute.settings) {   // 19:95 设置齿轮 → 纸本设置页（画布 24:43）
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(DWColor.paperIcon)
                    .frame(width: 20, height: 20)
            }
            .accessibilityLabel("设置")
        }
        .padding(.vertical, 11)              // 行高 56：34 + 11×2（水平 padding 由 pinnedHeader 统一给）
        .background(DWColor.paper)
    }

    // MARK: - 分类 tab（19:180，gap22，选中=墨字+朱砂短线）

    private var categoryTabs: some View {
        HStack(spacing: 22) {
            ForEach(ProfileViewModel.Category.allCases, id: \.self) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)             // 搜索图标靠右（画布它跟随文字流，屏宽 390 恰在尾部）
            searchButton
        }
    }

    private func tabButton(_ tab: ProfileViewModel.Category) -> some View {
        let selected = viewModel.category == tab
        return Button {
            guard viewModel.category != tab else { return }
            AppHaptics.light()
            withAnimation(.easeInOut(duration: 0.15)) { viewModel.category = tab }
        } label: {
            VStack(spacing: 5) {             // 19:181 文字与短线 gap5
                Text(tab.rawValue)
                    .font(selected ? DWFont.serif(15, .semibold) : DWFont.serif(15))
                    .foregroundStyle(selected ? DWColor.paperInk : DWColor.paperInkSub)
                Rectangle()
                    .fill(selected ? DWColor.paperCinnabar : .clear)
                    .frame(width: 18, height: 2)   // 19:183 朱砂短线 18×2
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var searchButton: some View {
        Button {
            // 搜索入口待接全局搜索（先占位，不弹不报）
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(DWColor.paperInkSub)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜索")
    }

    // MARK: - 筛选胶囊行（19:190，gap8；选中 #E2DED5 / 未选 #EAE7DF，r14）

    private var filterRow: some View {
        HStack(spacing: 8) {
            ForEach(ProfileViewModel.WatchFilter.allCases, id: \.self) { filter in
                filterChip(filter)
            }
            Spacer(minLength: 0)             // 19:197 弹性占位
            Button {
                // 时间线/站点筛选待做（占位）
            } label: {
                Text("筛选")
                    .font(DWFont.cn(11))
                    .foregroundStyle(DWColor.paperIcon)
            }
            .buttonStyle(.plain)
            Button {
                // 批量管理待做（占位）
            } label: {
                Text("编辑")
                    .font(DWFont.cn(11))
                    .foregroundStyle(DWColor.paperIcon)
            }
            .buttonStyle(.plain)
        }
    }

    private func filterChip(_ filter: ProfileViewModel.WatchFilter) -> some View {
        let selected = viewModel.watchFilter == filter
        return Button {
            guard viewModel.watchFilter != filter else { return }
            withAnimation(.easeInOut(duration: 0.15)) { viewModel.watchFilter = filter }
        } label: {
            Text(filter.rawValue)
                .font(selected ? DWFont.cn(11, .medium) : DWFont.cn(11))
                .foregroundStyle(selected ? DWColor.paperInk : DWColor.paperInkSub)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)       // 胶囊高 28
                .background(selected ? DWColor.paperChipSel : DWColor.paperChipIdle,
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 封面墙（19:200 wrap gap10；卡宽 106，封面 106×114 r6）

    /// 390 - 20×2 = 350 可用宽：3 列 106 + 2 缝 10 = 338，余 12 由 spacing 吸收
    private let columns: [GridItem] = [
        GridItem(.fixed(106), spacing: 10),
        GridItem(.fixed(106), spacing: 10),
        GridItem(.fixed(106))
    ]

    /// 列表末行与 tab bar 之间的呼吸间距（用户要求 2026-11-14：再加大 15pt）
    static let bottomGap: CGFloat = 15

    @ViewBuilder
    private var coverWall: some View {
        if viewModel.items.isEmpty {
            emptyState
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(viewModel.items) { item in
                    NavigationLink(value: ProfileRoute.drama(item.target)) {
                        dramaCard(item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 单卡（19:201）：封面 + 剧名（衬线 fs11）+ 进度（fs10）
    private func dramaCard(_ item: ProfileViewModel.Item) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            coverThumb(item)
                .frame(width: 106, height: 114)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(item.name)
                .font(DWFont.serif(11))
                .foregroundStyle(DWColor.paperInk)
                .lineLimit(1)
            Text(item.progress)
                .font(DWFont.cn(10))
                .foregroundStyle(DWColor.paperInkSub)
                .lineLimit(1)
        }
        .frame(width: 106, alignment: .leading)
    }

    /// 封面三态：图 / 占位色。本地文件直接 Image（AsyncImage 对 file:// 不走缓存还闪），
    /// 远程 URL 用 AsyncImage。与 DramaDetailView 的封面目的一致（coverPlaceholder 是墨本色，纸本下加深一档对比可接受）
    @ViewBuilder
    private func coverThumb(_ item: ProfileViewModel.Item) -> some View {
        if let url = item.coverURL, url.isFileURL {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                coverFallback
            }
        } else if let url = item.coverURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    coverFallback
                default:
                    coverFallback
                }
            }
        } else {
            coverFallback
        }
    }

    /// 无图兜底：与画布封面位（106×114 深色块）一致的中性色
    private var coverFallback: some View {
        Rectangle()
            .fill(DWColor.coverPlaceholder)
            .overlay {
                Image(systemName: "film")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(DWColor.placeholderIcon)
            }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(viewModel.emptyMessage)
                .font(DWFont.serif(13))
                .foregroundStyle(DWColor.paperInkSub)
            Text("去浏览页看几集，这里就会有记录")
                .font(DWFont.cn(11))
                .foregroundStyle(DWColor.paperInkSub.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

// MARK: - 路由（值驱动 NavigationStack 路径）

/// 「我的」页二级页。用路径值而不是 `NavigationLink { destination }` 闭包形式，
/// 是因为 App 需要知道「当前是否在二级页」来隐藏自定义 tab bar——
/// `path.isEmpty` 是唯一事实来源，不用给每个入口各记一个布尔标志。
enum ProfileRoute: Hashable {
    case settings
    case drama(DramaTarget)
}
