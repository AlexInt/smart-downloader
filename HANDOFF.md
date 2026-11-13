# HANDOFF.md — 交接文档

> 给接手的 AI 编码代理：**先读 `AGENTS.md`**（硬性禁止 + 架构/日志/网络/并发约定，最高优先级）。本文只讲「做到哪了 / 还剩什么 / 怎么验」。**实现细节与防回归约束在 AGENTS 与代码注释里，完整过程在 git 历史**，本文不重复每个 build 日志。
>
> 最后更新：2026-11-13 · 分支 `feat/player-uikit-shell`（包 A 六步 + 全屏转向修复共 7 个提交在此分支，领先 main，待真机回归后合回）· 基准提交见 `git log -1`

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
| 横屏安全区改取窗口值（11-13） | 真机反馈横屏布局混乱：卡片经 UIHostingController + UIScrollView(.never) 宿主链，`geo.safeAreaInsets` 横屏下不可信（0/过期），兜底 10–16pt 远小于灵动岛两侧 47–59pt → 控件压系统区。修复：横屏控件层 insets 改读 keyWindow 的 `safeAreaInsets`（与宿主链无关，旋转由 UIKit 统一更新）；日志 `landscapeInsets` 对账 geo/window 两值定案 | 构建 0 error / 0 warning，**待真机回归**（锚点：`PLAYER_DBG [UIScroll] landscapeInsets … MATCH/MISMATCH`） |
| 旋转后画面消失 + bounds 振荡修复（11-13） | 真机日志实锤两件事：① geo insets 全 0、window=0/62/20/62 **MISMATCH**，坐实宿主链传播问题；② 旋转后 contentOffset 不重排——竖屏 offset 2622 在横屏页高 402 下落到第 6.5 页，正在播的卡整个在屏外（画面消失、声音继续）；且 bounds 在 402x874 ↔ 874x402 每 ~2s 振荡（无 SwiftUI 重渲染参与，旧 layoutPages 每个布局 pass 无条件重写 frame+contentSize 的布局回环）。修复：layoutPages 幂等化（几何没变就跳过）+ 几何变化后重新落回 currentSort 那一页 | 同上（锚点：旋转后 `layout bounds=…x…` 一次 + `startOffset APPLY/APPLIED` 重新落位、无反复振荡） |
| 旋转过渡跳变修复（11-13） | 真机确认横屏画面恢复，但「旋转过程很奇怪」：旋转动画的每个中间尺寸 pass 都重置 startApplied 并排一个异步 setContentOffset，动画结束后连环执行 → 内容连环跳。改为同步 `realignToCurrentPage`（每 pass 把当前页顶对齐视口，无排队跳变）；另加 `geometryFlip AGREE/DISAGREE` 判别日志（bounds 方向 vs keyWindow 方向）区分物理旋转与桥接自振荡 | 构建 0 error / 0 warning，**待真机复验**（锚点：`realignOffset`、`geometryFlip … AGREE/DISAGREE`；DISAGREE = 坐实桥接自振荡 → #6 UIKit 化根除） |
| 旋转流畅度修复（11-13） | geometryFlip 每次翻转都 **AGREE** → App 忠实跟随系统旋转、无自振荡；翻转每 ~1.5s 一次 = 设备在竖横 45° 边界附近来回倾/反复转，每次跨界系统就重播旋转动画（系统行为）。不顺畅的量化：每次翻转 mainStall ~110-130ms ≈ 丢 7-8 帧，主因 = 11 张卡每 pass 全量重建控件层。修复：横屏控制层只在活跃卡渲染，邻卡只留渐变占位（成本 ~1/11 + 去邻卡叠影，AGENTS 12 已记）；顺带 tags 列改「先查再补」清掉启动报错噪音 | 构建 0 error / 0 warning，**待真机复验**：旋转时 mainStall 应显著下降；若仍 >100ms → 剩余成本在桥接/11 个 hosting 重建，归 #6 UIKit 化 |
| **播放器 UIKit+Combine 化 包 A：全屏链路重构（11-13，新分支 feat/player-uikit-shell）** | 按开源 rotate 模式重构（对照 ZFPlayer/SJVideoPlayer，用户拍板）：① App 锁竖屏（Info.plist 仅 Portrait，窗口方向永不翻转，旋转振荡/跳变整类退役）；② 播放器容器单例化（PlayerSurfaceUIView 挂分页滚动层下对位活跃卡，卡片视频区透明、videoLayer 改可搬运子层）；③ 全屏 = PlayerFullscreenController 搬 videoLayer 进 keyWindow 容器 + transform 旋转 90°/放大连续动画（视频「跟随旋转慢慢变大」，退出反向）；④ 全屏控制层 UIKit+Combine（左上返回 icon=退出、点按呼出 3s 收起、订阅同一 VM，安全区按旋转方向映射避灵动岛）；⑤ 姿态判稳触发器（CoreMotion，滞后 55°/28°+0.6s 稳定窗，仅横屏片源，无按钮）；⑥ 卡片横屏分支/geometryFlip/landscapeInsets 全部退役，AGENTS 12 改写为「锁竖屏+容器自转」；⑦ 全屏旋转方向跟随设备实际转向（de08f27）：此前旋转角写死 +π/2，另一半转向进全屏内容上下倒置（返回 icon 跑对角、进度条翻顶），改为触发器按重力角给出 ±π/2 存入 VM，进/出动画与控制层安全区映射统一使用（对齐 SJVideoPlayer 映射） | 各步构建 0 error / 0 warning，**待真机回归**（§7 ⑭，两个转向都要验） |
| **全屏旋转修复批次（11-13 下午，真机日志驱动，四个根因）** | ① **控制层全消失**（返回/清屏/静音/进度条/时间全不可见）：performEnter 置父视图 alpha=0，显隐管理只动子控件 alpha，父视图永不恢复——修：enter 完成置 1、exit 动画中淡出，控制层 init 补一次 updateVisibility，进度条显隐改「非清屏常驻 / 清屏跟随点按呼出与 scrub」（与竖屏 HUD 同口径）；② **另一半转向倒置（de08f27 未修净）**：enter 动画 transform 写死 +π/2 未用 VM rotationAngle——修：模型 transform 用实际 rotationAngle；③ **进出两端裁切跳变**（进入竖屏闪一下 / 动画观感差）：起/终点用 surface 全框 + fill 与卡片 fit 两端跳变——修：起/终点改为「视频显示带」（surface 内按 presentationSize fit 的居中矩形，VM 新增 videoPixelSize），全程 fill（起点=带无裁切），旋转/缩放改 CA 标量关键路径（transform.rotation.z / scale.x|y，矩阵整体插值有泵缩伪影），时长 0.35→0.30；④ **全屏中左右转向无响应**（原只处理退出，转到另一侧内容颠倒）——新增：触发器全屏态 ≥55° 判稳且方向不同 → VM.rotateFullscreen → 控制器单段转体（经 0° 回正再转向另一侧），控制层 insets 随转体重映射 | 模拟器构建通过，**待真机复验**（锚点：`enter band=`（视频带矩形而非全框）/ `flip angle=` / `flip done`）。**第二轮（同日，真机复验反馈三问题）**：⑤ 回竖屏画面动一下——exit 模型终态落 identity（足迹撑回整屏宽）与动画终态不一致，结束帧闪大画面——修：模型终态=动画终态 scale(s0)；⑥ 转屏「突然转的没有过渡」——v1 起点用不等比 scale 把 fill 裁切内容压扁（竖向拉伸 22%），首帧即变形——修：几何改 v2「容器 bounds=视频横屏整幅矩形（与片源同宽高比，874×491.6 型）+ fill 恒等精确铺满 + 均匀 scale s0→1 标量动画」，全程零变形、起点逐像素重合、分辨率整幅原生；⑦ 清屏黄线偏大——全屏控制层视觉对齐竖屏 DramaPlayerView（清屏 21×16 描边矩形+27×2.2 斜线 替代 SF rectangle、静音 26 图标+36×2.5 斜线），并新增溢出感知布局（容器足迹比屏幕宽，两侧各溢 ~45pt 被裁，顶/底行相对可见区排布）+ 一次性布局对账日志 `fullscreenControls`；**第三轮（同日）**：⑧ 回竖屏视频「变大再变小」——退出动画 scale 线性收缩但旋转加速，中段（~45°）包围盒先缩后胀（874→601→706→226）——修：改旋转+缩放联合关键帧，竖向足迹按缓动单调插值、scale 沿途反解 s=targetH/(W·sinθ+H·cosθ)，竖向严格单调不超屏（横向超出与全屏裁切同语义不可见）；⑨ 黄线很大实锤：带 45° transform 的斜线用 setFrame 被 UIKit 逆变换重设 bounds（实测 27×2.2 被改成 20.65×17.54）——修：斜线改 bounds+center 定位，对账日志 `fullscreenControls slashBounds=` 应回 27×2.2；**第四轮（同日）**：⑩ 裸 CALayer 隐式动画——videoLayer 是手动 addSublayer 的子层（非 UIView 背板层），直接改 frame 触发 0.25s 隐式飞行（刚进竖屏/横转竖都抖一下的根因，进/退全屏 frame 在两坐标系间切换时叠加在容器动画上）；修：所有 videoLayer 几何写入统一包 `PlayerSurfaceUIView.withoutLayerActions`（CATransaction 禁隐式动作，不影响显式 CAAnimation），搬家/还原改「先落位再挂回」（树里不存在携旧 frame 的中间态）；⑪ 进页首帧 fill→fit 跳变：gravity 原在 makeUIView 时按 videoIsLandscape=false 设 fill，ready 翻转后等下一轮 SwiftUI update 才改 fit，首帧先渲染就是裁切闪一下；修：Coordinator 订阅 $videoIsLandscape 同步落 gravity（同调用栈早于渲染提交，用 sink 参数勿读属性）；⑫ 防穿透：surface.videoGravity setter 加「layer 搬走期间不写入」保护（全屏中 SwiftUI 周期 updateSurfaceContainer 的 fit 写入不能改掉容器的 fill）+ APPLY/SKIP 日志 + surface frame 变更日志；**第五轮（同日）**：⑬ 点击播放进竖屏「画面由大到小」：排除法坐现——加载渐变不透明、fill 就绪前不可见、isReady 与 fit 同拍提交；真正时序 = 全屏紫色渐变（像大画面）→ isReady 在 item-ready 即翻 → 渐变淡出时续播 seek 未完成底下是黑的 → 小条带「啦」地出现（fill 时代渐变→全屏视频无尺寸落差，fit 后才出现）；修：isReady 改在首帧真正合成（timeControlStatus == .playing，周期 tick 检测）才翻转，渐变盖住整个 seek 黑屏期、淡出直接交叉到已渲染条带；兑底：ready 后 3s 强制翻转（firstFrameGuard，看门狗在 settle 已取消不再保护这段）；错开风险：秒开指标不变（waitedMs 仍在 ready 测），翻转延迟典型 100–300ms ≪ spinner 800ms 阈；**第六轮（同日，上轮误诊回滚 + 真修）**：上轮「等首帧 playing 才翻 isReady」是误诊（日志实锤：`isReady flip t=79s` 在 `resume at=79s` 之后，seek 几乎瞬时，黑屏期不存在；且 waitedMs 劣化 363ms、翻转压到 load OK 前）——已回滚；真因：**AVPlayerLayer 首帧提交独立延迟于 item-ready/playing**，渐变淡出与首帧提交是两个异步事件，同拍对齐必黑一下；真修：isReady 恢复 item-ready 即翻 + 新增**条带延迟首显机制**（PlayerSurfaceUIView.concealForReveal/scheduleVideoReveal/markRevealed）：进页/切集时条带藏住（渐变盖着不可见），ready 后延迟 150ms 淡入 0.15s，与卡片渐变淡出形成交叉——两个事件谁先谁后都不黑屏；全屏路径不经首显（还原时 opacity 归 1 + markRevealed）；**第七轮（终验，用户拍板收尾）**：reveal 改 ready 当拍交叉淡入后探针全绿——两次进页淡入曲线 0→1 单调、约 150ms、与渐变淡出同拍同时长，无黑窗、无几何跳变，横屏往返正常；残余「由大到小」仅为占位渐变（全屏紫）与视频条带的形态落差（DramaPlayerView 用户文件，维持现状不再改）；双 conceal 日志为幂等重复打印，无害；revealProbe 按约定保留 | 模拟器构建通过，**待真机复验**（锚点同上 + `fullscreenControls` 对账行） |
| **剧集页封面缓存 + 简介两行门控（11-13，用户拍板）** | ① 封面按剧集 id 本地文件缓存（新 `Drama/DramaCoverCache.swift`：键=(site,dramaID) SHA256、存 Caches/DramaCovers、15 天过期按文件修改时间判定、失败保留旧文件、UIImage 解码校验防缓存错误页）；VM 三个赋值点统一走 `applyCover`（本地命中直接文件 URL 不联网，未命中远程兕底+后台落盘，成功切本地）；retryCover 改走缓存重拉；② 详情采集 15 天新鲜度闸门：`DramaCache.detailFetchedAt` 读 detail_fetched_at 列，`harvestIfNeeded(force:)` 15 天内 SKIP（不再每次进页都请求），↻ 刷新按钮 force 绕过；AGENTS 第 8 条采集时机措辞同步；③ 简介展开/收起门控：View 层 TextKit 测量（宽 350/字号 13/行距 5，UIFont 对齐 DWFont.cn 默认映射）超过两行才显示按钮，不足两行无按钮、简介变短自动收回 | 构建通过；待真机验证：二次进页 `cover use cache` + `harvest SKIP reason=fresh`、简介 ≤2 行无按钮 |
| **封面 CDN 密文 → WebView 解密落盘（11-13）** | 真机日志 `cover cache FETCH FAIL err=badData` 根因：图床 pic.* CDN 下发的封面是**密文**（curl 实证 HTTP 200 binary/octet-stream、magic 非任何图片格式；站点 JS 解密后转 blob 展示）。AES(API 常量) 与重复 XOR 均解不开，JS bundle 反推因主站掐 curl/代理 522 未成；改为**不逆算法**：收割 JS 在隐藏 WebView 里挑最大已解密 `<img>`（blob 优先，naturalWidth≥300）画 canvas 导出 JPEG（`dramaMetaJS` 新增 coverData），`DramaCoverCache.storeImageData` 按剧集 id 落盘（密文图永远拉不到，此路是本站封面唯一可用来源）；收割收尾条件改为「coverData 或 og/desc 两轮后」，轮询日志带 coverData 长度；新鲜度闸门加封面文件必须存在条件（`coverMissing` 触发重收，防缓存路径永远没封面）；applyCover 拉取加在飞去重（修 3× 重复 FETCH FAIL）；FETCH FAIL 日志带远程 URL | 构建通过；待真机验证：`cover cache STORED via=harvest`、`cover use cache`（本轮收割 SKIP 生效但封面首次落盘失败，此前无缓存命中属预期）、`harvest SKIP reason=fresh cover=ok` |
| **选集点不下载排查（11-13）** | 真机日志实证：点 3935 的第 3/4 集走了 `tapEpisodeDirect` 的 `!ep.playable` 分支（toast「暂不可看」有发出，用户感知为「没反应」）。`playable` 映射下载接口 `episodeAll[].access.can_play`（DramaAPI），即**下载接口对 3/4 集返回 can_play=false**——结合 `trial_episode_count` 机制（3703 样本全集 free/trial=0；3445 SSR 匿名样本全集 can_play=true），初判是站点「免费试看 N 集」模式，3/4 集需站点解锁，App 如实拒绝（下载接口也不发 video_url，强下只会 noVideoURL）。改进：① fetchInfo/saveDetail 各加 `[CHECK]` 每集 access 原值日志（sort/id/state/can_play/trial/reason），下次进页即可定性「站点锁定 vs 解析缺失」；② 批量下载路径选中集全不可播时原本静默清选返回（chosen 空 guard），补 DROP-ALL/DROP-PARTIAL toast；③ toast 文案改为「站点未开放下载」 | 构建通过；待真机：`[CHECK] fetchInfo ... access [...]` 日志确认 3/4 集 state（locked?/pay?），若站点锁定则行为正确，解锁后需站点内操作。跟进（f2d8e5a）：缓存路径进页现在也打 `[CHECK] cacheLoad ... [s1:api=x,dtl=y/state ...]`（下载接口 playable vs 详情接口 can_play 双源对照），上一轮进页走缓存闸门 SKIP 没触发 fetchInfo 日志，故补此路。**根因确认（真机 ↻ 实证）**：`fetchInfo` 实时返回四集全部 `state=free,can_play=true`——api=0 是 DB 陈旧缓存（上次 fetchInfo 落库的旧权益，站点后来放开 3/4 集），↻ 刷新 saveInfo 后 api 全部翻 1，问题解除；缓存优先加载设计使陈旧 playable 无限存活（只能手动 ↻ 治愈），后续可选方案：检测 api/dtl 可播冲突时后台静默 fetchInfo 自愈（暂不做）。顺带修复：`harvestIfNeeded` 的 force 原被 `hasHarvestedThisVisit` 去重前置吞掉（↻ 承诺的强制重抓失效），改为 `!hasHarvestedThisVisit || force` |
| **为你推荐封面解密落盘（11-13）** | 推荐卡 cover 与主封面同一张密文图床（related_list 的 pic.* URL），AsyncImage 直连必败全占位。复用主封面方案：dramaMetaJS 逐推荐卡（`a[href*=/drama/detail/]` 取视频 id，排除本页 ownId）挑 naturalWidth≥60 的已解密 img canvas 导出 JPEG（宽封顶 320、q0.8、上限 12 张），didFinish 先 scrollTo 底部 + 强制 eager 触发懒加载（不滚拿到的是 1px 占位图）；pollMeta 逐张 `DramaCoverCache.storeImageData` 按**推荐剧自己的 id** 落缓存（后续进该剧页 applyCover 直接命中，storeImageData 加 fresh-skip 防 poll 重复写）；收尾条件改为「主封面+推荐封面齐」或 og/desc 三轮兜底（`apiDetail.relatedList.count` 为期望值）；`relatedDramas` 读库时本地命中换文件 URL（coverLocal=x/10 日志），AsyncImage(fileURL) 与主封面同路已验证 | 构建通过；待真机：`harvest recCovers stored=10/10`、`cover cache STORED id=<推荐剧id> via=harvest`、下次进页 `coverLocal=10/10` 且卡片出图 |
| **推荐封面 rec=0 修复：收割 webview 挂窗（11-13）** | 真机实证 `rec=0`：收割 webview 原先完全脱离视图树 → WebKit 不渲染 → 站点懒加载 IntersectionObserver 永不回调 → 推荐卡停在 1px 占位图（naturalWidth=1 被过滤器全灭）；主封面能拿到是首屏非懒加载。修复：begin() 把收割 webview **挂进 keyWindow 最底层**（alpha 0.01 + 禁交互，用户不可见不挡操作，WebKit 认定可见 → IO 回调 → blob 换入），finish() removeFromSuperview；didFinish 滚动改**分步滚动**（10 步 × 800px × 250ms，跳底只覆盖最后一屏、前面卡不进视口）；recDiag 诊断字段（anchors/imgs/ready/nw 采样）进 round 日志 | 构建通过；待真机：`diag=a:10 i:10 r:10 nw:[...]`（非全 1）+ `rec=10` + `recCovers stored=10/10`；下次进页 `coverLocal=10/10` 卡片出图 |
| **播放中下完的集滑过去仍显示「尚未下载」（11-13）** | 根因：`PlaybackQueueService` 的槽位在 configure 时构建一次，`isAvailable` 是开播快照；播放期间下载完成不回填，滑到该集永远占位 +「尚未下载」toast（AGENTS 待办 #10 场景）。修复：① Service 加 `refreshAvailability()`（重扫磁盘按集号对位 playlistURL/identity，新集号可追加，current/history 重新对位，无变化返回 false 零 UI 成本）；② `PlayerFeedViewModel.pageSettled` 先对账再取槽位（对账后新可播集走正常 load，toast 不再误发）；③ `PlayerPagingScrollView.refreshCardsIfNeeded` 加槽位可用性指纹（sort:isAvailable）——原来只跟踪 currentSort/isReady/toast 三个维度，slots 内容变化不重绘卡片；AGENTS #10 措辞同步 | 构建通过；待真机：播放 ep1 期间 ep2 下完 → 上滑 `queueRefresh series=... available=[1,2]` → 卡片出视频、无「尚未下载」toast |

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
| 6 | **播放器视图壳 UIKit+Combine 化**：**包 A（全屏链路）已完成**（§2，分支 feat/player-uikit-shell）；包 B 待做——竖屏卡片 DramaPlayerView UIKit 化（designFrame 转 frame+scale）、卡片手势迁 UIGestureRecognizer（六条仲裁约束逐条对照）、PlayerFeedView/Container 胶水收编、UIHostingController 退役；VM/Service/Model（GCD+Combine）零改动路线已在包 A 验证（全屏控制器/控制层直接订阅同一批 @Published）；前置调研：specs/播放器旋转方案调研.md（ZFPlayer/SJRotation/KSPlayer 源码级对照 + 借鉴清单，搬运粒度维持 videoLayer 勿改搬 view） | 中 |

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

