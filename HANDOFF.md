# HANDOFF.md — 交接文档

> 给接手的 AI 编码代理：**先读 `AGENTS.md`**（硬性禁止 + 架构/日志/网络/并发约定，最高优先级）。本文只讲「做到哪了 / 还剩什么 / 怎么验」。**实现细节与防回归约束在 AGENTS 与代码注释里，完整过程在 git 历史**，本文不重复每个 build 日志。
> 
> 最后更新：2026-11-16 · 审查第一批止血 + 手势 A 档已提交，新增验证点待真机回归（见 §2 末）· 此前 30 个验证点 82 处已全部销账（用户逐一确认通过）· `feat/drama-page-paper` 已合并至 `main`，后续修复直接在 `main` 上提交 · 基准提交见 `git log -1`

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

### 已完成代码、待真机验证（2026-11-16 本批：审查第一批 + 手势 A 档）

- **审查第一批止血 6 条**（`cbf0a6a`）：DownloadEngine `ipDirectHosts`/`dnsCache` 收敛进 `sharedStateLock`（外部一律走 `ipDirectContains/Insert` + `dnsCacheGet/Set` 四入口；`preferWebKit` 保持裸 Bool 良性竞争）· DramaFavorites 三方法补 `defer close`（此前每次调用泄漏一个连接）· `seek(fraction:)` 删 `isSeekGestureActive` 置位行（两条 pan 路径 `.began` 已各自置位；菜单「从头播放」无手势在跑，置位即泄漏 → 点按暂停与长按 2x 静默失效）· 全屏倍速文案走 `DramaPlayerViewModel.rateText`（删本地 `trimmed`，`"0$"` 字面量替换 bug 曾在这份拷贝复活成「2.00×」）· `detailFetchedAt` prepare 失败分支删显式 close（defer 已关，双 close）· 旧 UserDefaults 搬迁改「写失败保留源键不置迁移标记、下次启动幂等重试」（`execWrite`/`writeLegacy` 返回 Bool，`@discardableResult`）
- **手势 A 档**（本轮，行业基线已核不推翻拍板）：
  - **拖动中不实时 seek，松手才 seek**：`.changed` 只挂 `scrubPreview(fraction:)`（@Published `scrubPreviewFraction/Text`，目标时间由 VM 算好下发）；`.ended` → `commitScrubThenEndGesture()`（performSeek 带完成回调、落稳后 `flush()`）；`.cancelled/.failed` → `cancelScrubThenEndGesture()`（丢弃不 seek）。HUD 停留时序铁律：commit 里 performSeek 先行、收尾最后（showScrubHud 会 cancel 已排的 800ms 停留任务，反序 = HUD 永不淡出）。
  - **目标时间气泡**：竖屏 DramaPlayerView 气泡 y712 钳 45…345 防出屏；全屏 previewBubble 悬轨道目标点上方。两侧填充/圆点渲染统一 `previewFraction ?? progress`。
  - **全屏竖滑 = 左亮度右音量**（此前全屏竖滑完全空手）：容器旋转 ±90° 后本地 x = 视频横轴 = 用户感知左右、本地 ty 主导即竖滑；`PanAxis` 首个 ≥6pt 主导方向锁轴全程不换，锁轴那一刻定左右边中途不换；竖滑 branch guard `!isFastForwarding`（2x 先起独占）。
  - **亮度/音量 Service `PlayerBrightnessVolume`**（VM 不 import UIKit）：音量走隐藏 `MPVolumeView` slider（挂全屏容器，随容器销毁下次重挂）；亮度 `window.screen.brightness`；亮度死钮接真 = `toggleMaxBrightness`（一键最亮 ↔ 还原点）。指示浮层 `adjustPill`/`showAdjustFeedback` 不进控件数组（控件收起时也有反馈）。
  - 顺手清两个存量警告：SwipeBackSupport 的 `as? UINavigationController`（UIKit 动态挂载误报，`(view as AnyObject) as?` 跳板保持同一运行时判定）、EpisodeDrawerPanel 的 no-op `as?`（直接 `panel?.revealCurrent()`）。
  - 真机回归锚点（PLAYER_DBG）：`scrubPreview` / `scrubCommit` / `scrubCancel` / `fullscreen seekPan axis=` / `fullscreen adjust side=` / `volumeBridge attached` / `brightness toggle`；约定全文见 `docs/agents/conventions-player.md` 第 2/4 条。

### 已完成代码（2026-11-16 第二批：审查第二批 7 条，全量构建 0 error / 0 warning）

