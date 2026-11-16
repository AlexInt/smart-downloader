# Smart Downloader iOS

iPhone App（最低 iOS 26）：内嵌浏览器打开视频资源网页，自动嗅探 m3u8，一键下载到沙盒，下载列表点击即播。

## 一、真机跑通步骤（开发手机）

1. 双击 `iOS/SmartDownloader.xcodeproj` 打开（需 Xcode 26+）
2. 选中 SmartDownloader target → **Signing & Capabilities** → Team 选你的 Apple ID（免费账号即可）
   - 如提示 bundle id 冲突，把 `com.firefish.smartdownloader` 改成唯一值
3. 数据线连接 iPhone → Xcode 顶部设备栏选中你的手机 → **⌘R**
4. 首次运行需在手机上：**设置 → 通用 → VPN与设备管理 → 信任开发者证书**
5. 免费账号签名 **7 天过期**，过期后重新 ⌘R 即可

## 二、使用方法

1. 「浏览」页下次启动时优先加载「设置 → 浏览页快捷站点」的默认站点（从没手动选过时自动用列表第一项）；点行右侧圆圈可改选或取消，取消后才恢复上次访问页（首次为空白起始页，地址栏输入视频资源站点即可）；在网页里正常登录、点开剧集播放。**页面自带的广告弹窗/推广浮层会被自动清理**（广告类名词表 + 空浮层启发式，含 SPA 路由切换），日志锚点 `BROWSER: adClean removed <tag.class> via <规则>`
2. 播放后底部「**下载视频 (n)**」按钮亮起（嗅探到的 m3u8 实时累积；多个时可点击选择）
3. **选集下载**：首页点击剧集卡片 → 路由到**原生剧集页**（内嵌网页打开剧集页，主页停留不变）并自动弹出选集面板：
   grid 展示全集，点击集号选中（可全选/多选），已下载集打绿勾、点 ▶ 直接播放（文件系统就是账本，无数据库），
   付费锁定集灰显带锁；「下载所选」一次排队下载（同时最多 2 集），每集下载前重调站点接口取新鲜直链；
   关掉面板可用页内「**选集**」按钮重开；页内点击其它剧集会继续推入新的原生剧集页。
   剧集信息与每集下载状态存本地 SQLite（Documents/drama_cache.sqlite3）：第二次打开同剧集直接读本地零网络请求，
   右上角 ↻ 刷新拉新集（已下载标记保留），页内刷新/删除/收编后自动对账同步
4. 点「下载」页看进度（多集调度最多 2 集并行，每集内部 6 并发切片）；下载页按剧分组：
   正在下载 / 剧集（点进二级页看集列表）/ 散装条目；剧详情页点集即播、左滑删单集、右上角删全剧
5. 点击已完成条目**直接播放**；左滑删除（同时删除沙盒文件）
6. 播放页（沉浸式）：上下滑切集；**播完自动连播下一集**（末集播完停在末帧，点按不从头重播——重看拖进度条回带）；横屏片源稳定转横自动全屏；左缘右滑返回；末页再往滑一次提示「已经到底了」
7. 文件位置：App 沙盒 `Documents/Downloads/`。选集下载按剧分目录：`Downloads/<剧名>/第NN集/playlist.m3u8`；
   散装下载仍是 `Downloads/<标题>/`。已开启文件共享，iPhone 连 Mac 时 Finder 左侧可看到并拷出

## 三、架构

