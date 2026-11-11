import CoreGraphics

/// 横向 scrub 的纯几何换算（不依赖 SwiftUI / UIKit，可单测）。
///
/// 2026-11-11 用户拍板「横向 seek 全屏化（方案 A）」后，命中带几何已整体删除：
/// 横向拖动全屏有效、相对映射（拖动位移 / 屏宽 = 进度增量，一屏宽 ≈ 全片时长），
/// 落点无关 —— 「带在哪、盲按落点、带几何与 designFrame 同步」这类问题连根消失。
/// 进度条 HUD 的视觉坐标仍按 DramaPlayerView 的 designFrame（20,744,350），
/// 但那只影响显示，不再有任何手势几何与它耦合。
struct PlayerGesturePolicy {
    /// 拖动位移 → 进度增量。screenWidth 为分页 scrollView 宽度（点），为 0 时返回 0。
    static func scrubDelta(translationX: CGFloat, screenWidth: CGFloat) -> Double {
        guard screenWidth > 0 else { return 0 }
        return Double(translationX / screenWidth)
    }
}
