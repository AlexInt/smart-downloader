import Foundation

/// 年龄确认门（age gate）自动确认脚本（WKUserScript 注入，与 AdCleanerScript 同一安装模式）。
///
/// 为什么单独一支：广告清理只负责「删掉盖住页面的垃圾」，而年龄门是站点自己的
/// 合法弹窗——不能删（删了页面可能缺导航/缺状态），只能像用户那样点一下「已满18岁
/// 继续观看」把它正式放行。用户实报「首页一直被确认弹窗挡着」，手点一次就没了，
/// 所以做成自动点击。
///
/// 判据（通用，不含任何站点地址/站点 DOM 结构，AGENTS：代码内不硬编码站点）：
///  1. **必须是浮层**：role=dialog/alertdialog，或自身/祖先 position 为 fixed/absolute
///     且面积足够大（≥55% 宽、≥30% 高；role=dialog 放宽到 240×120）。只在页面正文里
///     出现「18」字样的按钮一律不碰——视频站的「继续观看」是最常见的普通按钮。
///  2. **浮层文字必须像年龄门**：含 `18`（独立数字，避免 1180 之类误命中）/`十八`/
///     `周岁`/`成年`/`年龄`/`adult`。
///  3. **按钮必须是正向确认**：文案匹配「已满18岁 / 我已满18 / 同一年龄确认 / 继续观看 /
///     进入 / 同意」等；含「未满 / 未成年 / 成年后见 / 好可惜 / 离开 / 退出 / 不同意 /
///     暂不」的一律排除（这些是「我还未成年」的拒绝按钮，点了会跳走）。
///  4. 只点**一个**按钮，点完等 1.1s 复核浮层是否消失：消失即完成；还在就重试，
///     最多 4 次后放弃并留日志，绝不进入死循环（每页最多 4 次点击）。
///
/// 日志经 messageHandlers.ageGate 回传原生（`BROWSER: ageGate ...`），WKWebView 的
/// console.log 真机不进 Xcode 控制台，调判据只能靠这条通道。
enum AgeGateScript {
    static let source = #"""
    (function () {
      if (window.__dwAgeGateLoaded) return;
      window.__dwAgeGateLoaded = true;

      // ---- 日志 ----
      function say(text) {
        try {
          var w = window.webkit;
          if (w && w.messageHandlers && w.messageHandlers.ageGate) {
            w.messageHandlers.ageGate.postMessage(text);
          }
        } catch (e) {}
      }

      function sig(el) {
        if (!el) return 'null';
        var id = el.id ? ('#' + el.id) : '';
        var cls = '';
        try {
          if (el.className && typeof el.className === 'string') {
            cls = '.' + el.className.trim().split(/\s+/).slice(0, 3).join('.');
          }
        } catch (e) {}
        var txt = '';
        try {
          txt = String(el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 24);
        } catch (e) {}
        return '<' + String(el.tagName).toLowerCase() + id + cls + '>' + (txt ? '"' + txt + '"' : '');
      }

      // ---- 判据 ----
      // 年龄词：`18` 必须独立成数（前后不是数字），否则 1180 / 2018 之类全命中
      function hasAgeWords(text) {
        if (!text) return false;
        if (/周岁|十八|成年|年龄|未成年人|adult|age\s*(verification|gate|check)/i.test(text)) return true;
        return /(^|[^0-9])1[8８]([^0-9]|$)/.test(text);
      }

      var NEGATIVE = /未满|未成年|不满18|成年后见|好可惜|离开|退出|不同意|暂不|不进入|取消|返回/;

      // 正向确认打分：3 = 明确成年确认，2 = 明确「进入/继续」动作，1 = 泛「同意/确定」
      function positiveScore(text) {
        var t = String(text || '').replace(/\s+/g, '');
        if (!t || t.length > 24) return 0;      // 长文本不是按钮标签
        if (NEGATIVE.test(t)) return 0;
        if (/(已满|已年满|我满|我已满|满)\s*(18|十八)\s*(岁|周岁)?/.test(t)) return 3;
        if (/已成年|我成年|成年了|年满18|18岁以上|确认成年/.test(t)) return 3;
        if (/继续观看|继续访问|继续浏览|进入网站|同意并继续|确定进入|进入本站|^进入/.test(t)) return 2;
        if (/^(同意|确定|确认|我知道了|知道了|我已了解|我已知悉|我同意)/.test(t)) return 1;
        return 0;
      }

      // 「看得见」的判定用在两处：浮层本身（大）与按钮（可能很小）。
      // 按钮阈值必须放得足够低——原生 <button> 只有 30pt 左右高，按 40 判会把
      // 真按钮全过滤掉（本地合成页实测：abs-full 命中浮层但 nobtn）。
      function isShown(el) {
        try {
          if (!el || !el.isConnected) return false;
          var cs = getComputedStyle(el);
          if (cs.display === 'none' || cs.visibility === 'hidden') return false;
          if (parseFloat(cs.opacity || '1') < 0.05) return false;
          var r = el.getBoundingClientRect();
          return r.width > 16 && r.height > 12;
        } catch (e) { return false; }
      }

      // 浮层判定：
      //  ① 有 dialog 语义（role=dialog/alertdialog 或 <dialog open>）：真实弹窗，面积门槛很低
      //  ② 没有语义：必须**近全屏**（≥90% 宽、≥80% 高）且 fixed/absolute 祖先才算浮层。
      //     SPA 的主滚动容器也常是 absolute 全屏，所以这一路还会再要求按钮文案**自身**
      //     带年龄词（见 findGate），避免把首页的「继续观看」当成确认按钮点掉。
      function overlayInfo(el) {
        try {
          var r = el.getBoundingClientRect();
          var vw = window.innerWidth || 1, vh = window.innerHeight || 1;
          var tag = String(el.tagName || '').toUpperCase();
          var role = (el.getAttribute && el.getAttribute('role')) || '';
          var byRole = role === 'dialog' || role === 'alertdialog' ||
                       (tag === 'DIALOG' && el.hasAttribute('open'));
          if (byRole) {
            if (r.width < 240 || r.height < 120) return null;
            return { rect: r, role: role || 'dialog' };
          }
          if (r.width < vw * 0.9 || r.height < vh * 0.8) return null;
          var pos = false, n = el;
          for (var i = 0; n && n.nodeType === 1 && i < 8; i++) {
            var cs = getComputedStyle(n);
            if (cs.position === 'fixed' || cs.position === 'absolute') { pos = true; break; }
            if (n === document.body) break;
            n = n.parentElement;
          }
          if (!pos) return null;
          return { rect: r, role: '-fullsize' };
        } catch (e) { return null; }
      }

      // 候选浮层：role=dialog + body 顶层两层（teleport 浮层的落点）+ 语义类名兜底。
      // 不做全 document 扫描：视频站 DOM 上万个节点，逐节点取 rect 会卡主线程。
      function candidates() {
        var out = [], seen = [];
        function add(el) {
          if (!el || el.nodeType !== 1 || seen.indexOf(el) >= 0) return;
          seen.push(el);
          out.push(el);
        }
        try {
          var roles = document.querySelectorAll('[role="dialog"],[role="alertdialog"]');
          for (var i = 0; i < roles.length && i < 8; i++) add(roles[i]);
        } catch (e) {}
        var kids = document.body ? document.body.children : [];
        for (var k = 0; k < kids.length; k++) {
          add(kids[k]);
          var gk = kids[k].children || [];
          for (var m = 0; m < gk.length && m < 40; m++) add(gk[m]);
        }
        try {
          var named = document.querySelectorAll(
            '[class*="age-gate"],[class*="age_gate"],[class*="agegate"],[class*="ageGate"],' +
            '[id*="age-gate"],[id*="age_gate"],[class*="adult"],[class*="verify-age"],[class*="age-verify"]');
          for (var n = 0; n < named.length && n < 40; n++) add(named[n]);
        } catch (e) {}
        return out;
      }

      // 浮层里的正向按钮：先看交互元素，再看 div/span 假按钮（必须带 cursor:pointer）
      function findConfirmButton(overlay) {
        var best = null, bestScore = 0;
        var sel = 'button,[role="button"],a,[onclick],input[type="button"],input[type="submit"]';
        var nodes = [];
        try { nodes = overlay.querySelectorAll(sel); } catch (e) { nodes = []; }
        for (var i = 0; i < nodes.length; i++) {
          var el = nodes[i];
          if (!isShown(el)) continue;
          var label = '';
          try { label = el.innerText || el.value || el.textContent || ''; } catch (e) {}
          var s = positiveScore(label);
          if (s > bestScore) { bestScore = s; best = el; }
        }
        if (best) return { el: best, score: bestScore };
        // 假按钮兜底：站点用 div/span 画按钮时点击仍然有效
        var fake = [];
        try { fake = overlay.querySelectorAll('div,span,li'); } catch (e) { fake = []; }
        for (var j = 0; j < fake.length; j++) {
          var f = fake[j];
          if (!isShown(f)) continue;
          var cs = null;
          try { cs = getComputedStyle(f); } catch (e) {}
          if (!cs || cs.cursor !== 'pointer') continue;
          var t = '';
          try { t = f.innerText || f.textContent || ''; } catch (e) {}
          var sc = positiveScore(t);
          if (sc > bestScore) { bestScore = sc; best = f; }
        }
        return best ? { el: best, score: bestScore } : null;
      }

      // 判据失败的原因只在「变了」时打一条：每秒轮询若每次都打，日志会被刷满，
      // 但完全不记又没法判断「为什么不点」。
      var lastScan = '';
      function findGate() {
        var list = candidates();
        var notes = [];
        for (var i = 0; i < list.length; i++) {
          var el = list[i];
          if (!isShown(el)) continue;
          var info = overlayInfo(el);
          if (!info) continue;
          var text = '';
          try { text = el.innerText || el.textContent || ''; } catch (e) {}
          if (!hasAgeWords(text)) continue;
          var btn = findConfirmButton(el);
          if (!btn) {
            notes.push('ageLayerNoButton' + sig(el));
            continue;
          }
          // 没有 dialog 语义的全屏层：只接受「明确说我成年了」这类按钮（score 3）。
          // 光「继续观看/进入」不够——SPA 首页整块内容也是全屏 absolute，
          // 页面上随便一个「继续观看」被点掉就是真故障。
          if (info.role === '-fullsize' && btn.score < 3) {
            notes.push('weakButton' + sig(el) + ' score=' + btn.score + ' button' + sig(btn.el));
            continue;
          }
          var note = 'hit ' + sig(el) + ' role=' + info.role + ' score=' + btn.score;
          if (lastScan !== note) { lastScan = note; say('scan ' + note); }
          return { overlay: el, button: btn.el, score: btn.score, role: info.role, text: text };
        }
        var out = 'cand=' + list.length + (notes.length ? ' ' + notes.join(' | ') : '');
        if (notes.length && out !== lastScan) { lastScan = out; say('scan ' + out); }
        return null;
      }

      // ---- 点击 ----
      // 先走 el.click()（React/Vue 的 onClick 都吃这个）；如果 1.1s 后浮层还在，
      // 下一轮改派发完整指针事件序列（部分站点监听 pointerdown/pointerup 自绘按钮）
      var pointerMode = false;
      function fire(el) {
        try {
          var r = el.getBoundingClientRect();
          var opts = {
            bubbles: true, cancelable: true, composed: true, view: window,
            clientX: Math.round(r.left + r.width / 2),
            clientY: Math.round(r.top + r.height / 2),
            button: 0, buttons: 1
          };
          if (!pointerMode) { el.click(); return 'click'; }
          if (window.PointerEvent) {
            el.dispatchEvent(new PointerEvent('pointerdown', opts));
            el.dispatchEvent(new PointerEvent('pointerup', opts));
          }
          el.dispatchEvent(new MouseEvent('mousedown', opts));
          el.dispatchEvent(new MouseEvent('mouseup', opts));
          el.dispatchEvent(new MouseEvent('click', opts));
          return 'pointer-sequence';
        } catch (e) { return 'error:' + e; }
      }

      // ---- 调度 ----
      var state = { tries: 0, lastOverlay: null, lastAt: 0, doneAt: 0, gave: false, busy: false };

      function attempt() {
        if (state.busy) return;
        if (state.gave) return;
        if (state.doneAt && Date.now() - state.doneAt < 5000) return;
        var gate = findGate();
        if (!gate) return;
        var now = Date.now();
        if (gate.overlay === state.lastOverlay) {
          if (state.tries >= 4) {
            state.gave = true;
            say('gaveUp tries=' + state.tries + ' ' + sig(gate.overlay));
            return;
          }
          if (now - state.lastAt < 700) return;   // 节流：点完先等复核，别连点
        } else {
          state.lastOverlay = gate.overlay;
          state.tries = 0;
          pointerMode = false;
        }
        if (now - state.lastAt < 700) return;
        state.lastAt = now;
        state.tries++;
        var how = fire(gate.button);
        say('clicked #' + state.tries + ' score=' + gate.score + ' via=' + how +
            ' overlay' + sig(gate.overlay) + ' role=' + gate.role +
            ' button' + sig(gate.button));
        // 复核：浮层消失 → 完成；还在 → 下一轮换指针序列重试
        state.busy = true;
        setTimeout(function () {
          state.busy = false;
          var still = false;
          try { still = isShown(gate.overlay); } catch (e) {}
          if (!still) {
            state.doneAt = Date.now();
            pointerMode = false;
            say('confirmed tries=' + state.tries + ' ' +
                'html.class=' + (document.documentElement.className || '-') +
                ' overlayGone=1');
            return;
          }
          pointerMode = true;
          say('stillVisible tries=' + state.tries + ' nextMode=pointer ' + sig(gate.overlay));
          attempt();
        }, 1100);
      }

      var pending = 0;
      function schedule(delay) {
        if (pending) return;
        pending = setTimeout(function () { pending = 0; attempt(); }, delay || 150);
      }

      // 只在页面早期盯：年龄门一定在首屏出现，30s 后停（每页最多 30 次便宜扫描）
      var ticks = 0;
      var ticker = setInterval(function () {
        ticks++;
        if (state.doneAt || state.gave || ticks > 30) { clearInterval(ticker); return; }
        attempt();
      }, 1000);

      try {
        new MutationObserver(function () { schedule(150); })
          .observe(document.documentElement, { childList: true, subtree: true });
      } catch (e) {}
      document.addEventListener('DOMContentLoaded', function () { schedule(60); });
      schedule(60);
    })();
    """#
}
