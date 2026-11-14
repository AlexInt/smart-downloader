import SwiftUI
import UIKit

/// 自绘导航栏的二级页（`.toolbar(.hidden, for: .navigationBar)`）会把系统的
/// `interactivePopGestureRecognizer` 一并关掉，只剩按钮能返回，右滑返回失效。
/// 这里把系统手势重新接上，并加一道闸：**只在导航栈深度 > 1 时允许起手**——
/// 在栈根起手会弹出根控制器，是这类 hack 最经典的卡死/白屏来源。
///
/// 用法：`SomePushedPage().swipeBackEnabled()`
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false   // 只是个挂载点，不参与命中
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        // 页面刚 push 上来时宿主还没进导航栈，等一拍再取 navigationController
        DispatchQueue.main.async {
            guard let nav = controller.navigationController,
                  let gesture = nav.interactivePopGestureRecognizer else { return }
            gesture.isEnabled = true
            gesture.delegate = PopGestureGate.shared
        }
    }
}

private final class PopGestureGate: NSObject, UIGestureRecognizerDelegate {
    static let shared = PopGestureGate()

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let nav = gestureRecognizer.view as? UINavigationController else { return false }
        return nav.viewControllers.count > 1
    }
}

extension View {
    /// 给隐藏了系统导航栏的二级页恢复右滑返回手势
    func swipeBackEnabled() -> some View {
        background(
            SwipeBackEnabler()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}
