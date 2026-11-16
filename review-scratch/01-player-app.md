# iOS 播放域 + 组装根 架构/SOLID/交互审查（01-player-app）

审查范围：`iOS/SmartDownloader/player/` 全部 24 个 Swift 文件 + `iOS/SmartDownloader/App.swift`，合计 8015 行（wc -l 实测）。判据：AGENTS.md「iOS 架构约定」「域内五层规则」「并发与线程」「具体约定 1–24」。只读审查，未改动任何源码。

## 小结

五层边界与并发约定执行质量高：Service 层零 SwiftUI/零 @Published、VM 不碰系统对象、组装根只做注入、async 岛仅约定的一处、代际令牌/幂等标志成体系。AGENTS 2（手势仲裁）、12（全屏/冻帧/底栏）、19（选集面板）、并发节的拍板记录在实现中逐条可对上。发现 **P0 = 0、P1 = 2、P2 = 13**。两个 P1 都是单点可修的正确性/约定问题：①「从头播放」菜单导致手势仲裁闸门泄漏、点按与 2x 静默失效；②全屏倍速按钮复用了 AGENTS 已明文记录修掉的 `"0$"` 字面量替换 bug，且违反「文案走 rateText 一处给出」。

---

## P1（违反 AGENTS 约定或交互正确性问题）

### P1-1 「从头播放」菜单令 `isSeekGestureActive` 泄漏 → 卡片点按/长按 2x 静默失效

- **位置**：`player/DramaPlayerView.swift:499`（调用点，**用户文件**）+ `player/DramaPlayerViewModel.swift:520`（根因）
- **证据**：
  - `DramaPlayerView.swift:499`（更多菜单「从头播放」）：`playback.seek(fraction: 0)` —— 无任何配对的 `endSeekGesture()`；
  - `DramaPlayerViewModel.swift:519-520`：`func seek(fraction: Double) { isSeekGestureActive = true ... }` —— 顶部无条件置位仲裁闸门；
  - 消费方：`DramaPlayerView.swift:177`（`if playback.isSeekGestureActive { TAP SKIP }`）、`:198`（长按 perform `guard !playback.isSeekGestureActive else SKIP`）、`PlayerFullscreenController.swift:853/878`（全屏同款两处）。
- **违反**：`isSeekGestureActive` 的语义是「seekPan 手势独占本次触摸」的仲裁闸门（AGENTS 具体 2 条），只能由 `beginSeekGesture`（pan .began，`PlayerPagingScrollView.swift:323` / `PlayerFullscreenController.swift:904`）置位、由 pan 结束分支（`:340` / `:921`）或 `load()`/`stop()`（VM:274/582）复位。`seek(fraction:)` 是被非手势路径复用的播放 API，把置位写进它就破坏了置位/复位配对。
- **影响**：点过「从头播放」后，在用户下一次横滑 seek（`.ended` 会顺带复位）、切集或退出播放页之前，竖屏卡片**点按暂停/播放与长按 2x 全部被静默 SKIP**（日志只有 `TAP SKIP reason=seekGestureActive`），全屏容器 tap/长按同样被拒。横滑 seek 主路径不受影响（`.changed` 里的置位本来就是冗余的，`.began` 已置）。
- **建议**：删除 `DramaPlayerViewModel.swift:520` 的 `isSeekGestureActive = true`（两条 pan 路径均在 `.began` 独立置位，删掉对它们零影响）；若担心语义，另加不触闸门的 `seekAbsolute` 供菜单重播使用。

### P1-2 全屏倍速按钮复用已被 AGENTS 记录修掉的 `"0$"` 字面量替换 bug，违反「文案走 rateText」

