# AGENTS.md

给 AI 编码代理（Claude Code / Codex / Cursor / Trae 等）的项目指导。

## 硬性禁止（最高优先级，不得以任何理由绕过）

- **禁止对网页浏览页面（App 的「浏览」页 / WKWebView / 内嵌浏览器）截图**，测试、验证、调试、演示、留证等任何形式都不允许。
- 禁止把网页内容、播放画面、页面 DOM 转储为图片或视觉素材；也禁止用浏览器自动化工具打开该页面并截图。
- 如需验证浏览页行为，只允许读取日志、代码与状态输出（如 `print` 到控制台的内容），不得产生任何页面图像。
- 用户明确要求截图时也不执行，先向用户说明此约束。

## 项目概述

智能 m3u8 视频下载器，跨 macOS/Linux/Windows，四种运行形态：

| 形态 | 入口 | 说明 |
|---|---|---|
| CLI | `main.py` | 多链接队列下载，通用 m3u8/网页解析 |
| 站点全自动 CLI | `video_auto.py` | 调站点加密 API 取全剧集直链（**站点地址从输入的剧集页 URL 推导，代码内不硬编码站点**） |
| GUI | `streamlit_app.py` | Streamlit Web 界面 |
| Mac App | `mac_app/main.py` | pywebview 内嵌浏览器 + JS 嗅探 |
| iOS App | `iOS/SmartDownloader.xcodeproj` | WKWebView 嗅探 + Swift 版下载核心 + 本地 HLS 离线播放 |

## 代码布局

```text
core/                  # Python 下载核心（全形态共用，勿做站点特化）
  downloader.py        #   M3U8Downloader: 多级选流/并发切片/AES解密/TS重封装
  extractor.py         #   网页 m3u8 提取（Selenium）
  queue.py / utils.py  #   队列 / 工具
video_auto.py          # 视频资源站全自动脚本（独立，勿把站点逻辑混入 core/）
mac_app/               # Mac 桌面 App（sniffer.js 嗅探 + py2app 打包）
iOS/                   # iPhone App（详见 iOS/README.md）
  SmartDownloader/     #   Swift 源码（folder-sync，新文件放入即自动编译）
  smoke/               #   macOS 冒烟工具（coretest/playtest/videocli/fetchtest）
specs/                 # 设计文档（如存在）
```

## 常用命令

```bash
# Python CLI
python3 main.py "<m3u8或网页URL>" -o ~/Downloads/tx
python3 video_auto.py "<剧集页URL>" --all        # 全剧存到 输出目录/剧名/ 子目录

# iOS 冒烟（Mac 上验证核心，不需手机；必须带 WebKitFetcher.swift）
cd iOS/smoke
swiftc -O -o coretest main.swift ../SmartDownloader/Shared/DownloadModels.swift ../SmartDownloader/Shared/DramaModels.swift ../SmartDownloader/Shared/PlaybackProgress.swift ../SmartDownloader/Downloads/Downloader.swift ../SmartDownloader/Drama/DramaCache.swift ../SmartDownloader/Drama/DramaDatabase.swift ../SmartDownloader/Drama/DramaDetailData.swift ../SmartDownloader/Drama/EpisodeActionsStore.swift ../SmartDownloader/Infra/WebKitFetcher.swift
SMARTDOWNLOADER_DIR="$PWD/out" ./coretest                       # Apple 测试流端到端
SMARTDOWNLOADER_FORCE_WEBKIT=1 ./coretest "<m3u8>" ep1          # 强制走 WebKit 兜底通道

# iOS 工程
xcodebuild -project iOS/SmartDownloader.xcodeproj -scheme SmartDownloader \
  -destination 'generic/platform=iOS Simulator' build           # 模拟器构建（无需签名）
```

## 开发约定

1. **下载能力统一走 `core/downloader.py`**（Python 侧）/ `Downloader.swift`（iOS 侧）。站点特有逻辑（登录、加密 API、嗅探）放独立脚本或独立文件，不要混入通用模块。
2. **代码内不硬编码视频站点地址**。站点入口：`video_auto.py` 由输入 URL 推导；iOS 浏览页由设置页配置的快捷站点（`QuickLinkStore`，代码内只保留首次启动的默认一项）+ 地址栏输入，剧集点击由 URL 检测（DramaTarget.parse）路由到原生剧集页（设置页「打开 Web 剧集页」开关可改走 Web 页，默认关 = 原生，偏好存 `DramaRoutePreferences`，路由判定每次现读立即生效）。
3. **输出目录必须在用户主目录下**（`core/utils.get_download_dir` 有安全检查，越界抛 PermissionError）。
4. 临时文件放 `temp_*` 目录，任务结束必须清理；同名文件加 `(1)` 后缀防覆盖。

