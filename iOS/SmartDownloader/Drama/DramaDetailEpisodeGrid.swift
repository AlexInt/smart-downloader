import SwiftUI

// 内容组 / 选集区——从 DramaDetailView.swift 逐字搬出（纯搬移，逻辑零改动）：
// vm / motion / descShift 以入参传入；共用配色 cellBackground / cellForeground 仍在主文件
//（「// MARK: - 共用配色」），以同名函数入参传入，调用点逐字保留。

struct CellColorFn {
    /// Swift 函数值不能带实参标签，用 callAsFunction 让搬移后的调用点
    /// （`cellBackground(isSelected:…)`）与主文件同名方法的签名逐字一致。
    let f: (Bool, Bool, Bool) -> Color

    func callAsFunction(isSelected: Bool, isDownloaded: Bool, playable: Bool) -> Color {
        f(isSelected, isDownloaded, playable)
    }
}

struct DramaDetailEpisodeGrid {
    let vm: DramaPageViewModel
    /// 设计稿 .32s cubic-bezier(.2,.8,.2,1)（reduced-motion 时为 nil），主文件同名只读属性传入
    let motion: Animation?
    /// 简介展开位移：设计稿 --desc-shift，唯一驱动内容组 translateY（主文件同名只读属性传入）
    let descShift: CGFloat
    let cellBackground: CellColorFn
    let cellForeground: CellColorFn

    // MARK: ④ 内容组（唯一位移 translateY(--desc-shift)）

    func contentGroup(_ info: DramaInfo) -> some View {
        ZStack(alignment: .topLeading) {
            Text("选集")
                .font(DWFont.serif(16, .medium))
                .foregroundStyle(DWColor.paperInk)
                .designFrame(20, 490, 64, 24, alignment: .leading)

            // 「共 N 集」已按用户要求移除（2026-11-14）：集数在下方格子里一眼可数，
            // 这行小字只是噪音。原来空出的位置就留给行尾两个动作按钮（2026-11-15 右移）。

            // 「下载全部」紧挨「查看全部」排在行尾（用户 2026-11-15 要求右移）。
            // 可播集全部落盘后置灰禁用（同用户要求）：再点也只会得到「没有可下载的剧集」，
            // 按钮状态应该先说话。排队中的集不算已下载，按钮仍可点（downloadAll 会如实提示）。
            Button { vm.downloadAll() } label: {
                Text("下载全部")
                    .font(DWFont.cn(12, .medium))
                    .foregroundStyle(vm.allPlayableDownloaded
                                     ? DWColor.paperFaint : DWColor.paperCinnabar)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 64, height: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(vm.allPlayableDownloaded)
            .accessibilityLabel("下载全部")
            .accessibilityHint(vm.allPlayableDownloaded
                               ? "所有可下载剧集均已下载"
                               : "把全部可下载剧集加入下载队列")
            .designFrame(228, 481, 64, 44, alignment: .trailing)

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
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 70, height: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!vm.hasExtraEpisodes)
            .designFrame(300, 481, 70, 44, alignment: .trailing)

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
    /// 刷新已改为页面下拉刷新，所以 sheet 可以整块删掉，功能不丢。
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
                // 选中态也要画环：用户 2026-11-15 拍板「选中 + 下载两种状态叠加时，
                // 下载边缘进度颜色应该是白色的」——朱砂底上的墨环看不见，等于进度丢了
                progressRing(phase, onCinnabar: isSelected)
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
    /// `onCinnabar` = 这一格是选中态（朱砂底）：墨色环在朱砂上等于消失，整套换纸白
    /// （用户 2026-11-15 拍板：选中 + 下载叠加时，下载边缘进度必须是白的）。
    @ViewBuilder
    private func progressRing(_ phase: EpisodeDownloadPhase, onCinnabar: Bool = false) -> some View {
        let track = onCinnabar ? DWColor.paper.opacity(0.45) : DWColor.paperTrack.opacity(0.55)
        let bar = onCinnabar ? DWColor.paper : DWColor.paperTrackFill
        let done = onCinnabar ? DWColor.paper.opacity(0.9) : DWColor.paperInkSub
        // 失败态在朱砂底上不能再用朱砂，换墨：仍然是最重的一条线，语义不丢
        let failed = onCinnabar ? DWColor.paperInk : DWColor.paperCinnabar
        switch phase {
        case .idle:
            EmptyView()
        case .queued:
            RoundedRectangle(cornerRadius: 10)
                .stroke(track, lineWidth: 2)
                .padding(1)
        case .active(let progress):
            RoundedRectangle(cornerRadius: 10)
                .trim(from: 0, to: progress)
                .stroke(bar, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(1)
        case .done:
            // 完成态用半档墨：2pt 实墨闭环在纸面上会和「选中」抢同一份重量，
            // 而已下载本来就有淡朱砂底 + 墨三角角标，闭环只需"看起来是合上的"。
            RoundedRectangle(cornerRadius: 10)
                .stroke(done, lineWidth: 1.5)
                .padding(1)
        case .failed:
            RoundedRectangle(cornerRadius: 10)
                .stroke(failed, lineWidth: 2)
                .padding(1)
        }
    }
}
