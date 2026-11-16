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

## 细节文档（按需加载；本文件只保留结论与索引）

| 细节文件 | 内容 | 何时读 |
|---|---|---|
| `docs/agents/domains.md` | 8 域完整文件清单与职责 | 新增/移动文件归域时 |
| `docs/agents/paper-visual.md` | 纸本视觉 16 条全文 | 改任何页面视觉前 |
| `docs/agents/conventions-player.md` | 播放域约定全文（手势铁律等） | 改 player/ 前必读 |
| `docs/agents/conventions-drama-profile.md` | 剧集页/我的页约定全文 | 改 Drama/、Profile/ 前必读 |
| `docs/agents/conventions-browser-downloads.md` | 浏览/下载域约定全文 | 改 Browser/、Downloads/ 前必读 |
| `docs/agents/conventions-data.md` | 数据与工程约定全文 | 改 SQLite/持久化/Service 前必读 |
| `docs/handoff/archive-2026-11.md` | 11-12～11-16 全部条目的排查链历史 | 追溯某个已验证功能的成因时 |

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

8 个功能域：`Shared/`（跨域纯数据+设计系统）· `Drama/` · `Downloads/` · `Browser/` · `Settings/` · `Profile/` · `Infra/` · `player/`；`Components/` 是全局通用 UI；根目录只留 `App.swift` 与 `Info.plist`/`Media.xcassets`（两批迁移已完成，不要再往根目录新增 Swift 文件）。**每个域的完整文件清单、职责与边界 → 详见 `docs/agents/domains.md`（新增文件归域前必读）**。域内五层规则见下。

### 纸本单轨视觉（2026-11-14 起全 App 唯一视觉轨）

浏览/下载/我的/设置/剧集详情五页已全部宣纸底纸本视觉，深色墨本轨只残留播放页。**16 条完整约束（图标画布还原与像素 diff 验收 / 几何常量 / DWColor token 纪律 / 下拉刷新三态 / 海报墨块 / PosterGrid 等）→ 详见 `docs/agents/paper-visual.md`（改任何视觉前必读）**。三条承重规则常驻：

1. **栏底恒为纸**：MainTabBar 无 `forcePaper`/`colorScheme` 双轨；页面色值全是写死的十六进制。不要再加回双轨，也不要在 Scene 层加 `preferredColorScheme(.light)`（会连带变浅播放页等墨本页面）。
2. **纸底统一上提到 App 容器**（App.swift 一次 `.background(DWColor.paper.ignoresSafeArea())`）；各页不要自己 `ignoresSafeArea()` 铺纸底——会连**顶部**安全区一起吃掉，底边溢出到 tab bar 后面。
3. **【承重规则】`safeAreaInset` 的 62pt 不会传下来**：自定义 tab bar 走 App 层 safeAreaInset，系统只把它自带的 34pt 底部安全区算进内容区，栏本身 62pt 实高不传给任何页面。任何带底部内容的全屏页必须显式 `.safeAreaPadding(.bottom, MainTab.barReservedHeight)`（下载/我的/浏览三处已有，新增页面一律先加这句）。

### 布局缩放与机型适配（2026-11-16 成文；缘起：用户对「designFrame 不考虑其他设备」的担忧）

1. **designFrame 的适用边界**：`designFrame(x,y,w,h)`（`Shared/DesignTokens.swift:226`）是设计稿坐标的裸 `.position()` 映射，**只允许出现在「按画布整页对齐」的骨架页**——现状仅 `DramaDetailView`（25 处）与 `DramaPlayerView`（23 处，用户文件）两个文件。**不要再往列表页/设置页/浏览页/我的页加 designFrame**：那些页面是流式布局（List/ScrollView/VStack + 常量 + 容器现算），混入绝对坐标会失去机型自适应。
2. **三套缩放策略，新页面按内容性质对号入座**（不是偏好选择）：
   - **骨架画布页**（整页按画布对齐、内容纵向流可滚动）→ **width-scale**：`scale = geo.size.width / 390`，画布 `scaleEffect(scale, anchor: .topLeading)` + 外层 frame 补真实占位（范本 `DramaDetailView.swift:167-186`，含「scaleEffect 不改布局尺寸」注释）；纵向高度差异由 ScrollView 吸收。
   - **整页设计页**（横纵都按画布整体呈现、不可滚动）→ **min 双轴**：`scale = min(w/390, h/840)`（范本 `DramaPlayerView.swift:93`，用户文件）；小屏整页等比缩小、UI 完整为先。
   - **流式内容**（列表/网格/弹层）→ **容器现算**：`PosterGrid` `.flexible()`、`EpisodeGridMetrics.cell(availableWidth:)`、`GeometryReader` 现量；禁 `UIScreen.main`（既有约定）。
   - 全屏控制层沿用画布单位 × `sx`（`PlayerFullscreenControlsView.M.edge`），与 width-scale 同性质。