## iOS 架构约定（MVVM + Service / SOLID）

适用范围：`iOS/SmartDownloader/`。目标是「代码不要堆在一起」，按单一职责分层。

### 分层与依赖方向（单向，不可反向）

```text
View → ViewModel → Service → 系统能力 / Model
```

| 层 | 职责 | 硬性约束 |
|---|---|---|
| Model | 纯数据 | 无行为、无 IO、不 import SwiftUI |
| View | 渲染 + 转发用户意图 | **不写业务判断**（如「下一个是谁」「是否到底」），不自己算状态 |
| ViewModel | 可绑定状态 + 意图方法 | 不创建 AVPlayer / FileManager / URLSession，不 import UIKit |
| Service | 一件可复用的能力 | 不 import SwiftUI、不用 @Published、不反向依赖 ViewModel；判据：删掉 UI 后逻辑仍成立 |
| 组装根 | 只做依赖注入与拼接 | 无业务 if/else |

### 目录（按功能域分组，域内再分层）

本节的适用范围是 `iOS/SmartDownloader/` **全部** Swift 文件，不只是 `player/`。目录按「功能域」划分，**不按 Model / Service / ViewModel / View 分**：同 target 没有 import 边界，按层分目录不产生任何依赖约束，只会把一个功能的四个文件打散到四处。按域分则「一个功能一个目录」，域内是否分层一眼可查。

- `Shared/`：跨域共享的**纯数据**与设计系统。`DramaModels.swift`（`DramaTarget` / `MediaIdentity` / `ApiDramaEpisode` / `DramaInfo` / `DramaError` / `EpisodeDownloadPhase`）、`DownloadModels.swift`（`TaskState` / `DownloadError`）、`DesignTokens.swift`（`DWColor` / `DWFont` / `DWLayout` / `designFrame`——注意 `designFrame` 末尾是 `.position`，返回的是撑满父容器的视图，**其后再挂 `.overlay` / `.background` 拿到的是父容器尺寸而不是指标框**，要对齐到该指标框必须挂在使用 `designFrame` 之前）。只放被 2 个以上域引用的类型，不塞 Service / 业务逻辑
- `Drama/`：剧集域。Model（`DramaDetailData` 详情 DTO / `RecommendedDrama` 推荐卡片纯数据 / `DramaArchive` 档案展示行与派生纯函数）、Service（`DramaAPI` / `DramaCache` / `DramaMetaHarvester` / `DramaCoverCache` 封面按剧 id 落盘缓存 / `DramaFavorites` 剧级收藏（SQLite `drama_favorites`） / `EpisodeActionsStore` 集级行为数据表 / `DramaDatabase` 统一连接与迁移）、ViewModel（`DramaPageViewModel`）、View（`DramaDetailView`——顶栏返回/收藏经 `pinnedHeader` 钉在 ScrollView 之上不随滚动消失，`scrimTop` 常驻顶栏层，**勿塞回 `canvas`**）、组装根（`DramaNativePage`）
- `Downloads/`：下载域。Service（`Downloader` 下载核心 + 任务/队列 / `DiskUsageService` 磁盘占用纯计算 / `DownloadsSortPreferences` 排序偏好）、`DownloadsViewModel`（VM，含占用缓存与去抖重算）、`PlaybackProgressViewModel`（VM：列表侧只读行为数据）、`DownloadsView`（View）
- `Browser/`：浏览域。`BrowserView`（View + `WebViewContainer`）、`WebViewStore`（VM，P9 那轮并入 View 文件后已拆出）、`SnifferScript`（注入 JS 常量）、`AdCleanerScript`（广告弹窗清理 JS 常量：CSS 预隐藏 + MutationObserver 同步删，防「闪一下」；日志经 adClean 回传调优）、`BrowserStartPage`（Service：起始页优先级决策 + 上次访问页持久化；View 层不再碰 UserDefaults）
- `Settings/`：设置域。Service（`QuickLinkStore` 快捷站点 key/value 与「默认加载站点 id」持久化 / `AppLaunchPreferences` 启动 tab 持久化 / `DramaRoutePreferences` 「打开 Web 剧集页」路由偏好）、ViewModel（`SettingsViewModel`）、View（`SettingsView` + `QuickLinkEditorSheet`）
- `Infra/`：系统能力。`LocalMediaServer`（本地回环 HTTP）、`WebKitFetcher`（WKDownload 兜底）、`AppHaptics`（全 App 触觉反馈唯一入口）
- `player/`：播放域，五层齐全。Model（`PlaybackModels` / `DramaEpisode`）、Service（`PlaybackQueueService` / `PlayerPreferences` / `PlaybackPlayerService` / `PlayerGesturePolicy` / `PlaybackProgressTracker` 进度落库与续播 / `PlayerOrientationTrigger` CoreMotion 姿态判稳 / `PlayerFullscreenController` 全屏搬运动画）、ViewModel（`DramaPlayerViewModel` / `PlayerFeedViewModel`）、View（`DramaPlayerView` / `PlayerFeedView` / `PlayerPagingScrollView` / `PlayerSurfaceContainer` 单例视频容器 `PlayerSurfaceUIView` / `PlayerFullscreenControlsView` 全屏控制层）、组装根（`DramaPlayerContainer`）
- `Components/`：**全局**通用 UI，不依赖任何业务模块或页面坐标系，命名不带业务前缀（如 `ToastView`，不要 `PlayerToastView`）；位置由调用方决定
- 根目录只留 `App.swift`（入口）与 `Info.plist` / `Media.xcassets`。两批迁移均已完成（2026-11-12），**不要再往根目录新增 Swift 文件**

