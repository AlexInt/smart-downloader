import SwiftUI

// MARK: - 倍速面板（画布 22:77 倍速抽屉）
//
// 横屏与竖屏共用同一份选项列表与视觉语言，只是落位不同：
// - 横屏：右侧 300×390 滑入抽屉（r36，右内边距 54 收窄，避开圆角与安全区）
// - 竖屏：居中墨本浮层（画布未给竖屏版本，沿用同一套材质与档位——用户拍板 2026-11-15）
//
// 色值与几何全部来自画布节点实读，勿凭目测调整：
// 底 #1C1E1F / 选项文字 #E8E6DF 15px / 选中行 46pt 高 r10 #35393B、文字 #F2F0EA Medium。

/// 倍速面板的行高与内边距（画布 22:77：pt22 pb22 pl18 pr54、六档 SPACE_EVENLY）
enum PlaybackRateMetrics {
    /// 选中行高（画布 22:83 height 46）
    static let selectedRowHeight: CGFloat = 46
    /// 未选中行是 hug_contents 文本，行距由 SPACE_EVENLY 撑开——用固定行高近似同观感
    static let rowHeight: CGFloat = 34
    static let rowSpacing: CGFloat = 0
    static let cornerRadius: CGFloat = 10
    static let panelCornerRadius: CGFloat = 36
    static let panelWidth: CGFloat = 300
    /// 文本左右内边距：画布 pl18，选中行整行铺满内宽，文字居中
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 22
    /// 6 档 × (46 选中 / 34 其余) + 上下 22 + 行间余量 ≈ 390 的画布高度
    static var preferredHeight: CGFloat {
        verticalPadding * 2
            + selectedRowHeight
            + rowHeight * CGFloat(DramaPlayerViewModel.rateOptions.count - 1)
    }
}

/// 单档文案：画布是「3.0倍速」「1.25倍速」「1.0倍速（默认）」
func playbackRateLabel(_ rate: Double) -> String {
    let trimmed = String(format: "%.2f", rate)
        .replacingOccurrences(of: "0$", with: "")
        .replacingOccurrences(of: "\\.$", with: "")
    return rate == 1.0 ? "\(trimmed)倍速（默认）" : "\(trimmed)倍速"
}

struct PlaybackRatePanel: View {
    let currentRate: Double
    var onSelect: (Double) -> Void

    var body: some View {
        VStack(spacing: PlaybackRateMetrics.rowSpacing) {
            ForEach(DramaPlayerViewModel.rateOptions, id: \.self) { rate in
                row(rate)
            }
        }
        .padding(.horizontal, PlaybackRateMetrics.horizontalPadding)
        .padding(.vertical, PlaybackRateMetrics.verticalPadding)
        .frame(width: PlaybackRateMetrics.panelWidth)
        .background(DWColor.ratePanel, in: RoundedRectangle(cornerRadius: PlaybackRateMetrics.panelCornerRadius))
    }

    private func row(_ rate: Double) -> some View {
        let selected = abs(rate - currentRate) < 0.001
        return Button {
            onSelect(rate)
        } label: {
            Text(playbackRateLabel(rate))
                .font(selected ? DWFont.cn(15, .medium) : DWFont.cn(15, .regular))
                .foregroundStyle(selected ? DWColor.rateTextSelected : DWColor.rateText)
                .frame(maxWidth: .infinity)
                .frame(height: selected ? PlaybackRateMetrics.selectedRowHeight
                                        : PlaybackRateMetrics.rowHeight)
                .background(selected ? DWColor.rateRowSelected : .clear,
                            in: RoundedRectangle(cornerRadius: PlaybackRateMetrics.cornerRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playbackRateLabel(rate))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

#Preview("倍速面板") {
    ZStack {
        Color.black
        PlaybackRatePanel(currentRate: 1.0) { _ in }
    }
    .ignoresSafeArea()
}
