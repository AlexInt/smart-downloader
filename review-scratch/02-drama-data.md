# iOS 数据域审查：Drama/ + Profile/（02-drama-data）

## 小结

范围 15 文件 6414 行（Drama/ 6105 + Profile/ 581）。**P0=0，P1=5，P2=13**。数据域整体质量高于平均线：迁移单入口、SWR 归一化、错误链路、封面一致性四个机制都严格按 AGENTS 落地；ProfileViewModel 的「后台串行队列+代际令牌」实现正确。但存在两个硬伤：**DramaFavorites 全部 3 个方法不关连接**（每调用泄漏一个 SQLite 连接）；**ProfileViewModel 直接 import SQLite3 在 VM 里写裸 SQL**，同时**绕过了**「追更逐剧 load 卡顿」本应走 Service 层修的路径。ProfileView 的 `.preferredColorScheme(.light)` 会沿 NavigationStack 环境流进 push 的 DramaNativePage 与 fullScreenCover 播放页，与「纸本单轨视觉」第 1 条禁令同型。

---

## P1（违反 AGENTS 约定或明显架构债）

### P1-1 DramaFavorites 三个方法全部不调用 sqlite3_close —— 连接泄漏
- 位置：`iOS/SmartDownloader/Drama/DramaFavorites.swift:13-69`（isFavorite:13 / setFavorite:25 / favoriteDramas:53）
- 证据：全文件 `grep -c sqlite3_close` = **0**。对照同库其余 Service（DramaCache 15 处、EpisodeActionsStore 11 处均有 `defer { sqlite3_close(db) }`）。
```swift
func isFavorite(site: String, dramaID: String) -> Bool {
    guard let db = DramaDatabase.open() else { return false }
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }   // 只 finalize 语句，连接从不关闭
```
- 违反：DramaDatabase.swift 头注释自定的「sqlite3 连接按次开关不共享」契约（DramaDatabase.swift:20）；VM 层 DramaPageViewModel.init、toggleFavorite 与 ProfileViewModel.favoriteItems 每次 reload 都走这三个方法。
- 影响：每次调用泄漏一个连接 + 文件句柄。iOS 进程 fd 上限有限，长会话（连续看多部剧 + 反复进出「我的」页）累积，最终 `sqlite3_open_v2` 返回 SQLITE_CANTOPEN → isFavorite 恒 false、收藏写不进（且只 print 不抛错）。
- 建议：三方法补 `defer { sqlite3_close(db) }`；更稳的做法是在 DramaDatabase 加 `withConnection<T>(_ body: (OpaquePointer) -> T?)` 统一开关，消灭这类手写遗漏。

### P1-2 ProfileViewModel 在 VM 里直接写 SQL —— 违反「建表/查询只有一个入口」「VM 不碰系统对象」
- 位置：`iOS/SmartDownloader/Profile/ProfileViewModel.swift:2`（import SQLite3）、`:156-195`（chasingItems 裸 SQL）
- 证据：
```swift
guard let db = DramaDatabase.open() else { ... }
let sql = """
SELECT site, drama_id, name, update_status, cover, fetched_at,
       (SELECT e.downloaded FROM drama_episodes e ... ORDER BY e.sort DESC LIMIT 1) AS last_downloaded
FROM drama_cache
WHERE update_status IS NOT NULL AND update_status != ''
  AND update_status NOT LIKE '%完结%' AND update_status NOT LIKE '%全%'
```
- 违反：AGENTS 第 5 条「所有持久化统一走 Service，ViewModel 里不得出现 UserDefaults.standard / FileManager」（SQLite 查询同性质）；第 7 条「建表与迁移只有一个入口」延伸出的「drama_cache/drama_episodes 的查询口径归 DramaCache」；域内五层规则「VM 不直接读写系统对象」。
- 影响：①「连载中」的判定口径（LIKE '%完结%'/'%全%'）写死在 VM，无法被其它域复用，口径漂移无一处收口；②与同文件 history/favorite/liked 三条已走 Service 的装配路径并立，域内出现两种数据访问范式；③开了「VM 可以直接摸库」的先例。
- 建议：把这条查询原样搬进 DramaCache（如 `static func chasingRows() -> [(site:dramaID:name:status:cover:lastDownloaded:)]`），VM 只装配。性能动机（避免 97 次逐剧 load）在 Service 层同样成立，子查询本身写得很好（一条 SQL 消灭 97 次 load），只是放错了层。

