import SwiftUI
import CoreText

// MARK: - 剧集详情页（DramaWave · 390×840 设计稿 + 可滚动扩展）
//
// 设计源：drama-detail.html「剧集详情页三态对照原型」。屏内仍用固定 390 宽的设计坐标，
// 逐节点用 designFrame 落位；颜色/字体复用 Shared/DesignTokens.swift。
// 三态：desc-collapsed（简介两行）/ desc-expanded（内容组 +54pt）/ cover-failed（占位 + 重试）。
//
// 2026-11-12 更新（按用户拍板）：
//  1. 屏内改为可滚动（设计稿 .screen 本来就是 overflow-y:auto），画布高度从固定 840
//     扩到 840 + 为你推荐 + 剧集档案；缩放改按屏宽，不再按高度压整屏。
//  2. 移除底部固定 CTA，选集格子恢复「直点」语义（播放 / 取消下载 / 直接下载）。
//  3. 补设计稿缺项：「下载全部」、下载中 n/100 分数。
//  4. 新增「为你推荐」双列瀑布流 + 「剧集档案」，数据全部来自本地 SQLite（离线可用）。
//  保留此前真机迭代成果：海报 376、≤12 集固定栅格。
//  5. 同日追加三项设计稿还原：右下 18×18 状态角标、进度环由绿改回金色 #F5C451、
//     「查看全部」由 sheet 改为内联展开 13+ 集（全选/清空/下载所选进内联工具条，刷新移到选集行 ↻）。
//
// 本文件只渲染 + 转发用户意图；业务状态与编排在 DramaPageViewModel（AGENTS.md MVVM 约定）。

// MARK: - 布局常量与滚动画布尺寸

private enum DetailLayout {
    /// 海报高 470 → 376（用户要求降低 20%）；文字层坐标保持不动
    static let posterHeight: CGFloat = 376
    /// 内容组相对设计稿整体上移，收紧「简介 → 选集」空白
    static let sectionLift: CGFloat = 32
    /// 「查看全部」内联展开：额外集 6 列 × 56pt 步进，末尾留一条批量工具条
    static let inlineRowStep: CGFloat = 56
    static let inlineToolbarHeight: CGFloat = 44

    // 为你推荐（设计稿 .reco / .reco-grid / .reco-card）
    static let recoTopPadding: CGFloat = 16
    static let recoTitleBlock: CGFloat = 34      // 22 标题 + 12 margin
    static let recoBottomPadding: CGFloat = 28
    static let recoColumnGap: CGFloat = 10
    static let recoCardGap: CGFloat = 12
    static let recoColumnWidth: CGFloat = 170   // (390 - 20*2 - 10) / 2
    static let recoCoverHeights: [CGFloat] = [228, 184, 150]
    static let recoTextHeight: CGFloat = 86     // 标题 8+36 + 标签 4+15 + 统计 4+15 + 余量

    // 剧集档案
    static let archiveTopPadding: CGFloat = 16
    static let archiveTitleBlock: CGFloat = 44
    static let archiveSectionTitle: CGFloat = 24
    static let archiveRowHeight: CGFloat = 26
    static let archiveSectionPadding: CGFloat = 36
    static let archiveSectionGap: CGFloat = 8
    static let archiveBottomPadding: CGFloat = 28
    static let archiveSlack: CGFloat = 40       // 估算留白，宁多勿裁
}

/// 一张推荐卡片带全局序号：序号决定封面三档高度（设计稿 h-tall/h-mid/h-low 循环）
private struct RecoCardItem: Identifiable {
    let index: Int
    let drama: RecommendedDrama
    var id: Int { drama.id }
}

/// 滚动画布的尺寸预算。设计坐标是固定的，但推荐/档案条数随真实数据变化，
/// 必须算出总高才能让 ScrollView 的 contentSize 正确（缩放后的 frame 也依赖它）。
private struct PageLayout {
    let leftItems: [RecoCardItem]
    let rightItems: [RecoCardItem]
    let recoGridHeight: CGFloat
    let recoY: CGFloat
    let recoHeight: CGFloat
    let archiveY: CGFloat
    let archiveHeight: CGFloat
    let totalHeight: CGFloat
}

struct DramaDetailView: View {
    @ObservedObject var vm: DramaPageViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 左缘右滑返回的跟手位移（系统 pop 手势在导航栏隐藏时失效，这里自己补）
    @State private var edgeDragWidth: CGFloat = 0
    /// 简介两行测量：文字实际渲染超过两行才允许出现「展开/收起」（用户拍板 2026-11-13）
    @State private var introOverflow = false
    /// 简介第二行实际渲染宽度（CoreText 量出）：截断态胶囊贴行尾用
    @State private var introSecondLineWidth: CGFloat = 0
    /// 第一行基线到第二行基线的距离（CoreText 实测，行高取整后 + 行距）
    @State private var introLineDelta: CGFloat = 0
    /// 展开态最后一条**完整可见**行的基线距首行的距离（CoreText 实测）：收起按钮纵向落位
    @State private var introLastLineDelta: CGFloat = 0
    /// 展开态最后一条**完整可见**行的实际宽度：收起按钮贴行尾用
    @State private var introLastLineWidth: CGFloat = 0
    /// 顶栏底下还是不是海报（纸本化 2026-11-14）：海报盖着顶栏时用白图标 + 墨色 scrim，
    /// 滚过去之后顶栏换纸底 + 细线 + 墨色图标。没有这个开关，滚到选集以后会剩一条
    /// 灰雾压在宣纸上——深色轨的 scrim 直接搬到纸面上就是坏掉的样子。
    @State private var posterUnderHeader = true

