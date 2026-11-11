import SwiftUI
import WebKit

/// 原生剧集页入口（纯原生，无网页）：点击剧集路由过来后交给 DramaDetailView 渲染。
/// 本文件只做依赖组装与生命周期编排；屏内视觉在 DramaDetailView.swift，
/// 业务状态与编排在 DramaPageViewModel.swift，元数据收割器保留在本文件下半部分。
/// MVVM（架构评估 P8）：View → ViewModel → Service，单向依赖。
struct DramaNativePage: View {
    @ObservedObject var manager: DownloadManager
    @StateObject private var vm: DramaPageViewModel

    init(target: DramaTarget, manager: DownloadManager) {
        self.manager = manager
        _vm = StateObject(wrappedValue: DramaPageViewModel(target: target, manager: manager))
    }

    var body: some View {
        DramaDetailView(vm: vm)
            .fullScreenCover(item: $vm.playbackRequest) { request in
                DramaPlayerContainer(request: request, onClose: { vm.playbackRequest = nil })
            }
            .task(id: vm.reloadID) { await vm.load() }
            .onAppear { vm.preloadHeaderFromCache() }
            .onReceive(manager.objectWillChange) { _ in vm.refreshDownloadedSorts() }
    }

}

// MARK: - 元数据收割器 + 提取 JS

/// 剧集页元数据提取 JS（og:image/标题/简介/图片列表/正文样本），主浏览页与收割器共用
let dramaMetaJS = """
(function(){
  var q = function(sel){ var el = document.querySelector(sel); return el ? (el.content || el.src || el.getAttribute('content') || '') : ''; };
  var imgs = [];
  var nodes = document.querySelectorAll('img');
  for (var i = 0; i < nodes.length && i < 40; i++) { var s = nodes[i].currentSrc || nodes[i].src; if (s) imgs.push(s); }
  return JSON.stringify({
    url: location.href,
    title: document.title || '',
    ogImage: q('meta[property="og:image"]') || q('meta[name="twitter:image"]'),
    ogTitle: q('meta[property="og:title"]'),
    keywords: q('meta[name="keywords"]'),
    desc: q('meta[name="description"]') || q('meta[property="og:description"]'),
    imgs: imgs,
    text: (document.body.innerText || '').replace(/\\s+/g,' ').slice(0, 500)
  });
})()
"""

/// 调查数据落盘：Documents/DramaMeta/<name>（Finder 文件共享可拷出分析）。
/// 只放页面公开内容（DOM 提取结果）；带账号凭据的接口原始 dump 仍由
/// dumpDramaMeta 启动参数门控（见 DramaAPI），不从这里走。
@MainActor
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

/// 一次性隐藏 webview：加载剧集页提取元数据（og:image/标题/简介），落库后释放。
/// 仅在纯原生页缺封面/简介时使用；同一剧每次运行只收割一次。
/// 2026-11-11 tags 来源改走请求拦截：注入响应捕获脚本，把剧集页全部 API 响应
/// （api_*.json）与主文档完整 HTML（html_*.html）落盘，真机样本拿到后按 JSON
/// 字段定向提取 tags（取代锚点法止血）。`-captureDramaMeta` 启动参数强制收割
/// （绕过头部缓存判定），供已缓存剧补采样本。
@MainActor
final class DramaMetaHarvester: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static var harvestedKeys: Set<String> = []

    static func harvest(target: DramaTarget) async {
        let key = target.id
        guard !harvestedKeys.contains(key) else {
            print("PLAYER_DBG [Entry] harvest SKIP reason=alreadyHarvested key=\(key)")
            return
        }
        harvestedKeys.insert(key)
        print("PLAYER_DBG [Entry] harvest begin site=\(target.site) dramaID=\(target.dramaID)")
        let harvester = DramaMetaHarvester()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // harvester 必须由 async 函数局部变量持有（挂起期间任务上下文保活）。
            // 原实现把它建在 continuation 闭包体内：闭包一返回引用即消失，
            // 隐藏 webview 被连带释放（delegate 是 weak），didFinish/25s 超时全部落空——
            // continuation 泄漏、harvest_*.json 永不产生（真机日志：TASK CONTINUATION MISUSE）
            harvester.finishHandler = { continuation.resume() }
            harvester.begin(target: target)
        }
        print("PLAYER_DBG [Entry] harvest done site=\(target.site) dramaID=\(target.dramaID)")
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
        // 超时兜底：25 秒后用已拿到的部分数据收尾
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            self?.finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
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
        var detail = try? JSONDecoder().decode(DramaDetailData.self, from: Data(body.utf8))
        if detail == nil, let json = DramaSession.decryptCapturedBody(body),
           let data = try? JSONSerialization.data(withJSONObject: json) {
            detail = try? JSONDecoder().decode(DramaDetailData.self, from: data)
            via = "envelope"
        }
        if detail == nil, let d = DramaDetailData.fromNuxtPayload(Data(body.utf8), videoID: target.dramaID) {
            detail = d
            via = "payload"
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
        // SPA 渲染滞后：轮询提取直到拿到 og/desc 或超时收尾
        Task { [weak self] in
            guard let self, let target = self.pendingTarget else { return }
            // 主文档完整 HTML 一次性落盘：meta keywords / class 选择器的样本，
            // SSR 直出 tags 时也是兜底证据（不用靠 innerText 猜选择器）
            if let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String {
                DramaMetaDump.write(String(html.prefix(2_000_000)),
                                    name: "html_\(target.site)_\(target.dramaID).html")
            }
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let result = try? await webView.evaluateJavaScript(dramaMetaJS) as? String,
                      let d = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] else { continue }
                var update = d
                if let og = d["ogImage"] as? String, !og.isEmpty { update["cover"] = og }
                if let desc = d["desc"] as? String, !desc.isEmpty { update["intro"] = desc }
                if let t = d["title"] as? String, !t.isEmpty { update["page_title"] = t }
                if let tags = self.apiDetail?.tags, !tags.isEmpty {
                    update["tags"] = tags.joined(separator: " ")
                    update["tags_source"] = "api"
                }
                DramaCache.savePageMeta(site: target.site, dramaID: target.dramaID, update: update)
                let og = (d["ogImage"] as? String ?? "").isEmpty ? "no" : "yes"
                let desc = (d["desc"] as? String ?? "").isEmpty ? "no" : "yes"
                print("PLAYER_DBG [Entry] harvest round site=\(target.site) dramaID=\(target.dramaID) bytes=\(result.count) og=\(og) desc=\(desc)")
                // 每轮覆盖落盘（最终轮为准）：接口字段调查的数据源——tags/作者名是否在
                // 页面 DOM 里靠这个文件确认（NSLog 动态串被 <private> 脱敏，日志不可靠）
                DramaMetaDump.write(result, name: "harvest_\(target.site)_\(target.dramaID).json")
                if !(d["ogImage"] as? String ?? "").isEmpty || !(d["desc"] as? String ?? "").isEmpty { break }
            }
            self.finish()
        }
    }
}
