# HANDOFF.md — 交接文档

> 给接手的 AI 编码代理：**先读 `AGENTS.md`**（硬性禁止 + 架构/日志/网络/并发约定，最高优先级）。本文只讲「做到哪了 / 还剩什么 / 怎么验」。**实现细节与防回归约束在 AGENTS 与代码注释里，完整过程在 git 历史**，本文不重复每个 build 日志。
>
> 最后更新：2026-11-16 · 全部「待真机验证」挂账销账（30 个验证点 82 处，用户逐一确认通过）· `feat/drama-page-paper` 已合并至 `main`，后续修复直接在 `main` 上提交 · 基准提交见 `git log -1`

## 1. 项目一览

智能 m3u8 视频下载器，跨平台多形态（CLI / 站点全自动 CLI `video_auto.py` / Streamlit GUI / Mac App / iOS App）。**近期全部工作聚焦 iOS**（`iOS/SmartDownloader/`，Xcode 26 folder-sync 工程，新 Swift 文件放入目录即自动编译）。用户只要求维护 iOS，勿主动改 Python 侧；例外：2026-11-14 用户点名把 iOS 下载逻辑同步到 Python CLI（已完成，见 §2 同名行），Python 下载核心自此与 iOS 同源。

iOS App：WKWebView 嗅探 + Swift 下载核心 + SQLite 剧集缓存 + 本地 HLS 离线播放。核心页面：浏览（WKWebView，`MainTab.browser`）、下载（`MainTab.downloads`）、设置（`MainTab.settings`）、沉浸式播放页（抖音式上下滑切集，fullScreenCover）。

## 2. 功能状态

### 已实现并真机验证（2026-11-16 用户逐点确认通过；逐条目排查链历史见 `docs/handoff/archive-2026-11.md`）

- **全局底座**：GCD 并发体系（代际令牌 / 后台化管线 / 主线程卡顿探针）· ZStack 保活容器 + 自定义 tab bar · 诊断日志体系（PLAYER_DBG 全链路）· 触觉 6 点位（AppHaptics 单一入口）· tab 切换卡顿已根治
- **浏览域**：WKWebView 嗅探 → 原生剧集页 · 快捷站点三态默认逻辑 · 「打开 Web 剧集页」开关 · 年龄门自动点击（当天不重复）· 广告清理 + 滚动锁解锁 · 滚动收起联动 · 滑动网页收键盘
- **下载域**：队列 / 6 并发切片 / IP 直连降级 · 同集去重三源收口 · 磁盘占用统计 + 容量排序 · 纸本视觉（自绘分段/行/编辑条）
- **剧集详情页**：纸本视觉 + 顶栏滚过海报双态 + 状态栏字色 · 下拉刷新三态（封面中心放大 / 失败不演「已更新」）· SWR 编排（缓存秒出 + 静默对账）· 封面证据链（主封面 / 推荐封面 / 本地缓存 / 错配根治）· 选集面板集号补全 1…N · 接口失败可复制错误详情 · 简介展开终态
- **播放域**：竖屏流（分页切集 / 横滑相对 seek / 长按 2x / 点按暂停 / 清屏 / 边界提示 / 选集面板与下载打通）· 横屏全屏（容器自转 / 切集冻帧不黑闪 / 锁定三重锁 / 控制层）· 秒开三件套 · 后台回来自愈 · 播放/暂停图标单视图重绘
- **我的域**：四分类分页左右滑 · 海报网格（PosterGrid 三处共用）· 滑动返回不卡顿（后台装配 + 代际令牌）
- **数据**：SQLite 三表 + DramaDatabase 单入口迁移 · 播放进度 / 剧级收藏入库 · 续播位置正确 · 同集只有一条记录

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
| `PlayerOrientationTrigger.swift` | Service | CoreMotion 重力向量姿态判稳（滞后 55°/28° + 0.6s 稳定窗），进/出全屏与全屏内左右转向意图的唯一触发源；无按钮入口 |
| `PlayerFullscreenController.swift` | Service | 全屏动画核心：订阅 `$isFullscreen`，把 `videoLayer` 在 feed surface 与 keyWindow 容器之间搬运 + transform 旋转 ±90° 与等比铺满连续动画（退出反向）；起/终点用「视频显示带」 |
| `DramaPlayerViewModel.swift` | ViewModel | 单集播放状态机：load（KVO 直挂 + 看门狗 + 代际令牌）、isReady/isLoadingSlow/isScrubbing、seek、倍速、时间进度 |
| `PlayerFeedViewModel.swift` | ViewModel | 分页数据源、当前页、`schedulePageSettle` 停稳防抖 + 相邻集预热、边界 toast；组装 `DramaPlayerViewModel` |
| `PlayerFeedView.swift` | View | 分页容器 SwiftUI 侧：onAppear/onChange 转发 `schedulePageSettle` |
| `PlayerPagingScrollView.swift` | View | **UIKit `UIScrollView.isPagingEnabled` + `UIHostingController` 卡片**；seekPan/edgePan 识别器、`refreshCardsIfNeeded`（currentSort/isReady/toast/槽位可用性 变化时重设 rootView）；挂载单例 surface 与全屏控制器，`videoGravity` 在此按片源方向统一设置 |
| `DramaPlayerView.swift` | View | 单张卡片（390×840 逐节点，**卡片内零连续手势**，点按/长按离散手势在此；视频区透明，控件已抽成可复用组件）|
| `PlayerSurfaceContainer.swift` | View | `PlayerSurfaceUIView` **单例视频容器**：唯一 `AVPlayerLayer` 宿主，挂分页滚动层下对位活跃卡；`videoLayer` 是可搬运子层（背板层不能离开自己的 view）；首显机制 concealForReveal/scheduleVideoReveal + `withoutLayerActions` 禁隐式动作（原每卡一个 `PlayerSurfaceView` 已废）|
| `PlayerFullscreenControlsView.swift` | View | 全屏控制层（UIKit + Combine，横屏坐标空间挂全屏容器内）：顶栏返回/清屏/静音 + 底栏进度条/时间；点按呼出 3s 收起；订阅同一个 VM，状态不另立源 |
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
9. **播放页两条有意取舍（2026-11-13 用户拍板）**：① 全屏 = 观影模式——竖屏画布的信息区/点赞收藏/上滑提示在全屏控制层 `PlayerFullscreenControlsView` 不渲染（只有顶栏返回/清屏/静音 + 底栏进度条/时间），点赞收藏回竖屏卡片操作，勿当缺失补回全屏（原 `landscapeOverlay` 路线已随包 A 退役）；② 片源方向未知（`AVPlayerItem.presentationSize` 0×0）按竖屏 fill 处理，宁可不切换也不猜方向。详见 AGENTS「iOS 架构约定」第 12 条。

