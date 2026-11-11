# HANDOFF.md — 交接文档

> 给接手的 AI 编码代理：**先读 `AGENTS.md`**（硬性禁止 + 架构/日志/网络约定，最高优先级），本文档讲「已经做了什么、还剩什么、怎么继续」。两份都读再动手。
>
> 最后更新：2026-11-11 · 分支 `main` · 基准提交见 `git log -1`

## 1. 项目一览

智能 m3u8 视频下载器，跨平台多形态（Python CLI / Streamlit / Mac App / iOS App）。**近期全部工作聚焦 iOS**（`iOS/SmartDownloader/`，Xcode 26 folder-sync 工程，新 Swift 文件放入目录即自动编译）。用户只要求维护 iOS，勿主动改 Python 侧。

iOS App 形态：WKWebView 嗅探 + Swift 下载核心 + SQLite 剧集缓存 + 本地 HLS 离线播放。核心页面：浏览（WKWebView）、下载（双 tab 横滑）、沉浸式播放页（抖音式上下滑切集）。

## 2. 当前状态（截至本次交接）

### 已就绪、经用户真机验证过的功能

| 功能 | 状态 |
|---|---|
| 剧集嗅探 → 原生剧集页 → 选集下载（含蜂窝网络 IP 直连降级） | ✅ 早期完成 |
| 下载页双 tab（下载中/已下载）横滑、创建时间排序、删除、批量编辑 | ✅ `3234c10` |
| 重复点击下载防重 | ✅ `3234c10` |
| 播放页：设计稿还原 + 真实 AVPlayer 播放、长按 2×、点按暂停 | ✅ `11664da` / `5a9dde5` |
| 全屏无黑边、可关闭、进度条带内水平 seek（±60pt） | ✅ `80d2f9d` |
| 全剧集数同步（三种真实来源，绝不造槽位）、边界 toast「已经到底了」 | ✅ `c746815` |
| UIKit 原生分页（轻滑 15% 翻页、起始定位正确、11 集双向滑动） | ✅ `78abf2d`，用户日志确认全链路 OK |
| 秒开三件套（相邻集预热池 + KVO 事件流就绪 + spinner 延迟显示） | ✅ 编译通过，**待用户真机体验确认** |
| 播放页交互细节修复批（布局收紧/静音图标/点按分区/边缘返回/倍速） | ✅ 编译通过，**待用户真机体验确认**（见下） |
| 清屏模式（隐藏界面信息只看画面，状态本地记住） | ✅ 编译通过，**待用户真机体验确认** |
| 滑动误触 2x 修复（起 2x 移到 perform，落指不再闪倍速） | ✅ 编译通过，**待用户真机体验确认**（见下） |
| 清屏下 seek 瞬态进度 HUD（拖动时进度条+时间淡入，松手 800ms 淡出） | ✅ 编译通过，**待用户真机体验确认**（见下） |
| 清屏盲操作命中带放宽 ±120（第五批） | ✅ 被第六批全屏化取代（闪现参照保留） |
| 横向 seek 全屏化：相对映射 + 左缘排除（第六批，用户拍板） | ✅ 编译通过，**待用户真机验证**（见下） |
| 清屏快滑仍闪 2x 修复（seekPan 全域起手 + .began 即翻转仲裁闸门） | ✅ 编译通过，**待用户真机体验确认**（见下） |
| 启动页（系统渐变 launch screen + SwiftUI splash logo 呼吸 1.2s 淡出） | ✅ 编译通过，**待用户真机体验确认** |
| splash 不拦截触摸 + PERF_DBG 卡顿探针（-perfLog：tabSwitch 时间戳 + 主线程 >250ms 停顿） | ✅ 编译通过，**待真机复测 tab 切换卡** |
| 剧集详情页设计稿落地（390×840 三态 / 简介展开 / 封面失败重试 / 单选 CTA / 查看全部下载面板） | ✅ 编译通过，**待用户真机体验确认**（见下） |

### 秒开优化（本次刚做，未验证细节）

背景：用户问「已下载视频为什么还要 loading」。时间线拆解：150ms 停稳防抖 + AVPlayer 固有异步管线（拉 m3u8 → 解析 → 取首段 → 解码）+ 旧代码 100ms 轮询量化误差 + spinner 全程显示，合计体感 300–500ms。三项改动：

1. **`PlaybackPlayerService` 相邻集资产预热池**：`preload(_:)` 提前对相邻集 `asset.load(.isPlayable)`（完成 m3u8 拉取解析），`makeItem` 命中池则直接构建 item（log `makeItem HIT`）。停稳播当前集时并行预热两侧；进入播放页时首集也预热（与 150ms 防抖并行）。池按需淘汰，`teardown()` 全清。
2. **`DramaPlayerViewModel` KVO 事件流**：旧 100ms 轮询删除，改为 `statusEvents(for:timeout:)`（KVO → AsyncStream，`.initial` 覆盖「观察前已 ready」的 HIT 场景，4s 看门狗，取消安全——新滑动自动终止并清理观察器；`item === player.currentItem` 防陈旧回调翻转状态）。
3. **spinner 延迟显示**：`isLoadingSlow` 只在延迟期满仍未就绪时置 true，`DramaPlayerView` 的 ProgressView 挂在它下面；视频/渐变层加 150ms easeOut 交叉淡入。初版 300ms，2026-11-11 依真机实测（HIT 就绪 642–871ms）调至 **800ms**。

验证方法（真机抓 log，见 §6）：预热生效应看到 `preload OK sort=N` → 滑动后 `makeItem HIT` → `load OK ... waitedMs=<几十>`（旧轮询是 `waited=1~3` 即 100–300ms），且滑动切集不再出现转圈。

