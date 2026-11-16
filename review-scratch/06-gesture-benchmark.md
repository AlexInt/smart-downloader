# 06 · 播放器手势交互行业基线（手势 × 方案矩阵）

- 调查日期：2026-11-16。用途：为播放器横竖屏手势审查提供客观行业基线。
- 分工：本文件只查外部资料；本项目代码现状由主 agent 自行核实后对照（本文件不含对项目代码的现状断言）。
- 覆盖对象：① ZFPlayer（开源 iOS 播放器）② SJVideoPlayer / SJBaseVideoPlayer（开源 iOS 播放器）③ 抖音竖屏沉浸流 ④ B站官方说明 + 爱奇艺/优酷/腾讯视频等横屏长视频惯例 ⑤ YouTube 移动端。
- 证据分级标注：
  - **[S1] 一手代码**：GitHub 源码 / 头文件摘录（最高可信）。
  - **[S2] 官方文档**：开源库官方 Wiki、B站官方专栏（官方口径）。
  - **[S3] 二手分析**：产品分析 / 媒体报道 / 问答（采信前已核对来源与日期，仅作行业惯例佐证）。
- 未见官方说明的负向结论（如"某 App 无某手势"）一律标注为低置信，不与正向结论混写。

---

## 0. 速览矩阵

| 手势维度 | ZFPlayer | SJVideoPlayer | 抖音（竖屏沉浸流） | B站 | 爱优腾（横屏长视频惯例） | YouTube 移动端 |
|---|---|---|---|---|---|---|
| 单击 | 控制层显隐 [S1] | 控制层显隐 [S2] | 暂停/继续 [S3] | 控制层显隐（横屏惯例）[S2][S3] | 控制层显隐 [S3] | 控制层显隐（未找到官方页，低置信） |
| 双击 | 播放/暂停 [S1] | 播放/暂停 [S2] | 点赞 [S3] | 播放/暂停 [S2] | 多为暂停/播放（低置信） | 左半屏−10s / 右半屏+10s（可调）[S3] |
| 横滑 seek 映射 | **拖动增量** [S1] | 增量（由控制层实现）[S2] | 无横滑 seek（左右滑=切 tab）[S3] | 增量（沿用通用方案）[S3] | **拖动增量**，方向与拖拽滑块一致 [S3] | 拖动+按住增量 [S3]；进度条红点=手指位置 [S3] |
| seek 实时反馈 | 中央浮层：预览图+目标时间+简化进度条，松手才 seek [S1] | 控制层代理自行实现（默认 demo 显示快进/快退提示）[S2] | — | 简化进度条+时间（类同爱奇艺）[S3] | 腾讯：关键帧预览小窗+时间；爱奇艺/搜狐：简化进度条+时间 [S3] | 顶部提示条+缩略图预览 [S3] |
| 竖滑·横屏/长视频 | 左半屏=亮度，右半屏=音量 [S1][S3] | 左边=亮度，右边=音量（带提示视图）[S2] | —（竖屏流无此手势） | 左侧上下滑=亮度，右侧上下滑=音量 [S2] | **右侧=音量、左侧=亮度，"已成通用的解决方案"** [S3] | 无（未见来源，低置信） |
| 竖滑·竖屏沉浸流 | —（列表滚动即切视频，ZFPlayer 有列表播放方案） | — | **上滑=下一个视频** [S3] | 竖屏模式上下滑切视频（Story 模式，未找到官方页，低置信） | — | Shorts 上下滑切换（未找到官方页，低置信） |
| 长按倍速 | 仅有回调挂钩，默认控制层**空实现** [S1] | 官方功能；**默认手势集不含长按**，需显式开启；`rateWhenLongPressGestureTriggered=2.0` [S2] | 长按=2 倍速（官方合集页）/长按弹菜单 [S2][S3] | 2021-02 时未上线长按倍速，后有更新 [S3] | 爱奇艺 3 倍（任意位置）、优酷 3 倍、腾讯左退右进 3 倍 [S3] | 无长按倍速（低置信） |
| 全屏进出 | 点击全屏按钮触发；`ZFFullScreenMode`：横屏片源=旋转 / 竖屏片源=竖屏全屏 / Automatic=按片源自动选 [S1] | 点击全屏按钮触发；横屏片源=rotation，竖屏片源=fitOnScreen 撑满**不旋转**；默认"自动选择" [S2] | 未深查 | 全屏按钮；设置—播放设置含锁屏等开关 [S2] | 点击竖屏右下角屏幕切换按钮进横屏；横屏返回=退出横屏 [S3] | 全屏按钮（未深查） |
| 重力自动旋转 | `allowOrentitaionRotation` 默认 YES（可关）[S1] | 自动旋转默认开启，`rotationManager.disabledAutorotation` 可关 [S2] | — | —（各家设置内有重力开关，未逐一取证） | — | Android 有自动旋转设置（未取证） |
| 锁定 | `lockedScreen` 属性（锁定屏幕方向）[S1] | `lockedScreen`（锁屏时状态栏不显示）[S2] | 未深查 | 截图/GIF/锁屏功能可开关 [S2] | 芒果TV/爱奇艺/搜狐：播放器左侧锁屏按钮，锁定后其余按钮不可点 [S3] | 未深查 |
| 左缘滑动语义 | 手势枚举**无 edge pan**（一手负证据）；返回=按钮 | 未找到公开可引来源（v3 边缘侧滑**待证**，见 §4） | 左右滑=切顶部 tab [S3] | — | 横屏返回按钮=退出横屏 [S3] | 双击左右半屏被 seek 占用，非返回 |

