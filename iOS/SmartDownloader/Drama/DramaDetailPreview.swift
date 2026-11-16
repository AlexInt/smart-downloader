import SwiftUI

// 纸本样张段（#if DEBUG，仅模拟器截图用）——从 DramaDetailView.swift 逐字搬出（纯搬移，逻辑零改动）。
// DramaDebugFlags 是模块内访问级，主文件 body 的 DEBUG 分支照常引用。

#if DEBUG
// MARK: - 纸本样张容器（仅模拟器截图用）

/// 样张专用开关。模拟器点不了、滑不了，纸本轨又必须"改一版、看一张"。
enum DramaDebugFlags {
    /// 启动即落到内容页底，用于查看档案区与「滚过海报后的顶栏」
    static var bottomAnchor: Bool {
        ProcessInfo.processInfo.arguments.contains("-dramaPreviewBottom")
    }

    /// 下拉刷新三态定帧：`-refreshPreview pull|ready|refreshing|done`。
    /// 下拉刷新靠手指，模拟器既滑不了也不好定帧，只能让页面自己停在某一态上截。
    static var refreshPreview: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-refreshPreview"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// 档案区展开定帧（`-archiveExpandedPreview`）：模拟器点不了，展开态的高度预算
    /// 只能靠启动参数直接落到目标状态来截。
    static var archiveExpandedPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("-archiveExpandedPreview")
    }

    /// 自动跑一遍下拉刷新（`-refreshAuto`）：验证「刷新 → 已更新 → 收起」整条链路
    /// 会不会自己走回来。手势本身进不了模拟器，但状态机与 VM 调用可以这样验证。
    static var refreshAuto: Bool {
        ProcessInfo.processInfo.arguments.contains("-refreshAuto")
    }

    /// 错误态定帧（`-dramaErrorPreview`）：看错误详情块与复制按钮的排布
    static var errorPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("-dramaErrorPreview")
    }
}

/// 启动参数 `-dramaPreview` 打开：注入固定样本后直接渲染剧集页。
/// 存在的理由——模拟器点不了、滑不了，纸本轨又必须"改一版、看一张"；
/// 没有这个入口就只能盲改。Release 不编译。
struct DramaPreviewHost: View {
    @StateObject private var vm: DramaPageViewModel

    init(manager: DownloadManager) {
        let vm = DramaPageViewModel(target: DramaTarget(site: "https://preview.local", dramaID: "9001"),
                                    manager: manager)
        if DramaDebugFlags.errorPreview {
            vm.injectPreviewError()
        } else {
            vm.injectPreviewData()
        }
        _vm = StateObject(wrappedValue: vm)
    }

    var body: some View {
        NavigationStack { DramaDetailView(vm: vm) }
    }
}
#endif
