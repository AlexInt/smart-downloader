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

// MARK: - Design Tokens · 纸本轨（「我的」页，画布 19:63 / 24:43）
//
// 与墨本轨（详情页/播放页的深底）并行的第二套视觉：「我的」页是域级浅色页，
// 色值全部来自画布节点实读，勿凭目测调整。
extension DWColor {
    /// 宣纸底
    static let paper         = Color(hex: "#F2F0EA")
    /// 墨字（标题/选中态）
    static let paperInk      = Color(hex: "#1C1E1F")
    /// 次级墨（未选中 tab / 进度文案）
    static let paperInkSub   = Color(hex: "#8C9190")
    /// 图标与辅助操作文字（夜间/设置/筛选/编辑）
    static let paperIcon     = Color(hex: "#5A5F60")
    /// 朱砂（选中短线 / 选中胶囊态语义色）
    static let paperCinnabar = Color(hex: "#A05243")
    /// 胶囊选中底
    static let paperChipSel  = Color(hex: "#E2DED5")
    /// 胶囊未选底
    static let paperChipIdle = Color(hex: "#EAE7DF")
    /// 纸本轨栏底顶部的发丝分隔线（与白底网页交界处才不会糊成一片）
    static let paperHairline = Color(hex: "#E0DBD1")
    /// 导航栏下方分隔线（画布 24:67，比组间细线深一档）
    static let paperDivider  = Color(hex: "#DDD9D0")
    /// 分组之间的细线（画布 30:11 / 30:19）
    static let paperRule     = Color(hex: "#E4E0D6")
    /// 最弱的一档线：行尾箭头（30:9）、未选圆圈、页脚版本号（30:37）
    static let paperLineIdle = Color(hex: "#B9BCB9")
    /// 开关关闭态轨道（画布 30:16）；开启态复用朱砂 `paperCinnabar`
    static let paperSwitchOff = Color(hex: "#C9CCC9")
    /// 开关钮 / 勾选反白（画布 30:17）
    static let paperKnob     = Color(hex: "#F7F5F0")

    // 浏览页 / 下载页（画布 22:284 / 2:2）新增的四档
    /// 输入框与站点胶囊底（22:297 / 22:305，比纸底深一档的"纸面凹槽"）
    static let paperField     = Color(hex: "#E7E4DE")
    /// 输入框与站点胶囊描边（22:297 stroke #C2BFB8；画布给 0.8/0.9 不透明度，用时再压）
    static let paperFieldLine = Color(hex: "#C2BFB8")
    /// 网页内容区兜底底色（22:321，比纸底深一档）
    static let paperCanvas    = Color(hex: "#EDEAE2")
    /// 进度轨道 / 分段下的细线（2:37 / 2:45 / 19:303）
    static let paperTrack     = Color(hex: "#C4C7C3")
    /// 进度条已下载部分（2:46，比 shell 更沉的墨）
    static let paperTrackFill = Color(hex: "#35393B")
    /// 最弱一档说明文字（22:326 占位说明 / 前进禁用态 22:331）
    static let paperFaint     = Color(hex: "#A2A6AD")

    // 剧集页海报占位（2026-11-14 纸本化）：纸本里没有紫色渐变可用，
    // 无封面时给一块"墨"——白剧名压在底部 scrim 上仍然立得住。
    /// 墨块渐变三档（原 posterTop/Mid/Bottom 的纸本替身）
    static let paperInkTop    = Color(hex: "#3C4042")
    static let paperInkMid    = Color(hex: "#24282A")
    static let paperInkBottom = Color(hex: "#141719")
    /// 单色墨板：封面加载中 / 加载失败 / 无 URL 时的海报底
    static let paperInkPlate  = Color(hex: "#1A1D1E")
}