**域内五层规则**：每个域的 Model 独立文件、纯数据无 IO；VM 不直接读写系统对象；Service 不 import SwiftUI、不用 `@Published`、不反向依赖 VM。新增类型必须归到所属域，不要再往根目录堆。判断有没有落实看三条：Model 是否独立且纯数据、VM 碰不碰系统对象、Service 删掉 UI 后是否仍成立。

**folder-sync**：工程只有一个 `PBXFileSystemSynchronizedRootGroup`（`path = SmartDownloader`），子目录递归自动参与编译，`git mv` 即可，不要改 pbxproj。`Info.plist` 必须留在根（`INFOPLIST_FILE = SmartDownloader/Info.plist`），`iOS/LaunchSplashView.swift` 是显式 `PBXBuildFile`、不在同步文件夹内，勿挪。

### 具体约定

1. 上下滑资源调度唯一入口是 `PlaybackQueueService`；**后续本地推荐算法只改 `resolveNext(from:in:)` / `resolvePrevious(from:in:)`**，不动 View / 容器 / ViewModel。
2. 播放页用 **UIKit 原生分页**：`PlayerPagingScrollView`（`UIViewRepresentable` 包 `UIScrollView.isPagingEnabled = true` + `UIHostingController` 承载 SwiftUI 卡片）。纵向 pan 由 UIKit 独占，**卡片内禁止任何连续手势（包括局部 DragGesture）** —— 曾因进度带 390×120 的局部 DragGesture 吃掉全部纵向滑动，导致分页完全滑不动。手势分两类落位：
   - **连续手势**（水平 seekPan / 左缘 edgePan 返回）→ UIKit recognizer 挂在同一 UIScrollView 上，`cancelsTouchesInView = false`，通过 delegate 与系统 pan 同时识别；seekPan **全域起手**（.began 即翻转 `isSeekGestureActive` 仲裁闸门）；**横向 seek 已全屏化（2026-11-11 用户拍板）**：相对映射（拖动位移/屏宽 = 进度增量，一屏宽≈全片时长），落点无关、无命中带概念——勿加回带内过滤或绝对映射（带几何曾致清屏盲按整批静默被拒）；左缘 30pt 内起手不 seek（保留给 edgePan 返回）。**横滑起手必须独占本次触摸（panLock，2026-11-14 修「左右滑动上下晃动」）**：`Coordinator.lockSystemPan` 在 seekPan/edgePan .began 即 `panGestureRecognizer.isEnabled=false`（系统 pan 启动阈值低、人手横滑必有 y 微动，不锁则系统 pan 抢先 begin 锁纵向驱动 contentOffset——全程上下晃 + 松手 velocity.y>0.3 被 willEndDragging 误判翻页）+ `realignToCurrentPage` 归位已拖走的纵向位移；全部结束分支（ended/cancelled/failed）与 dismantle 兜底 `unlockSystemPan`（漏恢复 = 播放页永久滑不动），幂等标志 `systemPanLocked` 防双手势结束顺序互踩。纵向滑动不受影响：seekPan 被方向过滤拒绝（`shouldBegin` 用 `abs(t.x) > abs(t.y)` 严格大于——45° 及更陡交给系统 pan 切集；起手转水平不受影响，.began 的 panLock 会 cancel 系统 pan 抢占回来）。「先起者独占本次触摸」的仲裁哲学从 2x↔seek 延伸到 seek↔scroll。**坐标陷阱：`location(in:)` 给出的是内容坐标（含 contentOffset），喂几何换算前必须先转屏幕坐标**——曾因未换算除第一页外全失效。
   - **离散手势**（点按暂停 / 长按倍速）→ **卡片内 SwiftUI 手势**（`.onTapGesture` / `.onLongPressGesture(pressing:)`）。SwiftUI 手势按深度优先解析：卡片上的 Button（返回/静音/点赞/收藏）天然优先于卡片手势，点控件不会连带暂停，**不需要控件区判定表**（曾用 `PlayerGesturePolicy.isTapOnControl` 几何表排除控件区，因每个新控件都要登记、维护成本高，已删）。
   - **长按 2x ↔ 水平 seek 冲突仲裁 = 「先起者独占本次触摸」**（真机日志实证后定的规则，改手势前勿破坏本条与相邻子条的约束）：拖动先起 → seek 独占（**seekPan .began 起手即置 `isSeekGestureActive`**——判定点勿放首个有效 .changed「水平主导+dx>6」：清屏下带外起点的横滑、斜起手转水平的快滑，都会让长按 0.15s 的 perform 插进空窗闪 2x，2026-11-11 修；卡片 perform 起手前查 `playback.isSeekGestureActive`，拖动中长按被识别也不得起 2x）；长按先起 → 2x 独占（`VM.seek` guard `isFastForwarding`，按住 2x 期间漂移不 seek；`maximumDistance` 放开到 10_000，**不靠位移距离掐 2x**——原 40pt 让按住 2x 的手一漂就掉回 1x）。短按 2x 快速松手会被同时认成长按+单击（误暂停），卡片用 250ms 抑制窗吞掉；seekPan **抬手不补 seek**（防「松手清 2x 后 .ended 的 seek 穿过闸门」的竞态跳变）。**seek 独占的触摸抬手还要开同样的 250ms 吞单击窗**（VM `tapSuppressionDeadline`，2026-11-13 修）：seekPan `cancelsTouchesInView=false` 且纯横滑时系统分页 pan 不 begin，SwiftUI tap 全程存活，不设窗则每次横滑结束误 TAP→暂停，勿删窗。**2x 只能在 perform（按满 0.15s）里起，勿放 pressing(true)**——pressing 在触摸落下瞬间即回调（先于任何位移判定），放那里每次快速滑动（含翻页/清屏后的轻扫）都误触 2x（2026-11-11 修）。
   - 手势几何已无命中带（2026-11-11 全屏化，`PlayerGesturePolicy` 仅剩 scrub 灵敏度纯函数）；进度条 HUD 的视觉坐标仍在 `DramaPlayerView` 的 designFrame（20,744,350），移动进度条时同步 HUD 与相关注释即可，不再有手势几何与它耦合。边界提示由 ViewModel 给出，但触发点不是「停稳末页」——用户拍板 2026-11-14：**末页再往下滑一次（想看下一集但已无资源、翻不出去）才提示「已经到底了」**（`scrollViewWillEndDragging` 里翻页目标超出最后页时经 `onPullBeyondEnd` 回调 → `PlayerFeedViewModel.pulledBeyondEnd()`，一次会话一次；停稳末页本身是正常状态不提示，抖音同行为）。
   - 曾使用 SwiftUI `ScrollView + .scrollTargetBehavior(.paging) + .scrollPosition(id:)`，因与卡片内 `GeometryReader` / 子视图手势 / 尺寸计算冲突导致**完全滑不动**（多轮排障无效），已弃用，勿改回。
