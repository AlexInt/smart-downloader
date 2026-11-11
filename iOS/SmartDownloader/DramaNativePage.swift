import SwiftUI
import WebKit

/// 原生剧集页（纯原生，无网页）：点击剧集路由过来，
/// 头部 = 封面/剧名/简介（缓存 + 后台收割），下方全集 grid：未下载点选下载、已下载 ▶ 播放；
/// 元数据缺失时后台用一次性隐藏 webview 拉网页提取（落库后头部即时更新），右上角 ↻ 强制更新集数。
/// MVVM（架构评估 P8）：业务状态与编排全部在 DramaPageViewModel，本文件只渲染 + 转发意图。
struct DramaNativePage: View {
    @ObservedObject var manager: DownloadManager
    @StateObject private var vm: DramaPageViewModel

    init(target: DramaTarget, manager: DownloadManager) {
        self.manager = manager
        _vm = StateObject(wrappedValue: DramaPageViewModel(target: target, manager: manager))
    }

    var body: some View {
        Group {
            if vm.loading {
                ProgressView("正在获取剧集列表…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError = vm.loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(loadError)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("重试") { vm.reload() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let info = vm.info {
                pageContent(info)
            }
        }
        .navigationTitle(vm.info?.name ?? "剧集页")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .fullScreenCover(item: $vm.playbackRequest) { request in
            DramaPlayerContainer(request: request, onClose: { vm.playbackRequest = nil })
        }
        .task(id: vm.reloadID) { await vm.load() }
        .onAppear { vm.preloadHeaderFromCache() }
        .onReceive(manager.objectWillChange) { _ in vm.refreshDownloadedSorts() }
    }

    private func pageContent(_ info: DramaInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    if let coverURL = vm.coverURL {
                        AsyncImage(url: coverURL) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Color(uiColor: .systemGray5)
                        }
                        .frame(width: 90, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.name).font(.headline).lineLimit(2)
                        Text(vm.headerSubtitle)
                            .font(.caption).foregroundColor(.secondary)
                        if let intro = vm.intro {
                            Text(intro).font(.caption).foregroundColor(.secondary).lineLimit(4)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal)

                HStack {
                    Spacer()
                    Button("全选") { vm.selectAll() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(vm.selectableEpisodes.isEmpty)
                    Button("清空") { vm.clearSelection() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(vm.selected.isEmpty)
                    Button {
                        Task { await vm.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                    ForEach(info.episodes) { ep in
                        episodeCell(ep)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom) {
            Button { vm.startDownload() } label: {
                if vm.selected.isEmpty && vm.selectableEpisodes.isEmpty {
                    Label(vm.queuedSorts.isEmpty ? "全部已下载" : "已全部加入队列",
                          systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                } else {
                    Label("下载所选 (\(vm.selected.count))", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.selected.isEmpty)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// 单元格状态：已下载 = 绿勾 ▶（点击播放）；排队中 = 灰显 ↓（禁点）；付费锁定 = 灰锁（禁点）；
    /// 选中 = 高亮；其余可点选。排队态优先于选中态，避免残留选择显示成可再次提交
    private func episodeCell(_ ep: ApiDramaEpisode) -> some View {
        let isSelected = vm.selected.contains(ep.id)
        let isDownloaded = vm.downloadedSorts.contains(ep.sort)
        let isQueued = vm.queuedSorts.contains(ep.sort)
        return Button {
            vm.tapEpisode(ep)
        } label: {
            Group {
                if isDownloaded {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text(String(format: "第%02d集", ep.sort))
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                    }
                } else if isQueued {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String(format: "第%02d集", ep.sort))
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                    }
                } else {
                    Text(String(format: "第%02d集", ep.sort))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(isQueued
                ? Color(uiColor: .systemGray6)
                : cellBackground(isSelected: isSelected, isDownloaded: isDownloaded, playable: ep.playable))
            .foregroundStyle(isQueued
                ? Color(uiColor: .tertiaryLabel)
                : cellForeground(isSelected: isSelected, isDownloaded: isDownloaded, playable: ep.playable))
            .overlay(alignment: .topTrailing) {
                if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .offset(x: 5, y: -5)
                } else if isQueued {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .offset(x: 5, y: -5)
                } else if !ep.playable {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .offset(x: 5, y: -5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .disabled(!ep.playable || isQueued)
    }

    private func cellBackground(isSelected: Bool, isDownloaded: Bool, playable: Bool) -> Color {
        if isSelected { return .accentColor }
        if isDownloaded { return .green.opacity(0.12) }
        return playable ? Color(uiColor: .systemGray5) : Color(uiColor: .systemGray6)
    }

    private func cellForeground(isSelected: Bool, isDownloaded: Bool, playable: Bool) -> Color {
        if isSelected { return .white }
        if isDownloaded { return .primary }
        return playable ? .primary : Color(uiColor: .tertiaryLabel)
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
    static func write(_ string: String, name: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("DramaMeta", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try string.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            print("PLAYER_DBG [Entry] DramaMetaDump ok name=\(name) bytes=\(string.count)")
        } catch {
            print("PLAYER_DBG [Entry] DramaMetaDump FAIL name=\(name) error=\(error.localizedDescription)")
        }
    }
}

/// 一次性隐藏 webview：加载剧集页提取元数据（og:image/标题/简介），落库后释放。
/// 仅在纯原生页缺封面/简介时使用；同一剧每次运行只收割一次。
@MainActor
final class DramaMetaHarvester: NSObject, WKNavigationDelegate {
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

    private func begin(target: DramaTarget) {
        pendingTarget = target
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // 与主浏览页共享登录态
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
        print("PLAYER_DBG [Entry] harvest finish")
        finishHandler?()
        finishHandler = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // SPA 渲染滞后：轮询提取直到拿到 og/desc 或超时收尾
        Task { [weak self] in
            guard let self, let target = self.pendingTarget else { return }
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let result = try? await webView.evaluateJavaScript(dramaMetaJS) as? String,
                      let d = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] else { continue }
                var update = d
                if let og = d["ogImage"] as? String, !og.isEmpty { update["cover"] = og }
                if let desc = d["desc"] as? String, !desc.isEmpty { update["intro"] = desc }
                if let t = d["title"] as? String, !t.isEmpty { update["page_title"] = t }
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
