import Foundation

/// 浏览页广告弹窗清理脚本（WKUserScript 注入，与 SnifferScript 同一安装模式）。
/// 三层策略，全部通用词表、不针对任何站点（AGENTS：代码内不硬编码站点）：
///  1. 选择器直删：常见广告类名/id 词表（含拼音 tanchuang/guanggao、gg 等国内站惯用），
///     含 <video> 的元素一律不删（防误伤播放器）；
///  2. 空浮层启发式：fixed + 近全屏 + 无有效内容（无表单/大图/文字）的「点击劫持层」，
///     首见只记 candidate 并打时间戳，2s 后仍空才删——Nuxt 水合先挂空遮罩再填内容的
///     场景（登录框）不会被误杀；
///  3. 时序：atDocumentStart 注入 + MutationObserver（150ms 去抖）兜 SPA 路由切换，
///     2s 定时全扫兜样式翻转型弹窗。
/// WKWebView 的 console.log 真机不进 Xcode 控制台，所有删除/候选都经
/// messageHandlers.adClean 回传原生打印（BROWSER: adClean ...），靠日志调优词表。
enum AdCleanerScript {
    static let source = #"""
    (function () {
      if (window.__dwAdCleanLoaded) return;
      window.__dwAdCleanLoaded = true;

      var SELECTORS = [
        '.ad-popup', '.ad-overlay', '.ad-modal', '.ad-banner', '.ad-box', '.ad-wrap',
        '.ad-wrapper', '.ad-container', '.ad-floating', '.ad-float', '.ad-fixed',
        '.adsbygoogle', 'ins.adsbygoogle',
        '[class~="ad"]', '[class~="ads"]', '[class~="adv"]', '[class~="adsense"]',
        '[class*="advert"]', '[id*="advert"]',
        '[class*="ad-popup"]', '[id*="ad-popup"]', '[class*="popup-ad"]', '[id*="popup-ad"]',
        '[class*="float-ad"]', '[id*="float-ad"]', '[class*="fixed-ad"]', '[class*="ad-fixed"]',
        '[class*="banner-ad"]', '[id*="banner-ad"]', '[class*="adbanner"]', '[id*="adbanner"]',
        '[class*="modal-ad"]', '[id*="modal-ad"]',
        '[class*="promo"]', '[id*="promo"]',
        '[class~="gg"]', '[class*="gg-"]',
        '[class*="tanchuang"]', '[id*="tanchuang"]',
        '[class*="guanggao"]', '[id*="guanggao"]',
        '[class*="app-download"]', '[id*="app-download"]',
        '[class*="download-app"]', '[id*="download-app"]',
        '[class*="open-app"]', '[class*="app-open"]',
        'iframe[src*="googlesyndication"]', 'iframe[src*="doubleclick"]', 'iframe[src*="googleads"]'
      ];

      function sig(el) {
        var id = el.id ? ('#' + el.id) : '';
        var cls = '';
        try {
          if (el.className && typeof el.className === 'string') {
            cls = '.' + el.className.split(/\s+/).slice(0, 3).join('.');
          }
        } catch (e) {}
        return '<' + String(el.tagName).toLowerCase() + id + cls + '>';
      }

      function say(kind, el, how) {
        try {
          var w = window.webkit;
          if (w && w.messageHandlers && w.messageHandlers.adClean) {
            w.messageHandlers.adClean.postMessage(kind + ' ' + sig(el) + ' via ' + how);
          }
        } catch (e) {}
      }

      function hasRealContent(el) {
        try {
          if (el.querySelector('video, input, form, textarea, select')) return true;
          var imgs = el.querySelectorAll('img');
          for (var i = 0; i < imgs.length; i++) {
            var r = imgs[i].getBoundingClientRect();
            if (r.width > 8 && r.height > 8) return true;
          }
          var t = (el.innerText || '').replace(/\s+/g, '');
          if (t.length > 6) return true;
        } catch (e) {}
        return false;
      }

      function sweep() {
        // 1) 选择器直删
        for (var i = 0; i < SELECTORS.length; i++) {
          var nodes;
          try { nodes = document.querySelectorAll(SELECTORS[i]); } catch (e) { continue; }
          for (var j = 0; j < nodes.length; j++) {
            var el = nodes[j];
            try {
              if (!el || !el.parentNode) continue;
              if (el.querySelector('video')) continue;
              el.parentNode.removeChild(el);
              say('removed', el, SELECTORS[i]);
            } catch (e) {}
          }
        }
        // 2) 空浮层启发式（只看 body 直接子节点，成本可控且劫持层几乎都挂在这）
        var vw = window.innerWidth, vh = window.innerHeight;
        var kids;
        try { kids = document.body ? document.body.children : []; } catch (e) { return; }
        var now = Date.now();
        for (var k = 0; k < kids.length; k++) {
          var f = kids[k];
          try {
            var cs = getComputedStyle(f);
            if (cs.position !== 'fixed') continue;
            if (cs.display === 'none' || cs.visibility === 'hidden') continue;
            var r = f.getBoundingClientRect();
            if (r.width < vw * 0.9 || r.height < vh * 0.85) continue;
            var seen = parseInt(f.getAttribute('data-dwseen') || '0', 10);
            if (!seen) {
              f.setAttribute('data-dwseen', String(now));
              say('candidate', f, 'fullsize-fixed(首见,2s后仍空才删)');
              continue;
            }
            if (now - seen < 1800) continue;
            if (hasRealContent(f)) continue;
            f.parentNode.removeChild(f);
            say('removed', f, 'fullsize-fixed(空浮层,存活' + (now - seen) + 'ms)');
          } catch (e) {}
        }
      }

      var pending = 0;
      function schedule() {
        if (pending) return;
        pending = setTimeout(function () { pending = 0; sweep(); }, 150);
      }

      sweep();
      document.addEventListener('DOMContentLoaded', sweep);
      try {
        new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
      } catch (e) {}
      setInterval(sweep, 2000);
    })();
    """#
}
