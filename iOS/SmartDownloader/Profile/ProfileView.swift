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
            // 四个分类做成系统分页容器（与下载页「下载中 / 已下载」同一个套路）：
            // 点分类 tab 切页、也可以在封面墙上左右滑着切（用户 2026-11-15 要求
            // 「历史-收藏-追更-点赞应该与下载-已下载一样可以左右滑动」）。
            // 每页自带 ScrollView，纵向滚动与横向翻页互不抢手势。
            VStack(spacing: 0) {
                TabView(selection: $viewModel.category) {
                    ForEach(ProfileViewModel.Category.allCases, id: \.self) { category in
                        categoryPage(category)
                            .tag(category)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(DWColor.paper.ignoresSafeArea())
            // 底部避让（用户实报 2026-11-14：tab bar 遮挡封面墙最后一行）：
            // 自定义 tab bar 是 App 层 `safeAreaInset(edge: .bottom)` 注入的，**不进
            // NavigationStack 内的页面**（模拟器 402×874 实测：修复前 contentInsets.bottom
            // 只有 34 的家区，ScrollView 内容区一直画到 840，而 bar 占 794…840 → 重叠 46pt）。
            // 分页 TabView 的页面同样不接收祖先追加的安全区，所以照样在外层补一次，
            // 与下载页 `safeAreaPadding` 同一口径；另 +15 是用户要求的呼吸间距。
            .safeAreaPadding(.bottom, MainTab.barReservedHeight + Self.bottomGap)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)   // 画布无导航条：身份行即顶栏
            // 顶栏区（身份行 + 分类 tab + 筛选胶囊）钉在页面之上，不随封面墙上滑消失
            //（用户要求 2026-11-14）。用 safeAreaInset 而不是塞进每页内容里：
            // 前者是布局级固定，后者进 4 个页面会各钉一份。
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
            .onAppear {
                viewModel.reload()
                #if DEBUG
                // 分类定帧（`-profilePreview 收藏`）：模拟器既点不了 tab 也滑不了分页
                if let preview = Self.previewCategory { viewModel.category = preview }
                #endif
            }
            .onChange(of: viewModel.category) { _, new in
                print("PROFILE_DBG category → \(new.rawValue) items=\(viewModel.items(for: new).count)")
            }
        }
        .preferredColorScheme(.light)   // 纸本轨锁浅色：域级分工，不影响其它页
        // 二级页进出 → App 隐藏/恢复自定义 tab bar（push 动画期间同步，避免 bar 压在新页上）
        .onChange(of: path.isEmpty) { _, empty in
            print("PROFILE_DBG path \(empty ? "回到根页" : "进入二级页 depth=\(path.count)") → tabBar \(empty ? "shown" : "hidden")")
            detailActive = !empty
            // 回到根页重读：详情页里可能改过收藏/点赞。分类不再各自 reload（四个页面
            // 同时在场），不重读的话滑到那一页看到的还是离开前的旧数据。
            if empty { viewModel.reload() }
        }
        .onAppear {
            // tab 被销毁重建（切走再切回）时把隐藏状态复位，防 bar 永久消失
            detailActive = !path.isEmpty
        }
    }

    // MARK: - 分类页（封面墙；一页一个分类）

    private func categoryPage(_ category: ProfileViewModel.Category) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                coverWall(category)
            }
            .padding(.top, 10)
            .padding(.horizontal, DWLayout.edge)
        }
        // 底部避让诊断（开发即埋日志，排障期保留）：contentInsets 是 ScrollView 实际
        // 生效的内容内缩（安全区 + safeAreaPadding）。期望 bottom = 34 + 62 + 15 = 111；
        // 若哪天变成 47/34，说明传递行为变了（或 bar 内边距改了没同步 barReservedHeight）
        .onScrollGeometryChange(for: EdgeInsets.self) { geo in
            geo.contentInsets
        } action: { _, insets in
            print("PROFILE_DBG insets cat=\(category.rawValue) top=\(insets.top) bottom=\(insets.bottom) barReserved=\(MainTab.barReservedHeight) gap=\(Self.bottomGap)")
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

    // MARK: - 封面墙（19:200；2026-11-15 起与剧集页「为你推荐」同一套双列海报卡）

    /// 列表末行与 tab bar 之间的呼吸间距（用户要求 2026-11-14：再加大 15pt）
    static let bottomGap: CGFloat = 15

    #if DEBUG
    /// 分类定帧（`-profilePreview 收藏`）：模拟器既点不了 tab 也滑不了分页，
    /// 另外三个分类页只能靠启动参数直接落位截图核对。Release 不编译。
    private static var previewCategory: ProfileViewModel.Category? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-profilePreview"), i + 1 < args.count else { return nil }
        return ProfileViewModel.Category(rawValue: args[i + 1])
    }
    #endif

    @ViewBuilder
    private func coverWall(_ category: ProfileViewModel.Category) -> some View {
        let items = viewModel.items(for: category)
        if items.isEmpty {
            emptyState(category)
        } else {
            // 三列海报卡组件与剧集页推荐 / 下载页「已下载」共用（Components/PosterGrid.swift）：
            // 封面 3:4 + 固定 67 文字块，列宽按容器现算（不再写死 3 列 106×114）；
            // 一行 3 张（2026-11-15 用户拍板），字号走 `compact` 档
            PosterGrid(items: items, columns: 3) { item in
                NavigationLink(value: ProfileRoute.drama(item.target)) {
                    PosterCardView(model: cardModel(item, category: category), compact: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 封面墙一张卡：剧名 + 该分类进度 + 分类状态（推荐卡同一套三行文字块）
    private func cardModel(_ item: ProfileViewModel.Item,
                           category: ProfileViewModel.Category) -> PosterCardModel {
        PosterCardModel(
            id: item.id,
            title: item.name,
            subtitle: item.progress,
            stat: viewModel.statusText(for: category),
            cover: coverSource(item.coverURL)
        )
    }

    /// 封面来源：本地缓存文件直接读盘（AsyncImage 对 file:// 不走缓存还闪），远程走 AsyncImage
    private func coverSource(_ url: URL?) -> PosterCoverSource {
        guard let url else { return .none }
        return url.isFileURL ? .local(url) : .remote(url)
    }

    private func emptyState(_ category: ProfileViewModel.Category) -> some View {
        VStack(spacing: 8) {
            Text(viewModel.emptyMessage(for: category))
                .font(DWFont.serif(13))
                .foregroundStyle(DWColor.paperInkSub)
            Text(viewModel.emptyHint(for: category))
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