```
「浏览」页
  WKWebView 加载视频资源站点 (cookie 共享, 登录态/付费内容自动解锁)
  ├ 注入嗅探 JS (atDocumentStart): Hook XHR/fetch + performance 历史 + video/source DOM 扫描
  │     → window.webkit.messageHandlers 回传 m3u8 → 按钮激活
  ├ 注入广告清理 JS (atDocumentStart): 广告类名/id 词表直删 + 空浮层启发式(2s 门槛)
  │     + MutationObserver 兜 SPA 路由切换 → messageHandlers.adClean 回传日志
  └ 点击剧集链接/SPA 路由检测 (/drama/(video|detail)/<ID>) → 推入原生剧集页（内嵌 webview 打开剧集页）
        选集面板: DramaAPI 登录 → playlet 接口 → AES-128-CBC 解密 → 剧名 + 全集列表
        （账号/AES 常量从随包 video_auto.py 解析, 不硬编码；站点地址从 URL 推导）
「下载」DownloadEngine (Swift 版 M3U8Downloader)
  拉清单(多级选最高码率) → 预取 AES-128 密钥 → 6 并发切片下载(重试/Range/解密)
  → 保存为「本地 HLS 文件夹」: playlist.m3u8(重写,去 KEY 行) + seg_*.ts(+init.mp4)
  选集下载由 SeriesDownloadCoordinator 调度: 每集下载前重调接口取新鲜 auth_key, 最多 2 集并行
  URLSession 被掐(连接层错误)时自动降级 WebKitFetcher(WKDownload, Safari 同源 TLS 栈,
  经由浏览页那个附加在视图树上的 WKWebView 发起——隐藏 webview 在真机上会直接 DownloadFailed)
「播放」LocalMediaServer (127.0.0.1 回环 HTTP) + AVPlayer 原生 HLS
  沉浸式播放页: UIKit 原生分页上下滑切集(停稳防抖后切 item) + 播完自动连播下一集
  + 横屏片源 CoreMotion 判稳自动全屏(锁竖屏 + 视频层搬运容器 transform 自转, 系统永不旋转)
```

**为什么播放要绕本地 HTTP 服务**：AVFoundation 无法直接播文件版 m3u8，也无法播裸 TS 合并文件（iOS 上没有 ffmpeg）。本地回环 HTTP + 重写播放列表是 iOS 离线 HLS 的标准做法；切片下载时已解密，播放列表去掉了 KEY 行。

与 Python 版同源能力：AES-128 解密（缺省 IV 按 media sequence 规范推导）、多级列表（最多 3 层）、`EXT-X-BYTERANGE`（含缺省 offset 接续）、fMP4 init 段、同名加 (1) 后缀。切片失败即任务失败，不做缺洞合并。Python 侧下载核心已全量同步这些能力与 IP 直连降级（2026-11-14，见根目录 README）。

## 四、已知限制（MVP）

- **仅前台下载**：切后台 App 被挂起会中断任务（后续可上 background URLSession）
- 无断点续传、无取消按钮
- 不导出单文件 MP4（TS→MP4 重封装需要 ffmpeg；如需 AirDrop 单文件，后续再加）
- 签名 URL 有时效：嗅探到后尽快点下载
- **WAF TLS 指纹拦截（已自动兜底）**：部分视频资源站点的 WAF 按客户端 TLS 握手特征掐非浏览器连接，URLSession 在部分真机网络下握手即被 RST（报 `-1200` TLS错误导致安全连接失败）。App 内置 WebKitFetcher 兜底：连接层错误时自动改走 WKDownload（与浏览页同源的 Safari TLS 栈，已被实测证明可过 WAF），成功后进程内 sticky 不再回头。失败信息会附带视频源域名便于定位。
- **蜂窝网络按域名（SNI）拦截 → IP 直连绕过（已实测解决）**：5G 蜂窝网络下 CDN 会在 TLS 握手期按 ClientHello 里的 SNI 域名直接 RST，此时 URLSession、WKWebView 乃至网页内视频全部失败（客户端指纹伪装无效）。App 对此内置 IP 直连：域名解析成 IP 后直接连 IP（URL 用 IP 时 TLS 不携带 SNI），`Host` 头回填原域名供 CDN 路由，证书不匹配由 TrustAll 兜底；成功则该域名进程内 sticky 走 IP。降级顺序：URLSession → IP 直连 → WebKit 兜底。
- 安全按「个人使用」标准：信任所有证书 + ATS 全放行（用户已确认此取舍）

## 五、冒烟测试（Mac 上验证核心，不需手机）

