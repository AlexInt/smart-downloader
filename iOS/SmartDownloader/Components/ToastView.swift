import SwiftUI

/// 全局通用轻提示（toast）。
/// 与任何业务模块、页面坐标系解耦：只负责把一条消息渲染成半透明胶囊，
/// 显隐由 message 决定，位置由调用方决定（也可用 `.toast()` 用默认位置）。
struct ToastView: View {
    let message: String?

    var body: some View {
        Text(message ?? "")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.black.opacity(0.72), in: Capsule())
            .opacity(message == nil ? 0 : 1)
            .animation(.easeInOut(duration: 0.2), value: message)
            .allowsHitTesting(false)
            .accessibilityHidden(message == nil)
    }
}

extension View {
    /// 在视图上叠加 toast（默认顶部居中）；需要精确控制位置时直接使用 ToastView。
    func toast(_ message: String?,
               alignment: Alignment = .top,
               edgePadding: CGFloat = 60) -> some View {
        overlay(alignment: alignment) {
            ToastView(message: message)
                .padding(edgePadding)
        }
    }
}