3. 播放器采用**单播放器常驻 + 滚动停稳防抖后切 item**（ZFPlayer / 开源抖音实践），禁止每次滑动新建 AVPlayer；暂不引入多 player pool。**播完自动连播（2026-11-14）只走「信号 + 既有停稳管线」，勿另立加载链路**：`DramaPlayerViewModel` 只发播完信号（`.AVPlayerItemDidPlayToEndTime`，object: nil + 回主线程判「事件对象 === currentItem」过滤迟到事件，`onPlaybackEnded` 闭包）→ `PlayerFeedViewModel.playbackDidEnd()` 按 hasNext/slots 算下一集置 `playback.autoAdvanceSort`（@Published）→ `PlayerPagingScrollView` Coordinator 订阅动画翻页（`scrollToSort`）并复位信号 → `scrollViewDidEndScrollingAnimation`→`report` 复用 scrollID→schedulePageSettle→pageSettled（预热池/autoplay 全在里面）；末集播完不跳（停在末帧），下一集未下载照常跳占位页。**片尾停留态不复活（2026-11-14 拍板）**：`togglePlayback` 对「暂停且位于片尾（now ≥ total-0.2）」直接 SKIP 不 seek(0) 重播——末集播完误点一下曾整集从头放；重看走横向 seek 拖离片尾后点按恢复。勿把「算下一集」或「直接 load 下一集」塞进播放 VM——它不持有队列/槽位知识。秒开链路由三件事共同保证，改切集加载行为时需一起评估：`PlaybackPlayerService` 的**相邻集资产预热池**（停稳播当前集时提前 `asset.load(.isPlayable)`（async 岛）完成相邻集 m3u8 拉取解析，`makeItem` 命中即 HIT；**wanted 名单必须含当前集+两侧邻居**——只报邻居会被自己的淘汰逻辑打穿，曾全 MISS；刚离开的集作为邻居重暖是回滑 HIT 保险，勿加「跳过正在播的集」过滤，曾因 playingSort 过滤致回滑必 MISS）+ `DramaPlayerViewModel` 的 **KVO 直挂就绪判定**（status 一变立刻翻转 isReady，4s 看门狗兜底，勿改回轮询）+ **spinner 800ms 延迟显示**（`isLoadingSlow`；阈值依真机实测定——HIT 就绪 642–871ms，300ms 每滑必闪）。
4. 全屏横向拖动 = 相对 scrub（拖动位移/屏宽换算进度，一屏宽≈全片时长），左缘 30pt 起手除外（保留给返回手势）；垂直滑动只切集，不碰进度。清屏下 seek 照常生效且全屏可用，进度条+时间瞬态淡入（`VM.isScrubbing`，松手停留 800ms 淡出；开启清屏闪现 1.5s 作空间参照）；**勿复用 `isSeekGestureActive` 驱动该 UI**——那是非渲染的手势仲裁闸门，两者语义不同（一个管仲裁、一个管显示）。
5. **所有持久化统一走 Service，ViewModel 里不得出现 `UserDefaults.standard` / `FileManager`**：播放器全局开关（静音/清屏/时长 label）走 `PlayerPreferences`，剧集收藏走 `DramaFavorites`（SQLite `drama_favorites` 表，v3 起不再用 UserDefaults），集级行为数据（点赞/收藏/进度）走 `EpisodeActionsStore`（SQLite），快捷站点与启动 tab 走 `QuickLinkStore` / `AppLaunchPreferences`，路由偏好走 `DramaRoutePreferences`，排序偏好走 `DownloadsSortPreferences`，起始页走 `BrowserStartPage`，登录 token 由 `DramaSession` 自行读写（Service 内部允许）。Service 只做读写，不含业务判断。判据：删掉 UI 后这个读写仍然成立。
6. **每一集自己的行为数据（点赞 / 收藏 / 上次播放位置 / 后续要加的字段）一律进 SQLite 的 `episode_actions` 表，不许再散进 UserDefaults**：主键 `(site, drama_id, episode_id)` 与 `drama_episodes` 同一套身份，能 JOIN 出「看到第几集」「哪些集收藏过」这类关系查询。归属由 `MediaIdentity` 表达、由 `EpisodeActionsStore.identity(...)` 一处解析（播放队列、下载列表、删除清理三处共用），解析不到服务端 id 的资源退化进 `local_actions`（路径主键），两张表互不覆盖。表结构变更走 `PRAGMA user_version` 版本迁移，新字段写 v(n)→v(n+1)，别再用「ALTER 报错就忽略」。写入只发生在关键时机（暂停 / 拖完 seek / 切集 / 退出播放页 / 进后台），播放中只攒内存不落库；拖完 seek 的 flush 必须**现读 `player.currentTime()`**（`PlaybackProgressTracker.current()` 现读优先于 1Hz tick 更新的 pending——拖完立即 flush 曾把拖动前旧位置落库，2026-11-14 修），flush 同时把现读值回写 pending（防 deinit 兜底 flush 倒退）。
7. **建表与迁移只有一个入口 `Drama/DramaDatabase.swift`**：`user_version` 是整库一个计数器，两个 Service 各管一段会互相跳过对方的建表，所以 `DramaCache` / `EpisodeActionsStore` 的 `openDB()` 都只调 `DramaDatabase.open()`。补列逐列查 `PRAGMA table_info` 再 ALTER（不靠版本号判断列是否存在）；旧数据搬迁用独立 UserDefaults 标记门控，与 schema 版本解耦。
8. **站点详情接口整包落库，不许只挑字段**：`DramaCache.saveDetail` 把响应体原文存 `drama_cache.api_detail`，另把常用字段提升为列（计数/规格/权限/催更/服务端观看进度）+ 每集元数据进 `drama_episodes` + 推荐剧进 `drama_related`。挑字段等于把没挑的永久丢掉；站点加字段时整包自动留存，只有要按该字段查询/展示才提升为列。采集时机：进页先查详情缓存新鲜度——`detail_fetched_at` 在 15 天内不重抓（用户拍板 2026-11-13，原先每次进页都抓），过期或 ↻ 刷新按钮强制重抓；封面图另有按剧集 id 的本地文件缓存（`DramaCoverCache`，15 天过期、拉取失败保留旧文件），封面/简介以详情接口为准、DOM 兜底。
9. 不为了分层而分层：不硬造协议、不搬 Coordinator/Router、不给三行代码加一层；等一个类型出现第二个变更理由再拆。`struct` 做 Service 可以。
10. 未下载集的占位页保留（如实显示 + 引导下载），但**槽位可用性快照必须在每次停稳时对账磁盘**（`PlaybackQueueService.refreshAvailability()`，VM 在 `pageSettled` 里先对账再取槽位；`PlayerPagingScrollView.refreshCardsIfNeeded` 跟踪槽位可用性指纹，占位→可播要重绘卡片）——曾因开播快照不更新，「播放中下完的集」滑过去永远停在「尚未下载」占位（真机实证）。
11. **App 用 ZStack 保活容器而非系统 TabView**：浏览页（WKWebView）常驻底层可见、其余 tab（下载页 / 设置页）各自以不透明背景盖上去，切 tab 只改可见性——因为 SwiftUI TabView 会藏起非活跃 tab，WKWebView 离屏被 WebKit 挂起/回收图层，切回唤醒阻塞主线程 300ms–1s（真机日志实证）。tab 条目与顺序只在 `Shared/MainTab.swift` 一处定义（新增 tab 改那里），底部 bar 是自定义 `safeAreaInset`，剧集详情 push 时经 `BrowserView` 的 `detailActive` 绑定隐藏。勿改回用 TabView 装 WKWebView。
12. **播放页锁竖屏 + 播放器容器自转全屏**（2026-11-13 重构，对齐 ZFPlayer/SJVideoPlayer rotate 模式，取代早期的卡片横屏 overlay 路线）：Info.plist 仅 Portrait，**系统窗口方向永不翻转**——勿再往卡片/页面加「随系统旋转」类实现（曾致布局振荡、跳变、每 pass 全量重排，相关补丁已全部退役）。竖屏 feed 里横屏片源 letterbox（gravity 统一由 `PlayerPagingScrollView.videoGravity` 设置：横屏片源 fit、竖屏片源 fill，presentationSize 未知按竖屏 fill，**勿随持屏方向切换**——fit↔fill 二值跳变即「中间条突变全屏」的根因）。全屏 = `PlayerFullscreenController` 把可搬运视频子层（`PlayerSurfaceUIView.videoLayer`，view 背板层不能搬）搬进 keyWindow 容器，transform 旋转 ±90°（按重力角跟随设备实际转向，写死单侧会令另一半转向内容上下倒置，见 PlayerOrientationTrigger→VM→PlayerFullscreenController 链）+等比放大连续铺满（退出反向动画）；触发 = `PlayerOrientationTrigger` 姿态判稳（滞后阈值 55°/28° + 0.6s 稳定窗，仅横屏片源 + isReady，无按钮入口）；全屏控制层 `PlayerFullscreenControlsView`（左上返回 icon=退出全屏、点按呼出 3s 收起、Combine 订阅同一个 VM，状态不另立源）。视频由单例容器渲染（`PlayerSurfaceUIView` 挂分页滚动层下、frame 对位活跃卡），卡片视频区透明；返回/静音/清屏等控件已抽成卡片可复用组件。

