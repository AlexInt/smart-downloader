import Foundation

/// 浏览页广告弹窗清理脚本（WKUserScript 注入，与 SnifferScript 同一安装模式）。
/// 目标：**用户完全看不到弹窗**，连一帧闪烁都不能有。为此分两路，互相补位：
///
///  A. CSS 预隐藏（零间隙）：类名词表转成 `<style>` 规则（`visibility:hidden !important`
///     + `:not(:has(video))` 保护播放器）。CSS 在节点插入的瞬间就生效，不依赖 JS 执行时机，
///     因此类名命中的广告**从第一帧起就不可见**。
///  B. MutationObserver 同步处理：回调在微任务阶段执行、**早于浏览器绘制**，所以在里面
///     同步隐藏/删除新节点，也不会闪。这里只做「新增节点」的定向处理（便宜），
///     全量扫描仍走去抖 + 定时，避免每次 DOM 变动都跑 28 个选择器（主线程卡顿）。
///
/// 两层策略，全通用词表、不针对任何站点（AGENTS：代码内不硬编码站点）：
///  1. 选择器直删：常见广告类名/id 词表（含拼音 tanchuang/guanggao、gg 等国内站惯用），
///     含 <video> 的元素一律不删（防误伤播放器）；
///  2. 空浮层启发式：fixed + 近全屏 + 无有效内容（无表单/大图/文字）的「点击劫持层」。
///     首见**立刻隐藏**（不等观察期），DOM 留 2s：期间填入真实内容（Nuxt 水合挂登录框）
///     就 `restored` 撤销隐藏交还页面，仍空才删节点。
///
/// WKWebView 的 console.log 真机不进 Xcode 控制台，所有动作都经
/// messageHandlers.adClean 回传原生打印（`BROWSER: adClean ...`），靠日志调优词表。
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

      // ---- A. CSS 预隐藏 ----
      // :not(:has(video)) 保护播放器容器；visibility 而非 display，避免隐藏瞬间页面跳动
      var CSS_TEXT = (function () {
        var parts = [];
        for (var i = 0; i < SELECTORS.length; i++) {
          parts.push(SELECTORS[i] + ':not(:has(video))');
        }
        return parts.join(',') +
          '{visibility:hidden !important;pointer-events:none !important;}';
      })();

      function injectCSS() {
        try {
          if (document.getElementById('__dwAdCss')) return true;
          var target = document.head || document.documentElement;
          if (!target) return false;
          var s = document.createElement('style');
          s.id = '__dwAdCss';
          s.textContent = CSS_TEXT;
          target.appendChild(s);
          return true;
        } catch (e) { return false; }
      }

      // ---- 日志 ----
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

      // ---- 判据 ----
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

      // 命中词表就删（含 video 的一律跳过）。返回是否已处理
      function killIfMatches(el) {
        for (var i = 0; i < SELECTORS.length; i++) {
          var sel = SELECTORS[i];
          var m = false;
          try { m = el.matches(sel); } catch (e) {}
          if (!m) continue;
          try {
            if (el.querySelector('video')) return true; // 播放器容器，放过
            var parent = el.parentNode;
            if (!parent) return true;
            parent.removeChild(el);
            say('removed', el, sel + '(sync)');
          } catch (e) {}
          return true;
        }
        return false;
      }

      // 空浮层启发式：首见即隐藏（不给用户看到的机会），2s 后仍空才删节点
      function checkFixedLayer(f, now) {
        try {
          if (!f || !f.parentNode || f.nodeType !== 1) return;
          var cs = getComputedStyle(f);
          if (cs.position !== 'fixed') return;
          if (cs.display === 'none' || cs.visibility === 'hidden') return;
          var r = f.getBoundingClientRect();
          var vw = window.innerWidth, vh = window.innerHeight;
          if (r.width < vw * 0.9 || r.height < vh * 0.85) return;

          var seen = parseInt(f.getAttribute('data-dwseen') || '0', 10);
          if (!seen) {
            f.setAttribute('data-dwseen', String(now));
            f.setAttribute('data-dwhidden', '1');
            f.style.setProperty('visibility', 'hidden', 'important');
            f.style.setProperty('pointer-events', 'none', 'important');
            say('candidate', f, 'fullsize-fixed(已隐藏,2s后仍空才删)');
            return;
          }
          if (hasRealContent(f)) {
            // 水合填入了真实内容（登录框等）：撤销隐藏，交还页面
            if (f.getAttribute('data-dwhidden')) {
              f.removeAttribute('data-dwhidden');
              f.style.setProperty('visibility', 'visible', 'important');
              f.style.setProperty('pointer-events', 'auto', 'important');
              say('restored', f, 'fullsize-fixed(填入真实内容)');
            }
            return;
          }
          if (now - seen < 1800) return;
          f.parentNode.removeChild(f);
          say('removed', f, 'fullsize-fixed(空浮层,存活' + (now - seen) + 'ms)');
        } catch (e) {}
      }

      // ---- 全量扫描（去抖 + 定时，成本高，不放进同步路径）----
      function sweepAll() {
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
        var kids;
        try { kids = document.body ? document.body.children : []; } catch (e) { return; }
        var now = Date.now();
        var snapshot = [];
        for (var k = 0; k < kids.length; k++) snapshot.push(kids[k]);
        for (var m = 0; m < snapshot.length; m++) checkFixedLayer(snapshot[m], now);
      }

      var pendingFull = 0;
      function scheduleFullSweep() {
        if (pendingFull) return;
        pendingFull = setTimeout(function () { pendingFull = 0; sweepAll(); }, 200);
      }

      // ---- B. 同步路径：新增节点定向处理（微任务内完成，早于绘制）----
      function handleAdded(node) {
        if (!node || node.nodeType !== 1) return;
        killIfMatches(node);
        if (!node.parentNode) return; // 已被删
        var now = Date.now();
        // 启发式只看 body 直接子节点（劫持层几乎都是 teleport 到 body）
        if (node.parentNode === document.body) checkFixedLayer(node, now);
        var kids = node.children;
        if (!kids) return;
        for (var i = 0; i < kids.length; i++) {
          var kid = kids[i];
          killIfMatches(kid);
          if (kid.parentNode === document.body) checkFixedLayer(kid, now);
        }
      }

      injectCSS();
      sweepAll();
      document.addEventListener('DOMContentLoaded', function () { injectCSS(); sweepAll(); });
      try {
        new MutationObserver(function (records) {
          injectCSS();
          for (var i = 0; i < records.length; i++) {
            var added = records[i].addedNodes;
            for (var j = 0; j < added.length; j++) handleAdded(added[j]);
          }
          scheduleFullSweep();
        }).observe(document.documentElement, { childList: true, subtree: true });
      } catch (e) {}
      setInterval(sweepAll, 2000);
    })();
    """#
}