3. **机型适配的验收 = 三机型快照，不靠推理**：布局相关改动（designFrame 数值、缩放策略、安全区处理）必须在**小屏（375pt 级，如 iPhone SE 或等效）/ 标准（iPhone 17 Pro 402×874）/ Max（iPhone 17 Pro Max）**三档模拟器各截关键态（详情页顶部+页底、播放页竖屏+全屏、下载页）。已实证安全区差异会咬人（下拉刷新阈值踩过灵动岛坑），这类问题只能跑出来看，模拟器命令见「模拟器视觉验收」节。
4. **布局体系按 surface 归属选择（2026-11-16 二次修订，替代早先「不引入 AutoLayout」的过死表述，与用户讨论后确认）**：
   - **SwiftUI 页面**维持流式（flexible frame / `layout protocol` / size class 是它的对应物）；画布逐像素对齐是产品主张，等比缩放画布正是它在多机型上的实现手段——SwiftUI 页不引约束体系（也没法引）。
   - **UIKit 岛屿的新代码一律用 UIStackView / NSLayoutConstraint**，不再手算 frame 摆放——存量手调的代价已有实证：横屏进度行四连修（`9396af7` 左右留白 → `950de44` 整体左移 → `089a884` 时间贴两端 → `4475b74` 轨道右缘 819→762）+ 被迫引入 `sizeThatFits` 实测宽度回推（「具体约定」12），一次 Stack/约束就能收敛的行式布局手调了四轮。
   - **存量反复手调的行**（横屏进度行这类）：**再回归一次就转约束/Stack**，不继续手调系列——渐进触发，不做全库迁移。
   - 项目级布局体系重构（届时用 SwiftUI size class / layout protocol）的触发条件不变：上 iPad / 支持系统横屏 / Mac Catalyst——任一立项另开专项。
5. **Dynamic Type 与画布对齐的分工**：全库固定字号是画布对齐的一部分，不因多机型适配而整体放开；正文类长文本（错误详情/空态提示/简介）优先支持 `@ScaledMetric`，逐像素对齐的画布指标框除外。已记入审查报告 P1-⑫（`iOS-REVIEW.md`）。

### 具体约定（编号 1–24 供全局引用；**改对应域代码前必读该域细节文件**）

**读取路由**：播放域 1/2/3/4/12/19/23 → `docs/agents/conventions-player.md`；剧集与我的 8/13/14/20/21/22 → `docs/agents/conventions-drama-profile.md`；浏览与下载 16/17/18/24 → `docs/agents/conventions-browser-downloads.md`；数据与工程 5/6/7/9/10/11/15 → `docs/agents/conventions-data.md`。