**真机首测暴露两个 bug，已修（2026-11-11，复测日志确认生效）**：
1. **seek 非第一页全失效**：`location(in: scrollView)` 是内容坐标（含 contentOffset），未换算成屏幕坐标就喂给 `isInSeekBand`；第一页 offset=0 掩盖了问题。已在 shouldBegin / didSeekPan 减 contentOffset（log 现在同时打 screenY 与 contentY）。复测：任意页 `inBand=true`、fraction 跟手。
2. **预热池被自己的淘汰逻辑打穿（全 MISS）**：pageSettled 只报邻居为 wanted，每次滑动先把上一轮为当前集预热的资产淘汰掉再 makeItem。修复：wanted = [当前集] + 邻居（调用方 `preloadNeighbors(of:current:)` 保证）。曾试过在 service 加 `playingSort` 过滤避免重复预热，但它把「刚离开的集」也剔出 wanted——该集资产已被消费又永不重暖，**回滑必 MISS**，已删；重暖刚离开的集本来就是来回滑动的 HIT 保险（它总是新当前的邻居），代价仅一次回环 m3u8 解析。复测：正滑 / 回滑全部 `makeItem HIT`。
3. 附带修正 `waitedMs` 日志换算（`components.seconds` 只有整秒，亚秒在 attoseconds，此前 <1s 全打成 0ms）。复测：HIT 实测 642–871ms、入口 MISS 1008–1177ms。

### 长按 2x 与滑动的冲突仲裁（2026-11-11 第二批，待真机验证）

用户报告「滑动与长按 2 倍偶尔冲突」，日志实证三类，规则定为 **「先起者独占本次触摸」**：

| 冲突 | 日志实证 | 修复 |
|---|---|---|
| 慢起拖拽误触发 2x | `seekPan shouldBegin → LONGPRESS began → 2x →（拖动继续）`：长按 maxDistance=40 远大于 pan 起手阈值 ~10pt，拖拽 0.15s 内位移 <40pt 长照样识别 | ① 拖动先起 → seek 独占：pressing 起手 guard `isSeekGestureActive` |
| 按住 2x 指头漂移误 seek | 2x 保持中 `seekPan x=235 dx=27 dy=-6 → seek fraction=0.59` 位置跳变；且漂移 >40pt 时 2x 掉回 1x | ② 长按先起 → 2x 独占：`VM.seek` guard `isFastForwarding`；`maximumDistance` 40→10_000（2x 不靠位移掐断） |
| 短按 2x 快速松手误暂停 | `LONGPRESS ended → 1x → TAP → togglePlayback → pause`，之后 `beginFastForward SKIP control=0` 证明暂停生效（同一次抬手被同时认成长按结束和单击） | ③ 250ms 抑制窗（`suppressTapUntil`）+ `longPressOwnedTouch`：只有未被 seek 抢占的长按才吞松手误触（被抢占的拖动抬手不可能出单击） |

配套改动：`didSeekPan` 只在 `.changed` 寻址，`.ended/.cancelled/.failed` 只调 `endSeekGesture()`——**抬手不补 seek**（fraction 取绝对位置，最后一次 .changed 已到位；且防「松手先清 2x → .ended 的 seek 穿过闸门」竞态跳变）。`isSeekGestureActive` 为非渲染状态（故意不用 @Published），load/stop 兜底清位。

验证日志看点：拖动中只出 `LONGPRESS SKIP reason=seeking`（不再有拖动中的 `LONGPRESS began`）；按住 2x 漂移只出 `seek SKIP reason=fastForwarding`、无位置跳变、2x 不中断；2x 松手后若出 `TAP SKIP reason=justEndedLongPress` 即误触被吞；正常单击仍出 `TAP → togglePlayback`。

已知观察（用户已拍板，2026-11-11 已改）：预热 HIT 后就绪仍需 642–1177ms（m3u8 已解析，剩首段拉取+解码），300ms spinner 延迟被普遍超过 → 每次滑动都闪转圈。已把延迟提至 **800ms**：HIT 路径（642–871ms）基本无感，真正慢的入口 MISS（~1.2s）仍会短暂显示。

### 滑动误触 2x（2026-11-11 第三批，待真机验证）

用户报告「清屏后滑动、翻页轻扫会闪一下 2x 倍速」。真机日志实证：**每次触摸落下都出 `LONGPRESS began → 2x`**（含所有纵向/横向快速滑动），`playbackTime` 跳变证明 2x 真实生效。

- **根因**：`onLongPressGesture(pressing:)` 的 `pressing(true)` 在**触摸落下瞬间即回调**（先于任何位移判定），旧代码把「起 2x」放在这里，等于「落指即 2x」；`minimumDuration: 0.15` 只约束空的 `perform`，从未生效。快速滑动抬手虽早，但 2x 已起过、`pressing(false)` 又拨回 1x，形成一闪。
- **修复**（`DramaPlayerView.swift`）：起 2x 移到 `perform`（按满 0.15s 才回调）——仍 guard `isSeekGestureActive`（拖动先起 → seek 独占不变）、置 `longPressOwnedTouch`、`beginFastForward()`。`pressing` 只做收尾：`!pressing` 时 `defer` 清 `longPressOwnedTouch`，仅真正起过 2x 的触摸才 `endFastForward()` + 设 250ms 吞误触窗；未起 2x 的触摸抬手不动作、不打日志。
- **为什么快速滑动不再误触**：快速轻扫抬手早于 0.15s，`perform` 不触发；纵向滑动被分页 pan 提前取消（touchesCancelled），`perform` 也不触发。`maximumDistance: 10_000` 保留（2x 不靠位移掐断，第二批的漂移修复不回归）。
- 残余已知边界（可接受）：带外慢速横向拖拽 >0.15s 仍可能起 2x；用户报告的误触均为快速轻扫，本修复覆盖。

