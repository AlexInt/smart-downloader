<!-- 本文件内容逐字搬自 AGENTS.md（2026-11-16 拆分），是对应域的完整约束。改动该域代码前必读；主文档 AGENTS.md 只保留结论索引与承重规则。 -->

# 功能域目录与文件清单

## 目录（按功能域分组，域内再分层）

本节的适用范围是 `iOS/SmartDownloader/` **全部** Swift 文件，不只是 `player/`。目录按「功能域」划分，**不按 Model / Service / ViewModel / View 分**：同 target 没有 import 边界，按层分目录不产生任何依赖约束，只会把一个功能的四个文件打散到四处。按域分则「一个功能一个目录」，域内是否分层一眼可查。

- `Shared/`：跨域共享的**纯数据**与设计系统。`DramaModels.swift`（`DramaTarget` / `MediaIdentity` / `ApiDramaEpisode` / `DramaInfo` / `DramaError` / `EpisodeDownloadPhase`）、`DownloadModels.swift`（`TaskState` / `DownloadError`）、`DesignTokens.swift`（`DWColor` / `DWFont` / `DWLayout` / `designFrame`——注意 `designFrame` 末尾是 `.position`，返回的是撑满父容器的视图，**其后再挂 `.overlay` / `.background` 拿到的是父容器尺寸而不是指标框**，要对齐到该指标框必须挂在使用 `designFrame` 之前）、`MainTab.swift`（tab 条目与顺序的唯一来源）、`PaperGlyphs.swift`（纸本轨 1pt 线稿图元库，见下文「纸本单轨视觉」）。只放被 2 个以上域引用的类型，不塞 Service / 业务逻辑
- `Drama/`：剧集域。Model（`DramaDetailData` 详情 DTO / `RecommendedDrama` 推荐卡片纯数据 / `DramaArchive` 档案展示行与派生纯函数）、Service（`DramaAPI` / `DramaCache` / `DramaMetaHarvester` / `DramaCoverCache` 封面按剧 id 落盘缓存 / `DramaFavorites` 剧级收藏（SQLite `drama_favorites`） / `EpisodeActionsStore` 集级行为数据表 / `DramaDatabase` 统一连接与迁移）、ViewModel（`DramaPageViewModel`）、View（`DramaDetailView`——顶栏返回/收藏经 `pinnedHeader` 钉在 ScrollView 之上不随滚动消失，`scrimTop` 常驻顶栏层，**勿塞回 `canvas`**）、组装根（`DramaNativePage`）
- `Downloads/`：下载域（纸本轨）。Service（`Downloader` 下载核心 + 任务/队列 / `DiskUsageService` 磁盘占用纯计算 / `DownloadsSortPreferences` 排序偏好）、`DownloadsViewModel`（VM，含占用缓存与去抖重算、`seriesCovers` 封面后台解析）、`PlaybackProgressViewModel`（VM：列表侧只读行为数据）、`DownloadsView`（View，**按画布 `2:2` / `19:272` / `34:1` 全自绘、不是系统 `List(.insetGrouped)` 观感**：分段头自绘 + 行透明化 + 编辑条）
- `Browser/`：浏览域。`BrowserView`（View + `WebViewContainer`）、`WebViewStore`（VM，P9 那轮并入 View 文件后已拆出）、`SnifferScript`（注入 JS 常量）、`AdCleanerScript`（广告弹窗清理 JS 常量：CSS 预隐藏 + MutationObserver 同步删，防「闪一下」；每删/藏一个弹窗都顺手 `unlockScroll` 解掉站点加的滚动锁，另带 `scrollLocked` / `scrollStuck` 滚动诊断；日志经 adClean 回传调优）、`AgeGateScript`（年龄确认门自动点「已满18岁 继续观看」：只认浮层 + 年龄文案 + 正向按钮，每页最多 4 次，日志经 ageGate 回传；见 AGENTS 第 18 条）、`KeyboardDismissScript`（滑动网页收键盘的手势上报：捕获阶段 scroll + touchmove 兜底，走 keyboardDismiss handler）、`ScrollCollapseScript`（滚动收起联动的方向上报：捕获阶段 scroll、每容器各记位移、只上报方向；走 browserScroll handler）、`ScrollCollapsePolicy`（纯判定：方向 + 回到顶部 → 顶部两行/工具条收不收起）、`BrowserStartPage`（Service：起始页优先级决策 + 上次访问页持久化；View 层不再碰 UserDefaults）
- `Settings/`：设置域。Service（`QuickLinkStore` 快捷站点 key/value 与「默认加载站点 id」持久化 / `AppLaunchPreferences` 启动 tab 持久化 / `DramaRoutePreferences` 「打开 Web 剧集页」路由偏好）、ViewModel（`SettingsViewModel`）、View（`SettingsView` + `QuickLinkEditorSheet`）。**设置页是「我的」页的二级页，导航栈由 `ProfileView` 提供，`SettingsView` 不要自建 `NavigationStack`**（嵌套栈会丢返回按钮/标题）
  - **设置页按画布 `24:43 设置页 · 纸本` 全自绘，不是系统 `List(.insetGrouped)`**：`.toolbar(.hidden, for: .navigationBar)` 后自己画顶栏（返回尖角 / 「设置」衬线 fs30 / 「恢复默认」fs12）。几何来自节点实读并与设计稿逐像素校准过：顶栏 63 = 上下 padding 10 + 内容 43，下方分隔线 1（`#DDD9D0`，**通栏**，不吃 20pt 边距）；分组容器 padding top 6 / 左右 20；组标 fs11 行高 16；行高 40；脚注 fs10 行高 14（用 `lineSpacing(2)` 达成）；组内一律 gap 4；组间细线 1（`#E4E0D6`，**在 20pt 边距内**，实测 x<20 处没有线）。
  - **「设置」标题不是页面居中**：设计稿墨迹 x 148…205、中心 177，而页面中心是 195 —— 它居中于「返回箭头右沿」与「恢复默认左沿」之间。用 `HStack { 返回; Spacer; 标题; Spacer; 恢复默认 }` 复现；改成 `ZStack` 居中会右移 18pt。返回按钮的**布局宽必须是 12**，命中区只能 `.padding(.vertical:)` 往下扩，横向加 padding 会把标题顶偏。
  - 行尾尖角方向别搞反：`ChevronShape(pointsLeft:)`，返回用 `true`「‹」、行尾用默认「›」。初版两边都画成「‹」，行尾语义反了。
  - 开关与单选圆圈都是自绘：开关轨道 40×24（关 `#C9CCC9` / 开朱砂）、钮 20×20 内缩 2；圆圈 20 框内 17 实心 + 纸白勾，未选态画同尺寸描边圈（设计稿只有选中态，未选态按同一尺寸补）。
  - **恢复默认 = 三项一起回默认**（启动 tab `.downloads`、剧集页开关 `false`、快捷站点回内置列表），会清掉用户自建站点，所以先弹 `confirmationDialog` 确认。
  - 站点行有**两个平级 Button**（左侧整行进编辑器、右侧圆圈改默认），不能嵌套——外层 Button 会吞掉内层点击。
  - 隐藏系统导航栏会连带关掉右滑返回，用 `swipeBackEnabled()`（`Infra/SwipeBackSupport.swift`，只在导航栈深度 > 1 时放行，防止栈根起手卡死）补回。