    /// 简介展开位移：设计稿 --desc-shift，唯一驱动「简介容器高度」与「内容组 translateY」
    private var descShift: CGFloat { vm.isDescriptionExpanded ? 54 : 0 }
    /// 设计稿 .32s cubic-bezier(.2,.8,.2,1)；reduced-motion 时全动效归零
    private var motion: Animation? {
        reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)
    }

    var body: some View {
        GeometryReader { geo in
            // 内容超屏后按高度缩放会把顶部整体压小，改按屏宽等比缩放（390 宽机型 = 1:1）
            let scale = geo.size.width / DWLayout.designWidth
            ZStack {
                if vm.loading {
                    loadingState
                } else if let error = vm.loadError {
                    errorState(error)
                } else if let info = vm.info {
                    let layout = pageLayout(info)
                    ScrollView(.vertical, showsIndicators: false) {
                        canvas(info, layout: layout)
                            .frame(width: DWLayout.designWidth, height: layout.totalHeight)
                            .scaleEffect(scale, anchor: .topLeading)
                            // scaleEffect 不改布局尺寸，外层 frame 给出缩放后的真实占位
                            .frame(width: DWLayout.designWidth * scale,
                                   height: layout.totalHeight * scale,
                                   alignment: .topLeading)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    // 顶栏随滚动换底：海报底边（设计 376，按 scale 换算成屏幕点）压过
                    // 顶栏底（96）就切纸底。offset 是屏幕点，两边同一口径。
                    .onScrollGeometryChange(for: Bool.self) { g in
                        g.contentOffset.y + 96 * scale < DetailLayout.posterHeight * scale
                    } action: { _, overPoster in
                        posterUnderHeader = overPoster
                    }
                    #if DEBUG
                    // 样张落到页底（`-dramaPreviewBottom`）：模拟器滑不了，
                    // 要看「滚过海报后的顶栏」和档案区只能靠它。
                    .defaultScrollAnchor(DramaDebugFlags.bottomAnchor ? .bottom : .top)
                    #endif
                    // 顶栏（返回 / 收藏）钉在屏幕顶部：**不随页面滚动**，用户拍板 2026-11-14
                    .overlay(alignment: .topLeading) { pinnedHeader(scale: scale) }
                    // 左缘右滑时整屏跟手，露出左侧底层，模拟系统返回观感
                    .offset(x: edgeDragWidth)
                    // toast 改屏幕悬浮：画布变长后不能再钉在 y690
                    .overlay(alignment: .bottom) {
                        ToastView(message: vm.toastText)
                            .padding(.bottom, 40)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .background(DWColor.paper.ignoresSafeArea())
        // 设计稿是沉浸式全屏，状态栏之上不叠系统导航栏；返回用屏内自带按钮
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        // 整页 ScrollView 的 pan 与左缘返回并存：仍只在左缘 + 横向主导时生效
        .simultaneousGesture(edgeBackGesture)
    }

    /// 只在屏幕左缘 30pt 内起手、横向主导地右拖才生效；抬手过阈值触发 dismiss，否则弹回。
    private var edgeBackGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard value.startLocation.x <= 30,
                      value.translation.width > 0,
                      value.translation.width > abs(value.translation.height) * 1.2 else { return }
                edgeDragWidth = min(value.translation.width, 160)
            }
            .onEnded { value in
                guard value.startLocation.x <= 30,
                      value.translation.width > abs(value.translation.height) * 1.2 else {
                    withAnimation(.easeOut(duration: 0.2)) { edgeDragWidth = 0 }
                    return
                }
                if value.translation.width > 80 || value.predictedEndTranslation.width > 180 {
                    dismiss()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { edgeDragWidth = 0 }
                }
            }
    }

    // MARK: - 尺寸预算

    private func pageLayout(_ info: DramaInfo) -> PageLayout {
        let items = vm.recommendations.enumerated().map {
            RecoCardItem(index: $0.offset, drama: $0.element)
        }
        let left = items.filter { $0.index % 2 == 0 }
        let right = items.filter { $0.index % 2 == 1 }
        func columnHeight(_ list: [RecoCardItem]) -> CGFloat {
            list.reduce(0) { sum, item in
                sum + DetailLayout.recoCoverHeights[item.index % 3]
                    + DetailLayout.recoTextHeight + DetailLayout.recoCardGap
            }
        }
        let gridHeight = max(columnHeight(left), columnHeight(right))
        let recoHeight = items.isEmpty ? 0 :
            DetailLayout.recoTopPadding + DetailLayout.recoTitleBlock
            + gridHeight + DetailLayout.recoBottomPadding

        var archiveHeight: CGFloat = 0
        if !vm.archiveSections.isEmpty {
            let rowsTotal = vm.archiveSections.reduce(0) {
                $0 + CGFloat($1.rows.count) * DetailLayout.archiveRowHeight
            }
            archiveHeight = DetailLayout.archiveTopPadding + DetailLayout.archiveTitleBlock
                + CGFloat(vm.archiveSections.count)
                * (DetailLayout.archiveSectionPadding + DetailLayout.archiveSectionGap)
                + rowsTotal + DetailLayout.archiveBottomPadding + DetailLayout.archiveSlack
        }

        // 内容组最后一个元素的设计底 y：折叠 = hint 底 668；
        // 展开 = 额外集(642 起、每行 56) + 批量工具条 + hint，额外集把推荐/档案一起下推。
        // 内容组整体还有 (descShift - sectionLift) 位移，reco 必须按同一口径对齐。
        let rows = vm.extraEpisodeRows
        let expanded = vm.showAllEpisodesInline && rows > 0
        let contentBottomDesignY: CGFloat = expanded
            ? 720 + CGFloat(rows) * DetailLayout.inlineRowStep
            : 668
        let recoY = contentBottomDesignY + descShift - DetailLayout.sectionLift + 24
        let archiveY = recoY + recoHeight + (recoHeight > 0 ? 8 : 0)
        let totalHeight = max(DWLayout.designHeight, archiveY + archiveHeight + 40)
        return PageLayout(leftItems: left, rightItems: right,
                          recoGridHeight: gridHeight, recoY: recoY, recoHeight: recoHeight,
                          archiveY: archiveY, archiveHeight: archiveHeight,
                          totalHeight: totalHeight)
    }

    // MARK: - 屏内画布

    /// 层序与设计稿一致：海报 → 光晕/scrim → 占位 → 文字 → 内容组 → 推荐 → 档案
    /// 顶栏（返回 / 收藏）**不在画布里**——它钉在 ScrollView 之上（body 里的 pinnedHeader）
    @ViewBuilder
    private func canvas(_ info: DramaInfo, layout: PageLayout) -> some View {
        ZStack(alignment: .topLeading) {
            DWColor.paper
                .frame(width: DWLayout.designWidth, height: layout.totalHeight)
            coverLayer
            titleAndTags(info)
            descriptionBlock
            contentGroup(info)
            if layout.recoHeight > 0 {
                recommendationSection(layout: layout)
                    .designFrame(0, layout.recoY, DWLayout.designWidth, layout.recoHeight)
            }
            if layout.archiveHeight > 0 {
                archiveSection(layout: layout)
                    .designFrame(0, layout.archiveY, DWLayout.designWidth, layout.archiveHeight)
            }
        }
        .frame(width: DWLayout.designWidth, height: layout.totalHeight)
    }

    // MARK: ① 海报层（三态占位）

    /// 无封面时的海报底：纸本轨用「墨块」而不是原来的紫渐变。
    /// 剧名/标签是白字、压在底部 scrim 上，底色必须是墨——纸色会让白字直接消失。
    private var posterGradient: some View {
        LinearGradient(stops: [
            .init(color: DWColor.paperInkTop, location: 0),
            .init(color: DWColor.paperInkMid, location: 0.45),
            .init(color: DWColor.paperInkBottom, location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    /// 真实封面 + 三态占位。AsyncImage 的 phase 是纯渲染状态，重试由 VM 的
    /// coverReloadToken 换 id 重建（无 URL 时由 VM 重新收割元数据）。
    private var coverLayer: some View {
        ZStack(alignment: .topLeading) {
            posterGradient
            if let url = vm.coverURL {
                AsyncImage(url: url) { phase in
                    ZStack(alignment: .topLeading) {
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                                .frame(width: 390, height: DetailLayout.posterHeight)
                                .clipped()
                        case .failure, .empty:
                            DWColor.paperInkPlate
                        @unknown default:
                            DWColor.paperInkPlate
                        }
                        // 纸本轨去掉原来的径向光晕：宣纸上不会有色晕，那一层只在
                        // 深色轨成立。封面本身有明暗，scrim 够了。
                        scrimBottom
                        switch phase {
                        case .empty: loadingPlaceholder
                        case .failure: failurePlaceholder
                        default: EmptyView()
                        }
                    }
                    .frame(width: 390, height: DetailLayout.posterHeight)
                }
                .id(vm.coverReloadToken)
            } else {
                ZStack(alignment: .topLeading) {
                    DWColor.paperInkPlate
                    scrimBottom
                    failurePlaceholder
                }
                .frame(width: 390, height: DetailLayout.posterHeight)
            }
        }
        .designFrame(0, 0, 390, DetailLayout.posterHeight)
        .clipped()
    }

    /// 顶部压暗渐变：现在由 `pinnedHeader` 常驻渲染（不再属于海报层），
    /// 保证顶栏图标在任何滚动位置都有对比度。纸本化后它只在「海报还盖着顶栏」时出现，
    /// 滚过去换纸底（见 pinnedHeader）。
    private var scrimTop: some View {
        LinearGradient(colors: [.black.opacity(0.45), .clear],
                       startPoint: .top, endPoint: .bottom)
            .designFrame(0, 0, 390, 96)
            .allowsHitTesting(false)
    }

    /// 滚过海报后的顶栏底：96 高纸面 + 一条细线（与设置页纸本导航栏同一种做法），
    /// 高度与 scrimTop 一致，切换时图标不位移。
    private var paperHeaderPlate: some View {
        VStack(spacing: 0) {
            DWColor.paper
                .frame(width: 390, height: 96)
            DWColor.paperHairline
                .frame(width: 390, height: 0.5)
        }
        .allowsHitTesting(false)
    }

    /// 海报上的说明文字用纸白半透明（墨块上紫灰读不出来）
    private var onPosterSubText: Color { Color.white.opacity(0.62) }

    private var scrimBottom: some View {
        LinearGradient(colors: [.clear, .black.opacity(0.92)],
                       startPoint: .top, endPoint: .bottom)
            .designFrame(0, 176, 390, 200)
            .allowsHitTesting(false)
    }

    /// 加载中占位：spinner + 「正在加载封面…」
    private var loadingPlaceholder: some View {
        ZStack(alignment: .topLeading) {
            ProgressView()
                .tint(DWColor.paperCinnabar)
                .designFrame(171, 134, 48, 48)
            Text("正在加载封面…")
                .font(DWFont.cn(13, .medium))
                .foregroundStyle(onPosterSubText)
                .designFrame(115, 190, 160, 18)
        }
        .frame(width: 390, height: DetailLayout.posterHeight)
        .allowsHitTesting(false)
    }

    /// 失败占位：破图图标 + 文案 + 点击重试（命中区仍 90×44）
    private var failurePlaceholder: some View {
        ZStack(alignment: .topLeading) {
            Image(systemName: "photo")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.30))
                .designFrame(171, 134, 48, 48)
            Text("封面加载失败")
                .font(DWFont.cn(13, .medium))
                .foregroundStyle(onPosterSubText)
                .designFrame(156, 190, 78, 18)
            Button { vm.retryCover() } label: {
                Text("点击重试")
                    .font(DWFont.cn(12, .medium))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .frame(width: 90, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(150, 208, 90, 44)
            .accessibilityLabel("点击重试加载封面")
        }
        .frame(width: 390, height: DetailLayout.posterHeight)
    }

    // MARK: ② 顶栏（钉在屏幕顶部，不随滚动）

    /// 固定顶栏层：与画布同一套设计坐标（390 宽），在 body 里按 scale 缩放后叠在
    /// ScrollView 之上。高度只取 100（顶栏内容全部落在 y44…88），不铺满整屏，
    /// 这样它不会挡住下方的滚动区域。
    private func pinnedHeader(scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // 两层同时在场、只切不透明度：交叉淡入比「换视图」少一次硬跳。
            // 海报盖着顶栏 → 墨色 scrim + 白图标；滚过去 → 纸底 + 细线 + 墨图标。
            scrimTop
                .opacity(posterUnderHeader ? 1 : 0)
            paperHeaderPlate
                .opacity(posterUnderHeader ? 0 : 1)
            headerBar
        }
        .frame(width: DWLayout.designWidth, height: 100)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: DWLayout.designWidth * scale, height: 100 * scale, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: posterUnderHeader)
    }

    /// 顶栏图标色：压在海报上是纸白，落在纸面上是墨
    private var headerGlyphColor: Color {
        posterUnderHeader ? .white : DWColor.paperInk
    }

    /// 收藏态：海报上仍是白（设计稿 30:110 的实心白），纸面上一枚朱砂——
    /// 纸本轨里「已收藏」= 一方印，与设置页/我的页同一个说法
    private var heartColor: Color {
        guard vm.isFavorite else { return headerGlyphColor }
        return posterUnderHeader ? .white : DWColor.paperCinnabar
    }

    /// 视觉盒 32×32 @ (16,50)/(334,50)，命中区外扩到 44×44（设计稿 ::after 规则）
    private var headerBar: some View {
        ZStack(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(headerGlyphColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(10, 44, 44, 44)
            .accessibilityLabel("返回")

            Button { vm.toggleFavorite() } label: {
                Image(systemName: vm.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(heartColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(328, 44, 44, 44)
            .accessibilityLabel(vm.isFavorite ? "取消收藏" : "收藏")
        }
        .frame(width: 390, height: 100)
    }

    // MARK: ③ 标题 / 标签 / 简介（不随展开位移）

    private func titleAndTags(_ info: DramaInfo) -> some View {
        ZStack(alignment: .topLeading) {
            // 画布 22:172 的节点名就是「剧名 24pt 衬线」——深色轨当年落成了黑体，
            // 纸本轨按画布改回衬线（与设置页/我的页标题同一族）。白字压在墨色 scrim 上。
            Text(info.name)
                .font(DWFont.serif(24, .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .designFrame(20, 310, 350, 32, alignment: .leading)

            ForEach(Array(vm.tagChips.enumerated()), id: \.offset) { index, tag in
                Text(tag)
                    .font(DWFont.cn(11, .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: 56, height: 22)
                    .background(DWColor.tagFill, in: Capsule())
                    .designFrame(20 + CGFloat(index) * 64, 352, 56, 22)
            }
        }
        .frame(width: 390, height: 840)
    }

    private var descriptionBlock: some View {
        ZStack(alignment: .topLeading) {
            let height = introTwoLineHeight + descShift
            Text(vm.intro ?? "")
                .font(DWFont.cn(13))
                .lineSpacing(5)
                .foregroundStyle(DWColor.paperInk)
                .lineLimit(vm.isDescriptionExpanded ? nil : 2)
                .frame(width: 350, height: height, alignment: .topLeading)
                .clipped()
                .designFrame(20, 386, 350, height, alignment: .topLeading)
                .animation(motion, value: vm.isDescriptionExpanded)

            // 截断态行尾胶囊（用户拍板 2026-11-14）：位置按**第二行实际渲染宽度**落位，
            // 不能钉 frame 右缘——简介带换行符或第二行较短时文字行尾缩在中间，
            // 胶囊会孤零零停在最右侧（真机实证「跑到垂直中心靠右」）。宽度/纵向间距
            // 来自 measureIntroOverflow 的 CoreText 自然排版（与 Text 同字体/同宽/同行距）
            if !vm.isDescriptionExpanded, introOverflow {
                introTailPill
                    .designFrame(introPillX, introPillY, introPillWidth, 18)
            }

            if vm.isDescriptionExpanded {
                if introOverflow {
                    // 展开态「收起」：与截断态胶囊**同一落位规则**——贴最后一行行尾、
                    // 右侧最多收到 370（与胶囊同一右边界）。曾钉死 (296, 471) 68×44，
                    // 文案居中在框内导致距右缘比胶囊远 10pt+，纵向也不跟文本行（真机反馈）
                    Button { vm.toggleDescription() } label: {
                        HStack(spacing: 2) {
                            Text("收起")
                                .lineLimit(1)
                            Image(systemName: "chevron.up")
                        }
                        .font(DWFont.cn(12, .medium))
                        .foregroundStyle(DWColor.paperCinnabar)
                        // fixedSize：宽度只由内容决定，永不因容器窄了而换行/竖排
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: collapseWidth, height: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .designFrame(collapseX, collapseY, collapseWidth, 44)
                }
            }
        }
        .frame(width: 390, height: 840)
        .onAppear { measureIntroOverflow(vm.intro ?? "") }
        .onChange(of: vm.intro) { _, new in
            measureIntroOverflow(new ?? "")
            // 简介变短（含换集）后不再溢出时自动收回：按钮已隐藏，展开位移不能悬空
            if !introOverflow, vm.isDescriptionExpanded { vm.isDescriptionExpanded = false }
        }
    }

    /// 截断态行尾胶囊：左缘 20pt 渐隐过渡到背景色，露出「… 展开」；仅自身可点
    private var introTailPill: some View {
        Text("… 展开")
            .font(DWFont.cn(12, .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(DWColor.paperCinnabar)
            .padding(.leading, 22)
            .padding(.trailing, 3)
            .frame(height: 18)
            .background(LinearGradient(colors: [.clear, DWColor.paper, DWColor.paper],
                                       startPoint: .leading, endPoint: .trailing))
            .contentShape(Rectangle())
            .onTapGesture { vm.toggleDescription() }
    }

    // MARK: 简介行尾胶囊几何（全部来自渲染度量，勿凭目测调）

    /// 简介正文行高（13pt 系统字体，与 Text 渲染一致）
    private var introLineHeight: CGFloat { UIFont.systemFont(ofSize: 13).lineHeight }

    /// 简介行距（与 Text 的 .lineSpacing 必须一致）
    private let introLineSpacing: CGFloat = 5

    /// 截断态简介容器高度：**CoreText 会把行高向上取整**再加行距
    /// （13pt 系统字体 lineHeight≈15.31 → 取整 16，两行 = 16×2 + 5 = 37）。
    /// 曾硬编码 36（按 15.31×2+5≈35.6 手算），比实际所需少 1pt，
    /// SwiftUI 判定第二行放不下 → **只画一行**（真机实证）。+1 是给 SwiftUI
    /// 与 CoreText 取整差留的容差。
    private var introTwoLineHeight: CGFloat {
        ceil(introLineHeight) * 2 + introLineSpacing + 1
    }

    /// 胶囊总宽 = 文案实测 38 + 左 22（渐隐过渡）+ 右 3（宽度只用于落位，文案本身
    /// 已 fixedSize + lineLimit(1)，不会再因差 1pt 而换行）
    private var introPillWidth: CGFloat {
        let font = UIFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = ("… 展开" as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth) + 22 + 3
    }

    /// 胶囊左上角 x：贴第二行行尾（左移一个「…」宽度压住系统省略号）；
    /// 行尾太靠右时右对齐收进文本框（20…370）
    private var introPillX: CGFloat {
        let lineEnd = 20 + min(introSecondLineWidth, 350)
        let preferred = lineEnd - 13
        return max(20, min(preferred, 370 - introPillWidth))
    }

    /// 胶囊左上角 y：第二行垂直居中（386 + 实测基线间距 + (行框高-胶囊高)/2）
    private var introPillY: CGFloat {
        let box = introLineBoxHeight
        let delta = introLineDelta > 0 ? introLineDelta : ceil(introLineHeight) + introLineSpacing
        return 386 + delta + (box - 18) / 2
    }

    /// 简介正文单行的字框高度（ascent + descent）
    private var introLineBoxHeight: CGFloat {
        let f = UIFont.systemFont(ofSize: 13)
        return f.ascender - f.descender
    }

    /// 「收起」按钮宽 = 「收起」实测 24 + 间距 2 + chevron 实测 14（SF Symbol 12pt = 14×8）+ 容差 2。
    /// 曾按 chevron≈12 估成 38，比实际 intrinsic（40）窄 2pt → Text 被压缩后
    /// **「收起」两个字竖排**（收在上、起在下，真机实证）。
    private var collapseWidth: CGFloat {
        let font = UIFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = ("收起" as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth) + 2 + 14 + 2
    }

    /// 「收起」是否与末行同行（行尾还剩 ≥ 按钮宽 + 6pt 的空间）
    private var collapseFitsInline: Bool {
        let lineEnd = 20 + min(introLastLineWidth, 350)
        return lineEnd + 6 + collapseWidth <= 370
    }

    /// 「收起」左上角 x：同行放得下就贴行尾（与胶囊同一规则，只是不压省略号，留 6pt）；
    /// 放不下则右对齐到文本右缘 370 —— 与胶囊被 clamp 时的右边界完全一致
    private var collapseX: CGFloat {
        let lineEnd = 20 + min(introLastLineWidth, 350)
        return collapseFitsInline ? lineEnd + 6 : 370 - collapseWidth
    }

    /// 「收起」左上角 y：同行就垂直居中于末行；放不下则落到末行下方
    ///（按钮 44pt 触摸高、可见内容约 18pt，故上边距取 -13 让可见内容贴行底 +2）
    private var collapseY: CGFloat {
        let delta = introLastLineDelta > 0 ? introLastLineDelta : ceil(introLineHeight) + introLineSpacing
        let lineTop = 386 + delta
        if collapseFitsInline { return lineTop + introLineBoxHeight / 2 - 22 }
        return lineTop + introLineBoxHeight + 2 - 13
    }

    /// 简介测量（View 层职责：渲染度量不走 VM）：用 CoreText 按实际渲染参数
    ///（宽 350 / 13pt / 行距 5 / **自动换行**）排全文，一次拿到五个量：
    ///  - introOverflow：自然排版超过两行 → 需要「展开」
    ///  - introSecondLineWidth / introLineDelta：第二行宽度与基线距 → 截断态胶囊落位
    ///  - introLastLineWidth / introLastLineDelta：展开态最后一条完整可见行的宽度与
    ///    基线距 → 「收起」贴行尾落位（展开容器固定 54pt 位移，超出的行会被裁掉，
    ///    所以这里按 `introTwoLineHeight + 54` 的实际可视高度取最后一条完整行）
    ///
    /// **禁止用 `.byTruncatingTail` 测量**：CoreText 会把整段当成一行做尾部截断
    /// （实测 lines 恒为 1、末行 range 覆盖全文），溢出判定恒为 false，按钮直接消失。
    /// 截断是渲染阶段的事，测量只看自然换行结果。
    private func measureIntroOverflow(_ text: String) {
        let measured = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let uiFont = UIFont.systemFont(ofSize: 13)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = introLineSpacing
        style.lineBreakMode = .byWordWrapping
        let attr = NSAttributedString(string: measured,
                                      attributes: [.font: uiFont, .paragraphStyle: style])
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        // 高度给足，只为拿到「自然排版」的行数与各行宽度
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: 350, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        if !lines.isEmpty {
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)
        }
        var secondLineWidth: CGFloat = 0
        var delta: CGFloat = 0
        if lines.count >= 2 {
            secondLineWidth = CGFloat(CTLineGetTypographicBounds(lines[1], nil, nil, nil))
            delta = origins[0].y - origins[1].y
        }
        // 展开态可视范围：容纳最后一条「整行」都在框内的行
        let expandableHeight = introTwoLineHeight + 54
        let lineBox = uiFont.ascender - uiFont.descender
        var lastIdx = 0
        for i in 0..<lines.count {
            let top = origins[0].y - origins[i].y
            if top + lineBox <= expandableHeight + 0.5 { lastIdx = i } else { break }
        }
        var lastLineWidth: CGFloat = 0
        var lastLineDelta: CGFloat = 0
        if !lines.isEmpty {
            lastLineWidth = CGFloat(CTLineGetTypographicBounds(lines[lastIdx], nil, nil, nil))
            lastLineDelta = origins[0].y - origins[lastIdx].y
        }
        introSecondLineWidth = min(secondLineWidth, 350)
        introLineDelta = delta
        introLastLineWidth = min(lastLineWidth, 350)
        introLastLineDelta = lastLineDelta
        introOverflow = lines.count > 2
        print("PLAYER_DBG [Entry] introOverflow=\(introOverflow) lines=\(lines.count) line2W=\(Int(secondLineWidth)) delta=\(Int(delta)) lastIdx=\(lastIdx) lastW=\(Int(lastLineWidth)) lastDelta=\(Int(lastLineDelta)) len=\(measured.count) boxH=\(Int(introTwoLineHeight))")
        // 落位对账：胶囊（截断态）与「收起」（展开态）的实测坐标，右缘应为 370 或贴行尾
        print("PLAYER_DBG [Entry] introGeo pill=(\(Int(introPillX)),\(Int(introPillY)),w\(Int(introPillWidth))) collapse=(\(Int(collapseX)),\(Int(collapseY)),w\(Int(collapseWidth))) inline=\(collapseFitsInline)")
    }

    // MARK: ④ 内容组（唯一位移 translateY(--desc-shift)）

    private func contentGroup(_ info: DramaInfo) -> some View {
        ZStack(alignment: .topLeading) {
            Text("选集")
                .font(DWFont.serif(16, .medium))
                .foregroundStyle(DWColor.paperInk)
                .designFrame(20, 490, 64, 24, alignment: .leading)

            Text(vm.episodeCountText)
                .font(DWFont.cn(12))
                .foregroundStyle(DWColor.paperInkSub)
                .designFrame(96, 494, 76, 18, alignment: .leading)

            // 设计稿「下载全部」：一次把所有可下且未入队的集交给现有调度。
            // 纸本轨的动作文字一律朱砂（设置页「重命名」/下载页「全选」同一档）。
            Button { vm.downloadAll() } label: {
                Text("下载全部")
                    .font(DWFont.cn(12, .medium))
                    .foregroundStyle(DWColor.paperCinnabar)
                    .frame(width: 64, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(176, 481, 64, 44)

            // 原「查看全部」sheet 里的刷新能力：sheet 移除后由选集行这个 ↻ 承接
            Button { vm.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DWColor.paperCinnabar)
                    .frame(width: 28, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(244, 481, 28, 44)
            .accessibilityLabel("刷新剧集列表")

            // 「查看全部 ›」= 内联展开（设计稿 all-open），不再是 sheet。
            // ≤12 集没有额外集可展开：保留版面、置灰禁用，文案如实说明。
            Button {
                withAnimation(motion) { vm.showAllEpisodesInline.toggle() }
            } label: {
                Text(vm.hasExtraEpisodes
                     ? (vm.showAllEpisodesInline ? "收起 ›" : "查看全部 ›")
                     : "已显示全部")
                    .font(DWFont.cn(12, .medium))
                    .foregroundStyle(vm.hasExtraEpisodes
                                     ? DWColor.paperCinnabar : DWColor.paperFaint)
                    .frame(width: 90, height: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!vm.hasExtraEpisodes)
            .designFrame(280, 481, 90, 44)

            episodeGrid(info)

            let hintY: CGFloat = vm.showAllEpisodesInline && vm.extraEpisodeRows > 0
                ? 702 + CGFloat(vm.extraEpisodeRows) * DetailLayout.inlineRowStep
                : 650
            Text(vm.hintText)
                .font(DWFont.cn(12))
                .foregroundStyle(DWColor.paperFaint)
                .lineLimit(1)
                .designFrame(20, hintY, 350, 18, alignment: .leading)
        }
        .frame(width: 390, height: vm.showAllEpisodesInline
               ? max(840, 720 + CGFloat(vm.extraEpisodeRows) * DetailLayout.inlineRowStep + 40)
               : 840)
        // 整体上移收紧「简介 → 选集」空白 + 展开态的 54pt 位移，两者叠加
        .offset(y: descShift - DetailLayout.sectionLift)
        .animation(motion, value: vm.isDescriptionExpanded)
    }

    /// 选集区：前 12 集固定 6×2（直点）；「查看全部」内联展开 13 集以后的集
    /// （6 列 × 56pt 步进，设计稿 all-open 语义），底部接一条批量工具条，
    /// 推荐区 / 档案区由 pageLayout 按 extraEpisodeRows 一起下推。
    /// 展开集用 `vm.tapEpisode`（多选勾选 / 已下载直接播），主屏 12 格用 `tapEpisodeDirect`。
    @ViewBuilder
    private func episodeGrid(_ info: DramaInfo) -> some View {
        ForEach(Array(info.episodes.prefix(12).enumerated()), id: \.element.id) { index, ep in
            let col = CGFloat(index % 6)
            let row = CGFloat(index / 6)
            episodeCellButton(ep, multiSelect: false)
                .designFrame(20 + col * 60, 530 + row * 56, 50, 44)
        }

        if vm.showAllEpisodesInline && vm.hasExtraEpisodes {
            ForEach(Array(info.episodes.dropFirst(12).enumerated()), id: \.element.id) { index, ep in
                let slot = index + 12
                let col = CGFloat(slot % 6)
                let row = CGFloat(slot / 6)
                episodeCellButton(ep, multiSelect: true)
                    .designFrame(20 + col * 60, 530 + row * 56, 50, 44)
            }
            inlineBatchToolbar
                .designFrame(20, 650 + CGFloat(vm.extraEpisodeRows) * DetailLayout.inlineRowStep,
                             350, DetailLayout.inlineToolbarHeight)
        }
    }

    /// 内联展开区的批量工具条：原 sheet 的「全选 / 清空 / 下载所选」搬到这里，
    /// 刷新已移到选集行 ↻，所以 sheet 可以整块删掉，功能不丢。
    private var inlineBatchToolbar: some View {
        HStack(spacing: 8) {
            // 纸本轨的次级按钮 = 纸块胶囊 + 墨字（下载页编辑工具条 34:84 同一做法），
            // 主操作 = 朱砂胶囊 + 纸白字。深色轨的「深底 + 金字」在宣纸上没有对应物。
            Button { vm.selectAll() } label: {
                Text("全选")
                    .font(DWFont.cn(11, .medium))
                    .foregroundStyle(DWColor.paperInkSub)
                    .frame(width: 52, height: 32)
                    .background(Capsule().fill(DWColor.paperChipIdle))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(vm.selectableEpisodes.isEmpty)

            Button { vm.clearSelection() } label: {
                Text("清空")
                    .font(DWFont.cn(11, .medium))
                    .foregroundStyle(DWColor.paperInkSub)
                    .frame(width: 52, height: 32)
                    .background(Capsule().fill(DWColor.paperChipIdle))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(vm.selected.isEmpty)

            Button { vm.startDownload() } label: {
                Text("下载所选 (\(vm.selected.count))")
                    .font(DWFont.cn(11, .semibold))
                    .foregroundStyle(DWColor.paper)
                    .frame(height: 32)
                    .padding(.horizontal, 12)
                    .background(Capsule().fill(vm.selected.isEmpty
                                               ? DWColor.paperLineIdle
                                               : DWColor.paperCinnabar))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(vm.selected.isEmpty)

            Spacer(minLength: 0)
        }
        .frame(width: 350, height: DetailLayout.inlineToolbarHeight, alignment: .leading)
    }

    /// 单个集格子：底色 = 可播性、边缘环 = 下载进度、选中红底优先。
    /// 右下角小角标按设计稿 `.dl-play` / `.dl-todo`：已下载金色播放三角、未下载灰色下载箭头；
    /// 下载中让位给金色环 + n/100，当前选中集不叠加角标与环（同 `[aria-checked=true]` 规则）。
    private func episodeCellButton(_ ep: ApiDramaEpisode, multiSelect: Bool) -> some View {
        let isSelected = multiSelect ? vm.selected.contains(ep.id) : (vm.selectedSort == ep.sort)
        let isDownloaded = vm.downloadedSorts.contains(ep.sort)
        let phase = vm.downloadPhase(for: ep.sort)
        return Button {
            if multiSelect { vm.tapEpisode(ep) } else { vm.tapEpisodeDirect(ep) }
        } label: {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    Text("\(ep.sort)")
                    if case .active(let progress) = phase {
                        Text("\(Int(progress * 100))/100")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            // 选中格是朱砂底：数字必须转纸白，朱砂压朱砂就没了
                            .foregroundStyle(isSelected ? DWColor.paper : DWColor.paperCinnabar)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .font(DWFont.en(13, .medium))
                .frame(width: 50, height: 44, alignment: .center)

                if !isSelected {
                    episodeStatusBadge(phase: phase)
                        .designFrame(27, 23, 18, 18)
                }
            }
            .frame(width: 50, height: 44)
            .foregroundStyle(cellForeground(isSelected: isSelected,
                                            isDownloaded: isDownloaded,
                                            playable: ep.playable))
            .background(cellBackground(isSelected: isSelected,
                                       isDownloaded: isDownloaded,
                                       playable: ep.playable))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                if !isSelected { progressRing(phase) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(ep.sort) 集")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 设计稿右下角 18×18 状态角标（left 27 / top 23 相对 50×44 格子）。
    /// 纸本轨：已下载 = 墨实心三角（= 纸上已落定），待下载 = 最弱的灰箭头；
    /// downloading / queued / failed 不叠加。
    @ViewBuilder
    private func episodeStatusBadge(phase: EpisodeDownloadPhase) -> some View {
        switch phase {
        case .idle:
            VStack(spacing: 1) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .medium))
                Rectangle()
                    .frame(width: 10, height: 1)
            }
            .foregroundStyle(DWColor.paperFaint)
        case .done:
            Path { p in
                p.move(to: CGPoint(x: 3, y: 2))
                p.addLine(to: CGPoint(x: 10, y: 6))
                p.addLine(to: CGPoint(x: 3, y: 10))
                p.closeSubpath()
            }
            .fill(DWColor.paperInk)
            .frame(width: 12, height: 12)
        default:
            EmptyView()
        }
    }

    /// 剧集按钮边缘进度环。纸本轨一套三档：轨道用最淡的纸线、进度用墨
    /// （与下载页 `PaperProgressBar` 的 轨道 #C4C7C3 + 完成段 #35393B 同一套）；
    /// **红色只留给失败**——深色轨那套「金色代表一切进度」搬到纸面上会散成一片。
    /// 不旋转形状（50×44 非正方形，rotationEffect 会让它歪）。
    @ViewBuilder
    private func progressRing(_ phase: EpisodeDownloadPhase) -> some View {
        switch phase {
        case .idle:
            EmptyView()
        case .queued:
            RoundedRectangle(cornerRadius: 10)
                .stroke(DWColor.paperTrack.opacity(0.55), lineWidth: 2)
                .padding(1)
        case .active(let progress):
            RoundedRectangle(cornerRadius: 10)
                .trim(from: 0, to: progress)
                .stroke(DWColor.paperTrackFill, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(1)
        case .done:
            // 完成态用半档墨：2pt 实墨闭环在纸面上会和「选中」抢同一份重量，
            // 而已下载本来就有淡朱砂底 + 墨三角角标，闭环只需"看起来是合上的"。
            RoundedRectangle(cornerRadius: 10)
                .stroke(DWColor.paperInkSub, lineWidth: 1.5)
                .padding(1)
        case .failed:
            RoundedRectangle(cornerRadius: 10)
                .stroke(DWColor.paperCinnabar, lineWidth: 2)
                .padding(1)
        }
    }

    // MARK: ⑤ 为你推荐（设计稿 .reco 双列瀑布流）

    private func recommendationSection(layout: PageLayout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("为你推荐")
                    .font(DWFont.serif(15, .medium))
                    .foregroundStyle(DWColor.paperInk)
                Spacer()
                Text("\(vm.recommendations.count) 部 · 详情接口")
                    .font(DWFont.cn(10))
                    .foregroundStyle(DWColor.paperFaint)
            }
            .frame(height: DetailLayout.recoTitleBlock - 12, alignment: .topLeading)

            HStack(alignment: .top, spacing: DetailLayout.recoColumnGap) {
                recoColumn(layout.leftItems)
                recoColumn(layout.rightItems)
            }
            .frame(height: layout.recoGridHeight, alignment: .topLeading)
        }
        .padding(.horizontal, 20)
        .padding(.top, DetailLayout.recoTopPadding)
        .padding(.bottom, DetailLayout.recoBottomPadding)
        .frame(width: 390, height: layout.recoHeight, alignment: .topLeading)
        // 分节细线（纸本轨）：深色轨靠「黑底留白」分段，纸面必须有线才分得开。
        // 走 overlay 画在顶上，不占布局高度，推荐区高度预算不受影响。
        .overlay(alignment: .top) {
            DWColor.paperRule
                .frame(height: 0.5)
                .padding(.horizontal, 20)
        }
    }

    private func recoColumn(_ items: [RecoCardItem]) -> some View {
        VStack(alignment: .leading, spacing: DetailLayout.recoCardGap) {
            ForEach(items) { item in
                recoCard(item, coverHeight: DetailLayout.recoCoverHeights[item.index % 3])
            }
            Spacer(minLength: 0)
        }
        .frame(width: DetailLayout.recoColumnWidth, alignment: .topLeading)
    }

    private func recoCard(_ item: RecoCardItem, coverHeight: CGFloat) -> some View {
        Button { vm.openRecommendation(item.drama) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if let cover = item.drama.cover, let url = URL(string: cover) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                // scaledToFit（用户拍板 2026-11-13）：完整显示整张封面不裁切；
                                // 中/矮两档卡高比 3:4 矮，图片宽度收窄居中，两侧露出纸底
                                image.resizable().scaledToFit()
                                    .frame(width: DetailLayout.recoColumnWidth, height: coverHeight)
                            default:
                                recoCoverPlaceholder(title: item.drama.displayTitle,
                                                     height: coverHeight)
                            }
                        }
                    } else {
                        recoCoverPlaceholder(title: item.drama.displayTitle, height: coverHeight)
                    }
                    if let badge = item.drama.displayBadge {
                        Text(badge)
                            .font(DWFont.cn(10, .semibold))
                            .foregroundStyle(DWColor.paper)
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            // 角标压在图/纸块上，必须自己带底：墨底 + 纸白字
                            .background(DWColor.paperInk.opacity(0.82), in: Capsule())
                            .padding(8)
                    }
                }
                .frame(width: DetailLayout.recoColumnWidth, height: coverHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // 纸本轨封面收一圈 0.5 细边（下载页 PaperCover 同款），
                // 否则浅色封面直接化在宣纸里、找不到边界
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(DWColor.paperRule, lineWidth: 0.5)
                }

                Text(item.drama.displayTitle)
                    .font(DWFont.serif(13, .medium))
                    .foregroundStyle(DWColor.paperInk)
                    .lineLimit(2)
                    .frame(width: DetailLayout.recoColumnWidth, height: 36,
                           alignment: .topLeading)
                    .padding(.top, 8)

                Text(item.drama.tags.isEmpty ? "—" : item.drama.tags.joined(separator: " / "))
                    .font(DWFont.cn(10))
                    .foregroundStyle(DWColor.paperInkSub)
                    .lineLimit(1)
                    .frame(width: DetailLayout.recoColumnWidth, height: 15,
                           alignment: .leading)
                    .padding(.top, 4)

                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(DWColor.paperFaint)
                    Text(item.drama.displayPlayCount)
                        .font(DWFont.cn(10, .semibold))
                        .foregroundStyle(DWColor.paperCinnabar)
                    if let status = item.drama.serializeStatusText, !status.isEmpty {
                        Text("· \(status)")
                            .font(DWFont.cn(10))
                            .foregroundStyle(DWColor.paperFaint)
                    }
                }
                .frame(width: DetailLayout.recoColumnWidth, height: 15,
                       alignment: .leading)
                .padding(.top, 4)
            }
        }
        .buttonStyle(.plain)
        .frame(width: DetailLayout.recoColumnWidth,
               height: coverHeight + DetailLayout.recoTextHeight,
               alignment: .topLeading)
        .accessibilityLabel("推荐：\(item.drama.displayTitle)")
    }

    /// 推荐卡无封面兜底：纸块 + 首字（下载页 `PaperCover.fallback` 同一说法）。
    /// 深色轨这里原本是三色紫渐变，纸本轨没有紫色可用，也不该给一块死灰。
    private func recoCoverPlaceholder(title: String, height: CGFloat) -> some View {
        ZStack {
            DWColor.paperChipIdle
            Text(String(title.prefix(1)))
                .font(DWFont.serif(34))
                .tracking(2)
                .foregroundStyle(DWColor.paperLineIdle)
        }
        .frame(width: DetailLayout.recoColumnWidth, height: height)
    }

    // MARK: ⑥ 剧集档案（详情接口整包字段，尽量全展示）

    private func archiveSection(layout: PageLayout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("剧集档案")
                    .font(DWFont.serif(15, .medium))
                    .foregroundStyle(DWColor.paperInk)
                    .frame(height: 24, alignment: .leading)
                Text("详情接口原始字段 · 本地留存，离线可读")
                    .font(DWFont.cn(10))
                    .foregroundStyle(DWColor.paperFaint)
                    .frame(height: 16, alignment: .leading)
            }
            .frame(height: DetailLayout.archiveTitleBlock, alignment: .topLeading)

            ForEach(vm.archiveSections) { section in
                VStack(alignment: .leading, spacing: 0) {
                    // 分组名用朱砂：纸本轨里"标题/落款"都用这一档（设置页分组标同款）
                    Text(section.title)
                        .font(DWFont.cn(12, .bold))
                        .foregroundStyle(DWColor.paperCinnabar)
                        .frame(height: DetailLayout.archiveSectionTitle, alignment: .leading)
                    ForEach(section.rows) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(row.label)
                                .font(DWFont.cn(10))
                                .foregroundStyle(DWColor.paperFaint)
                                .lineLimit(1)
                                .frame(width: 108, alignment: .leading)
                            Text(row.value)
                                .font(DWFont.cn(10))
                                .foregroundStyle(DWColor.paperInk)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: DetailLayout.archiveRowHeight)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                // 纸本卡：比纸底深一档的纸块 + 0.5 细边（不是深色轨那种浮在黑上的实心块）
                .background(DWColor.paperCanvas, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(DWColor.paperRule, lineWidth: 0.5)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, DetailLayout.archiveTopPadding)
        .padding(.bottom, DetailLayout.archiveBottomPadding)
        .frame(width: 390, height: layout.archiveHeight, alignment: .topLeading)
    }

    // MARK: - 加载 / 错误态

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(DWColor.paperCinnabar)
            Text("正在获取剧集列表…")
                .font(DWFont.cn(13))
                .foregroundStyle(DWColor.paperInkSub)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(DWColor.paperCinnabar)
            Text(message)
                .font(DWFont.cn(13))
                .foregroundStyle(DWColor.paperInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            // 系统 borderedProminent 会有自己的强调色底，纸本轨用自己的胶囊（同下载页删除所选）
            Button {
                vm.reload()
            } label: {
                Text("重试")
                    .font(DWFont.cn(12, .medium))
                    .foregroundStyle(DWColor.paper)
                    .padding(.horizontal, 22)
                    .frame(height: 32)
                    .background(Capsule().fill(DWColor.paperCinnabar))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    // MARK: - 共用配色

    /// 主屏 12 格与内联展开集共用：底色表达「能不能播」，选中态朱砂底优先。
    /// 纸本轨三档纸色，不用深色轨的「实心块 + 红底」：
    ///   选中 = 朱砂（唯一的重色，等于把这一集"圈出来"）
    ///   已下载 = 极淡朱砂（存过 = 有印，但比选中轻）
    ///   可播 = 纸块；不可播 = 空
    private func cellBackground(isSelected: Bool, isDownloaded: Bool, playable: Bool) -> Color {
        if isSelected { return DWColor.paperCinnabar }
        if isDownloaded { return DWColor.paperCinnabar.opacity(0.10) }
        return playable ? DWColor.paperChipIdle : .clear
    }

    private func cellForeground(isSelected: Bool, isDownloaded: Bool, playable: Bool) -> Color {
        if isSelected { return DWColor.paper }
        if isDownloaded { return DWColor.paperCinnabar }
        return playable ? DWColor.paperInk : DWColor.paperFaint
    }
}

#if DEBUG
// MARK: - 纸本样张容器（仅模拟器截图用）

/// 样张专用开关。模拟器点不了、滑不了，纸本轨又必须"改一版、看一张"。
enum DramaDebugFlags {
    /// 启动即落到内容页底，用于查看档案区与「滚过海报后的顶栏」
    static var bottomAnchor: Bool {
        ProcessInfo.processInfo.arguments.contains("-dramaPreviewBottom")
    }
}

/// 启动参数 `-dramaPreview` 打开：注入固定样本后直接渲染剧集页。
/// 存在的理由——模拟器点不了、滑不了，纸本轨又必须"改一版、看一张"；
/// 没有这个入口就只能盲改。Release 不编译。
struct DramaPreviewHost: View {
    @StateObject private var vm: DramaPageViewModel

    init(manager: DownloadManager) {
        let vm = DramaPageViewModel(target: DramaTarget(site: "https://preview.local", dramaID: "9001"),
                                    manager: manager)
        vm.injectPreviewData()
        _vm = StateObject(wrappedValue: vm)
    }

    var body: some View {
        NavigationStack { DramaDetailView(vm: vm) }
    }
}
#endif
