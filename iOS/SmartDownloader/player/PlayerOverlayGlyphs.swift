import SwiftUI

// MARK: - 播放器叠层图标（按画布几何重绘）
//
// 素材库只有 6 个图标（back / like / save / sound / swipeUp / LaunchLogo），画布上
// 「更多三点」「倍速表盘」「画面适配」「锁」「音量」「播放三角」「下一集」都没有现成素材。
// 这里用 Shape/Path 按画布节点坐标重绘，尺寸与描边宽度逐项对齐，避免用近似 SF Symbol
// 造成「形制漂移」（此前集数胶囊、静音斜线就是这么跑偏的）。
//
// 坐标口径：每个图标在 viewport 内按画布节点本地坐标绘制，调用方只需给外层尺寸。

// MARK: 更多（画布 2:99 / 22:21 三个 2.8pt 圆点，竖向 gap 3）

/// 三个竖排圆点。viewport 20×20（竖屏）/ 16×20（横屏），点径 2.8。
struct OverlayMoreGlyph: View {
    var size: CGSize = CGSize(width: 20, height: 20)
    var color: Color = DWColor.overlayInk

    private let dot: CGFloat = 2.8

    var body: some View {
        // 画布竖屏：三点 y = 2.6 / 8.6 / 14.6（间距 6），x 居中（8.6 + 2.8/2 = 10 = 20/2）
        VStack(spacing: 6 - dot) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(color).frame(width: dot, height: dot)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: 倍速表盘（画布 2:95：12.4 描边圆 @1.8 + 2.4×5.4 指针 @(8,4.2)，描边 1.2）

/// 时钟表盘 + 指针 = 倍速。viewport 16×16。
struct OverlayRateGlyph: View {
    var size: CGFloat = 16
    var color: Color = DWColor.overlayInk

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 16   // 画布 16 基准 → 实际尺寸的换算
            let stroke = 1.2 * s
            // 表盘：12.4 直径居中（1.8..14.2）
            let dial = CGRect(x: 1.8 * s, y: 1.8 * s, width: 12.4 * s, height: 12.4 * s)
            ctx.stroke(Path(ellipseIn: dial), with: .color(color), lineWidth: stroke)
            // 指针：竖线 2.4×5.4 @(8,4.2) —— 表盘中心向上偏
            var hand = Path()
            hand.move(to: CGPoint(x: (8 + 1.2) * s, y: 4.2 * s))
            hand.addLine(to: CGPoint(x: (8 + 1.2) * s, y: (4.2 + 5.4) * s))
            ctx.stroke(hand, with: .color(color),
                       style: StrokeStyle(lineWidth: stroke, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

// MARK: 画面适配（画布 19:37：18.8 r4.6 描边方 @2.6 + 两个 4.3×3.6 角标，描边 1.5）

/// 「收缩画面」：描边方框 + 右上/左下两枚角标。viewport 24×24。
struct OverlayFitGlyph: View {
    var size: CGFloat = 24
    var color: Color = .white

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 24
            let stroke = 1.5 * s
            // 外框 18.8 r4.6 @(2.6,2.6)
            let box = CGRect(x: 2.6 * s, y: 2.6 * s, width: 18.8 * s, height: 18.8 * s)
            ctx.stroke(Path(roundedRect: box, cornerRadius: 4.6 * s),
                       with: .color(color), lineWidth: stroke)
            // 右上角标 4.3×3.6 @(12.9,7.2)：一条向右的短划 + 一条向下的短划（构成长方缺口）
            var tr = Path()
            tr.move(to: CGPoint(x: 12.9 * s, y: 7.2 * s))
            tr.addLine(to: CGPoint(x: (12.9 + 4.3) * s, y: 7.2 * s))
            tr.move(to: CGPoint(x: (12.9 + 4.3) * s, y: 7.2 * s))
            tr.addLine(to: CGPoint(x: (12.9 + 4.3) * s, y: (7.2 + 3.6) * s))
            ctx.stroke(tr, with: .color(color),
                       style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
            // 左下角标 4.3×3.6 @(6.8,13.2)：镜像
            var bl = Path()
            bl.move(to: CGPoint(x: (6.8 + 4.3) * s, y: (13.2 + 3.6) * s))
            bl.addLine(to: CGPoint(x: 6.8 * s, y: (13.2 + 3.6) * s))
            bl.move(to: CGPoint(x: 6.8 * s, y: (13.2 + 3.6) * s))
            bl.addLine(to: CGPoint(x: 6.8 * s, y: 13.2 * s))
            ctx.stroke(bl, with: .color(color),
                       style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

// MARK: 播放三角（画布 19:57：27.7×26.4 实心白三角 @(13,14.82)，容器 56×56）

/// 饱满大圆角白三角：画布是纯三角（无圆角描边痕迹），直接用 Path 填充。
struct OverlayPlayGlyph: View {
    var size: CGFloat = 28
    var color: Color = .white

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 27.7
            // 画布三角：宽 27.7、高 26.36，尖端朝右，垂直居中
            var tri = Path()
            tri.move(to: CGPoint(x: 0, y: 0))
            tri.addLine(to: CGPoint(x: 27.7 * s, y: 26.3636 / 2 * s))
            tri.addLine(to: CGPoint(x: 0, y: 26.3636 * s))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(color))
        }
        .frame(width: size, height: size * 26.3636 / 27.7)
    }
}

/// 暂停双竖条（画布 22:28：48×48 内两条 7×32 r3.5，x=14 / x=27，y=8）
struct OverlayPauseGlyph: View {
    var size: CGFloat = 48
    var color: Color = .white

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 48
            for x in [14.0, 27.0] {
                let bar = CGRect(x: x * s, y: 8 * s, width: 7 * s, height: 32 * s)
                ctx.fill(Path(roundedRect: bar, cornerRadius: 3.5 * s), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: 锁（画布 22:31：44×44 r11 底 #8C9190 a0.42；锁梁 10×8 @(17,11) 描边 2，锁体 14×13 r2.5 @(15,19)）

struct OverlayLockGlyph: View {
    var size: CGFloat = 44
    var locked: Bool
    var color: Color = .white

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11)
                .fill(DWColor.overlayButton.opacity(0.42))
            Canvas { ctx, canvasSize in
                let s = canvasSize.width / 44
                let stroke = 2 * s
                // 锁梁：半圆拱（10 宽 8 高，顶点在 y=11，两腿落到 y=19）
                var shackle = Path()
                shackle.move(to: CGPoint(x: 17 * s, y: 19 * s))
                shackle.addLine(to: CGPoint(x: 17 * s, y: 15 * s))
                shackle.addArc(center: CGPoint(x: 22 * s, y: 15 * s), radius: 5 * s,
                               startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                shackle.addLine(to: CGPoint(x: 27 * s, y: 19 * s))
                ctx.stroke(shackle, with: .color(color), lineWidth: stroke)
                // 锁体 14×13 r2.5 @(15,19)
                let body = CGRect(x: 15 * s, y: 19 * s, width: 14 * s, height: 13 * s)
                ctx.stroke(Path(roundedRect: body, cornerRadius: 2.5 * s),
                           with: .color(color), lineWidth: stroke)
                // 锁孔：0 宽 3.5 高的竖线 @(22,24)
                var keyhole = Path()
                keyhole.move(to: CGPoint(x: 22 * s, y: 24 * s))
                keyhole.addLine(to: CGPoint(x: 22 * s, y: 27.5 * s))
                ctx.stroke(keyhole, with: .color(color),
                           style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

// MARK: 音量（画布 22:36：44×44 r11 底；喇叭 10×18 @(14,13) 描边 2 + 声波 7×14 @(28,15) 描边 1.8）
//
// **竖屏静音钮与全屏音量钮共用这一枚**（2026-11-15 用户要求「竖屏的静音与非静音 icon
// 改为与全屏的一致」）：全屏带 44 方钮底（`showsChip = true`），竖屏右下角没有钮底，
// 直接画在画面上（默认 false）。几何与全屏 `VolumeGlyphView` 逐点一致——喇叭
// 14…24 / 13…31 描边 2，声波圆心 (24,22) r9 ±55° 描边 1.8，静音斜线 (15,15)-(31,31) 描边 2.2。

struct OverlayVolumeGlyph: View {
    var size: CGFloat = 44
    var muted: Bool
    var color: Color = .white
    /// 是否画 44 方钮底（全屏有、竖屏没有）
    var showsChip: Bool = false

    var body: some View {
        ZStack {
            if showsChip {
                RoundedRectangle(cornerRadius: 11 * (size / 44))
                    .fill(DWColor.overlayButton.opacity(0.42))
            }
            Canvas { ctx, canvasSize in
                let s = canvasSize.width / 44
                // 喇叭：矩形 + 三角（画布 10×18 @(14,13)）
                var horn = Path()
                horn.move(to: CGPoint(x: 14 * s, y: 19 * s))
                horn.addLine(to: CGPoint(x: 18 * s, y: 19 * s))
                horn.addLine(to: CGPoint(x: 24 * s, y: 13 * s))
                horn.addLine(to: CGPoint(x: 24 * s, y: 31 * s))
                horn.addLine(to: CGPoint(x: 18 * s, y: 25 * s))
                horn.addLine(to: CGPoint(x: 14 * s, y: 25 * s))
                horn.closeSubpath()
                ctx.stroke(horn, with: .color(color),
                           style: StrokeStyle(lineWidth: 2 * s, lineCap: .round, lineJoin: .round))
                if muted {
                    // 静音：一道斜线划过（与全屏同一条线：15,15 → 31,31）
                    var slash = Path()
                    slash.move(to: CGPoint(x: 15 * s, y: 15 * s))
                    slash.addLine(to: CGPoint(x: 31 * s, y: 31 * s))
                    ctx.stroke(slash, with: .color(color),
                               style: StrokeStyle(lineWidth: 2.2 * s, lineCap: .round))
                } else {
                    // 声波：圆弧，圆心与全屏一致 (24,22) r9
                    var wave = Path()
                    wave.addArc(center: CGPoint(x: 24 * s, y: 22 * s), radius: 9 * s,
                                startAngle: .degrees(-55), endAngle: .degrees(55), clockwise: false)
                    ctx.stroke(wave, with: .color(color),
                               style: StrokeStyle(lineWidth: 1.8 * s, lineCap: .round))
                }
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

// MARK: 亮度（画布 22:25：26×26，内圆 9.2 @8.4 描边 1.7 + 8 根射线 20.8 @2.6 描边 1.7）

struct OverlayBrightnessGlyph: View {
    var size: CGFloat = 26
    var color: Color = .white

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 26
            let stroke = 1.7 * s
            // 日心圆 9.2 直径 @(8.4,8.4)
            let core = CGRect(x: 8.4 * s, y: 8.4 * s, width: 9.2 * s, height: 9.2 * s)
            ctx.stroke(Path(ellipseIn: core), with: .color(color), lineWidth: stroke)
            // 8 根射线：半径从 20.8/2 处向内收，留出与圆心的间隙
            let center = CGPoint(x: 13 * s, y: 13 * s)
            let outer = 20.8 / 2 * s
            let inner = 7.6 * s
            for i in 0..<8 {
                let angle = Double(i) * .pi / 4
                var ray = Path()
                ray.move(to: CGPoint(x: center.x + cos(angle) * inner,
                                     y: center.y + sin(angle) * inner))
                ray.addLine(to: CGPoint(x: center.x + cos(angle) * outer,
                                        y: center.y + sin(angle) * outer))
                ctx.stroke(ray, with: .color(color),
                           style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: 下一集（画布 22:41：20×20，三角 8×12 @(4,4) 实心 + 竖线 2.2×13 r1 @(14,3.5)）

struct OverlayNextGlyph: View {
    var size: CGFloat = 20
    var color: Color = .white

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 20
            var tri = Path()
            tri.move(to: CGPoint(x: 4 * s, y: 4 * s))
            tri.addLine(to: CGPoint(x: 12 * s, y: 10 * s))
            tri.addLine(to: CGPoint(x: 4 * s, y: 16 * s))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(color))
            let bar = CGRect(x: 14 * s, y: 3.5 * s, width: 2.2 * s, height: 13 * s)
            ctx.fill(Path(roundedRect: bar, cornerRadius: 1 * s), with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

// MARK: 展开箭头（画布 2:132：14×14 内 7.875×3.94 的 V 形 @(3.06,4.81)，描边 1.4）

struct OverlayChevronGlyph: View {
    var size: CGFloat = 14
    var color: Color = DWColor.overlayInk
    /// true = 朝上（胶囊里是朝上的 V，暗示面板从下方升起）
    var pointsUp: Bool = true

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 14
            let stroke = 1.4 * s
            var v = Path()
            if pointsUp {
                v.move(to: CGPoint(x: 3.0625 * s, y: 8.75 * s))
                v.addLine(to: CGPoint(x: (3.0625 + 3.9375) * s, y: 4.8125 * s))
                v.addLine(to: CGPoint(x: (3.0625 + 7.875) * s, y: 8.75 * s))
            } else {
                v.move(to: CGPoint(x: 3.0625 * s, y: 4.8125 * s))
                v.addLine(to: CGPoint(x: (3.0625 + 3.9375) * s, y: 8.75 * s))
                v.addLine(to: CGPoint(x: (3.0625 + 7.875) * s, y: 4.8125 * s))
            }
            ctx.stroke(v, with: .color(color),
                       style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

// MARK: 星形收藏（横屏 22:61：18×18 内 14×13.4 实心星 @(2,1.8)）

/// 五角星：画布给的是一颗实心星；用正五角星路径按 14×13.4 的包围盒绘制。
struct OverlayStarGlyph: View {
    var size: CGFloat = 18
    var color: Color = .white

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 18
            let rect = CGRect(x: 2 * s, y: 1.8 * s, width: 14 * s, height: 13.4 * s)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outerR = rect.width / 2
            let innerR = outerR * 0.382   // 正五角星的内外半径比
            var star = Path()
            for i in 0..<10 {
                let r = i.isMultiple(of: 2) ? outerR : innerR
                // 起点朝上（-90°），每 36° 一个顶点
                let angle = -Double.pi / 2 + Double(i) * .pi / 5
                let p = CGPoint(x: center.x + cos(angle) * r,
                                y: center.y + sin(angle) * r * (rect.height / rect.width))
                i == 0 ? star.move(to: p) : star.addLine(to: p)
            }
            star.closeSubpath()
            ctx.fill(star, with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

// MARK: 心形点赞（横屏 22:50：18×18 内 14×12 实心心 @(2,3.5)）

struct OverlayHeartGlyph: View {
    var size: CGFloat = 18
    var color: Color = .white

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 18
            let w = 14 * s, h = 12 * s
            let x = 2 * s, y = 3.5 * s
            var heart = Path()
            // 两瓣圆弧 + 下端尖角
            heart.move(to: CGPoint(x: x + w / 2, y: y + h))
            heart.addCurve(to: CGPoint(x: x, y: y + h * 0.32),
                           control1: CGPoint(x: x + w * 0.22, y: y + h * 0.78),
                           control2: CGPoint(x: x, y: y + h * 0.58))
            heart.addCurve(to: CGPoint(x: x + w / 2, y: y + h * 0.22),
                           control1: CGPoint(x: x, y: y + h * 0.02),
                           control2: CGPoint(x: x + w * 0.34, y: y - h * 0.06))
            heart.addCurve(to: CGPoint(x: x + w, y: y + h * 0.32),
                           control1: CGPoint(x: x + w * 0.66, y: y - h * 0.06),
                           control2: CGPoint(x: x + w, y: y + h * 0.02))
            heart.addCurve(to: CGPoint(x: x + w / 2, y: y + h),
                           control1: CGPoint(x: x + w, y: y + h * 0.58),
                           control2: CGPoint(x: x + w * 0.78, y: y + h * 0.78))
            heart.closeSubpath()
            ctx.fill(heart, with: .color(color))
        }
        .frame(width: size, height: size)
    }
}
