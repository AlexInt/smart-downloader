import SwiftUI

// MARK: - 海报卡 + 双列网格（全局组件 · 纸本轨）
//
// 三处共用同一套「封面 3:4 + 固定 67 文字块」的卡片与双列排布：
//   · 剧集页「为你推荐」（画布 22:163 / 30:104）
//   · 「我的」页封面墙（画布 19:200）
//   · 下载页「已下载」（画布 19:272）
// 组件只负责视觉与排布，不碰数据来源、导航、删除等业务；点击由调用方用
// Button / NavigationLink 包住，选择态只作为纯视觉入参传进来（SOLID：单一职责）。
//
// 几何全部来自画布实读（170 = (390 − 20×2 − 10) / 2，封面 170×226.7，文字块 67）：
// 改这里三处同时生效，别再往各页写一套卡片。

/// 封面来源：本地缓存文件 / 远程 URL / 无图（纸本占位）
enum PosterCoverSource {
    case local(URL)
    case remote(URL)
    case none
}

/// 统计行左侧的小图元：推荐卡是播放量三角，其余场景可不给
enum PosterStatIcon {
    case play
}

/// 一张海报卡的展示数据（纯数据，无 IO）。
struct PosterCardModel: Identifiable {
    let id: String
    let title: String
    var subtitle: String = ""
    var stat: String = ""
    var statIcon: PosterStatIcon? = nil
    var statTrailing: String? = nil
    var badge: String? = nil
    var cover: PosterCoverSource = .none
}

/// 卡片度量（画布 22:163 / 30:104 / 19:200）
enum PosterCardMetrics {
    /// 页面左右边距（三处都是 20：剧集页分节 20、「我的」DWLayout.edge、下载页沿用 20）
    static let horizontalPadding: CGFloat = 20
    /// 两列中缝（画布 10）
    static let columnGap: CGFloat = 10
    /// 行距（画布 12）
    static let rowGap: CGFloat = 12
    /// 整卡圆角（画布 8）
    static let cornerRadius: CGFloat = 8
    /// 封面宽高比 = 3:4（height = width × 4 / 3）
    static let coverAspect: CGFloat = 3.0 / 4.0
    /// 文字左右内缩（卡片细线要留呼吸，画布 8）
    static let textInset: CGFloat = 8
    /// 文字块固定高：上 6 + 标题 20 + 2 + 标签 14 + 3 + 统计 14 + 下 8 = 67
    static let textHeight: CGFloat = 67

    /// 列宽（按容器可用宽度现算，不写死 170 —— 390 设计稿上是 170，402 机型上是 176）
    static func columnWidth(availableWidth: CGFloat) -> CGFloat {
        (availableWidth - columnGap) / 2
    }
}

