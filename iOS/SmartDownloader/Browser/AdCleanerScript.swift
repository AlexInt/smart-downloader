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
///  2. 空浮层启发式：fixed + 近全屏 + **确实没有可见内容**（无表单/大图/文字）的
///     「点击劫持层」。首见先判内容，真有内容就 `kept` 放过（登录框/年龄确认/
///     公告等真实弹窗一律不碰）；确认是空层才隐藏，DOM 留 2s，期间填入内容就
///     `restored` 撤销隐藏交还页面，仍空才删节点。
///
/// 两条铁律（都踩过坑）：
///  - **隐藏后的复查不能被 visibility 守卫挡住**：旧实现先判 `visibility === 'hidden'`
///    就 return，导致「被我们藏起来」的层永远走不到 restore/删除分支。站点年龄确认
///    弹窗被藏掉后不恢复，只剩它身后的全屏暗色底盖住整页（2026-11-15）。
///  - **只把「看得见的」内容算作真实内容**：广告弹窗内容被 CSS 词表藏掉后，背板里
///    的图片不该再让它被判成「有内容」而保留；但判断年龄确认弹窗恢复时，又要能透过
///    「我们加在根节点上的 visibility:hidden」看到里面的文字/图片。
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

      function sayRaw(kind, text) {
        try {
          var w = window.webkit;
          if (w && w.messageHandlers && w.messageHandlers.adClean) {
            w.messageHandlers.adClean.postMessage(kind + ' ' + text);
          }
        } catch (e) {}
      }

      // ---- 滚动锁：站点弹窗的「副作用」，不是广告本身 ----
      // 站点弹窗的标准玩法：弹窗出现时给 html/body 加 overflow:hidden（或 body
      // position:fixed + top:-scrollY），点它自己那个「关闭」按钮时再还原。
      // 我们把弹窗藏掉/删掉了，用户看不到弹窗，但站点的**还原回调永远不会执行**，
      // 于是页面从此滑不动——用户实报「首页刚开始能滑动，后面滑不动了」（2026-11-14）。
      // 所以每处理掉一个弹窗都要顺手解开滚动锁；只解「我们处理过弹窗之后」的那一次，
      // 不常驻抢站点状态（正常站点的合法弹窗/全屏播放器不碰）。
      function lockState() {
        try {
          var html = document.documentElement, body = document.body;
          var hs = getComputedStyle(html);
          var parts = ['html.overflow=' + (hs.overflowY || hs.overflow)];
          if (body) {
            var bs = getComputedStyle(body);
            parts.push('body.overflow=' + (bs.overflowY || bs.overflow));
            parts.push('body.position=' + bs.position);
            parts.push('body.touchAction=' + bs.touchAction);
          }
          var se = document.scrollingElement || html;
          parts.push('scrollTop=' + Math.round(se.scrollTop) + '/' +
                     Math.round(Math.max(0, se.scrollHeight - se.clientHeight)));
          return parts.join(' ');
        } catch (e) { return 'lockState?'; }
      }

      function unlockScroll(reason, depth, forcePos) {
        depth = depth || 0;
        try {
          var html = document.documentElement, body = document.body;
          var fixes = [];
          function fix(el, name) {
            if (!el) return;
            var cs = getComputedStyle(el);
            if (cs.overflowY === 'hidden' || cs.overflow === 'hidden') {
              el.style.setProperty('overflow-y', 'auto', 'important');
              fixes.push(name + '.overflow');
            }
            if (cs.touchAction === 'none') {
              el.style.setProperty('touch-action', 'auto', 'important');
              fixes.push(name + '.touchAction');
            }
          }
          fix(html, 'html');
          fix(body, 'body');
          var overflowLocked = fixes.length > 0;
          // body position:fixed 锁：站点的常规写法是同时给 top:-scrollY，还原时要滚回去。
          // 只在「确实是锁」时才动 position：负 top（iOS body-scroll-lock 标准写法）或
          // 同时命中 overflow 锁，或诊断探针明确判定卡住（forcePos）——
          // 少数 SPA 把 body 常设 fixed + 内层滚动，不该被我们掰成 double scroll。
          if (body) {
            var bs = getComputedStyle(body);
            if (bs.position === 'fixed') {
              var top = parseFloat(bs.top || '0') || 0;
              var y = top < 0 ? -top : 0;
              if (y > 0 || overflowLocked || forcePos) {
                body.style.setProperty('position', 'static', 'important');
                body.style.setProperty('top', 'auto', 'important');
                body.style.setProperty('left', 'auto', 'important');
                fixes.push('body.position');
                if (y > 0) {
                  setTimeout(function () { try { window.scrollTo(0, y); } catch (e) {} }, 0);
                }
              }
            }
          }
          if (fixes.length) {
            sayRaw('unlockScroll', 'depth=' + depth + ' reason=' + reason +
                   ' fixes=' + fixes.join(',') + ' → [' + lockState() + ']');
            // 站点的渲染钩子可能在我们之后又锁一次：延迟复核两次，仍锁才再解。
            // depth 上限 2：复核本身的 unlockScroll 也有 fixes 就会再排复核，
            // 不设上限会变成长跑定时器（每 320/1400ms 一轮，永不停止）
            if (depth < 2) {
              setTimeout(function () { unlockScroll('retry:' + reason, depth + 1, forcePos); }, 320);
              setTimeout(function () { unlockScroll('retry:' + reason, depth + 1, forcePos); }, 1400);
            }
          }
        } catch (e) {}
      }

      // ---- 判据 ----
      // node 在 root（含）以内是否「可能被看见」：root 自身被我们加的
      // visibility:hidden 要忽略，否则隐藏态下永远判不出内容已填入；
      // 更内层的 visibility:hidden/display:none 照常算隐藏（广告弹窗内容
      // 被 CSS 词表藏掉后，不该再算作背板的真实内容）。
      function visibleWithin(node, root) {
        var n = node;
        while (n && n.nodeType === 1) {
          try {
            var cs = getComputedStyle(n);
            if (cs.display === 'none') return false;
            if (cs.visibility === 'hidden' && n !== root) return false;
            if (n === root) return true;
          } catch (e) { return false; }
          n = n.parentElement;
        }
        return true;
      }

      // 可见文字：不能用 innerText——元素处于 visibility:hidden 时它可能返回空，
      // 而「我们隐藏后，内容是否已经水合进来」恰恰要在隐藏态下判断。
      function hasVisibleText(el) {
        try {
          var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
          var total = 0, node;
          while ((node = walker.nextNode())) {
            var text = (node.nodeValue || '').replace(/\s+/g, '');
            if (!text) continue;
            var p = node.parentElement;
            if (!p || !visibleWithin(p, el)) continue;
            total += text.length;
            if (total > 6) return true;
          }
        } catch (e) {}
        return false;
      }

      function hasRealContent(el) {
        try {
          if (el.querySelector('video, input, form, textarea, select')) return true;
          var imgs = el.querySelectorAll('img');
          for (var i = 0; i < imgs.length; i++) {
            var r = imgs[i].getBoundingClientRect();
            if (r.width > 8 && r.height > 8 && visibleWithin(imgs[i], el)) return true;
          }
          if (hasVisibleText(el)) return true;
        } catch (e) {}
        return false;
      }

      // 删掉广告节点后，它的祖先里可能有一块全屏 fixed 背板（站点把暗色底画在
      // 背板而不是弹窗上）——内容一空要立刻复查，否则会留下一层遮罩盖住页面。
      function checkEnclosingLayers(from) {
        var now = Date.now();
        var p = from;
        for (var i = 0; p && p.nodeType === 1 && i < 6; i++) {
          checkFixedLayer(p, now);
          if (p === document.body) break;
          p = p.parentElement;
        }
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
            // 删掉的多半就是那个「锁着滚动」的弹窗：顺手把站点加的滚动锁解开
            //（站点自己的关闭回调永远不会执行了，不解锁页面就永久滑不动）
            unlockScroll('removed:' + sel, 0);
            // 弹窗背后若还有一块全屏暗色背板，现在它已经是空层，立刻复查
            checkEnclosingLayers(parent);
          } catch (e) {}
          return true;
        }
        return false;
      }

      // 隐藏 / 恢复一块被我们判定为「空浮层」的全屏层。
      // 隐藏前记下它原本的内联值，恢复时原样还回去（不要留下 visibility:visible
      // 这类残留，站点自己的样式可能靠内联值工作）。
      function hideLayer(f, now, reason) {
        if (!f.hasAttribute('data-dwprevvis')) {
          f.setAttribute('data-dwprevvis', f.style.getPropertyValue('visibility'));
          f.setAttribute('data-dwprevpe', f.style.getPropertyValue('pointer-events'));
        }
        f.setAttribute('data-dwhidden', '1');
        f.setAttribute('data-dwseen', String(now));
        f.style.setProperty('visibility', 'hidden', 'important');
        f.style.setProperty('pointer-events', 'none', 'important');
        say('candidate', f, reason);
      }

      function restoreLayer(f, how) {
        var pv = f.getAttribute('data-dwprevvis') || '';
        var pp = f.getAttribute('data-dwprevpe') || '';
        if (pv) f.style.setProperty('visibility', pv); else f.style.removeProperty('visibility');
        if (pp) f.style.setProperty('pointer-events', pp); else f.style.removeProperty('pointer-events');
        f.removeAttribute('data-dwhidden');
        f.removeAttribute('data-dwprevvis');
        f.removeAttribute('data-dwprevpe');
        say('restored', f, how);
      }

      // 空浮层启发式：先判内容，真有内容一律放过；确认是空层才隐藏，
      // 之后每次复查都重新判内容：填入了就恢复，持续为空才删节点。
      function checkFixedLayer(f, now) {
        try {
          if (!f || !f.parentNode || f.nodeType !== 1) return;
          var cs = getComputedStyle(f);
          if (cs.position !== 'fixed') return;
          if (cs.display === 'none') return;
          var hiddenByUs = f.getAttribute('data-dwhidden') === '1';
          // 站点自己藏起来的层不管；但「被我们藏起来」的层必须继续往下走，
          // 否则永远走不到 restore / 删除分支（年龄确认弹窗就是这么消失的）
          if (cs.visibility === 'hidden' && !hiddenByUs) return;
          var r = f.getBoundingClientRect();
          var vw = window.innerWidth, vh = window.innerHeight;
          if (r.width < vw * 0.9 || r.height < vh * 0.85) return;

          var seen = parseInt(f.getAttribute('data-dwseen') || '0', 10);
          var real;
          if (hiddenByUs) {
            // visibility 会继承：根节点被我们藏起来后，里面的文字/图片也全是
            // hidden，直接量必然判空。先同步摘掉我们加的隐藏再量——同一段 JS
            // 内完成，浏览器不会在中间绘制；量完仍空就原样藏回去。
            f.style.removeProperty('visibility');
            f.style.removeProperty('pointer-events');
            real = hasRealContent(f);
            if (!real) {
              f.style.setProperty('visibility', 'hidden', 'important');
              f.style.setProperty('pointer-events', 'none', 'important');
            }
          } else {
            real = hasRealContent(f);
          }

          if (real) {
            // 真实弹窗（登录框 / 年龄确认 / 公告等）：首见就放过；
            // 若曾被我们藏起来，说明水合内容已填入 → 撤销隐藏交还页面
            if (hiddenByUs) {
              restoreLayer(f, 'fullsize-fixed(填入真实内容)');
            } else if (!seen) {
              f.setAttribute('data-dwseen', String(now));
              say('kept', f, 'fullsize-fixed(有真实内容,不处理)');
            }
            return;
          }
          if (!seen) {
            hideLayer(f, now, 'fullsize-fixed(空浮层,已隐藏,2s后仍空才删)');
            // 这里**不**解滚动锁：有可能是水合中的真实弹窗，2s 内会 restore；
            // 提前解开会把站点合法的滚动锁（如年龄确认期间的锁）掰掉。
            return;
          }
          if (!hiddenByUs) {
            // 首见时有内容（例如广告弹窗），随后内容被我们删掉 → 背板变空层。
            // 重新从「刚隐藏」开始计时，避免暗色背板继续盖住页面。
            hideLayer(f, now, 'fullsize-fixed(内容被清空,已隐藏,2s后仍空才删)');
            return;
          }
          if (now - seen < 1800) return;
          f.parentNode.removeChild(f);
          say('removed', f, 'fullsize-fixed(空浮层,存活' + (now - seen) + 'ms)');
          unlockScroll('popup-removed', 0);
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
              var parent = el.parentNode;
              parent.removeChild(el);
              say('removed', el, SELECTORS[i]);
              unlockScroll('sweep:' + SELECTORS[i], 0);
              checkEnclosingLayers(parent);
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

      // ---- 滚动诊断：查「滑不动」到底卡在哪 ----
      // WebKit 不给「滚不动」事件，只能自己对账：按下时记下祖先链各滚动容器（含
      // document.scrollingElement）的 scrollTop，拖拽（竖直位移 > 20px）抬手 300ms 后
      // 若整条链一格都没动、且不在顶部/底部边界，就判定为卡住 → 打 `scrollStuck`
      //（带 lockState）并顺手解一次滚动锁。全程 passive 只读，不影响正常滚动；
      // 只在判定成立时打日志，3s 节流。
      var probe = { startY: 0, targets: null, dragged: false, lastAt: 0, hit: '' };

      // 手指底下到底是哪个元素：卡住时若页面没被锁，多半是某个透明浮层吃掉了触摸，
      // 这一项就是抓它的线索（名字 + position + z-index）
      function describeAt(x, y) {
        try {
          var el = document.elementFromPoint(x, y);
          if (!el) return 'none';
          var cs = getComputedStyle(el);
          return sig(el) + '(pos=' + cs.position + ',z=' + (cs.zIndex || 'auto') + ')';
        } catch (e) { return '?'; }
      }

      function scrollTargets(from) {
        var out = [];
        var node = from;
        while (node && node.nodeType === 1) {
          try {
            if (node.scrollHeight - node.clientHeight > 4) {
              out.push({ el: node, top: node.scrollTop });
            }
          } catch (e) {}
          if (node === document.documentElement) break;
          node = node.parentElement;
        }
        try {
          var se = document.scrollingElement;
          if (se && se.scrollHeight - se.clientHeight > 4) {
            out.push({ el: se, top: se.scrollTop });
          }
        } catch (e) {}
        return out;
      }

      document.addEventListener('touchstart', function (ev) {
        try {
          var t = ev.touches && ev.touches[0];
          if (!t || ev.touches.length > 1) { probe.targets = null; return; }
          probe.startY = t.clientY;
          probe.dragged = false;
          probe.targets = scrollTargets(ev.target);
          probe.hit = describeAt(t.clientX, t.clientY);
        } catch (e) { probe.targets = null; }
      }, { passive: true, capture: true });

      document.addEventListener('touchmove', function (ev) {
        try {
          var t = ev.touches && ev.touches[0];
          if (!t) return;
          if (Math.abs(t.clientY - probe.startY) > 20) probe.dragged = true;
        } catch (e) {}
      }, { passive: true, capture: true });

      document.addEventListener('touchend', function (ev) {
        try {
          var targets = probe.targets, dragged = probe.dragged, hit = probe.hit, startY = probe.startY;
          probe.targets = null;
          if (!targets || !targets.length || !dragged) return;
          var t = ev.changedTouches && ev.changedTouches[0];
          var dy = t ? (startY - t.clientY) : 0;   // >0 = 往上推（内容下滚）
          setTimeout(function () {
            var moved = false, names = [];
            for (var i = 0; i < targets.length; i++) {
              var it = targets[i];
              try {
                if (!it.el.isConnected) continue;
                var d = Math.abs(it.el.scrollTop - it.top);
                names.push(sig(it.el) + '@' + Math.round(it.el.scrollTop) + (d > 1 ? '^' : '='));
                if (d > 1.5) moved = true;
              } catch (e) {}
            }
            if (moved) return;
            // 顶部/底部边界：本来就滚不动，不算卡住
            try {
              var se = document.scrollingElement || document.documentElement;
              var max = se.scrollHeight - se.clientHeight;
              if (dy > 0 && max - se.scrollTop < 2) return;
              if (dy < 0 && se.scrollTop < 2) return;
            } catch (e) {}
            var now = Date.now();
            if (now - probe.lastAt < 3000) return;
            probe.lastAt = now;
            sayRaw('scrollStuck', 'dy=' + Math.round(dy) + ' hit=' + hit +
                   ' chain=' + names.join(',') + ' → [' + lockState() + ']');
            // 只在确实处于「滚动锁」状态时才动手解：
            // 虚拟滚动（transform 位移、scrollTop 不变）与浮层吃触摸也会被这条探针
            // 判成 stuck，那种情况绝不能改样式，只留日志由人判断（hit= 就是浮层线索）
            if (isScrollLocked()) unlockScroll('scrollStuck', 0, true);
          }, 300);
        } catch (e) {}
      }, { passive: true, capture: true });

      // ---- 滚动锁状态探针：锁是在什么时候被加上的 ----
      // 每秒比对一次「页面当前是否处于滚动锁状态」，只在翻转时打一条日志。
      // 用户报「滑不动」时，日志里有没有 scrollLocked、时间是几点，一眼就能判读：
      // 有 → 站点弹窗残留的锁；没有 → 问题不在锁上（再去查别的手势拦截）。
      var lockWatch = { locked: null };
      function isScrollLocked() {
        try {
          var html = document.documentElement, body = document.body;
          var hs = getComputedStyle(html);
          if (hs.overflowY === 'hidden' || hs.overflow === 'hidden') return true;
          if (body) {
            var bs = getComputedStyle(body);
            if (bs.overflowY === 'hidden' || bs.overflow === 'hidden') return true;
            if (bs.position === 'fixed' && (parseFloat(bs.top || '0') || 0) < 0) return true;
          }
        } catch (e) {}
        return false;
      }
      setInterval(function () {
        var now = isScrollLocked();
        if (lockWatch.locked === null) { lockWatch.locked = now; return; }
        if (now === lockWatch.locked) return;
        lockWatch.locked = now;
        sayRaw(now ? 'scrollLocked' : 'scrollUnlocked', '[' + lockState() + ']');
      }, 1000);

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