---

## 1. 逐项明细（含出处与关键摘录）

### 1.1 单击

- **ZFPlayer [S1]**：单击回调转给控制层；默认控制层 `gestureSingleTapped` 在 `controlViewAppeared` 时隐藏、否则显示控制层，控制层显示后 2.5s 自动隐藏（`autoHiddenTimeInterval = 2.5`）。
  - 出处：https://github.com/renzifeng/ZFPlayer/blob/master/ZFPlayer/Classes/Core/ZFPlayerControlView.m （`gestureSingleTapped:`、`autoFadeOutControlView`、`self.autoHiddenTimeInterval = 2.5`）
- **SJVideoPlayer [S2]**：官方 Wiki「Documents §10.1 单击手势」："当用户单击播放器时, 播放器会调用 显示或隐藏控制层的操作"，默认实现即 `switchAppearState`。另有 `pausedToKeepAppearState`（暂停时是否保持控制层显示，默认 NO）。
  - 出处：https://github.com/changsanjiang/SJVideoPlayer/wiki/Documents
- **抖音 [S3]**："抖音的单击触发暂停短视频播放，双击触发点赞"；单击是"快击"——按住过久会触发更多操作浮层而非暂停。
  - 出处：https://zhuanlan.zhihu.com/p/451923182 （§1.1、§2.4 案例段）
- **B站 [S2]**：官方专栏移动端手势清单未列单击；横屏轻击显隐控制层属行业通识（[S3] 佐证：https://www.woshipm.com/ucd/574256.html §1.2 "轻击操作可在两个状态间切换"）。
- **爱优腾 [S3]**：导航栏/工具栏"显示状态、临时隐藏状态，轻击操作可在两个状态间切换"。
  - 出处：https://www.woshipm.com/ucd/574256.html §1.2
- **YouTube**：单击显隐控制层为通识，但本次未检索到官方帮助页（检索引擎多次 0 命中），低置信。

### 1.2 双击

- **ZFPlayer [S1]**：`gestureDoubleTapped:` → `playOrPause`（横竖屏两套控制层同逻辑）。
  - 出处：https://github.com/renzifeng/ZFPlayer/blob/master/ZFPlayer/Classes/Core/ZFPlayerControlView.m
