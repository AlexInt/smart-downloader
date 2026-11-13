import Foundation
import WebKit

// 元数据收割（Service）：从 DramaNativePage.swift 拆出，逐字迁移不改行为。
// 站点特有逻辑（请求拦截 / DOM 提取 / 落盘）独立成域内 Service，不留在 View 文件里。

// MARK: - 元数据收割器 + 提取 JS

/// 剧集页元数据提取 JS（og:image/标题/简介/图片列表/正文样本），主浏览页与收割器共用
let dramaMetaJS = """
(function(){
  var q = function(sel){ var el = document.querySelector(sel); return el ? (el.content || el.src || el.getAttribute('content') || '') : ''; };
  var imgs = [];
  var nodes = document.querySelectorAll('img');
  for (var i = 0; i < nodes.length && i < 40; i++) { var s = nodes[i].currentSrc || nodes[i].src; if (s) imgs.push(s); }
  var coverData = '';
  try {
    var big = null;
    for (var i = 0; i < nodes.length; i++) {
      var im = nodes[i];
      var s = im.currentSrc || im.src || '';
      if (im.complete && im.naturalWidth >= 300 && s.indexOf('blob:') === 0) { big = im; break; }
    }
    if (!big) {
      for (var i = 0; i < nodes.length; i++) {
        if (nodes[i].complete && nodes[i].naturalWidth >= 300) { big = nodes[i]; break; }
      }
    }
    if (big) {
      var cv = document.createElement('canvas');
      cv.width = big.naturalWidth; cv.height = big.naturalHeight;
      cv.getContext('2d').drawImage(big, 0, 0);
      coverData = cv.toDataURL('image/jpeg', 0.85);
    }
  } catch (e) { coverData = ''; }
  function idFromHref(h) {
    if (!h) return '';
    var parts = h.split('?')[0].split('#')[0].split('/').filter(function (x) { return x !== ''; });
    for (var i = parts.length - 1; i >= 0; i--) {
      if (/^\\d+$/.test(parts[i])) return parts[i];
    }
    return '';
  }
  var recCovers = {};
  try {
    var ownId = idFromHref(location.pathname);
    var anchors = document.querySelectorAll('a[href*="/drama/detail/"]');
    var recCount = 0;
    for (var i = 0; i < anchors.length && recCount < 12; i++) {
      var vid = idFromHref(anchors[i].getAttribute('href'));
      if (!vid || vid === ownId || recCovers[vid]) continue;
      var im = anchors[i].querySelector('img');
      if (!im || !im.complete || !im.naturalWidth || im.naturalWidth < 60) continue;
      try {
        var w = Math.min(im.naturalWidth, 320);
        var h = Math.round(im.naturalHeight * (w / im.naturalWidth));
        var cv = document.createElement('canvas');
        cv.width = w; cv.height = h;
        cv.getContext('2d').drawImage(im, 0, 0, w, h);
        var durl = cv.toDataURL('image/jpeg', 0.8);
        if (durl.indexOf('data:image') === 0) { recCovers[vid] = durl; recCount++; }
      } catch (e2) {}
    }
  } catch (e) {}
  return JSON.stringify({
    url: location.href,
    title: document.title || '',
    ogImage: q('meta[property="og:image"]') || q('meta[name="twitter:image"]'),
    ogTitle: q('meta[property="og:title"]'),
    keywords: q('meta[name="keywords"]'),
    desc: q('meta[name="description"]') || q('meta[property="og:description"]'),
    coverData: coverData,
    recCovers: recCovers,
    imgs: imgs,
    text: (document.body.innerText || '').replace(/\\s+/g,' ').slice(0, 500)
  });
})()
"""

