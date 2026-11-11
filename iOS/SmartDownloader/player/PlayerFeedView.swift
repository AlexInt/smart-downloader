import SwiftUI

/// 播放页容器：纵向翻页交给 UIKit 原生 `UIScrollView.isPagingEnabled`
/// （见 PlayerPagingScrollView），SwiftUI 侧只负责数据、当前页与停稳后切换播放源。
struct PlayerFeedView: View {
    @ObservedObject var vm: PlayerFeedViewModel
    var onClose: () -> Void
    /// 当前页只由分页容器回写，避免与 VM 的 @Published 形成反馈环
    @State private var scrollID: Int?

    var body: some View {
        Group {
            if vm.slots.isEmpty {
                emptyState
            } else {
                PlayerPagingScrollView(
                    slots: vm.slots,
                    currentSort: $scrollID,
                    playback: vm.playback,
                    vmCurrentSort: vm.currentSort,
                    isReady: vm.playbackReady,
                    makeCard: { slot in AnyView(card(for: slot)) }
                )
                .ignoresSafeArea()
                // 停稳防抖：快滑时旧任务自动取消，只在最后一页切换播放源
                .task(id: scrollID) {
                    print("PLAYER_DBG [CHECK] feedTask start scrollID=\(scrollID.map(String.init) ?? "nil") vmBefore=\(vm.currentSort.map(String.init) ?? "nil")")
                    guard let sort = scrollID else { return }
                    vm.currentSort = sort
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    await vm.pageSettled(sort: sort)
                }
                // slots 就绪后把 UIKit 分页定位到用户点的那一集（只做一次）
                .onChange(of: vm.slots.count, initial: true) { _, count in
                    print("PLAYER_DBG [FeedView] slotsCount=\(count) scrollID=\(scrollID.map(String.init) ?? "nil") vmCurrent=\(vm.currentSort.map(String.init) ?? "nil")")
                    guard count > 0, scrollID == nil else { return }
                    scrollID = vm.currentSort
                    print("PLAYER_DBG [FeedView] initial scrollID set=\(scrollID.map(String.init) ?? "nil")")
                }
                .onAppear {
                    print("PLAYER_DBG [FeedView] appear slots=\(vm.slots.count)")
                }
            }
        }
        .background(DWColor.background.ignoresSafeArea())
    }

    @ViewBuilder
    private func card(for slot: PlayableEpisode) -> some View {
        DramaPlayerView(
            episode: .local(seriesName: vm.seriesName,
                            intro: vm.intro,
                            index: slot.sort,
                            total: vm.totalEpisodes),
            playback: vm.playback,
            player: vm.currentSort == slot.sort ? vm.playback.player : nil,
            isActive: vm.currentSort == slot.sort,
            onClose: onClose,
            hasNextEpisode: vm.hasNext(after: slot.sort),
            isEpisodeAvailable: slot.isAvailable,
            nextEpisodeAvailable: vm.nextIsAvailable(after: slot.sort),
            toastText: vm.currentSort == slot.sort ? vm.toastText : nil
        )
    }

    private var emptyState: some View {
        ZStack {
            DWColor.background.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "film")
                    .font(.largeTitle)
                    .foregroundStyle(DWColor.textHint)
                Text("没有可播放的剧集")
                    .font(DWFont.cn(13))
                    .foregroundStyle(DWColor.textBody)
                Button("返回") { onClose() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