- **SJVideoPlayer [S2]**：Wiki §10.2："双击会触发暂停或播放的操作"，默认实现 `if playing → pause else play`。
  - 出处：https://github.com/changsanjiang/SJVideoPlayer/wiki/Documents
- **B站 [S2]**：官方专栏："视频暂停/播放：单指双击屏幕，可切换暂停/播放"。
  - 出处：https://www.bilibili.com/read/cv118811 （移动端·单指手势解锁）
- **YouTube [S3]**："Simply double-tap the left or right side of the video, and you will skip ahead or back 10-seconds"；默认 10s，可在 设置→General→"Double-Tap to Seek"（iOS 名"Skip Forward and Back"）调整档位。
  - 出处：https://www.howtogeek.com/751238/how-to-change-youtubes-double-tap-skip-time （2021-09）
- **抖音 [S3]**：双击 = 点赞（出处同 1.1 知乎文）。
- **爱奇艺/优酷/腾讯 [S3]**：双击暂停/播放为常见配置，本次未逐家取证，低置信（长按倍速竞品分析文未覆盖双击）。

### 1.3 横滑 seek：映射方式（本次审查核心问题一）

**结论：全行业（开源库 + 商业 App + YouTube）横滑 seek 均为「拖动增量」映射，没有任何一家采用「手指位置=进度」；「手指位置=进度」只存在于进度条（slider/红点）拖拽。**

- **ZFPlayer [S1]**：源码即映射公式——
  ```
  /// 每次滑动需要叠加时间
  self.sumTime += velocity.x / 200;
  ...
  [self sliderValueChangingValue:self.sumTime/totalMovieDuration isForward:style];
  ```
  松手时 `gestureEndedPan` 才调用 `seekToTime:`（拖动过程中不改播放位置）。
  - 出处：https://github.com/renzifeng/ZFPlayer/blob/master/ZFPlayer/Classes/Core/ZFPlayerControlView.m （`gestureChangedPan:...withVelocity:` H 分支、`gestureEndedPan:`）
- **SJVideoPlayer [S2]**：Wiki §10.3："水平滑动时, 会触发控制层相应的代理方法"——seek 的具体映射由控制层实现（官方 wiki 不锁死公式），默认 demo 控制层按增量显示快进/快退提示。
  - 出处：https://github.com/changsanjiang/SJVideoPlayer/wiki/Documents
- **爱优腾 [S3]**："所有app都做了可以替代拖拽滑块操作手势，那就是手指的左右滑动，滑动方向与拖拽滑块的方向一致，保持了很一致的映射关系"——即以拖动位移换算进度增量，而非绝对落点。
  - 出处：https://www.woshipm.com/ucd/574256.html §2.5 左右滑动手势
- **YouTube [S3]**："drag-and-hold"：`tapping-and-holding anywhere on the video screen and sliding left or right to rewind or skip`（按住后横滑，增量 scrub），这是增量映射的直接佐证；另一条路径"先点出进度条，再拖红点"才是绝对位置映射。
  - 出处：https://www.gadgets360.com/apps/news/youtube-slide-to-seek-drag-and-hold-gesture-video-skip-android-ios-reddit-2506315 （2021-08-09）
- **抖音 [S3]**：横滑被顶部 tab（同城/关注/推荐）占用，无横滑 seek。
  - 出处：https://www.woshipm.com/ucd/4317868.html （"左右滑动是切换顶部的三个tab"）

### 1.4 横滑 seek：实时反馈形式

- **ZFPlayer [S1]**：中央 140×80 浮层 `fastView` = 预览图（`fastImageView`）+ 目标时间（`fastTimeLabel`）+ 简化进度（`fastProgressView`）；即"预览图 + 目标时间 + 微型进度条"三件套。
  - 出处：同 1.3 ZFPlayerControlView.m（`addAllSubViews` 与 `layoutSubviews` 中 fastView 相关段）
