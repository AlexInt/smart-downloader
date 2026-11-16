# 04 · 设置域 / 全局组件 / Shared / 工程横切面 审查

审查范围：`iOS/SmartDownloader/Settings/` 全部（5 文件）、`Components/`（2 文件）、`Shared/`（7 文件）、`iOS/LaunchSplashView.swift`、`iOS/SmartDownloader.xcodeproj/project.pbxproj`、`iOS/SmartDownloader/Info.plist`、`iOS/smoke/`（源码级概览）。判据 = 根目录 AGENTS.md（iOS 架构约定、域内五层规则、纸本单轨视觉、具体约定、并发与线程）。只读审查，未改动任何源码。

## 小结

**P0 = 0，P1 = 1，P2 = 9。** 设置域、Shared 层、全局组件的纪律执行质量高：偏好 Service 模式统一（全库 `UserDefaults.standard` 仅出现在 4 个 Service 文件）、恢复默认按 AGENTS 收口在 VM 一处、PosterGrid 三处共用且零业务依赖、MainTab 单一来源完整执行、pbxproj 与 AGENTS 记录逐项一致。唯一的 P1 是 **player 域 30 处裸 hex 颜色违反 DWColor token 纪律**（AGENTS 纸本单轨视觉第 6 条），且已发生一处实证色值漂移（全屏选集描边 #A04D42 vs token #A05142），证明这条债已经开始产生真实成本。

---

## P0

无。

## P1

### P1-1 裸 hex 颜色违反 token 纪律（player 域 30 处），并已实证一处色值漂移

**位置与证据**（一级：一手代码）：

- `iOS/SmartDownloader/player/FullscreenDrawers.swift` **17 处** `UIColor(hex:)`：133、134、179、241、274、462、466、469、473、479、480、482、483、492、496、500、513。摘录（133-134）：
  ```swift
  backgroundColor = UIColor(hex: "#1C1E1F")
  selectedRow.backgroundColor = UIColor(hex: "#35393B")
  ```
- `iOS/SmartDownloader/player/PlayerFullscreenControlsView.swift` **8 处**：235、237、240、334、340、887、1033、1034；且 **27-36 行定义了全库第二个 hex 解析器**：
  ```swift
  /// 全屏容器本地坐标的 UIColor 便捷初始化（与 Shared/DesignTokens 同色值口径）
  extension UIColor { convenience init(hex: String) { … } }
  ```
- `iOS/SmartDownloader/player/PlayerFullscreenController.swift` **2 处**：539（`#0B0C0E`）、734（`#1C1E1F`）。
- `iOS/LaunchSplashView.swift:48`：`.foregroundStyle(Color(hex: "#C4C7C3"))` —— `DWColor.paperTrack`（DesignTokens.swift:100）与 `DWColor.overlayInkSub`（:124）都是 `#C4C7C3`，token 已存在。
- `iOS/SmartDownloader/player/DramaPlayerView.swift:242-243`：`Color(hex: "#0F1212")` 两处（**用户文件**，改前需知会用户）。

**token 重复对照**：裸值与既有 DWColor token 同值约 24 处 —— `#1C1E1F`=`ratePanel`/`paperInk`、`#35393B`=`rateRowSelected`/`paperTrackFill`、`#F2F0EA`=`rateTextSelected`/`paper`、`#E8E6DF`=`overlayInk`/`rateText`/`overlayTrack`、`#A05243`=`overlayCinnabar`/`paperCinnabar`（5 处）、`#C4C7C3`=`overlayInkSub`/`paperTrack`（6 处）、`#8C9190`=`overlayButton`（2 处）、`#2A2422`=`episodeCellCurrent`、`#25282B`=`episodeCell`、`#101214`=`episodePanel`。

**漂移实证**（这条债已产生真实后果）：
```swift
// FullscreenDrawers.swift:466
? UIColor(hex: "#A04D42").withAlphaComponent(0.5).cgColor
// Shared/DesignTokens.swift:147
static let episodeCellStroke  = Color(hex: "#A05142")
```
同一语义「选集格当前集描边」出现两个值；AGENTS 具体约定第 22 条记录的画布值是 `#A05142`。差异 4/255 肉眼难辨，但竖屏弹层与全屏抽屉两套实现已经各画各的。