13. **剧集页加载编排 = SWR（用户拍板 2026-11-13）**：进页先用缓存渲染（零等待），同时后台拉下载接口对账（`DramaPageViewModel.revalidateIfNeeded`）——失败静默保留缓存；成功先做**本地状态归一化**（downloaded/folder 并回 fresh，接口不带本地下载态，不归一化必假 diff），与内存 info 对比，**有 diff 才落库+刷新，无 diff 不写库不重绘**。同一页面实例 60s 内存 TTL 节流。WebView 详情收割不纳入 SWR（整页加载开销大，仍走 15 天闸门 + `coverMissing` 补救），↻ 刷新按钮 = force 强制重收割。别改回「缓存优先永不联网」——陈旧 playable 假拒绝下载就是这么来的。
14. **用 CoreText 量文本（简介两行溢出、行尾胶囊）两条铁律**，违反必静默错判：①**测量绝不能给 paragraphStyle 设 `.byTruncatingTail`**——CoreText 会把整段当**单行**做尾部截断（实测 `lines` 恒为 1、末行 range 覆盖全文），溢出判定永远 false，按钮直接消失；截断是渲染阶段的事，测量只看 `.byWordWrapping` 的自然换行。②**给文本容器算高度时行高要 `ceil`**——CoreText 把行高向上取整（13pt 系统字体 15.31→16），两行需要 `16×2+5=37`，手算 `15.31×2+5≈35.6` 硬编码 36 会少 1pt，SwiftUI 判定第二行放不下、**只画一行**。纵向落位同理，用 `CTFrameGetLineOrigins` 的基线差（13pt+5 行距实测 21）比"行高+行距"手算准。
15. **给「Text + SF Symbol」算固定宽度时，符号宽度必须实测**（`NSImage(systemSymbolName:).withSymbolConfiguration(.init(pointSize:))`，12pt 的 `chevron.up` 是 **14×8**，按 12 估就差 2pt）。宽度少 1–2pt 时 SwiftUI 不会报错，而是把中文**压成竖排**（「收起」→ 收在上、起在下，真机实证）。所有这类自定义容器一律加 `.lineLimit(1)` + `.fixedSize(horizontal: true, vertical: false)`，让宽度只由内容决定，容器宽度仅用于落位。