- **位置**：`player/PlayerFullscreenControlsView.swift:722-725`（`trimmed`）+ `:344-348`（rate sink 调用点）
- **证据**：
  ```swift
  private static func trimmed(_ rate: Double) -> String {
      String(format: "%.2f", rate)
          .replacingOccurrences(of: "0$", with: "")        // 字面量匹配，永不命中
          .replacingOccurrences(of: "\\.$", with: "")      // 同上
  }
  ```
  sink：`let title = abs(rate - 1.0) < 0.001 ? "倍速" : "\(Self.trimmed(rate))×"` → 2.0/1.5/0.75 显示「2.00×」「1.50×」「0.75×」。
- **违反**：AGENTS 具体 12 条明文记载此 bug 已修——「旧实现 `replacingOccurrences(of: "0$")` 是正则写法、匹配不到字面量，面板里全是『2.00倍速』……文案走 `rateText`」；`DramaPlayerViewModel.rateText`（:204-209，`hasSuffix("0")` 实现）是唯一口径，竖屏弹层 `PlaybackRatePanel.playbackRateLabel` 走它是对的，全屏按钮另写了一套并复现同款 bug。
- **影响**：全屏底栏倍速文案与画布 22:77/竖屏弹层不一致（多一位小数）；这是「同一文案两处实现必然漂移」的实证。
- **建议**：删除 `trimmed`，sink 直接用 `playback.rateShortText`（或 `DramaPlayerViewModel.rateText(rate) + "×"`）。

---

## P2（改进建议 / 架构债）

### P2-1 预热池在飞淘汰标记的方向与注释相反（PlaybackPlayerService.preload）

- **位置**：`player/PlaybackPlayerService.swift:84`
- **证据**：注释（:82-83）「淘汰在飞标记：迟到的预热回调发现标记没了就自行丢弃」，实现却是 `preloadingSorts.subtract(wantedSorts)`——去掉的是 **wanted** 集的标记：
  - wanted 且在飞的集：标记被去掉 → 下方 `!preloadingSorts.contains` 判定通过 → **同一集重启第二次 `asset.load(.isPlayable)`**（两个在飞加载并发；回调守卫保证最终只落一个资产，浪费一次 m3u8 拉取解析）；
  - 非 wanted 且在飞的集：标记保留 → 迟到回调通过 `contains` 检查 → **把已被淘汰的资产存回池**，与「回调落地发现已移除即丢弃」相反，直到下一次 `preload()` 才被再次淘汰。
- **影响**：无用户可见故障（正确性由回调守卫兜住），但每次停稳都可能多跑一次清单解析，且池里短暂残留未订阅资产。
- **建议**：淘汰对象应为「不再 wanted 的在飞集」：`preloadingSorts = preloadingSorts.subtracting(unwantedSorts)`（unwanted = 全部在飞集 − wanted）。

### P2-2 下载进度驱动的选集面板刷新每 0.25s 全量扫盘 + 3 次 SQLite 查询（主线程）

- **位置**：`player/PlayerFeedViewModel.swift:257 → 261-264 → 158（scanDisk 默认 true）`；`player/PlaybackQueueService.swift:231-233（buildSlots）/152（allSorts→DramaCache.allSorts + episodeTotal）/181（resolveIdentity）`
- **证据**：`manager.objectWillChange.sink { scheduleEpisodePanelRefresh() }` 去抖 0.25s 后调 `refreshEpisodePanel(reason: "downloads")`，`scanDisk` 用默认 `true` → `refreshAvailability()` → `buildSlots`：`contentsOfDirectory` 逐目录 stat `playlist.m3u8` + `DramaCache.allSorts` / `episodeTotal` / `seriesIdentity` 三次 SQLite 查询，全部在主线程。下载中任务状态变化很密，去抖只合并了调用次数、没减掉磁盘成本（97 集量级时每轮 ≈ 100 次文件 stat）。
- **影响**：下载期间主线程周期性做目录 IO + 查库；与 App.swift 注释里刚修过的「每次切 tab 全量重扫 97 集盘」同类问题。
- **建议**：downloads 路径对 `refreshAvailability` 加节流（如 ≥1s 才真正扫盘，期间复用上次结果），或仅在任务进入终态（done/failed）时扫盘、进度中间态只重配 phase。

