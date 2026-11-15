import SwiftUI

/// 原生剧集页入口（组装根）：点击剧集路由过来后交给 DramaDetailView 渲染。
/// 只做依赖注入与生命周期编排；屏内视觉在 DramaDetailView.swift，
/// 业务状态与编排在 DramaPageViewModel.swift，元数据收割在 DramaMetaHarvester.swift。
/// MVVM（架构评估 P8）：View → ViewModel → Service，单向依赖。
struct DramaNativePage: View {
    @ObservedObject var manager: DownloadManager
    @StateObject private var vm: DramaPageViewModel

    init(target: DramaTarget, manager: DownloadManager) {
        self.manager = manager
        _vm = StateObject(wrappedValue: DramaPageViewModel(target: target, manager: manager))
    }

    var body: some View {
        DramaDetailView(vm: vm)
            // 「为你推荐」卡片：在当前 NavigationStack 再推一层原生剧集页。
            // 站点地址由 VM 从当前 target.site 推导（不硬编码），返回即回到本剧。
            .navigationDestination(item: $vm.recommendedTarget) { target in
                DramaNativePage(target: target, manager: manager)
            }
            .fullScreenCover(item: $vm.playbackRequest) { request in
                DramaPlayerContainer(request: request, manager: manager,
                                     onClose: { vm.playbackRequest = nil })
            }
            // 顺序敏感：先回填缓存头部再 load——load 的 harvestIfNeeded 依赖头部缓存判定，
            // 反过来会让有缓存的页面误判缺封面/简介而多跑一次收割
            .onAppear {
                vm.preloadHeaderFromCache()
                vm.load()
            }
            .onChange(of: vm.reloadID) { vm.load() }
            .onReceive(manager.objectWillChange) { _ in vm.refreshDownloadedSorts() }
    }
}