验证日志看点：快速滑动（翻页/清屏后轻扫）**不再出** `LONGPRESS began → 2x`；真长按按满 0.15s 出 `LONGPRESS began → 2x`、抬手出 `LONGPRESS ended → 1x`；带内拖动按满时仍出 `LONGPRESS SKIP reason=seeking`（seek 独占不变）。

### 清屏快滑仍闪 2x（2026-11-11 第五批，待真机验证）

用户复报：「清屏模式下左右滑动进度快的时候，有时突然冒出 2 倍提示」。第三批（起 2x 移进 perform）修掉了「落指即闪」，但 `isSeekGestureActive` 的置位点仍在**首个有效 `.changed`**（要求水平主导 + dx>6），留下两类空窗，0.15s 的 perform 恰好插进去起 2x：

- **带外起点**：清屏下进度带不可见，横滑起点常落在带外 → 旧 `gestureRecognizerShouldBegin` 按带内过滤返回 false，识别器直接 **fail，一个事件都收不到**，闸门永不翻转（第三批「残余已知边界」即此，用户实测高频）。
- **斜起手转水平**：带内快滑但起始位移 dy>dx（或 dx 尚未攒到 6），首个有效 .changed 晚于 0.15s → perform 先到。

修复（`PlayerPagingScrollView` / `DramaPlayerViewModel`）：

- **seekPan 全域起手**：删掉 `gestureRecognizerShouldBegin` 的带内过滤，任何触摸位移约 10pt 即 begin；`.began` 时捕获「起点是否在带内」（`seekStartInBand`，location 减 contentOffset 换算屏幕坐标），`.changed` 按它过滤——**真 seek 语义不变**（带外水平滑动仍无效果），只是仲裁事件不再丢。
- **`.began` 即调 `VM.beginSeekGesture()` 翻转 `isSeekGestureActive`**：判定点从「首个有效 .changed」提前到 recognizer 起手。快滑（10pt 远快于 0.15s）→ 闸门先翻 → perform 里 `LONGPRESS SKIP reason=seeking`；慢漂移（10pt 超过 0.15s）→ perform 先到 → 2x 照常起，起手后漂移由 `VM.seek` 的 `isFastForwarding` guard 挡住，「先起者独占」不变。
- `maximumDistance: 10_000`、250ms 吞误触窗、抬手不补 seek 等前几批修复全部不回归。

验证日志看点：清屏下快速横滑（无论起点带内带外）→ 出 `seekPan began screenY=.. startInBand=..`，若按满 0.15s 只出 `LONGPRESS SKIP reason=seeking`，**不再出 `LONGPRESS began → 2x`**；带内起点照常 `seek fraction=..`；真长按（指头基本不动）仍 `LONGPRESS began → 2x`；按住 2x 慢漂移不 seek、不掉 1x。

残余已知边界（可接受）：带外**慢速**横向拖拽 >0.15s 仍会起 2x——慢拖与「长按+慢漂移」不可区分，属「先起者独占」的固有歧义。

### 交互细节修复批（同日第二批，待真机验证）

用户报告的 8 个 bug 一次修完：

1. **底部布局收紧**：左下信息簇（账号/标题/简介/标签/音频）整体下移 44pt，进度条 y 700→744、宽 290→350（左右边距对称各 20pt），时长文字右对齐到进度条右端；进度条与「上滑观看下一集」间距 97→53pt。
2. **点赞/收藏文字居中**：文字框改为与按钮框同位同宽（中心 347），修掉右偏 10pt。
3. **静音图标**：无独立静音素材，`ic_sound` 静音时变灰 + 叠加金色 45° 斜线。
4. **点控件不再连带暂停**：点按/长按从 UIScrollView 识别器移回**卡片内 SwiftUI 手势**（`.onTapGesture` / `.onLongPressGesture(pressing:)`）——SwiftUI 深度优先解析让 Button（返回/静音/点赞/收藏）天然优先，删掉了 `isTapOnControl` 几何判定表（用户指出维护成本高：每加一个控件都要登记）。离散手势与系统分页不冲突，只有连续手势必须留在 UIKit 层。
5. **左缘右滑返回**：fullScreenCover 无系统边缘返回，`UIScreenEdgePanGestureRecognizer`（.left，与系统 pan 同时识别）拖过 50pt 即触发 `onClose`。
6. **长按 2x 提速**：`minimumPressDuration` 0.25→0.15s，提示淡入 0.15→0.1s。
7. **松手立即回 1x**：根因是 `endFastForward` 只在 `.playing` 时置 `rate=1`，缓冲等待态（`.waitingToPlayAtSpecifiedRate`）被漏掉，缓冲恢复后仍是 2x；现在只要非暂停一律拨回 `rate=1`，`beginFastForward` 也接受等待态起 2x。
8. **几何同步**：`PlayerGesturePolicy` 的 seek 带（y 684..804）与 fraction 宽度（350）已随新布局更新——**进度条再动必须同步改这两处**（AGENTS 已记）。

### 清屏下 seek 瞬态进度 HUD（2026-11-11 第四批，待真机验证）

