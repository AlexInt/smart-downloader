# HANDOFF.md — 交接文档

> 给接手的 AI 编码代理：**先读 `AGENTS.md`**（硬性禁止 + 架构/日志/网络约定，最高优先级），本文档讲「已经做了什么、还剩什么、怎么继续」。两份都读再动手。
>
> 最后更新：2026-11-11 · 分支 `main` · 基准提交见 `git log -1`

## 1. 项目一览

智能 m3u8 视频下载器，跨平台多形态（Python CLI / Streamlit / Mac App / iOS App）。**近期全部工作聚焦 iOS**（`iOS/SmartDownloader/`，Xcode 26 folder-sync 工程，新 Swift 文件放入目录即自动编译）。用户只要求维护 iOS，勿主动改 Python 侧。

iOS App 形态：WKWebView 嗅探 + Swift 下载核心 + SQLite 剧集缓存 + 本地 HLS 离线播放。核心页面：浏览（WKWebView）、下载（双 tab 横滑）、沉浸式播放页（抖音式上下滑切集）。

## 2. 当前状态（截至本次交接）

### 已就绪、经用户真机验证过的功能

| 功能 | 状态 |
|---|---|
| 剧集嗅探 → 原生剧集页 → 选集下载（含蜂窝网络 IP 直连降级） | ✅ 早期完成 |
| 下载页双 tab（下载中/已下载）横滑、创建时间排序、删除、批量编辑 | ✅ `3234c10` |
| 重复点击下载防重 | ✅ `3234c10` |
| 播放页：设计稿还原 + 真实 AVPlayer 播放、长按 2×、点按暂停 | ✅ `11664da` / `5a9dde5` |
| 全屏无黑边、可关闭、进度条带内水平 seek（±60pt） | ✅ `80d2f9d` |
| 全剧集数同步（三种真实来源，绝不造槽位）、边界 toast「已经到底了」 | ✅ `c746815` |
| UIKit 原生分页（轻滑 15% 翻页、起始定位正确、11 集双向滑动） | ✅ `78abf2d`，用户日志确认全链路 OK |
| 秒开三件套（相邻集预热池 + KVO 事件流就绪 + spinner 延迟显示） | ✅ 编译通过，**待用户真机体验确认** |
| 播放页交互细节修复批（布局收紧/静音图标/点按分区/边缘返回/倍速） | ✅ 编译通过，**待用户真机体验确认**（见下） |
| 清屏模式（隐藏界面信息只看画面，状态本地记住） | ✅ 编译通过，**待用户真机体验确认** |

### 秒开优化（本次刚做，未验证细节）

背景：用户问「已下载视频为什么还要 loading」。时间线拆解：150ms 停稳防抖 + AVPlayer 固有异步管线（拉 m3u8 → 解析 → 取首段 → 解码）+ 旧代码 100ms 轮询量化误差 + spinner 全程显示，合计体感 300–500ms。三项改动：

1. **`PlaybackPlayerService` 相邻集资产预热池**：`preload(_:)` 提前对相邻集 `asset.load(.isPlayable)`（完成 m3u8 拉取解析），`makeItem` 命中池则直接构建 item（log `makeItem HIT`）。停稳播当前集时并行预热两侧；进入播放页时首集也预热（与 150ms 防抖并行）。池按需淘汰，`teardown()` 全清。
2. **`DramaPlayerViewModel` KVO 事件流**：旧 100ms 轮询删除，改为 `statusEvents(for:timeout:)`（KVO → AsyncStream，`.initial` 覆盖「观察前已 ready」的 HIT 场景，4s 看门狗，取消安全——新滑动自动终止并清理观察器；`item === player.currentItem` 防陈旧回调翻转状态）。
3. **spinner 300ms 延迟显示**：`isLoadingSlow` 只在 300ms 未就绪时置 true，`DramaPlayerView` 的 ProgressView 挂在它下面；视频/渐变层加 150ms easeOut 交叉淡入。

