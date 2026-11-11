import CoreGraphics

/// 进度控制的纯几何判定（不依赖 SwiftUI / UIKit，可单测）。
/// 纵向 pan 由系统 UIScrollView 独占；这里只做屏幕坐标 ↔ 390×840 设计稿坐标换算。
/// 几何值必须与 DramaPlayerView 的 designFrame 同步修改。
/// （点按/长按是离散手势、放卡片内由 SwiftUI 深度优先解析，无需控件区几何判定。）
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

    /// 屏幕 y 是否落在进度条(y=744)的 seek 命中带内。
    /// 普通模式 ±60（设计 684..804）；清屏下进度条不可见、全靠盲按，±60 太窄——
    /// 真机日志实证盲按落点集中在带顶上方 5~60pt（402×874 机型带顶 709，落点 649~704
    /// 整批被拒，静默无 seek 无 HUD），放宽到 ±120（设计 624..844）覆盖底部 1/4 屏幕。
    /// fraction 映射不变：仍按进度条 x=20..350 宽度换算。
    static func isInSeekBand(screenY y: CGFloat, screenSize size: CGSize, expanded: Bool) -> Bool {
        let topDesign: CGFloat = expanded ? 624 : 684
        let bottomDesign: CGFloat = expanded ? 844 : 804
        let top = offsetY(in: size) + topDesign * scale(in: size)
        let bottom = offsetY(in: size) + bottomDesign * scale(in: size)
        return y >= top && y <= bottom
    }

    /// 屏幕 x → 进度比例（进度条设计稿 x=20..370，左右边距对称）
    static func seekFraction(screenX x: CGFloat, screenSize size: CGSize) -> Double {
        let left = offsetX(in: size) + 20 * scale(in: size)
        let width = 350 * scale(in: size)
        guard width > 0 else { return 0 }
        return Double(min(max(0, (x - left) / width), 1))
    }
}