- **爱优腾 [S3]**：腾讯"拖拽滑块时……播放器上还有个小窗显示了拖拽位置的关键帧画面"；爱奇艺/搜狐在全屏隐藏栏时"显示一个简化样式的进度条来替代滑轨"供评估拖动幅度。
  - 出处：https://www.woshipm.com/ucd/574256.html §2.4、§2.5
- **YouTube [S3]**：拖动 scrub 时顶部出现 "Slide left or right to seek" 提示条，并显示所跳过内容的缩略图（thumbnail of the contents being skipped）。
  - 出处：https://www.gadgets360.com/apps/news/youtube-slide-to-seek-drag-and-hold-gesture-video-skip-android-ios-reddit-2506315
- **SJVideoPlayer [S2]**：反馈形式由控制层决定，官方 Wiki 未写死（见 1.3）。

### 1.5 竖滑分区：横屏/长视频（本次审查核心问题二）

**结论：横屏（长视频形态）下竖滑 = 亮度/音量左右分区，不承担切集；切集（切视频）只在竖屏沉浸流形态里由竖滑承担。**

- **ZFPlayer [S1]**：`gestureChangedPan` V 分支——`ZFPanLocationLeft → 调节亮度`、`ZFPanLocationRight → 调节声音`（亮度直接写 `UIScreen mainScreen.brightness`，音量走 MPVolumeView 系统音量）；手势枚举 `ZFPanLocation` 只有 Left/Right 两值。
  - 出处：https://github.com/renzifeng/ZFPlayer/blob/master/ZFPlayer/Classes/Core/ZFPlayerControlView.m 与 https://github.com/renzifeng/ZFPlayer/blob/master/ZFPlayer/Classes/Core/ZFPlayerGestureControl.h
- **SJVideoPlayer [S2]**：Wiki §10.3 原文："垂直滑动时, 默认情况下如果在屏幕左边, 则会触发调整亮度的操作, 并显示亮度提示视图. 如果在屏幕右边, 则会触发调整声音的操作, 并显示系统音量提示视图"。
  - 出处：https://github.com/changsanjiang/SJVideoPlayer/wiki/Documents
- **B站 [S2]**：官方专栏："调节屏幕亮度：单指在播放器左侧上下滑动……调节音量：单指在播放器右侧上下滑动"。
  - 出处：https://www.bilibili.com/read/cv118811
- **爱优腾 [S3]**："在播放器右侧上下滑动来调节音量，在左侧调节亮度，已经成了通用的解决方案"（并给出人体工学解释：音量高频放右手舒适区，亮度低频放偏僻区）。
  - 出处：https://www.woshipm.com/ucd/574256.html §2.5 音量调节和亮度调节
- **注意**：横屏竖滑切集在以上所有来源中均未出现——横屏形态下竖滑从不承担"下一集"。
  - 出处（负向，覆盖上述四条）。

### 1.6 竖滑：竖屏沉浸流（切视频）

- **抖音 [S3]**："上滑查看下一个视频"是抖音的核心手势；左右滑让位给顶部 tab 切换（同城/关注/推荐）。文章还论证了为何高频的"看下一个"应该用门槛最低的上滑。
  - 出处：https://www.woshipm.com/ucd/4317868.html （2020-12）
- **B站竖屏模式（低置信）**：B站后期竖屏 Story 模式上下滑切视频，本次未找到官方说明页，列为低置信。
- **YouTube Shorts（低置信）**：上下滑切换短视频为通识，未找到官方页。

### 1.7 长按倍速

