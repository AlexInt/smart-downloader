/**
 * m3u8 嗅探脚本 - 注入到用户访问的每个页面
 *
 * 功能:
 * 1. 网络层嗅探: Hook XHR / fetch，捕获播放器动态请求的 m3u8 (含 auth_key 等签名参数)
 * 2. 历史嗅探: 读取 performance 资源记录，覆盖注入前已发生的请求
 * 3. DOM 扫描: 扫描 video/source 标签 + MutationObserver 监听后续插入
 * 4. 悬浮工具栏: 后退/前进/地址栏/视频选择器/下载按钮/实时进度
 */
(function () {
  if (window.__m3u8SnifferLoaded) return;
  window.__m3u8SnifferLoaded = true;

  var found = []; // [{url, source}]，按发现顺序，最新的在末尾

  function isM3u8Url(u) {
    try { return /\.m3u8(\?|#|$)/i.test(u); } catch (e) { return false; }
  }

  function record(u, source) {
    if (!u) return;
    u = String(u);
    if (!isM3u8Url(u)) return;
    for (var i = 0; i < found.length; i++) {
      if (found[i].url === u) return;
    }
    found.push({ url: u, source: source });
    renderSelect();
    updateButton();
  }

  // ---- 网络嗅探: Hook XHR ----
  var origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    try { record(url, '网络'); } catch (e) {}
    return origOpen.apply(this, arguments);
  };

  // ---- 网络嗅探: Hook fetch ----
  if (window.fetch) {
    var origFetch = window.fetch;
    window.fetch = function (input) {
      try {
        var u = typeof input === 'string' ? input : (input && input.url);
        record(u, '网络');
      } catch (e) {}
      return origFetch.apply(this, arguments);
    };
  }

  // ---- 历史请求 (注入前播放器已加载的) ----
  try {
    var entries = performance.getEntriesByType('resource');
    for (var j = 0; j < entries.length; j++) record(entries[j].name, '历史');
  } catch (e) {}

  // ---- DOM 扫描 ----
  function scanDom() {
    var nodes = document.querySelectorAll('video, source');
    for (var i = 0; i < nodes.length; i++) {
      var s = nodes[i].src || nodes[i].getAttribute('src');
      if (s) record(s, '元素');
    }
  }
  scanDom();
  var mo = new MutationObserver(function () { scanDom(); });
  mo.observe(document.documentElement, { childList: true, subtree: true });

  // ---- 悬浮工具栏 ----
  var bar = document.createElement('div');
  bar.setAttribute('style',
    'position:fixed;top:0;left:0;right:0;z-index:2147483647;' +
    'display:flex;align-items:center;gap:8px;padding:8px 12px;' +
    'background:#1d1d1f;color:#fff;' +
    'font:13px -apple-system,"Helvetica Neue",sans-serif;' +
    'box-shadow:0 1px 10px rgba(0,0,0,.35);');

  function makeBtn() {
    var b = document.createElement('button');
    b.setAttribute('style',
      'border:0;border-radius:6px;padding:5px 10px;white-space:nowrap;' +
      'font:13px -apple-system,sans-serif;');
    return b;
  }

  var backBtn = makeBtn();
  backBtn.textContent = '←';
  backBtn.title = '后退';
  backBtn.setAttribute('style', backBtn.getAttribute('style') + 'background:#3a3a3c;color:#fff;cursor:pointer;');
  backBtn.onclick = function () { pywebview.api.back(); };

  var fwdBtn = makeBtn();
  fwdBtn.textContent = '→';
  fwdBtn.title = '前进';
  fwdBtn.setAttribute('style', fwdBtn.getAttribute('style') + 'background:#3a3a3c;color:#fff;cursor:pointer;');
  fwdBtn.onclick = function () { pywebview.api.forward(); };

  var addr = document.createElement('input');
  addr.setAttribute('style',
    'flex:1;min-width:120px;border:1px solid #48484a;border-radius:6px;padding:5px 8px;' +
    'background:#2c2c2e;color:#fff;font:13px -apple-system,sans-serif;outline:none;');
  addr.value = location.href;
  addr.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && addr.value.trim()) {
      var u = addr.value.trim();
      if (!/^https?:\/\//i.test(u)) u = 'https://' + u;
      pywebview.api.navigate(u);
    }
  });

  // 视频选择器: 发现多个 m3u8 时可切换，默认选最新 (通常是实际媒体列表)
  var sel = document.createElement('select');
  sel.setAttribute('style',
    'max-width:200px;border:1px solid #48484a;border-radius:6px;padding:5px 6px;' +
    'background:#2c2c2e;color:#fff;font:12px -apple-system,sans-serif;outline:none;');

  function renderSelect() {
    while (sel.options.length) sel.remove(0);
    if (!found.length) {
      sel.appendChild(new Option('未检测到视频', ''));
      return;
    }
    for (var i = found.length - 1; i >= 0; i--) {
      var f = found[i];
      var short = f.url.length > 60 ? f.url.slice(0, 57) + '...' : f.url;
      sel.appendChild(new Option('[' + f.source + '] ' + short, f.url));
    }
  }
  renderSelect();

  var dlBtn = makeBtn();

  function setBtn(text, bg, color, disabled) {
    dlBtn.textContent = text;
    dlBtn.disabled = !!disabled;
    dlBtn.setAttribute('style',
      'border:0;border-radius:6px;padding:5px 12px;white-space:nowrap;' +
      'font:13px -apple-system,sans-serif;color:' + color + ';' +
      'background:' + bg + ';cursor:' + (disabled ? 'not-allowed' : 'pointer') + ';');
  }

  function updateButton() {
    if (!found.length) {
      setBtn('未检测到视频', '#48484a', '#8e8e93', true);
    } else {
      setBtn('⬇ 下载视频', '#30d158', '#fff', false);
    }
  }
  updateButton();

  function startDownload() {
    var url = sel.value || (found.length ? found[found.length - 1].url : '');
    if (!url) return;
    setBtn('开始下载...', '#0a84ff', '#fff', true);
    pywebview.api.download(url, document.title || '');
  }
  dlBtn.onclick = startDownload;

  bar.appendChild(backBtn);
  bar.appendChild(fwdBtn);
  bar.appendChild(addr);
  bar.appendChild(sel);
  bar.appendChild(dlBtn);

  if (document.body) {
    document.body.appendChild(bar);
    // 顶部留白避免工具栏遮挡页面内容
    try {
      var pt = parseFloat(getComputedStyle(document.body).paddingTop || 0);
      document.body.style.paddingTop = (pt + 44) + 'px';
    } catch (e) {}
  } else {
    document.documentElement.appendChild(bar);
  }

  // ---- 轮询下载状态 ----
  var lastState = 'idle';
  setInterval(function () {
    if (!window.pywebview || !pywebview.api) return;
    pywebview.api.get_status().then(function (st) {
      if (!st) return;
      if (st.state === 'downloading') {
        var pct = st.total ? Math.round(st.current / st.total * 100) : 0;
        setBtn('下载中 ' + st.current + '/' + st.total + ' (' + pct + '%)', '#0a84ff', '#fff', true);
      } else if (st.state !== lastState) {
        if (st.state === 'done') {
          alert('✅ 下载完成\n\n已保存到:\n' + st.output);
          updateButton();
        } else if (st.state === 'error') {
          alert('❌ 下载失败: ' + (st.message || '未知错误'));
          updateButton();
        }
      }
      lastState = st.state;
    });
  }, 500);
})();