### P2-3 DramaPlayerViewModel（922 行）职责宽度与拆分点

- **位置**：`player/DramaPlayerViewModel.swift`（≈15 个 @Published、8 类职责）
- **证据**：同类内混装：播放控制（play/pause/seek/rate）、手势仲裁旗标（isSeekGestureActive/tapSuppressionDeadline）、HUD 瞬态机（isScrubbing + scrubLingerWork + isCleanScreenFlashActive + spinnerDelayWork）、全屏态（isFullscreen/isFullscreenLocked/rotationAngle）、冻帧、行为数据写入（liked/saved→writeAction）、前后台恢复与 item 重建、加载管线（StatusWatch + autoRetriedSorts + 看门狗）。
- **评估**：不判 P1——AGENTS 明文「不为了分层而分层」，且各块注释边界清楚、状态互斥关系（如 isSeekGestureActive 非渲染旗标 vs isScrubbing 渲染态）写得很清。但其中三块已具备「第二个变更理由」：① HUD 瞬态机自成闭环（两类 WorkItem + 两个标志 + load/stop 的清场规则）；② liked/saved 写入是纯 Service 转发；③ StatusWatch/重试只依赖 playerService，可归播放 Service 侧。P1-1 的闸门泄漏正是职责混装（仲裁旗标与播放 API 同方法）的直接产物。
- **建议**：优先抽 ①（HUD/瞬态子对象）与 ③（加载协调器），动作意图仍由 VM 暴露；② 可并入 `EpisodeActionsStore` 门面。

### P2-4 PlayerFullscreenControlsView（1061 行）混装控制层与图标绘制库

- **位置**：`player/PlayerFullscreenControlsView.swift:850-1061`
- **证据**：文件底部约 210 行是 4 个独立可复用的 UIView 图标类（`FullscreenGlyphView` / `PlayPauseGlyphView` / `VolumeGlyphView` / `LockGlyphView`），与控制层（布局/可见性/动作）无状态耦合；SwiftUI 侧同类图元已有独立文件先例（`PlayerOverlayGlyphs.swift`）。
- **建议**：拆出 `player/PlayerFullscreenGlyphs.swift`；控制层剩约 850 行（布局 + 可见性 + 绑定），单一职责即成立。

### P2-5 PlayerFullscreenController（1000 行）四职责并存

- **位置**：`player/PlayerFullscreenController.swift`
- **证据**：① 进/出/转体 CA 动画编排（performEnter/Exit/Reorientation + 关键帧数学，~400 行）；② videoLayer 搬运与 restore；③ 抽屉呈现管理（presentDrawer/dismissDrawer/backdrop/dim/geometry/面板热更新，~250 行）；④ 全屏手势仲裁 + 更多菜单 + toast（~300 行）。
- **评估**：作为 UIKit controller 可接受，但 ③ 与 ①/④ 无共享状态（只共用 container/geometry），抽屉面板本体也已在 `FullscreenDrawers.swift`。
- **建议**：抽 `FullscreenDrawerController`（持有 container 弱引用 + geometry），控制器瘦身 ~250 行；手势仲裁若继续膨胀再议。

### P2-6 @Published 粒度：0.25s tick × 4 个 @Published，N 张卡片全 body 重估

- **位置**：`player/DramaPlayerViewModel.swift:855-862`（syncTime 每 0.25s 写 currentTimeText/durationText/remainingTimeText/progress）；`player/DramaPlayerView.swift:13`（`@ObservedObject playback`）
- **证据**：SwiftUI 卡片订阅的是 VM 的 objectWillChange，每次 tick 4 个属性变化 → 全部在册卡片（N 张）body 重估； UIKit 控制层则用逐属性 `.sink`（`PlayerFullscreenControlsView.bind`），只刷对应 label，无此成本。VM 对 isScrubbing/isPlaying 已做「翻转才赋值」节流（refreshIsPlaying 注释），但时间/进度四件套天然每 tick 都变。
- **对照（做得对的）**：选集面板走 `episodePanelSubject`（CurrentValueSubject 专用通道），全屏抽屉不挂 objectWillChange —— AGENTS 19 要求的对比样本成立。
- **建议**：把 tick 状态（时间文案/进度）拆成子 ObservableObject 或迁去 UIKit 式逐属性订阅；至少邻卡可改读快照（现邻卡已用 episode.preview* 回避显示错乱，但 body 仍会被 tick 重估）。