// MARK: - Design Tokens · 播放器叠层（画布 2:11 竖屏 / 22:1 横屏 / 22:77 抽屉）
//
// 播放页是墨本轨：叠层文字统一用「纸白」#E8E6DF 而非纯白，与纸本轨同一色温；
// 进度已播段与当前点用朱砂 #A05243（与纸本轨同一个语义色，两轨共享）。
extension DWColor {
    /// 叠层主文字 / 图标（返回、集数、倍速、更多、材质描边）
    static let overlayInk       = Color(hex: "#E8E6DF")
    /// 叠层弱文字（右侧互动数值 23.7万 / 热评）
    static let overlayInkSub    = Color(hex: "#C4C7C3")
    /// 朱砂当前点与已播段（画布 2:129 / 2:128）
    static let overlayCinnabar  = Color(hex: "#A05243")
    /// 选集胶囊底（画布 2:130 #22262A）
    static let overlayChip      = Color(hex: "#22262A")
    /// 全集进度的未播轨道（画布 2:127，纸白满不透明——轨道本身就是一根细白线）
    static let overlayTrack     = Color(hex: "#E8E6DF")
    /// 横屏半透明圆角方钮底（画布 22:31 / 22:36：#8C9190 @ 0.42）
    static let overlayButton    = Color(hex: "#8C9190")
    /// 倍速抽屉底（画布 22:77 #1C1E1F）
    static let ratePanel        = Color(hex: "#1C1E1F")
    /// 倍速抽屉选项文字（画布 22:79 #E8E6DF）
    static let rateText         = Color(hex: "#E8E6DF")
    /// 倍速抽屉选中项文字（画布 22:84 #F2F0EA）
    static let rateTextSelected = Color(hex: "#F2F0EA")
    /// 倍速抽屉选中行底（画布 22:83 #35393B）
    static let rateRowSelected  = Color(hex: "#35393B")
    /// 选集抽屉底（画布 22:78 #101214）
    static let episodePanel     = Color(hex: "#101214")
    /// 选集格子底（画布 22:92 #25282B）
    static let episodeCell      = Color(hex: "#25282B")
    /// 选集当前集格子底（画布 22:98 #2A2422）与描边（#A05142）
    static let episodeCellCurrent = Color(hex: "#2A2422")
    static let episodeCellStroke  = Color(hex: "#A05142")
}

// MARK: - Design Tokens · 底部标签栏（画布 19:225 / 22:157）
//
// 栏底跟随所在页的轨：浏览/下载页是墨本深底，栏也压墨，图标与文字转纸白；
// 「我的」页是纸本，栏同纸，选中用墨字 + 朱砂点。两轨只有这三个角色色不同，
// 几何（图标 22 / 文字 fs10 / 朱砂点 4×4）完全一致。
extension DWColor {
    /// 墨本轨：栏底（与 DownloadsView 的页面底色同一值，栏与页无缝）
    static let barInk         = background
    /// 墨本轨：选中图标 / 文字（纸白，不用纯白，与纸本轨同一色温）
    static let barInkSelected = Color(hex: "#EDEAE2")
    /// 墨本轨：未选中图标 / 文字
    static let barInkIdle     = Color(hex: "#6F7576")
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

    /// 纸本轨衬线字体：设计稿「我的」页标题/剧名用 Noto Serif SC（宋体气质）。
    /// 未内置字体时退回系统衬线（中文为宋体-简），与画布的衬线感一致。
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        useBundledFonts
            ? .custom("Noto Serif SC", size: size).weight(weight)
            : .system(size: size, weight: weight, design: .serif)
    }
}

enum DWLayout {
    /// 设计画幅，仅作等比缩放基准；容器不写死此尺寸。
    static let designWidth: CGFloat = 390
    static let designHeight: CGFloat = 840
    /// 左右安全边距（「我的」/设置页，画布 19:63 / 24:43）
    static let edge: CGFloat = 20
    /// 浏览页与下载页的左右安全边距（画布 22:284 地址栏行 / 2:2 内容区都是 22）
    static let pageEdge: CGFloat = 22
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
