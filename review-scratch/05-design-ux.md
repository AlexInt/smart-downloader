# 05 · 设计一致性与交互合理性专项审查（iOS View 层）

范围：AGENTS 指定的 11 个 View 文件 + 为判定而读的共享层（DesignTokens / MainTab / AppHaptics / ToastView / PosterGrid / ProfileViewModel / PlayerFeedViewModel / DramaPageViewModel / DramaNativePage / PlayerFullscreenController）。判据 = AGENTS「纸本单轨视觉」「具体约定」已拍板记录（只评估设计代价与遗留债，不当翻案）+ Nielsen 启发式。标注「用户文件」者：DesignTokens.swift、DramaEpisode.swift、DramaPlayerView.swift。

## 顶部小结

- **P0：0 条**。未发现正确性/崩溃/数据丢失风险。
- **P1：6 条**。最重的三条：① 全屏倍速按钮仍用 AGENTS 已定性为 bug 的 `"0$"` 字面量替换（全屏显示 2.00×/1.50×，竖屏显示 2.0×/1.5×，同一档位两种文案）；② 当前集描边色在 SwiftUI 侧 `#A05142` 与 UIKit 抽屉侧 `#A04D42@0.5` 已实际漂移——裸色值与 DWColor 双源重复的代价已经兑现；③ 「已看完」一词存在两种互斥口径（播放看完 vs 最后一集已下载），「已加入下载队列」同一语义三种通道两种写法。
- 纸本轨五页的组件化与状态完备性整体质量高（PosterGrid 三处共用、错误详情可复制、破坏性操作全确认）；债集中在**播放域 UIKit 侧的双源维护**与**无障碍体系性缺口**（Dynamic Type 全库不支持、Browser/Downloads 零 accessibility 覆盖）。

---

## P0

无。

---

## P1

### P1-1 全屏倍速按钮文案：AGENTS 已定性的「0$」bug 在另一处回归

- **位置**：`player/PlayerFullscreenControlsView.swift:722-726`（`trimmed`），绑定于 `bind()` 的 `playback.$playbackRate`（:371-376）。
- **证据**：
  ```swift
  String(format: "%.2f", rate)
      .replacingOccurrences(of: "0$", with: "")
      .replacingOccurrences(of: "\\.$", with: "")
  ```
  `String.replacingOccurrences` 是字面量替换，`"0$"` 永远匹配不到（`\\.$` 同理双错）。
- **对照**：AGENTS「具体约定 12」明文：「旧实现 `replacingOccurrences(of: "0$")` 是正则写法、匹配不到字面量，面板里全是『2.00倍速』」；VM 侧已修复（`DramaPlayerViewModel.rateText` :161-165 用 `hasSuffix("0")` 去尾 0），竖屏倍速钮走 `rateShortText` → 「2.0×」「1.5×」。
- **违反**：AGENTS 约定 12「档位由 rateOptions 一处给出、文案走 rateText」；Nielsen 一致性；已知 bug 模式未随修复收敛。
- **影响**：选 1.5×/2.0× 后全屏底栏显示「1.50×」「2.00×」，与竖屏「1.5×」「2.0×」不一致（1.25/0.75 恰好无尾 0，问题被掩盖，更难被发现）。
- **建议**：删除 `trimmed`，改用 `DramaPlayerViewModel.rateText`（或 `playbackRateLabel`）。

### P1-2 当前集描边色两轨漂移：裸 UIColor 与 DWColor 双源重复已兑现为真实不一致

- **位置**：`player/FullscreenDrawers.swift:466` vs `Shared/DesignTokens.swift:147` + `player/EpisodePanel.swift:98`。
- **证据**：
  - UIKit 抽屉：`UIColor(hex: "#A04D42").withAlphaComponent(0.5)`（描边）；
  - SwiftUI 竖屏面板：`.strokeBorder(DWColor.episodeCellStroke, lineWidth: 1)`，token 定义 `episodeCellStroke = Color(hex: "#A05142")`（不透明度 1）。
  同一语义（选集格「当前集」描边）两个色值 + 两个透明度。