### 并发与线程（GCD 约定，2026-11-12 全量迁移）

**全代码库已移除 Swift concurrency（async/await / Task / Actor 隔离 / Continuation / AsyncStream），统一 GCD。** 工程锁定 Swift 5 语言模式 + minimal 并发检查（`SWIFT_VERSION = 5.0`），勿再升 Swift 6 / 开严格检查——迁移就是为了消除编译期隔离/Sendable 摩擦。例外仅限「Apple 无同步/非废弃 API 的边界」，保留两处 async 岛（用户拍板）：`WebKitFetcher` 的 `startDownload(using:)`（无 completion 变体）、`PlaybackPlayerService` 的 `asset.load(.isPlayable)`（`loadValuesAsynchronously` 已 deprecated）。岛内只做该 async 调用，完成后回主线程碰状态，勿扩散。

1. **主线程约定**：Manager / ViewModel / Store / WebKitFetcher 的可变状态只在主线程访问；后台回调入口一律 `DispatchQueue.main.async` 回主线程再碰状态。不再用 `@MainActor` 标注（编译器不强制，靠约定 + review）。
2. **死锁规则**：`DispatchSemaphore.wait` 只允许出现在后台工作线程（下载管线 / CLI 冒烟）；**主线程永不 wait**。主线程等异步结果用 RunLoop 让出（smoke）或 completion 回调（App）。
3. **下载核心**（`DownloadEngine`）：工作线程 + 信号量同步网络，管线保持线性（与 Python core 同构）；6 并发切片用 `DispatchGroup` + `NSLock` 收首错；重试退避 `Thread.sleep`。线程账：2 集 × (1 管线 + 6 切片) = 14 条峰值，勿再放大并发。
4. **UI 定时**（toast / spinner / HUD / 停稳防抖）：`DispatchWorkItem` + `asyncAfter`，新事件 cancel 旧 WorkItem；取消语义用**代际令牌**（loadGeneration / settleGeneration）或在飞标记，迟到回调按代际/标记丢弃。
5. **资产加载**：用 `asset.load(.isPlayable/.duration)`（async 岛，见上）；`loadValuesAsynchronously` 已 deprecated，勿用（会报警告）。岛内加载完成后 `DispatchQueue.main.async` 回主线程再碰预热池状态。
6. View 层不用 `.task`：生命周期加载用 `onAppear` / `onChange`，防抖收进 ViewModel（View 不持业务定时器）。