### P2-7 PlayerOrientationTrigger（Service）直接持有并驱动 ViewModel

- **位置**：`player/PlayerOrientationTrigger.swift:37-39（init(playback: DramaPlayerViewModel)）、consume 中读 isFullscreen/isFullscreenLocked/videoIsLandscape/isReady、调 enterFullscreen/exitFullscreen/rotateFullscreen`
- **证据**：分层表约定「Service 不反向依赖 ViewModel」；本 Service 直接耦合具体 VM 类型并回调其方法。
- **评估**：AGENTS 12 明文记载「PlayerOrientationTrigger→VM→PlayerFullscreenController 链」，属约定内实现，不判 P1。
- **建议**：改闭包注入（`onEnter/onExit/onRotate/onStateQuery`）或直接发事件给 VM，CoreMotion 判稳逻辑即可脱离 VM 单测（阈值/稳定窗是纯逻辑，现与 PlayerGesturePolicy 同级可测性却不同）。

### P2-8 前后台播放意图口径与「在播」口径不一致

- **位置**：`player/DramaPlayerViewModel.swift:410`
- **证据**：`wasPlayingBeforeBackground = player.timeControlStatus == .playing`；而 VM 注释与 `refreshIsPlaying`/`togglePlayback` 的既定口径是 `!= .paused`（waitingToPlayAtSpecifiedRate 算在播，AGENTS 12 亦记载）。
- **影响**：缓冲等待态进后台会被判成「未在播」，回前台不续播（needsRebuild=false 分支不 play）。
- **建议**：统一为 `!= .paused`。

### P2-9 全屏控制层两个「死件」：亮度钮无功能、updateSubtitle 无调用方

- **位置**：`player/PlayerFullscreenControlsView.swift:660-663（brightnessTapped 只 keepVisible）、:697（updateSubtitle 无任何调用方，grep 全库仅定义处）`
- **证据**：画布 22:25 有亮度钮，实现里点按只续期控件可见性，不调亮度、无回调接线；字幕 label 恒 hidden（本地 HLS 无字幕轨），`updateSubtitle` 是悬空 API。
- **建议**：亮度钮要么接 `UIScreen.main.brightness`（注意 main 屏语境）要么收进「更多」菜单；`updateSubtitle` 加注释说明保留原因（未来字幕轨）或删除。

### P2-10 refreshCardsIfNeeded 任一变化重建全部卡片 rootView

- **位置**：`player/PlayerPagingScrollView.swift:347-360`
- **证据**：`lastRefreshedSort/Ready/Toast/SlotsKey` 任一变化 → `for slot in parent.slots { hosts[slot.sort]?.rootView = parent.makeCard(slot) }`。每次 settle 内 isReady 翻转两次（load 置 false、ready 置 true）+ toast 变化，都是 O(N) 次 UIHostingController rootView 整树重建。
- **建议**：只重建活跃卡 ±1（视频层/渐变只在活跃卡变化），或按 slot 指纹 diff。N 小（≤12）时可不动，长剧（30+）建议做。

### P2-11 播放域颜色未进 DesignTokens（裸 hex 与 DWColor 同值异名）

