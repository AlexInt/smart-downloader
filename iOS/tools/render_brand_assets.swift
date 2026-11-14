import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 品牌图形渲染器（水墨纸墨双轨）
//
// 记号：墨箭 + 朱砂承线。几何为手工定值，改动后务必按 1024 / 120 / 60 三档目视校验。
//
// 用法（在仓库根执行，直接覆盖 asset catalog 里的图）：
//     swift iOS/tools/render_brand_assets.swift
//
// 产出：
//   AppIcon.appiconset/sd.png        纸底墨箭（universal）
//   AppIcon.appiconset/sd-dark.png   墨底纸箭（dark 外观）
//   AppIcon.appiconset/sd-tinted.png 中性灰（tinted 外观，交系统上色）
//   LaunchLogo.imageset/LaunchLogo-1024.png  透明底墨箭（splash 用）
//
// 注意：图标三档不带 alpha（noneSkipLast），带 alpha 打包会被 App Store 拒。

let paper = CGColor(srgbRed: 0xF2/255, green: 0xF0/255, blue: 0xEA/255, alpha: 1)
let ink   = CGColor(srgbRed: 0x1C/255, green: 0x1E/255, blue: 0x1F/255, alpha: 1)
let inkDeep = CGColor(srgbRed: 0x14/255, green: 0x17/255, blue: 0x1A/255, alpha: 1)
let cinnabar = CGColor(srgbRed: 0xA0/255, green: 0x52/255, blue: 0x43/255, alpha: 1)

/// 确定性伪随机（纸纹用，保证每次生成一致）
struct LCG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0x7FFF_FFFF) / Double(0x7FFF_FFFF)
    }
}

func makeContext(_ w: Int, _ h: Int, alpha: Bool = true) -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                     : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs, bitmapInfo: info)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    // 用「左上角为原点」的坐标书写，最后统一翻转
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func writePNG(_ ctx: CGContext, _ path: String) {
    guard let img = ctx.makeImage() else { print("ERR makeImage"); return }
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        print("ERR dest"); return
    }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote", path)
}

/// 纸纹：极轻的纤维噪点 + 暖色晕影
func drawPaperGrain(_ ctx: CGContext, size: CGFloat, strength: Double) {
    var rng = LCG(state: 20261114)
    ctx.saveGState()
    for _ in 0..<3400 {
        let x = CGFloat(rng.next()) * size
        let y = CGFloat(rng.next()) * size
        let a = 0.012 + 0.030 * rng.next()
        let w = 1.0 + 2.4 * rng.next()
        ctx.setFillColor(CGColor(srgbRed: 0x1C/255, green: 0x1E/255, blue: 0x1F/255, alpha: a * strength))
        ctx.fill(CGRect(x: x, y: y, width: w, height: w))
    }
    ctx.restoreGState()
}

/// 记号主体：墨箭 + 朱砂承线。arrowColor / lineColor 由调用方决定（浅底用墨、深底用纸白）
func drawMark(_ ctx: CGContext, scale s: CGFloat, dx: CGFloat, dy: CGFloat,
              arrowColor: CGColor, lineColor: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: dx, y: dy)
    ctx.scaleBy(x: s, y: s)

    // ---- 墨箭（圆join描边实现笔锋般的圆角）----
    // 几何：箭杆 92 宽 / 箭头半宽 178 / 箭头深 308；描边 34 使外轮廓再外扩 17 并倒圆
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 460, y: 182))
    p.addLine(to: CGPoint(x: 564, y: 182))
    p.addLine(to: CGPoint(x: 564, y: 430))
    p.addLine(to: CGPoint(x: 717, y: 430))
    p.addQuadCurve(to: CGPoint(x: 512, y: 762), control: CGPoint(x: 552, y: 668))
    p.addQuadCurve(to: CGPoint(x: 307, y: 430), control: CGPoint(x: 472, y: 668))
    p.addLine(to: CGPoint(x: 460, y: 430))
    p.closeSubpath()

    ctx.setFillColor(arrowColor)
    ctx.setStrokeColor(arrowColor)
    ctx.setLineWidth(38)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.addPath(p)
    ctx.drawPath(using: .fillStroke)

    // ---- 朱砂承线 ----
    ctx.setStrokeColor(lineColor)
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 366, y: 830))
    ctx.addLine(to: CGPoint(x: 658, y: 830))
    ctx.strokePath()

    ctx.restoreGState()
}

// MARK: - 1. App Icon（浅色：纸底墨箭）

func renderIcon(bg: CGColor, arrow: CGColor, line: CGColor, grain: Double, path: String) {
    let ctx = makeContext(1024, 1024, alpha: false)
    ctx.setFillColor(bg)
    ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    if grain > 0 { drawPaperGrain(ctx, size: 1024, strength: grain) }
    drawMark(ctx, scale: 1, dx: 0, dy: 0, arrowColor: arrow, lineColor: line)
    writePNG(ctx, path)
}

renderIcon(bg: paper, arrow: ink, line: cinnabar, grain: 1.0, path: "iOS/SmartDownloader/Media.xcassets/AppIcon.appiconset/sd.png")
renderIcon(bg: inkDeep, arrow: CGColor(srgbRed: 0xF2/255, green: 0xF0/255, blue: 0xEA/255, alpha: 1),
           line: cinnabar, grain: 1.4, path: "iOS/SmartDownloader/Media.xcassets/AppIcon.appiconset/sd-dark.png")

// 着色版（tinted）：交给系统上色，故为中性灰
let tintBg = CGColor(srgbRed: 0xE9/255, green: 0xE9/255, blue: 0xE9/255, alpha: 1)
let tintFg = CGColor(srgbRed: 0x30/255, green: 0x30/255, blue: 0x30/255, alpha: 1)
renderIcon(bg: tintBg, arrow: tintFg, line: tintFg, grain: 0, path: "iOS/SmartDownloader/Media.xcassets/AppIcon.appiconset/sd-tinted.png")

// MARK: - 2. LaunchLogo（透明底，墨箭 + 朱砂承线）

func renderLaunchLogo(_ path: String) {
    let ctx = makeContext(1024, 1024)
    ctx.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    // 记号在 1024 画布内占比 0.72，四周留白供 splash 呼吸空间
    drawMark(ctx, scale: 0.86, dx: 512 - 512 * 0.86, dy: 512 - 512 * 0.86,
             arrowColor: ink, lineColor: cinnabar)
    writePNG(ctx, path)
}
renderLaunchLogo("iOS/SmartDownloader/Media.xcassets/LaunchLogo.imageset/LaunchLogo-1024.png")

// 系统启动屏已改为颜色资源 LaunchBackground（UILaunchScreen → UIColorName），
// 不再是整屏 PNG：固定分辨率铺不满所有机型，边缘会露白。故这里不再渲染启动图。