- **上下文**：FullscreenDrawers.swift 共 17 处裸 `UIColor(hex:)`，PlayerFullscreenControlsView.swift 8 处，PlayerFullscreenController.swift 2 处（`#0B0C0E`、`#1C1E1F`），合计 ≈27 处在 DesignTokens 之外复写了已有 token（overlayInk `#E8E6DF`、overlayInkSub `#C4C7C3`、episodeCell `#25282B`、episodeCellCurrent `#2A2422`、ratePanel `#1C1E1F`、rateRowSelected `#35393B`、rateTextSelected `#F2F0EA`、overlayCinnabar `#A05243`、overlayButton `#8C9190`）。
- **违反**：AGENTS「纸本单轨视觉 6」的精神（token 单源）；本审查维度①点名评估的重复。UIKit 侧无法直接用 SwiftUI Color 不是豁免理由——缺的是 UIColor 镜像层。
- **影响**：改 DWColor 不改 UIKit 副本 → 竖屏与全屏同一控件颜色分叉（描边已经分叉）；每次调色要人工对齐 27 处。
- **建议**：在 DesignTokens.swift（或 Infra）加 `enum DWUIColor` 镜像全部墨本轨 token，FullscreenDrawers/Controls/Controller 全部改引镜像；顺手把 `#A04D42` 收敛为 token 值。

### P1-3 无障碍体系缺口：Dynamic Type 全库不支持 + Browser/Downloads 零覆盖 + 自绘线稿无标签

- **位置与证据**：
  - `Shared/DesignTokens.swift:88-108`：`DWFont` 三个工厂全部 `.system(size:)` 固定字号 → **全库文字不随系统字号缩放**（Dynamic Type 整体失效）。
  - `Browser/BrowserView.swift`、`Downloads/DownloadsView.swift`、`Components/PosterGrid.swift`、`player/PlayerFeedView.swift`：**零 accessibility 修饰符**（全库 grep）。浏览页返回/前进/刷新是自定义 Shape（BrowserView.swift:278-282, 332-355），VoiceOver 只能读到「按钮」二字；下载页取消/重试圆钮（circleButton，26×26）、编辑铅笔、排序 Menu 同样无标签。
  - `Downloads/DownloadsView.swift` SeriesDetailView 行用 `.onTapGesture { playIfDone(task) }`、`Drama/DramaDetailView.swift` 简介胶囊 `introTailPill` 用 `.onTapGesture`：**非按钮语义，VoiceOver 无法激活**。
  - `Components/PosterGrid.swift` `selection: Bool?` 勾选态未接 `accessibilityTraits(.isSelected)`。
- **对照**：做得好的半边也存在——App.swift MainTabBar、EpisodePanel/FullscreenDrawers/PlaybackRateSheet/全屏控制层都有成体系的标签与选中态。缺口集中在浏览/下载两页与「手势当按钮」处。
- **违反**：Nielsen「识别而非回忆/用户控制」；本审查维度⑤。
- **影响**：VoiceOver 用户在下载页无法完成取消/重试/编辑/排序，在浏览页无法导航网页历史；大字号用户全 App 文字不缩放。
- **建议**：先补标签与 `.isButton`/`.isSelected`（零视觉改动）；DWFont 至少对正文/错误详情/空态提示支持 `@ScaledMetric` 或 relative sizing（与画布逐像素对齐的指标框除外，需逐处权衡）。

### P1-4 「已看完」双口径 + 「已加入下载队列」三通道两种写法：术语口径分裂

