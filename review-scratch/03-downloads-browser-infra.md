# 03 · 下载域 / 浏览域 / Infra 只读审查

审查范围：`iOS/SmartDownloader/Downloads/`（6 文件）+ `Browser/`（9 文件）+ `Infra/`（5 文件），共 20 文件全部通读；判据 = AGENTS.md「iOS 架构约定」「域内五层规则」「并发与线程」「具体约定 1–24」。只读审查，未改任何源码。

## 小结

三个域的分层纪律执行得很好：View/VM 零 UserDefaults/FileManager/UIScreen，持久化全部收进 Service；AGENTS 第 24 条同集去重三源收口（pruneSupersededAttempts / preferredEpisodeFolder / 引擎保存段替换旧目录）与约定逐条对应，keeper 语义与「散装不去重」都落实了；WebKitFetcher 两阶段握手、LocalMediaServer 的端口/路径边界处理是全库质量较高的两块。主要问题集中在：①下载引擎三个跨线程共享的 `static var` Set/Dictionary 无锁（注释称「良性竞争」，对 Bool 成立、对 Set/Dictionary 不成立，是崩溃风险）；②AGENTS 24 收口的合批标记在同 runloop 两个 done 时会丢掉第二个的去重；③约 1000 行启发式注入 JS 以 Swift 字符串内嵌，零编译期校验、零自动化回归，是当前最大的可维护性债。

计数：P0 = 1，P1 = 3，P2 = 12。

---

## P0

### P0-1 DownloadEngine 三个跨线程共享的 static Set/Dictionary 无任何同步，注释「良性竞争不加锁」的判断对集合类型不成立

- 位置：`iOS/SmartDownloader/Downloads/Downloader.swift:785-788`（声明）、`:731`（`ipDirectHosts.insert(host)`）、`:826`（`dnsCache[host] = ips`）、`:738`（`preferWebKit = true`）、`:660`（同款注释）
- 证据摘录：
  ```swift
  /// 已证实 IP 直连可用的域名（sticky；工作线程间共享，良性竞争不加锁）
  static var ipDirectHosts: Set<String> = []
  /// 域名 -> [IP] 解析缓存（进程内）
  static var dnsCache: [String: [String]] = [:]
  ```
  写点全部在切片工作线程：`fetchData`（Downloader.swift:716 起的重试循环）在连接层错误时对**每一批 6 个并发切片**（`:526` while + `:531` DispatchGroup，`maxConcurrency = 6` 于 `:444`）都可能并发进入 `fetchIPDirect → resolveHost`，`resolveHost` 末尾 `dnsCache[host] = ips`（`:826`），成功后 `ipDirectHosts.insert(host)`（`:731`）。
- 违反原则：AGENTS「并发与线程」第 1/3 条的精神——可变状态要么收敛主线程、要么有同步手段。Swift `Set`/`Dictionary` 是值类型 + COW，官方明确不支持多线程并发写；两个线程同时触发存储扩容/拷贝可导致内存损坏或崩溃。`preferWebKit: Bool` 一项确实是良性竞争，但注释把它不加区分地推广到了 Set/Dictionary。
- 影响：蜂窝/WAF 场景（连接层错误恰好是这些写点唯一的触发条件）下首个批次 6 线程同时失败 → 同时写 `dnsCache` 同一个 key，是现实可达的并发路径，不是构造出来的边角。后果是低概率但不可控的崩溃/数据损坏，且发生在用户网络最差、最不该崩的时刻。
- 建议：把两个集合的读写收敛到一个串行队列（`DispatchQueue(label:)` + sync/async）或 `NSLock`；改动面只有 `fetchData`/`resolveHost`/`fetchIPDirect` 三处，`preferWebKit` 可保持裸 Bool。

---

## P1

### P1-1 AGENTS 24 去重收口的合批标记会在同 runloop 两个 done 时丢弃第二个的去重

- 位置：`iOS/SmartDownloader/Downloads/Downloader.swift:93-101`（`observeTaskState` 内）
- 证据摘录：
  ```swift
  guard case .done = task.state, let series = task.seriesName,
        let sort = Self.episodeSort(fromFolderName: task.title) else { return }
  guard !self.pruneScheduled else { return }
  self.pruneScheduled = true
  ```
  `pruneScheduled` 置位后，下一个 runloop 只执行**当前捕获的这一个 task** 的 `pruneSupersededAttempts`（`:100`）；在置位与排水之间到达的第二个 done 直接 `return`，它的去重**不排队、不补跑**。
