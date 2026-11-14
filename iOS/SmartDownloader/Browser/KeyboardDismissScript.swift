import Foundation

/// 键盘收起触发器（WKUserScript 注入，与 SnifferScript / AdCleanerScript 同一安装模式）。
///
/// 需求（用户 2026-11-14）：键盘出现时，滑动网页就该把键盘带走（Safari 行为）。
///
/// 为什么不靠 `WKWebView.scrollView.keyboardDismissMode`：它只在**文档本身滚动**时生效。
/// 视频站多为 Nuxt SPA，正文在内部容器里滚动（`overflow:auto` 的 div），拖拽根本不动
/// webView.scrollView，系统不会收键盘（真机实证：设了 `.interactive` 后日志里连
/// `UI_DBG keyboard hide` 都没有）。所以这里在页面侧监听手势：
///
///  - `scroll`（**捕获阶段**，内部容器滚动不冒泡但捕获阶段能拿到）→ 有可编辑元素聚焦
///    且当前正被手指拖着（`touching`）才上报。只看「手指压着期间」的滚动是关键：
///    聚焦后 WebKit 自动把输入框滚进可视区也会触发 scroll，那属于程序滚动，不能收键盘。
///  - `touchmove` 兜底：部分站点用 transform 做虚拟滚动/根本不出 scroll 事件。
///    起点落在输入框内部的拖动（选文字 / 拖光标）一律不算。
///  - 聚焦后 700ms 内整段静默：躲开「聚焦 → 自动滚动 → 判成滑动」的误触。
///
/// 原生侧收到 `keyboardDismiss` 后 resignFirstResponder，日志 `BROWSER: keyboardDismiss from <kind>`。
enum KeyboardDismissScript {
    static let source = #"""
    (function () {
      if (window.__dwKbDismissLoaded) return;
      window.__dwKbDismissLoaded = true;

      var FOCUS_GUARD_MS = 700;
      var focusAt = 0;
      var touching = false;
      var touchedInsideEditable = false;
      var reportedThisTouch = false;
      var touchStartY = 0;
      var last = 0;

      function editable(el) {
        if (!el) return false;
        var tag = (el.tagName || '').toUpperCase();
        return tag === 'INPUT' || tag === 'TEXTAREA' || el.isContentEditable === true;
      }

      // 上报给原生。**这里不判断「网页里有没有输入框聚焦」**——
      // 地址栏那种原生键盘完全不经过网页（document.activeElement 是 body），
      // 那样判断会把原生键盘场景全丢掉（真机实证）。键盘到底在不在屏上由原生
      // 侧查 KeyboardObserver 决定，无键盘时它直接丢弃，成本可忽略。
      function report(kind) {
        if (Date.now() - focusAt < FOCUS_GUARD_MS) return;
        var now = Date.now();
        if (now - last < 300) return;      // 节流：一次拖动只报一条
        last = now;
        try {
          window.webkit.messageHandlers.keyboardDismiss.postMessage(kind);
        } catch (e) {}
      }

      document.addEventListener('focusin', function () { focusAt = Date.now(); }, true);

      window.addEventListener('touchstart', function (e) {
        touching = true;
        reportedThisTouch = false;
        // 起手就在输入框/可编辑区里 → 本次触摸大概率是拖光标、选文字，整段不报
        touchedInsideEditable = editable(e.target);
        if (e.touches && e.touches.length === 1) touchStartY = e.touches[0].clientY;
      }, { passive: true, capture: true });

      window.addEventListener('touchend', function () { touching = false; }, { passive: true, capture: true });
      window.addEventListener('touchcancel', function () { touching = false; }, { passive: true, capture: true });

      // 捕获阶段：内部滚动容器的 scroll 不冒泡，但捕获阶段能拿到
      window.addEventListener('scroll', function () {
        if (!touching) return;             // 只要手指正在拖（排除自动滚入可视区）
        if (touchedInsideEditable) return;
        report('scroll');
      }, true);

      // 兜底：transform 虚拟滚动等不出 scroll 的场景；每次触摸段只报一条
      window.addEventListener('touchmove', function (e) {
        if (reportedThisTouch || touchedInsideEditable) return;
        if (!e.touches || !e.touches.length) return;
        if (Math.abs(e.touches[0].clientY - touchStartY) < 12) return;
        reportedThisTouch = true;
        report('touchmove');
      }, { passive: true, capture: true });
    })();
    """#
}
