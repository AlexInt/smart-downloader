<!-- 本文件内容逐字搬自 AGENTS.md（2026-11-16 拆分），是对应域的完整约束。改动该域代码前必读；主文档 AGENTS.md 只保留结论索引与承重规则。 -->

# 具体约定 · 剧集详情页与「我的」页（缓存 / SWR / 简介与文本测量 / 错误透出 / 封面证据链 / 分页容器）

（编号沿用 AGENTS.md「具体约定」1–24 的全局引用）

8. **站点详情接口整包落库，不许只挑字段**：`DramaCache.saveDetail` 把响应体原文存 `drama_cache.api_detail`，另把常用字段提升为列（计数/规格/权限/催更/服务端观看进度）+ 每集元数据进 `drama_episodes` + 推荐剧进 `drama_related`。挑字段等于把没挑的永久丢掉；站点加字段时整包自动留存，只有要按该字段查询/展示才提升为列。采集时机：进页先查详情缓存新鲜度——`detail_fetched_at` 在 15 天内不重抓（用户拍板 2026-11-13，原先每次进页都抓），过期或 ↻ 刷新按钮强制重抓；封面图另有按剧集 id 的本地文件缓存（`DramaCoverCache`，15 天过期、拉取失败保留旧文件），封面/简介以详情接口为准、DOM 兜底。

13. **剧集页加载编排 = SWR（用户拍板 2026-11-13）**：进页先用缓存渲染（零等待），同时后台拉下载接口对账（`DramaPageViewModel.revalidateIfNeeded`）——失败静默保留缓存；成功先做**本地状态归一化**（downloaded/folder 并回 fresh，接口不带本地下载态，不归一化必假 diff），与内存 info 对比，**有 diff 才落库+刷新，无 diff 不写库不重绘**。同一页面实例 60s 内存 TTL 节流。WebView 详情收割不纳入 SWR（整页加载开销大，仍走 15 天闸门 + `coverMissing` 补救），↻ 刷新按钮 = force 强制重收割。别改回「缓存优先永不联网」——陈旧 playable 假拒绝下载就是这么来的。

14. **用 CoreText 量文本（简介两行溢出、行尾胶囊）两条铁律**，违反必静默错判：①**测量绝不能给 paragraphStyle 设 `.byTruncatingTail`**——CoreText 会把整段当**单行**做尾部截断（实测 `lines` 恒为 1、末行 range 覆盖全文），溢出判定永远 false，按钮直接消失；截断是渲染阶段的事，测量只看 `.byWordWrapping` 的自然换行。②**给文本容器算高度时行高要 `ceil`**——CoreText 把行高向上取整（13pt 系统字体 15.31→16），两行需要 `16×2+5=37`，手算 `15.31×2+5≈35.6` 硬编码 36 会少 1pt，SwiftUI 判定第二行放不下、**只画一行**。纵向落位同理，用 `CTFrameGetLineOrigins` 的基线差（13pt+5 行距实测 21）比"行高+行距"手算准。

