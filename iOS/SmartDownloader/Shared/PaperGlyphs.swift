import SwiftUI

// MARK: - 纸本轨线稿图元（浏览页 / 下载页）
//
// 画布里的图标几乎全是 1pt 描边线稿（22:298 锁 / 22:306 站点 / 22:329 后退 /
// 2:47 暂停 / 19:313 完成 / 30:56 编辑 / 30:60 排序），内部矢量坐标已逐点读过。
// 这里用 Shape 复刻而不是 SF Symbols：符号的字重/留白/端点由系统决定，笔画粗细与
// 画布的 1pt 线稿对不上（设置页的箭头/勾/加号同理，故全项目统一走自绘）。
//
// **例外：刷新（22:332）是实心填充形**，粗弧带 + L 形直角箭头，不是描边线稿，
// 故它由调用方 `.fill` 而不是 `.stroke`（详见该 struct 的注释）。
//
// 约定：Shape 的 rect 就是画布上该图标的字号框（如锁 12×12、下载徽标 14×14），
// 内部坐标按 12×12 / 14×14 这类原始栅格归一化，缩放时不失真。

/// 尖角箭头（‹ / ›）。画布 22:329 后退 = 6.5×13 的**中心线**折线，收在 20×20 命中框里。
/// 注意画布对描边图元报的 width/height 是几何框（不含描边），所以 6.5×13 直接当中心线用、
/// 描边 1.2 会外扩到墨迹 ~7.7×14.2；对填充图元（如刷新）报的则是墨迹框。
/// 调用方还需补设计稿的光学居中：后退/前进各向外偏 0.75（见 BrowserView.navGlyph）。
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