讨论结论：清屏后进度条隐藏但 seek 带仍生效，等于**盲操作**（用户在看不见的进度带上凭记忆滑动，无任何反馈）。定案：**清屏下 seek 时进度条+时间瞬态显示**，与倍速提示同属「瞬态反馈」类，不破坏清屏「只看画面」的克制——只出进度条+时间，不出整个界面信息组；点按暂停不唤出 UI（维持抖音式纯净）。

实现（`DramaPlayerViewModel` + `DramaPlayerView`）：

- VM 新增 `@Published isScrubbing`：`seek()` 实际生效路径（过全部 guard 后）置 true 并取消旧淡出任务（拖动中每次 .changed 续命）；`endSeekGesture()` 抬手时起 800ms 停留任务后置 false；`load()`/`stop()` 立即清除（切集不留残影）。**与 `isSeekGestureActive` 严格分开**：那是手势仲裁闸门（非渲染、故意不 @Published），这是 UI 显示状态。
- View：进度条+时间从「界面信息组」拆为独立 `progressHud`，opacity 由 `isProgressVisible = !isCleanScreen || isScrubbing` 驱动，0.2s easeInOut；其余界面信息（头像/点赞/标题/字幕）清屏下继续隐藏。`PlayerGesturePolicy` / seek 带判定不动。
- 800ms 停留时长与 spinner 阈值同值（项目内「瞬态停留」统一量级），可按手感再调。

验证日志看点：清屏下拖动进度带 → `scrub show clean=1` 且进度条+时间淡入；松手 → `seekGesture end`，800ms 后 `scrub hide reason=linger800ms`；带内纵向滑动（切集）不出 `scrub show`（.changed 的水平主导 guard 先拦）；2x 按住漂移不出 `scrub show`（fastForwarding guard 先拦）。

### 清屏盲操作 seek 命中率（2026-11-11 第五批，待真机验证）

用户报告「清屏下左右滑动经常看不到进度条，也经常没有实际影响进度」。真机日志（a9e9400 构建）实证，**不是仲裁错**：带内触摸（screenY 714/719/722/725/744）全部 seek 成功、全部 LONGPRESS 被 .began 闸门正确压制（全程无一次误触 2x）。真正根因是**几何命中带太窄 + 盲按落点在带外**：

1. seek 带设计 ±60（y 684..804），402×874 机型 scale≈1.031 → 实际屏幕带 [709,833]；
2. 清屏下进度条不可见，用户盲按落点集中在 screenY 649–704 —— 整批落在带顶上方 5~60pt → `seekStartInBand=false` → `.changed` 全程不 seek、无 HUD（静默失败。带外横滑无效果是约定语义，但盲按不知道带在哪就等于不可用）。

修复（两件）：

1. **清屏命中带放宽 ±120**（设计 624..844，覆盖底部 1/4 屏幕，用户全部落点 626~720 设计值入带）：`PlayerGesturePolicy.isInSeekBand(screenY:screenSize:expanded:)`，档位由 `playback.isCleanScreen` 在 seekPan .began 处选择；普通模式 ±60 不变（进度条可见、可精确暗准）。fraction 映射不变。
2. **开启清屏闪现进度条+时间 1.5s**（`scrub show reason=cleanScreenOn` → `scrub hide reason=linger1500ms`）：给盲操作一次「带在哪」的空间参照；init 恢复清屏态时同样触发（每次进清屏播放页提示一次）。日志格式变更：`scrub show` 现在带 `reason=`（seek / cleanScreenOn），`scrub hide` 的 reason 改为 `linger800ms`/`linger1500ms`。

验证日志看点：清屏下 screenY 650~700 起手的横滑应出 `startInBand=true expanded=true` 并正常 seek+出 HUD；开清屏出 1.5s 进度条闪现；普通模式带外横滑仍静默（不回归）；2x 仲裁行为不变（闸门仍 .began 即翻转）。

### 横向 seek 全屏化：相对映射（2026-11-11 第六批，用户拍板方案 A，待真机验证）

用户发起讨论「左右滑动是否放到全屏范围」后拍板方案 A：**全屏横向拖动 = 相对 scrub**。动机：命中带几何是「清屏盲按整批静默被拒」类问题的根，第五批 ±120 只是止血；主流短剧 App 均为全屏横滑 seek，肌肉记忆已成。

- **映射**：`.began` 捕获 `playback.progress` 为基准，`.changed` 以 基准 + 位移/屏宽 连续换算（一屏宽≈全片时长，clamp 0..1），无起手跳变。命中带、`isInSeekBand`、`seekFraction`、contentOffset y 换算全部删除——`PlayerGesturePolicy` 只剩 `scrubDelta` 纯函数，手势几何与 designFrame 的同步约束消失。
- **左缘保护**：x<30 起手不 seek（`scrubBaseFraction=nil`），保留给 edgePan 返回；闸门照常翻转。
- **不变**：垂直翻页独占、水平主导 + dx>6、a9e9400 仲裁（.began 翻闸门压 2x、250ms 抑制窗、抬手不补 seek）、清屏 HUD 与开屏 1.5s 参照闪现。`VM.seek(fraction:)` 签名未动。
- 第五批的清屏 ±120 被本批取代（命中带不存在了）；闪现参照保留，第五批作为证据链保留在 git 历史。
- 日志变更：`.began` → `seekPan began x= scrubBase=`（或 `reason=leftEdgeGuard`）；`.changed` → `seekPan dx= dy= fraction= base=`；不再有 `startInBand=`/`screenY=`。

验证日志看点：任意（非左缘）位置横滑 → seek 跟手、HUD 显示；左缘起手右滑 → 只触发返回不 seek；垂直快滑仍翻页；长按 2x 与拖拽仲裁行为不变；第五批的验证点（带顶盲按）自然失效——已无带。