- `Profile/`：我的域（纸本轨视觉）。`ProfileViewModel`（VM：四分类数据装配——历史/收藏/追更/点赞，口径全在 Service 层的关系查询上）、`ProfileView`（View + 组装：`NavigationStack(path:)` 值驱动路由，`ProfileRoute` 定义二级页）。**四个分类是分页 `TabView`（`.tabViewStyle(.page)`）**，点分类 tab 或左右滑都能切（与下载页「下载中/已下载」同一套路，用户 2026-11-15 要求「应该与下载-已下载一样可以左右滑动」）；VM 一次读全四个分类（`rawItems[Category]` + `items(for:)`），因为四页同时在场，按需再查库会让滑动闪空态。**顶栏区（身份行 + 分类 tab + 筛选胶囊）用 `safeAreaInset(edge: .top)` 钉住**，封面墙上滑时不动（用户要求：分类与筛选不应随上滑消失）；**底部必须 `.safeAreaPadding(.bottom, MainTab.barReservedHeight + 15)`**：自定义 tab bar 是 App 层 `safeAreaInset` 注入的，**栏本身 62pt 不传进页面**（详见「纸本单轨视觉」第 3 条承重规则），分页页面同样不接收，所以补在外层 VStack 上（照下载页写法）；不补的话封面墙最后一行被 bar 盖住。`path.isEmpty` 是「是否在二级页」唯一事实来源，经 `detailActive` 绑定让 App 隐藏 tab bar（设置页/剧集页都算）；回到根页（`path` 变空）重读一次，收藏/点赞可能在二级页改过
- `Infra/`：系统能力。`LocalMediaServer`（本地回环 HTTP）、`WebKitFetcher`（WKDownload 兜底）、`AppHaptics`（全 App 触觉反馈唯一入口）、`KeyboardObserver`（键盘显隐唯一入口：弹起时收起自定义 tab bar 与浏览页底部工具条，避免被系统顶到键盘上方）
- `player/`：播放域，五层齐全。Model（`PlaybackModels` / `DramaEpisode`）、Service（`PlaybackQueueService` / `EpisodePanelService` 选集面板数据装配与单集下载 / `PlayerPreferences` / `PlaybackPlayerService` / `PlayerGesturePolicy` / `PlaybackProgressTracker` 进度落库与续播 / `PlayerOrientationTrigger` CoreMotion 姿态判稳 / `PlayerFullscreenController` 全屏搬运动画）、ViewModel（`DramaPlayerViewModel` / `PlayerFeedViewModel`）、View（`DramaPlayerView` / `PlayerFeedView` / `PlayerPagingScrollView` / `PlayerSurfaceContainer` 单例视频容器 `PlayerSurfaceUIView` / `PlayerFullscreenControlsView` 全屏控制层）、组装根（`DramaPlayerContainer`）
- `Components/`：**全局**通用 UI，不依赖任何业务模块或页面坐标系，命名不带业务前缀（如 `ToastView`，不要 `PlayerToastView`）；位置由调用方决定。`PosterGrid.swift` = 纸本海报卡 + 可配列数的网格（推荐 2 列 / 我的·已下载 3 列，三处共用，见「纸本单轨视觉」第 16 条）。
- 根目录只留 `App.swift`（入口）与 `Info.plist` / `Media.xcassets`。两批迁移均已完成（2026-11-12），**不要再往根目录新增 Swift 文件**

**域内五层规则**：每个域的 Model 独立文件、纯数据无 IO；VM 不直接读写系统对象；Service 不 import SwiftUI、不用 `@Published`、不反向依赖 VM。新增类型必须归到所属域，不要再往根目录堆。判断有没有落实看三条：Model 是否独立且纯数据、VM 碰不碰系统对象、Service 删掉 UI 后是否仍成立。

**folder-sync**：工程只有一个 `PBXFileSystemSynchronizedRootGroup`（`path = SmartDownloader`），子目录递归自动参与编译，`git mv` 即可，不要改 pbxproj。`Info.plist` 必须留在根（`INFOPLIST_FILE = SmartDownloader/Info.plist`），`iOS/LaunchSplashView.swift` 是显式 `PBXBuildFile`、不在同步文件夹内，勿挪。

