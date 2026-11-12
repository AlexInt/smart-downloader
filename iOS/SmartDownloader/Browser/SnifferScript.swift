import Foundation

/// 浏览页 m3u8 嗅探脚本（移植自 mac_app/sniffer.js，去掉悬浮工具栏，改走 messageHandlers 回传）。
/// 独立成文件：WebViewContainer 只负责注入，不再把 60 行 JS 埋在 View 文件里。
enum SnifferScript {
    static let source = #"""
    (function () {
      if (window.__m3u8SnifferLoaded) return;
      window.__m3u8SnifferLoaded = true;

      var seen = {};

      function isM3u8(u) {
        try { return /\.m3u8(\?|#|$)/i.test(String(u)); } catch (e) { return false; }
      }

      function record(u) {
        if (!u) return;
        u = String(u);
        if (!isM3u8(u)) return;
        if (seen[u]) return;
        seen[u] = 1;
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sniffer) {
            window.webkit.messageHandlers.sniffer.postMessage(u);
          }
        } catch (e) {}
      }

      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        try { record(url); } catch (e) {}
        return origOpen.apply(this, arguments);
      };

      if (window.fetch) {
        var origFetch = window.fetch;
        window.fetch = function (input) {
          try { record(typeof input === 'string' ? input : (input && input.url)); } catch (e) {}
          return origFetch.apply(this, arguments);
        };
      }

      try {
        var entries = performance.getEntriesByType('resource');
        for (var i = 0; i < entries.length; i++) record(entries[i].name);
      } catch (e) {}

      function scanDom() {
        try {
          var nodes = document.querySelectorAll('video, source');
          for (var i = 0; i < nodes.length; i++) {
            var s = nodes[i].src || nodes[i].getAttribute('src');
            if (s) record(s);
          }
        } catch (e) {}
      }
      scanDom();
      try {
        new MutationObserver(scanDom).observe(document.documentElement, { childList: true, subtree: true });
      } catch (e) {}
    })();
    """#
}