1. 上下滑资源调度唯一入口是 `PlaybackQueueService` → 详见 `docs/agents/conventions-player.md`
2. 播放页用 UIKit 原生分页 → 详见 `docs/agents/conventions-player.md`
3. 播放器采用单播放器常驻 + 滚动停稳防抖后切 item（ZFPlayer / 开源抖音实践），禁止每次滑动新建 AVPlayer → 详见 `docs/agents/conventions-player.md`
4. 全屏横向拖动 = 相对 scrub（拖动位移/屏宽换算进度，一屏宽≈全片时长），左缘 30pt 起手除外（保留给返回手势） → 详见 `docs/agents/conventions-player.md`
5. 所有持久化统一走 Service，ViewModel 里不得出现 `UserDefaults.standard` / `FileManager` → 详见 `docs/agents/conventions-data.md`
6. 每一集自己的行为数据（点赞 / 收藏 / 进度）一律进 SQLite 的 `episode_actions` 表，不许散进 UserDefaults → 详见 `docs/agents/conventions-data.md`
7. 建表与迁移只有一个入口 `Drama/DramaDatabase.swift` → 详见 `docs/agents/conventions-data.md`
8. 站点详情接口整包落库，不许只挑字段 → 详见 `docs/agents/conventions-drama-profile.md`
9. 不为了分层而分层：不硬造协议、不搬 Coordinator/Router、不给三行代码加一层；等一个类型出现第二个变更理由再拆。 → 详见 `docs/agents/conventions-data.md`
10. 未下载集占位页保留，但槽位可用性快照必须在每次停稳时对账磁盘（`refreshAvailability()`，真机实证） → 详见 `docs/agents/conventions-data.md`
11. App 用 ZStack 保活容器而非系统 TabView → 详见 `docs/agents/conventions-data.md`
12. 播放页锁竖屏 + 播放器容器自转全屏（2026-11-13 重构，勿加「随系统旋转」类实现；gravity 不随持屏方向切换） → 详见 `docs/agents/conventions-player.md`
13. 剧集页加载编排 = SWR（用户拍板 2026-11-13） → 详见 `docs/agents/conventions-drama-profile.md`
14. 用 CoreText 量文本（简介两行溢出、行尾胶囊）两条铁律，违反必静默错判 → 详见 `docs/agents/conventions-drama-profile.md`
15. 给「Text + SF Symbol」算固定宽度时，符号宽度必须实测（12pt 的 `chevron.up` 是 14×8，估宽会把中文压成竖排） → 详见 `docs/agents/conventions-data.md`
16. 广告清理必须连带处理「滚动锁」这个副作用（2026-11-14 用户实报「首页刚开始能滑动，后面滑不动了」） → 详见 `docs/agents/conventions-browser-downloads.md`
17. 浏览页「滚动收起联动」是方案 B（用户 2026-11-14 拍板） → 详见 `docs/agents/conventions-browser-downloads.md`
18. 年龄确认门由 `AgeGateScript` 自动点确认、不删弹窗（浮层 + 年龄词 + 正向按钮三判据同时满足，每页最多 4 次） → 详见 `docs/agents/conventions-browser-downloads.md`
19. 选集面板的集号与状态必须与剧集页选集区一致（集号唯一来源 = 队列槽位 sort，按总集数补齐 1…N） → 详见 `docs/agents/conventions-player.md`
20. 「我的」页四个分类是分页容器，与下载页「下载中/已下载」同一套路（四页数据一次读全） → 详见 `docs/agents/conventions-drama-profile.md`
21. 接口失败必须把错误信息爆出来，不许只留系统那句「未能读取数据，因为它的格式不正确」（2026-11-15 用户要求） → 详见 `docs/agents/conventions-drama-profile.md`
22. 封面「是谁的」只能靠页面证据判（链接排除 → 面积 → alt×3），不许再按「首张大图」猜 → 详见 `docs/agents/conventions-drama-profile.md`
23. 选集格「选中 + 下载」叠加时，边缘环整套换纸白（2026-11-15 用户拍板「下载边缘进度颜色应该是白色的」） → 详见 `docs/agents/conventions-player.md`
24. 同一部剧的同一集只允许有一条记录（2026-11-15 用户实报「下载的里面有两个同名文件，但只有一个可以播」） → 详见 `docs/agents/conventions-browser-downloads.md`

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
- App 图标：`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`。**只有一个 universal 槽位（`sd.png`，1024×1024、无 alpha、无圆角）**，圆角与遮罩全部交给系统；不要再拆 dark/tinted 变体（设计稿只出一版）。
  **成图是「整幅纸」而不是设计稿节点原样**：设计稿 `19:278` 里有墨底 `#14171A` 描边纸面板（r160），直接导出会得到「深角 + 圆角纸面」，套上系统遮罩就是双重圆角。正确做法是把 720² 纸面板整块放大铺满 1024²（k = 1024/720 ≈ 1.4222），笔触、朱砂印、印文全部按同一 k 跟随纸面等比放大——**只放大不改摆位**，印与记号、印与纸边的关系才和设计稿一致。按此规则出的图：印面 836→939，距边 85，方印右下角到遮罩弧心 (795,795) 约 204 < 229，完整不被切。合成工序在 `docs/design/appicon-src/compose_paper_icon.swift`（同目录存三个 scale=2 导出的图层，`swift compose_paper_icon.swift <out.png>` 可逐字节复现 `sd.png`）。