### 清屏模式

- 静音旁（左侧，设计稿 277,41）新增「清屏」按钮：隐藏界面信息组（字幕/左下信息区/互动栏/上滑提示/上下压暗；进度条+时间已拆出为 seek 瞬态 HUD，见上节），保留常驻控件（返回/静音/清屏/集数胶囊）与瞬态反馈（倍速/加载/错误/toast）。切换 0.2s 交叉淡入淡出。
- **集数胶囊改为紧凑「4/11」**（`DramaEpisode.compactEpisodeLabel`），56pt 宽居中（x=167），永远紧凑格式、清屏不隐藏——用户在「清屏时切换格式」与「永远紧凑」两案中选定后者（一致性更好、顶栏四元素不拥挤、无格式切换动画复杂度）。
- 状态本地记住：`PlayerPreferences.isCleanScreen`（UserDefaults "DramaPlayer.cleanScreen"），VM init 恢复，同静音模式一套机制。
- 图标为 SwiftUI 绘制（圆角矩形描边 + 激活时金色斜线），与静音图标同一视觉语言；素材库无需新增图片。
- 新按钮**零手势代码**：Button 天然优先于卡片点按（手势架构简化的直接收益）。

### tags 来源改走请求拦截（2026-11-11，待真机样本）

窗口法（长 token 定界 + 黑名单）评估后回退：堆黑名单/正则/锚点本质还是在解析渲染文本，越堆越脆。治本 = 拿 JSON 字段当数据协议，拦截网页自己调的 API 响应。playlet 接口 P7 已证明无 tags，故目标是网页另调的接口或 SSR 直出——先抓一轮样本再写定向提取，不猜字段名/选择器。

- **捕获模式**：收割器 webview 注入 `apiCaptureScript`（嗅探器同骨架 Hook XHR/fetch，扩展为连响应体回传；只捕 JSON/text 或 api/drama/playlet URL，单条 ≤200KB、总量 ≤40），落盘 `Documents/DramaMeta/api_<site>_<dramaID>.json`；主文档完整 HTML 同时落 `html_*.html`（meta keywords / class 选择器样本一次拿齐）。捕获只搬运不解析；加密信封原样落盘，原生有现成 decryptPayload 可离线解。
- **强制采集开关**：`-captureDramaMeta` 启动参数让 harvestIfNeeded 绕过头部缓存判定（已缓存剧否则不触发收割）。真机：`xcrun devicectl device process launch --console --device <id> com.firefish.smartdownloader -captureDramaMeta`，进一次剧集页，Finder 拷出 api_*/html_*。
- **定向提取（样本已确认）**：真机拷回 `api_https___yeguodj.com_3703.json`——detail 接口明文 JSON，`tags` 为结构化数组；用户构造 `DramaDetailData` Codable（swiftc 对样本实测解码 OK）。捕获回调里 `JSONDecoder` 解码 + 剧 ID 命中即 `savePageMeta`（`source=api`，不等轮询），轮次优先用 `apiDetail.tags`；锚点法 parseTags 已删除。失败分支：`apiNoTags` / `noDetailResponse`。
- handler 收尾 removeScriptMessageHandler 防循环引用；`harvest finish apiCaptures=N` 看捕获条数。
- **旧缓存自动迁移**：`page_meta.tags_source` 记来源（不加列、无迁移）；旧缓存无来源 → harvestIfNeeded 视为不全，进页自动补采一次，采成功写 `api` 后恢复缓存优先零网络。`-captureDramaMeta` 保留为调查期手动强制重采。
- **payload 还原（3445 真机实证，根因落定）**：web 端 detail 走 Nuxt `_payload.json`（devalue 扁平数组：字典值/数组元素全是顶层下标，-1=undefined），非明文对象也非加密信封。`DramaDetailData.fromNuxtPayload` 按索引递归还原、取 video_id 命中节点（相关推荐也带 video_id+tags，必须比对）；角标字段（badge/app_badge/cover_badge）站点有时直出字符串，init(from:) 双形态兼容。解码链 明文→信封→payload，成功日志 `via=plain|envelope|payload`。swiftc 对真实捕获离线实测：tags=[姐姐 姐妹 家庭 都市]、episodes=10、剧 ID 不命中返回 nil。v2 迁移每进程只 ALTER 一次。

验证看点：进剧集页出 `harvest tags source=api tags=反差 人妻 都市 大女主`（样本剧），头部与播放卡 tags 行显示同一串；无 detail 响应时 finish 打 `tags FAIL reason=noDetailResponse`。待真机回归。

### 剧集详情页设计稿落地（feat/drama-detail-page，待真机回归）

设计源：`drama-detail.html`「DramaWave · 剧集详情页三态对照原型」，屏内 390×840 固定坐标。与播放页同为一套 Design System，颜色/字体/画幅/`designFrame` 复用 `Shared/DesignTokens.swift`（第一批目录整理前在 `player/`），只在该文件补了详情页专用色（海报三色渐变、CTA 末端 #FF8A5B、占位色、tag/divider 透明度）。

| 文件 | 变更 |
|---|---|
| `Drama/DramaDetailView.swift` | 新增：屏内全部视觉 + 三态 + 交互转发；旧版 ScrollView 头部/全量 grid 删除 |
| `Drama/DramaNativePage.swift` | 瘦身为入口薄壳（依赖组装 / fullScreenCover / task / onAppear / onReceive）；收割器 / JS / Dump 已再拆到 `Drama/DramaMetaHarvester.swift` |
| `Drama/DramaPageViewModel.swift` | 新增 `selectedSort`（单选）、`isDescriptionExpanded`、`isFavorite`、`showAllEpisodes`、`toastText`、`coverReloadToken` 及派生串 `tagChips` / `hintText` / `ctaTitle`；`ensureSelection` 在库状态对账后落位默认集 |
| `Shared/DesignTokens.swift` | `DWColor` 补详情页 8 个色值 |

