import SwiftUI

// MARK: - 纸本轨线稿图元（浏览页 / 下载页）
//
// 画布里的图标全是 1pt 描边线稿（22:298 锁 / 22:306 站点 / 22:329 后退 / 22:332 刷新 /
// 2:47 暂停 / 19:313 完成 / 30:56 编辑 / 30:60 排序），内部矢量坐标已逐点读过。
// 这里用 Shape 复刻而不是 SF Symbols：符号的字重/留白/端点由系统决定，笔画粗细与
// 画布的 1pt 线稿对不上（设置页的箭头/勾/加号同理，故全项目统一走自绘）。
//
// 约定：Shape 的 rect 就是画布上该图标的字号框（如锁 12×12、下载徽标 14×14），
// 内部坐标按 12×12 / 14×14 这类原始栅格归一化，缩放时不失真。

/// 尖角箭头（‹ / ›）。画布 22:329 后退 = 6.5×13 的折线，收在 20×20 命中框里。
struct PaperChevronShape: Shape {
    var pointsLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        if pointsLeft {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        return path
    }
}

/// 锁（22:298，12×12）：锁体 8×6 圆角 1.4 + 上方 4×3 的锁梁。
struct PaperLockShape: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 12
        var path = Path()
        let body = CGRect(x: rect.minX + 2 * k, y: rect.minY + 5 * k,
                          width: 8 * k, height: 6 * k)
        path.addRoundedRect(in: body, cornerSize: CGSize(width: 1.4 * k, height: 1.4 * k))
        // 锁梁：左腿升到 y=3.7，绕 (6,3.7) 半径 2 的半圆，右腿落回 y=5
        path.move(to: CGPoint(x: rect.minX + 4 * k, y: rect.minY + 5 * k))
        path.addLine(to: CGPoint(x: rect.minX + 4 * k, y: rect.minY + 3.7 * k))
        path.addArc(center: CGPoint(x: rect.minX + 6 * k, y: rect.minY + 3.7 * k),
                    radius: 2 * k,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + 8 * k, y: rect.minY + 5 * k))
        return path
    }
}

/// 站点胶囊里的小屏（22:306，12×12）：9×7 圆角 1.4 的屏 + 中心 2.4 的点。
/// 点用 1pt 描边画 → 描边宽度已接近边长，视觉上就是一个实心点，与画布一致。
struct PaperScreenShape: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 12
        var path = Path()
        let screen = CGRect(x: rect.minX + 1.5 * k, y: rect.minY + 2.5 * k,
                            width: 9 * k, height: 7 * k)
        path.addRoundedRect(in: screen, cornerSize: CGSize(width: 1.4 * k, height: 1.4 * k))
        path.addRect(CGRect(x: rect.minX + 4.8 * k, y: rect.minY + 4.8 * k,
                            width: 2.4 * k, height: 2.4 * k))
        return path
    }
}

/// 下载徽标（22:337，14×14）：12 的圆 + 圆内 4.8×6 的下箭头。
struct PaperBadgeArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 14
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.minX + k, y: rect.minY + k,
                                   width: 12 * k, height: 12 * k))
        path.move(to: CGPoint(x: rect.minX + 7 * k, y: rect.minY + 4 * k))
        path.addLine(to: CGPoint(x: rect.minX + 7 * k, y: rect.minY + 9.6 * k))
        path.move(to: CGPoint(x: rect.minX + 4.6 * k, y: rect.minY + 7.2 * k))
        path.addLine(to: CGPoint(x: rect.minX + 7 * k, y: rect.minY + 9.6 * k))
        path.addLine(to: CGPoint(x: rect.minX + 9.4 * k, y: rect.minY + 7.2 * k))
        return path
    }
}

/// 刷新（22:332）：缺右上角的一段圆 + 箭头。半径取 0.3 边长，与画布 12.76×12.8 的直径同量级。
struct PaperReloadShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.30
        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(-35), endAngle: .degrees(245),
                    clockwise: true)
        // 箭头画在 -35° 的端点处，指向切线方向（与画布 22:334 的小三角同位）
        let tip = CGPoint(x: center.x + radius * cos(-35 * .pi / 180),
                          y: center.y + radius * sin(-35 * .pi / 180))
        path.move(to: CGPoint(x: tip.x, y: tip.y - radius * 0.62))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x + radius * 0.62, y: tip.y - radius * 0.10))
        return path
    }
}

/// 取消（下载中行右侧圆形按钮内的叉）：两条对角线，收在 40% 内框里
struct PaperXShape: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.width * 0.30
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
        return path
    }
}

/// 勾（19:315 完成 / 34:59 勾选）：7.6×5.2 的折角，与设置页的勾同一套比例
struct PaperCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.06))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.04, y: rect.minY + rect.height * 0.06))
        return path
    }
}

/// 编辑（30:57，14.6×14.6）：笔杆四边 + 笔尖，一支斜放的铅笔轮廓
struct PaperPencilShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: p(0.03, 0.97))      // 笔尖
        path.addLine(to: p(0.13, 0.62))
        path.addLine(to: p(0.66, 0.05))   // 笔杆顶
        path.addLine(to: p(0.95, 0.34))
        path.addLine(to: p(0.37, 0.88))
        path.closeSubpath()
        path.move(to: p(0.13, 0.62))      // 笔杆与笔尖的分界
        path.addLine(to: p(0.37, 0.88))
        return path
    }
}

/// 排序（30:61，12×7）：三条左对齐、长度 12/9/6 递减的横线
struct PaperSortShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, ratio) in [1.0, 0.75, 0.5].enumerated() {
            let y = rect.minY + rect.height * CGFloat(index) / 2
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * ratio, y: y))
        }
        return path
    }
}

/// 网页内容区占位（22:324，22×22）：一条横贯的十字，四角留白
struct PaperPlusShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
