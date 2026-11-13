import UIKit

// MARK: - 触觉反馈统一入口（Service，系统能力域）

/// 全 App 的震动反馈集中一处：行业惯例只给「有意义、非重复」的事件加触觉，
/// 防触觉疲劳——点选格子、seek 拖动过程、普通翻页这类高频/低信息量事件不加。
/// 主线程约定：全部调用点都在主线程（VM 方法 / UIKit 回调）；generator 静态复用，
/// 避免"每次 new generator"的首次触发延迟。
enum AppHaptics {
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let notifyGenerator = UINotificationFeedbackGenerator()

    /// 轻触：动作确认类。长按 2x 起、收藏切换、入队确认、退出全屏
    static func light() {
        lightGenerator.impactOccurred()
    }

    /// 中触：显著状态迁移。自动进入全屏（横屏片源转屏）
    static func medium() {
        mediumGenerator.impactOccurred()
    }

    /// 成功：异步结果达成。单集下载完成
    static func success() {
        notifyGenerator.notificationOccurred(.success)
    }

    /// 警示：到达边界。上滑到最后一集（没有更多了）
    static func warning() {
        notifyGenerator.notificationOccurred(.warning)
    }
}
