import SwiftUI

// MARK: - Hex 颜色

extension Color {
    /// 设计稿色值以 #RRGGBB 记录，便于与画布逐项核对。
    init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue:  Double(value & 0xFF) / 255
        )
    }
}

// MARK: - Design Tokens · DramaWave 中文版（紫）

enum DWColor {
    // 基础
    static let background   = Color(hex: "#0A0A0F")
    static let surface      = Color(hex: "#16161F")
    static let primary      = Color(hex: "#FF5A5F")
    static let gold         = Color(hex: "#F5C451")

    // 文字
    static let textPrimary  = Color.white
    static let textBody     = Color(hex: "#E2E2E8")
    static let textMuted    = Color(hex: "#C9C9D2")
    static let textHint     = Color(hex: "#9A9AA5")
    static let textTime     = Color(hex: "#B5B5BE")
    static let textSwipe    = Color(hex: "#C9B98A")

    // 紫色版画面（VideoBg 三色标，top → bottom）
    static let videoTop     = Color(hex: "#16101F")
    static let videoMid     = Color(hex: "#2E1530")
    static let videoBottom  = background

    // 中央打光（SceneGlow 径向两色标）
    static let glowCenter   = Color(hex: "#F28C73")
    static let glowEdge     = Color(hex: "#994073")

    // 头像渐变
    static let avatarTop    = Color(hex: "#7C3AED")
    static let avatarBottom = Color(hex: "#DB2777")

    // 剧集详情页（drama-detail.html，390×840）专用色，屏内取值与播放页同一套设计系统
    static let posterTop       = Color(hex: "#2A1240")
    static let posterMid       = Color(hex: "#6B2154")
    static let posterBottom    = Color(hex: "#100A1A")
    static let ctaEnd          = Color(hex: "#FF8A5B")
    static let coverPlaceholder = Color(hex: "#1A1A22")
    static let placeholderIcon = Color(hex: "#5A5A68")
    static let tagFill         = Color.white.opacity(0.16)
    static let divider         = Color.white.opacity(0.08)
}

enum DWFont {
    /// 设计稿字体：Inter（西文）/ Noto Sans SC（中文）。
    /// 把两款字体文件加入工程并在 Info.plist 注册后改为 true，即可 1:1 还原；
    /// 默认 false 使用系统字体（中文为苹方），开箱即可编译运行。
    static let useBundledFonts = false

    /// 字重对应：Regular 400 / Medium 500 / SemiBold 600 / Bold 700 / ExtraBold 800
    static func cn(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        useBundledFonts
            ? .custom("Noto Sans SC", size: size).weight(weight)
            : .system(size: size, weight: weight)
    }

    static func en(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        useBundledFonts
            ? .custom("Inter", size: size).weight(weight)
            : .system(size: size, weight: weight)
    }
}

enum DWLayout {
    /// 设计画幅，仅作等比缩放基准；容器不写死此尺寸。
    static let designWidth: CGFloat = 390
    static let designHeight: CGFloat = 840
    /// 左右安全边距
    static let edge: CGFloat = 20
}

enum DWRadius {
    static let screen: CGFloat = 46
    static let chip: CGFloat = 13
    static let subtitle: CGFloat = 8
    static let progress: CGFloat = 2
    static let avatar: CGFloat = 24
}

// MARK: - 设计稿坐标 → SwiftUI

/// 把设计稿的左上角坐标 (x, y, w, h) 精确映射为 SwiftUI 布局。
/// 所有数值均来自设计文件的节点读取结果，勿凭目测调整。
struct DesignFrame: ViewModifier {
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    let alignment: Alignment

    func body(content: Content) -> some View {
        content
            .frame(width: w, height: h, alignment: alignment)
            .position(x: x + w / 2, y: y + h / 2)
    }
}

extension View {
    func designFrame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                     alignment: Alignment = .center) -> some View {
        modifier(DesignFrame(x: x, y: y, w: w, h: h, alignment: alignment))
    }
}