- **位置**：`player/FullscreenDrawers.swift`（15+ 处）、`player/PlayerFullscreenController.swift:541,708`、`player/PlayerFullscreenControlsView.swift`（多处）；便捷构造 `UIColor(hex:)` 定义在控制层 View 文件顶部（全局作用域）
- **证据**：`#A05243`=DWColor.paperCinnabar、`#35393B`=paperTrackFill、`#1C1E1F`=paperInk、`#F2F0EA`=paper、`#C4C7C3`=paperTrack 等同值异名；用户文件 `DramaPlayerView.swift` 亦有裸 `Color(hex: "#0F1212")`。
- **评估**：播放页仍是墨本轨，AGENTS 色板规则针对纸本轨，故 P2；但 token 一改播放域不跟。
- **建议**：把 overlay/ink 常量并入 `Shared/DesignTokens.swift`，`UIColor(hex:)` 移出 View 文件。

### P2-12 组装根 App.swift 附带调试基础设施与状态修复逻辑

- **位置**：`iOS/SmartDownloader/App.swift:44-77（stallProbe）、:241-265（autoTest 轮询）、:141-146（profileDetailActive 复位修复）`
- **证据**：AGENTS 要求组装根「只做依赖注入与拼接、无业务 if/else」；现状叠加了主线程卡顿探针、设备自动冒烟轮询、splash 编排、tab 切换时的 detailActive 复位。均有注释与排障理由（Debug 探针按约定保留）。
- **建议**：长期把探针/冒烟移入 Debug 工具文件（如 PlayerPreviewEntry 的同类做法）；`profileDetailActive` 复位属页面状态协调，可下沉到 ProfileView 自身。

### P2-13 全屏「下一集」以 episodeTotal 推进，非 1…N 编号时会静默落空

- **位置**：`player/PlayerFullscreenController.swift:706-716（advanceToNextEpisode）` + `player/PlayerPagingScrollView.swift:631（scrollToSort noSlot SKIP）`
- **证据**：`guard current < total` 用元数据总集数，`autoAdvanceSort = current + 1`；若集号 0 起或跳号导致 `current+1` 无槽位，`scrollToSort` 打 `SKIP reason=noSlot` 后无任何用户反馈（autoAdvanceSort 已被 sink 复位，也不弹「已经是最后一集」）。当前「第%02d集」1 起编号下不触发。
- **建议**：改用 FeedVM 的 `hasNext(after:)` 口径判定边界，或在 noSlot 时回 toast。

---

## 做得好的

1. **五层边界核查通过**：player/ 内 7 个 Service（PlaybackQueueService/PlaybackPlayerService/EpisodePanelService/PlaybackProgressTracker/PlayerPreferences/PlaybackFreezeFrame/PlayerOrientationTrigger）零 `import SwiftUI`、零 `@Published`、无 UI 依赖；VM 无 `UserDefaults`/`FileManager`/`URLSession`（持久化全走 PlayerPreferences/EpisodeActionsStore）；AVPlayer 只在 PlaybackPlayerService 创建；`DramaPlayerContainer`（39 行）是干净的组装根——只注入 manager、接线 configure/stop/statusBarHidden，无业务 if。
2. **手势仲裁状态机与 AGENTS 具体 2 条逐项吻合**：`.began` 即置闸门（非首个 .changed）、panLock 幂等标志 + 全部结束分支与 dismantle 兜底恢复、方向过滤严格大于（45° 让给系统 pan）、左缘 30pt 保留、seek 抬手不补 seek、250ms 吞单击窗（VM 与全屏各一份、机制相同）、`location(in:)` 陷阱注释与规避齐全。唯一漏洞即 P1-1 的菜单路径。
3. **并发约定执行严格**：async 岛仅 `PlaybackPlayerService.preloadOne` 的 `asset.load(.isPlayable)`（Task @MainActor，岛内只做加载回主线程碰状态）；KVO/NotificationCenter/LocalMediaServer 回调全部显式回主线程（已核 `Infra/LocalMediaServer.swift:169,190` 强制主线程 → makeItem completion 主线程成立）；DispatchWorkItem + 代际令牌（loadGeneration/settleGeneration/hintToken/toastToken）+ 幂等标志（systemPanLocked/longPressOwnedTouch）成体系；主线程无 semaphore；`SWIFT_STRICT_CONCURRENCY=minimal` 前提下无遗漏。
4. **选集面板数据链与 AGENTS 19 逐条对上**：集号唯一来源是队列槽位 sort；总集数补齐 `1…max(declared, ∪max)`（PlaybackQueueService.allSorts）；`selectEpisode` 统一收口、返回值决定面板收起/留下、当前集点按也给反应；CurrentValueSubject 专用通道 + 抽屉 `apply` 仅集号变化重建网格（防 0.3s 进度更新拽走滚动位置）；提示落面板标题位。
5. **冻帧换集链路与 AGENTS 12 描述逐字对应**：load 在 `isReady=false` 之前取帧（VM:281）、`holdFreezeFrame` 盖 videoLayer 子层随容器旋转、ready 后 0.15s 淡出、6s 看门狗 + 失败/超时/abort 三分支都放掉；全屏 `concealForReveal` 不再置 `videoLayer.opacity=0`（黑闪根因已修），无图退化原路径。
6. **停稳/连播/边界信号链完整复用既有管线**：pageSettled 先 `refreshAvailability()` 对账磁盘再取槽位；连播只发信号（autoAdvanceSort）由 Coordinator 动画翻页回写 `scrollViewDidEndScrollingAnimation→report→schedulePageSettle`；「已经到底了」只在 `onPullBeyondEnd`（末页再滑一次）触发；槽位可用性指纹（lastRefreshedSlotsKey）保证「播放中下完的集」卡片重绘。

