import UIKit

// MARK: - 键盘可见性统一入口（Service，系统能力域）

/// 全 App 共用的键盘显隐状态：**只回答「键盘现在是否遮住屏幕底部」**，不碰任何 UI。
///
/// 存在理由（用户实报 2026-11-14）：自定义 tab bar 是 `safeAreaInset(edge: .bottom)` 注入的，
/// 键盘一弹，系统把底部安全区顶上来，tab bar 就被顶到**键盘上方**——既挡住网页内容，
/// 又和网页自己的底部工具条一起把可用高度吃掉两层。行业做法（Safari / 抖音 / 小红书）
/// 是键盘期间收起底部栏，把竖直空间全让给输入区。
///
/// 主线程约定：UIKit 键盘通知默认在主线程投递，回调整体在主线程执行；
/// 订阅方在 View 的 `onAppear` 里挂、`onDisappear` 里用返回的闭包摘掉。
final class KeyboardObserver {
    static let shared = KeyboardObserver()

    private(set) var isVisible = false
    private var handlers: [UUID: (Bool) -> Void] = [:]
    private var tokens: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardWillChangeFrameNotification
        ]
        for name in names {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.handle(note)
            })
        }
    }

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// 订阅键盘显隐；返回的闭包用于取消订阅（订阅方 deinit / onDisappear 时调用）
    @discardableResult
    func observe(_ handler: @escaping (Bool) -> Void) -> () -> Void {
        let id = UUID()
        handlers[id] = handler
        return { [weak self] in self?.handlers[id] = nil }
    }

    private func handle(_ note: Notification) {
        // keyboardFrameEndUserInfoKey 给出结束时的窗口坐标：光看高度不够——
        // 交互式下滑收起（UIScrollView.keyboardDismissMode = .interactive）时键盘是
        // 整体移出屏幕、高度仍是全高，必须按 minY 是否还在屏内判定
        var height: CGFloat = 0
        var offScreen = false
        if let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            height = frame.height
            offScreen = screenHeight > 0 && frame.minY >= screenHeight - 1
        }
        let next: Bool
        switch note.name {
        case UIResponder.keyboardWillHideNotification:
            next = false
        default:
            next = height > 0 && !offScreen
        }
        guard next != isVisible else { return }
        isVisible = next
        print("UI_DBG keyboard \(next ? "show" : "hide") h=\(Int(height)) subscribers=\(handlers.count)")
        // 快照遍历：回调里可能取消订阅（自己把自己摘掉），不能边遍历边改字典
        for (_, handler) in Array(handlers) { handler(next) }
    }

    /// 主屏高度（键盘 frame 用的是屏幕坐标）：取当前活跃 windowScene 的坐标系。
    /// `UIWindowScene.coordinateSpace` 在 iOS 26 已废弃，改用 `effectiveGeometry.coordinateSpace`
    ///（iOS 26 SDK 提示：Use effectiveGeometry.coordinateSpace instead）；工程最低版本就是 26.0，
    /// 不需要 @available 分支。取不到 scene 时返回 0 —— 调用处据此跳过出屏判定
    ///（键盘离屏也会收到 willHide，功能不受影响）。
    private var screenHeight: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.effectiveGeometry.coordinateSpace.bounds.height ?? 0
    }
}
