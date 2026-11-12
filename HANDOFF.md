# HANDOFF.md — 交接文档

> 给接手的 AI 编码代理：**先读 `AGENTS.md`**（硬性禁止 + 架构/日志/网络/并发约定，最高优先级）。本文只讲「做到哪了 / 还剩什么 / 怎么验」。**实现细节与防回归约束在 AGENTS 与代码注释里，完整过程在 git 历史**，本文不重复每个 build 日志。
>
> 最后更新：2026-11-12 · 分支 `feat/drama-detail-page` · 基准提交见 `git log -1`

## 1. 项目一览

智能 m3u8 视频下载器，跨平台多形态（Python CLI / Streamlit / Mac App / iOS App）。**近期全部工作聚焦 iOS**（`iOS/SmartDownloader/`，Xcode 26 folder-sync 工程，新 Swift 文件放入目录即自动编译）。用户只要求维护 iOS，勿主动改 Python 侧。

iOS App：WKWebView 嗅探 + Swift 下载核心 + SQLite 剧集缓存 + 本地 HLS 离线播放。核心页面：浏览（WKWebView，`MainTab.browser`）、下载（`MainTab.downloads`）、设置（`MainTab.settings`）、沉浸式播放页（抖音式上下滑切集，fullScreenCover）。

## 2. 功能状态

### 已实现并真机验证（细节见 AGENTS / 代码 / git）

剧集嗅探 → 原生剧集页 → 选集下载（含蜂窝 IP 直连降级）· 下载页双 tab 横滑 + 排序 + 批量编辑 · 重复点击下载防重 · 播放页设计稿还原 + 真实 AVPlayer + 长按 2× + 点按暂停 + 全屏无黑边 + 左缘返回 · 横向 seek 全屏化（相对映射，一屏宽≈全片时长）· 全剧集数同步（三真实来源，绝不造槽位）+ 边界 toast · UIKit 原生分页 · 秒开三件套（预热池 + KVO 直挂 + spinner 延迟）· 清屏模式 · 启动页 splash · 剧集详情页设计稿（390×840 三态 / 单选 CTA / 查看全部下载面板 / 收藏 / 下载进度环）。

### 本轮（2026-11-12）改动

| 项 | 说明 | 状态 |
|---|---|---|
| 全量 GCD 迁移 | 移除 Swift concurrency：工作线程+信号量线性管线、DispatchGroup 6 并发、DispatchWorkItem 定时、代际令牌；两处 async 岛见 AGENTS「并发与线程」 | Mac 构建+冒烟全过，**待真机回归** |
| 降 Swift 5 | pbxproj `SWIFT_VERSION 6.0→5.0` + `minimal`（与 project.yml 对齐）；删尽 @MainActor/nonisolated/assumeIsolated/Mutex | 已完成 |
| 消 deprecated 警告 | 资产加载改回 `asset.load` 包 @MainActor Task 岛（恢复迁移前写法，秒开不变） | 构建零警告 |
| 播放页 toast 不收回 | `toastText` 按值快照入卡片，`refreshCardsIfNeeded` 未纳入 toast 变化→dismiss 后不重绘。加 `activeToast` 触发刷新 | 已修，真机确认收回 |
| 播放器偶现「无法连接服务器」 | `LocalMediaServer.start` 未 ready 时二次调用回 port=0→拼出 `:0`。改登记等待、ready 统一回调；playbackURL 端口 0 显式失败 | 已修 |
| tab 切换卡顿 | 探针三修（横杠兼容 / Debug 常开 / 心跳 20ms 消除假阳性）定位到 WKWebView 离屏唤醒；App 改 ZStack 保活容器 + 自定义 tab bar（AGENTS 决策 8） | 待真机回归 |
| 竖滑误暂停 | seekPan 不限方向、竖滑也 began 搅乱触摸取消→误判 TAP。加 `gestureRecognizerShouldBegin` 拒纵向主导 | 待真机回归 |
| 点按显示进度条 | togglePlayback 触发 HUD + 3s 淡出（清屏下也可见） | 待真机验证 |
| 进度条组合动画 | 出现时上升 12pt + 淡入，共用 0.2s easeInOut | 待真机验证 |
| 右侧时长切换剩余时间 | label 点按切 `-M:SS`↔总时长，`PlayerPreferences.showRemainingTime` 持久化 | 待真机验证 |
| toast 时长 | 3s→2s | 已完成 |
| 注释清理 | 删 GCD 迁移回声注释（等价旧 Task/.task 等），保留防回归说明 | 已完成 |
| 设置 tab 页 | 新增 `Settings/` 域（Service/VM/View）：条目 1 选启动落在哪个 tab，条目 2 浏览页快捷站点多对 key/value 增删改；浏览页 label 行改读配置 | 模拟器构建通过，待真机验证 |

## 3. `player/` 模块架构地图（MVVM + Service）

依赖方向：**View → ViewModel → Service → 系统/Model**，单向不可反向；组装根只做 DI。

