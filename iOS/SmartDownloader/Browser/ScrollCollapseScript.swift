import Foundation

/// 滚动方向上报（WKUserScript 注入，与 SnifferScript / AdCleanerScript 同一安装模式）。
///
/// 目的（用户 2026-11-14，方案 B）：网页下滑时把「地址栏 52 + 快捷站点 44」与
/// 「底部工具条 54」收起，上滑或回到顶部再展开 —— 竖屏可视区 569 → 719pt。
///
/// 为什么不在原生侧用 `webView.scrollView.contentOffset` 判方向：视频站多为 Nuxt / SPA，
/// 正文在**内部容器**里滚（`overflow:auto` 的 div），拖拽根本不动 `webView.scrollView`
/// —— 与 KeyboardDismissScript 踩的是同一个坑（真机实证）。所以在页面侧用**捕获阶段**
/// 的 scroll 监听拿「到底是谁在滚」，按每个滚动容器各自的上次位置算位移。
///
/// 只上报方向，不做状态：收不收起由原生 `ScrollCollapsePolicy` 判（纯函数）——
/// 页面侧不该知道地址栏长什么样。上报格式 `"down 1234"` / `"up 0"`（方向 + 当前 top）。
///
/// 只装主帧（`forMainFrameOnly: true`）：iframe 里的滚动不该收掉宿主的地址栏。
/// 全程 passive、无 preventDefault，不影响滚动本身；同一次惯性只按 120ms 节流上报。
enum ScrollCollapseScript {
    static let source = #"""
    (function () {
      if (window.__dwScrollCollapseLoaded) return;
      window.__dwScrollCollapseLoaded = true;

      var STEP = 12;        // 单次上报的最小位移（px）：太小会把惯性尾巴判成一串方向
      var THROTTLE = 120;   // 上报节流
      var TOP_RESET = 8;    // 回到这条线以内一律上报 up（原生据此展开）
      var mem = [];         // [{ el, top }]：每个滚动容器各记上一次位置
      var lastAt = 0;

      function post(dir, top, kind) {
        try {
          var w = window.webkit;
          if (w && w.messageHandlers && w.messageHandlers.browserScroll) {
            w.messageHandlers.browserScroll.postMessage(dir + ' ' + Math.round(top) + ' ' + kind);
          }
        } catch (e) {}
      }

      function recFor(el) {
        for (var i = 0; i < mem.length; i++) {
          if (mem[i].el === el) return mem[i];
        }
        var r = { el: el, top: null };
        mem.push(r);
        if (mem.length > 16) mem.shift();   // 页面可能有很多滚动容器，别无限长
        return r;
      }

      // 预置主文档的起点：不在加载完成时先记一次位置，页面里**第一次**滚动会被
      // 「首见只记位置」吞掉（要等第二次事件才有方向），手感上就是「第一下滑了没收起」。
      // 内层容器不做预置（页面里有哪些滚动容器只能等它自己响），
      // 真手指连续滑动的第二、三个事件就能补上，代价可忽略。
      function seed() {
        try {
          var se = document.scrollingElement || document.documentElement;
          if (se) recFor(se).top = se.scrollTop;
          if (document.body) recFor(document.body).top = document.body.scrollTop;
        } catch (e) {}
      }
      seed();
      document.addEventListener('DOMContentLoaded', seed);
      window.addEventListener('load', seed);

      window.addEventListener('scroll', function (ev) {
        try {
          var node = ev.target;
          // 文档滚动时 target 是 document（nodeType 9），换成真正的滚动元素
          if (!node || node.nodeType !== 1) {
            node = document.scrollingElement || document.documentElement;
          }
          if (!node) return;
          var top = node.scrollTop;
          var rec = recFor(node);
          if (rec.top === null) { rec.top = top; return; }   // 首见只记位置，不算位移
          var d = top - rec.top;
          rec.top = top;

          var now = Date.now();
          // 日志用：区分是文档在滚还是某个内层容器在滚（排障时一眼看出是哪种页面结构）
          var kind = (node === document.body ||
                      node === document.documentElement ||
                      node === document.scrollingElement) ? 'doc' : 'inner';
          // 回到顶部：不受阈值限制（滚回顶部通常位移很大，但节流仍要过）
          if (top <= TOP_RESET) {
            if (now - lastAt >= THROTTLE) { lastAt = now; post('up', top, kind); }
            return;
          }
          if (Math.abs(d) < STEP) return;
          if (now - lastAt < THROTTLE) return;
          lastAt = now;
          post(d > 0 ? 'down' : 'up', top, kind);
        } catch (e) {}
      }, { passive: true, capture: true });
    })();
    """#
}