```bash
cd iOS/smoke

# 目录整理后按域拆分，冒烟工具要显式列出依赖的 Swift 文件：
# - Shared/DownloadModels.swift（TaskState / DownloadError，三条命令都要，漏列报找不到类型）
# - coretest 额外需要 Shared/DramaModels.swift + Drama/DramaCache.swift（--library 会测剧集缓存）

# 1. 下载核心: 真实下载 Apple bipbop 测试流(BYTERANGE+多码率), 产出 out/smoke_test/ 本地 HLS 文件夹
swiftc -O -o coretest main.swift ../SmartDownloader/Shared/DownloadModels.swift ../SmartDownloader/Shared/DramaModels.swift ../SmartDownloader/Downloads/Downloader.swift ../SmartDownloader/Drama/DramaCache.swift ../SmartDownloader/Infra/WebKitFetcher.swift
SMARTDOWNLOADER_DIR="$PWD/out" ./coretest
# 期望: RESULT: DONE -> .../out/smoke_test/playlist.m3u8
# 加 SMARTDOWNLOADER_FORCE_WEBKIT=1 强制走 WebKit 兜底通道，验证 WKDownload 链路

# 1b. 两级库扫描: 空目录造 剧/集/散装/残缺结构, 验证分组与「已下载集」检测
rm -rf out/library_check
SMARTDOWNLOADER_DIR="$PWD/out/library_check" ./coretest --library
# 期望: LIBRARY: series_eps=["第01集", "第02集"] / standalone=2 / downloadedSorts=[1, 2] → RESULT: DONE
#       收编后 series_eps 含 第03集(1)、downloaded=[1, 2, 3] → RESULT: DONE

# 2. 播放验证: 启动内置本地服务, AVPlayer 实际播放并确认进度推进
swiftc -O -o playtest playtest.swift ../SmartDownloader/Infra/LocalMediaServer.swift ../SmartDownloader/Shared/DownloadModels.swift ../SmartDownloader/Downloads/Downloader.swift ../SmartDownloader/Infra/WebKitFetcher.swift
SMARTDOWNLOADER_DIR="$PWD/out" ./playtest out/smoke_test
# 期望: RESULT: PLAYING currentTime=1.xx s

# 3. 站点连通诊断: 用 App 同款 URLSession 栈测任意 URL（--browser 加 Safari 头）
swiftc -O -o fetchtest fetchtest.swift
./fetchtest "<任意URL>" --browser

# 4. 真实剧集端到端: 用 App 同款栈调站点接口取新鲜 m3u8(站点地址从剧集页 URL 解析), 再交给 coretest 下载
swiftc -O -o videocli videocli.swift ../SmartDownloader/Shared/DownloadModels.swift ../SmartDownloader/Downloads/Downloader.swift ../SmartDownloader/Infra/WebKitFetcher.swift
./videocli "<剧集页URL>"    # 输出 M3U8: <url>
SMARTDOWNLOADER_DIR="$PWD/out" ./coretest "<该url>" ep1

# 5. App 嗅探链路(可选): 临时把 BrowserView 默认起始页(about:blank)改为 http://127.0.0.1:8899/test.html,
#    运行 `python3 -m http.server 8899` 后在模拟器跑 App, 按钮应亮起「下载视频 (1)」

# 6. 真机蜂窝网络自动验证(需数据线连 iPhone): 传 -autoTestDownload 参数启动即自动下载,
#    状态 print 到控制台。用于验证 WAF TLS 拦截下 URLSession→WebKit 降级链路是否真的可用
xcrun devicectl device install app --device <设备ID> <DerivedData .../Debug-iphoneos/SmartDownloader.app>
xcrun devicectl device process launch --console --device <设备ID> com.firefish.smartdownloader -autoTestDownload "<新鲜m3u8地址>"
# 期望: DL[...]: 尝试 WebKit 兜底… → DL[...]: ✅ WebKit 兜底成功 → AUTOTEST RESULT: DONE
```

## 六、文件结构