### P1-3 ProfileView `.preferredColorScheme(.light)` 作用于整个 NavigationStack 子树，波及 push 页与播放页
- 位置：`iOS/SmartDownloader/Profile/ProfileView.swift:67`
- 证据：`.preferredColorScheme(.light)   // 纸本轨锁浅色：域级分工，不影响其它页`——挂在 NavigationStack 上，`navigationDestination` 的 SettingsView / **DramaNativePage** 都在栈内。
- 违反：纸本单轨视觉第 1 条明令「不要在 Scene 层加 preferredColorScheme(.light)（DramaDetailView 与播放页会跟着变浅）」。此处挂在栈级而非 Scene 级，但环境向 push 目的地传播的机制相同：从「我的」→ 剧集详情 → fullScreenCover 播放页（墨本轨）整条链被强制 light。播放页坐标/颜色全为墨本硬编码，colorScheme 环境翻 light 会让任何读 colorScheme 的系统件（菜单、sheet、状态栏配色）按浅色出。
- 影响：注释自称「不影响其它页」与事实不符；从「我的」进入的播放页与从下载页进入的播放页行为分叉。
- 建议：删除该修饰符。纸本页色值已全部写死（AGENTS 第 1 条「页面色值全是写死的十六进制」），不依赖系统外观，无需再锁。

### P1-4 DramaCache.detailFetchedAt prepare 失败分支双重 sqlite3_close —— UB/崩溃风险类缺陷
- 位置：`iOS/SmartDownloader/Drama/DramaCache.swift:281-289`
- 证据：
```swift
defer { sqlite3_close(db) }                      // :283
guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
    sqlite3_close(db)                            // :287 显式关一次
    return nil
}                                                // defer 再关第二次 → 对已释放句柄操作
```
- 违反：无（手写失误）；风险类别属 P0 类（崩溃），但触发条件=静态合法 SQL 的 prepare 失败（仅 OOM/库损坏），实际概率极低，降记 P1。
- 影响：潜在 use-after-free。
- 建议：删 :287 的显式 close，统一靠 defer。

### P1-5 旧 UserDefaults 行为搬迁：标记先置位 + 源键无条件删除，写失败即一次性数据丢失
- 位置：`iOS/SmartDownloader/Drama/DramaDatabase.swift:276-279`（defer 置位）、`:310-317`（removeObject 无条件删源键）
- 证据：
```swift
guard !defaults.bool(forKey: legacyMigratedKey) else { return }
defer { defaults.set(true, forKey: legacyMigratedKey) }   // writeLegacy 失败也置位
...
writeLegacy(db, identity:..., record: record)             // 失败只 print（execWrite 内）
for key in ... { defaults.removeObject(forKey: key) }     // 源键照样删
```
- 违反/风险：数据丢失风险类。搬迁写库失败（execWrite 只打日志）后源键仍被删，用户旧点赞/收藏/进度永久丢失且不可重试。
- 影响：概率低（需 SQLite 写失败而 UserDefaults 正常），但属一次性不可逆。
- 建议：writeLegacy 失败计数，moved < 待迁数时**不删源键、不置位标记**，下次启动重试（搬迁本身幂等：MAX 合并 + OR IGNORE）。

---

## P2（改进建议）

### P2-1 迁移标记在 migrate() 之前置位，首次迁移失败当进程不再重试
- 位置：`DramaDatabase.swift:46-49`。`if !migrated { migrated = true; migrate(db) }`。migrate 内部所有失败路径只 `fail()` 打日志不回传。首次开库若磁盘满/IO 错，schema 半成品，本进程后续所有 open 跳过迁移，全部查询失败（静默空结果）。建议 migrate 返回 Bool，失败不置位（migrate 幂等，重跑安全）。

