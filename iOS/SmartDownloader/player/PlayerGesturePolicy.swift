import CoreGraphics

/// 进度控制的纯几何判定（不依赖 SwiftUI / UIKit，可单测）。
/// 纵向 pan 由系统 UIScrollView 独占；这里只把屏幕坐标换算到 390×840 设计稿坐标。
struct PlayerGesturePolicy {
    private static func scale(in size: CGSize) -> CGFloat {
        min(size.width / 390, size.height / 840)
    }
    private static func offsetX(in size: CGSize) -> CGFloat {
        (size.width - 390 * scale(in: size)) / 2
    }
    private static func offsetY(in size: CGSize) -> CGFloat {
        (size.height - 840 * scale(in: size)) / 2
    }

    /// 屏幕 y 是否落在进度条(y=700) 上下各 60 的带内
    static func isInSeekBand(screenY y: CGFloat, screenSize size: CGSize) -> Bool {
        let top = offsetY(in: size) + 640 * scale(in: size)
        let bottom = offsetY(in: size) + 760 * scale(in: size)
        return y >= top && y <= bottom
    }

    /// 屏幕 x → 进度比例（进度条设计稿 x=20..310）
    static func seekFraction(screenX x: CGFloat, screenSize size: CGSize) -> Double {
        let left = offsetX(in: size) + 20 * scale(in: size)
        let width = 290 * scale(in: size)
        guard width > 0 else { return 0 }
        return Double(min(max(0, (x - left) / width), 1))
    }
}
