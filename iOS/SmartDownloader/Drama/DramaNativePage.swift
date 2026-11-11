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
            .fullScreenCover(item: $vm.playbackRequest) { request in
                DramaPlayerContainer(request: request, onClose: { vm.playbackRequest = nil })
            }
            .task(id: vm.reloadID) { await vm.load() }
            .onAppear { vm.preloadHeaderFromCache() }
            .onReceive(manager.objectWillChange) { _ in vm.refreshDownloadedSorts() }
    }
}