## 诊断日志约定

排查跨层问题（播放页 / 分页 / 数据源）时的硬性要求：

1. **统一前缀** `PLAYER_DBG`，分类标签 `[CHECK]` / `[Entry]` / `[Service]` / `[VM]` / `[Container]` / `[FeedView]` / `[UIScroll]` / `[Playback]`。
2. `[CHECK]` 是断言行，**必须带输入值与判定依据**（如 `expectedY / actualY → OK|FAIL`），拿到日志即可判读，不靠追问。
3. **覆盖整条链路**：入口（点了哪集、request 内容）→ 数据源（全剧集号来自 knownSorts / SQLite / 磁盘兜底）→ 容器（页高、contentSize、每页 frame）→ 起始定位（PENDING 原因 / APPLY / APPLIED）→ 手势判定（delegate 全过程、误触）→ 状态回写（当前集、停稳防抖）→ 播放源（load 成功与每个失败分支）。
4. **失败分支必须有日志**，尤其是提前 `return` 的 guard。「日志里什么都没有」本身就是线索 —— 曾因 `applyStartOffset` 静默跳过导致点任意集都停在第一页，排查了四轮。
5. **降噪**：连续事件（didScroll、seekFraction）按阈值节流；同一原因的 PENDING 只打一次。
6. 排障结束后**保留**这些日志，不要清理；定位问题靠日志，不要靠猜测反复改代码。
7. 取日志：Xcode Console 过滤 `PLAYER_DBG`；真机 `xcrun devicectl device process launch --console --device <id> com.firefish.smartdownloader`。本项目只禁浏览页截图，不禁 build/run/console。
8. **开发即埋日志（用户要求 2026-11-13，能加尽加）**：写新代码 / 改现有代码时，能加日志的点全部顺手加上，不等排障再回头补——入口（触发源 + 关键参数）、分支判定（每个 guard/if 走了哪条、依据什么值）、状态变更（旧值 → 新值）、异步回调（完成 / 取消 / 迟到按代际丢弃）、提前 return 与失败分支。开发期加日志是零成本的，出了问题再补要多轮真机往返；第 5 条降噪只管高频事件节流，不是「少加」的理由。