- **位置与证据**：
  - **「已看完」口径互斥**：`Shared/PlaybackProgress.swift:13` `isFinished = seconds >= total - 5`（按播放进度，下载页行用，DownloadsView.swift:896）vs `Profile/ProfileViewModel.swift:216-222`「已看完 = 剧的最后一集已下载」(sort 最大集 downloaded=1，「我的」页筛选用，:33-34)。同一词：下载页指「这部看完了」，「我的」筛选指「这部下完了」——一集未看但全下完的剧会出现在「已看完」筛选里。
  - **集号空格**：剧集页/下载页/档案/a11y 全用「第 N 集」（DramaPageViewModel.swift:439/444/473/595、DownloadsView.swift:317、EpisodePanel.swift:137-140、FullscreenDrawers.swift:425-428、DramaDetailView.swift:1302）；播放域提示全用「第N集」（PlayerFeedViewModel.swift:201-242）。**同一条消息两种写法并存**：「已加入下载队列：第 N 集」（DramaPageViewModel.swift:444）vs「已加入下载队列：第N集」（PlayerFeedViewModel.swift:234）。
  - **同义异形**：「已入队 N 集」（DramaPageViewModel.swift:420）/「已加入下载队列」（:444）；「站点未开放下载」（PlayerFeedViewModel.swift:225/240、DramaPageViewModel.swift:439）/「站点未开放」（EpisodePanel.swift:140）/「暂无可下载项（站点未开放或已在队列）」（DramaPageViewModel.swift:410）。
  - **下载页内部**：同状态两种文案——进行中行「等待中」/「失败 · msg」（progressDetail）vs 剧行「等待中…」/「失败: msg」（TaskRow detailLine，DownloadsView.swift:846-886）。
- **违反**：AGENTS 19 的「统一口径」精神（选集面板与剧集页已对齐状态语义，但文案字面未对齐）；Nielsen 一致性；维度⑦。
- **影响**：「已看完」双口径直接造成筛选结果与用户预期相悖（语义错误，不只是文案）；其余为品牌语感磨损。
- **建议**：「已看完」统一为播放口径或改名「已下完」给「我的」筛选；集号空格择一（建议跟随 AGENTS 标题拍板用「第N集」，a11y 标签保留空格不影响）；失败分隔符统一「失败 · 」。

### P1-5 命中区系统性小于 44×44，且同一语义控件两套命中尺寸

- **位置与证据**（均为实际布局尺寸，`contentShape` 未外扩）：
  - `Settings/SettingsView.swift`：返回钮布局宽 **12**（:76-88，AGENTS 明文拍板，见 P2-8）；单选圆圈 DefaultDot **20×20**；PaperSwitch 开关整钮 **40×24**。
  - `Profile/ProfileView.swift:127-144,176-188`：月亮/齿轮 **20×20**、搜索 **18×18**。
  - `Downloads/DownloadsView.swift`：取消/重试圆钮 **26×26**（circleButton :549-560）、编辑铅笔 **22×22**、排序 Menu **22×22**。
  - `Browser/BrowserView.swift:278-282,332-355`：返回/前进/刷新 **20×20**；快捷站点胶囊高 **26**；「访问」钮 54×34。
  - `player/DramaPlayerView.swift:360-373`：竖屏倍速钮 **54×26**；选集胶囊高 38（宽 290 尚可）。
  - `player/FullscreenDrawers.swift:253-260,305-309`：抽屉关闭钮 **20×20**——而竖屏同一语义的关闭钮是 44×44（EpisodePanel.swift:160-164）。
  - `player/PlayerFullscreenControlsView.swift:575-589`：点赞/收藏命中盒 ≈**32×32**（18×1.2+pad5×2）；倍速/清晰度 60×40。
- **违反**：Nielsen 防错；Apple HIG 44×44 惯例；本审查维度④。**AGENTS 已拍板的设置页返回 12pt 不算违规**，其代价单列 P2-8。
- **影响**：浏览页前进/后退是高频低容错操作却只有 20×20；取消下载（破坏性入口）26×26 偏小但误触反被确认弹窗兜住——真正疼的是「想点点不中」。抽屉 20×20 关闭钮在旋转容器里误触邻区概率更高。
- **建议**：不动视觉，统一用「视觉框 + 透明命中层」方案（SwiftUI `.overlay` 放 44×44 透明 Button/`contentShape`，UIKit 设 44×44 frame 内缩 glyph——全屏控制层的 `centered(at:size:44)` 就是现成范本）；至少把返回/前进/刷新、抽屉关闭、点赞/收藏三处补齐。

