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
      var touchStartY = 0;
      var last = 0;

      function editable(el) {
        if (!el) return false;
        var tag = (el.tagName || '').toUpperCase();
        return tag === 'INPUT' || tag === 'TEXTAREA' || el.isContentEditable === true;
      }

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
        if (!e.touches || e.touches.length !== 1) return;
        touching = true;
        touchStartY = e.touches[0].clientY;
      }, { passive: true, capture: true });

      window.addEventListener('touchend', function () { touching = false; }, { passive: true, capture: true });
      window.addEventListener('touchcancel', function () { touching = false; }, { passive: true, capture: true });

      // 捕获阶段：内部滚动容器的 scroll 不冒泡，但捕获阶段能拿到
      window.addEventListener('scroll', function () {
        if (!touching) return;             // 只要手指正在拖（排除自动滚入可视区）
        if (!editable(document.activeElement)) return;
        report('scroll');
      }, true);

      // 兜底：transform 虚拟滚动等不出 scroll 的场景；输入框内部起手不算
      window.addEventListener('touchmove', function (e) {
        if (!editable(document.activeElement)) return;
        if (!e.touches || !e.touches.length) return;
        if (editable(e.target)) return;    // 在输入框里拖光标 / 选字，不收键盘
        if (Math.abs(e.touches[0].clientY - touchStartY) < 12) return;
        report('touchmove');
      }, { passive: true, capture: true });
    })();
    """#
}