- **ZFPlayer [S1]**：手势枚举含 LongPress 且回调转给控制层，但默认控制层实现为**空**：
  ```
  - (void)longPressed:(ZFPlayerGestureControl *)gestureControl state:(ZFLongPressGestureRecognizerState)state {
  }
  ```
  即 ZFPlayer 默认不带长按倍速，只留挂钩。
  - 出处：https://github.com/renzifeng/ZFPlayer/blob/master/ZFPlayer/Classes/Core/ZFPlayerControlView.m
- **SJVideoPlayer [S2]**：官方 Wiki「长按快进」：需显式开启 `_player.gestureControl.supportedGestureTypes |= SJPlayerGestureTypeMask_LongPress`，触发速率 `_player.rateWhenLongPressGestureTriggered = 2.0`；且默认手势集 `SJPlayerGestureTypeMask_Default` **不含** LongPress（只有 SingleTap/DoubleTap/Pan/Pinch）。
  - 出处：https://github.com/changsanjiang/SJVideoPlayer/wiki/%E9%95%BF%E6%8C%89%E5%BF%AB%E8%BF%9B 及 https://github.com/changsanjiang/SJVideoPlayer/wiki/Documents （§10.5 枚举）
- **抖音 [S2][S3]**：长按 = 2 倍速播放（抖音官方话题合集页收录相关教程："长按视频左侧或右侧，就可以二倍速播放了"）；同时知乎手势分析指出长按（按住超过阈值）触发"更多操作浮层"。
  - 出处：https://www.douyin.com/zhuanti/7206038820071131173 、https://www.douyin.com/zhuanti/7208145640893843513 、https://zhuanlan.zhihu.com/p/451923182 §2.4
- **爱优腾 [S3]**：竞品分析（2021-02）：爱奇艺"长按快进 2 倍优化为长按快进 3 倍，长按屏幕任意位置均可触发"；优酷与爱奇艺相似（3 倍）；腾讯视频"长按屏幕左侧快退，长按屏幕右侧快进，速度均为 3 倍速"（左右热区以白色遮罩范围为准）；B站彼时尚未上线。松手后默认恢复常速。
  - 出处：https://zoej-zhang.github.io/post/bilibili-ai-qi-yi-you-ku-teng-xun-shi-pin-chang-an-bei-su-bo-fang-jing-pin-fen-xi （2021-02-05）
- **要点**：长按倍速是商业 App 的后发功能；开源播放器要么空实现（ZF）要么默认关闭（SJ）。用户认知里"长按=倍速"来自抖音/爱优腾，不来自开源库默认行为。

### 1.8 全屏进出方式（本次审查核心问题三）

**结论：行业基线是「按钮触发为主」，重力/自动旋转只是辅助通道；且两个开源库都做了"横屏片源才旋转、竖屏片源只撑满不旋转"的自动选择。**

- **ZFPlayer [S1]**：
  - API：`enterFullScreen:animated:completion:` / `rotateToOrientation:animated:`（按钮调它）；
  - `ZFFullScreenMode`：Landscape=旋转全屏 / Portrait=竖屏全屏 / **Automatic=按片源宽高自动选**——源码 `presentationSizeChanged` 回调里：`size.width > size.height ? Landscape : Portrait`；
  - `allowOrentitaionRotation` 默认 YES（自动旋转随设备方向，可关）；`lockedScreen` 锁定屏幕方向。
  - 出处：https://github.com/renzifeng/ZFPlayer/blob/master/ZFPlayer/Classes/Core/ZFPlayerController.h 与 .../ZFPlayerController.m
- **SJVideoPlayer [S2]**：Wiki「旋转横屏和竖屏全屏」原文："当播放竖屏拍摄的视频时(Width < Height), 在**点击全屏按钮之后**, 选择竖屏全屏(fitOnScreen)而不触发旋转. 当播放横屏拍摄的视频时(Width > Height), 在点击全屏按钮之后, 选择横屏旋转(rotation)"；"默认为自动选择"；自动旋转默认开启，`rotationManager.disabledAutorotation` 可关。
  - 出处：https://github.com/changsanjiang/SJVideoPlayer/wiki/%E6%97%8B%E8%BD%AC%E6%A8%AA%E5%B1%8F%E5%92%8C%E7%AB%96%E5%B1%8F%E5%85%A8%E5%B1%8F