/// 调查数据落盘：Documents/DramaMeta/<name>（Finder 文件共享可拷出分析）。
/// 只放页面公开内容（DOM 提取结果）；带账号凭据的接口原始 dump 仍由
/// dumpDramaMeta 启动参数门控（见 DramaAPI），不从这里走。
enum DramaMetaDump {
    /// 文件名 sanitize：site 形如 https://yeguodj.com，直接拼进文件名时
    /// 斜杠会让 write 把它当子路径解析（真机日志实证：文件夹“yeguodj.com_4094.json”不存在）；
    /// 仅替换路径非法字符，保留点号与连字符——否则 .json 扩展名也变 _json，文件无法直接打开
    ///（真机实证：harvest_https___yeguodj_com_4073_json）
    static func sanitized(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return String(raw.map { allowed.contains($0) ? $0 : "_" })
    }

    static func write(_ string: String, name: String) {
        let safeName = sanitized(name)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("DramaMeta", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try string.write(to: dir.appendingPathComponent(safeName), atomically: true, encoding: .utf8)
            print("PLAYER_DBG [Entry] DramaMetaDump ok name=\(safeName) bytes=\(string.count)")
        } catch {
            print("PLAYER_DBG [Entry] DramaMetaDump FAIL name=\(safeName) error=\(error.localizedDescription)")
        }
    }
}

