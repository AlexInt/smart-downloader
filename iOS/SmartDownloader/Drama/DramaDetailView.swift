import SwiftUI

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
    /// 截断态前缀：使「前缀 + … 展开」≤2 行且预留 2 字符漂移余量（用户拍板 2026-11-14）——nil = 不溢出
    @State private var collapsedIntro: String?

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
        .background(DWColor.background.ignoresSafeArea())
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
    @ViewBuilder
    private func canvas(_ info: DramaInfo, layout: PageLayout) -> some View {
        ZStack(alignment: .topLeading) {
            DWColor.background
                .frame(width: DWLayout.designWidth, height: layout.totalHeight)
            coverLayer
            headerBar
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

    private var posterGradient: some View {
        LinearGradient(stops: [
            .init(color: DWColor.posterTop, location: 0),
            .init(color: DWColor.posterMid, location: 0.45),
            .init(color: DWColor.posterBottom, location: 1)
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
                            DWColor.coverPlaceholder
                        @unknown default:
                            DWColor.coverPlaceholder
                        }
                        if case .success = phase { glowLayer }
                        scrimTop
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
                    DWColor.coverPlaceholder
                    scrimTop
                    scrimBottom
                    failurePlaceholder
                }
                .frame(width: 390, height: DetailLayout.posterHeight)
            }
        }
        .designFrame(0, 0, 390, DetailLayout.posterHeight)
        .clipped()
    }

    private var glowLayer: some View {
        RadialGradient(stops: [
            .init(color: DWColor.glowCenter.opacity(0.18), location: 0),
            .init(color: Color.clear, location: 1)
        ], center: .center, startRadius: 0, endRadius: 120)
            .designFrame(60, 56, 270, 240)
            .allowsHitTesting(false)
    }

    private var scrimTop: some View {
        LinearGradient(colors: [.black.opacity(0.45), .clear],
                       startPoint: .top, endPoint: .bottom)
            .designFrame(0, 0, 390, 96)
            .allowsHitTesting(false)
    }

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
                .tint(DWColor.gold)
                .designFrame(171, 134, 48, 48)
            Text("正在加载封面…")
                .font(DWFont.cn(13, .medium))
                .foregroundStyle(DWColor.textHint)
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
                .foregroundStyle(DWColor.placeholderIcon)
                .designFrame(171, 134, 48, 48)
            Text("封面加载失败")
                .font(DWFont.cn(13, .medium))
                .foregroundStyle(DWColor.textHint)
                .designFrame(156, 190, 78, 18)
            Button { vm.retryCover() } label: {
                Text("点击重试")
                    .font(DWFont.cn(12, .medium))
                    .foregroundStyle(DWColor.textMuted)
                    .frame(width: 90, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(150, 208, 90, 44)
            .accessibilityLabel("点击重试加载封面")
        }
        .frame(width: 390, height: DetailLayout.posterHeight)
    }

    // MARK: ② 顶栏

    /// 视觉盒 32×32 @ (16,50)/(334,50)，命中区外扩到 44×44（设计稿 ::after 规则）
    private var headerBar: some View {
        ZStack(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(10, 44, 44, 44)
            .accessibilityLabel("返回")

            Button { vm.toggleFavorite() } label: {
                Image(systemName: vm.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(328, 44, 44, 44)
            .accessibilityLabel(vm.isFavorite ? "取消收藏" : "收藏")
        }
        .frame(width: 390, height: 840)
    }

    // MARK: ③ 标题 / 标签 / 简介（不随展开位移）

    private func titleAndTags(_ info: DramaInfo) -> some View {
        ZStack(alignment: .topLeading) {
            Text(info.name)
                .font(DWFont.cn(24, .heavy))
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
            let height = 36 + descShift
            Text(vm.intro ?? "")
                .font(DWFont.cn(13))
                .lineSpacing(5)
                .foregroundStyle(DWColor.textBody)
                .lineLimit(vm.isDescriptionExpanded ? nil : 2)
                // 截断态且已算出内联尾部时隐藏底本，避免与上层前缀文本叠影
                .opacity(vm.isDescriptionExpanded || collapsedIntro == nil ? 1 : 0)
                .frame(width: 350, height: height, alignment: .topLeading)
                .clipped()
                .designFrame(20, 386, 350, height, alignment: .topLeading)
                .animation(motion, value: vm.isDescriptionExpanded)

            if vm.isDescriptionExpanded {
                if introOverflow {
                    Button { vm.toggleDescription() } label: {
                        HStack(spacing: 2) {
                            Text("收起")
                            Image(systemName: "chevron.up")
                        }
                        .font(DWFont.cn(12, .medium))
                        .foregroundStyle(DWColor.gold)
                        .frame(width: 68, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .designFrame(296, 471, 68, 44)
                }
            } else if let prefix = collapsedIntro {
                // 截断态（用户拍板 2026-11-14）：第二行被文字填满，行尾「… 展开」为文字流收尾——
                // 省略号紧贴最后一个可见字（前缀二分截断 + 2 字符漂移余量），无渐隐遮罩、无箭头图标；
                // lineLimit(2)+clipped 兑底：估算与渲染有分毫偏差时最多省略号位置微移，不破版
                collapsedIntroText(prefix)
                    .font(DWFont.cn(13))
                    .lineSpacing(5)
                    .lineLimit(2)
                    .frame(width: 350, height: height, alignment: .topLeading)
                    .clipped()
                    .designFrame(20, 386, 350, height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { vm.toggleDescription() }
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

    /// 截断态渲染：前缀（正文色）+「… 展开」（金色）同段内联，尾部即第二行行尾
    private func collapsedIntroText(_ prefix: String) -> Text {
        let tail = "… 展开"
        var attr = AttributedString(prefix + tail)
        attr.foregroundColor = DWColor.textBody
        if let range = attr.range(of: tail), range.upperBound == attr.endIndex {
            attr[range].foregroundColor = DWColor.gold
        }
        return Text(attr)
    }

    /// 简介两行溢出测量（View 层职责：渲染度量不走 VM）：与实际渲染同参数
    ///（宽 350 / 字号 13 / 行距 5），高度超过两行（含行距）即溢出。
    /// 字体对齐 DWFont.cn 的默认映射（.system → UIFont.systemFont）
    private func measureIntroOverflow(_ text: String) {
        let uiFont = UIFont.systemFont(ofSize: 13)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: uiFont, .paragraphStyle: style],
            context: nil)
        let twoLineHeight = uiFont.lineHeight * 2 + 5 + 1   // 两行行高 + 行距 + 容差
        introOverflow = bounds.height > twoLineHeight
        if introOverflow {
            collapsedIntro = Self.truncatedIntroPrefix(text, tail: "… 展开", width: 350,
                                                       font: uiFont, paragraphStyle: style)
        } else {
            collapsedIntro = nil
        }
        print("PLAYER_DBG [Entry] introOverflow=\(introOverflow) h=\(Int(bounds.height)) twoLine=\(Int(twoLineHeight)) collapsedLen=\(collapsedIntro.map { $0.count } ?? 0) len=\(text.count)")
    }

    /// 二分最大前缀 L：lines(prefix(L) + tail) ≤ 2（行数按 boundingRect 高度/行步进估算），
    /// 结果回退 2 字符作渲染漂移安全余量——尾部距行尾最多差两个字宽，仍读作「第二行行尾」
    private static func truncatedIntroPrefix(_ text: String, tail: String, width: CGFloat,
                                             font: UIFont, paragraphStyle: NSParagraphStyle) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraphStyle]
        func lines(_ s: String) -> Int {
            let b = (s as NSString).boundingRect(
                with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs, context: nil)
            return max(1, Int((b.height + 2) / (font.lineHeight + 5)) + 1)
        }
        guard lines(text + tail) > 2 else { return text }
        var lo = 0, hi = text.count, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            let idx = text.index(text.startIndex, offsetBy: mid, limitedBy: text.endIndex) ?? text.endIndex
            if lines(String(text[..<idx]) + tail) <= 2 { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return String(text.prefix(max(0, best - 2)))
    }

    // MARK: ④ 内容组（唯一位移 translateY(--desc-shift)）

    private func contentGroup(_ info: DramaInfo) -> some View {
        ZStack(alignment: .topLeading) {
            Text("选集")
                .font(DWFont.cn(16, .bold))
                .foregroundStyle(.white)
                .designFrame(20, 490, 64, 24, alignment: .leading)

            Text(vm.episodeCountText)
                .font(DWFont.cn(12))
                .foregroundStyle(DWColor.textHint)
                .designFrame(96, 494, 76, 18, alignment: .leading)

            // 设计稿「下载全部」：一次把所有可下且未入队的集交给现有调度
            Button { vm.downloadAll() } label: {
                Text("下载全部")
                    .font(DWFont.cn(12, .medium))
                    .foregroundStyle(DWColor.gold)
                    .frame(width: 64, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(176, 481, 64, 44)

            // 原「查看全部」sheet 里的刷新能力：sheet 移除后由选集行这个 ↻ 承接
            Button { vm.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DWColor.gold)
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
                    .foregroundStyle(vm.hasExtraEpisodes ? DWColor.gold : DWColor.textHint)
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
                .foregroundStyle(DWColor.textHint)
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
            Button { vm.selectAll() } label: {
                Text("全选")
                    .font(DWFont.cn(11, .medium))
                    .frame(width: 52, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DWColor.gold)
            .background(DWColor.surface, in: RoundedRectangle(cornerRadius: 8))
            .disabled(vm.selectableEpisodes.isEmpty)

            Button { vm.clearSelection() } label: {
                Text("清空")
                    .font(DWFont.cn(11, .medium))
                    .frame(width: 52, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DWColor.gold)
            .background(DWColor.surface, in: RoundedRectangle(cornerRadius: 8))
            .disabled(vm.selected.isEmpty)

            Button { vm.startDownload() } label: {
                Text("下载所选 (\(vm.selected.count))")
                    .font(DWFont.cn(11, .semibold))
                    .frame(height: 36)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(DWColor.primary, in: RoundedRectangle(cornerRadius: 8))
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
                            .foregroundStyle(DWColor.gold)
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
    /// ready = 金色实心三角，todo = 灰色向下箭头 + 底线；downloading / queued / failed 不叠加。
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
            .foregroundStyle(DWColor.textHint)
        case .done:
            Path { p in
                p.move(to: CGPoint(x: 3, y: 2))
                p.addLine(to: CGPoint(x: 10, y: 6))
                p.addLine(to: CGPoint(x: 3, y: 10))
                p.closeSubpath()
            }
            .fill(DWColor.gold)
            .frame(width: 12, height: 12)
        default:
            EmptyView()
        }
    }

    /// 剧集按钮边缘进度环：设计稿 `.ring-fg` 色 `#F5C451` 金色（2026-11-12 由绿色改回金色）。
    /// 排队淡金轨道 → 下载中金色逐渐闭环 → 完成金色闭环；失败仍是红环。
    /// 与右下角状态角标、n/100 分数同用一套金色，不再有绿色元素。
    /// 不旋转形状（50×44 非正方形，rotationEffect 会让它歪）。
    @ViewBuilder
    private func progressRing(_ phase: EpisodeDownloadPhase) -> some View {
        switch phase {
        case .idle:
            EmptyView()
        case .queued:
            RoundedRectangle(cornerRadius: 10)
                .stroke(DWColor.gold.opacity(0.30), lineWidth: 2)
                .padding(1)
        case .active(let progress):
            RoundedRectangle(cornerRadius: 10)
                .trim(from: 0, to: progress)
                .stroke(DWColor.gold, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(1)
        case .done:
            RoundedRectangle(cornerRadius: 10)
                .stroke(DWColor.gold, lineWidth: 2)
                .padding(1)
        case .failed:
            RoundedRectangle(cornerRadius: 10)
                .stroke(DWColor.primary, lineWidth: 2)
                .padding(1)
        }
    }

    // MARK: ⑤ 为你推荐（设计稿 .reco 双列瀑布流）

    private func recommendationSection(layout: PageLayout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("为你推荐")
                    .font(DWFont.cn(15, .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(vm.recommendations.count) 部 · 详情接口")
                    .font(DWFont.cn(10))
                    .foregroundStyle(DWColor.textHint)
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
                                // 中/矮两档卡高比 3:4 矮，图片宽度收窄居中，两侧露出深色背景
                                image.resizable().scaledToFit()
                                    .frame(width: DetailLayout.recoColumnWidth, height: coverHeight)
                            default:
                                recoCoverPlaceholder(height: coverHeight)
                            }
                        }
                    } else {
                        recoCoverPlaceholder(height: coverHeight)
                    }
                    if let badge = item.drama.displayBadge {
                        Text(badge)
                            .font(DWFont.cn(10, .semibold))
                            .foregroundStyle(DWColor.gold)
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(Color.black.opacity(0.72), in: Capsule())
                            .padding(8)
                    }
                }
                .frame(width: DetailLayout.recoColumnWidth, height: coverHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Text(item.drama.displayTitle)
                    .font(DWFont.cn(13, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(width: DetailLayout.recoColumnWidth, height: 36,
                           alignment: .topLeading)
                    .padding(.top, 8)

                Text(item.drama.tags.isEmpty ? "—" : item.drama.tags.joined(separator: " / "))
                    .font(DWFont.cn(10))
                    .foregroundStyle(DWColor.textHint)
                    .lineLimit(1)
                    .frame(width: DetailLayout.recoColumnWidth, height: 15,
                           alignment: .leading)
                    .padding(.top, 4)

                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(DWColor.textHint)
                    Text(item.drama.displayPlayCount)
                        .font(DWFont.cn(10, .semibold))
                        .foregroundStyle(DWColor.gold)
                    if let status = item.drama.serializeStatusText, !status.isEmpty {
                        Text("· \(status)")
                            .font(DWFont.cn(10))
                            .foregroundStyle(DWColor.textHint)
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

    private func recoCoverPlaceholder(height: CGFloat) -> some View {
        LinearGradient(colors: [Color(hex: "#3A1A4E"), Color(hex: "#5A2148"), Color(hex: "#16101E")],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .frame(width: DetailLayout.recoColumnWidth, height: height)
    }

    // MARK: ⑥ 剧集档案（详情接口整包字段，尽量全展示）

    private func archiveSection(layout: PageLayout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("剧集档案")
                    .font(DWFont.cn(15, .bold))
                    .foregroundStyle(.white)
                    .frame(height: 24, alignment: .leading)
                Text("详情接口原始字段 · 本地留存，离线可读")
                    .font(DWFont.cn(10))
                    .foregroundStyle(DWColor.textHint)
                    .frame(height: 16, alignment: .leading)
            }
            .frame(height: DetailLayout.archiveTitleBlock, alignment: .topLeading)

            ForEach(vm.archiveSections) { section in
                VStack(alignment: .leading, spacing: 0) {
                    Text(section.title)
                        .font(DWFont.cn(12, .bold))
                        .foregroundStyle(DWColor.gold)
                        .frame(height: DetailLayout.archiveSectionTitle, alignment: .leading)
                    ForEach(section.rows) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(row.label)
                                .font(DWFont.cn(10))
                                .foregroundStyle(DWColor.textHint)
                                .lineLimit(1)
                                .frame(width: 108, alignment: .leading)
                            Text(row.value)
                                .font(DWFont.cn(10))
                                .foregroundStyle(DWColor.textBody)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: DetailLayout.archiveRowHeight)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(DWColor.surface, in: RoundedRectangle(cornerRadius: 10))
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
            ProgressView().tint(DWColor.gold)
            Text("正在获取剧集列表…")
                .font(DWFont.cn(13))
                .foregroundStyle(DWColor.textHint)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(DWColor.gold)
            Text(message)
                .font(DWFont.cn(13))
                .foregroundStyle(DWColor.textBody)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("重试") { vm.reload() }
                .buttonStyle(.borderedProminent)
                .tint(DWColor.primary)
        }
    }

    // MARK: - 共用配色

    /// 主屏 12 格与内联展开集共用：底色表达「能不能播」，选中态红底优先。
    /// 原「查看全部」sheet 已按设计稿改为内联展开，全选/清空/下载所选在
    /// `inlineBatchToolbar`，刷新在选集行 ↻，两条能力都保留。
    private func cellBackground(isSelected: Bool, isDownloaded: Bool, playable: Bool) -> Color {
        if isSelected { return DWColor.primary }
        // 已下载淡金底：与金色进度环/角标同色系，但仍与「待下载」中性深色可区分
        if isDownloaded { return DWColor.gold.opacity(0.16) }
        return playable ? DWColor.surface : Color(uiColor: .systemGray6)
    }

    private func cellForeground(isSelected: Bool, isDownloaded: Bool, playable: Bool) -> Color {
        if isSelected { return .white }
        if isDownloaded { return .white }
        return playable ? .white : DWColor.textHint
    }
}
