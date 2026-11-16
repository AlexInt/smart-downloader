<!-- 本文件内容逐字搬自 AGENTS.md（2026-11-16 拆分），是对应域的完整约束。改动该域代码前必读；主文档 AGENTS.md 只保留结论索引与承重规则。 -->

# 具体约定 · 浏览域与下载域（广告清理滚动锁 / 滚动收起联动 / 年龄门 / 同集去重）

（编号沿用 AGENTS.md「具体约定」1–24 的全局引用）

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

24. **同一部剧的同一集只允许有一条记录**（2026-11-15 用户实报「下载的里面有两个同名文件，但只有一个可以播」）：
   - 成因有三条，三条都在这次堵掉了：
     ① **失败后重试**会新建一条同名任务（旧的 `.failed` 已结束，`queuedEpisodeSorts` 不再拦它）→ `manager.tasks` 里并列两条「第01集」，点旧的那条 `playIfDone` 因 `state != .done` 直接不播；
     ② **`refreshLibrary` 只清 `isFromLibrary`**，会话里正在下/刚下完的任务还在，再扫一遍磁盘又补一条同名同目录记录；
     ③ **重下同一集**会在剧目录里并出「第01集」+「第01集(1)」两个目录（`uniqueFolderName` 只给目录加后缀），列表两条、播放却只能落到其中一份。
   - 规则：`DownloadManager.pruneSupersededAttempts(series:sort:keeper:)` 按**集号**（不是标题）收口，登记新尝试与落盘成功两处调用；`keeper` 为 done 时摘掉该集其余已结束记录，`keeper` 仍在下载时只摘已结束**且非 done** 的旧尝试（重下失败也不能丢掉能播的那份）。只摘列表条目、不动磁盘。
   - 目录层面：`DownloadEngine` 保存时对**选集**先删掉同集号的旧目录再落新目录（切片此时已全在 tempDir，替换窗口只有 move 那几毫秒），不再生成 `(1)`；`loadLibrary` 对同集号目录去重，`downloadEpisodeFolders` 与它共用 `DownloadManager.preferredEpisodeFolder`（**无后缀的「第NN集」优先**，否则取最新创建的一份）——列表与播放必须落到同一份，否则就是「点 A 播 B」。散装条目不参与去重（同名不同目录是两条不同视频）。
   - 验收：**回归网 = `iOS/smoke/deduptest.swift`**（审查 P1-⑭ 固化入库，2026-11-16；此前冒烟只在排障会话跑过、源码不在仓库不可复现）。编译与运行（`SMARTDOWNLOADER_DIR` 指到 fixture 根，`DownloadEngine.downloadsDir` 会重定向过去）：
     ```bash
     cd iOS/smoke && swiftc -O -o deduptest deduptest.swift \
       ../SmartDownloader/Shared/DownloadModels.swift ../SmartDownloader/Shared/DramaModels.swift \
       ../SmartDownloader/Shared/PlaybackProgress.swift ../SmartDownloader/Downloads/Downloader.swift \
       ../SmartDownloader/Drama/DramaCache.swift ../SmartDownloader/Drama/DramaDatabase.swift \
       ../SmartDownloader/Drama/DramaDetailData.swift ../SmartDownloader/Drama/EpisodeActionsStore.swift \
       ../SmartDownloader/Drama/RecommendedDrama.swift <DramaCoverCache 桩> \
       ../SmartDownloader/Infra/WebKitFetcher.swift
     SMARTDOWNLOADER_DIR="$PWD/out/dedup-fixture" ./deduptest   # 5 断言 PASS/FAIL 逐条打印
     ```
     覆盖「同集双目录只列一条 / 播放目录与列表一致（preferredEpisodeFolder 两侧共用）/ 重试摘旧（含不夺走能播的 done）/ 落盘后只留一条 / 散装不去重」；改 `pruneSupersededAttempts` / `loadLibrary` / `preferredEpisodeFolder` / `registerEpisode` 后必须重跑。模拟器看列表用 `-downloadsSeries <剧名>` 直接推入剧详情（点不了卡片），磁盘造 `第01集` + `第01集(1)` 时详情页只应有一行。