- **P1-④ 追更 SQL 下沉**（`27ce095`）：ProfileViewModel 删 `import SQLite3` 与裸 SQL（AGENTS 5/7），追更查询原样搬入 `DramaCache.chasingRows()`（含「最后一集已下载」子查询，返回 `ChasingRow`）；`DramaCache.rows(for:)` 一次连接批量读多部剧——历史/收藏/点赞三分类此前逐条 load（每条各开各关连接）、`coverURL` 兜底还会再 load 一遍整剧（双重读放大），现 `load` 的逐剧读取体抽成私有 `readEntry(db:site:dramaID:)`、`coverURL(site:dramaID:remote:)` 由调用方带入远端 URL。
- **P1-⑤ 删 preferredColorScheme**（`ec66f32`）：环境值会沿 `navigationDestination`/`fullScreenCover` 传进墨本轨播放页，旧注释「不影响其它页」与事实不符；纸本页色值全写死，无需锁。
- **P1-⑧ prune 合批改队列**（`c6b125b`）：旧 `pruneScheduled` 布尔在同 runloop 两个 done 时丢弃第二个的去重请求（AGENTS 24 窄窗口复现路径）；改 `pendingPrunes` 队列 + 排水循环，排水途中入队的新 done 同轮处理。
- **P1-⑨ playIfDone 下沉 VM**（`9b7211f`）：新增 `SeriesDetailViewModel`（与列表页 `handleTap` 同范式），done 守卫/失败重试/HLS 选型/集号解析全部出 View；View 只发意图 + 绑定两个出口。
- **P1-⑬ 「已下完」口径**（`9a0410e`）：「我的」筛选按审查选项 B 改名「已下完/未下完」（判定 = 最后一集已下载，命名即口径）；播放口径「已看完」（距片尾 5s）保留在下载页逐集显示，两个词各管各的。
- **P1-⑭ 去重冒烟固化**（`c18a245`）：`iOS/smoke/deduptest.swift`（@main 包装），5 断言全 PASS（同集双目录只列一条+选无后缀 / 列表落点==preferredEpisodeFolder 判读 / 重试摘旧+不夺走能播的 done / keeper done 落盘后只留一条 / 散装不去重）；分册验收段引用具体文件名与编译命令，`pruneSupersededAttempts`/`loadLibrary`/`preferredEpisodeFolder`/`registerEpisode` 改动后必须重跑。
- **P1-⑪ DWUIColor 镜像收口**（`46b9e8c`）：DesignTokens 新增 `DWUIColor`（每 token 镜像 DWColor 同名同值），`UIColor(hex:)` 解析器全库唯一（删全屏控制层私设拷贝）；30 处裸 hex 收口（Drawers 17 / ControlsView 8 / Controller 2 / LaunchSplash 1）+ 新 token `drawerDim`；**漂移实证修复**：全屏选集描边 `#A04D42` → `episodeCellStroke`（#A05142）。DramaPlayerView 2 处属用户文件暂缓（待用户拍板）。
- **三机型快照首跑**（`docs` 提交，2026-11-16）：新建 SE 3 代 iOS 26.5 模拟器「SE3-快照」（iOS 26.5 无预置 SE，`simctl create`），矩阵脚本固化 `iOS/smoke/snapshot3.sh`（样张源自动发现 + install 后灌样张——重装 App 换数据容器清样张的坑写在脚本头），5 态 × 3 机型 15 张全 PASS、零布局问题，明细见 §5 第 5 项。

## 3. `player/` 模块架构地图

→ 已并入 `docs/agents/conventions-player.md` 顶部（改 player/ 前读那一个文件即可）。

## 4. 关键设计决策

→ 已并入 AGENTS「具体约定」各条与 `docs/agents/conventions-*.md`：原 1–7 与 AGENTS 重复（分页 UIKit / 禁连续手势 / 单播放器 / ZStack 保活 / 日志），4.8 进 `conventions-drama-profile.md`，4.9 进 `conventions-player.md`。此处不再重复维护。

## 5. 待办清单（按优先级，2026-11-16 同步）