验证方法（真机抓 log，见 §6）：预热生效应看到 `preload OK sort=N` → 滑动后 `makeItem HIT` → `load OK ... waitedMs=<几十>`（旧轮询是 `waited=1~3` 即 100–300ms），且滑动切集不再出现转圈。

**真机首测暴露两个 bug，已修（2026-11-11）**：
1. **seek 非第一页全失效**：`location(in: scrollView)` 是内容坐标（含 contentOffset），未换算成屏幕坐标就喂给 `isInSeekBand`；第一页 offset=0 掩盖了问题。已在 shouldBegin / didSeekPan 减 contentOffset（log 现在同时打 screenY 与 contentY）。
2. **预热池被自己的淘汰逻辑打穿（全 MISS）**：pageSettled 只报邻居为 wanted，每次滑动先把上一轮为当前集预热的资产淘汰掉再 makeItem。修复：wanted = [当前集] + 邻居（调用方 `preloadNeighbors(of:current:)` 保证）。曾试过在 service 加 `playingSort` 过滤避免重复预热，但它把「刚离开的集」也剔出 wanted——该集资产已被消费又永不重暖，**回滑必 MISS**，已删；重暖刚离开的集本来就是来回滑动的 HIT 保险（它总是新当前的邻居），代价仅一次回环 m3u8 解析。
3. 附带修正 `waitedMs` 日志换算（`components.seconds` 只有整秒，亚秒在 attoseconds，此前 <1s 全打成 0ms）。

### 交互细节修复批（同日第二批，待真机验证）

用户报告的 8 个 bug 一次修完：

1. **底部布局收紧**：左下信息簇（账号/标题/简介/标签/音频）整体下移 44pt，进度条 y 700→744、宽 290→350（左右边距对称各 20pt），时长文字右对齐到进度条右端；进度条与「上滑观看下一集」间距 97→53pt。
2. **点赞/收藏文字居中**：文字框改为与按钮框同位同宽（中心 347），修掉右偏 10pt。
3. **静音图标**：无独立静音素材，`ic_sound` 静音时变灰 + 叠加金色 45° 斜线。
4. **点控件不再连带暂停**：点按/长按从 UIScrollView 识别器移回**卡片内 SwiftUI 手势**（`.onTapGesture` / `.onLongPressGesture(pressing:)`）——SwiftUI 深度优先解析让 Button（返回/静音/点赞/收藏）天然优先，删掉了 `isTapOnControl` 几何判定表（用户指出维护成本高：每加一个控件都要登记）。离散手势与系统分页不冲突，只有连续手势必须留在 UIKit 层。
5. **左缘右滑返回**：fullScreenCover 无系统边缘返回，`UIScreenEdgePanGestureRecognizer`（.left，与系统 pan 同时识别）拖过 50pt 即触发 `onClose`。
6. **长按 2x 提速**：`minimumPressDuration` 0.25→0.15s，提示淡入 0.15→0.1s。
7. **松手立即回 1x**：根因是 `endFastForward` 只在 `.playing` 时置 `rate=1`，缓冲等待态（`.waitingToPlayAtSpecifiedRate`）被漏掉，缓冲恢复后仍是 2x；现在只要非暂停一律拨回 `rate=1`，`beginFastForward` 也接受等待态起 2x。
8. **几何同步**：`PlayerGesturePolicy` 的 seek 带（y 684..804）与 fraction 宽度（350）已随新布局更新——**进度条再动必须同步改这两处**（AGENTS 已记）。

### 清屏模式

