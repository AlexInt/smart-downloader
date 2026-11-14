import CoreGraphics

/// 滚动收起联动的纯判定（Service：无 IO、无 UI 依赖、删掉 UI 仍成立）。
///
/// 背景（用户 2026-11-14）：竖屏里地址栏 52 + 快捷站点 44 + 底部工具条 54 + tab bar 62
/// 一共 212pt，网页可视区只剩 569pt。方案 = 网页**下滑**收起、**上滑 / 回到顶部**展开
/// （Safari 同行为），收起后可视区 569 → 719pt。
///
/// 判定只吃「方向 + 当前滚动位置」：阈值与节流在脚本侧
/// （`ScrollCollapseScript`：单次位移 ≥ 12px、120ms 节流），
/// 这样惯性尾巴的微抖不会让栏位来回抽动；这里只做状态机。
enum ScrollCollapsePolicy {

    /// 滚动方向（脚本上报的原始意图）
    enum Direction: String {
        case down
        case up
    }

    /// 回到顶部这条线以内一律展开：换页 / 锚点跳转后页面都从顶部开始，此时必须有地址栏
    static let topReset: CGFloat = 8

    /// 解析新状态。`nil` = 不该变（方向与当前状态一致，或已在顶部本来就该展开）。
    static func resolve(collapsed: Bool, direction: Direction, top: CGFloat) -> Bool? {
        if top <= topReset { return collapsed ? false : nil }
        switch direction {
        case .down: return collapsed ? nil : true
        case .up:   return collapsed ? false : nil
        }
    }
}