- **品牌资产的唯一来源是设计稿**（Ardot 文件 `746972112461422`）：App Icon = 节点 `19:278 App Icon · 1024×1024`（墨底 `#14171A` + 纸面板 `19:363` r160 + 一笔墨主体 `19:364` + 朱砂小印 `19:367`/印文「观」`19:368`）；品牌符号 = 节点 `19:356 一笔墨 · 品牌符号`。改图先改设计稿，再 `export_nodes`（scale 1 导出即 1024）；`19:363` 只是那块纸面板，单导它是张空白纸。**禁止在代码里重画记号**——曾用脚本自绘了一个「下箭头」图标，与设计稿的一笔墨完全不是一回事，返工一次。
- 启动屏分两层：系统层是 `UILaunchScreen → UIColorName = LaunchBackground`（颜色资源，纸底 `#F2F0EA`）；应用层 `iOS/LaunchSplashView.swift` 在同一纸底上把 `LaunchLogo` 淡入。`LaunchLogo` 由 `19:356` 导出后**只做取景不改图形**（裁到 alpha 包围盒、居中放进 1024 方画布，图形高度占 72%，对齐设计稿 86/120），保留 alpha。**不要退回整屏 PNG 启动图**：固定分辨率铺不满所有机型，边缘会露白。
- App 显示名在 `Info.plist` 的 `CFBundleDisplayName`，改这一个字符串即可，不动工程名/bundle id。当前为 `观影`，与设计稿 `19:359` 应用名、`19:368` 朱砂印文一致。
- 底部 tab bar 是 `App.swift` 里的 `MainTabBar`（独立 View，不是 App 内联）。历史坑仍记着：`colorScheme` 若写在 `App`/Scene 层读到的是初始值（实测深色外观下仍判成 light）——但 2026-11-14 单轨化后 `MainTabBar` 已不读 `colorScheme`，别再把它加回来（见「纸本单轨视觉」第 1 条）。
- iOS 26 符号集没有 `compass` SF Symbol；三个 tab 统一线稿（`safari` / `arrow.down.circle` / `person`），别把浏览换回 `safari.fill`（实心图标与另两个不同重，底部会一头沉）。`webView.downloadDelegate` 是 macOS-only，iOS 上 delegate 挂在 `WKDownload` 对象上。
- 真机自动冒烟：`xcrun devicectl device process launch --console --device <id> com.firefish.smartdownloader -autoTestDownload "<m3u8URL>"`。
- **模拟器换 App 图标不会立刻刷新**：SpringBoard 缓存旧图标，`simctl install` 覆盖装也刷不掉。必须 `simctl uninstall` → `simctl shutdown` → `simctl boot` → 再 `install`，否则主屏截图里看到的还是上一版（曾据此误判成合成出错）。图标本身对不对，直接看构建产物 `SmartDownloader.app/AppIcon60x60@2x.png` 最快。

## 模拟器视觉验收（不碰真机，2026-11-14 建立）

纸本轨对齐画布需要「改一版、截一张、量一次」，真机往返太慢。以下是实测可用的链路与踩过的死路。

**多机型验收（2026-11-16 起，见「布局缩放与机型适配」第 3 条）**：布局相关改动换 `-destination 'platform=iOS Simulator,name=<机型>'` 分别截小屏（375pt 级）/ 标准（iPhone 17 Pro）/ Max 三档；`xcrun simctl list devices available` 现查可用机型名。

**构建**（约 4 分钟）：

```bash
cd iOS && xcodebuild -project SmartDownloader.xcodeproj -scheme SmartDownloader \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DD \
  ONLY_ACTIVE_ARCH=YES build
```

**必须 `dangerouslyDisableSandbox: true`**（代理工具侧）——沙箱里 keychain 访问被拒，直接 `BUILD FAILED`，与代码无关。

**装机与截图**：`xcrun simctl install booted <app>` → `xcrun simctl launch booted com.firefish.smartdownloader` → `xcrun simctl io booted screenshot /tmp/x.png`。模拟器 iPhone 17 Pro（402×874pt，iOS 26.5）。换 App 图标必须 `uninstall → shutdown → boot → install`，SpringBoard 图标缓存刷不掉。

**Debug 专用启动参数**（`simctl` 点不了也滑不了，只能靠参数直接落到目标状态；均 `#if DEBUG` 门控，Release 不编译）：

