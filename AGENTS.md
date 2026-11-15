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
- `Profile/`：我的域（纸本轨视觉）。`ProfileViewModel`（VM：四分类数据装配——历史/收藏/追更/点赞，口径全在 Service 层的关系查询上）、`ProfileView`（View + 组装：`NavigationStack(path:)` 值驱动路由，`ProfileRoute` 定义二级页）。**顶栏区（身份行 + 分类 tab + 筛选胶囊）用 `safeAreaInset(edge: .top)` 钉住**，封面墙上滑时不动（用户要求：分类与筛选不应随上滑消失）；**底部必须 `.safeAreaPadding(.bottom, MainTab.barReservedHeight + 15)`**：自定义 tab bar 是 App 层 `safeAreaInset` 注入的，**栏本身 62pt 不传进页面**（详见「纸本单轨视觉」第 3 条承重规则），不补的话封面墙最后一行被 bar 盖住（实测 contentInsets.bottom 只有 34 家区、内容区画到 840 而 bar 占 794…840）；补完 contentInsets.bottom = 111（34+62+15）、内容止于 763，与 bar 顶（779）留 15pt 呼吸。`path.isEmpty` 是「是否在二级页」唯一事实来源，经 `detailActive` 绑定让 App 隐藏 tab bar（设置页/剧集页都算）
- `Infra/`：系统能力。`LocalMediaServer`（本地回环 HTTP）、`WebKitFetcher`（WKDownload 兜底）、`AppHaptics`（全 App 触觉反馈唯一入口）、`KeyboardObserver`（键盘显隐唯一入口：弹起时收起自定义 tab bar 与浏览页底部工具条，避免被系统顶到键盘上方）
- `player/`：播放域，五层齐全。Model（`PlaybackModels` / `DramaEpisode`）、Service（`PlaybackQueueService` / `PlayerPreferences` / `PlaybackPlayerService` / `PlayerGesturePolicy` / `PlaybackProgressTracker` 进度落库与续播 / `PlayerOrientationTrigger` CoreMotion 姿态判稳 / `PlayerFullscreenController` 全屏搬运动画）、ViewModel（`DramaPlayerViewModel` / `PlayerFeedViewModel`）、View（`DramaPlayerView` / `PlayerFeedView` / `PlayerPagingScrollView` / `PlayerSurfaceContainer` 单例视频容器 `PlayerSurfaceUIView` / `PlayerFullscreenControlsView` 全屏控制层）、组装根（`DramaPlayerContainer`）
- `Components/`：**全局**通用 UI，不依赖任何业务模块或页面坐标系，命名不带业务前缀（如 `ToastView`，不要 `PlayerToastView`）；位置由调用方决定
- 根目录只留 `App.swift`（入口）与 `Info.plist` / `Media.xcassets`。两批迁移均已完成（2026-11-12），**不要再往根目录新增 Swift 文件**

**域内五层规则**：每个域的 Model 独立文件、纯数据无 IO；VM 不直接读写系统对象；Service 不 import SwiftUI、不用 `@Published`、不反向依赖 VM。新增类型必须归到所属域，不要再往根目录堆。判断有没有落实看三条：Model 是否独立且纯数据、VM 碰不碰系统对象、Service 删掉 UI 后是否仍成立。

**folder-sync**：工程只有一个 `PBXFileSystemSynchronizedRootGroup`（`path = SmartDownloader`），子目录递归自动参与编译，`git mv` 即可，不要改 pbxproj。`Info.plist` 必须留在根（`INFOPLIST_FILE = SmartDownloader/Info.plist`），`iOS/LaunchSplashView.swift` 是显式 `PBXBuildFile`、不在同步文件夹内，勿挪。

### 纸本单轨视觉（2026-11-14 起全 App 唯一视觉轨）

浏览（画布 `22:284`）/ 下载（`2:2` `19:272` `34:1`）/ 我的（`19:63`）/ 设置（`24:43`）/ 剧集详情（`22:163` `30:104`，2026-11-14）**五页都已是宣纸底纸本视觉**，全 App 视觉单轨化完成。深色墨本轨只残留在播放页。