## 5. 待办清单（按优先级）

| # | 事项 | 优先级 |
|---|---|---|
| 1 | **本轮全部改动的真机回归**（清单见 §7）：GCD 迁移行为不变量 + 保活 + 手势 + toast/服务器/进度条/剩余时间 + 详情页滚动/直点/推荐跳转/档案 | 高（验证） |
| 2 | 浏览页路由统一（见 §6，本轮只查未改） | 中 |
| 3 | 相邻卡片首帧海报（渐变占位 → AVAssetImageGenerator + 磁盘缓存，可复用预热池 asset） | 中 |
| 4 | 本地推荐算法（接入点已留 §4.6） | 按需 |
| 5 | 「长按 2x 中途继续上滑切集」手势竞争观察（离散手势回卡片后未专测此组合） | 低 |
| 6 | **播放器视图壳 UIKit+Combine 化**：**包 A（全屏链路）已完成**（§2，分支 feat/player-uikit-shell）；包 B 待做——竖屏卡片 DramaPlayerView UIKit 化（designFrame 转 frame+scale）、卡片手势迁 UIGestureRecognizer（六条仲裁约束逐条对照）、PlayerFeedView/Container 胶水收编、UIHostingController 退役；VM/Service/Model（GCD+Combine）零改动路线已在包 A 验证（全屏控制器/控制层直接订阅同一批 @Published）；前置调研：specs/播放器旋转方案调研.md（ZFPlayer/SJRotation/KSPlayer 源码级对照 + 借鉴清单，搬运粒度维持 videoLayer 勿改搬 view） | 中 |

## 6. 待查 / 已知问题