**违反约定**：AGENTS「纸本单轨视觉」第 6 条——「新色必须先在画布上量出来再进 DWColor，不要在 View 里写裸 Color(hex:)」。

**影响**：改 token 不会传播到全屏控制层；新色没有 token 化关卡，色值对不上画布时排查成本高；两个 hex 解析器（SwiftUI `Color` 版在 Shared、UIKit `UIColor` 版在 player）分叉维护。

**建议**：① 全屏控制层三文件改引 DWColor（`UIColor(DWColor.xxx)` 即可，无需新解析器），删除 PlayerFullscreenControlsView:27-36 的第二解析器；② `#A04D42` 对齐回 token `#A05142`；③ LaunchSplashView:48 换 `DWColor.paperTrack`；④ DramaPlayerView 两处属用户文件，列出待用户定夺。无 token 的新色（`#0B0C0E`、`#0F1212`）先回画布量值再进 token。

---

## P2

### P2-1 SettingsView 私有复制 PaperGlyphs 三个图元，同一个「勾」两处维护

**位置**：`Settings/SettingsView.swift:368`（ChevronShape）、:388（CheckShape）、:399（PlusShape）vs `Shared/PaperGlyphs.swift:20`（PaperChevronShape）、:170（PaperCheckShape）、:213（PaperPlusShape）。

**证据**：`CheckShape` 与 `PaperCheckShape` 的三段坐标逐字相同（`0.08/0.55`、`0.38/maxY-0.06`、`maxX-0.04/minY+0.06`）；Chevron/Plus 同理。而 `Components/PosterGrid.swift:135` 的勾选圈用的是**库版** `PaperCheckShape`——同一个语义图元，PosterGrid 走库、SettingsView 走私有副本。

**违反**：AGENTS「纸本单轨视觉」第 4 条（PaperGlyphs 是纸本轨线稿图元库）与 Components/Shared 单一来源精神。图元几何修一处漏两处。

**建议**：SettingsView 改用库版三图元后删除私有副本（`pointsLeft` 参数语义一致，替换零风险）。

**附（同维度 API 观察 ）**：PaperGlyphs 内部归一化口径混用——lock/screen/badge 用 12/14 栅格归一化（`k = rect.width/12`）、reload 用 20 栅格且 sx/sy 独立、chevron/check/x/pencil/sort/plus 用 rect 比例坐标。行为都正确（均随 rect 等比缩放），但文件头「内部坐标按 12×12 / 14×14 这类原始栅格归一化」只描述了一半图元，新图元落地时容易拿错参照；建议头部注释补一句两种口径的判别。

### P2-2 「恢复默认」后默认圈落「显式无默认」态，与出厂「从未配置」态行为不一致

**位置**：`Settings/SettingsViewModel.swift:118`（restoreDefaults）→ :60（refreshEffectiveDefault）→ `Shared/../Settings/QuickLinkStore.swift:40-66`（hasConfiguredDefault / defaultLinkID / resolvedDefaultID）。

**证据**：QuickLinkStore.swift:47-53 的设计是三种状态分离——key 不存在 = 从没点过（自动选第一项）、key 存在但空串 = 显式取消（回落「恢复上次访问页」）。restoreDefaults 走 refreshEffectiveDefault 后，`defaultLinkID` 被写成空串（setter :57-66 对 nil 写 `""` 而非 `removeObject`），`hasConfiguredDefault` 恒为 true，`resolvedDefaultID` 返回 nil。于是：**首次安装**（key 不存在）自动选中第一项；**恢复默认后**却是「显式无默认」——同为「默认设置」两种行为。

**影响**：无数据丢失，但「恢复默认」对默认圈这一项没有真正回到出厂口径；用户感知为「恢复后浏览页起始行为变了」。