| # | 事项 | 优先级 |
|---|---|---|
| 1 | ~~审查第一批止血~~ → **已完成**（`cbf0a6a`，2026-11-16，代码级验证通过，无真机专项） | ✅ |
| 2 | ~~手势 A 档~~ → **已完成**（2026-11-16 提交，**待真机回归**：拖动手感 / 竖滑灵敏度 / 锁轴阈值，锚点见 §2 末） | ✅ |
| 3 | 手势 B 档待拍板：竖屏全屏按钮（推翻「无按钮入口」）、edgePan 改交互式跟随（推翻「越阈即退」） | 中（等用户拍板） |
| 4 | ~~审查第二批（7 条）~~ → **已完成**（2026-11-16 逐条提交：④`27ce095` ⑤`ec66f32` ⑧`c6b125b` ⑨`9b7211f` ⑬`9a0410e` ⑭`c18a245` ⑪`46b9e8c`，全量构建 0 error / 0 warning；明细见 §2 第二批小节） | ✅ |
| 5 | ~~三机型快照首跑~~ → **已完成**（2026-11-16：`simctl create` 新建 SE 3 代 iOS 26.5 模拟器「SE3-快照」375×667，5 态 × 3 机型 15 张全 PASS——SE 播放页 0.79 contain 缩放控件完整无裁切（画布 310×667 水平居中留 ~33pt）、详情页安全区三档正确（顶部让出状态栏/灵动岛、页底无溢出）、下载页 3 列网格 103 / 112.7 / 125pt 全命中 (宽−44−20)/3；**零布局问题**。矩阵脚本固化 `iOS/smoke/snapshot3.sh`；坑：重装 App 换数据容器清样张，须 install 后再灌） | ✅ |
| 5b | **快照复验（画面/选集上下排布 d4de1eb）**：15 张全 PASS——17 Pro/SE 竖屏画面止于选集胶囊顶、底部墨带完整、控件无裁切；全屏铺满不受影响；顺手修脚本两 bug（无参数设备列表被并成串、样张源在待重装设备旧容器内须先拷中性位置） | ✅ |
| 6 | 播放器视图壳 UIKit 化包 B：竖屏卡片 UIKit 化（**DramaPlayerView 是用户文件，等用户发起**；VM/Service 零改动路线已在包 A 验证） | 中（依赖用户） |
| 7 | 中期：~~AGENTS 简介块行号改锚定符号名~~（✅ `9076145`）、~~SQLite WAL+busy_timeout 放宽+BUSY 计数~~（✅ `c1b46a7`）；剩：无障碍第一遍（标签/命中区）、千行文件拆分 | 低 |
| 8 | 本地推荐算法（接入点 = `PlaybackQueueService.resolveNext/Previous`） | 按需 |

## 6. 待查 / 已知问题

- **浏览页路由「有时原生有时 web」（未改，待拍板）**：`decidePolicyFor` 只在 `navigationType == .linkActivated`（真实 `<a>`）+ `DramaTarget.parse` 命中时取消网页推原生；卡片若用 JS `location.href`/`pushState`/`window.open` 跳，`.other` 拦不住。URL KVO 兜底但 `detectDrama` 有 `lastAutoDramaKey` 去重、`pushDramaPage` 不写该标记 → 两路径状态不一致，同剧二次点击可能被挡。`DramaTarget.parse` 只认 `/drama/(video|detail)/<数字>`。建议：主帧剧集 URL 一律 `.cancel` 并推原生、两路径共用去重标记——触及导航，先等确认。
- **手势残余边界（可接受）**：带外慢速横向拖拽 >0.15s 仍可能起 2x（慢拖与「长按+慢漂移」不可区分，「先起者独占」的固有歧义）。
- **tags 数据源（已定案，细节见 `DramaDetailData` 代码注释）**：站点 detail 走 Nuxt `_payload.json`（devalue 扁平数组），非明文/非信封；解码链 明文→信封→payload，`via=plain|envelope|payload` 日志区分。旧缓存无 `tags_source` → 进页自动补采一次。
- **纸本轨字体（已定案 2026-11-14：保持系统字体）**：画布用 Noto Serif SC / Noto Sans SC，App 走系统字体（宋体/苹方）替代，纵向落位存在 ≤4pt 偏差。用户拍板不内置（省 10–20MB 包体），该偏差只在与设计稿逐像素并排比才看得出，接受。**若将来要 1:1 还原，改 `DWFont` 映射 + 打包字体文件即可，View 层不用动**（`DWFont.serif/cn` 本来就是唯一入口）。
- **`docs/design/gear-*`（已处理 2026-11-14）**：5 个工作稿已入库（`122ee41`），3 个 `.DRAFT-not-adopted` 废弃稿已删除。后续同类比稿：**采用稿入库、废弃稿即删**，不要留 DRAFT 后缀的文件堆在仓库里。

## 7. 验证与调试

编译 / 冒烟 / 真机日志命令 → AGENTS「常用命令」与「诊断日志约定」第 7 条；模拟器验收（装机/截图/Debug 参数/探针死路）→ AGENTS「模拟器视觉验收」节，此处不重复。

- 排障一律**先加 log 再请用户贴 log**，靠日志判读不靠猜（本项目协作模式）。
- 高频日志锚点：秒开 `preload OK` / `makeItem HIT|MISS` / `load OK waitedMs=`；交互 `TAP → togglePlayback` / `LONGPRESS began|ended` / `seekPan began` / `edgePan → back`；卡顿 `PERF_DBG mainStall ms=`（>100ms 真卡顿）。

## 8. 维护本文档

每完成一个任务：更新 §2 状态 / §5 待办，提交里带上本文档变更。**改架构约定改 `AGENTS.md`，改进度状态改本文档**；实现细节写进代码注释，不在此堆 build 日志。
