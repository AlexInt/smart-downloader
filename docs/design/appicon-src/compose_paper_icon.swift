import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// 用设计稿的分层导出机械合成一张「整幅纸」App 图标：不重画任何图形，只按坐标摆层。
//
// ⚠️ 这不是「在代码里画图标」。三个图层 layer-*.png 全部由 Ardot 设计稿
//    https://ardot.tencent.com/file/746972112461422 的节点 19:364 / 19:367 / 19:368
//    用 export_nodes(scale=2) 原样导出；本脚本只做「放大 + 摆放 + 合成为不带 alpha 的 PNG」。
//    改图请改设计稿再重导，不要在这里动路径数据。
//
// 画布坐标来自画布节点（设计稿 1024 基准，纸面板 19:363 = (152,152) 720×720 r160）：
//   19:364 一笔墨·主体 (300,270) 430×430
//   19:367 朱砂小印   (740,740)  72×72
//   19:368 印文       (754,750)  40×57
// 图层按 scale=2 导出，故绘制尺寸用设计稿原值即等比缩回 1×。
//
// 用法：swift compose_paper_icon.swift <out.png> [zoom|sealEdge|design]
// 参数 2 = 模式：
//   zoom      （默认，即当前采用）把 720² 纸面板整块放大铺满 1024²，所有元素随纸等比放大
//                     —— 印与记号、印与纸边的关系和设计稿完全一致
//   sealEdge  印章距新纸边仍取 60（把纸面 872→1024 的增量全让给记号，印贴边）
//                     ✗ 已弃用：方印右下角会压在系统圆角遮罩弧线外，被切掉一角
//   design    原样 1:1 摆层（印离角 212，最保守）

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "zoom"

// 图层与本脚本同目录，从哪个 cwd 跑都能找到
let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

let paperColor = CGColor(srgbRed: 0xF2/255, green: 0xF0/255, blue: 0xEA/255, alpha: 1)
let canvas = 1024.0

func load(_ name: String) -> CGImage {
    let url = here.appendingPathComponent(name)
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}

let mark = load("layer-mark.png")         // 860×860
let seal = load("layer-seal.png")         // 144×144
let sealText = load("layer-sealtext.png") // 80×114

let intCanvas = Int(canvas)
let ctx = CGContext(data: nil, width: intCanvas, height: intCanvas, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    // 图标不带 alpha 通道（带 alpha 打包会被 App Store 拒）
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high
ctx.setFillColor(paperColor)
ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))

/// 以设计稿的「左上角原点」坐标把图层画上去（CoreGraphics 原点在左下，这里换一次）
func draw(_ img: CGImage, _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
    ctx.draw(img, in: CGRect(x: x, y: canvas - (y + h), width: w, height: h))
}

// 设计稿纸面板
let panelOrigin = 152.0
let panelSize = 720.0

switch mode {
case "zoom":
    // 纸面板 → 整幅画布，元素全部跟随纸面等比放大
    let k = canvas / panelSize
    func m(_ v: Double) -> Double { (v - panelOrigin) * k }
    draw(mark, m(300), m(270), 430 * k, 430 * k)
    draw(seal, m(740), m(740), 72 * k, 72 * k)
    draw(sealText, m(754), m(750), 40 * k, 57 * k)
    print("paper 720→1024, k=\(k)")

case "sealEdge":
    draw(mark, 300, 270, 430, 430)
    let sealX = canvas - 60 - 72
    let sealY = canvas - 60 - 72
    draw(seal, sealX, sealY, 72, 72)
    draw(sealText, sealX + 14, sealY + 10, 40, 57)

default:
    draw(mark, 300, 270, 430, 430)
    draw(seal, 740, 740, 72, 72)
    draw(sealText, 754, 750, 40, 57)
}

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote", out, "(\(mode))")