视觉还原：海报层（渐变 + 真实封面）/ 光晕 / 上下 scrim → 返回·收藏（视觉盒 32×32、命中区 44×44）→ 标题 24px + 3 个标签胶囊 → 简介（折叠两行 + 右端渐隐 + 「… 展开」/「收起」）→ 选集区（6×2 共 12 格，选中态 #FF5A5F）→ 固定分隔线 y758 与 CTA y772。展开只由 `--desc-shift` 54pt 驱动「简介容器高度」与「内容组 offset」，0.32s cubic-bezier(.2,.8,.2,1)，reduced-motion 归零。封面三态由 `AsyncImage` phase 驱动：loading（spinner + 文案）/ failed（图标 + 点击重试）/ ok（占位组隐藏）；重试有 URL 时换 `coverReloadToken` 让 AsyncImage 换 id 重建，无 URL 时清 `harvestedKeys` 重新收割元数据。

产品化取舍（设计稿是视觉原型，功能规范由本项目补齐）：格子改为 **radio 单选**（点格子只选中，不直接下载/播放），底部 CTA 按真实状态显示「播放第 N 集 / 下载第 N 集 / 第 N 集下载中 / 第 N 集暂不可看」并分别触发播放或单集入队；全选 / 清空 / 下载所选 / ↻ 刷新收进「查看全部 ›」sheet，下载能力不丢。收藏按 `site#dramaID` 存本地（与播放页 `PlayerPreferences` 分开）。hint 与 CTA 文案一律用真实数据（不编「每集约 2 分钟」），无 tags 时不渲染胶囊、绝不造假标签；已下载集在格子右上角加 5pt 绿点、锁定集降透明度。

验证：`swiftc -typecheck -disable-sandbox -D DEBUG -target x86_64-apple-ios26.5-simulator`（全部 29 个 Swift 文件，含 `iOS/LaunchSplashView.swift`）0 错误；`xcodebuild` 两次均被沙箱拦（`sandbox_apply` / 宏插件 `PreviewsMacros` 加载失败），属环境限制非代码错误。**待真机回归**：三态切换、封面失败重试、展开动画手感、CTA 四种状态、查看全部下载面板、返回/收藏。

### 目录与分层第一批整理（架构讨论后落地）

**先改规则再动代码**：`AGENTS.md` §目录 补「按功能域分组、域内再分层」，写明适用范围是 `iOS/SmartDownloader/` 全部文件（此前只规定 `player/` 与 `Components/`，根目录无规可依，新代码一直往根目录堆）；第 5 条改为「所有持久化统一走 Service，VM 里不得出现 `UserDefaults.standard` / `FileManager`」。不按 Model/Service/VM/View 分目录的理由：同 target 没有 import 边界，按层分不产生任何依赖约束，只会把一个功能打散到四处。

| 动作 | 内容 |
|---|---|
| 新建 `Shared/` | `DramaModels.swift`（从 `DramaAPI.swift` 抽出 `DramaTarget` / `ApiDramaEpisode` / `DramaInfo` / `DramaError`，解除 View 为拿数据结构而依赖接口文件的概念反向依赖）、`DramaFavorites.swift`（收藏持久化，key 前缀沿用旧值不丢数据）、`DesignTokens.swift`（从 `player/` 提升为全局设计系统） |
| 新建 `Drama/` | 剧集域 6 个文件 `git mv` 归位；`DramaMetaHarvester.swift` 从 `DramaNativePage.swift` 逐字拆出（收割器 / `dramaMetaJS` / `DramaMetaDump`），入口只剩薄壳 |
| VM 收口 | `DramaPageViewModel` 删掉 `UserDefaults.standard` 与 `favoriteKey(for:)`，改持有 `DramaFavorites` |

工程侧零改动：folder-sync 只有一个 `PBXFileSystemSynchronizedRootGroup`（`path = SmartDownloader`），子目录递归自动参与编译，`git mv` 即可；`Info.plist` 与 `iOS/LaunchSplashView.swift` 保持原位（前者被 `INFOPLIST_FILE` 写死、后者是显式 `PBXBuildFile`）。

**第二批未做**：`Downloads/`（Downloader / VM / View）、`Browser/`（BrowserView + 拆出 WebViewStore / 嗅探 JS）、`Infra/`（LocalMediaServer / WebKitFetcher）、`Shared/DownloadModels.swift`（TaskState / DownloadError）。`DramaCache.swift` 里的 `extension DramaInfo { init?(entry:) }` 是缓存行→领域模型的转换，暂留 Service 文件，记为后续清理项。

## 3. `player/` 模块架构地图（MVVM + Service）

依赖方向：**View → ViewModel → Service → 系统/Model**，单向不可反向；组装根只做 DI。