### P1-6 ProfileView 的 `.preferredColorScheme(.light)` 作用于整条含播放页的栈

- **位置与证据**：`Profile/ProfileView.swift:67` `.preferredColorScheme(.light)   // 纸本轨锁浅色：域级分工，不影响其它页`——它挂在 Profile 的 NavigationStack 上，而该栈经 `navigationDestination` 推入 `DramaNativePage`（DramaNativePage.swift:20 `fullScreenCover` 呈现 `DramaPlayerContainer`），播放容器**没有自己的 scheme override**（DramaPlayerContainer.swift:37 仅 `.statusBarHidden(true)`）。环境值会随呈现链传入 cover。
- **违反**：AGENTS「纸本单轨视觉 1」明文警示过这个坑：「也不要在 Scene 层加 `preferredColorScheme(.light)`（DramaDetailView 与播放页会跟着变浅）」——这里在域级复现了同一机制；Nielsen 一致性。
- **影响**：页面自绘色值全是写死十六进制，**视觉主体不变**；变浅的是系统级控件——播放页「更多」菜单/系统弹层（UIAlertController、menu）在「我的→剧集页→播放」路径下按浅色渲染，落在墨本画面上突兀。剧集页本身安全（DramaDetailView 有自己的 `.preferredColorScheme(statusBarScheme)` 覆盖）。
- **建议**：把 `.light` 下移到封面墙那一层（TabView/内容容器），或给 DramaPlayerContainer 补 `.preferredColorScheme(.dark)` 终结歧义。注释「不影响其它页」与实际传播范围不符，一并修正。

---

## P2

### P2-1 对比度低于 WCAG AA（色值来自画布，需设计侧拍板）

实测（WCAG 相对亮度法，底=宣纸 `#F2F0EA`）：`paperInkSub #8C9190` **2.8:1**、`paperFaint #A2A6AD` **2.14:1**、`paperLineIdle #B9BCB9` **1.68:1**；均低于 AA 正文 4.5:1 / 大字 3:1。而它们大量承载 9–11pt 小字：版本脚注 fs9 用 paperLineIdle（SettingsView.swift:405-412）、档案行 fs10 用 paperFaint（DramaDetailView.swift:1355-1370）、空态 hint fs11 用 paperFaint（DownloadsView paperEmpty）、tab 未选文字 fs10 用 paperInkSub（App.swift MainTabBar）。色值是画布实读、AGENTS 禁止目测改 → 本条不判代码违规，建议回设计稿提对比度诉求；最危险的是 fs9+1.68:1 的版本脚注（信息也最不重要，可接受）。

### P2-2 触觉不成体系：AppHaptics 注释宣称的「单集下载完成」无任何调用点

`Infra/AppHaptics.swift:9-18` 注释：`success()`「异步结果达成。单集下载完成」——实际唯一 success 调用是剧集页下拉刷新成功（DramaDetailView.swift:783）。下载完成**全 App 无触觉**（剧集页只有 toast「第 N 集下载完成」DramaPageViewModel.swift:595，下载页完成连 toast 都没有，仅行态迁移）。其余缺口：主 tab 切换无触觉（App.swift MainTabBar）而「我的」分类 tab 有（ProfileView.swift:166）；同页筛选胶囊无触觉（filterChip）而分类 tab 有；下载页（取消确认/重试/编辑模式）、设置页（开关/恢复默认）全程无触觉。共 17 个调用点全在 Profile/Drama/player 三域。建议：把「下载完成 = success」补进 DownloadManager 完成回调；主 tab 与子 tab 触觉对齐。

### P2-3 「我的」页四个占位死按钮零反馈

ProfileView.swift:130-156（夜间）、:184-196（搜索）、:203-217（筛选/编辑）：点击无任何反应也无禁用态。Nielsen「系统状态可见」：可点击外观 + 零反馈 = 用户以为坏了。AGENTS/画布确实定义了占位，但至少应 `.disabled(true)` 置灰或点击给一条「即将上线」提示。同页对照：设置页占位项没有此问题。