**建议**：给 QuickLinkStore 加 `resetDefaultID()`（`removeObject(forKey:)`），restoreDefaults 调用之，回到「从未配置」态；或注释里写明恢复后保持「显式无默认」是刻意行为。

### P2-3 PosterGrid 本地封面在 body 内主线程同步解码

**位置**：`Components/PosterGrid.swift:126`：`if let image = UIImage(contentsOfFile: url.path) {`。

**影响**：LazyVGrid 滚动中每张卡首次出现时同步读盘 + 解码（`UIImage(contentsOfFile:)` 不会命中任何缓存，body 每次重算——如编辑模式进出、VM 进度刷新——都重新解码）。下载页/我的页三列墙卡片多时是可感知的滚动开销。

**建议**：封面解码上提到调用方 VM（`PosterCardModel.cover` 直接带解码好的 `UIImage`，与「我的」页 `seriesCovers` 后台解析的既有做法一致），或组件内做内存缓存 + 异步加载。

### P2-4 版本号双源：Info.plist 硬编码，pbxproj 变量形同虚设

**位置**：`iOS/SmartDownloader/Info.plist`（`CFBundleShortVersionString` = `1.0.0`、`CFBundleVersion` = `1`，均硬编码）；`project.pbxproj:267/274、287/294` 定义 `CURRENT_PROJECT_VERSION = 1` / `MARKETING_VERSION = 1.0`，且 `GENERATE_INFOPLIST_FILE = NO`（:268/288）意味着这两个变量不会注入。设置页版本脚注（SettingsView.swift:225 起，读 `CFBundleShortVersionString`）显示的是 Info.plist 硬编码值。

**影响**：升版本时改 pbxproj 无效、必须改 Info.plist——双源必漂移。

**建议**：Info.plist 改为 `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`。

### P2-5 无 XCTest target，一批核心行为零自动回归

**位置**：`project.pbxproj` 全文仅 1 个 app target；`iOS/smoke/` 5 个工具均为手动 CLI（coretest/playtest/videocli/fetchtest/dumpdrama）。

**无冒烟覆盖的核心行为**：AES 解密管线（coretest 默认 Apple bipbop 流不加密，只有 videocli 取真实站点直链时才间接覆盖）；Swift 侧 IP 直连降级（`Downloader.swift` 的蜂窝降级链）；`EpisodeActionsStore`（SQLite 行为表，smoke 只测了 DramaCache）；`pruneSupersededAttempts` 同集去重（见 P2-6）；`PlayerGesturePolicy` 纯函数（冒烟工具够不着 UI）。

**建议**：smoke 已证明 `Downloader.swift` 依赖链可在 macOS `swiftc` 编译——将其升级为 `swift test`（Package.swift 包一层），把现有断言搬进去，新增上述缺口的最小用例。

### P2-6 AGENTS 第 24 条声称的去重冒烟在 iOS/smoke 现有源码中不存在，验收不可复现

**位置**：AGENTS「具体约定」第 24 条：「`iOS/smoke` 式独立冒烟……已覆盖『同集双目录只列一条 / 播放目录与列表一致 / 重试摘旧 / 落盘后只留一条 / 散装不去重』」。现有 `iOS/smoke/main.swift` 的 `--library` 分支（runLibraryCheck）只有：残缺集排除、散装收编（`第03集(1)` 后缀）、DramaCache round-trip 与集数合并——**五个去重断言一个都没有**。`iOS/smoke/out/library_check_v2…v10` 产物目录（含 `第03集(1)`、`drama_cache.sqlite3`）说明跑过 10 轮，但产物被 `.gitignore:49` 忽略、源码不在仓库 → 当时那个冒烟已不可复现。

**影响**：AGENTS 记录与代码现状脱节；下次动 `DownloadManager.pruneSupersededAttempts` / `preferredEpisodeFolder` 时没有可跑的回归。

**建议**：把去重冒烟固化为 `iOS/smoke/deduptest.swift`（或并入 main.swift `--library`），AGENTS 该条目引用具体文件名。

### P2-7 偏好 Service 形态不一致：DramaRoutePreferences 是 final class，其余均为 struct

