# HANDOFF.md — 交接文档

> 给接手的 AI 编码代理：**先读 `AGENTS.md`**（硬性禁止 + 架构/日志/网络/并发约定，最高优先级）。本文只讲「做到哪了 / 还剩什么 / 怎么验」。**实现细节与防回归约束在 AGENTS 与代码注释里，完整过程在 git 历史**，本文不重复每个 build 日志。
> 
> 最后更新：2026-11-16 · 全部「待真机验证」挂账销账（30 个验证点 82 处，用户逐一确认通过）· `feat/drama-page-paper` 已合并至 `main`，后续修复直接在 `main` 上提交 · 基准提交见 `git log -1`

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

## 3. `player/` 模块架构地图

→ 已并入 `docs/agents/conventions-player.md` 顶部（改 player/ 前读那一个文件即可）。

## 4. 关键设计决策

→ 已并入 AGENTS「具体约定」各条与 `docs/agents/conventions-*.md`：原 1–7 与 AGENTS 重复（分页 UIKit / 禁连续手势 / 单播放器 / ZStack 保活 / 日志），4.8 进 `conventions-drama-profile.md`，4.9 进 `conventions-player.md`。此处不再重复维护。

## 5. 待办清单（按优先级，2026-11-16 同步）

| # | 事项 | 优先级 |
|---|---|---|
| 1 | **审查第一批止血**（iOS-REVIEW.md）：P0 下载引擎静态 Set/Dict 加锁 + DramaFavorites 连接泄漏 + seek 闸门泄漏一行 + `0$` 倍速文案 + `detailFetchedAt` 双 close + 搬迁失败不删源键 | 高 |
| 2 | **手势 A 档**（行业基线已核，不推翻拍板）：拖动中不实时 seek（松手才 seek）+ 目标时间跟随浮层；横屏竖滑 = 左亮度右音量 + 亮度死钮接真 | 高 |
| 3 | 手势 B 档待拍板：竖屏全屏按钮（推翻「无按钮入口」）、edgePan 改交互式跟随（推翻「越阈即退」） | 中（等用户拍板） |
| 4 | 审查第二批：追更 SQL 下沉 DramaCache、删 ProfileView `preferredColorScheme`、prune 合批改队列、playIfDone 下沉、「已看完」口径统一、同集去重冒烟固化入库、DWUIColor 镜像 | 中 |
| 5 | 三机型快照首跑（SE 上播放页 0.79 缩放与详情页安全区表现，AGENTS「布局缩放与机型适配」第 3 条） | 中 |
| 6 | 播放器视图壳 UIKit 化包 B：竖屏卡片 UIKit 化（**DramaPlayerView 是用户文件，等用户发起**；VM/Service 零改动路线已在包 A 验证） | 中（依赖用户） |
| 7 | 中期：无障碍第一遍（标签/命中区）、SQLite WAL+withConnection、千行文件拆分、AGENTS 简介块行号改锚定符号名 | 低 |
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