- 违反/风险：AGENTS 第 24 条是本轮刚修的承重逻辑（「同一部剧的同一集只允许有一条记录」）。双集并行（`SeriesDownloadCoordinator` 上限 2 集）几乎同时完成、或网络断导致两集最后一批同刻结束 时，两 个 done 的状态回写（`setTask` 的 `DispatchQueue.main.async`）会落在同一个主线程 drain 里，第二集的旧记录不摘——正是该条要消灭的「并列两条同名」会在窄窗口复现，直到下一次同集事件或重启 `loadLibrary` 去重才被掩盖。
- 影响：列表残留重复条目（点击旧条不播），低频但属于用户已实报过的故障形态回归。
- 建议：把布尔标记换成待处理队列 `[(series, sort, task)]`，排水时逐条 prune；或直接用 `DispatchQueue.main.async` 串行不设防（prune 本身幂等，代价是多跑几次空过滤）。

### P1-2 `SeriesDetailView.playIfDone` 把失败重试与播放路由的业务判断留在 View

- 位置：`iOS/SmartDownloader/Downloads/DownloadsView.swift:772-793`
- 证据摘录：
  ```swift
  private func playIfDone(_ task: DownloadTask) {
      guard task.state == .done, let url = task.outputURL else {
          ...
          if case .failed = task.state, !task.url.isEmpty {
              manager.run(task)            // 失败重试：业务动作在 View 里
  ...
      guard task.isHLSFolder else { playerItem = ... ; return }   // HLS/非 HLS 路由
      immersivePlayback = ImmersivePlaybackRequest(...)           // 沉浸式入口决策
  ```
- 违反原则：AGENTS「域内五层规则」View 行硬性约束「不写业务判断、不自己算状态」；同文件里下载页入口已把播放编排收进 `DownloadsViewModel.handleTap(_:identity:)`（DownloadsViewModel.swift:313-317），本页是残留的不一致点。
- 影响：重试条件、播放器选型这类规则散在 View 后，与 `EpisodePanelService.selectEpisode` / `playIfDone` 的其它调用方口径会漂移；且 View 内直接触发下载动作，违反「View 转发意图」的边界。
- 建议：判断与路由下沉到 VM 或 `EpisodePanelService` 类 Service，View 只发「点了这个 task」的意图。

### P1-3 约 1000 行启发式注入 JS 内嵌为 Swift 字符串：零编译期校验、零自动化回归、handler 协议无 schema

- 位置：`AdCleanerScript.swift`（554 行）、`AgeGateScript.swift`（384 行）、`SnifferScript.swift`（71 行）、`KeyboardDismissScript.swift`（60 行）、`ScrollCollapseScript.swift`（76 行）
- 证据摘录：`enum AdCleanerScript { static let source = #""" ... """# }` —— 空浮层启发式 + 滚动锁解锁 + scrollStuck 探针三套状态机全部写在 raw string 里；Swift 侧只按字符串前缀分发：
  ```swift
  if message.name == "adClean", let text = message.body as? String { print("BROWSER: adClean \(text)"); return }
  ```
  唯一被解析的结构化消息是 `browserScroll` 的 `"dir top kind"` 空格分隔协议（BrowserView.swift:641-653），其余全是自由文本日志。
- 违反/风险：属于「明显架构债」。①JS 语法错误编译期不可见，注入失败真机无日志（WKWebView console 不进 Xcode，注释自己也说明只能靠 messageHandler 回传）；②判据复杂度已经到了注释比代码长的程度（AdCleaner 头部 30 行铁律注释），每次改词表/阈值都只能靠手工构造本地合成页验证，iOS/smoke 四个冒烟工具（coretest/playtest/videocli/fetchtest）没有一支覆盖浏览域脚本；③五 个 handler 的名字字符串在 `makeUIView` 注册（BrowserView.swift:504-533）与 `dismantleUIView` 摘除（:578-583）两处手写，新增一个要同步改两处，漏一处就是 handler 泄漏。
- 影响：这三个脚本直接对用户网页做删 DOM/点按钮的破坏性操作，误伤面控制（保守边界）写得很细，但没有任何回归网兜住「改一行、坏一片」。
- 建议：①handler 名单收敛为单一常量表，注册/摘除同源；②把 AGENTS 里已验证过的「本地合成页 + handler 捕获」手法固化成第五个 smoke 工具（起本地 HTTP、断言 adClean/ageGate/browserScroll 回传），判据改动先跑它；③中长期把 JS 抽成 `.js` 资源文件（folder-sync 会自动带资源），至少让编辑器有语法高亮/lint。