**位置**：`Settings/DramaRoutePreferences.swift:13`（`final class`）vs `AppLaunchPreferences.swift:9`、`QuickLinkStore.swift:9`、`player/PlayerPreferences.swift:6`（均 `struct`）。三者内部结构完全同构（defaults 注入 + 私有 key 常量 + 计算属性读写）。

**影响**：无功能差异（class 无引用语义需求，无状态共享），纯模式噪音。

**建议**：统一为 struct。

### P2-8 ToastView 的 `.toast()` 便捷修饰符是死代码；组件色值未走 token

**位置**：`Components/ToastView.swift:25-32` 的 `extension View { func toast(...) }` 全库零调用（实际使用点 `DramaDetailView.swift:276`、`DramaPlayerView.swift:344` 都直接 `ToastView(message:)`）；:11-12 用裸 `.white` / `.black.opacity(0.72)`（浮层色无画布 token，尚可接受，但与第 6 条精神不符且无注释说明）。

**建议**：删掉 `.toast()` 或让两个调用方迁移后删；给裸色加一行「无 token 依据（跨页浮层）」注释。

### P2-9 QuickLinkStore.load() 解码失败静默回落内置默认

**位置**：`Settings/QuickLinkStore.swift:18-25`：`guard let data = …, let links = try? JSONDecoder().decode([QuickLink].self, from: data) else { return Self.defaultLinks }`。

**影响**：`QuickLink` schema 演进（改字段名/改类型）时，老用户配置的全部站点会静默变回内置 🍎，且无任何日志（违反 AGENTS「诊断日志约定」第 4 条「失败分支必须有日志」的精神——持久化解码失败属静默 return）。

**建议**：解码失败分支打一条日志（携带 decodingError），必要时按版本迁移。

---

## 做得好的

1. **偏好 Service 纪律执行彻底**：全库 `UserDefaults.standard` 仅出现在 4 个 Service 文件（Settings/AppLaunchPreferences、Browser/BrowserStartPage、Drama/DramaDatabase、Drama/DramaAPI），SettingsViewModel/SettingsView 零直接读写；「恢复默认」收口在 `SettingsViewModel.restoreDefaults`（:118）一处，三项一起回默认 + `confirmationDialog` 确认，与 AGENTS 设置域节逐条对应。
2. **QuickLinkStore 三态建模到位**（key 不存在 / 空串 / 合法 UUID）+ `resolvedDefaultID`/`defaultURL` 纯函数解析：「显式取消」不被误判成「从未配置」，删条目自动降级，注释写明上一版 `removeObject` 的坑；「从未配置」与「删空」靠 `data(forKey:)` nil 区分，删空不会长回默认项。
3. **PosterGrid 职责边界干净**：只 import SwiftUI + 设计系统，`selection: Bool?` 纯视觉入参，三处调用点（`DramaDetailView.swift:1423` 用 `DetailLayout.recoColumnWidth` 钉 170 宽、`ProfileView.swift:263`、`DownloadsView.swift:366`）全部由调用方包 Button/NavigationLink，点击/导航/删除零进入组件；列宽按容器现算、无 `UIScreen.main`；`compact` 三列只降字号不改行盒高度，网格行对齐的约束被显式保住。
4. **MainTab 单一来源完整执行**：条目/顺序/标题/图标/`barReservedHeight` 全在 `Shared/MainTab.swift`（且该文件不 import SwiftUI，符合 Model 约束）；`App.swift` MainTabBar（:265 `Image(systemName: tab.icon)`）与设置页 LaunchTabPicker 都遍历 `allCases`；全库 grep 无第二处 tab 图标硬编码（`DownloadsView.swift:34`、`DramaPlayerView.swift:644` 的 `arrow.down.circle` 是各自场景的下载符号，非 tab 图标）。
5. **Shared 层零污染、工程配置与文档一致**：Shared 7 文件全部纯数据/设计系统，无 IO、无 @Published、无 Service；跨域引用均 ≥2 域。pbxproj 逐项对上 AGENTS：folder-sync root group（`PBXFileSystemSynchronizedRootGroup`）+ `membershipExceptions = (Info.plist)` + `LaunchSplashView.swift` 唯一显式 PBXBuildFile；`SWIFT_VERSION = 5.0` / `SWIFT_STRICT_CONCURRENCY = minimal` 四配置同值；`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` 单槽位；Info.plist 锁 Portrait 与播放页容器自转方案一致。