- 静音旁（左侧，设计稿 277,41）新增「清屏」按钮：隐藏界面信息组（字幕/左下信息区/进度条/互动栏/上滑提示/上下压暗），保留常驻控件（返回/静音/清屏/集数胶囊）与瞬态反馈（倍速/加载/错误/toast）。切换 0.2s 交叉淡入淡出。
- **集数胶囊改为紧凑「4/11」**（`DramaEpisode.compactEpisodeLabel`），56pt 宽居中（x=167），永远紧凑格式、清屏不隐藏——用户在「清屏时切换格式」与「永远紧凑」两案中选定后者（一致性更好、顶栏四元素不拥挤、无格式切换动画复杂度）。
- 状态本地记住：`PlayerPreferences.isCleanScreen`（UserDefaults "DramaPlayer.cleanScreen"），VM init 恢复，同静音模式一套机制。
- 图标为 SwiftUI 绘制（圆角矩形描边 + 激活时金色斜线），与静音图标同一视觉语言；素材库无需新增图片。
- 新按钮**零手势代码**：Button 天然优先于卡片点按（手势架构简化的直接收益）。

## 3. `player/` 模块架构地图（MVVM + Service）

依赖方向：**View → ViewModel → Service → 系统/Model**，单向不可反向；组装根只做 DI。

| 文件 | 层 | 职责 |
|---|---|---|
| `PlaybackModels.swift` | Model | `PlayableEpisode` / `ImmersivePlaybackRequest` / `PlaybackDirection`，纯数据 |
| `DramaEpisode.swift` | Model | 卡片展示模型（设计稿文案/预览值） |
| `PlaybackQueueService.swift` | Service | **上下滑资源调度唯一入口**：全剧集数三来源、槽位构建、history 回溯栈、`resolveNext/resolvePrevious`（推荐算法接入点）、`neighbors(of:)`（预热目标，走同一接入点） |
| `PlaybackPlayerService.swift` | Service | 唯一常驻 `AVPlayer`、`makeItem`（含预热池 HIT/MISS）、`preload` / `clear` / `teardown` |
| `PlayerPreferences.swift` | Service | 静音/点赞/收藏持久化（UserDefaults 封装） |
| `PlayerGesturePolicy.swift` | Service | 纯函数几何判定（seek 带内/进度比例，390×840 设计坐标 ↔ 屏幕坐标） |
| `DramaPlayerViewModel.swift` | ViewModel | 单集播放状态机：load（KVO 事件流）、isReady/isLoadingSlow、seek、倍速、时间进度 |
| `PlayerFeedViewModel.swift` | ViewModel | 分页数据源、当前页、停稳后切源 + 相邻集预热触发、边界 toast；组装 `DramaPlayerViewModel` |
| `PlayerFeedView.swift` | View | 分页容器（SwiftUI 侧）：`.task(id:)` 150ms 停稳防抖 |
| `PlayerPagingScrollView.swift` | View | **UIKit `UIScrollView.isPagingEnabled` + `UIHostingController` 卡片**；点按/长按/seekPan 识别器都挂这里 |
| `DramaPlayerView.swift` | View | 单张卡片（390×840 设计稿逐节点映射，**卡片内零连续手势**） |
| `PlayerSurfaceView.swift` | View | `AVPlayerLayer` 包装 |
| `DramaPlayerContainer.swift` | 组装根 | fullScreenCover 入口，configure + onDisappear stop |
| `Components/ToastView.swift` | 全局组件 | 全局 toast，不依赖业务/坐标系 |

## 4. 关键设计决策（勿轻易推翻）

1. **分页用 UIKit `UIScrollView.isPagingEnabled`**。SwiftUI `ScrollView + .scrollTargetBehavior(.paging)` 与卡片 GeometryReader/手势冲突，四轮排障完全滑不动，已弃用（AGENTS 有记录，**勿改回**）。轻滑翻页靠 `scrollViewWillEndDragging` 里 15% 位移或 0.3 速度阈值。
2. **卡片内禁止任何连续手势**（包括局部 DragGesture）——曾因进度带局部 DragGesture 吃掉全部纵向滑动。所有交互用 UIKit 识别器挂分页 ScrollView 上，`cancelsTouchesInView = false`，seekPan 与系统 pan 同时识别、只在「起点在进度带 ±60pt + 水平主导」时 begin。
3. **单播放器常驻**，切集只 `replaceCurrentItem`，禁止滑动时新建 AVPlayer。秒开靠预热池三件套（§2），不是多 player pool。
4. **集数绝不造假**：来源优先级 = 调用方 knownSorts → SQLite `DramaCache.allSorts` → 磁盘已下载兜底。没有元数据时只有 1 集就不能滑，toast「已经到底了」，不造空槽位。
5. **推荐算法接入点**：只改 `PlaybackQueueService.resolveNext/resolvePrevious`（可读 slots/history/current，返回任意槽位即换序）。`neighbors(of:)` 也走它们，预热自动跟随新序。
6. **诊断日志**：`PLAYER_DBG` 前缀 + `[CHECK]` 断言行（带输入与判定）；失败分支必须有 log；排障后保留不清理（约定全文见 AGENTS.md）。