/// 一次性隐藏 webview：加载剧集页，捕获详情接口响应并整包落库（DramaCache.saveDetail），
/// 同时提取 DOM 元数据兜底，完成后释放。
/// 每次进剧集页都抓一次（计数/推荐/服务端观看进度要新）；同一次访问内只抓一次。
/// 2026-11-11 tags 来源改走请求拦截：注入响应捕获脚本，把剧集页全部 API 响应
/// （api_*.json）与主文档完整 HTML（html_*.html）落盘，真机样本拿到后按 JSON
/// 字段定向提取 tags（取代锚点法止血）。`-captureDramaMeta` 启动参数强制收割
/// （绕过头部缓存判定），供已缓存剧补采样本。
/// 主线程约定：收割器状态只在主线程访问（WebKit 回调固定主线程）
final class DramaMetaHarvester: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static var harvestedKeys: Set<String> = []
    /// 进行中的收割器（保活）：finish 后自动移除。
    /// 曾把实例建在闭包体内：闭包一返回引用即消失，隐藏 webview 被连带释放
    ///（delegate 是 weak），didFinish/25s 超时全部落空、harvest_*.json 永不产生（真机日志实证）
    private static var active: [DramaMetaHarvester] = []

    static func harvest(target: DramaTarget, completion: (() -> Void)? = nil) {
        let key = target.id
        guard !harvestedKeys.contains(key) else {
            print("PLAYER_DBG [Entry] harvest SKIP reason=alreadyHarvested key=\(key)")
            completion?()
            return
        }
        harvestedKeys.insert(key)
        print("PLAYER_DBG [Entry] harvest begin site=\(target.site) dramaID=\(target.dramaID)")
        let harvester = DramaMetaHarvester()
        active.append(harvester)
        harvester.finishHandler = {
            print("PLAYER_DBG [Entry] harvest done site=\(target.site) dramaID=\(target.dramaID)")
            completion?()
        }
        harvester.begin(target: target)
    }

    private var webView: WKWebView?
    private var pendingTarget: DramaTarget?
    private var finishHandler: (() -> Void)?
    private var finished = false
    /// 捕获到的 API 响应（JSON 串数组，逐条追加重写落盘）
    private var apiCaptures: [String] = []
    /// 定向提取命中的 detail 响应（真机样本实证：明文 JSON 带 tags 数组）
    private var apiDetail: DramaDetailData?

    private func begin(target: DramaTarget) {
        pendingTarget = target
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // 与主浏览页共享登录态
        // 请求拦截：捕获 XHR/fetch 响应体回传原生落盘（捕获模式只搬运不解析）
        config.userContentController.addUserScript(
            WKUserScript(source: Self.apiCaptureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(self, name: "apicap")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        view.navigationDelegate = self
        webView = view
        view.load(URLRequest(url: URL(string: target.pageURLString)!))
        // 超时兜底：25 秒后用已拿到的部分数据收尾（finish 幂等，迟到触发无害）
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            self?.finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        Self.active.removeAll { $0 === self }
        // userContentController 强持有 handler，不解除会 harvester↔webview 循环引用
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "apicap")
        if apiDetail == nil {
            print("PLAYER_DBG [Entry] tags FAIL reason=noDetailResponse apiCaptures=\(apiCaptures.count)")
        }
        print("PLAYER_DBG [Entry] harvest finish apiCaptures=\(apiCaptures.count)")
        finishHandler?()
        finishHandler = nil
    }

    // MARK: 请求拦截（tags 数据源调查）

    /// JS -> 原生：一条 API 响应 {url,status,body}。追加数组并重写 api_*.json
    /// （条数有 JS 侧上限，重写成本可忽略）；加密信封原样落盘，原生有现成
    /// decryptPayload 可离线解。
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "apicap", let raw = message.body as? String,
              let target = pendingTarget else { return }
        apiCaptures.append(raw)
        DramaMetaDump.write("[" + apiCaptures.joined(separator: ",\n") + "]",
                            name: "api_\(target.site)_\(target.dramaID).json")
        // 定向提取：detail 响应两种形态——明文 JSON 或 api.php 加密信封
        // （errcode=0 + data base64，与 App 接口同协议，随包常量解密）。
        // 解码成功且剧 ID 命中即落库，不等轮询；其它 API 响应解码失败自然忽略。
        guard let cap = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let body = cap["body"] as? String else { return }
        var via = "plain"
        // 入库用的原文：明文直接用响应体；信封用解密后的 JSON；payload 用结构化回写
        var rawForStore = body
        var detail = try? JSONDecoder().decode(DramaDetailData.self, from: Data(body.utf8))
        if detail == nil, let json = DramaSession.decryptCapturedBody(body),
           let data = try? JSONSerialization.data(withJSONObject: json) {
            detail = try? JSONDecoder().decode(DramaDetailData.self, from: data)
            via = "envelope"
            rawForStore = String(data: data, encoding: .utf8) ?? body
        }
        if detail == nil, let d = DramaDetailData.fromNuxtPayload(Data(body.utf8), videoID: target.dramaID) {
            detail = d
            via = "payload"
            if let data = try? JSONEncoder().encode(d), let text = String(data: data, encoding: .utf8) {
                rawForStore = text
            }
        }
        guard let detail else {
            // 候选体量（>200B）的解码失败都打：空 beacon/短响应是噪音不记；
            // bodyHead 一眼判读 明文/信封/JS chunk/HTML（曾「只打首条」被空 beacon 占用，真失败被静默）
            if body.count > 200 {
                print("PLAYER_DBG [Entry] tags FAIL reason=decode url=\(cap["url"] ?? "?") bytes=\(body.count) bodyHead=\(body.prefix(120))")
            }
            return
        }
        guard String(detail.videoId) == target.dramaID else {
            print("PLAYER_DBG [Entry] tags FAIL reason=videoIdMismatch detail=\(detail.videoId) target=\(target.dramaID)")
            return
        }
        apiDetail = detail
        // 整包落库：详情接口的全部字段都留下（计数/规格/权限/催更/每集元数据/推荐剧），
        // 不再只挑 tags —— 挑字段等于把没挑的永久丢掉
        DramaCache.saveDetail(site: target.site, dramaID: target.dramaID, rawJSON: rawForStore, detail: detail)
        print("PLAYER_DBG [Entry] harvest detail saved via=\(via) bytes=\(rawForStore.count) episodes=\(detail.episodes?.count ?? 0) related=\(detail.relatedList?.count ?? 0)")
        if let tags = detail.tags, !tags.isEmpty {
            DramaCache.savePageMeta(site: target.site, dramaID: target.dramaID,
                                    update: ["tags": tags.joined(separator: " "), "tags_source": "api"])
            print("PLAYER_DBG [Entry] harvest tags source=api via=\(via) tags=\(tags.joined(separator: " "))")
        } else {
            print("PLAYER_DBG [Entry] tags FAIL reason=apiNoTags videoId=\(detail.videoId)")
        }
    }

    /// 响应捕获脚本：与嗅探器同骨架（Hook XHR/fetch），扩展为连响应体一起回传。
    /// 只捕 JSON/text 类或 api/drama/playlet 相关 URL，单条 ≤200KB、总量 ≤40 条，
    /// 避免静态资源灌爆落盘。不改变页面行为（fetch 返回原 resp，XHR 只监听 load）。
    static let apiCaptureScript = #"""
    (function () {
      if (window.__apiCapLoaded) return;
      window.__apiCapLoaded = true;
      var count = 0;
      function post(url, status, body) {
        if (count >= 40) return;
        count++;
        try {
          window.webkit.messageHandlers.apicap.postMessage(JSON.stringify({
            url: String(url), status: status, body: String(body).slice(0, 200 * 1024)
          }));
        } catch (e) {}
      }
      function want(url, ct) {
        return /json|text|javascript/.test(ct) || /api|drama|playlet/.test(String(url));
      }
      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__capUrl = url;
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        var xhr = this;
        xhr.addEventListener('load', function () {
          try {
            if (want(xhr.__capUrl, xhr.getResponseHeader('content-type') || '')) {
              post(xhr.__capUrl, xhr.status, xhr.responseText);
            }
          } catch (e) {}
        });
        return origSend.apply(this, arguments);
      };
      if (window.fetch) {
        var origFetch = window.fetch;
        window.fetch = function (input) {
          var url = typeof input === 'string' ? input : (input && input.url);
          return origFetch.apply(this, arguments).then(function (resp) {
            try {
              if (want(url, resp.headers.get('content-type') || '')) {
                resp.clone().text().then(function (t) { post(url, resp.status, t); }).catch(function () {});
              }
            } catch (e) {}
            return resp;
          });
        };
      }
    })();
    """#

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let target = pendingTarget else { return }
        // 滚到底触发懒加载：推荐卡封面在折叠线以下，站点的懒加载不解不换 blob、
        // 不滚永远 naturalWidth=1px 占位图（收割 JS 拿不到已解密图）
        webView.evaluateJavaScript("""
        window.scrollTo(0, document.body.scrollHeight);
        document.querySelectorAll('img[loading="lazy"]').forEach(function (i) { i.loading = 'eager'; });
        """, completionHandler: nil)
        // 主文档完整 HTML 一次性落盘：meta keywords / class 选择器的样本，
        // SSR 直出 tags 时也是兜底证据（不用靠 innerText 猜选择器）
        webView.evaluateJavaScript("document.documentElement.outerHTML") { html, _ in
            if let html = html as? String {
                DramaMetaDump.write(String(html.prefix(2_000_000)),
                                    name: "html_\(target.site)_\(target.dramaID).html")
            }
        }
        // SPA 渲染滞后：轮询提取直到拿到 og/desc 或超时收尾
        pollMeta(webView: webView, target: target, round: 0)
    }

    /// 每 2s 一轮、最多 5 轮；拿到 og/desc 提前收尾，轮次用尽也收尾
    private func pollMeta(webView: WKWebView, target: DramaTarget, round: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.finished else { return }
            webView.evaluateJavaScript(dramaMetaJS) { result, _ in
                guard let result = result as? String,
                      let d = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] else {
                    self.nextRound(webView: webView, target: target, round: round)
                    return
                }
                var update = d
                if let api = self.apiDetail {
                    // 详情接口的封面/简介比 DOM 干净（简介是完整剧情），以接口为准；
                    // DOM 的 ogImage/desc 仍留在 page_meta 里备查
                    if let cover = api.cover, !cover.isEmpty { update["cover"] = cover }
                    if let intro = api.description, !intro.isEmpty { update["intro"] = intro }
                } else {
                    if let og = d["ogImage"] as? String, !og.isEmpty { update["cover"] = og }
                    if let desc = d["desc"] as? String, !desc.isEmpty { update["intro"] = desc }
                }
                if let t = d["title"] as? String, !t.isEmpty { update["page_title"] = t }
                if let tags = self.apiDetail?.tags, !tags.isEmpty {
                    update["tags"] = tags.joined(separator: " ")
                    update["tags_source"] = "api"
                }
                DramaCache.savePageMeta(site: target.site, dramaID: target.dramaID, update: update)
                // 封面 blob 已由站点 JS 解密（pic.* CDN 下发的是密文，URLSession 直拉必 badData）：
                // 把已解密的 <img> 画到 canvas 导出 JPEG，按剧集 id 落进 15 天封面缓存
                if let cd = d["coverData"] as? String, cd.hasPrefix("data:image"),
                   let comma = cd.firstIndex(of: ","),
                   let imgData = Data(base64Encoded: String(cd[cd.index(after: comma)...])) {
                    DramaCoverCache.storeImageData(site: target.site, dramaID: target.dramaID, data: imgData)
                }
                // 推荐卡封面：同一张密文图床，站点已解密成 blob —— 逐卡 canvas 导出后
                // 按「推荐剧自己的 id」落缓存（后续进该剧页时 applyCover 直接命中）
                if let recs = d["recCovers"] as? [String: String], !recs.isEmpty {
                    var stored = 0
                    for (vid, dataURL) in recs {
                        guard dataURL.hasPrefix("data:image"), let comma = dataURL.firstIndex(of: ","),
                              let imgData = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { continue }
                        DramaCoverCache.storeImageData(site: target.site, dramaID: vid, data: imgData)
                        stored += 1
                    }
                    print("PLAYER_DBG [Entry] harvest recCovers stored=\(stored)/\(recs.count)")
                }
                let og = (d["ogImage"] as? String ?? "").isEmpty ? "no" : "yes"
                let desc = (d["desc"] as? String ?? "").isEmpty ? "no" : "yes"
                let coverDataLen = (d["coverData"] as? String ?? "").count
                let recCount = (d["recCovers"] as? [String: String] ?? [:]).count
                print("PLAYER_DBG [Entry] harvest round site=\(target.site) dramaID=\(target.dramaID) bytes=\(result.count) og=\(og) desc=\(desc) coverData=\(coverDataLen) rec=\(recCount)")
                // 每轮覆盖落盘（最终轮为准）：接口字段调查的数据源——tags/作者名是否在
                // 页面 DOM 里靠这个文件确认（NSLog 动态串被 <private> 脱敏，日志不可靠）
                DramaMetaDump.write(result, name: "harvest_\(target.site)_\(target.dramaID).json")
                // 收尾条件：主封面 + 推荐封面齐了才早收（推荐图有懒加载，早收会漏）；
                // 一直不齐则 og/desc 拿到且三轮后兜底收尾（25s 超时仍在）
                let hasCoverData = (d["coverData"] as? String ?? "").hasPrefix("data:image")
                let hasOgOrDesc = !(d["ogImage"] as? String ?? "").isEmpty || !(d["desc"] as? String ?? "").isEmpty
                let expectedRelated = min(self.apiDetail?.relatedList?.count ?? 0, 12)
                let recsComplete = expectedRelated > 0 && recCount >= expectedRelated
                if (hasCoverData && recsComplete) || (hasOgOrDesc && round >= 3) {
                    self.finish()
                } else {
                    self.nextRound(webView: webView, target: target, round: round)
                }
            }
        }
    }

    private func nextRound(webView: WKWebView, target: DramaTarget, round: Int) {
        if round + 1 < 5 {
            pollMeta(webView: webView, target: target, round: round + 1)
        } else {
            finish()
        }
    }
}
