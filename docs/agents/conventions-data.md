<!-- 本文件内容逐字搬自 AGENTS.md（2026-11-16 拆分），是对应域的完整约束。改动该域代码前必读；主文档 AGENTS.md 只保留结论索引与承重规则。 -->

# 具体约定 · 数据与工程底座（持久化收口 / SQLite 迁移 / 槽位对账 / ZStack 保活 / 文本测量）

（编号沿用 AGENTS.md「具体约定」1–24 的全局引用）

5. **所有持久化统一走 Service，ViewModel 里不得出现 `UserDefaults.standard` / `FileManager`**：播放器全局开关（静音/清屏/时长 label）走 `PlayerPreferences`，剧集收藏走 `DramaFavorites`（SQLite `drama_favorites` 表，v3 起不再用 UserDefaults），集级行为数据（点赞/收藏/进度）走 `EpisodeActionsStore`（SQLite），快捷站点与启动 tab 走 `QuickLinkStore` / `AppLaunchPreferences`，路由偏好走 `DramaRoutePreferences`，排序偏好走 `DownloadsSortPreferences`，起始页走 `BrowserStartPage`，登录 token 由 `DramaSession` 自行读写（Service 内部允许）。Service 只做读写，不含业务判断。判据：删掉 UI 后这个读写仍然成立。

6. **每一集自己的行为数据（点赞 / 收藏 / 上次播放位置 / 后续要加的字段）一律进 SQLite 的 `episode_actions` 表，不许再散进 UserDefaults**：主键 `(site, drama_id, episode_id)` 与 `drama_episodes` 同一套身份，能 JOIN 出「看到第几集」「哪些集收藏过」这类关系查询。归属由 `MediaIdentity` 表达、由 `EpisodeActionsStore.identity(...)` 一处解析（播放队列、下载列表、删除清理三处共用），解析不到服务端 id 的资源退化进 `local_actions`（路径主键），两张表互不覆盖。表结构变更走 `PRAGMA user_version` 版本迁移，新字段写 v(n)→v(n+1)，别再用「ALTER 报错就忽略」。写入只发生在关键时机（暂停 / 拖完 seek / 切集 / 退出播放页 / 进后台），播放中只攒内存不落库；拖完 seek 的 flush 必须**现读 `player.currentTime()`**（`PlaybackProgressTracker.current()` 现读优先于 1Hz tick 更新的 pending——拖完立即 flush 曾把拖动前旧位置落库，2026-11-14 修），flush 同时把现读值回写 pending（防 deinit 兜底 flush 倒退）。**点赞/收藏只记本地状态，不显示计数**（2026-11-15 用户拍板）：竖屏互动列与横屏底栏都只有图标，勿再按集号编占位数值（`DramaEpisode.likeCount` / `savedCount` / `compactCount` 已删除）——本地片源没有服务端计数，编出来就是假数据。

7. **建表与迁移只有一个入口 `Drama/DramaDatabase.swift`**：`user_version` 是整库一个计数器，两个 Service 各管一段会互相跳过对方的建表，所以 `DramaCache` / `EpisodeActionsStore` 的 `openDB()` 都只调 `DramaDatabase.open()`。补列逐列查 `PRAGMA table_info` 再 ALTER（不靠版本号判断列是否存在）；旧数据搬迁用独立 UserDefaults 标记门控，与 schema 版本解耦。

9. 不为了分层而分层：不硬造协议、不搬 Coordinator/Router、不给三行代码加一层；等一个类型出现第二个变更理由再拆。`struct` 做 Service 可以。

10. 未下载集的占位页保留（如实显示 + 引导下载），但**槽位可用性快照必须在每次停稳时对账磁盘**（`PlaybackQueueService.refreshAvailability()`，VM 在 `pageSettled` 里先对账再取槽位；`PlayerPagingScrollView.refreshCardsIfNeeded` 跟踪槽位可用性指纹，占位→可播要重绘卡片）——曾因开播快照不更新，「播放中下完的集」滑过去永远停在「尚未下载」占位（真机实证）。

11. **App 用 ZStack 保活容器而非系统 TabView**：浏览页（WKWebView）常驻底层可见、其余 tab（下载页 / 设置页）各自以不透明背景盖上去，切 tab 只改可见性——因为 SwiftUI TabView 会藏起非活跃 tab，WKWebView 离屏被 WebKit 挂起/回收图层，切回唤醒阻塞主线程 300ms–1s（真机日志实证）。tab 条目与顺序只在 `Shared/MainTab.swift` 一处定义（新增 tab 改那里），底部 bar 是自定义 `safeAreaInset`，剧集详情 push 时经 `BrowserView` 的 `detailActive` 绑定隐藏。勿改回用 TabView 装 WKWebView。

15. **给「Text + SF Symbol」算固定宽度时，符号宽度必须实测**（`NSImage(systemSymbolName:).withSymbolConfiguration(.init(pointSize:))`，12pt 的 `chevron.up` 是 **14×8**，按 12 估就差 2pt）。宽度少 1–2pt 时 SwiftUI 不会报错，而是把中文**压成竖排**（「收起」→ 收在上、起在下，真机实证）。所有这类自定义容器一律加 `.lineLimit(1)` + `.fixedSize(horizontal: true, vertical: false)`，让宽度只由内容决定，容器宽度仅用于落位。