### P2-2 transaction() 无 ROLLBACK，部分写失败仍 COMMIT
- 位置：`DramaDatabase.swift:357-362`。`BEGIN; body(); COMMIT;` 三连，body 内 execWrite 失败只打印，COMMIT 照走 → saveDetail（40+ 列 + N 集 + related）部分提交的中间态落库。建议记录 body 内失败计数，失败走 ROLLBACK。

### P2-3 无 WAL + busy_timeout 100ms + BUSY 时读路径静默返空
- 位置：`DramaDatabase.swift:41`（唯一 busy_timeout 设置点）；全库 grep `journal_mode|WAL` = 0 命中。Profile 后台装配队列（ProfileViewModel.swift:60）与主线程写（saveDetail 大事务、reconcileDownloaded）并发时，读者撞锁最多等 100ms，随后 watchedDramas()/favoriteDramas() 返回 `[]`——**静默空列表**，用户看到的是空态而非错误。建议：①开 `PRAGMA journal_mode=WAL`（读不阻塞写，最划算）；②读路径 busy_timeout 放宽到 2–5s 或 BUSY 重试一次；③连接复用或线程内缓存连接，省每次 open_v2+migrationLock 的固定开销（当前一次剧集页 load 约 6 次开关）。

### P2-4 reconcileDownloaded 逐行 autocommit，未包事务
- 位置：`DramaCache.swift:369-398`。N 集 = N 次独立 COMMIT（回滚日志模式每次 fsync），与同文件 saveInfo/saveDetail 的事务化不一致；且非原子（中断留下半对账状态）。包进 `DramaDatabase.transaction` 即可。

### P2-5 DramaAPI 每个请求新建 ephemeral URLSession 且不 invalidate
- 位置：`DramaAPI.swift:225-228`。TrustAllSessionDelegate 每请求新建，session 无 finishTasksAndInvalidate；且放弃连接复用，每个 POST 重新 TLS 握手——在「站点 WAF 对握手敏感」的背景下（AGENTS 网络节）既慢又增加被识别面。建议 DramaSession 持有一个按 target 缓存的 session，用完 invalidate。

### P2-6 refreshDownloadedSorts 在每个 objectWillChange tick 上全目录扫盘（主线程）
- 位置：`DramaNativePage.swift:40`（`.onReceive(manager.objectWillChange)`）→ `DramaPageViewModel.swift:588` → `Downloader.swift:256 downloadedEpisodeFolders` = contentsOfDirectory + 每子目录 fileExists。下载进行中进度 tick 高频触发 → 主线程反复扫盘。DownloadsViewModel 对同类问题已有「占用缓存+去抖重算」模式，此处未套用。建议对磁盘对账去抖（如 0.5s），tick 期间只读内存。

### P2-7 Profile 装配逐条 DramaCache.load ×2 的模式未推广到已修的追更
- 位置：`ProfileViewModel.swift:118-129 / 171-179 / 213-221`（history/favorite/liked 每条目 DramaCache.load 一次 + coverURL() 内可能再 load 一次）。注释自己记录了「127 部 ≈250 次 load」与 1.6s 主线程冻结；后台队列化只治了卡 UI，没治读放大。追更用一条子查询消灭了 97 次 load，同思路可做 `DramaCache.rows(forIDs:)` 一次取回。P1-2 落地时一并处理。

### P2-8 resolveDramaID 全表扫 + 逐行 sanitizeTitle，位于热路径
- 位置：`DramaCache.swift:130-165`。`SELECT site, drama_id, name FROM drama_cache ORDER BY fetched_at DESC` 全扫，每行跑一次 `DownloadEngine.sanitizeTitle` 字符串处理；被 allSorts/episodeTotal/seriesIdentity 调（选集面板打开、播放队列对账）。缓存剧目上百后可测。建议：精确名先走 `WHERE name=?`（主键外可建索引），tolerant 兜底才全扫。

