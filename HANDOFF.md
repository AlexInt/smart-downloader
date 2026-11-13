# HANDOFF.md — 交接文档

> 给接手的 AI 编码代理：**先读 `AGENTS.md`**（硬性禁止 + 架构/日志/网络/并发约定，最高优先级）。本文只讲「做到哪了 / 还剩什么 / 怎么验」。**实现细节与防回归约束在 AGENTS 与代码注释里，完整过程在 git 历史**，本文不重复每个 build 日志。
>
> 最后更新：2026-11-13 · 分支 `feat/drama-detail-page` · 基准提交见 `git log -1`

## 1. 项目一览

智能 m3u8 视频下载器，跨平台多形态（Python CLI / Streamlit / Mac App / iOS App）。**近期全部工作聚焦 iOS**（`iOS/SmartDownloader/`，Xcode 26 folder-sync 工程，新 Swift 文件放入目录即自动编译）。用户只要求维护 iOS，勿主动改 Python 侧。

iOS App：WKWebView 嗅探 + Swift 下载核心 + SQLite 剧集缓存 + 本地 HLS 离线播放。核心页面：浏览（WKWebView，`MainTab.browser`）、下载（`MainTab.downloads`）、设置（`MainTab.settings`）、沉浸式播放页（抖音式上下滑切集，fullScreenCover）。

## 2. 功能状态

### 已实现并真机验证（细节见 AGENTS / 代码 / git）

剧集嗅探 → 原生剧集页 → 选集下载（含蜂窝 IP 直连降级）· 下载页双 tab 横滑 + 排序 + 批量编辑 · 重复点击下载防重 · 播放页设计稿还原 + 真实 AVPlayer + 长按 2× + 点按暂停 + 全屏无黑边 + 左缘返回 · 横向 seek 全屏化（相对映射，一屏宽≈全片时长）· 全剧集数同步（三真实来源，绝不造槽位）+ 边界 toast · UIKit 原生分页 · 秒开三件套（预热池 + KVO 直挂 + spinner 延迟）· 清屏模式 · 启动页 splash · 剧集详情页设计稿（390×840 三态 / 格子直点 / 查看全部下载面板 / 收藏 / 下载进度环）。**本轮新增的推荐专区 / 档案区 / 可滚动布局待真机回归，见 §7。**

### 本轮（2026-11-12）改动