| 文件 | 层 | 职责 |
|---|---|---|
| `PlaybackModels.swift` | Model | `PlayableEpisode` / `ImmersivePlaybackRequest` / `PlaybackDirection`，纯数据 |
| `DramaEpisode.swift` | Model | 卡片展示模型（设计稿文案/预览值） |
| `PlaybackQueueService.swift` | Service | **上下滑资源调度唯一入口**：全剧集数三来源、槽位构建、history 回溯栈、`resolveNext/resolvePrevious`（推荐算法接入点）、`neighbors(of:)`（预热目标，走同一接入点） |
| `PlaybackPlayerService.swift` | Service | 唯一常驻 `AVPlayer`、`makeItem`（含预热池 HIT/MISS）、`preload` / `clear` / `teardown` |
| `PlayerPreferences.swift` | Service | 静音/点赞/收藏持久化（UserDefaults 封装） |
| `PlayerGesturePolicy.swift` | Service | 纯函数几何判定（seek 带内/进度比例，390×840 设计坐标 ↔ 屏幕坐标） |
| `DramaPlayerViewModel.swift` | ViewModel | 单集播放状态机：load（KVO 事件流）、isReady/isLoadingSlow、seek、倍速、时间进度 |
| `PlayerFeedViewModel.swift` | ViewModel | 分页数据源、当前页、停稳后切源 + 相邻集预热触发、边界 toast；组装 `DramaPlayerViewModel` |
| `PlayerFeedView.swift` | View | 分页容器（SwiftUI 侧）：`.task(id:)` 150ms 停稳防抖 |
| `PlayerPagingScrollView.swift` | View | **UIKit `UIScrollView.isPagingEnabled` + `UIHostingController` 卡片**；点按/长按/seekPan 识别器都挂这里 |
| `DramaPlayerView.swift` | View | 单张卡片（390×840 设计稿逐节点映射，**卡片内零连续手势**） |
| `PlayerSurfaceView.swift` | View | `AVPlayerLayer` 包装 |
| `DramaPlayerContainer.swift` | 组装根 | fullScreenCover 入口，configure + onDisappear stop |
| `Components/ToastView.swift` | 全局组件 | 全局 toast，不依赖业务/坐标系 |

## 4. 关键设计决策（勿轻易推翻）

1. **分页用 UIKit `UIScrollView.isPagingEnabled`**。SwiftUI `ScrollView + .scrollTargetBehavior(.paging)` 与卡片 GeometryReader/手势冲突，四轮排障完全滑不动，已弃用（AGENTS 有记录，**勿改回**）。轻滑翻页靠 `scrollViewWillEndDragging` 里 15% 位移或 0.3 速度阈值。
2. **卡片内禁止任何连续手势**（包括局部 DragGesture）——曾因进度带局部 DragGesture 吃掉全部纵向滑动。所有交互用 UIKit 识别器挂分页 ScrollView 上，`cancelsTouchesInView = false`，seekPan 与系统 pan 同时识别、只在「起点在进度带 ±60pt + 水平主导」时 begin。
3. **单播放器常驻**，切集只 `replaceCurrentItem`，禁止滑动时新建 AVPlayer。秒开靠预热池三件套（§2），不是多 player pool。
4. **集数绝不造假**：来源优先级 = 调用方 knownSorts → SQLite `DramaCache.allSorts` → 磁盘已下载兜底。没有元数据时只有 1 集就不能滑，toast「已经到底了」，不造空槽位。
5. **推荐算法接入点**：只改 `PlaybackQueueService.resolveNext/resolvePrevious`（可读 slots/history/current，返回任意槽位即换序）。`neighbors(of:)` 也走它们，预热自动跟随新序。
6. **诊断日志**：`PLAYER_DBG` 前缀 + `[CHECK]` 断言行（带输入与判定）；失败分支必须有 log；排障后保留不清理（约定全文见 AGENTS.md）。

### 架构债务清偿（2026-11-11，评估报告执行）

对照 AGENTS iOS 架构约定的全面评估报告，其全部问题按批准计划清偿：

| 项 | 内容 | 提交 |
|---|---|---|
| P1-P3 | 删 VM 多余 SwiftUI import / endToastShown 复位 / player 契约 API 注释 | `bbfba18` |
| P4 | 相邻卡片状态隔离：进度/时间/点赞/收藏/静音/清屏按 isActive；HUD 可见性与 2x 胶囊收尾 | `0ad7361` + `7337126` |
| P5 | 停稳在未下载集时 toast 引导「第N集尚未下载 · 回剧集页下载后可看」（不改 resolve 语义） | `5abcc8f` |
| P6 | harvest 结果落盘 Documents/DramaMeta/harvest_<site>_<dramaID>.json（Finder 可拷，tags/作者字段调查数据源）；DRAMAMETA-DOM 双份 NSLog 收敛为单行摘要 | `f322e0f` |
| P8 | **DramaNativePage 拆 DramaPageViewModel**：业务状态（loading/info/downloadedSorts/selected/fromCache/coverURL/intro/playbackRequest）与编排（缓存优先加载/选集下载/播放入口/收割触发）全部入 VM；View 只渲染+转发意图；harvester/JS/Dump 工具随迁独立文件；BrowserView.swift 935→482 行 | 本提交 |
| P9 | 浏览页下载入口锁（isSubmitting）与 beginDownload 编排并入 WebViewStore（@MainActor），View 只剩渲染派生 | `7727353` |
| P10 | **DownloadsView 拆 DownloadsViewModel**：编辑模式/勾选/批量删除/整剧删除确认/排序偏好持久化与两个区域派生列表全部入 VM；SeriesDetailView/TaskRow/PlayerView 不动 | 本提交 |
| P7 | **真实 tags 接入**（已定案：tags 在剧集页 DOM「催更/播放」之间，作者名不存在）：harvester 解析 tags 入缓存（drama_cache 新增 tags 列 + v2 迁移）；剧集页头部补 tags 行；tags 经 ImmersivePlaybackRequest → PlaybackQueueService → DramaEpisode.local 透传到播放卡片（无标签时回落占位文案） | 本提交 |
| P11 | 真机回归（用户） | 待办 |