| 文件 | 层 | 职责 |
|---|---|---|
| `PlaybackModels.swift` / `DramaEpisode.swift` | Model | 纯数据：`PlayableEpisode` / `ImmersivePlaybackRequest`、卡片展示模型 |
| `PlaybackQueueService.swift` | Service | **上下滑资源调度唯一入口**：全剧集数三来源、槽位、history 回溯栈、`resolveNext/resolvePrevious`（推荐算法接入点）、`neighbors(of:)` |
| `PlaybackPlayerService.swift` | Service | 唯一常驻 `AVPlayer`、`makeItem`（预热池 HIT/MISS）、`preload`/`clear`/`teardown` |
| `PlayerPreferences.swift` | Service | 静音/清屏/点赞/收藏/**剩余时间显示**持久化（UserDefaults 封装）|
| `PlayerGesturePolicy.swift` | Service | 仅剩 scrub 灵敏度纯函数（命中带已废）|
| `DramaPlayerViewModel.swift` | ViewModel | 单集播放状态机：load（KVO 直挂 + 看门狗 + 代际令牌）、isReady/isLoadingSlow/isScrubbing、seek、倍速、时间进度 |
| `PlayerFeedViewModel.swift` | ViewModel | 分页数据源、当前页、`schedulePageSettle` 停稳防抖 + 相邻集预热、边界 toast；组装 `DramaPlayerViewModel` |
| `PlayerFeedView.swift` | View | 分页容器 SwiftUI 侧：onAppear/onChange 转发 `schedulePageSettle` |
| `PlayerPagingScrollView.swift` | View | **UIKit `UIScrollView.isPagingEnabled` + `UIHostingController` 卡片**；seekPan/edgePan 识别器、`refreshCardsIfNeeded`（currentSort/isReady/toast 变化时重设 rootView）|
| `DramaPlayerView.swift` | View | 单张卡片（390×840 逐节点，**卡片内零连续手势**，点按/长按离散手势在此）|
| `PlayerSurfaceView.swift` | View | `AVPlayerLayer` 包装 |
| `DramaPlayerContainer.swift` | 组装根 | fullScreenCover 入口，onAppear configure + onDisappear stop |
| `Components/ToastView.swift` | 全局组件 | 通用 toast，不依赖业务/坐标系 |

其余域（Shared / Drama / Downloads / Browser / Infra）见 AGENTS「目录」节。

## 4. 关键设计决策（勿轻易推翻）

1. **分页用 UIKit `UIScrollView.isPagingEnabled`**。SwiftUI `ScrollView + .scrollTargetBehavior(.paging)` 与卡片 GeometryReader/手势冲突，四轮排障完全滑不动，已弃用（勿改回）。轻滑翻页靠 `scrollViewWillEndDragging` 里 15% 位移或 0.3 速度阈值。
2. **卡片内禁止任何连续手势**——手势分类与长按 2x↔seek 仲裁细则见 AGENTS「具体约定」2。seekPan 已加 `gestureRecognizerShouldBegin` 方向过滤（拒纵向主导）。
3. **单播放器常驻**，切集只 `replaceCurrentItem`，禁止滑动时新建 AVPlayer；秒开靠预热池三件套（AGENTS「具体约定」3），不是多 player pool。
4. **App 用 ZStack 保活容器而非 TabView**：WKWebView 不离屏，避免切回浏览页时离屏唤醒阻塞主线程（AGENTS「具体约定」8）。
5. **集数绝不造假**：来源优先级 = 调用方 knownSorts → SQLite `DramaCache.allSorts` → 磁盘已下载兜底。没有元数据时只有 1 集就不能滑，toast「已经到底了」。
6. **推荐算法接入点**：只改 `PlaybackQueueService.resolveNext/resolvePrevious`；`neighbors(of:)` 也走它们，预热自动跟随新序。
7. **诊断日志**：`PLAYER_DBG` 前缀 + `[CHECK]` 断言行；失败分支必须有 log；排障后保留不清理（全文见 AGENTS）。

## 5. 待办清单（按优先级）

| # | 事项 | 优先级 |
|---|---|---|
| 1 | **本轮全部改动的真机回归**（清单见 §7）：GCD 迁移行为不变量 + 保活 + 手势 + toast/服务器/进度条/剩余时间 | 高（验证） |
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

**本轮真机回归重点**：① WiFi/蜂窝下载（IP 直连/WebKit 降级日志）；② 切回浏览页不再 mainStall；③ 竖滑/斜滑不再误暂停；④ 点按显示进度条 3s、上升淡入；⑤ 右侧时长切剩余时间、杀进程重开记住；⑥ toast 2s 收回；⑦ 播放不再偶现「无法连接服务器」；⑧ 秒开 `makeItem HIT`、长按 2x/横滑 seek/翻页仲裁不变。

## 8. 维护本文档

每完成一个任务：更新 §2 状态 / §5 待办，提交里带上本文档变更。**改架构约定改 `AGENTS.md`，改进度状态改本文档**；实现细节写进代码注释，不在此堆 build 日志。