### P2-9 DramaMetaHarvester 唯一强解包 `URL(string:)!`
- 位置：`DramaMetaHarvester.swift:248`。全范围（Drama+Profile）唯一 `!` 解包。site 来自用户输入解析链（DramaTarget.parse 已校验，但推荐跳转 ProfileVM 直构的 target 只重组字符串）。改 `guard let url = URL(string:)` 打日志收尾即可，与 25s 超时兜底天然契合。

### P2-10 收割器无条件向 Documents/DramaMeta 写调查文件，生产环境无门控无清理
- 位置：`DramaMetaHarvester.swift:189-205`（api_* 每次 API 捕获重写）、`:416-421`（html_* 最多 2MB/次）、`:477`（harvest_* 每轮重写，最多 5 轮）。任何用户进任何剧集页都写，无限累积（Finder 文件共享可见）。注释说明是调查数据源，但建议：①默认关，`-captureDramaMeta` 启动参数才写；②或加目录容量上限/按剧 LRU 清理。注意 AGENTS 第 22 条「排障证据别删」指的是**日志**，落盘大文件不在其列。

### P2-11 DramaCoverCache.dir 每次访问都 createDirectory；didCleanLegacyFiles 非线程安全
- 位置：`DramaCoverCache.swift:28-36, 47-49`。dir 是 computed property，每次 validLocalURL/fileURL 都走 createDirectory 系统调用；`didCleanLegacyFiles` 静态 Bool 在 Profile 后台装配队列与主线程并发读写（Swift 内存模型下是数据竞争，实践中良性）。改为 static let 目录 + 迁移时一次性建目录即可。

### P2-12 AGENTS 第 12 条简介块行号已漂移（文档债，可能误导后续改动）
- 事实：AGENTS 写「简介展开/折叠块（DramaDetailView.swift:398–625）」；当前文件 398–625 实际是「尺寸预算/屏内画布/海报层」，简介+CoreText 测量+胶囊实际在 **880–1110**（descriptionBlock:905 起，measureIntroOverflow:1063）。第 12 条是用户点名禁区，行号漂移会让后续代理去改错区块。建议改 AGENTS 行号或改为锚定符号名（`descriptionBlock` / `measureIntroOverflow`）。

### P2-13 DramaDetailView（1682 行）拆分点评估（维度⑦）
单 struct 承载 17 个 @State + 6 类区块。**禁区 880–1110（简介/CoreText/胶囊）本轮不动**（P2-12 修行号后按 AGENTS 12 仍只许改色）。可拆分块按「内聚高、耦合低、风险小」排序：
1. **Debug 样张 1626–1682**（DramaDebugFlags + DramaPreviewHost，已 #if DEBUG）→ 独立文件，零风险。
2. **错误/加载态 1533–1605**（loadingState + errorState，输入仅 vm）→ 独立 struct。
3. **档案区 1444–1533 + 推荐区 1372–1444**（只读 vm.archiveSections / vm.recommendations，几何常量随迁）→ 两个子 View。
4. **下拉刷新 587–818 + body 内手势段 213–259**（7 个专属 @State：refreshPhase/pullDistance/peakPull/holdDown/ringSpin/dotBreath/refreshToken）→ PullRefresh 子树。注意：holdDown 与 coverLayer.posterZoom(:511) 按 AGENTS 14「封面原地放大」耦合，拆分时以只读入参传 pull 值，几何阈值常量（refreshThreshold:602、refreshRevealOpacity:699）随迁不改值。
5. **内容组/选集区 1110–1372**（含 inlineBatchToolbar:1211）→ EpisodeGridSection。
拆后主文件约 700–800 行、@State 降至 ~6，均为「整体搬移不改逻辑」，与 AGENTS「不为了分层而分层」不冲突——每个块都有独立变更理由（刷新状态机、错误链路、档案数据源分别改过）。

