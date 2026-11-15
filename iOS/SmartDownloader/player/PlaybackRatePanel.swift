import SwiftUI

// MARK: - 倍速面板（画布 22:77 倍速抽屉）
//
// 横屏与竖屏共用同一份选项列表与视觉语言，只是落位不同：
// - 横屏：右侧 300×390 滑入抽屉（r36，右内边距 54 收窄，避开圆角与安全区）
// - 竖屏：半屏底部弹层 `PlaybackRateSheet`（2026-11-15 用户要求「拉起半屏」，
//   与选集面板同一个 BottomSheet 容器，档位同源）
//
// 色值与几何全部来自画布节点实读，勿凭目测调整：
// 底 #1C1E1F / 选项文字 #E8E6DF 15px / 选中行 46pt 高 r10 #35393B、文字 #F2F0EA Medium。

/// 档位行的圆角（画布 22:83 r10）——全屏抽屉与竖屏弹层共用
enum PlaybackRateMetrics {
    static let cornerRadius: CGFloat = 10
}

/// 单档文案：画布是「2.0倍速」「1.25倍速」「1.0倍速（默认）」
/// 数字部分走 `DramaPlayerViewModel.rateText`（与顶栏紧凑文案同源，别再各写一套）
func playbackRateLabel(_ rate: Double) -> String {
    let text = DramaPlayerViewModel.rateText(rate)
    return rate == 1.0 ? "\(text)倍速（默认）" : "\(text)倍速"
}

// MARK: - 竖屏倍速弹层（半屏）

/// 竖屏倍速面板（2026-11-15 用户要求「点倍速拉起半屏，选项与全屏一致」）：
/// 与选集面板共用 `BottomSheet` 容器（自底部升起、只切高度），档位取自
/// `DramaPlayerViewModel.rateOptions`（全屏抽屉同一份），视觉沿用画布 22:77 的墨本材质：
/// #1C1E1F 底 / 选中行 46 高 r10 #35393B / 选项文字 15px。
/// 原来是一块 300 宽的居中浮层，在整屏播放页上显得像弹窗而不是播放器面板。
struct PlaybackRateSheet: View {
    let currentRate: Double
    var onSelect: (Double) -> Void
    var onClose: () -> Void

    /// 每行高度：竖屏弹层整屏宽，比画布抽屉里的 22pt 行好点得多
    private static let rowHeight: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标题行：与选集面板同一形制（左关闭 / 居中标题）
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
                Text("倍速")
                    .font(DWFont.serif(17, .medium))
                    .foregroundStyle(.white)
            }
            .frame(height: 32)

            VStack(spacing: 0) {
                ForEach(DramaPlayerViewModel.rateOptions, id: \.self) { rate in
                    row(rate)
                }
            }
        }
        .padding(.horizontal, EpisodeGridMetrics.horizontalPadding)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DWColor.ratePanel)
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
                .frame(height: Self.rowHeight)
                .background(selected ? DWColor.rateRowSelected : .clear,
                            in: RoundedRectangle(cornerRadius: PlaybackRateMetrics.cornerRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playbackRateLabel(rate))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