- **爱优腾 [S3]**："点击竖屏模式右下角的屏幕切换按钮，播放器进入横屏模式"；横屏里"去掉了切换横竖屏按钮，点击返回就是退出横屏"（返回按钮=唯一出口）。
  - 出处：https://www.woshipm.com/ucd/574256.html §2.0、§2.1
- **B站 [S2]**：全屏按钮 + 全屏后右上角弹出播放设置（含倍速/播放方式等）；锁屏等功能开关在 设置—播放设置。
  - 出处：https://www.bilibili.com/read/cv118811
- **抖音/YouTube**：本次未深查其全屏入口来源，留待证。

### 1.9 锁定

- **ZFPlayer [S1]**：`lockedScreen`（"Lock the screen orientation"），全屏播放可锁定屏幕方向（README 功能句亦见 [S3] 转述：https://github.com/Taylor0101/ZFPlayer-1 ）。
- **SJVideoPlayer [S2]**：`lockedScreen`——"锁屏时, 不显示"状态栏（Documents §13.4 `vc_prefersStatusBarHidden`）。
  - 出处：https://github.com/changsanjiang/SJVideoPlayer/wiki/Documents
- **B站 [S2]**：截图、GIF 录制、锁屏功能可在 设置—播放设置 中开关。
  - 出处：https://www.bilibili.com/read/cv118811
- **爱优腾 [S3]**："芒果TV、爱奇艺和搜狐视频都在播放器的左侧放置了锁屏按钮。锁屏之后，无法点击其它功能按钮"——锁屏 = 隐藏全部控制、只留解锁入口。
  - 出处：https://www.woshipm.com/ucd/574256.html §2.9
- **共同语义**：锁定发生在"全屏/沉浸"场景，锁定后仅保留解锁按钮，任何其它触摸不触发功能。

### 1.10 左缘滑动语义 / 返回

- **ZFPlayer [S1]**：手势枚举只有 SingleTap/DoubleTap/Pan/Pinch（+LongPress），**没有边缘手势**；退出全屏走左上角返回按钮。一手负证据：https://github.com/renzifeng/ZFPlayer/blob/master/ZFPlayer/Classes/Core/ZFPlayerGestureControl.h
- **SJVideoPlayer**：v3 有内置边缘侧滑返回的说法（社区普遍认知），但本次公开检索（GitHub 页面、搜索引擎）未能取到可引用的一手来源，**列为待证**（查法见 §4）。
- **爱优腾 [S3]**：横屏退出 = 左上角返回按钮；iOS 系统级"左缘右滑返回"负责页面间返回。
  - 出处：https://www.woshipm.com/ucd/574256.html §2.1
- **YouTube [S3]**：左右半屏被双击 seek 占用（howtogeek，同 1.2），边缘语义让位于 seek。
- **抖音 [S3]**：左右滑 = 切顶部 tab（woshipm 4317868），不做边缘返回。

---

## 2. 三个专项问题的直接回答

1. **横滑 seek 是「手指位置=进度」还是「拖动增量」？**
   —— **拖动增量**。ZFPlayer 源码公式 `sumTime += velocity.x / 200`（每 200px 速度增量 ≈ 1s，[S1]）；爱优腾"滑动方向与拖拽滑块的方向一致"[S3]；YouTube 按住+横滑 scrub [S3]。「手指位置=进度」仅出现在进度条控件（slider/红点）拖拽，与画布横滑是两条并存路径（YouTube 两者都有：按住拖=增量，点出进度条拖红点=绝对）。