### P2-14 DramaPageViewModel（762 行）职责宽度评估（维度⑧）
核心编排（load/revalidateIfNeeded/fetchAndCache/applyLibraryState，SWR+15 天闸门+60s TTL）内聚合理，是「页面状态唯一事实源」的正解。可抽的三块（均满足 AGENTS 9 的「第二个变更理由」检验）：
- **封面管线**（applyCover/retryCover + coverFetchInFlight/coverLocalStamp/coverReloadToken/remoteCoverURL 5 字段，:44-84、:196-210）：2026-11-15 刚因错图纠正改过一轮，变更理由独立，可抽 CoverPresenter 小结构；
- **下载阶段映射纯函数化**：downloadPhase(for:)/selectableEpisodes/queuedSorts（:246-290）只依赖 (info, downloadedSorts, manager 快照)，改静态纯函数入参后可推演（对比 EpisodePanelService 同口径实现）；
- **DEBUG 注入 injectPreviewData/injectPreviewError（:105-194，约 90 行）**：可移 #if DEBUG extension 文件，主文件减 12%。
60s TTL（lastRevalidatedAt）与 toast 令牌是编排状态，留在 VM 正确。

---

## 维度⑥评估：全静态 Service 无协议注入 vs AGENTS 第 9 条「不为了分层而分层」

**结论：当前权衡成立，不建议引入协议注入；应延续既有的「纯函数抽离」补缝。**
- 现状：7 个 Service 全是 enum/struct + 静态方法（或无状态 struct），VM 直接调具体类型，零协议。项目的测试策略是 iOS/smoke 冒烟（编译真实代码打真实 Apple 流），不是 mock 测试——静态 Service 与该策略自洽。
- 反约束适用：7 个协议 + 7 个 fake = 14 个只有测试用得到的新类型，正是 AGENTS 9 禁止的「不硬造协议」。SQLite 文件型 Service 的第二个变更理由（协议化）尚未出现。
- 真实缺口不在「协议缺失」而在**决策逻辑与 IO 缠在一起**：revalidate 的 diff 判定、downloadPhase 映射、mergedWithLocalState（DramaPageViewModel.swift:443-457，实例方法读 self.info）都只能带着真库真 manager 跑。代码库已有成熟解法——bindRecCovers（DramaMetaHarvester.swift:494-530）、DramaArchive.sections、titleKey 都是「纯函数 + 注释即规格」。按同一模式把上述三处改成纯函数，可测性缺口基本补齐，零协议成本。
- 反例警示：P1-2 正是「性能需求出现时绕开分层直接在 VM 写 SQL」——AGENTS 9 反的是过度分层，不禁止把查询放进正确的 Service 层；「少一层」不该等于「错一层」。

---

## 做得好的

1. **迁移机制完全符合 AGENTS 第 7 条**：`DramaDatabase.open()` 单入口 + user_version 单计数器 + 逐列 `PRAGMA table_info` 补列（不靠版本号判列存在）+ 旧数据搬迁用独立 UserDefaults 标记门控与 schema 版本解耦（DramaDatabase.swift:16-19, 91-97, 166-233）。版本历史注释 v1→v3 可追溯。
2. **SWR 编排精确落实 AGENTS 第 13 条**：缓存优先零等待 → 后台 fetchInfo → **本地状态归一化（mergedWithLocalState）后再 diff** → 有 diff 才落库+重绘 → 60s TTL → 失败静默保留缓存（DramaPageViewModel.swift:424-441, 459-474）。注释把「不归一化必假 diff」的因果写透。
3. **错误链路全链闭环（AGENTS 第 21 条样板）**：网络层原始事实日志（[API] POST status/type/bytes）→ `DramaError.badBody(status:contentType:bytes:snippet:)`（snippet 压空白截 200）→ `diagnostic`（DramaModels.swift:97-108）→ VM `diagnosticText`（含站点/剧 ID/时间）→ 错误态可滚动等宽详情块 + 复制按钮（DramaDetailView.swift:1542-1601）→ 静默刷新 `shortReason` 28 字摘要。每一层都有，且日志与 UI 共用一份口径。
4. **封面一致性三环节齐整（AGENTS 第 22 条）**：layoutVersion v2 目录隔离 + 旧目录一次性清理（DramaCoverCache.swift:21-27, 47-63）；收割器 per-harvest storedCoverIDs 节流但 overwrite:true 保纠错（:396-410）；applyCover 比 modifiedAt 触发 coverReloadToken 重建 AsyncImage（DramaPageViewModel.swift:52-64）。挑图主证据链（linkVideoId 排除 → 面积 → alt ×3）在 JS 侧有 fallback 与诊断串。
5. **ProfileViewModel 后台串行队列 + 代际令牌实现正确**：generation 主线程自增 → 后台全量装配 → 回主线程按代际丢弃迟到结果（ProfileViewModel.swift:56-110），与「并发与线程」第 1/4 条吻合；1.6s 主线程冻结的因果链（~250 次 load）有 Gesture gate 日志实证并写进注释。SQL 全参数绑定。
6. **Model 层纯度与命名**：DramaDetailData/DramaArchive/RecommendedDrama 纯数据无 IO；DramaTarget.parse 纯函数解析住 Shared（避免「View 为拿结构依赖接口文件」的反向依赖，DramaModels.swift:5-7 注释明说动机）；Service 层零 import SwiftUI、零 @Published、零 async（与批次硬数据一致）。