/// 刷新（22:332，20×20）：**实心填充**形，不是描边线稿。
///
/// 这个图标和本文件其它图元不是一类：画布上是两个填充矢量（22:333 弧带 12.76×12.8 +
/// 22:334 L 形箭头 4.5×4.6），弧带本身比 1pt 线稿粗一倍、且收笔处变宽。
/// 早先按「1.2pt 描边圆 + 手画一个 V 形刺」实现，实机看着像圈里插了根斜杠——
/// 因为 ① 线宽只有设计的一半；② 箭头根本不是 V，是 L 形直角箭头；③ 圆心也偏高 1.3pt。
/// 所以这里不做圆拟合、不再自绘箭头：把设计稿导出的 path 原样转成 Path（逐段 Q 曲线），
/// 由调用方 `.fill(DWColor.paperInk)`。坐标即画布 20×20 原始空间，缩放时等比。
struct PaperReloadShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 20
        let sy = rect.height / 20
        /// 画布局部坐标 → rect 坐标（各子路径自带平移量，与 SVG 的 transform 一致）
        func pt(_ x: CGFloat, _ y: CGFloat, _ ox: CGFloat, _ oy: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x + ox) * sx, y: rect.minY + (y + oy) * sy)
        }

        var path = Path()

        // 22:333 弧带 —— 缺口在右侧（约 3 点钟方向），收笔在左上
        let ax: CGFloat = 3.83603, ay: CGFloat = 4.92186
        path.move(to: pt(11.5616, 4.3646, ax, ay))
        path.addQuadCurve(to: pt(7.6696, 0.9978, ax, ay), control: pt(10.5052, 1.6642, ax, ay))
        path.addQuadCurve(to: pt(2.6719, 2.2775, ax, ay), control: pt(4.8325, 0.331, ax, ay))
        path.addQuadCurve(to: pt(0.8986, 7.0917, ax, ay), control: pt(0.514, 4.2215, ax, ay))
        path.addQuadCurve(to: pt(3.8789, 11.2769, ax, ay), control: pt(1.2832, 9.9628, ax, ay))
        path.addQuadCurve(to: pt(9.0395, 11.2091, ax, ay), control: pt(6.4771, 12.5923, ax, ay))
        path.addQuadCurve(to: pt(11.9077, 6.9473, ax, ay), control: pt(11.5993, 9.8274, ax, ay))
        path.addQuadCurve(to: pt(12.2192, 6.3762, ax, ay), control: pt(11.9354, 6.5919, ax, ay))
        path.addQuadCurve(to: pt(12.8434, 6.1926, ax, ay), control: pt(12.4902, 6.1445, ax, ay))
        path.addQuadCurve(to: pt(13.4145, 6.5041, ax, ay), control: pt(13.1988, 6.2204, ax, ay))
        path.addQuadCurve(to: pt(13.598, 7.1283, ax, ay), control: pt(13.6462, 6.7751, ax, ay))
        path.addQuadCurve(to: pt(9.8471, 12.7051, ax, ay), control: pt(13.1944, 10.8982, ax, ay))
        path.addQuadCurve(to: pt(3.111, 12.7936, ax, ay), control: pt(6.5024, 14.5106, ax, ay))
        path.addQuadCurve(to: pt(-0.7864, 7.3174, ax, ay), control: pt(-0.2829, 11.0753, ax, ay))
        path.addQuadCurve(to: pt(1.5341, 1.0144, ax, ay), control: pt(-1.29, 3.5586, ax, ay))
        path.addQuadCurve(to: pt(8.0586, -0.6571, ax, ay), control: pt(4.3555, -1.5274, ax, ay))
        path.addQuadCurve(to: pt(13.1448, 3.7452, ax, ay), control: pt(11.7632, 0.2135, ax, ay))
        path.addQuadCurve(to: pt(13.1319, 4.3956, ax, ay), control: pt(13.2842, 4.0733, ax, ay))
        path.addQuadCurve(to: pt(12.6629, 4.8465, ax, ay), control: pt(12.9985, 4.7262, ax, ay))
        path.addQuadCurve(to: pt(12.0125, 4.8336, ax, ay), control: pt(12.3348, 4.9858, ax, ay))
        path.addQuadCurve(to: pt(11.5616, 4.3646, ax, ay), control: pt(11.6819, 4.7001, ax, ay))
        path.closeSubpath()

        // 22:334 箭头 —— L 形直角箭头（短竖臂 + 长横臂），不是三角形也不是 V
        let bx: CGFloat = 11.9, by: CGFloat = 4.4
        path.move(to: pt(5.35, 0, bx, by))
        path.addLine(to: pt(5.35, 4.6, bx, by))
        path.addQuadCurve(to: pt(5.101, 5.201, bx, by), control: pt(5.3603, 4.9563, bx, by))
        path.addQuadCurve(to: pt(4.5, 5.45, bx, by), control: pt(4.8563, 5.4603, bx, by))
        path.addLine(to: pt(0, 5.45, bx, by))
        path.addQuadCurve(to: pt(-0.601, 5.201, bx, by), control: pt(-0.3563, 5.4603, bx, by))
        path.addQuadCurve(to: pt(-0.85, 4.6, bx, by), control: pt(-0.8603, 4.9563, bx, by))
        path.addQuadCurve(to: pt(-0.601, 3.999, bx, by), control: pt(-0.8603, 4.2437, bx, by))
        path.addQuadCurve(to: pt(0, 3.75, bx, by), control: pt(-0.3563, 3.7397, bx, by))
        path.addLine(to: pt(3.65, 3.75, bx, by))
        path.addLine(to: pt(3.65, 0, bx, by))
        path.addQuadCurve(to: pt(3.899, -0.601, bx, by), control: pt(3.6397, -0.3563, bx, by))
        path.addQuadCurve(to: pt(4.5, -0.85, bx, by), control: pt(4.1437, -0.8603, bx, by))
        path.addQuadCurve(to: pt(5.101, -0.601, bx, by), control: pt(4.8563, -0.8603, bx, by))
        path.addQuadCurve(to: pt(5.35, 0, bx, by), control: pt(5.3603, -0.3563, bx, by))
        path.closeSubpath()

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