---

## P2

### P2-1 `observeTaskState` 的 sink 只进不出，闭包强持有已删除任务

- 位置：`Downloader.swift:85-103`（`.store(in: &stateCancellables)` 于 :103）；`delete(at:)`/`remove`/`deleteSeries`/`deleteTasks` 均不取消对应 sink。
- 证据：`task.objectWillChange.receive(on:).sink { [weak self] _ in ... task.state ... }` —— 闭包强捕获 `task`。
- 影响：每个任务一条订阅随 App 生命周期永久存活，已删任务仍会向 `manager.objectWillChange` 转发（触发一次空转的 sizeRecompute 指纹检查）。量级小（随下载数线性），无功能性错误。
- 建议：任务从 `tasks` 移除时按 id 取消对应 AnyCancellable（id→cancellable 字典）。

### P2-2 引擎保存段「先删旧同集目录、再移动切片」，move 中途失败会同时丢旧副本与新副本

- 位置：`Downloader.swift:569-575`（删除同集 sibling）→ `:577-590`（createDirectory + moveItem 循环）
- 证据：`try? FileManager.default.removeItem(at: sibling)` 先执行，`try FileManager.default.moveItem(...)` 在其后逐片 move；AGENTS 注释承认「替换窗口只有 move 那几毫秒」。
- 影响：moveItem 对同卷是 rename，磁盘满等故障概率极低，但一旦中途抛错，旧的可播副本已删、新目录无 `playlist.m3u8`（残缺、不可播）——该集从「可播」变「无」。属于数据丢失路径上的顺序问题。
- 建议：先把旧目录 rename 到同集临时名，move 全部成功后再删临时目录；失败则把临时名 rename 回来。

### P2-3 删除清理在循环内逐条解析剧身份（SQLite），与 2026-11-14 主线程卡顿修复同款模式

- 位置：`Downloader.swift:159-168`（`removeActions(for:)` 循环调 `EpisodeActionsStore.identity(seriesName:sort:playlistURL:)`）；`EpisodeActionsStore.swift:308-309` 注释明确写「别在循环里反复调」。
- 影响：`deleteTasks` 批量删除大剧（几十上百集）在主线程串行开库查 `DramaCache.seriesIdentity`，正是 `PlaybackProgressViewModel` 修复过的那类 tab 切换卡顿来源。
- 建议：删除入口按剧名去重后一次性解析身份再分发，或整块移到后台队列。

### P2-4 编辑模式「全选」覆盖了 UI 上无法勾选的「下载中」任务

- 位置：`DownloadsViewModel.swift:246-252`（`allSelected`/`toggleSelectAll` 对全部 `manager.tasks`）、`DownloadsView.swift` `inProgressRow`（~:264-297，行内无勾选 UI）。
- 影响：编辑模式下进行中行没有任何勾选入口，但「全选→删除所选」会把它们（含下载中的文件与目录）一并删除；用户在已下载页看到的勾选数与实际删除范围不一致。
- 建议：要么全选范围限定在已完成条目，要么给进行中行补勾选态。

### P2-5 `WKUserScript` 注入与摘除不对称：`dismantleUIView` 无条件摘 5 个名字

- 位置：`BrowserView.swift:524-533`（browserScroll 仅 primary 注册）vs `:578-583`（五个名字全部 removeScriptMessageHandler）。
- 影响：非 primary webview 从未注册 `browserScroll` 也照摘——对未注册名是 no-op（Apple 未文档化该行为），当前无害；真正的债是名字字符串散落两处（已并入 P1-3 的建议）。
- 顺带：`isPrimaryBrowser`/`initialURL` 两个参数全库无消费者（grep 仅 BrowserView 内部自用），是为剧集内嵌页预留的死参数，接通前标注一下避免误删。

### P2-6 AdCleaner/AgeGate 常驻定时器 + 每 iframe 一份拷贝，SPA 页面主线程成本无实测账

- 位置：`AdCleanerScript.swift` 尾部 `setInterval(sweepAll, 2000)`、`setInterval(lockWatch, 1000)`（永不清）；注入 `forMainFrameOnly: false` → 每个iframe 各自持有一份拷贝与定时器；`MutationObserver → scheduleFullSweep` 200ms 去抖，在 DOM 持续变动的视频站上≈每 200ms 跑 50+ 个 `querySelectorAll`。
- 影响：有注释权衡（「成本高，不放进同步路径」）但没有耗电/卡顿数据；iframe 内跑广告清理是否必要也未区分。
- 建议：给 sweep 加一次实测（PERF 探针已有基建）；iframe 是否注入 `AdCleaner` 单独拍板。