---

## 关键数据事实

- 规模：Drama/ 13 文件 6105 行；Profile/ 2 文件 581 行；合计 6414。最大 DramaDetailView 1682，次大 DramaPageViewModel 762。
- SQLite 连接：每方法自开自关（DramaCache 15 处 close、EpisodeActionsStore 11 处）；**DramaFavorites 0 处 close（3 方法）**。每剧集页 load ≈ 6 次 open/close（load/detailFetchedAt/reconcile/relatedDramas/load/rawDetail），harvest 回调再 +3。
- busy_timeout 100ms 唯一设置点 DramaDatabase.swift:41；journal_mode/WAL 全库 0 命中（默认回滚日志）；synchronous 未设。
- 索引支撑：drama_episodes 全部查询命中 PK 前缀 (site, drama_id, episode_id)，ORDER BY sort 走小结果集排序；drama_cache 无 name/fetched_at 索引，resolveDramaID 全表扫（每行一次 sanitizeTitle）。
- SQL 参数绑定：全部用户数据走 `?` 绑定；插值仅限内部常量列名（EpisodeActionsStore.writeFlag 的 liked/saved）与建表 DDL/PRAGMA 整数，无注入面。
- 强解包：范围内唯一一处 DramaMetaHarvester.swift:248（try!/as! 确认 0，与批次硬数据一致）。
- UserDefaults：DramaAPI 仅 token（第 5 条明示允许）；DramaDatabase 仅迁移门控标记；DramaFavorites/ProfileVM 无。
- 线程：ProfileViewModel.loadQueue（串行，userInitiated）+ reloadGeneration 代际丢弃；DramaCoverCache.didCleanLegacyFiles 是范围内唯一跨线程裸静态 Bool。
- 简介禁区实际位置 880–1110（descriptionBlock:905 / measureIntroOverflow:1063）；AGENTS 第 12 条所写 398–625 已漂移。
- DramaDetailView @State 17 个；区块行号：body 167–340 / 预算 362–419 / 画布 420–444 / 海报层 445–586 / 下拉刷新 587–818 / 顶栏 819–880 / 简介区 880–1110（禁区）/ 内容组 1110–1372 / 推荐 1372–1444 / 档案 1444–1533 / 错误态 1533–1605 / 配色 1605–1626 / Debug 1626–1682。

## 待证项

- P1-3 播放页实际受 preferredColorScheme 影响的程度（fullScreenCover 对环境继承 + 播放页是否读 colorScheme）：建议真机从「我的」→剧集→播放对照从下载页进入的播放页，看系统件配色。
- P2-3 的 BUSY 实际发生率：可临时把 busy_timeout 改 0 压测，或在 DramaDatabase.fail 的 BUSY 分支加计数日志观察一周。
- DownloadManager.objectWillChange 的 tick 频率（P2-6 影响面）：需读 DownloadEngine 进度上报节流逻辑（本轮只审了调用侧）。