### P2-4 浏览页无页面加载进度指示

WebViewStore 仅有 `loadError`/`isSubmitting`（添加任务锁），无加载态。点「访问」到 didCommit/didFinish 之间无任何可见反馈（白屏/paperCanvas 底），弱网下像死机。Nielsen「系统状态可见」。建议：细进度条（WebView estimatedProgress KVO）或至少转圈；自动重试文案已有（「连接被重置，自动重试 n/2…」）是好实践，但重试间隔 1.5s 内同样无指示。

### P2-5 「我的」页装配期间空态先现（无 loading 态区分）

ProfileViewModel.reload 全异步（后台队列 + 代际丢弃，ProfileView.swift:52-96），`rawItems` 初值为空 → 进入页面先渲染 `emptyState`（「还没有观看记录」），数据到了再跳成封面墙。有观看记录的用户每次进页/回根页都闪一下空态。DownloadsView 同样无骨架但有磁盘缓存兜底感知不明显。建议加 `isLoading` 态（或保留上次数据 + 低调刷新指示）。

### P2-6 播放页空态用系统 `borderedProminent`（默认蓝）

PlayerFeedView.swift:221 `Button("返回").buttonStyle(.borderedProminent)` 在墨本底上出现系统蓝，与全 App「朱砂为唯一强调色」的 token 体系冲突（剧集页错误态注释明确说过要绕开系统强调色）。DramaPlayerView.swift:637 `ProgressView().tint(.white)` 与 EpisodePanel 均已按轨处理，仅此一处漏网。

### P2-7 用户文件：DramaPlayerView mock 文案残留 + 裸色

DramaPlayerView.swift（用户文件）:443 硬编码「从第 1 集开始看」——从下载页/选集面板进入第 7 集时文案仍如此，属假信息（AGENTS 6 的精神：不编数据）；:463-470「热评」源自 mock 画布（本地无热评数据，靠 caption/tags 兜底，语义错位）；:521 选集胶囊「免费观看」——本地片源无计费概念。另有 :242-243 裸 `Color(hex: "#0F1212")`（仅 1 组，影响小）。建议改为中性文案（「当前第 N 集 · 共 M 集」类）或删行。

### P2-8 已拍板决策的设计代价与遗留债记录（不翻案）

- **设置页返回布局宽 12**（AGENTS 明文）：命中带仅 12×42，紧邻标题 Spacer。视觉约束成立，但可用 `.overlay` 挂 44×44 透明命中层（offset 不影响布局宽）两全。
- **清屏图标沿用「画面适配」icon**（用户拍板）：借用他处语义的图标指向新功能，学习成本一次性转移；全屏控制层锁/音量都是「钮底+glyph」而清屏钮是裸 glyph，识别依赖颜色变化（金=开）。
- **选集网格列数三处不同**：剧集页 6 列 50×44 / 竖屏面板 6 列自适应 / 全屏抽屉 4 列 46（画布 228 宽决定）。密度不一致是画布忠实度与面板宽度的真实冲突，已有注释说明，接受即可。
- **面板标题位当一次性提示通道**（AGENTS 19 拍板）：2.4s 内「选集」标题被提示顶替；若提示恰逢用户想确认当前面板，需再等恢复。代价已知情，保留。
- **浏览页切 tab 即退出剧集页**（BrowserView.swift:101-103 `dramaPageTarget = nil`）：回浏览页丢失当前剧详情（网页路由不丢）。属刻意的轻量行为，建议至少记入 HANDOFF 待用户验收。
- **站点编辑器「删除该站点」无确认**（SettingsView.swift:508-511）：与「恢复默认」的确认标准不对齐；自建数据误删后需手动重建。

### P2-9 手势可发现性：无任何首次使用引导（容错已做得细）