20. **「我的」页四个分类是分页容器，与下载页「下载中/已下载」同一个套路**（2026-11-15 用户要求「应该与下载-已下载一样可以左右滑动」）：
   - 分类 tab 与封面墙一起放进 `TabView(selection: $vm.category)` + `.tabViewStyle(.page(indexDisplayMode: .never))`，点 tab 与左右滑是同一条 selection 通道；**别再退回「Switch 内容 + 只有 tab 能切」**。
   - **数据必须一次读全四个分类**（`ProfileViewModel.rawItems[Category]` + `items(for:)`）：四页同时在场，按需再查库会让滑到的那页先闪一下空态。`watchFilter` 的「已看完/未看完」也按分类各自索引（`finishedIndex[Category]`），别只保留一份。
   - 顶部两段（身份行 + 分类 tab + 筛选胶囊）仍走 `safeAreaInset(edge: .top)` 钉在**页面级**（不是塞进每页），否则四页各钉一份、滑动时位置还会抖。
   - 底部 `.safeAreaPadding(.bottom, MainTab.barReservedHeight + 15)` 补在**外层 VStack** 上（分页页面不接收祖先安全区，见「纸本单轨视觉」第 3 条）。
   - 回到根页（`path` 变空）时 `reload()` 一次：二级页里可能改过收藏/点赞，分类不再各自 reload，不重读会看到旧数据。
   - **reload 的装配必须在后台串行队列跑（`ProfileViewModel.loadQueue`），主线程只收结果赋 `rawItems`/`finishedIndex`**：四分类装配要对每部剧 `DramaCache.load`（历史+收藏+追更可达 127 部），曾在主线程同步装配且 `isFinished` 对每部再 load 一遍（合计 ~250 次全量 load），滑动返回的 pop 动画冻在半路 1.6s+，日志实证 `Gesture: System gesture gate timed out.` + `mainStall 1640`（2026-11-15）。别改回主线程同步装配；别把「已看完」判定改成独立二次查库（装配时顺手算，追更分类用 SQL 子查询取每剧最大 sort 集的 downloaded）；迟到结果按代际令牌丢弃。
   - 验收：模拟器点不了也滑不了，用 `-profilePreview 历史|收藏|追更|点赞` 直接落到某一页截图（Debug 专用），四页的空态/有数据态都要过一遍。

21. **接口失败必须把错误信息爆出来，不许只留系统那句「未能读取数据，因为它的格式不正确」**（2026-11-15 用户要求）：
   - `DramaAPI.apiPost` 里 `JSONSerialization` 解析失败 → 一律转成 `DramaError.badBody(status:contentType:bytes:snippet:)`，带上 **HTTP 状态 / Content-Type / 字节数 / 响应体片段**（`DramaAPI.snippet` 把空白压成单空格、截 200 字）。`errcode != 0` 走 `apiError` 时同样带 `HTTP 状态 + errcode + msg`，响应体片段进日志。
   - 剧集页错误态（`DramaDetailView.errorState`）= 一句摘要 + **可滚动的等宽详情块**（`vm.loadErrorDetail`，来自 `DramaPageViewModel.diagnosticText(for:target:)`，含站点/剧 ID/时间）+ **复制错误信息**（`UIPasteboard`）+ 重试。别再只显示一行 `localizedDescription`。
   - 下拉刷新失败（静默路径）的提示条也要带原因摘要（`shortReason(for:)`，28 字截断），不能只说「刷新失败，请稍后重试」。
   - 日志：`PLAYER_DBG [API] POST <path> status/type/bytes/error`、`[CHECK] API decode FAIL domain/code/debug`、`[CHECK] API decode body=<片段>`、`[CHECK] Entry errorDetail`（多行）。这些是排障的主证据，**不要删**。
   - 单集取直链失败同样打 `drama.diagnostic`（`SeriesDownloadCoordinator`），任务行仍显示 `localizedDescription`。

