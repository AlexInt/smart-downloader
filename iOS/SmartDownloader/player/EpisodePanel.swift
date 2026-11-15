import SwiftUI

// MARK: - 选集面板（竖屏）
//
// 画布给了完整版「选集面板 · 上墨下纸」（19:62，上半剧照 352 + 下半纸本弹层 492，
// 含拖拽把手 / 剧集信息行 / 内容 tab / 集数分段 / 集数网格）。本轮按用户拍板先做简单版：
// 照横屏 22:78 的网格样式改成竖屏底部弹层，只保留「标题行 + 集数网格」，
// 网格与当前集样式严格对齐画布 22:91 / 22:98（4 列 46×46 gap 9、当前集朱砂描边 + 播放小点）。
//
// 后续做完整版时只需替换本文件的容器部分，网格可原样复用。

/// 选集网格度量（画布 22:78 / 22:92 / 22:98）
enum EpisodeGridMetrics {
    /// 每格边长（画布 46×46）
    static let cell: CGFloat = 46
    /// 格间（画布 gap 9）
    static let gap: CGFloat = 9
    /// 格圆角（画布 9）
    static let cellRadius: CGFloat = 9
    /// 列数（画布 4 列）
    static let columns = 4
    /// 当前集播放小点（画布 4×4 r2，gap 3）
    static let dot: CGFloat = 4
}

struct EpisodeGrid: View {
    let total: Int
    let current: Int
    var onSelect: (Int) -> Void

    private var rows: [[Int]] {
        stride(from: 1, through: max(total, 1), by: EpisodeGridMetrics.columns).map {
            Array($0..<min($0 + EpisodeGridMetrics.columns, total + 1))
        }
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(EpisodeGridMetrics.cell),
                                               spacing: EpisodeGridMetrics.gap),
                           count: EpisodeGridMetrics.columns),
            alignment: .leading,
            spacing: EpisodeGridMetrics.gap
        ) {
            ForEach(1...max(total, 1), id: \.self) { index in
                cell(index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ index: Int) -> some View {
        let isCurrent = index == current
        return Button {
            onSelect(index)
        } label: {
            HStack(spacing: isCurrent ? 3 : 0) {
                Text("\(index)")
                    .font(isCurrent ? DWFont.en(14, .medium) : DWFont.en(14, .regular))
                    .foregroundStyle(isCurrent ? DWColor.overlayCinnabar : DWColor.overlayInk)
                if isCurrent {
                    Circle()
                        .fill(DWColor.overlayCinnabar)
                        .frame(width: EpisodeGridMetrics.dot, height: EpisodeGridMetrics.dot)
                }
            }
            .frame(width: EpisodeGridMetrics.cell, height: EpisodeGridMetrics.cell)
            .background(isCurrent ? DWColor.episodeCellCurrent : DWColor.episodeCell,
                        in: RoundedRectangle(cornerRadius: EpisodeGridMetrics.cellRadius))
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: EpisodeGridMetrics.cellRadius)
                        .strokeBorder(DWColor.episodeCellStroke, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(index) 集")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}

/// 竖屏选集面板：底部升起的墨本弹层（照横屏 22:78 的材质与网格，改成竖屏铺满宽度）
struct EpisodePanel: View {
    let total: Int
    let current: Int
    var onSelect: (Int) -> Void
    var onClose: () -> Void

    var body: some View {
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
                Text("选集")
                    .font(DWFont.serif(17, .medium))
                    .foregroundStyle(.white)
            }
            .frame(height: 32)

            ScrollView {
                EpisodeGrid(total: total, current: current, onSelect: onSelect)
                    .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        EpisodeGrid(total: 60, current: 8) { _ in }
            .padding(18)
    }
    .ignoresSafeArea()
}
