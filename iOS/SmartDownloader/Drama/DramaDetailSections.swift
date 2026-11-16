import SwiftUI

// 为你推荐 + 剧集档案——从 DramaDetailView.swift 逐字搬出（纯搬移，逻辑零改动）：
// vm / archiveExpanded（Binding，@State 仍在主文件，pageLayout 高度预算依赖它）/ motion
// 以入参传入；DetailLayout、PageLayout、RecoCardItem 仍在主文件，访问级已由 private 放开为模块内。

struct DramaDetailSections {
    let vm: DramaPageViewModel
    @Binding var archiveExpanded: Bool
    /// 设计稿 .32s cubic-bezier(.2,.8,.2,1)（reduced-motion 时为 nil），主文件同名只读属性传入
    let motion: Animation?

    // MARK: ⑤ 为你推荐（设计稿 .reco 双列瀑布流）

    func recommendationSection(layout: PageLayout) -> some View {
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
                recoCard(item)
            }
            Spacer(minLength: 0)
        }
        .frame(width: DetailLayout.recoColumnWidth, alignment: .topLeading)
    }

    /// 一张推荐卡。2026-11-15 用户拍板：所有封面统一「列宽 3:4」+ 固定文字块，
    /// 不再按序号取三档高度——原来 `scaledToFit` 会把窄卡裁成两侧露纸底的小图，
    /// 一眼看过去大小不齐。现在 `scaledToFill` 等比铺满、超出部分居中裁掉。
    /// 卡片视觉与「我的」封面墙、下载页「已下载」共用 `PosterCardView`（Components/PosterGrid.swift），
    /// 这里只负责把推荐数据翻成展示模型 + 点击意图，几何沿用画布 170 宽。
    private func recoCard(_ item: RecoCardItem) -> some View {
        Button { vm.openRecommendation(item.drama) } label: {
            PosterCardView(model: recoModel(item.drama))
                .frame(width: DetailLayout.recoColumnWidth)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("推荐：\(item.drama.displayTitle)")
    }

    /// 推荐剧 → 共享海报卡数据（纯映射，不碰 IO）
    private func recoModel(_ drama: RecommendedDrama) -> PosterCardModel {
        PosterCardModel(
            id: "reco:\(drama.id)",
            title: drama.displayTitle,
            subtitle: drama.tags.isEmpty ? "—" : drama.tags.joined(separator: " / "),
            stat: drama.displayPlayCount,
            statIcon: .play,
            statTrailing: drama.serializeStatusText,
            badge: drama.displayBadge,
            cover: drama.cover.flatMap { URL(string: $0) }.map { PosterCoverSource.remote($0) } ?? .none
        )
    }

    // MARK: ⑥ 剧集档案（详情接口整包字段，尽量全展示）

    /// 档案区默认折叠（用户 2026-11-15 要求）：这是给排障/取证看的低频信息，
    /// 不该把一整屏高度固定占着。标题行整行可点，右侧「展开/收起 + 尖角」指示状态；
    /// 折叠态的高度预算只留标题行（pageLayout 跟着 `archiveExpanded` 走）。
    func archiveSection(layout: PageLayout) -> some View {
        VStack(alignment: .leading, spacing: DetailLayout.archiveSectionGap) {
            Button {
                withAnimation(motion) { archiveExpanded.toggle() }
                AppHaptics.light()
                print("PLAYER_DBG [Entry] archive fold=\(archiveExpanded ? "expanded" : "collapsed") sections=\(vm.archiveSections.count)")
            } label: {
                HStack(alignment: .center, spacing: 0) {
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
                    Spacer(minLength: 8)
                    HStack(spacing: 3) {
                        Text(archiveExpanded ? "收起" : "展开")
                            .font(DWFont.cn(12))
                            .foregroundStyle(DWColor.paperInkSub)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        // 行尾尖角：折叠朝下（› 转 90°）、展开朝上（-90°），语义与
                        // 设置页行尾箭头同一套（PaperChevronShape 默认朝右）
                        PaperChevronShape(pointsLeft: false)
                            .stroke(DWColor.paperLineIdle,
                                    style: StrokeStyle(lineWidth: 1.2,
                                                       lineCap: .round, lineJoin: .round))
                            .frame(width: 6, height: 11)
                            .rotationEffect(.degrees(archiveExpanded ? -90 : 90))
                    }
                }
                .frame(height: DetailLayout.archiveTitleBlock, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(archiveExpanded ? "收起剧集档案" : "展开剧集档案")

            if archiveExpanded {
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
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, DetailLayout.archiveTopPadding)
        .padding(.bottom, DetailLayout.archiveBottomPadding)
        .frame(width: 390, height: layout.archiveHeight, alignment: .topLeading)
    }
}