22. **封面这张图「是谁的」只能靠页面证据判，不许再按「首张大图」猜**（2026-11-15 用户实报「剧集 cover 变成推荐第一个 cover」「为你推荐里有些 cover 与卡片对不上」）：
   - **主封面 = `dramaMetaJS` 里「不在别的剧卡片里 + 可见面积最大」的那张**。判定链条：① `linkVideoId(im)` 拿图所在 `a[href*="/drama/detail/"]` 的剧 id，**指向别的剧的一律排除**（推荐/相关模块的卡片图全长这样，而主海报要么没有这层链接、要么链回本剧）；② 剩下的按 `getBoundingClientRect` 面积取最大（主海报 390×376 ≫ 推荐卡 170×226）；③ `alt` 含页面标题（= 本剧剧名）时分数 ×3。`ownId` 取不到（页面地址不带数字 id）时**不做链接排除**，退回按面积排——否则包着「链回本剧」那层 a 的主海报会被一并排除。全都排除光才 fallback 到老规则「首张 naturalWidth≥300」，日志标 `cover=fallback`。
   - **推荐封面绑 id 先看卡片文字、再看 href id**（`DramaMetaHarvester.bindRecCovers` 纯函数）：`dramaMetaJS` 除 `recCovers[vid]` 外多回一个 `recCards=[{id,text}]`（卡片可见文字：`a.innerText`；链接只包海报时往上找一层「只含 1 张图、文字 ≤40 字」的容器取，模块级多图容器直接放弃留空）；Swift 侧按 `titleKey`（去空白标点、小写）让接口剧名去匹配卡片文字（**长标题优先**，避免短标题恰好是长剧名的一部分），匹配不上才退回 href id。一张候选卡只绑一次，没绑上的打 `rec cover UNMATCHED`。
   - **不许再用「按 href id 直接落盘」当唯一路径**：站点 id 口径一变就整片串图，而卡片上的文字就是海报上印的剧名，按它对齐才是用户视角的正确。
   - **`DramaCoverCache.layoutVersion` 是提取规则的一部分**：挑图规则一改**必须递增**（现 `v2`，目录 `Caches/DramaCovers/v2`，根目录散落的旧文件首次访问时删掉）。因为 `storeImageData` 有 fresh-skip，不换目录的话错图会一直用满 15 天。
   - **收割写封面 = 每个 id 本次收割写一次，且是覆盖写**（`storeImageData(overwrite: true)` + 收割器 `storedCoverIDs` 节流）：poll 有 5 轮不能轮轮重写，但 ↻ 刷新必须能纠正旧错图。覆盖后文件 URL 没变，`AsyncImage` 不会自己重读——`applyCover` 比对 `DramaCoverCache.modifiedAt` 发现有改写就 `coverReloadToken += 1` 重建，否则用户看不到纠正结果。
   - 排障证据：`harvest round … cover=pick 1200x1600 shown:… score:… top:… blob:… big:… excl:…` / `harvest recCovers stored=N/M byTitle=X byID=Y dropped=Z cards=N` / `cover cache STORED id=… via=harvest` / `cover cache cleanup legacy v1 files=N`。**这些别删**。

## 剧集详情页是可滚动画布（搬自 HANDOFF §4.8，勿轻易推翻）

8. **剧集详情页是可滚动画布，不是固定 840**：设计稿 `.screen` 本来 `overflow-y:auto`，推荐/档案在首屏之外。缩放改按屏宽（`geo.size.width / 390`），`scaleEffect(anchor: .topLeading)` 后必须再给一层缩放后尺寸的 frame，否则 ScrollView contentSize 不对。**底部 CTA 已移除**；主屏 12 格直点（`tapEpisodeDirect`），「查看全部」是内联展开（`showAllEpisodesInline`），展开的 13+ 集走多选语义（`tapEpisode`）+ 底部工具条，两条点击路径按 `multiSelect` 分流、别合并。展开时 `pageLayout` 的 recoY 必须按 `contentBottomDesignY = 720 + extraEpisodeRows*56` 下推，否则推荐区会压住额外集。勿改回固定高度 / sheet / CTA。
9. **播放页两条有意取舍（2026-11-13 用户拍板）**：① 全屏 = 观影模式——竖屏画布的信息区/点赞收藏/上滑提示在全屏控制层 `PlayerFullscreenControlsView` 不渲染（只有顶栏返回/清屏/静音 + 底栏进度条/时间），点赞收藏回竖屏卡片操作，勿当缺失补回全屏（原 `landscapeOverlay` 路线已随包 A 退役）；② 片源方向未知（`AVPlayerItem.presentationSize` 0×0）按竖屏 fill 处理，宁可不切换也不猜方向。详见 AGENTS「iOS 架构约定」第 12 条。