```text
iOS/
├── SmartDownloader.xcodeproj       # Xcode 26 工程（folder-sync：目录内文件自动参与编译）
├── SmartDownloader/                # App 源码（9 个功能域 + 全局组件）
│   ├── App.swift                   # 入口 + 自定义 tab bar + 主线程卡顿探针
│   ├── Info.plist                  # ATS 放行 / 文件共享 / 横竖屏
│   ├── Media.xcassets              # 资源目录（App Icon sd.png 1024）
│   ├── video_auto.py               # → 仓库根的 symlink（DramaAPI 解析账号/AES 常量用）
│   ├── Shared/                     # 跨域纯数据 + 设计系统
│   │   ├── DramaModels.swift       #   DramaTarget/MediaIdentity/ApiDramaEpisode/DramaInfo/DramaError
│   │   ├── DownloadModels.swift    #   TaskState/DownloadError
│   │   ├── DesignTokens.swift      #   DWColor/DWFont/DWLayout/designFrame（纸本视觉 token）
│   │   ├── PaperGlyphs.swift       #   纸本轨 1pt 线稿图元库
│   │   ├── MainTab.swift           #   tab 条目与顺序唯一来源
│   │   ├── QuickLink.swift         #   快捷站点模型
│   │   └── PlaybackProgress.swift  #   播放进度纯数据
│   ├── Components/                 # 全局通用 UI（不依赖业务域）
│   │   ├── PosterGrid.swift        #   纸本海报卡+网格（详情推荐/我的/下载页三处共用）
│   │   └── ToastView.swift         #   通用 toast
│   ├── Drama/                      # 剧集域（详情页 + 站点数据）
│   │   ├── DramaAPI.swift          #   站点接口（详情/下载链接，含加密参数）
│   │   ├── DramaDetailData.swift   #   详情响应 DTO 整包
│   │   ├── RecommendedDrama.swift  #   推荐卡片纯数据
│   │   ├── DramaArchive.swift      #   详情「档案区」展示行派生（纯函数）
│   │   ├── DramaDatabase.swift     #   SQLite 统一连接与迁移（WAL）
│   │   ├── DramaCache.swift        #   drama_cache/drama_related 缓存读写 + 批量读
│   │   ├── EpisodeActionsStore.swift   # episode_actions 集级行为数据（点赞/收藏/播放进度）
│   │   ├── DramaFavorites.swift    #   drama_favorites 剧级收藏
│   │   ├── DramaCoverCache.swift   #   封面本地缓存（密文 CDN → WebView 解密落盘）
│   │   ├── DramaMetaHarvester.swift#   收割 WebView（封面解密/推荐/简介/tags 采集）
│   │   ├── DramaPageViewModel.swift#   详情页 VM（SWR 缓存优先编排 + 下载阶段映射）
│   │   ├── DramaDetailView.swift   #   详情页主体（海报/简介/下拉刷新，1134 行）
│   │   ├── DramaDetailEpisodeGrid.swift # 选集网格 + 批量下载工具条
│   │   ├── DramaDetailSections.swift    # 为你推荐 + 剧集档案区
│   │   ├── DramaDetailStates.swift      # 加载/错误态
│   │   ├── DramaDetailPreview.swift     # Debug 样张入口（#if DEBUG）
│   │   └── DramaNativePage.swift   #   浏览页推入的原生剧集页组装根
│   ├── Downloads/                  # 下载域（纸本轨自绘界面）
│   │   ├── Downloader.swift        #   下载核心：6 并发切片/AES 解密/同集去重/磁盘账本
│   │   ├── DownloadsViewModel.swift#   列表 VM（磁盘占用缓存/封面后台解析）
│   │   ├── PlaybackProgressViewModel.swift # 播放进度列表 VM
│   │   ├── DownloadsView.swift     #   下载页（双 tab/排序/批量编辑）
│   │   ├── DiskUsageService.swift  #   磁盘占用计算（三级缓存增量重算）
│   │   └── DownloadsSortPreferences.swift # 排序偏好持久化
│   ├── Browser/                    # 浏览域（WKWebView + 注入 JS）
│   │   ├── BrowserView.swift       #   浏览页 + WebViewContainer（嗅探注册/底部工具条）
│   │   ├── WebViewStore.swift      #   浏览页 VM（导航/剧集链接检测路由）
│   │   ├── BrowserStartPage.swift  #   起始页决策（默认站点 > 上次访问页）
│   │   ├── SnifferScript.swift     #   m3u8 嗅探注入 JS
│   │   ├── AdCleanerScript.swift   #   广告弹窗清理 JS（连带解锁站点滚动锁）
│   │   ├── AgeGateScript.swift     #   年龄确认门自动点击 JS（每页最多 4 次）
│   │   ├── KeyboardDismissScript.swift # 滑动网页收键盘 JS
│   │   ├── ScrollCollapseScript.swift  # 滚动方向上报 JS（顶栏/工具条收起联动）
│   │   └── ScrollCollapsePolicy.swift  # 收起联动纯判定
│   ├── Settings/                   # 设置域（画布全自绘，「我的」页二级页）
│   │   ├── QuickLinkStore.swift    #   快捷站点持久化 + 默认站点决策
│   │   ├── AppLaunchPreferences.swift  # 启动 tab 偏好
│   │   ├── DramaRoutePreferences.swift # 「打开 Web 剧集页」路由偏好
│   │   ├── SettingsViewModel.swift #   设置 VM（恢复默认收口）
│   │   ├── SettingsView.swift      #   设置页
│   │   └── QuickLinkEditorSheet.swift  # 站点编辑弹层
│   ├── Profile/                    # 「我的」域（纸本轨）
│   │   ├── ProfileViewModel.swift  #   四分类装配（历史/收藏/追更/点赞，后台串行队列）
│   │   └── ProfileView.swift       #   我的页（分页容器 + 封面墙 + 二级页路由）
│   ├── Infra/                      # 基础设施（系统能力）
│   │   ├── LocalMediaServer.swift  #   本地回环 HTTP 服务（HLS 播放源）
│   │   ├── WebKitFetcher.swift     #   WKDownload 下载兜底（过 TLS 指纹 WAF）
│   │   ├── AppHaptics.swift        #   触觉反馈唯一入口
│   │   ├── KeyboardObserver.swift  #   键盘显隐观察
│   │   └── SwipeBackSupport.swift  #   导航页右滑返回桥件
│   └── player/                     # 播放域（沉浸式竖屏 + 横屏全屏）
│       ├── PlaybackModels.swift    #   播放纯数据
│       ├── DramaEpisode.swift      #   播放卡片数据模型
│       ├── PlaybackQueueService.swift  # 上下滑资源调度唯一入口（推荐算法接入点）
│       ├── PlaybackPlayerService.swift # 单 AVPlayer 常驻 + 预热池（秒开）
│       ├── PlaybackProgressTracker.swift # 进度落库与续播
│       ├── PlayerPreferences.swift #   静音/清屏/剩余时间显示偏好
│       ├── PlayerGesturePolicy.swift   # 横滑快进换算纯函数
│       ├── PlayerBrightnessVolume.swift # 横屏左亮度/右音量手势 Service
│       ├── PlayerOrientationTrigger.swift # 重力姿态判稳自动进/出全屏
│       ├── PlayerFullscreenController.swift # 全屏动画核心（视频层搬运+旋转）
│       ├── EpisodePanelService.swift   # 选集面板数据装配 + 单集下载
│       ├── DramaPlayerViewModel.swift  # 单集播放状态机（加载/快进/代际令牌）
│       ├── PlayerFeedViewModel.swift   # 分页数据源/停稳防抖/边界提示
│       ├── DramaPlayerView.swift       # 竖屏播放卡片
│       ├── PlayerFeedView.swift        # 播放页容器（顶栏悬浮条/倍速与选集浮层）
│       ├── PlayerPagingScrollView.swift # UIKit 分页滚动 + 快进/边缘返回手势
│       ├── PlayerSurfaceContainer.swift # 单例视频容器（AVPlayerLayer 宿主）
│       ├── PlayerFullscreenControlsView.swift # 横屏全屏控制层
│       ├── EpisodePanel.swift          # 选集面板（竖屏底部弹层）
│       ├── PlaybackRatePanel.swift     # 倍速面板
│       ├── FullscreenDrawers.swift     # 全屏抽屉（选集/清晰度）
│       ├── PlaybackFreezeFrame.swift   # 切集冻帧（换集不黑闪）
│       ├── PlayerOverlayGlyphs.swift   # 播放页自绘图元库
│       ├── PlayerPreviewEntry.swift    # Debug 定帧入口（#if DEBUG）
│       └── DramaPlayerContainer.swift  # fullScreenCover 组装根
├── LaunchSplashView.swift         # 启动屏（显式工程引用，不在同步文件夹内）
└── smoke/                          # macOS 冒烟工具（不需要手机即可验证下载核心）
    ├── main.swift                  #   冒烟总入口（SMARTDOWNLOADER_DIR 下跑真实流端到端）
    ├── deduptest.swift             #   同集去重 5 断言（改动去重逻辑后必跑）
    ├── playtest.swift              #   本地 HLS 播放验证
    ├── fetchtest.swift             #   站点连通诊断（--browser 加 Safari 头）
    ├── videocli.swift              #   命令行：剧集页 URL → 新鲜 m3u8
    ├── dumpdrama.swift             #   站点接口采集
    ├── snapshot3.sh                #   三机型视觉快照矩阵（5 态 × 3 机型）
    └── WebKitFetcher.swift         #   冒烟所需的下载兜底实现
```

工程文件为 Xcode 26 新格式（文件夹同步组），无需 xcodegen：新 Swift 文件放进**对应域目录**即自动参与编译（根目录只留 `App.swift`，规则见 `AGENTS.md`「目录」）。`Info.plist` 必须留在根（`INFOPLIST_FILE` 写死路径），`iOS/LaunchSplashView.swift` 是显式工程引用、不在同步文件夹内。