1. **栏底恒为纸**：`MainTabBar` 已删掉 `forcePaper` 参数与 `@Environment(\.colorScheme)` 双轨判定。页面色值全是写死的十六进制，深色外观下照样是宣纸底，「深色外观压墨」只会造成一屏里深浅两截。**不要再加回双轨**，也不要在 Scene 层加 `preferredColorScheme(.light)`（`DramaDetailView` 与播放页会跟着变浅）。
2. **纸底统一上提到 App 容器**（`App.swift`）：`.background(DWColor.paper.ignoresSafeArea())` 只写一次。**各页不要自己 `ignoresSafeArea()` 铺纸底**——那会连**顶部**安全区一起吃掉，页面根视图于是多拿一个状态栏高度、底边溢出到 tab bar 后面（浏览页底部工具条整行被盖，就是这么丢的）。
3. **【承重规则】`safeAreaInset` 的 62pt 不会传下来**：自定义 tab bar 走 App 层 `.safeAreaInset(edge: .bottom)`，系统**只把它自带的 34pt 底部安全区**算进内容区，**栏本身 62pt 的实高不传给任何页面**（也传不进 NavigationStack / 分页 TabView 内的页面）。任何页面的根视图若只依赖系统 safe area，底边恒落在「屏幕高 − 34」（如 874−34 = 840），而 bar 占 778…840 → 底部内容被整行盖住。**必须在页面根视图显式 `.safeAreaPadding(.bottom, MainTab.barReservedHeight)`**（=62）：下载页 `DownloadsView.swift:125`、我的页 `ProfileView.swift:33`（另加 15pt 呼吸）、浏览页 `BrowserView.swift`。新增任何带底部内容的全屏页，一律先加这一句，改 `MainTab.barReservedHeight` 时三处同步。
4. **`PaperGlyphs.swift` 是纸本轨的线稿图元库**：10 个 1pt 线稿 `Shape`（chevron / 锁 / 屏 / 下载徽章 / 重载 / 叉 / 勾 / 铅笔 / 排序 / 加号）替代 SF Symbols。理由是符号的字重、留白、端点全由系统决定，与画布上 1pt 线稿对不上（同一位置换 `Image(systemName:)` 会明显粗一圈、端点带圆角）。**尺寸与线宽照画布节点实读**，不要「看起来差不多」自己定。
5. **几何常量**：`DWLayout.edge = 20`（设置页/我的页）、`DWLayout.pageEdge = 22`（浏览页/下载页，画布左右边距就是 22）、`MainTab.barReservedHeight = 62`（bar 自身 `padding(.top, 10).padding(.bottom, 6)` + 内容 46）。下载页行高 82 / 封面 60×82 r5 / 组内 gap **5**（2026-11-15 用户拍板；画布 19:304 原为 12，`DownloadsView.completedCellSpacing`，行内边距上下各 2.5）、浏览页地址栏行 52（输入框 34，描边 1pt `paperFieldLine.opacity(0.8)`）/ 快捷站点行 44（胶囊 26）/ 底部工具条 54。
6. **纸本轨 token 全在 `DWColor`**：`paper` `#F2F0EA` / `paperInk` `#1C1E1F` / `paperInkSub` `#8C9190` / `paperIcon` `#5A5F60` / `paperCinnabar` `#A05243` / `paperChipSel` `#E2DED5` / `paperChipIdle` `#EAE7DF` / `paperHairline` `#E0DBD1` / `paperDivider` `#DDD9D0` / `paperRule` `#E4E0D6` / `paperLineIdle` `#B9BCB9` / `paperSwitchOff` `#C9CCC9` / `paperKnob` `#F7F5F0` / `paperField` `#E7E4DE` / `paperFieldLine` `#C2BFB8` / `paperCanvas` `#EDEAE2` / `paperTrack` `#C4C7C3` / `paperTrackFill` `#35393B` / `paperFaint` `#A2A6AD`。**新色必须先在画布上量出来再进 `DWColor`**，不要在 View 里写裸 `Color(hex:)`。
7. **列表类页面用 `List` 时必须把系统观感剥干净**：`.listStyle(.plain)` + `scrollContentBackground(.hidden)` + 行 `.listRowBackground(Color.clear)` / `.listRowSeparator(.hidden)` / `.listRowInsets(...)`。**行距只由 `listRowInsets` 的上下值决定**（实测 iOS 26 + `defaultMinListRowHeight 0` 下 List 不追加任何行距：`vertical: 0` 时相邻封面块只隔 0.5pt 描边；旧注释「List 自己又给 12」已证伪）——`paperRow(vertical:)` 默认 6 会得到 12（6+6），相邻行间距要 5 就给各 2.5（见 `completedCellSpacing`）。
8. **画布节点的 width/height 有两种口径，照抄前必须先分清**：**描边图元报的是几何框（不含描边）**，例如 22:329 后退 6.5×13 是中心线尺寸，加 1.2 描边后墨迹约 7.7×14.2；**填充图元报的是墨迹框**，例如 22:332 刷新 12.764×12.8 就是可见范围。两者混用会得到「图标大了 20%」或「描边套描边」。判据：`strokes` 有值且无 `fills` → 几何框；有 `fills` → 墨迹框。
9. **图标类图元照画布原样落地，不做「看起来差不多」的再创作**：`export_nodes(format: "svg")` 拿到精确路径后，**填充形就用 `.fill`、描边形才用 `.stroke`**（22:332 刷新是填充形，早先按 1.2pt 描边圆还原，实机看着像「圈里插了根斜杠」，返工一次）。落地后必须验证：把图元按画布真实几何排成 mock（本地 CoreGraphics 渲染 + `export_nodes` 导出的画布 PNG 垫纸底）做**像素 diff**，红像素只剩抗锯齿边才算过；本项目的验收值是 3 图标 · 110×54pt · 4x 下 **< 0.4%**。**这条链路也是浏览页图标的唯一验收手段**——浏览页禁止截图（见「硬性禁止」），不能靠实机截图对图标。
10. **描边类图标常有光学偏移，别默认居中**：画布把后退/前进各向外偏 0.75（后退中心线 x=6、前进 x=7.5，框心居中会是 6.75）。少这 0.75 与画布 diff 会整条笔画错位。居中只是默认假设，量过再定。
11. **剧集页（`DramaDetailView`）转纸本时只换材质、不动几何**：原文件是按 390 宽设计稿逐节点 `designFrame` 落位的，纸本化只改颜色/字体/卡片材质，**尺寸预算（`DetailLayout` / `PageLayout`）、区块顺序、`descShift` 位移一律不动**（例外：用户点名的布局改造，如 2026-11-15 九项——推荐卡统一 170×226.7 / 档案折叠 / 下载全部右移）。深色轨 → 纸本轨的对应关系：`background`→`paper`、`surface`→`paperChipIdle`/`paperCanvas`、`primary`(#FF5A5F)→`paperCinnabar`、`gold`(#F5C451)→`paperCinnabar`（动作文字）/`paperTrackFill`（进度）、`textBody`→`paperInk`、`textHint`→`paperInkSub` 或 `paperFaint`、`posterTop/Mid/Bottom`(紫渐变)→`paperInkTop/Mid/Bottom`（墨块）。
12. **简介展开/折叠块（`DramaDetailView.swift:398–625`）是用户点名的禁区**：逻辑、几何、CoreText 测量（`introOverflow` / `introLastLineWidth` / `introLastLineDelta` / `introCollapsedHeight`）、胶囊贴行尾的落位规则一律不许动，纸本化时**只改颜色**（正文 `textBody`→`paperInk`、两个动作 `gold`→`paperCinnabar`、胶囊渐隐底 `background`→`paper`，共 4 处）。改别处的配色时要回头确认这 4 处还在。
13. **海报是纸本页里唯一的"墨"**：剧名/标签是白字压在底部 scrim 上，所以无封面时的占位**必须是墨色**（`paperInkPlate` / `paperInkTop…Bottom`），不能顺手改成纸色——纸色会让白字直接消失。同一页的顶栏要跟着换底：海报还盖着顶栏 → 墨色 scrim + 白图标；滚过去 → 纸底 + 0.5 细线 + 墨图标（`onScrollGeometryChange` 判 `contentOffset.y + 96*scale < 376*scale`）。**别把深色轨那层顶部 scrim 直接留在纸面上**，滚到选集以后会是一条灰雾。
14. **下拉刷新沿用画布三态（`30:69`），且指示器不能钉在页面最顶**：墨环 22×22（`trim 0…0.75` + 2pt 圆头）/ 朱砂点 6×6 居中于环心 / 完成态环消失、点收拢成 8×8 / 态标 10px 在下一行；文案 ①`松手即刷新` ②`正在更新剧集…` ③`已更新`。**触发阈值 = 顶部安全区 + 64**（`refreshThreshold`），因为环要整只落在安全区之下 —— 画布样张的「环心 32」照搬到真机正好被灵动岛的黑胶囊吃掉（实测 402 宽机型岛体压到 y46、安全区 59）。同理整组只有在内容被拉够时（`refreshRevealOpacity` 起点 = 安全区+49）才淡入，否则会露出一小截压在岛上的黑弧。**下拉视觉 = 封面原地放大（用户 2026-11-15 拍板）**：内容被手指（或刷新期间的 `holdDown`）推下 d，`coverLayer` 反向平移 `-d` 并 `scaleEffect(1 + d/376, anchor: .top)`，封面顶钉在屏幕顶、底边与随内容下移的标题/标签严格对齐——**不要再改回「纸带」方案**，也不要把封面做成跟随内容整体下移。**锚点必须是 `.top`（横向居中）**：`.topLeading` 只往右下长，视觉上像整张图往右错位（用户 2026-11-15 实机反馈「不是中心放大」）；但纵向**不能**取 `.center`——那会把底边抬到标题上方露出纸底（模拟器像素实测：图标包围盒中心 602.5px vs 页面中心 603px，偏 0.17pt；封面底边 376+d 与标题严格对齐）。顶上不再是宣纸条而是剧照，所以指示器用**白环 + 白字 + 轻阴影**（不是墨色），落在剧照上仍清楚。刷新期间必须 `holdDown` 把内容按住（否则松手封面放大立刻缩回）+ `scrollDisabled`，并留 10s 兜底收尾（滚动是锁着的，请求卡住不能让用户划不动页面）。**不用 `.refreshable`**：系统给的是转圈 spinner，与这套环/点不是一回事。
15. **刷新走「静默」路径**：`vm.refresh(quiet: true, completion:)`。默认 `fetchAndCache` 会把 `loading` 置真，整页当场退回骨架屏，海报与内容全消失、指示器还悬在上头。静默模式下网络失败也不撕页面（有内容只弹 toast）。

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
6. **每一集自己的行为数据（点赞 / 收藏 / 上次播放位置 / 后续要加的字段）一律进 SQLite 的 `episode_actions` 表，不许再散进 UserDefaults**：主键 `(site, drama_id, episode_id)` 与 `drama_episodes` 同一套身份，能 JOIN 出「看到第几集」「哪些集收藏过」这类关系查询。归属由 `MediaIdentity` 表达、由 `EpisodeActionsStore.identity(...)` 一处解析（播放队列、下载列表、删除清理三处共用），解析不到服务端 id 的资源退化进 `local_actions`（路径主键），两张表互不覆盖。表结构变更走 `PRAGMA user_version` 版本迁移，新字段写 v(n)→v(n+1)，别再用「ALTER 报错就忽略」。写入只发生在关键时机（暂停 / 拖完 seek / 切集 / 退出播放页 / 进后台），播放中只攒内存不落库；拖完 seek 的 flush 必须**现读 `player.currentTime()`**（`PlaybackProgressTracker.current()` 现读优先于 1Hz tick 更新的 pending——拖完立即 flush 曾把拖动前旧位置落库，2026-11-14 修），flush 同时把现读值回写 pending（防 deinit 兜底 flush 倒退）。**点赞/收藏只记本地状态，不显示计数**（2026-11-15 用户拍板）：竖屏互动列与横屏底栏都只有图标，勿再按集号编占位数值（`DramaEpisode.likeCount` / `savedCount` / `compactCount` 已删除）——本地片源没有服务端计数，编出来就是假数据。
7. **建表与迁移只有一个入口 `Drama/DramaDatabase.swift`**：`user_version` 是整库一个计数器，两个 Service 各管一段会互相跳过对方的建表，所以 `DramaCache` / `EpisodeActionsStore` 的 `openDB()` 都只调 `DramaDatabase.open()`。补列逐列查 `PRAGMA table_info` 再 ALTER（不靠版本号判断列是否存在）；旧数据搬迁用独立 UserDefaults 标记门控，与 schema 版本解耦。
8. **站点详情接口整包落库，不许只挑字段**：`DramaCache.saveDetail` 把响应体原文存 `drama_cache.api_detail`，另把常用字段提升为列（计数/规格/权限/催更/服务端观看进度）+ 每集元数据进 `drama_episodes` + 推荐剧进 `drama_related`。挑字段等于把没挑的永久丢掉；站点加字段时整包自动留存，只有要按该字段查询/展示才提升为列。采集时机：进页先查详情缓存新鲜度——`detail_fetched_at` 在 15 天内不重抓（用户拍板 2026-11-13，原先每次进页都抓），过期或 ↻ 刷新按钮强制重抓；封面图另有按剧集 id 的本地文件缓存（`DramaCoverCache`，15 天过期、拉取失败保留旧文件），封面/简介以详情接口为准、DOM 兜底。
9. 不为了分层而分层：不硬造协议、不搬 Coordinator/Router、不给三行代码加一层；等一个类型出现第二个变更理由再拆。`struct` 做 Service 可以。
10. 未下载集的占位页保留（如实显示 + 引导下载），但**槽位可用性快照必须在每次停稳时对账磁盘**（`PlaybackQueueService.refreshAvailability()`，VM 在 `pageSettled` 里先对账再取槽位；`PlayerPagingScrollView.refreshCardsIfNeeded` 跟踪槽位可用性指纹，占位→可播要重绘卡片）——曾因开播快照不更新，「播放中下完的集」滑过去永远停在「尚未下载」占位（真机实证）。
11. **App 用 ZStack 保活容器而非系统 TabView**：浏览页（WKWebView）常驻底层可见、其余 tab（下载页 / 设置页）各自以不透明背景盖上去，切 tab 只改可见性——因为 SwiftUI TabView 会藏起非活跃 tab，WKWebView 离屏被 WebKit 挂起/回收图层，切回唤醒阻塞主线程 300ms–1s（真机日志实证）。tab 条目与顺序只在 `Shared/MainTab.swift` 一处定义（新增 tab 改那里），底部 bar 是自定义 `safeAreaInset`，剧集详情 push 时经 `BrowserView` 的 `detailActive` 绑定隐藏。勿改回用 TabView 装 WKWebView。
12. **播放页锁竖屏 + 播放器容器自转全屏**（2026-11-13 重构，对齐 ZFPlayer/SJVideoPlayer rotate 模式，取代早期的卡片横屏 overlay 路线）：Info.plist 仅 Portrait，**系统窗口方向永不翻转**——勿再往卡片/页面加「随系统旋转」类实现（曾致布局振荡、跳变、每 pass 全量重排，相关补丁已全部退役）。竖屏 feed 里横屏片源 letterbox（gravity 统一由 `PlayerPagingScrollView.videoGravity` 设置：横屏片源 fit、竖屏片源 fill，presentationSize 未知按竖屏 fill，**勿随持屏方向切换**——fit↔fill 二值跳变即「中间条突变全屏」的根因）。全屏 = `PlayerFullscreenController` 把可搬运视频子层（`PlayerSurfaceUIView.videoLayer`，view 背板层不能搬）搬进 keyWindow 容器，transform 旋转 ±90°（按重力角跟随设备实际转向，写死单侧会令另一半转向内容上下倒置，见 PlayerOrientationTrigger→VM→PlayerFullscreenController 链）+等比放大连续铺满（退出反向动画）；触发 = `PlayerOrientationTrigger` 姿态判稳（滞后阈值 55°/28° + 0.6s 稳定窗，仅横屏片源 + isReady，无按钮入口）；全屏控制层 `PlayerFullscreenControlsView`（左上返回 icon=退出全屏、点按呼出 3s 收起、Combine 订阅同一个 VM，状态不另立源）。视频由单例容器渲染（`PlayerSurfaceUIView` 挂分页滚动层下、frame 对位活跃卡），卡片视频区透明；返回/静音/清屏等控件已抽成卡片可复用组件。**播放页隐藏状态栏**（`DramaPlayerContainer` 的 `.statusBarHidden(true)`）：App 锁竖屏、横屏靠容器自转，系统状态栏仍按竖屏画在屏幕一侧，不隐藏就会与旋转后的画面叠成「15:46 / 5G / 89% 压在视频上」。**横屏底栏左侧是播放/暂停，不是「下一集」**（2026-11-15 用户拍板）：`barPlayButton` 订阅 `playback.$isPlaying`，与中部 48×48 大按钮同源同拍翻面；「下一集」已移入顶栏「更多」菜单，勿把 ▶| 图标放回底栏（用户实机会把它当播放键点，且它不会翻面）。底栏保持两行：① 播放/暂停 · 当前时间 · 进度条 · 总时长 ② ♥ ★ 倍速 1080P 选集。**播放/暂停图标必须是「一个视图按状态重绘」（`PlayPauseGlyphView(box:)`，中部 48 / 底栏 20），不能用两个视图来回 `isHidden`**——隐显过渡会留一帧「两个都在/两个都不在」，真机上就是「点一下 icon 闪一下」（2026-11-15 用户实报）。同理 `FullscreenGlyphView.glyphScale` 的 `didSet` 有「值未变不重绘」守卫：`layoutSubviews` 被 1Hz 进度 tick 反复触发，没守卫等于每秒强制重绘全部图标。**`isPlaying` 的口径是 `timeControlStatus != .paused`**（`waitingToPlayAtSpecifiedRate` 算在播）：只看 `== .playing` 时弱网每缓冲一次图标就翻一次面，看起来就是「一直在刷」；`togglePlayback` 的 `wasPlaying` 同口径，否则缓冲中点按会再下一次 `play()`、表现为「点不动」。**全屏横屏控制层的左右边距只有一个常量 `M.edge`**（`PlayerFullscreenControlsView.M.edge = 98`，画布单位，真机 = edge×sx，2026-11-15 用户拍板「设为一个常量后续不合适可以自己调节」）：返回 / 亮度 / 点赞 / 底栏播放键的左缘、更多 / 锁定音量 / 选集的右缘、以及进度行「播放键 → 时间 → 轨道 → 时长」整行两端，全部钉在 `X(edge)` 与 `X(844-edge)` 两条竖线上；零碎坐标别再写死，改间距只改这一个数（`moreInkInset` 是「⋮」的墨迹补偿——三枚圆点只有 2.8 宽、居中在 16 宽盒里，盒子要右移 6.6 墨迹才与边距线齐平；锁定/音量的 44 方钮底整盒填充，不需要补）。**进度行右端不能按「轨道右缘 = 常量」写死**：总时长文字宽度随 `00:24` / `1:23:45` 变，轨道右端要按 `sizeThatFits` 实测宽度回推（`X(edgeRight) − 时长宽 − timeGap`），否则换部电影就压字或留空。**全屏进度条配色必须与竖屏同源**（`DramaPlayerView.progressHud`）：未播 `#E8E6DF` @0.30 / 已播 `#E8E6DF` / 当前点朱砂 `#A05243`（旧版横屏是纯白 0.45/0.95 + 白点，色温与竖屏对不上，2026-11-15 用户实报）。顶栏剧名字号 16（画布 13 太小，2026-11-15 用户实报）；点赞/收藏图标 = 画布 18 × `M.actionIconScale`(1.2)。**锁定态（画布 22:31）按行业做法三件事一起锁**：① `PlayerOrientationTrigger` 在全屏中遇到 `isFullscreenLocked` 直接 `resetStability` 并 return——转回竖屏不退出、左右转向不转体（否则躺着看片手一歪就掉回竖屏）；② `gestureRecognizerShouldBegin` 里除 `UITapGestureRecognizer` 外全部 REJECT（不 seek、不起 2x）；③ 点按只 `showTransient` 呼出解锁钮，控件层其余元素（含压暗）alpha 0。改锁定行为时三条要一起评估。**竖屏底部弹层（选集等面板）统一走 `BottomSheet`**（`EpisodePanel.swift`）：贴底高度窗 0↔H + `.clipped()`，出现 = 自底部弹出、消失 = 向底部缩短，内容不参与缩放。**别用 `.transition(.move(edge: .bottom))`**（整体平移）**也别 `.scaleEffect`**（格子会被纵向压扁）；面板本体常驻只切高度，用 `if` 插拔会把展开动画吞掉（插入那一帧高度已是满值）。选集面板高度 = 屏高 × 0.465（原 0.62，2026-11-15 用户要求降 25%）。**倍速也走同一个半屏弹层**（2026-11-15 用户要求「拉起半屏，选项与全屏一致」）：`PlaybackRateSheet` 放同一个 `BottomSheet`、同一高度比例，原先是 300 宽的居中浮层；档位由 `DramaPlayerViewModel.rateOptions` 一处给出（**3.0× 已移除，现五档** 2.0/1.5/1.25/1.0/0.75，全屏抽屉与竖屏弹层同源），文案走 `rateText`——旧实现 `replacingOccurrences(of: "0$")` 是正则写法、匹配不到字面量，面板里全是「2.00倍速」。**选集网格必须「一行排满」**（2026-11-15 用户实报「集全部靠左排布不对」）：`EpisodeGridMetrics.columns = 6`，格宽由 `cell(availableWidth:)` 按弹层实际宽度现算（写死画布 46 会让整片网格缩在左边、右侧空 150pt）；宽度用 `GeometryReader` 现量，**不要 `UIScreen.main`**（iOS 26 起 deprecated，工程要求零警告）。**竖屏时间 label 在进度条上方**（2026-11-15 用户要求）：当前时间 designFrame(20,731) 靠左、总时长 (310,731) 靠右缘 370，跟随 HUD 隐显（原来贴在轨道下方 756，只在拖动时出现）。**竖屏倍速入口清屏态也常驻**（2026-11-15）：清屏下 返回/标题/更多 都还在，唯独倍速曾被藏起来，清屏态就没有倍速入口了。**全屏抽屉打开时点播放区也只关抽屉**（2026-11-15 用户要求）：`handleTap` 先判 `openDrawer` → `dismissDrawer`，不动播放状态；`gestureRecognizerShouldBegin` 在抽屉打开时只放行点按（拖拽/长按照旧拒绝），压暗层与黑底自带 tap，容器手势要在 `shouldReceive` 里放掉它们，否则同一次点击会「关抽屉 + 顺带暂停」。**竖屏静音钮与全屏音量钮共用 `OverlayVolumeGlyph`**（全屏 `showsChip=true`、竖屏默认 false；静音态不变灰，只多一道白斜线），别再用素材 `ic_sound` + 金色斜线。**竖屏右下角只有两枚按钮（2026-11-15 用户拍板）**：静音 `designFrame(318,776,24,24)` + 清屏 `(350,776,24,24)`（清屏占原「画面适配」的画布位，右缘仍是 374；静音由 286 右移到 318，向清屏靠拢、间距 32）。**清屏图标 = 原「画面适配」那枚 `OverlayFitGlyph`**（描边方 + 两枚角标，用户原话「画面适配的 icon 就是新的清屏 icon」），清屏中整枚转金、不再画 45° 斜线；`VM.cycleVideoGravity()` / `videoFitMode` 仍在（gravity 仍按片源方向自动定），但没有手动入口，别又把「画面适配」按钮加回右下角。**选集胶囊宽度由按钮位推导、不再写死**：`episodePillWidth = muteSlotX − 12 − 16`（用户要求「选集自动变长」，现为 290），按钮再动胶囊自动跟随；注意**内层 `.frame(width:)` 必须与调用方 `designFrame` 同源**——只改外层会让胶囊缩在框里（2026-11-15 实测踩到）。**竖屏顶栏标题与全屏同一条文案**「剧集名 + 第n集」（两个空格分隔、第n集不空格，`topTitle` 与 `PlayerFullscreenControlsView.updateTitle` 逐字一致），宽 220 截断，别再退回只显示「第 n 集」。**切集不许黑闪：全屏走冻帧、竖屏走渐变（2026-11-15）**：`replaceCurrentItem` 会让 AVPlayerLayer 立刻丢画面，竖屏有卡片加载渐变兜底，全屏没有 → 那一刻直接露容器黑底（用户实报「全屏选集切集闪一下」）。`PlaybackFreezeFrame` 在 `VM.load()` 置 `isReady=false` **之前**从 `AVPlayerItemVideoOutput` 同步取当前显示帧（已解码帧，~1-5ms）→ `PlayerSurfaceUIView.holdFreezeFrame` 盖在 `videoLayer` 的子层（随视频层搬进全屏容器/跟着旋转缩放）→ ready 后 0.15s 淡出；全屏的 `concealForReveal` **不再把 videoLayer.opacity 置 0**（那正是黑闪本身），无冻帧时直接跳过 conceal。冻帧层尺寸靠 `VideoPlayerLayer.layoutSublayers` 跟随（iOS 没有 `CALayer.autoresizingMask`，那是 macOS-only），6s 看门狗与「加载失败/无资源」分支都会放掉它。**全屏清屏态第一次点按只呼出控件、不暂停**（2026-11-15 用户拍板）：`handleTap` 先用 `controls.isChromeVisible`（与 `updateVisibility` 同一口径）判控件是否真的画在屏幕上——收起态（3s 自动隐藏之后）点一下只 `showTransient()`，否则「想调出控件」会把正看的片子停掉；控件已在才走 `togglePlayback()`。落点判定另有一条铁律：**触摸起点在 UIControl 上的不交给容器手势**（`gestureRecognizer(_:shouldReceive:)` 沿 superview 链找 `UIControl`，命中就 REJECT），否则点「更多/锁/倍速」会连带触发容器 tap；压暗层与空白区照常落给容器手势（所以只排除 UIControl，不要用「在 controls 内就拒绝」——那会把上下留暗带的点按也废掉）。

13. **剧集页加载编排 = SWR（用户拍板 2026-11-13）**：进页先用缓存渲染（零等待），同时后台拉下载接口对账（`DramaPageViewModel.revalidateIfNeeded`）——失败静默保留缓存；成功先做**本地状态归一化**（downloaded/folder 并回 fresh，接口不带本地下载态，不归一化必假 diff），与内存 info 对比，**有 diff 才落库+刷新，无 diff 不写库不重绘**。同一页面实例 60s 内存 TTL 节流。WebView 详情收割不纳入 SWR（整页加载开销大，仍走 15 天闸门 + `coverMissing` 补救），↻ 刷新按钮 = force 强制重收割。别改回「缓存优先永不联网」——陈旧 playable 假拒绝下载就是这么来的。
14. **用 CoreText 量文本（简介两行溢出、行尾胶囊）两条铁律**，违反必静默错判：①**测量绝不能给 paragraphStyle 设 `.byTruncatingTail`**——CoreText 会把整段当**单行**做尾部截断（实测 `lines` 恒为 1、末行 range 覆盖全文），溢出判定永远 false，按钮直接消失；截断是渲染阶段的事，测量只看 `.byWordWrapping` 的自然换行。②**给文本容器算高度时行高要 `ceil`**——CoreText 把行高向上取整（13pt 系统字体 15.31→16），两行需要 `16×2+5=37`，手算 `15.31×2+5≈35.6` 硬编码 36 会少 1pt，SwiftUI 判定第二行放不下、**只画一行**。纵向落位同理，用 `CTFrameGetLineOrigins` 的基线差（13pt+5 行距实测 21）比"行高+行距"手算准。
15. **给「Text + SF Symbol」算固定宽度时，符号宽度必须实测**（`NSImage(systemSymbolName:).withSymbolConfiguration(.init(pointSize:))`，12pt 的 `chevron.up` 是 **14×8**，按 12 估就差 2pt）。宽度少 1–2pt 时 SwiftUI 不会报错，而是把中文**压成竖排**（「收起」→ 收在上、起在下，真机实证）。所有这类自定义容器一律加 `.lineLimit(1)` + `.fixedSize(horizontal: true, vertical: false)`，让宽度只由内容决定，容器宽度仅用于落位。
16. **广告清理必须连带处理「滚动锁」这个副作用**（2026-11-14 用户实报「首页刚开始能滑动，后面滑不动了」）：站点弹窗的标准玩法是出现时给 `html/body` 加 `overflow:hidden` 或 `body{position:fixed;top:-scrollY}`，靠用户点它自己的关闭按钮才还原。我们把弹窗删掉/藏掉之后，站点的还原回调永远不会执行 → 页面从此**永久**滑不动。所以 `AdCleanerScript` 的每条处理路径（选择器直删 / 全屏空浮层隐藏 / 全屏空浮层删除 / 定时全量扫描删除）都要顺手调 `unlockScroll(reason, depth, forcePos)`：复位 `html/body` 的 `overflow-y`、`touch-action`、`body.position`，并按 `-top` 把页面滚回原位；复核 320ms / 1400ms 两轮即停（`depth` 上限 2——复核自己命中 fixes 会再排复核，不设上限就是永不停的长跑定时器）。**保守边界别删**：`body.position:fixed` 只在「负 top / 同时命中 overflow 锁 / 探针明确判卡」时才复位，否则会把「body 常设 fixed + 内层滚动」的 SPA 掰成双滚动。**空浮层启发式必须先判内容、且隐藏后仍要复查**（2026-11-15 用户实报「首页一直有个遮罩，刷新会突然出现网页」）：站点年龄确认弹窗（`role=dialog` 全屏 fixed）被旧实现首见无条件 `visibility:hidden`，而复查入口又先判 `visibility === 'hidden'` 就 return，永远走不到 restore/删除 → 弹窗消失、身后那张全屏年龄门背景图成了「整页遮罩」，用户既看不到确认按钮也点不了。规则：① 首见先 `hasRealContent`，登录框/年龄确认/公告等真实弹窗 `kept` 放过；② 只有确认是空层才隐藏，且**隐藏后的复查不能被 visibility 守卫挡住**（用 `data-dwhidden` 区分「站点自己藏的」与「我们藏的」）；③ 真实内容只算**看得见的**文字/图片（`visibleWithin` + 文本节点遍历；`innerText` 在 `visibility:hidden` 下可能为空，不能用来判恢复）；且 `visibility` 会继承，量之前必须**同步摘掉我们加在根节点上的隐藏**再量（同一段 JS 内完成、不会绘制），否则里面全是 hidden、永远判空，水合进来的弹窗会被当空层误删（本地合成页实测）；④ 删广告节点后要 `checkEnclosingLayers` 复查祖先全屏背板，否则会留下一层暗色遮罩；⑤ 隐藏空层时先**不**解滚动锁，等确认删除再解（避免把站点合法的年龄门滚动锁掰掉）。诊断探针**排障结束后保留**：`scrollLocked`/`scrollUnlocked` 只在锁状态翻转时打一条；`scrollStuck` 判据是「拖了 >20px、抬手 300ms 后祖先链各滚动容器（含 `document.scrollingElement`）的 `scrollTop` 全没动、且不在顶/底边界」，打 `dy= hit= chain= [lockState]`（`hit=` 是 `elementFromPoint` 命中的元素，专门用来识别「没锁却滑不动 = 透明浮层吃掉触摸」），并且**只在确实处于锁状态时才动手解**——虚拟滚动（transform 位移、`scrollTop` 不变）也会被判成 stuck，绝不能去改它的样式。

17. **浏览页「滚动收起联动」是方案 B（用户 2026-11-14 拍板）**：竖屏里地址栏 52 + 快捷站点 44 + 工具条 54 + tab bar 62 共 212pt，网页只剩 569pt。规则：网页**下滑**收起顶部两行 + 底部工具条（省 150pt，实测网页 `innerHeight` 566 → 716），**上滑 / 回到顶部 / 换页 / 聚焦地址栏 / 键盘弹起**一律展开；
   - **方向必须由页面侧上报**（`ScrollCollapseScript`：捕获阶段 `scroll`、每个滚动容器各记位移、单次 ≥12px 且 120ms 节流、只上报方向 + top + doc/inner）。**不要改用 `webView.scrollView.contentOffset`**——SPA 的视频站正文在内部容器里滚，拖拽根本不动 `webView.scrollView`（与 KeyboardDismissScript 同一个坑，真机实证）。
   - **状态机在 `ScrollCollapsePolicy`（纯函数）**，View 只落视觉状态；`top <= 8` 一律展开（换页/锚点之后必须有地址栏）。
   - **顶部两行用「固定高度 + clipped」收起，不能用 `if` 插拔**：`if` 会连 TextField 一起销毁重建，正在输入的地址会被打断。高度常量 `BrowserView.topChromeHeight = 52 + 44`，改画布几何时与 `addressRow` / `quickLinkRow` 的 frame 一起改。
   - **收起/展开后 0.35s 静默窗**（`chromeQuietUntil`）：栏位高度变化会让 WebKit 重排并吐回一条 scroll 事件，不压住会和这次收起对着干（连点式抽动）。
   - **键盘弹着 / 地址栏聚焦时不收**（收走地址栏会打断输入）。
   - **底部工具条在嗅到可下载视频时钉住**（`foundURLs` 非空；该列表是会话级、换页不清空，所以本会话嗅到过 m3u8 后工具条就不再收起——刻意为之，「下载视频 (n)」是可用操作）。
   - **验收不能靠浏览页截图**（硬性禁止）：用本地 HTTP 起一个可程序化滚动的页面 + `simctl launch --console-pty` 收 `BROWSER: chrome collapsed=...` 与页面自报的 `innerHeight` 判读；单次 `scrollTo` 只有 1 个 scroll 事件，会被脚本「首见只记位置」吞掉，必须用连续小步滚动模拟手指，否则测不出收起。
18. **年龄确认门（age gate）由 `AgeGateScript` 自动点确认，不删弹窗**（2026-11-15 用户拍板「用脚本点击」）：站点年龄门是**合法弹窗**，删掉会连带丢站点状态（`html.age-ok`、`localStorage` 标记），只能像用户那样点一下「已满18岁 继续观看」正式放行。判据必须同时满足三条，缺一不可：① **是浮层**——`role=dialog/alertdialog` 或 `<dialog open>`（面积 ≥240×120），或**近全屏**（≥90% 宽、≥80% 高）且自身/祖先 `fixed|absolute`；② 浮层文字含年龄词（`18` 必须独立成数，避免 1180/2018 误命中；或 `十八/周岁/成年/年龄/adult`）；③ 浮层里有**正向确认按钮**（`已满18岁/我已满18/已成年/继续观看/进入/同意` 等），含 `未满/未成年/成年后见/好可惜/离开/退出/不同意/暂不` 的一律排除。**没有 dialog 语义的全屏层只接受 score 3（明确说「我成年了」）的按钮**——SPA 首页整块内容也是全屏 absolute，页面上随便一个「继续观看」被点掉就是真故障（本地合成页 `weak-pagebtn` 用例守着这条）。点击先走 `el.click()`，1.1s 后浮层还在才换完整指针事件序列重试，**每页最多 4 次**，之后 `gaveUp` 停手，绝不进死循环。日志经 `ageGate` handler 回传（`BROWSER: ageGate scan/clicked/confirmed/stillVisible/gaveUp`），`scan` 只在判据结果变化时打一条。**别把年龄门加进 `AdCleanerScript` 的删除词表**，也别用 `localStorage` 猜站点标记（键名站点各异，点击才是通用解）。

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
| `-refreshAuto` | 启动 2s 后自动跑一遍刷新，验证「刷新 → 已更新 → 收起」会不会自己走回来 |
| `-archiveExpandedPreview` | 剧集页档案区展开定帧（默认折叠；模拟器点不了，用它看展开态高度预算） |
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
