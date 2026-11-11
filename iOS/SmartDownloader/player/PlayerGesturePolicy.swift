import CoreGraphics

/// 进度控制与点按分区的纯几何判定（不依赖 SwiftUI / UIKit，可单测）。
/// 纵向 pan 由系统 UIScrollView 独占；这里只做屏幕坐标 ↔ 390×840 设计稿坐标换算。
/// 几何值必须与 DramaPlayerView 的 designFrame 同步修改。
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

    /// 屏幕 y 是否落在进度条(y=744) 上下各 60 的带内
    static func isInSeekBand(screenY y: CGFloat, screenSize size: CGSize) -> Bool {
        let top = offsetY(in: size) + 684 * scale(in: size)
        let bottom = offsetY(in: size) + 804 * scale(in: size)
        return y >= top && y <= bottom
    }

    /// 屏幕 x → 进度比例（进度条设计稿 x=20..370，左右边距对称）
    static func seekFraction(screenX x: CGFloat, screenSize size: CGSize) -> Double {
        let left = offsetX(in: size) + 20 * scale(in: size)
        let width = 350 * scale(in: size)
        guard width > 0 else { return 0 }
        return Double(min(max(0, (x - left) / width), 1))
    }

    /// 屏幕坐标 → 设计稿坐标（contain 缩放的逆变换）
    static func designPoint(screenX x: CGFloat, screenY y: CGFloat, screenSize size: CGSize) -> CGPoint {
        let s = scale(in: size)
        guard s > 0 else { return .zero }
        return CGPoint(x: (x - offsetX(in: size)) / s,
                       y: (y - offsetY(in: size)) / s)
    }

    /// 点按是否落在交互控件上（返回 / 静音 / 点赞 / 收藏）。
    /// 这些区域的点按不触发「点按暂停」——交给 SwiftUI Button 自己响应，
    /// 否则点静音会连带暂停播放。控件区外扩 12pt 容错。
    static func isTapOnControl(screenX x: CGFloat, screenY y: CGFloat, screenSize size: CGSize) -> Bool {
        let p = designPoint(screenX: x, screenY: y, screenSize: size)
        let pad: CGFloat = 12
        // (x, y, w, h) 与 DramaPlayerView 各 Button 的 designFrame 一致
        let frames: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (8 - pad, 44 - pad, 44 + pad * 2, 44 + pad * 2),      // 返回
            (329 - pad, 41 - pad, 44 + pad * 2, 44 + pad * 2),    // 静音
            (325 - pad, 538 - pad, 44 + pad * 2, 66 + pad * 2),   // 点赞（含文字）
            (325 - pad, 625 - pad, 44 + pad * 2, 66 + pad * 2),   // 收藏（含文字）
        ]
        return frames.contains { x0, y0, w, h in
            p.x >= x0 && p.x <= x0 + w && p.y >= y0 && p.y <= y0 + h
        }
    }
}