## 5. 待办清单（按优先级）

| # | 事项 | 说明 | 优先级 |
|---|---|---|---|
| 1 | **用户真机确认秒开体验** | 本次优化只过了编译；重点看 HIT 路径 log 与「切集无转圈」体感 | 高（验证） |
| 2 | 相邻卡片首帧海报 | 相邻页现在是渐变占位；可做首帧缓存（AVAssetImageGenerator）+ 磁盘缓存，更接近抖音观感。预热池里的 asset 可直接复用 | 中 |
| 3 | 非当前卡片的状态显示隔离 | 相邻卡片复用了当前卡的进度/点赞/收藏显示（`DramaPlayerView` 里 playback 是共享单例），需按 isActive 隔离为静态预览值 | 中 |
| 4 | 未下载占位页拦截 | 有全剧集数但只下载 1 集时，上滑仍会切到「尚未下载」空页；用户明确**记下待办、本次不做**，期望是滑到未下载集时提示「已经到底了」式引导 | 低（用户定级） |
| 5 | 本地推荐算法 | 接入点已留好（见 §4.5），算法本身未实现 | 按需 |
| 6 | 「长按 2x 中途继续上滑切集」手势竞争 | 离散手势回卡片后未真机验证该组合；若出现长按后滑不动，调 maximumDistance 或该手势回 UIKit | 低（观察项） |

## 6. 验证与调试

```bash
# 编译（不启动模拟器，无签名）
xcodebuild -project iOS/SmartDownloader.xcodeproj -scheme SmartDownloader \
  -destination 'generic/platform=iOS Simulator' build

# 真机日志（用户自己跑，代理只看 log）
xcrun devicectl device process launch --console --device <id> com.firefish.smartdownloader
```

- 排障一律**先加 log 再请用户提供 log**，靠日志判读，不靠猜测改代码（这是本项目的协作模式，用户会贴 log）。
- 秒开链路关键 log 行：`preload OK` / `preload EVICT` / `makeItem HIT|MISS` / `load OK ... waitedMs=` / `spinner show`（出现即说明 300ms 未就绪）/ `status STALE`。
- 交互链路关键 log 行：`TAP → togglePlayback` / `LONGPRESS began|ended → 2x|1x` / `edgePan dx=.. > 50 → back`。
- 冒烟工具（macOS，不需手机）：`iOS/smoke/` 下 coretest / playtest 等，编译命令见 AGENTS.md。

## 7. 硬性禁止（全文见 AGENTS.md，此处摘要）

- **禁止对浏览页 / WKWebView 截图**（测试、验证、演示都不行）；验证只看 log。
- 禁止启动模拟器跑 UI（编译可以）；用户明确杀过一次。
- 不 push；提交 = 中文 message + feat/fix/refactor/docs 前缀，每个任务完成即 commit。
- 只关注 iOS，勿动 Python 侧。
- 站点地址不硬编码进通用模块；Info.plist 的 folder-sync 排除规则勿破坏。

## 8. 维护本文档

每完成一个任务：更新 §2 状态表 / §5 待办清单，并在提交里带上本文档的变更。改架构约定改 `AGENTS.md`，改进度状态改本文档。