| 参数 | 作用 |
|---|---|
| `-startDownloadedPage` | 下载页直接落在「已下载」分段 |
| `-startEditMode` | 下载页直接进编辑模式 |
| `-autoTestDownload <URL>` | 启动即自动下载（真机蜂窝链路冒烟） |
| `-perfLog` | Release 启用主线程卡顿探针（Debug 常开） |
| `-dramaPreview` | 直接弹剧集页纸本样张（注入固定 30 集 + 推荐 + 档案，全程不联网） |
| `-dramaPreviewBottom` | 配合上一条：内容直接落到页底，用于看档案区与「滚过海报后的顶栏」 |
| `-refreshPreview pull\|ready\|refreshing\|done` | 下拉刷新定帧：让页面停在某一态供截图（下拉靠手指，模拟器滑不了） |
| `-dramaRingPreview active\|done` | 配合 `-dramaPreview`：选集格「选中 + 下载中(42/100)」/「选中 + 已下载」叠加定帧，验收朱砂底上的纸白进度环 |
| `-refreshAuto` | 启动 2s 后自动跑一遍刷新，验证「刷新 → 已更新 → 收起」会不会自己走回来 |
| `-archiveExpandedPreview` | 剧集页档案区展开定帧（默认折叠；模拟器点不了，用它看展开态高度预算） |
| `-downloadsSeries <剧名>` | 下载页启动即推入该剧详情（模拟器点不了海报卡；验证同集去重后「一集只有一行」） |
| `-playerLocked` | 配合 `-playerPreview -playerFullscreen -playerPinControls`：进全屏后直接置锁定态，只剩解锁钮（看锁定视觉与控件收起） |
| `-playerPaused` | 配合 `-playerPreview [-playerFullscreen]`：进页后立刻暂停，用于截「播放三角」那一态（默认片源在播 = 暂停双竖条） |
| `-playerFreezePreview` | 配合 `-playerPreview -playerFullscreen`：进页 10s 后手动挂一次切集冻帧（6s 看门狗自动放掉）。模拟器切不了集，用它验证冻帧层在全屏容器里铺得对不对：间隔 2s 截两张、`diffimg` 比画面区应 0.000%（挂冻帧）/ 5%+（正常播放） |

**合成鼠标事件进不了 App**（2026-11-14 实测）：`CGEvent` 造的 `leftMouseDown/Dragged/Up` 能被 Simulator 窗口收到位置，但点击、拖拽都不生效——终端侧没有辅助功能授权，事件被系统丢弃。**别指望用它验证手势**；手势类改动只能靠状态定帧参数 + 真机回归。

例：`xcrun simctl launch booted com.firefish.smartdownloader -startDownloadedPage -startEditMode`。

**造「下载中」任务**：本机起一个慢速 HLS 服务器（本地 24 片 × 180KB、每片 sleep 0.25 → 约 22 秒完成），下载页才有真实进度可截。纯静态文件秒完成，抓不到中间态。

**探针通道（重要，两条都走不通）**：

- `simctl launch --console` **拿不到 App 的 `print`**（输出 0 字节）。
- `simctl spawn booted defaults read <bundle>` **读不到 App 写的 `UserDefaults`**（模拟器偏好缓存不落盘，plist 里根本没有新 key）。

所以模拟器排障**唯一可靠通道是屏幕**：临时在界面上压一层 `Text` 显示探针值 → 截图 → 读图；要判几何就从 `simctl io screenshot` 的 PNG 里按列扫颜色找边界（Swift + CoreGraphics 写个小脚本，本机无 PIL）。真机走 `devicectl --console` + `PLAYER_DBG` 日志，不受此限。

## 文档与提交

- 交接状态（已完成 / 待办 / 进度）见根目录 `HANDOFF.md`；本文档只维护规则与约定。每完成一个任务同步更新 HANDOFF.md。
- 文档中的 Mermaid 图：节点标签用双引号、边标签用 `-->|"label"|` 语法，并在 directive 中配置 `textColor`/`primaryTextColor`/`edgeLabelTextColor`（深色文字）与 `edgeLabelBackground`（白底），否则渲染出错或文字不可见。
- 提交惯例：每个任务完成即 commit，中文 message，`feat`/`fix`/`refactor`/`docs` 前缀；不 push 除非用户要求。