| 项 | 说明 | 状态 |
|---|---|---|
| 全量 GCD 迁移 | 移除 Swift concurrency：工作线程+信号量线性管线、DispatchGroup 6 并发、DispatchWorkItem 定时、代际令牌；两处 async 岛见 AGENTS「并发与线程」 | Mac 构建+冒烟全过，**待真机回归** |
| 降 Swift 5 | pbxproj `SWIFT_VERSION 6.0→5.0` + `minimal`（与 project.yml 对齐）；删尽 @MainActor/nonisolated/assumeIsolated/Mutex | 已完成 |
| 消 deprecated 警告 | 资产加载改回 `asset.load` 包 @MainActor Task 岛（恢复迁移前写法，秒开不变） | 构建零警告 |
| 播放页 toast 不收回 | `toastText` 按值快照入卡片，`refreshCardsIfNeeded` 未纳入 toast 变化→dismiss 后不重绘。加 `activeToast` 触发刷新 | 已修，真机确认收回 |
| 播放器偶现「无法连接服务器」 | `LocalMediaServer.start` 未 ready 时二次调用回 port=0→拼出 `:0`。改登记等待、ready 统一回调；playbackURL 端口 0 显式失败 | 已修 |
| tab 切换卡顿 | 探针三修（横杠兼容 / Debug 常开 / 心跳 20ms 消除假阳性）定位到 WKWebView 离屏唤醒；App 改 ZStack 保活容器 + 自定义 tab bar（AGENTS 决策 11） | 待真机回归 |
| 竖滑误暂停 | seekPan 不限方向、竖滑也 began 搅乱触摸取消→误判 TAP。加 `gestureRecognizerShouldBegin` 拒纵向主导 | 待真机回归 |
| 点按显示进度条 | togglePlayback 触发 HUD + 3s 淡出（清屏下也可见） | 待真机验证 |
| 进度条组合动画 | 出现时上升 12pt + 淡入，共用 0.2s easeInOut | 待真机验证 |
| 右侧时长切换剩余时间 | label 点按切 `-M:SS`↔总时长，`PlayerPreferences.showRemainingTime` 持久化 | 待真机验证 |
| toast 时长 | 3s→2s | 已完成 |
| 注释清理 | 删 GCD 迁移回声注释（等价旧 Task/.task 等），保留防回归说明 | 已完成 |
| 设置 tab 页 | 新增 `Settings/` 域（Service/VM/View）：条目 1 选启动落在哪个 tab，条目 2 浏览页快捷站点多对 key/value 增删改；浏览页 label 行改读配置 | 模拟器构建通过，待真机验证 |
| 播放进度入库 | 新增 `Drama/EpisodeActionsStore.swift`：`episode_actions` 按 (site, drama_id, episode_id) 一集一行存点赞/收藏/上次播放位置，`local_actions` 按资源路径兜底（散装 HLS、普通文件、缓存缺失）；`PRAGMA user_version` v0→v1 建表并把 UserDefaults 里的旧 liked/saved/进度搬进库（muted/清屏仍留 Preference） | 冒烟双场景通过（有 id / 无 id），待真机回归 |
| 续播与进度显示 | `PlaybackProgressTracker`（1Hz 攒内存，暂停/seek 收尾/切集/退出/进后台落库）接入沉浸式播放页与下载页 AVKit 播放；就绪后续播并闪现 HUD 1.5s；已下载列表行显示「播至 03:12 / 12:30」或「已看完」；删除条目连带清行为数据 | 同上 |
| 身份链补齐 | `MediaIdentity`（Shared 纯数据）+ `PlayableEpisode.identity` + `ImmersivePlaybackRequest.target`；剧集页入口带 site/drama_id 直达，下载页按剧名反查（同名多剧打 AMBIGUOUS 日志）；`EpisodeActionsStore.identity(...)` 为唯一解析口径 | 同上 |
| 详情接口整包落库 | 此前详情响应只有 tags 被收集，其余 39 个顶层字段解码即丢。新增 `DramaCache.saveDetail`：`api_detail` 存响应体整包 + 35 个提升列（计数/规格/权限/催更/服务端观看进度）、`drama_episodes` 加 8 个每集元数据列、新表 `drama_related` 存推荐剧快照；采集改为每次进剧集页一次 | 用真实样本 3703.json 验证：整包一字不差回读、4 集元数据、10 条推荐、v1→v2 升级不丢行为数据 |
| 数据库迁移收口 | 新增 `Drama/DramaDatabase.swift` 统一 open/建表/补列/旧数据搬迁（`user_version` 整库一个，两个 Service 各管一段会互相跳过建表）；补列逐列查 table_info，搬迁用独立标记门控；共用 bind/text/execWrite/fail/transaction | 同上 |
| saveInfo 合并式落库 | 原「先 DELETE 全表再逐集 INSERT」使 ON CONFLICT 永不触发，刷新集列表把 `downloaded/folder` 清成 0/NULL。改为读现有 id 后只删接口已不存在的集、既有集 upsert 不动下载标记与每集元数据（v1 老库升级 + 同列表刷新 + 列表变化 + saveDetail 幂等重跑四场景冒烟通过） | 已修，冒烟通过，待真机回归 |
| 剧集详情页对齐新设计稿 | 设计稿 `drama-detail.html` 的 `.screen` 本来就是 `overflow-y:auto`，原实现是固定 390×840 不可滚。改为可滚动画布（高度 = 840 + 推荐 + 档案）、缩放按屏宽、toast 改屏幕悬浮；**移除底部固定 CTA**，格子恢复直点（已下载→播放 / 下载中→取消 / 未下载→直接下载 / 锁定→提示）；补「下载全部」与下载中 `n/100` 分数。保留海报 376、≤12 集固定栅格 | 模拟器构建通过，真实样本验证通过，**待真机回归** |
| 「为你推荐」专区 | `Drama/RecommendedDrama.swift`（纯数据）+ `DramaCache.relatedDramas` 由 5 列扩到 8 列（补 `play_count_text` / `serialize_status_text` / `content_access_type`）；双列瀑布流、封面 228/184/150 三档循环、连载+VIP 角标、标题/标签/播放量；卡片点击由 `DramaNativePage` 的 `navigationDestination` 再推一层剧集页（站点从 `target.site` 推导，不硬编码） | 同上 |
| 「剧集档案」区 | `Drama/DramaArchive.swift` 把 `api_detail` 整包解码回 `DramaDetailData` 后纯函数派生分组展示行：数据表现 / 内容规格 / 权限与付费 / 角标状态 / 催更 / 服务端观看进度 / 分享与链接 / 每集元数据 / 本地记录；0 与 nil 如实显示，不编造文案 | 真实样本 3703.json：解码 4 集 / 10 推荐，档案 9 组 70 行、VIP 角标正确；**待真机回归** |
| 设计稿三项补齐（同日追加） | ① 格子右下 18×18 状态角标：已下载金色三角 / 未下载灰色下载箭头，下载中与选中集不叠加（同 `[aria-checked=true]` 规则）；② 进度环由绿改回设计稿金色 `#F5C451`（排队淡金轨道 / 下载中闭环 / 完成闭环 / `n/100` / 已下载淡金底同色系，失败仍红环）；③ 「查看全部 ›」由 sheet 改为**内联展开** 13 集以后（6 列 × 56pt，文案切「收起 ›」，≤12 集置灰禁用），推荐/档案按 `extraEpisodeRows` 一起下推。原 sheet 的全选/清空/下载所选搬进展开区底部工具条，刷新移到选集行 ↻，能力不丢 | 模拟器构建 0 error / 0 warning，**待真机回归** |
| 快捷站点默认加载 | 设置页快捷站点行右侧圆圈单选「默认」（再点取消，默认行带金色标记）；`QuickLinkStore.defaultLinkID` 单独存 UUID（不改 `[QuickLink]` JSON、无需迁移），按 id 查当前列表取 URL，编辑网址自动跟随、条目被删自动回落。新增 `Browser/BrowserStartPage.swift` 统一决策「默认站点 > 上次访问页 > 空白页」，顺手把 View 层的 `UserDefaults.standard` 收进 Service | 模拟器构建 0 error / 0 warning；起始页 8 场景冒烟全过，**待真机验证** |
| 快捷站点「默认第一项」（11-13 补充） | 用户**从没点过圆圈**时自动选中列表第一项（UI 第一行圆圈直接是选中态）；点过又取消 = 显式「无默认」，回落恢复上次访问页。三态靠 `hasConfiguredDefault`（key 是否存在）+ 空串哨兵区分：上一版取消时 `removeObject` 会把「显式取消」误判成「从没配置」，现改为写空串。`QuickLinkStore.resolvedDefaultID(in:)` 一处解析；VM 的 `defaultLinkID` 改为**生效值**（非存储原值），增删 / 恢复默认列表后由 `refreshEffectiveDefault()` 重算；显式选中的条目被删不猜别的站点 | 构建 0 error / 0 warning；三态 17 项冒烟全过（含重启后持久化、空列表新增、删第一项跟随），**待真机验证** |
| 横滑结束误暂停修复（11-13） | 调查实证：seekPan `cancelsTouchesInView=false` 且纯横滑时系统分页 pan 不 begin，触摸全程不被取消，SwiftUI tap 收到完整序列，抬手即 TAP→暂停（竖滑那轮已实证同机制，当时只挡了纵向起手）。修复：`endSeekGesture` 开 250ms 吞单击窗（VM `tapSuppressionDeadline`，与长按松手的 `suppressTapUntil` 同机制），卡片 onTapGesture 查询；手势仲裁规则（先起者独占）不变 | 构建 0 error / 0 warning，**待真机回归**（日志锚点：`TAP SKIP reason=justEndedSeek`） |
| 播放页按片源方向渲染（11-13） | 竖屏持机时横屏片源不再拉满裁切：`AVPlayerItem.presentationSize`（同步非废弃，不新增 async 岛）→ VM `videoIsLandscape`（ready + 周期 tick 刷新，0×0 未知按竖屏处理维持 fill 现状）；`PlayerSurfaceView` 增加 `videoGravity` 参数，片源与持屏方向一致 fill、错配 fit 完整显示（黑边） | 同上（日志锚点：`videoOrientation landscape=true/false`） |
| 播放器横屏专用控件布局（11-13） | 横屏不再沿用 390×840 画布 contain 缩放（会缩到 ~0.47 控件过小）：新增 `DramaPlayerView.landscapeOverlay`（安全区感知：顶部返回/集数/清屏/静音横排 + 底部进度条横贯 + 2x/toast/加载/错误/未下载居中）；竖屏画布的信息区/点赞收藏/上滑提示横屏不渲染；返回/静音/清屏/集数胶囊/2x/加载/错误/未下载抽成可复用组件两套布局共用，竖屏视觉与坐标不变 | 同上 |