## 网络与 WAF（重要背景）

- 部分视频资源站点的 CDN/WAF 按 **TLS 指纹**（ClientHello 特征）掐连接，与请求头无关：
  - Mac 网络：python requests / curl 被掐，URLSession、WKWebView 可过
  - iOS 5G 蜂窝网络：CDN 还会按 **SNI 域名**在握手期 RST，URLSession、WKWebView、网页内视频全部失败
- iOS 下载降级链：URLSession → **IP 直连**（域名解析成 IP 直连，不带 SNI，`Host` 头回填原域名，证书由 TrustAll 兜底；成功后该域名进程内 sticky）→ `WebKitFetcher`（WKDownload）。IP 直连已实测解决蜂窝网络下的真机下载失败。
- Python 侧已同步 IP 直连降级（`core/downloader.py` `_ip_direct_fetch`，2026-11-14）：连接层失败（SSLError/ConnectionError/Timeout）时解析 IP 直连 + Host 回填，成功进程级 sticky；TLS 指纹拦截仍无解（Python 无 WebKit 通道），失败消息提示换网。
- **真机上 WKDownload 必须经由附加在视图树里的真实 WKWebView 发起**（浏览页 makeUIView 注册 host）；隐藏 webview 在真机直接 DownloadFailed（Mac 上却可用，勿被 Mac 冒烟误导）。
- 冒烟开关 `SMARTDOWNLOADER_FORCE_WEBKIT=1` 强制走 WebKit 兜底通道验证。

## iOS 工程注意（Xcode 26 folder-sync 格式）

- 站点接口/选集下载逻辑在 `iOS/SmartDownloader/Drama/DramaAPI.swift`（独立文件，勿混入 `Downloads/Downloader.swift`）；
  账号/AES 常量来自随包 symlink `iOS/SmartDownloader/video_auto.py -> 仓库根 video_auto.py`，改常量只改仓库根一处。

- **语言模式锁定 Swift 5**（`SWIFT_VERSION = 5.0` + `SWIFT_STRICT_CONCURRENCY = minimal`，与 project.yml 一致）：全库 GCD 化后勿升 Swift 6 / 开严格并发检查，详见「并发与线程」节。
- 新 Swift 文件放进 `SmartDownloader/` 自动参与编译；资源目录（Media.xcassets）同理。
- **Info.plist 在同步文件夹内**：pbxproj 已用 `PBXFileSystemSynchronizedBuildFileExceptionSet` 排除它，否则与 `INFOPLIST_FILE` 冲突报 "Multiple commands produce Info.plist"。
- App 图标：`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`，AppIcon.appiconset 三个外观槽位（universal/dark/tinted）都要填 filename。
- iOS 26 符号集没有 `compass` SF Symbol（用 `safari.fill`）；`webView.downloadDelegate` 是 macOS-only，iOS 上 delegate 挂在 `WKDownload` 对象上。
- 真机自动冒烟：`xcrun devicectl device process launch --console --device <id> com.firefish.smartdownloader -autoTestDownload "<m3u8URL>"`。

## 文档与提交

- 交接状态（已完成 / 待办 / 进度）见根目录 `HANDOFF.md`；本文档只维护规则与约定。每完成一个任务同步更新 HANDOFF.md。
- 文档中的 Mermaid 图：节点标签用双引号、边标签用 `-->|"label"|` 语法，并在 directive 中配置 `textColor`/`primaryTextColor`/`edgeLabelTextColor`（深色文字）与 `edgeLabelBackground`（白底），否则渲染出错或文字不可见。
- 提交惯例：每个任务完成即 commit，中文 message，`feat`/`fix`/`refactor`/`docs` 前缀；不 push 除非用户要求。