### P2-7 WebKitFetcher 超时后 `waiters` 表项滞留

- 位置：`WebKitFetcher.swift:55-58`（120s 超时 throw）—— 超时分支不从 `waiters` 移除 key；下载终态回调（`downloadDidFinish`/`didFailWithError`）到达时 `finish(key:)` 会取到已废弃的 waiter 闭包并向其写结果箱（闭包仍被字典持有，内存安全但语义已死）。
- 影响：极慢下载（>120s）时表项滞留到终态，量级可忽略；属可读性问题。
- 建议：超时分支顺手 `waiters.removeValue(forKey:)`（下载继续跑，终态走 results 暂存，两阶段握手本来就能兜住）。

### P2-8 LocalMediaServer 不支持后缀 Range（`bytes=-N`），按 0 起始整文件回 206

- 位置：`LocalMediaServer.swift` `HTTPConnectionHandler.handleRequest`（Range 解析段：`let a = Int64(bounds[0]); start = max(0, a)`）。
- 影响：AVPlayer 常用显式 range，后缀 range 少见；误回整文件只是多传流量，不会错播。
- 建议：`bounds[0]` 为空时按 `total - suffix` 计算 start，或对不认识的 range 形态直接回 200 全量（去掉 partial 标记）。

### P2-9 删除路径的两处不对称：`deleteSeries` 不做空壳清理、散装卡无独立删除入口

- 位置：`Downloader.swift:207-220`（deleteSeries：只删 members 的集目录，不清剧目录壳；deleteTasks 于 :239-252 有 `hasContent` 空壳清理）；`DownloadsView.swift` completedCard：剧卡有 contextMenu「删除全剧」，散装卡非编辑模式无任何删除入口。
- 影响：deleteSeries 后磁盘可能留下只含残缺目录的剧壳（无 playlist，不会被重新导入，纯占空间）；散装条目删除只能走编辑模式勾选。
- 建议：deleteSeries 复用 deleteTasks 的空壳清理逻辑；散装卡补 contextMenu（同一能力，AGENTS 16 的精神）。

### P2-10 `PaperCover` 主线程同步解码封面文件

- 位置：`DownloadsView.swift:636`（`UIImage(contentsOfFile: url.path)` 于行渲染中）。
- 影响：封面源文件可达 1200×1600（DramaCoverCache 收割原图），列表滚动时每行同步解码全尺寸图，是潜在的滚动卡顿点（本域其余主线程卡顿源都已后台化）。
- 建议：走 `AsyncImage` 本地路径或预降采样（缩略图缓存）。

### P2-11 `PlayerView` 在 View 内创建 AVPlayer / tracker / 调 LocalMediaServer

- 位置：`DownloadsView.swift:912-966`（`AVPlayer(url:)` :940、`PlaybackProgressTracker` :939-943、`LocalMediaServer.shared.playbackURL` :947）。
- 违反/边界：AGENTS 明文只约束 VM（「不创建 AVPlayer/FileManager/URLSession」），View 层属灰色地带；但与播放域「组装根只做 DI」的口径不一致，散装播放小入口可接受，标注为已知债。
- 建议：至少把「起播 + tracker 挂接」抽成一个小 Service/VM，View 只持有 `playerRequest`。

### P2-12 ScrollCollapsePolicy 纯函数化只完成一半：前置守卫留在 View，状态机不可整体单测

- 位置：`BrowserView.swift:161-171`（`handleScrollReport` 的 `guard !addressFocused, !keyboardVisible`、`chromeQuietUntil` 静默窗）vs `ScrollCollapsePolicy.swift:33-42`（`resolve` 只吃 direction+top）。
- 影响：`resolve` 本身可测，但「输入→收不收起」的真实决策链一半在 View，键盘/聚焦/静默窗这些条件改动时没有可回归的纯函数。
- 建议：把三个前置（addressFocused、keyboardVisible、quietWindowActive）作为 `resolve` 入参并入，View 只透传。
- 备注（同维度）：`PlayerGesturePolicy` 在播放域已按「仅剩纯函数」收敛，本条的收口方向与它一致。

### 文档漂移（不占 P 编号，随 P2 记录）

- `DownloadsViewModel.swift:7` 注释仍写「与剧详情页 SeriesDetailView 的 @AppStorage 共享同一 key」，实际 SeriesDetailView 已改走 `DownloadsSortPreferences`（DownloadsView.swift:699-703），注释落后一个版本。
- `WebViewStore.swift:1` VM `import SwiftUI`：AGENTS 只禁 VM import UIKit，不算违规，记录在案。

