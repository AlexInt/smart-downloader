import SwiftUI

// MARK: - 剧集详情页（DramaWave · 390×840 设计稿）
//
// 设计源：drama-detail.html「剧集详情页三态对照原型」。屏内固定 390×840 坐标，
// 逐节点用 designFrame 落位；颜色/字体/画幅复用 player/DesignTokens.swift（同一套设计系统）。
// 三态：desc-collapsed（简介两行）/ desc-expanded（内容组 +54pt）/ cover-failed（占位 + 重试）。
// 本文件只渲染 + 转发用户意图；业务状态与编排在 DramaPageViewModel（AGENTS.md MVVM 约定）。

struct DramaDetailView: View {
    @ObservedObject var vm: DramaPageViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 左缘右滑返回的跟手位移（系统 pop 手势在导航栏隐藏时失效，这里自己补）
    @State private var edgeDragWidth: CGFloat = 0

    /// 简介展开位移：设计稿 --desc-shift，唯一驱动「简介容器高度」与「内容组 translateY」
    private var descShift: CGFloat { vm.isDescriptionExpanded ? 54 : 0 }
    /// 设计稿 .32s cubic-bezier(.2,.8,.2,1)；reduced-motion 时全动效归零
    private var motion: Animation? {
        reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)
    }

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / DWLayout.designWidth,
                            geo.size.height / DWLayout.designHeight)
            ZStack {
                if vm.loading {
                    loadingState
                } else if let error = vm.loadError {
                    errorState(error)
                } else if let info = vm.info {
                    canvas(info)
                        .frame(width: DWLayout.designWidth, height: DWLayout.designHeight)
                        .scaleEffect(scale)
                        .frame(width: geo.size.width, height: geo.size.height)
                        // 左缘右滑时整屏跟手，露出左侧底层，模拟系统返回观感
                        .offset(x: edgeDragWidth)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .background(DWColor.background.ignoresSafeArea())
        // 设计稿是沉浸式全屏，状态栏之上不叠系统导航栏；返回用屏内自带按钮
        .toolbar(.hidden, for: .navigationBar)
        // TabView 的悬浮 tab bar 会压住 y772 的 CTA，进详情页必须隐藏
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $vm.showAllEpisodes) { allEpisodesSheet }
        .gesture(edgeBackGesture)
    }

    /// 只在屏幕左缘 30pt 内起手、向右拖才生效；抬手过阈值触发 dismiss，否则弹回。
    /// 挂在最外层而非卡片内，避免与格子 Button / 展开按钮抢连续手势（SwiftUI 深度优先，Button 仍优先）。
    private var edgeBackGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard value.startLocation.x <= 30, value.translation.width > 0 else { return }
                edgeDragWidth = min(value.translation.width, 160)
            }
            .onEnded { value in
                guard value.startLocation.x <= 30 else {
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

    // MARK: - 屏内画布

    /// 层序与设计稿一致：海报 → 光晕/scrim → 占位 → 文字 → 内容组 → 固定底栏 → toast
    @ViewBuilder
    private func canvas(_ info: DramaInfo) -> some View {
        ZStack(alignment: .topLeading) {
            DWColor.background
                .frame(width: DWLayout.designWidth, height: DWLayout.designHeight)
            coverLayer
            headerBar
            titleAndTags(info)
            descriptionBlock
            contentGroup(info)
            footerBar
            ToastView(message: vm.toastText)
                .designFrame(95, 690, 200, 40)
                .allowsHitTesting(false)
        }
        .frame(width: DWLayout.designWidth, height: DWLayout.designHeight)
    }

    // MARK: ① 海报层

    /// 设计稿海报高 470，用户要求降低 20% → 376。海报内的光晕 / scrim / 占位一并等比缩放（×0.8），
    /// 文字层（标题 310 / 标签 352 / 简介 386 / 选集 490）坐标保持不动，不牵动整页布局。
    private enum DetailLayout {
        static let posterHeight: CGFloat = 376
    }

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
                        case .failure:
                            DWColor.coverPlaceholder
                        case .empty:
                            DWColor.coverPlaceholder
                        @unknown default:
                            DWColor.coverPlaceholder
                        }
                        switch phase {
                        case .success:
                            glowLayer
                        default:
                            EmptyView()
                        }
                        scrimTop
                        scrimBottom
                        switch phase {
                        case .empty:
                            loadingPlaceholder
                        case .failure:
                            failurePlaceholder
                        case .success:
                            EmptyView()
                        @unknown default:
                            EmptyView()
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

    /// 加载中占位：spinner + 「正在加载封面…」（y 随海报 ×0.8）
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

    /// 失败占位：破图图标 + 文案 + 点击重试（y 随海报 ×0.8，命中区仍 90×44）
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
                .frame(width: 350, height: height, alignment: .topLeading)
                .clipped()
                .designFrame(20, 386, 350, height, alignment: .topLeading)
                .animation(motion, value: vm.isDescriptionExpanded)

            if !vm.isDescriptionExpanded {
                // 折叠态：右端渐隐遮罩 + 「… 展开」，命中区 44 高
                LinearGradient(colors: [.clear, DWColor.background.opacity(0.95)],
                               startPoint: .leading, endPoint: .trailing)
                    .designFrame(262, 404, 108, 18)
                    .allowsHitTesting(false)
                Button { vm.toggleDescription() } label: {
                    HStack(spacing: 2) {
                        Text("… 展开")
                        Image(systemName: "chevron.down")
                    }
                    .font(DWFont.cn(12, .medium))
                    .foregroundStyle(DWColor.gold)
                    .frame(width: 72, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .designFrame(280, 391, 72, 44)
            } else {
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
        }
        .frame(width: 390, height: 840)
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
                .designFrame(96, 494, 100, 18, alignment: .leading)

            Button { vm.showAllEpisodes = true } label: {
                Text("查看全部 ›")
                    .font(DWFont.cn(12, .medium))
                    .foregroundStyle(DWColor.gold)
                    .frame(width: 90, height: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(280, 481, 90, 44)

            episodeGrid(info)

            Text(vm.hintText)
                .font(DWFont.cn(12))
                .foregroundStyle(DWColor.textHint)
                .lineLimit(1)
                .designFrame(20, 650, 350, 18, alignment: .leading)
        }
        .frame(width: 390, height: 840)
        .offset(y: descShift)
        .animation(motion, value: vm.isDescriptionExpanded)
    }

    /// 设计稿 6×2 共 12 格；点格子只单选（radio），播放/下载统一交给底部 CTA。
    /// **底色表达「能不能播」**：已下载淡绿、待下载中性深色、锁定灰 —— 与「查看全部」面板
    /// 共用 cellBackground/cellForeground，两处一眼可分的配色一致；边缘环只负责下载进度。
    private func episodeGrid(_ info: DramaInfo) -> some View {
        let episodes = Array(info.episodes.prefix(12))
        return ForEach(Array(episodes.enumerated()), id: \.element.id) { index, ep in
            let col = CGFloat(index % 6)
            let row = CGFloat(index / 6)
            let isSelected = vm.selectedSort == ep.sort
            let isDownloaded = vm.downloadedSorts.contains(ep.sort)
            let phase = vm.downloadPhase(for: ep.sort)
            Button { vm.select(sort: ep.sort) } label: {
                HStack(spacing: 2) {
                    Text("\(ep.sort)")
                    if case .done = phase {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isSelected ? Color.white : Color.green)
                    }
                }
                .font(DWFont.en(13, .medium))
                .foregroundStyle(cellForeground(isSelected: isSelected,
                                                isDownloaded: isDownloaded,
                                                playable: ep.playable))
                .frame(width: 50, height: 44)
                .background(cellBackground(isSelected: isSelected,
                                           isDownloaded: isDownloaded,
                                           playable: ep.playable))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay { progressRing(phase, onSelected: isSelected) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .designFrame(20 + col * 60, 530 + row * 56, 50, 44)
            .accessibilityLabel("第 \(ep.sort) 集")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }

    /// 剧集按钮边缘进度环：下载中按进度 trim 逐渐闭环，完成后完整闭环 + 内部打勾，
    /// 排队是淡色轨道、失败是红环、未下载无边。
    /// 不旋转形状（50×44 非正方形，rotationEffect 会让它歪），trim 起点在右上角顺时针闭合。
    /// 选中态是红底，绿环/红环撞色看不清，这两态改白色环，进度金色环两种底色都清楚。
    @ViewBuilder
    private func progressRing(_ phase: EpisodeDownloadPhase, onSelected: Bool) -> some View {
        switch phase {
        case .idle:
            EmptyView()
        case .queued:
            RoundedRectangle(cornerRadius: 10)
                .stroke(DWColor.gold.opacity(0.35), lineWidth: 2)
                .padding(1)
        case .active(let progress):
            RoundedRectangle(cornerRadius: 10)
                .trim(from: 0, to: progress)
                .stroke(DWColor.gold, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(1)
        case .done:
            RoundedRectangle(cornerRadius: 10)
                .stroke(onSelected ? Color.white : Color.green, lineWidth: 2)
                .padding(1)
        case .failed:
            RoundedRectangle(cornerRadius: 10)
                .stroke(onSelected ? Color.white : DWColor.primary, lineWidth: 2)
                .padding(1)
        }
    }

    // MARK: ⑤ 固定底栏（分隔线 y758 / CTA y772，恒不位移）

    private var footerBar: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(DWColor.divider)
                .designFrame(0, 758, 390, 1)
                .allowsHitTesting(false)

            Button { vm.playSelected() } label: {
                ZStack {
                    LinearGradient(colors: [DWColor.primary, DWColor.ctaEnd],
                                   startPoint: .leading, endPoint: .trailing)
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text(vm.ctaTitle)
                            .font(DWFont.cn(16, .bold))
                    }
                    .foregroundStyle(.white)
                }
                .frame(width: 350, height: 52)
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .designFrame(20, 772, 350, 52)
            .accessibilityLabel(vm.ctaTitle)
        }
        .frame(width: 390, height: 840)
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

    // MARK: - 查看全部：保留全量选集 + 多选下载 + 刷新

    /// 设计稿主屏只放 12 格；下载能力（全选/清空/下载所选/刷新）收进这个面板，
    /// 行为与旧版剧集页完全一致，避免「换皮」把下载器入口弄丢。
    private var allEpisodesSheet: some View {
        NavigationStack {
            ScrollView {
                if let info = vm.info {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                        ForEach(info.episodes) { ep in episodeCell(ep) }
                    }
                    .padding()
                }
            }
            .background(DWColor.background.ignoresSafeArea())
            .navigationTitle("选集 · \(vm.episodeCountText)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { vm.showAllEpisodes = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await vm.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("全选") { vm.selectAll() }
                        .buttonStyle(.bordered)
                        .disabled(vm.selectableEpisodes.isEmpty)
                    Button("清空") { vm.clearSelection() }
                        .buttonStyle(.bordered)
                        .disabled(vm.selected.isEmpty)
                    Button { vm.startDownload() } label: {
                        Label("下载所选 (\(vm.selected.count))", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DWColor.primary)
                    .disabled(vm.selected.isEmpty)
                }
                .padding()
                .background(.bar)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// 全量面板的集格子：与主屏同一套下载阶段（边缘进度环 / 完成打勾）
    private func episodeCell(_ ep: ApiDramaEpisode) -> some View {
        let isSelected = vm.selected.contains(ep.id)
        let isDownloaded = vm.downloadedSorts.contains(ep.sort)
        let isQueued = vm.queuedSorts.contains(ep.sort)
        let phase = vm.downloadPhase(for: ep.sort)
        return Button { vm.tapEpisode(ep) } label: {
            Group {
                if case .done = phase {
                    Label("第\(ep.sort)集", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                } else if isQueued {
                    Label("第\(ep.sort)集", systemImage: "arrow.down.circle")
                        .labelStyle(.titleAndIcon)
                } else {
                    Text("第\(ep.sort)集")
                }
            }
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isQueued
                ? Color(uiColor: .systemGray6)
                : cellBackground(isSelected: isSelected, isDownloaded: isDownloaded, playable: ep.playable))
            .foregroundStyle(isQueued
                ? Color(uiColor: .tertiaryLabel)
                : cellForeground(isSelected: isSelected, isDownloaded: isDownloaded, playable: ep.playable))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { progressRing(phase, onSelected: isSelected) }
        }
        .buttonStyle(.plain)
        .disabled(!ep.playable || isQueued)
    }

    /// 主屏 12 格与「查看全部」面板共用：底色表达「能不能播」，选中态红底优先。
    /// 已下载淡绿 / 待下载中性深色 / 锁定灰 —— 两处配色必须一致，别各写一套。
    private func cellBackground(isSelected: Bool, isDownloaded: Bool, playable: Bool) -> Color {
        if isSelected { return DWColor.primary }
        if isDownloaded { return Color.green.opacity(0.18) }
        return playable ? DWColor.surface : Color(uiColor: .systemGray6)
    }

    private func cellForeground(isSelected: Bool, isDownloaded: Bool, playable: Bool) -> Color {
        if isSelected { return .white }
        if isDownloaded { return .white }
        return playable ? .white : DWColor.textHint
    }
}
