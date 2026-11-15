import SwiftUI

// MARK: - 选集面板（竖屏）
//
// 画布给了完整版「选集面板 · 上墨下纸」（19:62，上半剧照 352 + 下半纸本弹层 492，
// 含拖拽把手 / 剧集信息行 / 内容 tab / 集数分段 / 集数网格）。本轮按用户拍板先做简单版：
// 照横屏 22:78 的网格样式改成竖屏底部弹层，只保留「标题行 + 集数网格」，
// 网格与当前集样式严格对齐画布 22:91 / 22:98（4 列 46×46 gap 9、当前集朱砂描边 + 播放小点）。
//
// 后续做完整版时只需替换本文件的容器部分，网格可原样复用。

/// 选集网格度量（画布 22:78 / 22:92 / 22:98，2026-11-15 按用户要求改为「一行排满」）
enum EpisodeGridMetrics {
    /// 格间（画布 gap 9）
    static let gap: CGFloat = 9
    /// 格圆角（画布 9）
    static let cellRadius: CGFloat = 9
    /// 列数：画布横屏抽屉是 4 列 46 宽（面板只有 300 宽），竖屏弹层是整屏宽——
    /// 沿用 4 列会把整片网格缩在左边、右侧空 150pt（用户实报「全部靠左排布不对」），
    /// 故按竖屏宽度提到 6 列，密度与剧集页选集网格（6 列 × 56）一致
    static let columns = 6
    /// 面板左右内边距（与 EpisodePanel 的 padding 同源）
    static let horizontalPadding: CGFloat = 18
    /// 每格边长：按可用宽度等分，使一行正好排满（不写死 46）
    static func cell(availableWidth: CGFloat) -> CGFloat {
        max(46, (availableWidth - gap * CGFloat(columns - 1)) / CGFloat(columns))
    }
    /// 当前集播放小点（画布 4×4 r2，gap 3）
    static let dot: CGFloat = 4
}

struct EpisodeGrid: View {
    /// 面板格子：集号是队列里的真实集号（不按 1…total 编号）
    let items: [EpisodePanelItem]
    let current: Int
    /// 网格可用宽度（由容器现量后传入：整屏宽 − 左右内边距）
    var availableWidth: CGFloat
    var onSelect: (Int) -> Void

    private var side: CGFloat {
        EpisodeGridMetrics.cell(availableWidth: availableWidth)
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(side),
                                               spacing: EpisodeGridMetrics.gap),
                           count: EpisodeGridMetrics.columns),
            alignment: .leading,
            spacing: EpisodeGridMetrics.gap
        ) {
            ForEach(items) { item in
                cell(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ item: EpisodePanelItem) -> some View {
        let isCurrent = item.sort == current
        let numberColor: Color = {
            if isCurrent { return DWColor.overlayCinnabar }
            if item.isDownloaded { return DWColor.overlayInk }
            return item.playable ? DWColor.overlayInkSub : DWColor.overlayInkSub.opacity(0.45)
        }()
        return Button {
            onSelect(item.sort)
        } label: {
            ZStack {
                HStack(spacing: isCurrent ? 3 : 0) {
                    Text("\(item.sort)")
                        .font(isCurrent ? DWFont.en(14, .medium) : DWFont.en(14, .regular))
                        .foregroundStyle(numberColor)
                    if isCurrent {
                        Circle()
                            .fill(DWColor.overlayCinnabar)
                            .frame(width: EpisodeGridMetrics.dot, height: EpisodeGridMetrics.dot)
                    }
                }
                // 未下载且可下载：右下角小下箭头（对应剧集页 `.dl-todo` 的「点我可下」语义）。
                // 注意顺序：先给图元自身 padding，再按格子尺寸做 bottomTrailing 对齐——
                // 反过来（先对齐再 padding）会让整块放大 8pt 溢出格子、箭头被裁在边缘外
                if !item.isDownloaded && item.playable {
                    EpisodeTodoGlyph()
                        .stroke(DWColor.overlayInkSub,
                                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                        .frame(width: 7, height: 8)
                        .padding(4)
                        .frame(width: side, height: side, alignment: .bottomTrailing)
                }
            }
            .frame(width: side, height: side)
            .background(isCurrent ? DWColor.episodeCellCurrent : DWColor.episodeCell,
                        in: RoundedRectangle(cornerRadius: EpisodeGridMetrics.cellRadius))
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: EpisodeGridMetrics.cellRadius)
                        .strokeBorder(DWColor.episodeCellStroke, lineWidth: 1)
                }
            }
            .overlay {
                progressRing(item.phase)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(item))
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    /// 下载进度环（深色轨）：排队淡环 / 下载中朱砂弧 / 失败朱砂整环。
    /// 已下载与未开始不画（已下载靠数字恢复墨白、未下载靠下箭头）。
    @ViewBuilder
    private func progressRing(_ phase: EpisodeDownloadPhase) -> some View {
        switch phase {
        case .idle, .done:
            EmptyView()
        case .queued:
            RoundedRectangle(cornerRadius: EpisodeGridMetrics.cellRadius)
                .stroke(DWColor.overlayInkSub.opacity(0.32), lineWidth: 2)
                .padding(1)
        case .active(let progress):
            RoundedRectangle(cornerRadius: EpisodeGridMetrics.cellRadius)
                .trim(from: 0, to: progress)
                .stroke(DWColor.overlayCinnabar,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(1)
        case .failed:
            RoundedRectangle(cornerRadius: EpisodeGridMetrics.cellRadius)
                .stroke(DWColor.overlayCinnabar, lineWidth: 2)
                .padding(1)
        }
    }

    private func accessibilityLabel(_ item: EpisodePanelItem) -> String {
        switch item.phase {
        case .done: return "第 \(item.sort) 集，已下载"
        case .queued, .active: return "第 \(item.sort) 集，正在下载"
        case .failed: return "第 \(item.sort) 集，下载失败"
        case .idle: return item.playable ? "第 \(item.sort) 集，未下载" : "第 \(item.sort) 集，站点未开放"
        }
    }
}

/// 未下载格右下角的小下箭头（描边形；尺寸按画布 1pt 线稿口径）
struct EpisodeTodoGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: w * 0.5, y: 0))
        path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.76))
        path.move(to: CGPoint(x: w * 0.16, y: h * 0.46))
        path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.82))
        path.addLine(to: CGPoint(x: w * 0.84, y: h * 0.46))
        return path
    }
}