- **浏览页路由「有时原生有时 web」（未改，待拍板）**：`decidePolicyFor` 只在 `navigationType == .linkActivated`（真实 `<a>`）+ `DramaTarget.parse` 命中时取消网页推原生；卡片若用 JS `location.href`/`pushState`/`window.open` 跳，`.other` 拦不住。URL KVO 兜底但 `detectDrama` 有 `lastAutoDramaKey` 去重、`pushDramaPage` 不写该标记 → 两路径状态不一致，同剧二次点击可能被挡。`DramaTarget.parse` 只认 `/drama/(video|detail)/<数字>`。建议：主帧剧集 URL 一律 `.cancel` 并推原生、两路径共用去重标记——触及导航，先等确认。
- **手势残余边界（可接受）**：带外慢速横向拖拽 >0.15s 仍可能起 2x（慢拖与「长按+慢漂移」不可区分，「先起者独占」的固有歧义）。
- **tags 数据源（已定案，细节见 `DramaDetailData` 代码注释）**：站点 detail 走 Nuxt `_payload.json`（devalue 扁平数组），非明文/非信封；解码链 明文→信封→payload，`via=plain|envelope|payload` 日志区分。旧缓存无 `tags_source` → 进页自动补采一次。
- **纸本轨字体（已定案 2026-11-14：保持系统字体）**：画布用 Noto Serif SC / Noto Sans SC，App 走系统字体（宋体/苹方）替代，纵向落位存在 ≤4pt 偏差。用户拍板不内置（省 10–20MB 包体），该偏差只在与设计稿逐像素并排比才看得出，接受。**若将来要 1:1 还原，改 `DWFont` 映射 + 打包字体文件即可，View 层不用动**（`DWFont.serif/cn` 本来就是唯一入口）。
- **`docs/design/gear-*`（已处理 2026-11-14）**：5 个工作稿已入库（`122ee41`），3 个 `.DRAFT-not-adopted` 废弃稿已删除。后续同类比稿：**采用稿入库、废弃稿即删**，不要留 DRAFT 后缀的文件堆在仓库里。

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
- **纸本视觉验收走模拟器**（不需要真机）：构建 / 装机 / 截图 / Debug 启动参数（`-startDownloadedPage` `-startEditMode`）/ 慢速 HLS 造下载中 / 「模拟器拿不到 print 与 UserDefaults，只能靠屏幕探针」全部记在 AGENTS「模拟器视觉验收」一节。
- 秒开：`preload OK` / `preload EVICT` / `makeItem HIT|MISS` / `load OK waitedMs=` / `spinner show` / `status STALE`。
- 交互：`TAP → togglePlayback` / `LONGPRESS began|ended` / `seekPan began`（竖滑不应再出现）/ `edgePan → back` / `scrub show|hide`。
- tab 卡顿：`PERF_DBG stallProbe enabled`（探针自检）+ `PERF_DBG mainStall ms=`（>100ms 真卡顿）+ `PERF_DBG tabSwitch`，切回浏览页看 mainStall 是否消失。

**本轮真机回归重点**：① WiFi/蜂窝下载（IP 直连/WebKit 降级日志）；② 切回浏览页不再 mainStall；③ 竖滑/斜滑不再误暂停；④ 点按显示进度条 3s、上升淡入；⑤ 右侧时长切剩余时间、杀进程重开记住；⑥ toast 2s 收回；⑦ 播放不再偶现「无法连接服务器」；⑧ 秒开 `makeItem HIT`、长按 2x/横滑 seek/翻页仲裁不变；⑨ 详情页整页能滚到推荐与档案、`PLAYER_DBG [Entry] reco refresh count=10 archiveSections=9`、推荐卡片 push 新剧集页后返回能回原剧、格子直点（未下载→入队 / 下载中→取消 / 已下载→播放）、「下载全部」不重复入队、左缘返回手势与整页 ScrollView 不打架；⑩ 角标与金环（未下载灰箭头 / 已下载金三角 / 下载中金环+n/100 / 选中集不叠加）、「查看全部 ›」内联展开 13+ 集后推荐区被正确下推不重叠、「收起 ›」能收回、工具条全选→下载所选可提交、选集行 ↻ 刷新生效；⑪ 快速横滑结束不再误暂停、且 seek/翻页/2x 仲裁不变（误吞时应见 `TAP SKIP reason=justEndedSeek`）；⑫ 横屏片源竖屏持机完整显示不裁切（`videoOrientation landscape=true`）、竖屏片源维持拉满；⑬ 旋转横屏后返回/清屏/静音/进度条尺寸正常（landscapeOverlay）、旋转回竖屏恢复画布布局、横屏下点按暂停/长按 2x/横滑 seek/左缘返回照常；⑭ **（全屏改造后，取代 ⑬ 的旋转条目）**：App 锁竖屏——转设备不再引发界面翻转；横屏片源稳定转横自动进全屏（动画连续、视频全程可见不跳变、无按钮）、45° 边界倾斜不反复进出、全屏内左上返回 icon 回竖屏（动画反向回原卡）、点按暂停/长按 2x/横滑 seek 可用且不误暂停、竖屏片源转横不动作、上下滑切集不受影响、杀进程重开全屏态不残留；**两个转向都验**——向左倒与向右倒各进一次全屏，画面均不上下倒置（返回 icon 左上、进度条在底），退出反向动画两个方向同样正常（de08f27 修的就是另一半转向倒置）；全屏中再转向另一侧应单段转体（锚点：`flip angle=` / `flip done`），两侧都要验。

## 8. 维护本文档

每完成一个任务：更新 §2 状态 / §5 待办，提交里带上本文档变更。**改架构约定改 `AGENTS.md`，改进度状态改本文档**；实现细节写进代码注释，不在此堆 build 日志。