长按 2x、横向相对 seek、清屏、30pt 边缘返回、滚动收起联动——五套手势零引导（无 onboarding/无首次提示），「2x」只能在发现后靠 fastForwardCapsule 反馈。误触恢复侧反而成熟：250ms 吞单击窗、锁定态三重锁+解锁逃生、清屏首按只呼出控件、seek 抬手不补 seek。学习成本集中且无出口，建议至少给长按 2x 做一次性 toast 引导（复用现有 toast 通道即可）。

---

## 做得好的

1. **下拉刷新是全 App 状态机范本**（DramaDetailView）：三态自绘、峰值判定防回弹误判、10s 兜底解锁、失败/超时**不演「已更新」**（finishRefresh 显式区分三种 outcome）、阈值随灵动岛安全区自适应。
2. **错误透出体系完整落地**（AGENTS 21）：剧集页错误态 = 摘要 + 可滚动等宽详情 + 一键复制 + 重试；下拉刷新失败带 28 字原因摘要；失败不撕页面走静默 toast。
3. **破坏性操作全部有确认且文案说后果**：删全剧/取消下载（「已下载的分片会被删除」）/恢复默认（「自建的站点会被清掉」）。
4. **禁用态诚实并带 a11y hint**：下载全部置灰 + accessibilityHint「所有可下载剧集均已下载」；浏览页按钮文案随状态走（未检测到视频/正在添加…/已在下载队列）；m3u8 已入队项禁用 +「已在队列」标注。
5. **PosterGrid 单组件三处共用**，列数/compact 由调用方给——「三页一张卡」的一致性靠架构保证而非 review 约束，这是维度①能成立的基础。
6. **VoiceOver 在新增域覆盖好**：选集格状态化标签（「第 N 集，正在下载」两处实现逐字一致）、tab bar 选中态、全屏控制层 12 枚按钮全有标签且播放态同步更新。

---

## 关键数据事实

- **accessibility 修饰符**：全库 58 处 / 10 个文件；`BrowserView`、`DownloadsView`、`PosterGrid`、`PlayerFeedView` 为 **0**。
- **AppHaptics 调用点 17 处**：DramaPlayerViewModel 5、PlayerFeedViewModel 4、DramaDetailView 3、DramaPageViewModel 2、ProfileView 1（其余 2 处为定义与注释引用）；Downloads/Settings/Browser/EpisodePanel/FullscreenDrawers/PlayerFullscreenControlsView/MainTabBar = **0**。`success()` 的注释用途（单集下载完成）无调用点。
- **瞬态提示通道 4 套**：① Components/ToastView（黑 0.72 胶囊，2 个调用方：剧集页/竖屏播放卡）；② PlayerFullscreenController.showControlsToast（#1C1E1F@0.92 label）；③ 选集面板/抽屉标题位 hint（2.4s）；④ 进度 HUD。「已加入下载队列」同语义出现在 ①（剧集页）③（播放面板）+ 浏览页按钮文案，共 3 通道 2 种写法。
- **裸色值**（DesignTokens 外）：FullscreenDrawers 17 + PlayerFullscreenControlsView 8 + PlayerFullscreenController 2 + DramaPlayerView(用户文件) 2 ≈ **29 处**；`#A04D42` vs token `#A05142` 为已发生的实际漂移。
- **对比度**（底 paper #F2F0EA）：paperInkSub 2.8:1 / paperFaint 2.14:1 / paperLineIdle 1.68:1，全部低于 AA。
- **命中区 <44×44 清单**：见 P1-5（12/18/20/22/24/26/32/34/38/40pt 共 10 种尺寸）；DramaPlayerView 的返回/更多/静音/清屏已扩到 44、全屏控制层核心钮均 44——范本在播放域，缺的是纸本轨三页与抽屉。
- **分页容器三种实现**：下载页/我的页 SwiftUI paging TabView（行为一致）、播放页 UIKit UIScrollView paging（AGENTS 2 拍板，勿改回）。一致性在行为层成立，实现层三分是既定选择。
- **「已看完」双口径**：PlaybackProgress.isFinished（距片尾 5s）vs ProfileViewModel.lastEpisodeFinished（最后一集 downloaded=1）。