2. **横屏下竖滑是亮度音量还是切集？**
   —— **横屏/长视频形态：竖滑 = 左亮度右音量**（ZFPlayer/SJ 开源默认 [S1][S2]、B站官方 [S2]、爱优腾"通用解决方案" [S3]）。**切集只属于竖屏沉浸流**（抖音上滑切视频 [S3]）。两套形态不混用：没有任何来源显示横屏竖滑切集，也没有来源显示竖屏沉浸流竖滑调亮度。

3. **全屏进入是按钮还是纯重力？**
   —— **按钮为主，重力辅助**。两个开源库的文档/源码全部写"点击全屏按钮之后"触发旋转或撑满（[S1][S2]）；爱优腾是竖屏右下角屏幕切换按钮（[S3]）；重力自动旋转是默认开启但可关闭的辅助通道（SJ `disabledAutorotation`、ZF `allowOrentitaionRotation` 默认 YES）。未见任何主流方案把"纯重力、无按钮"作为唯一全屏入口。此外两者共同点：**按片源宽高自动选**——横屏片源旋转、竖屏片源撑满不旋转（ZF `ZFFullScreenModeAutomatic` [S1]、SJ "自动选择"默认 [S2]）。

---

## 3. 供主 agent 对照的基线检查单（不含项目现状断言）

对照时建议逐条问"项目行为处于行业基线的哪一侧"：

1. 横滑 seek 是否为增量映射（拖动位移 → 时间增量），而非"手指 x = 进度"；进度条拖拽才用绝对位置。
2. 横滑中实时反馈是否含「目标时间」（行业三件套：目标时间 / 简化进度 / 预览图，最低配是目标时间+微进度条）。
3. 松手才生效（ZF：拖动中不改播放位置，`gestureEndedPan` 才 seek；YouTube 按住拖完松手跳转）。
4. 横屏竖滑语义：行业=亮度/音量分区；若横屏竖滑被赋予其它语义，属偏离基线（需有明确理由）。
5. 竖屏沉浸流竖滑=切换内容；单击=播放控制（抖音）而非显隐（与长视频形态相反，形态决定语义）。
6. 双击语义：播放器内=暂停/播放（开源+B站），短视频流=点赞，YouTube=±10s——三种并存，选哪种都"有出处"，但混用需自洽。
7. 长按倍速：SJ 需显式开启、ZF 默认空实现——开源库默认行为不支持"长按倍速是标配"的说法；做长按倍速时参照商业 App 细节（松手恢复常速、热区避开边缘功能、震动反馈可关——竞品分析四要点）。
8. 全屏入口必须有按钮（基线无一例外）；重力只作辅助；竖屏片源全屏=撑满不旋转是开源库共同默认。
9. 锁定：全屏场景标配，锁定后只留解锁按钮，其余触摸无效（连点按暂停也应被吞）。
10. 控制层自动隐藏时长：ZF 默认 2.5s；SJ 用定时器一定间隔后隐藏——秒级量级，行业无 10s 级常显惯例（除暂停态可选常显：SJ `pausedToKeepAppearState` 默认 NO）。

---

## 4. 待证项（未定位，附建议查法）

| 待证项 | 现状 | 建议查法 |
|---|---|---|
| SJVideoPlayer v3 内置边缘侧滑返回（SJEdgePanGestureRecognizer） | 未找到可引用一手来源 | 本地 `git clone` SJVideoPlayer 旧 tag 后 grep `SJEdgePanGestureRecognizer`；或 GitHub 网页登录态 code search |
| YouTube 单击显隐 / 全屏下滑退出 / 锁定手势 | web_search 多轮 0 命中官方帮助页 | 直接抓 support.google.com/youtube 帮助目录；或抓 howtogeek "YouTube gestures" 系列姊妹篇 |
| 抖音横屏片源全屏进入方式（按钮 vs 自动） | 未深查 | 找抖音官方帮助或近期交互拆解文 |
| B站横屏左右滑快进官方说明 | cv118811 未提及；以爱优腾惯例 + 通用认知覆盖 | 查 B站客户端更新日志 / 帮助中心 |
| ZFPlayer「中文说明」README 原链 | 未定位文件名 | GitHub 仓库内搜 `中文说明` 锚点目标（不影响结论：源码证据已覆盖） |
| 抖音/YouTube 无亮度音量手势（负向结论） | 仅由"所有手势汇总均未提及"间接支撑 | 若需坐实，抓官方帮助页逐条核对 |