**P11 真机回归清单**（P8/P9/P10 均为行为不变的纯重构，重点验行为等价；⑤ 是新功能 P7）：① 剧集页全链路：点剧集→原生页渲染→选集下载（排队态/幂等）→已下载 ▶ 播放→↻ 合并新集；② 下载页：双 tab 横滑、排序切换（重进 App 后保留）、编辑模式全选/整剧勾选/批量删除、左滑删任务/删整剧确认；③ 浏览页：下载按钮连点不重复入队、单链接已在队列态、Picker 逐条禁用；④ 播放页：上下滑切集、秒开无转圈、长按 2x、清屏 + 清屏下任意位置横滑 seek、邻卡不显示当前集时间/点赞/2x 胶囊、未下载集 toast 引导、边缘返回；⑤ **P7 tags 链路**：旧版 App 数据升级后不崩（`drama_cache` 自动加 tags 列，原有剧名/集数/下载标记不丢）→ 进剧集页触发收割、从 Finder 拷出 `Documents/DramaMeta/harvest_*.json` 确认 text 含「催更…播放」→ 头部显示真实标签（样本期望「反差 都市 OL」）→ 点已下载集进播放页，卡片 tags 行显示同一标签；从「下载」页入口播放（无元数据）回落「离线播放 · 本地 HLS」；若某次收割没解析到 tags，缓存列保持 NULL（不是空串），重启 App 后应能再次收割（`DramaMetaHarvester.harvestedKeys` 仅进程内去重，同次运行内重进页不重试）。

## 5. 待办清单（按优先级）

| # | 事项 | 说明 | 优先级 |
|---|---|---|---|
| 1 | **用户真机确认秒开体验 + 架构清偿回归** | 秒开三件套 + 交互修复批 + 清屏 seek 全屏化 + 架构清偿（P4/P5/P8/P9/P10）全部过了编译，需一次真机回归（清单见「架构债务清偿」小节末尾） | 高（验证） |
| 2 | 相邻卡片首帧海报 | 相邻页现在是渐变占位；可做首帧缓存（AVAssetImageGenerator）+ 磁盘缓存，更接近抖音观感。预热池里的 asset 可直接复用 | 中 |
| 3 | ~~非当前卡片的状态显示隔离~~ | ✅ 已完成（`0ad7361` + `7337126`）：进度/时间/点赞/收藏/静音/清屏显示与按钮全部按 isActive 隔离，邻卡回落稿面值 | 已完成 |
| 4 | ~~未下载占位页拦截~~ | ✅ 已完成（`5abcc8f`）：停稳在未下载集时 toast「第N集尚未下载 · 回剧集页下载后可看」，占位卡内联提示保留 | 已完成 |
| 5 | 本地推荐算法 | 接入点已留好（见 §4.5），算法本身未实现 | 按需 |
| 6 | 「长按 2x 中途继续上滑切集」手势竞争 | 离散手势回卡片后未真机验证该组合；若出现长按后滑不动，调 maximumDistance 或该手势回 UIKit | 低（观察项） |
| 7 | ~~tags 定向提取（请求拦截）~~ | ✅ 已完成：detail 接口明文 tags + DramaDetailData 解码落库（source=api），锚点法删除；待真机回归 | 已完成 |
| 8 | **剧集详情页设计稿真机回归** | 三态 / 展开动画 / 封面重试 / CTA 四态 / 查看全部下载面板 / 收藏，清单见 §2 末节 | 高（验证） |
| 9 | 第二批目录迁移 | `Downloads/` / `Browser/` / `Infra/`，并从 `BrowserView.swift` 拆出 `WebViewStore`、从 `Downloader.swift` 抽出 `DownloadModels.swift`；按域分批 commit | 中 |

## 6. 验证与调试

```bash
# 编译（不启动模拟器，无签名）
xcodebuild -project iOS/SmartDownloader.xcodeproj -scheme SmartDownloader \
  -destination 'generic/platform=iOS Simulator' build

# 真机日志（用户自己跑，代理只看 log）
xcrun devicectl device process launch --console --device <id> com.firefish.smartdownloader
```

- 排障一律**先加 log 再请用户提供 log**，靠日志判读，不靠猜测改代码（这是本项目的协作模式，用户会贴 log）。
- 秒开链路关键 log 行：`preload OK` / `preload EVICT` / `makeItem HIT|MISS` / `load OK ... waitedMs=` / `spinner show`（出现即说明 800ms 未就绪）/ `status STALE`。
- 交互链路关键 log 行：`TAP → togglePlayback` / `LONGPRESS began|ended → 2x|1x` / `edgePan dx=.. > 50 → back` / `scrub show|hide`（清屏瞬态进度 HUD）。
- 冒烟工具（macOS，不需手机）：`iOS/smoke/` 下 coretest / playtest 等，编译命令见 AGENTS.md。

## 7. 硬性禁止（全文见 AGENTS.md，此处摘要）

- **禁止对浏览页 / WKWebView 截图**（测试、验证、演示都不行）；验证只看 log。
- 禁止启动模拟器跑 UI（编译可以）；用户明确杀过一次。
- 不 push；提交 = 中文 message + feat/fix/refactor/docs 前缀，每个任务完成即 commit。
- 只关注 iOS，勿动 Python 侧。
- 站点地址不硬编码进通用模块；Info.plist 的 folder-sync 排除规则勿破坏。

## 8. 维护本文档

每完成一个任务：更新 §2 状态表 / §5 待办清单，并在提交里带上本文档的变更。改架构约定改 `AGENTS.md`，改进度状态改本文档。
