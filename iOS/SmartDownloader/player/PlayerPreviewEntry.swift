#if DEBUG
import SwiftUI

// MARK: - 播放器样张入口（仅 Debug）
//
// 存在的理由：模拟器点不了、滑不了、也转不了屏（合成 CGEvent 被系统丢弃，终端无辅助键授权），
// 而横屏全屏态又必须 `videoIsLandscape && isReady` 才允许进入——手工操作根本到不了
// 画布 22:1 / 22:72 / 22:73 那三张横屏稿。这里用启动参数把播放器直接推到目标态，
// 让「改一版、截一张、逐项比对」成为可能。Release 不编译。
//
// 用法（模拟器）：
//   simctl launch booted <bundle> -playerPreview                     竖屏完整态（画布 2:11）
//   simctl launch booted <bundle> -playerPreview -playerClean       竖屏清屏态（2:74）
//   simctl launch booted <bundle> -playerPreview -playerPanel rate   竖屏倍速浮层
//   simctl launch booted <bundle> -playerPreview -playerPanel episode 竖屏选集弹层
//   simctl launch booted <bundle> -playerPreview -playerFullscreen   横屏控件层（22:1）
//   ... 追加 -playerDrawer rate | episodes                            横屏抽屉态（22:72 / 22:73）
//   ... 追加 -playerPinControls                                      钉住控件不自动收起（截图用）
enum PlayerPreviewFlags {
    private static let args = ProcessInfo.processInfo.arguments

    /// `-playerPreview` 总开关
    static var enabled: Bool { args.contains("-playerPreview") }

    /// `-playerClean`：直接进清屏态（不落盘，仅本次进程生效）
    static var cleanScreen: Bool { args.contains("-playerClean") }

    /// `-playerPanel rate|episode`：竖屏浮层定帧
    static var verticalPanel: String? { value(after: "-playerPanel") }

    /// `-playerFullscreen`：进页后自动转横进全屏
    static var fullscreen: Bool { args.contains("-playerFullscreen") }

    /// `-playerDrawer rate|episodes`：全屏后自动展开右侧抽屉
    static var drawer: String? { value(after: "-playerDrawer") }

    /// `-playerPinControls`：每 2s 重置一次控件显隐计时（否则 3s 后自动收起，截到空屏）
    static var pinControls: Bool { args.contains("-playerPinControls") }

    /// `-playerLocked`：全屏后直接置锁定态（只剩解锁钮），用于截锁定态视觉
    static var locked: Bool { args.contains("-playerLocked") }

    /// `-playerPaused`：全屏后立刻暂停，用于截「播放三角」那一态（默认片源在播 = 双竖条）
    static var paused: Bool { args.contains("-playerPaused") }

    /// `-playerFreezePreview`：全屏后 10s 手动挂一次切集冻帧（6s 后看门狗自动放掉），
    /// 用于验收「冻帧层在全屏容器里铺得对不对」。模拟器切不了集，只能这样定点验证
    static var freezePreview: Bool { args.contains("-playerFreezePreview") }

    /// 样张剧名（默认用装进模拟器的「横屏样张」，三集 1280×720 真片源）
    static var seriesName: String { value(after: "-playerSeries") ?? "横屏样张" }

    private static func value(after key: String) -> String? {
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        let next = args[i + 1]
        return next.hasPrefix("-") ? nil : next
    }
}

/// 样张拉起的播放请求：三集真片源，从第 1 集起播
func makePreviewPlaybackRequest() -> ImmersivePlaybackRequest {
    ImmersivePlaybackRequest(seriesName: PlayerPreviewFlags.seriesName,
                             intro: nil,
                             startSort: 1,
                             knownSorts: [1, 2, 3])
}

/// 样张宿：与正式入口同一套 DramaPlayerContainer，不复制任何播放逻辑
struct PlayerPreviewHost: View {
    var manager: DownloadManager
    var body: some View {
        DramaPlayerContainer(request: makePreviewPlaybackRequest(), manager: manager, onClose: {})
    }
}
#endif