/// 竖屏选集面板：底部升起的墨本弹层（照横屏 22:78 的材质与网格，改成竖屏铺满宽度）
struct EpisodePanel: View {
    let items: [EpisodePanelItem]
    let current: Int
    /// 一次性提示（下载入队 / 站点未开放…）：非空时顶替标题，2.4s 后恢复「选集」
    var hint: String?
    var onSelect: (Int) -> Void
    var onClose: () -> Void

    var body: some View {
        // 可用宽度用 GeometryReader 现量（不要 UIScreen.main：iOS 26 起 deprecated，
        // 且弹层宽度本来就等于「外层给的宽度 − 左右内边距」）
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 14) {
                // 标题行（画布 22:87：关闭 20×20 + 「选集」17px 衬线居中）
                ZStack {
                    HStack {
                        Button(action: onClose) {
                            OverlayCloseGlyph()
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭")
                        Spacer(minLength: 0)
                    }
                    if let hint {
                        Text(hint)
                            .font(DWFont.cn(12, .medium))
                            .foregroundStyle(DWColor.overlayCinnabar)
                            .lineLimit(1)
                    } else {
                        Text("选集")
                            .font(DWFont.serif(17, .medium))
                            .foregroundStyle(.white)
                    }
                }
                .frame(height: 32)

                ScrollView {
                    EpisodeGrid(items: items, current: current,
                                availableWidth: geo.size.width - EpisodeGridMetrics.horizontalPadding * 2,
                                onSelect: onSelect)
                        .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, EpisodeGridMetrics.horizontalPadding)
            .padding(.top, 18)
            .padding(.bottom, 18)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .background(DWColor.episodePanel)
    }
}

// MARK: - 底部弹层容器（选集面板用）

/// 自底部弹出 / 向底部缩短的弹层（2026-11-15 用户拍板）。
///
/// 实现 = **贴底的高度窗 + clipped**：内容始终按目标高度排布、底边钉在屏幕底，
/// 窗高 0 → H 就是把整块从底边「长出来」（观感是自底部弹出），H → 0 就是缩回底边
/// （观感是向底部缩短）。**不要换成 `.transition(.move(edge: .bottom))`**：那是整块
/// 上下平移，消失时内容会一边下移一边露出后面的画面；也不要 `.scaleEffect`，
/// 格子会被纵向压扁。用高度动画则内容不参与缩放、格子比例不变。
struct BottomSheet<Content: View>: View {
    /// 是否展开（外层配 `.animation(_:value:)` 驱动高度）
    let isPresented: Bool
    /// 展开后的高度
    let height: CGFloat
    var topRadius: CGFloat = 20
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content()
                .frame(height: height)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: topRadius,
                                                  topTrailingRadius: topRadius))
                // 高度窗：0 时整块被裁掉，H 时完整露头；对齐 .bottom 让底边始终钉在屏幕底
                .frame(height: isPresented ? height : 0, alignment: .bottom)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 关闭 X（画布 22:89：20×20 内 12×12 叉，描边 1.8）
struct OverlayCloseGlyph: View {
    var size: CGFloat = 20
    var color: Color = .white

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 20
            let stroke = 1.8 * s
            var x = Path()
            x.move(to: CGPoint(x: 4 * s, y: 4 * s))
            x.addLine(to: CGPoint(x: 16 * s, y: 16 * s))
            x.move(to: CGPoint(x: 16 * s, y: 4 * s))
            x.addLine(to: CGPoint(x: 4 * s, y: 16 * s))
            ctx.stroke(x, with: .color(color),
                       style: StrokeStyle(lineWidth: stroke, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

#Preview("选集网格") {
    ZStack {
        Color.black
        EpisodeGrid(items: (1...60).map {
            EpisodePanelItem(sort: $0,
                             phase: $0 == 8 ? .done : ($0 == 9 ? .active(0.4) : .idle),
                             playable: $0 % 7 != 0)
        }, current: 9, availableWidth: 366) { _ in }
            .padding(18)
    }
    .ignoresSafeArea()
}