## 关键数据事实

- **行数**：Settings 819（AppLaunchPreferences 27 / DramaRoutePreferences 23 / QuickLinkStore 77 / SettingsView 553 / SettingsViewModel 139）；Components 308（PosterGrid 274 / ToastView 34）；Shared 706（DesignTokens 230 / DramaModels 122 / PaperGlyphs 222 / DownloadModels 48 / MainTab 40 / PlaybackProgress 27 / QuickLink 17——后两个文件在任务清单未列，审查已覆盖）；LaunchSplashView 56。
- **QuickLinkEditorSheet 不是独立文件**：`SettingsView.swift:472-553` 内的 `private struct`。
- **裸 hex 统计**：FullscreenDrawers 17 + PlayerFullscreenControlsView 8（含第二解析器定义）+ PlayerFullscreenController 2 + LaunchSplashView 1 + DramaPlayerView 2（用户文件）= **30 处**；其中与既有 DWColor token 同值约 24 处；无 token 值 3 个（`#A04D42` 漂移值、`#0B0C0E`、`#0F1212`）。
- **smoke 覆盖面**：coretest = 端到端下载（Apple bipbop 测试流；`SMARTDOWNLOADER_FORCE_WEBKIT` 开关在 `Downloader.swift:658`）+ `--library`（两级库扫描 / 残缺集排除 / 散装收编 / DramaCache round-trip 与集数合并）；playtest = LocalMediaServer → `AVURLAsset.load(.duration)`（async 岛）→ AVPlayer 真播推进验证；videocli = 站点 API 全链（登录 → playlet/play → AES 解密 → 直链，常量从 `video_auto.py` 现解析、不硬编码不打印）；fetchtest = URLSession 连通性 + browser UA 对照（WAF 诊断）；dumpdrama = 接口全量 dump + HTML 元数据调查（og:image / img / 剧 ID）。TrustAll 有三处实现（videocli/fetchtest 各自内嵌 + `DownloadEngine.TrustAllSessionDelegate`，dumpdrama 已复用后者）——属冒烟工具内部重复，未单列发现。
- **工程配置**（project.pbxproj，326 行）：`SWIFT_VERSION=5.0` / `SWIFT_STRICT_CONCURRENCY=minimal`（Debug :203-204 / Release :256-257 同值）；`IPHONEOS_DEPLOYMENT_TARGET=26.0`（仅 iOS 26+ 可安装，个人项目口径）；`TARGETED_DEVICE_FAMILY=1`；`GENERATE_INFOPLIST_FILE=NO` + `INFOPLIST_FILE=SmartDownloader/Info.plist`；`membershipExceptions=(Info.plist)`（:21-23）；`LaunchSplashView.swift` 是唯一显式 PBXBuildFile（:18）；`ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`；`ENABLE_USER_SCRIPT_SANDBOXING=YES`；`DEVELOPMENT_TEAM=YY4M4NX34G`；无任何测试 target。
- **Info.plist**：`CFBundleDisplayName=观影`；`UILaunchScreen → UIColorName=LaunchBackground`（纸底，非整屏 PNG）；`NSAllowsArbitraryLoads=true`（注释自述「个人使用优先可用」——若上架需按 ATS 审核要求说明）；`UISupportedInterfaceOrientations` 仅 Portrait；`UIFileSharingEnabled=true` + `LSSupportsOpeningDocumentsInPlace=true`（沙盒取证口）。
- **仓库卫生**：`iOS/smoke/out/` 与 5 个编译二进制均在 `.gitignore:44-50`，git 未跟踪（`git ls-files iOS/smoke/out` = 0），无测试产物入库问题。