---

## 做得好的

1. **AGENTS 24 三源收口完整落地且可追踪**：引擎保存段同集先删旧目录（Downloader.swift:569-575）、`loadLibrary` 与 `downloadedEpisodeFolders` 共用同一份 `preferredEpisodeFolder` 规则（:269-296、:400-419，注释点名「列表与播放必须共用」）、`registerEpisode`/落盘成功两处调用 `pruneSupersededAttempts` 且 keeper 语义与约定逐字一致（:117-132）；每处都带成因注释（用户实报原文 + 三条成因编号），审计时不用反向推理。
2. **WebKitFetcher 两阶段握手**（WebKitFetcher.swift:59-116）：`paths/results/waiters` 三张表 + 主线程状态收敛 + 「拿到 download 前 delegate 可能先回调」的暂存覆盖，把 Apple async-only API 纳入同步管线的方式干净；async 岛边界（岛内只做 `startDownload`）与 AGENTS 例外清单吻合。
3. **LocalMediaServer 边界处理完整**：健康判据带 `listener.state`（防系统静默回收 socket）、restart 端口稳定策略 + 50ms 让拍防 EADDRINUSE、路径穿越防护（`rootPath + "/"` 前缀校验）、`port=0` 防呆（不拼 `http://127.0.0.1:0`，回退文件 URL 让上层报可读错误）、仅绑定 127.0.0.1。
4. **两个 VM 的后台化管线是卡顿修复的范本**：主线程只做快照拷贝与发布（`TaskSnap`）、代际令牌丢弃迟到结果（PlaybackProgressViewModel.refreshGeneration）、指纹去抖连 work item 都不排（DownloadsViewModel.sizeSignature）、`DispatchWorkItem` cancel 旧任务——与 AGENTS「并发与线程」第 4 条逐条对应。
5. **注入脚本的保守边界做得细**：AdCleaner 首见先 `hasRealContent`、隐藏态下同步摘掉自身隐藏再量内容、`unlockScroll` 深度上限 2、`scrollStuck` 只在确认锁状态才动手；AgeGate 无 dialog 语义全屏层只认 score 3、每页最多 4 次、30s 后停 ticker——「自动删/自动点」的误伤面控制明显花过功夫，且全部有日志回传（ageGate/adClean handler）支撑判据调优。
6. **纪律核查全绿**（本域）：View/VM 零 `UserDefaults`/`FileManager`/`UIScreen`，持久化全走 Service（DownloadsSortPreferences/BrowserStartPage/QuickLinkStore）；Infra 除 SwipeBackSupport（View 桥件）外零 import SwiftUI、零 @Published；全库 async 岛在本域仅 WebKitFetcher.swift:96 一处。

## 关键数据事实

- 文件规模：Downloader.swift 1174 / DownloadsView.swift 966 / BrowserView.swift 773 / AdCleanerScript.swift 554 / AgeGateScript.swift 384 / DownloadsViewModel.swift 317 / LocalMediaServer.swift ~310 / PlaybackProgressViewModel.swift 100 / WebViewStore.swift 89 / KeyboardObserver.swift 85 / ScrollCollapseScript.swift 76 / SnifferScript.swift 71 / SwipeBackSupport.swift 50 / BrowserStartPage.swift 47 / ScrollCollapsePolicy.swift 44 / AppHaptics.swift 33 / DiskUsageService.swift 34 / DownloadsSortPreferences.swift 21 / WebKitFetcher.swift ~200。
- 注入脚本 5 份、messageHandler 5 个：sniffer / adClean / ageGate / keyboardDismiss / browserScroll（仅主浏览页注册）。
- 下载并发：`maxConcurrency = 6`（Downloader.swift:444）；URLSession 重试 4 次退避 2/4/8s（:716-747）；`httpData` 信号量超时 35s；WebKit fetch 超时 120s；本地服务首选端口 18731/18732/18733。
- 去重收口调用点 3 类：`registerEpisode`（登记）、`observeTaskState` done 回调（落盘）、引擎保存段目录替换；列表去重规则 `preferredEpisodeFolder`（无后缀目录优先，其次创建时间最新）被 loadLibrary 与 downloadedEpisodeFolders 共用。
- 本域 async 岛 1 处：WebKitFetcher.swift:96（`Task { @MainActor in ... startDownload ... }`）。
- `isPrimaryBrowser=false` / `initialURL` 参数当前无消费者（全库 grep 仅 BrowserView 自身）。