## 5. 来源清单

一手代码 [S1]：
- https://github.com/renzifeng/ZFPlayer/blob/master/ZFPlayer/Classes/Core/ZFPlayerGestureControl.h
- https://github.com/renzifeng/ZFPlayer/blob/master/ZFPlayer/Classes/Core/ZFPlayerController.h
- https://github.com/renzifeng/ZFPlayer/blob/master/ZFPlayer/Classes/Core/ZFPlayerController.m
- https://github.com/renzifeng/ZFPlayer/blob/master/ZFPlayer/Classes/Core/ZFPlayerControlView.m（手势默认行为主证据）
- https://github.com/renzifeng/ZFPlayer/tree/master/ZFPlayer/Classes/ControlView（控制层文件清单：ZFPortraitControlView / ZFLandScapeControlView / ZFVolumeBrightnessView）

官方文档 [S2]：
- https://github.com/changsanjiang/SJVideoPlayer/wiki/Documents（§5 亮度音量、§10 手势、§13.4 lockedScreen）
- https://github.com/changsanjiang/SJVideoPlayer/wiki/%E9%95%BF%E6%8C%89%E5%BF%AB%E8%BF%9B（长按快进）
- https://github.com/changsanjiang/SJVideoPlayer/wiki/%E6%97%8B%E8%BD%AC%E6%A8%AA%E5%B1%8F%E5%92%8C%E7%AB%96%E5%B1%8F%E5%85%A8%E5%B1%8F（rotation / fitOnScreen / 自动选择）
- https://github.com/changsanjiang/SJVideoPlayer（README：旋转配置）
- https://www.bilibili.com/read/cv118811（B站官方专栏：移动端手势清单）
- https://www.douyin.com/zhuanti/7206038820071131173 、https://www.douyin.com/zhuanti/7208145640893843513（抖音话题合集：长按 2 倍速；弱官方来源）

二手分析 [S3]：
- https://www.woshipm.com/ucd/574256.html（4 款视频 App 交互浅析：横滑 seek、亮度音量通用方案、锁屏、返回=退出横屏；2017-01）
- https://www.woshipm.com/ucd/4317868.html（抖音为何上滑：上下滑切视频、左右滑切 tab；2020-12）
- https://zhuanlan.zhihu.com/p/451923182（交互手势全解析·点击类：抖音单击暂停/双击点赞/长按浮层、B站长按一键三连）
- https://zhuanlan.zhihu.com/p/615884998（ZFPlayer 剖析：功能清单、左侧亮度右侧音量、左右滑进度；2023-03）
- https://zoej-zhang.github.io/post/bilibili-ai-qi-yi-you-ku-teng-xun-shi-pin-chang-an-bei-su-bo-fang-jing-pin-fen-xi（长按倍速竞品分析：爱优腾 2-3 倍、腾讯左退右进；2021-02）
- https://www.howtogeek.com/751238/how-to-change-youtubes-double-tap-skip-time（YouTube 双击 ±10s 与时长设置；2021-09）
- https://www.gadgets360.com/apps/news/youtube-slide-to-seek-drag-and-hold-gesture-video-skip-android-ios-reddit-2506315（YouTube drag-and-hold scrub + 缩略图；2021-08-09）
- https://github.com/Taylor0101/ZFPlayer-1（ZFPlayer README 功能句转述："上下滑动调节音量、屏幕亮度，左右滑动调节播放进度"，与源码一致）