## 3. `player/` 模块架构地图（MVVM + Service）

依赖方向：**View → ViewModel → Service → 系统/Model**，单向不可反向；组装根只做 DI。

| 文件 | 层 | 职责 |
|---|---|---|
| `PlaybackModels.swift` / `DramaEpisode.swift` | Model | 纯数据：`PlayableEpisode` / `ImmersivePlaybackRequest`、卡片展示模型 |
| `PlaybackQueueService.swift` | Service | **上下滑资源调度唯一入口**：全剧集数三来源、槽位、history 回溯栈、`resolveNext/resolvePrevious`（推荐算法接入点）、`neighbors(of:)` |
| `PlaybackPlayerService.swift` | Service | 唯一常驻 `AVPlayer`、`makeItem`（预热池 HIT/MISS）、`preload`/`clear`/`teardown` |
| `PlayerPreferences.swift` | Service | 静音/清屏/**剩余时间显示**持久化（UserDefaults 封装）；点赞/收藏已迁 `EpisodeActionsStore`（SQLite）|
| `PlayerGesturePolicy.swift` | Service | 仅剩 scrub 灵敏度纯函数（命中带已废）|
| `PlaybackProgressTracker.swift` | Service | 进度落库与续播：1Hz 攒内存 + 关键时机 flush，播完/接近片尾从头播 |
| `DramaPlayerViewModel.swift` | ViewModel | 单集播放状态机：load（KVO 直挂 + 看门狗 + 代际令牌）、isReady/isLoadingSlow/isScrubbing、seek、倍速、时间进度 |
| `PlayerFeedViewModel.swift` | ViewModel | 分页数据源、当前页、`schedulePageSettle` 停稳防抖 + 相邻集预热、边界 toast；组装 `DramaPlayerViewModel` |
| `PlayerFeedView.swift` | View | 分页容器 SwiftUI 侧：onAppear/onChange 转发 `schedulePageSettle` |
| `PlayerPagingScrollView.swift` | View | **UIKit `UIScrollView.isPagingEnabled` + `UIHostingController` 卡片**；seekPan/edgePan 识别器、`refreshCardsIfNeeded`（currentSort/isReady/toast 变化时重设 rootView）|
| `DramaPlayerView.swift` | View | 单张卡片（390×840 逐节点，**卡片内零连续手势**，点按/长按离散手势在此）|
| `PlayerSurfaceView.swift` | View | `AVPlayerLayer` 包装 |
| `DramaPlayerContainer.swift` | 组装根 | fullScreenCover 入口，onAppear configure + onDisappear stop |
| `Components/ToastView.swift` | 全局组件 | 通用 toast，不依赖业务/坐标系 |

其余域（Shared / Drama / Downloads / Browser / Infra / Settings）见 AGENTS「目录」节。
行为数据表（`episode_actions` / `local_actions`）在 `Drama/EpisodeActionsStore.swift`，详情整包与推荐剧在 `DramaCache.saveDetail` / `drama_related`，
建表与迁移统一在 `Drama/DramaDatabase.swift`（schema v2），与 `drama_cache` 同一个 SQLite 文件，
写入方是播放页与下载页 AVKit 播放，读取方是下载列表与播放页续播 —— 口径统一由 `MediaIdentity` 表达。

## 4. 关键设计决策（勿轻易推翻）

1. **分页用 UIKit `UIScrollView.isPagingEnabled`**。SwiftUI `ScrollView + .scrollTargetBehavior(.paging)` 与卡片 GeometryReader/手势冲突，四轮排障完全滑不动，已弃用（勿改回）。轻滑翻页靠 `scrollViewWillEndDragging` 里 15% 位移或 0.3 速度阈值。
2. **卡片内禁止任何连续手势**——手势分类与长按 2x↔seek 仲裁细则见 AGENTS「具体约定」2。seekPan 已加 `gestureRecognizerShouldBegin` 方向过滤（拒纵向主导）。
3. **单播放器常驻**，切集只 `replaceCurrentItem`，禁止滑动时新建 AVPlayer；秒开靠预热池三件套（AGENTS「具体约定」3），不是多 player pool。
4. **App 用 ZStack 保活容器而非 TabView**：WKWebView 不离屏，避免切回浏览页时离屏唤醒阻塞主线程（AGENTS「具体约定」8）。
5. **集数绝不造假**：来源优先级 = 调用方 knownSorts → SQLite `DramaCache.allSorts` → 磁盘已下载兜底。没有元数据时只有 1 集就不能滑，toast「已经到底了」。
6. **推荐算法接入点**：只改 `PlaybackQueueService.resolveNext/resolvePrevious`；`neighbors(of:)` 也走它们，预热自动跟随新序。
7. **诊断日志**：`PLAYER_DBG` 前缀 + `[CHECK]` 断言行；失败分支必须有 log；排障后保留不清理（全文见 AGENTS）。
8. **剧集详情页是可滚动画布，不是固定 840**：设计稿 `.screen` 本来 `overflow-y:auto`，推荐/档案在首屏之外。缩放改按屏宽（`geo.size.width / 390`），`scaleEffect(anchor: .topLeading)` 后必须再给一层缩放后尺寸的 frame，否则 ScrollView contentSize 不对。**底部 CTA 已移除**；主屏 12 格直点（`tapEpisodeDirect`），「查看全部」是内联展开（`showAllEpisodesInline`），展开的 13+ 集走多选语义（`tapEpisode`）+ 底部工具条，两条点击路径按 `multiSelect` 分流、别合并。展开时 `pageLayout` 的 recoY 必须按 `contentBottomDesignY = 720 + extraEpisodeRows*56` 下推，否则推荐区会压住额外集。勿改回固定高度 / sheet / CTA。
9. **播放页两条有意取舍（2026-11-13 用户拍板）**：① 横屏 = 观影模式——竖屏画布的信息区/点赞收藏/上滑提示在 `landscapeOverlay` 不渲染，点赞收藏回竖屏操作，勿当缺失补回横屏；② 片源方向未知（`AVPlayerItem.presentationSize` 0×0）按竖屏 fill 处理，宁可不切换也不猜方向。详见 AGENTS「iOS 架构约定」第 12 条。

## 5. 待办清单（按优先级）

| # | 事项 | 优先级 |
|---|---|---|
| 1 | **本轮全部改动的真机回归**（清单见 §7）：GCD 迁移行为不变量 + 保活 + 手势 + toast/服务器/进度条/剩余时间 + 详情页滚动/直点/推荐跳转/档案 | 高（验证） |
| 2 | 浏览页路由统一（见 §6，本轮只查未改） | 中 |
| 3 | 相邻卡片首帧海报（渐变占位 → AVAssetImageGenerator + 磁盘缓存，可复用预热池 asset） | 中 |
| 4 | 本地推荐算法（接入点已留 §4.6） | 按需 |
| 5 | 「长按 2x 中途继续上滑切集」手势竞争观察（离散手势回卡片后未专测此组合） | 低 |

## 6. 待查 / 已知问题

- **浏览页路由「有时原生有时 web」（未改，待拍板）**：`decidePolicyFor` 只在 `navigationType == .linkActivated`（真实 `<a>`）+ `DramaTarget.parse` 命中时取消网页推原生；卡片若用 JS `location.href`/`pushState`/`window.open` 跳，`.other` 拦不住。URL KVO 兜底但 `detectDrama` 有 `lastAutoDramaKey` 去重、`pushDramaPage` 不写该标记 → 两路径状态不一致，同剧二次点击可能被挡。`DramaTarget.parse` 只认 `/drama/(video|detail)/<数字>`。建议：主帧剧集 URL 一律 `.cancel` 并推原生、两路径共用去重标记——触及导航，先等确认。
- **手势残余边界（可接受）**：带外慢速横向拖拽 >0.15s 仍可能起 2x（慢拖与「长按+慢漂移」不可区分，「先起者独占」的固有歧义）。
- **tags 数据源（已定案，细节见 `DramaDetailData` 代码注释）**：站点 detail 走 Nuxt `_payload.json`（devalue 扁平数组），非明文/非信封；解码链 明文→信封→payload，`via=plain|envelope|payload` 日志区分。旧缓存无 `tags_source` → 进页自动补采一次。

## 7. 验证与调试

```bash
# 编译（模拟器，无签名）
xcodebuild -project iOS/SmartDownloader.xcodeproj -scheme SmartDownloader \
  -destination 'generic/platform=iOS Simulator' build
# 冒烟（macOS，不需手机；命令详见 AGENTS「常用命令」）
cd iOS/smoke && swiftc -O -o coretest main.swift .../Downloader.swift ... ; SMARTDOWNLOADER_DIR="$PWD/out" ./coretest
# 真机日志（用户跑，代理只看 log；Debug 构建卡顿探针自动开）
xcrun devicectl device process launch --console --device <id> com.firefish.smartdownloader
```

- 排障一律**先加 log 再请用户贴 log**，靠日志判读不靠猜（本项目协作模式）。
- 秒开：`preload OK` / `preload EVICT` / `makeItem HIT|MISS` / `load OK waitedMs=` / `spinner show` / `status STALE`。
- 交互：`TAP → togglePlayback` / `LONGPRESS began|ended` / `seekPan began`（竖滑不应再出现）/ `edgePan → back` / `scrub show|hide`。
- tab 卡顿：`PERF_DBG stallProbe enabled`（探针自检）+ `PERF_DBG mainStall ms=`（>100ms 真卡顿）+ `PERF_DBG tabSwitch`，切回浏览页看 mainStall 是否消失。

**本轮真机回归重点**：① WiFi/蜂窝下载（IP 直连/WebKit 降级日志）；② 切回浏览页不再 mainStall；③ 竖滑/斜滑不再误暂停；④ 点按显示进度条 3s、上升淡入；⑤ 右侧时长切剩余时间、杀进程重开记住；⑥ toast 2s 收回；⑦ 播放不再偶现「无法连接服务器」；⑧ 秒开 `makeItem HIT`、长按 2x/横滑 seek/翻页仲裁不变；⑨ 详情页整页能滚到推荐与档案、`PLAYER_DBG [Entry] reco refresh count=10 archiveSections=9`、推荐卡片 push 新剧集页后返回能回原剧、格子直点（未下载→入队 / 下载中→取消 / 已下载→播放）、「下载全部」不重复入队、左缘返回手势与整页 ScrollView 不打架；⑩ 角标与金环（未下载灰箭头 / 已下载金三角 / 下载中金环+n/100 / 选中集不叠加）、「查看全部 ›」内联展开 13+ 集后推荐区被正确下推不重叠、「收起 ›」能收回、工具条全选→下载所选可提交、选集行 ↻ 刷新生效；⑪ 快速横滑结束不再误暂停、且 seek/翻页/2x 仲裁不变（误吞时应见 `TAP SKIP reason=justEndedSeek`）；⑫ 横屏片源竖屏持机完整显示不裁切（`videoOrientation landscape=true`）、竖屏片源维持拉满；⑬ 旋转横屏后返回/清屏/静音/进度条尺寸正常（landscapeOverlay）、旋转回竖屏恢复画布布局、横屏下点按暂停/长按 2x/横滑 seek/左缘返回照常。

## 8. 维护本文档

每完成一个任务：更新 §2 状态 / §5 待办，提交里带上本文档变更。**改架构约定改 `AGENTS.md`，改进度状态改本文档**；实现细节写进代码注释，不在此堆 build 日志。