/// 单张海报卡：封面 3:4 + 标题 / 副标题 / 统计三行固定文字块。
/// 宽度由父容器决定（`PosterGrid` 的列宽，剧集页用 `.frame(width: 170)` 钉回设计值）。
struct PosterCardView: View {
    let model: PosterCardModel
    /// 选择态：nil = 不显示；true/false = 编辑模式下的勾选圈
    var selection: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            textBlock
        }
        .background(DWColor.paper)
        .clipShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius)
                .strokeBorder(DWColor.paperRule, lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius))
    }

    // MARK: 封面

    private var cover: some View {
        Rectangle()
            .fill(DWColor.paperChipIdle)
            .aspectRatio(PosterCardMetrics.coverAspect, contentMode: .fit)
            .overlay {
                coverImage
            }
            .clipped()
            .overlay(alignment: .topLeading) {
                if let badge = model.badge, !badge.isEmpty {
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
            .overlay(alignment: .topTrailing) {
                if let selection {
                    selectionMark(selection)
                        .padding(8)
                }
            }
    }

    @ViewBuilder
    private var coverImage: some View {
        switch model.cover {
        case .local(let url):
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                coverPlaceholder
            }
        case .remote(let url):
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    coverPlaceholder
                }
            }
        case .none:
            coverPlaceholder
        }
    }

    /// 无封面兜底：纸块 + 首字（剧集页原 `recoCoverPlaceholder`，下载页 `PaperCover.fallback` 同一说法）
    private var coverPlaceholder: some View {
        ZStack {
            DWColor.paperChipIdle
            Text(String(model.title.prefix(1)))
                .font(DWFont.serif(34))
                .tracking(2)
                .foregroundStyle(DWColor.paperLineIdle)
        }
    }

    /// 编辑模式勾选圈（画布 34:39 已选 = 朱砂实心 + 纸白勾；未选 = 同尺寸描边圈）
    private func selectionMark(_ selected: Bool) -> some View {
        ZStack {
            if selected {
                Circle().fill(DWColor.paperCinnabar).frame(width: 20, height: 20)
                PaperCheckShape()
                    .stroke(DWColor.paper,
                            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 8.4, height: 5.8)
            } else {
                // 未选态要先垫一层纸色，否则压在白封面/深封面上都看不清
                Circle().fill(DWColor.paper.opacity(0.9)).frame(width: 20, height: 20)
                Circle().stroke(DWColor.paperInkSub, lineWidth: 1).frame(width: 20, height: 20)
            }
        }
        .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
    }

    // MARK: 文字块

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.title)
                .font(DWFont.serif(13, .medium))
                .foregroundStyle(DWColor.paperInk)
                .lineLimit(1)
                .frame(height: 20, alignment: .leading)
                .padding(.top, 6)

            Text(model.subtitle)
                .font(DWFont.cn(10))
                .foregroundStyle(DWColor.paperInkSub)
                .lineLimit(1)
                .frame(height: 14, alignment: .leading)
                .padding(.top, 2)

            HStack(spacing: 3) {
                if let icon = model.statIcon {
                    switch icon {
                    case .play:
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(DWColor.paperFaint)
                    }
                }
                Text(model.stat)
                    .font(DWFont.cn(10, .semibold))
                    .foregroundStyle(DWColor.paperCinnabar)
                if let trailing = model.statTrailing, !trailing.isEmpty {
                    Text("· \(trailing)")
                        .font(DWFont.cn(10))
                        .foregroundStyle(DWColor.paperFaint)
                }
            }
            .frame(height: 14, alignment: .leading)
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PosterCardMetrics.textHeight, alignment: .topLeading)
        .padding(.horizontal, PosterCardMetrics.textInset)
    }
}

/// 双列海报网格：列宽自适应父容器，卡片用同一套 `PosterCardView`。
/// `LazyVGrid` 的 `.flexible()` 让两列平分可用宽度，不依赖 `UIScreen.main`（iOS 26 起 deprecated）。
struct PosterGrid<Item: Identifiable, Card: View>: View {
    let items: [Item]
    var columnGap: CGFloat = PosterCardMetrics.columnGap
    var rowGap: CGFloat = PosterCardMetrics.rowGap
    @ViewBuilder var card: (Item) -> Card

    /// 两列平分：第一列右间距 = 中缝，第二列不再加（否则右缘多出 10pt）
    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: columnGap, alignment: .top),
            GridItem(.flexible(), spacing: 0, alignment: .top)
        ]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: rowGap) {
            ForEach(items) { item in
                card(item)
            }
        }
    }
}

#Preview("海报卡 · 双列") {
    ScrollView {
        PosterGrid(items: [
            PosterCardModel(id: "1", title: "都重生了谁谈恋爱啊",
                            subtitle: "都市 / 重生 / 逆袭", stat: "16W",
                            statIcon: .play, statTrailing: "更新至 32 集",
                            badge: "连载中 · VIP"),
            PosterCardModel(id: "2", title: "凡人修仙传",
                            subtitle: "仙侠 / 热血", stat: "8.2W", statIcon: .play),
            PosterCardModel(id: "3", title: "无封面剧集", subtitle: "—", stat: "—")
        ]) { model in
            PosterCardView(model: model)
        }
        .padding(.horizontal, PosterCardMetrics.horizontalPadding)
    }
    .background(DWColor.paper)
}