## 关键数据事实

- 范围与体量：`player/` 24 文件 + `App.swift` = **8015 行**（wc -l）；Top3：PlayerFullscreenControlsView 1061 / PlayerFullscreenController 1000 / DramaPlayerViewModel 922；其余：DramaPlayerView 669（用户文件）、PlayerPagingScrollView 580、FullscreenDrawers 573、PlayerFeedViewModel 397、PlayerOverlayGlyphs 372、PlayerSurfaceContainer 293、EpisodePanel 279、PlaybackQueueService 233、PlayerFeedView 225、PlayerOrientationTrigger 201、PlaybackPlayerService 158、EpisodePanelService 147、PlaybackProgressTracker 124、PlaybackRatePanel 91、PlayerPreviewEntry 81、PlaybackFreezeFrame 78、PlaybackModels 75、DramaEpisode 71（用户文件）、PlayerPreferences 47、DramaPlayerContainer 39、PlayerGesturePolicy 16。
- `seek(fraction:)` 调用点全库 3 处：PlayerPagingScrollView:333（pan 配对 ✓）、PlayerFullscreenController:918（pan 配对 ✓）、DramaPlayerView:499（菜单重播，**未配对** ✗ → P1-1）。
- `UIScreen.main` 在 player/ 零使用；`try!`/`as!`/`DispatchSemaphore` 零；player/ 内 async 岛仅 1 处（PlaybackPlayerService preloadOne；WebKitFetcher:97 在 Infra）。
- FeedVM 直接 `= PlaybackPlayerService()` / `= EpisodePanelService()` 硬实例化（无注入点）；AGENTS 未要求协议注入（规则 9），替换测试时需注意。
- 全屏倍速五档 `rateOptions = [2.0, 1.5, 1.25, 1.0, 0.75]` 与 AGENTS 一致；存储档位不在表内回落 1.0 有守卫（VM init）。
- 涉及「用户文件」标注的发现：P1-1（DramaPlayerView.swift:499）、P2-11（DramaPlayerView.swift 裸 hex）；`player/` 下无 DesignTokens.swift（在 Shared/，player 文件经 DWColor 引用）。
- P0 = 0；P1 = 2（P1-1 交互正确性、P1-2 违反 AGENTS 12 明文约定）；P2 = 13。