**本轮真机回归重点**：① WiFi/蜂窝下载（IP 直连/WebKit 降级日志）；② 切回浏览页不再 mainStall；③ 竖滑/斜滑不再误暂停；④ 点按显示进度条 3s、上升淡入；⑤ 右侧时长切剩余时间、杀进程重开记住；⑥ toast 2s 收回；⑦ 播放不再偶现「无法连接服务器」；⑧ 秒开 `makeItem HIT`、长按 2x/横滑 seek/翻页仲裁不变；⑨ 详情页整页能滚到推荐与档案、`PLAYER_DBG [Entry] reco refresh count=10 archiveSections=9`、推荐卡片 push 新剧集页后返回能回原剧、格子直点（未下载→入队 / 下载中→取消 / 已下载→播放）、「下载全部」不重复入队、左缘返回手势与整页 ScrollView 不打架；⑩ 角标与金环（未下载灰箭头 / 已下载金三角 / 下载中金环+n/100 / 选中集不叠加）、「查看全部 ›」内联展开 13+ 集后推荐区被正确下推不重叠、「收起 ›」能收回、工具条全选→下载所选可提交、选集行 ↻ 刷新生效；⑪ 快速横滑结束不再误暂停、且 seek/翻页/2x 仲裁不变（误吞时应见 `TAP SKIP reason=justEndedSeek`）；⑫ 横屏片源竖屏持机完整显示不裁切（`videoOrientation landscape=true`）、竖屏片源维持拉满；⑬ 旋转横屏后返回/清屏/静音/进度条尺寸正常（landscapeOverlay）、旋转回竖屏恢复画布布局、横屏下点按暂停/长按 2x/横滑 seek/左缘返回照常；⑭ **（全屏改造后，取代 ⑬ 的旋转条目）**：App 锁竖屏——转设备不再引发界面翻转；横屏片源稳定转横自动进全屏（动画连续、视频全程可见不跳变、无按钮）、45° 边界倾斜不反复进出、全屏内左上返回 icon 回竖屏（动画反向回原卡）、点按暂停/长按 2x/横滑 seek 可用且不误暂停、竖屏片源转横不动作、上下滑切集不受影响、杀进程重开全屏态不残留；**两个转向都验**——向左倒与向右倒各进一次全屏，画面均不上下倒置（返回 icon 左上、进度条在底），退出反向动画两个方向同样正常（de08f27 修的就是另一半转向倒置）；全屏中再转向另一侧应单段转体（锚点：`flip angle=` / `flip done`），两侧都要验。

## 8. 维护本文档

每完成一个任务：更新 §2 状态 / §5 待办，提交里带上本文档变更。**改架构约定改 `AGENTS.md`，改进度状态改本文档**；实现细节写进代码注释，不在此堆 build 日志。
