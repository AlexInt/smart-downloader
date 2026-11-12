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

1. 「浏览」页自动恢复上次访问的页面（首次为空白起始页，地址栏输入视频资源站点即可）；在网页里正常登录、点开剧集播放
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
6. 文件位置：App 沙盒 `Documents/Downloads/`。选集下载按剧分目录：`Downloads/<剧名>/第NN集/playlist.m3u8`；
   散装下载仍是 `Downloads/<标题>/`。已开启文件共享，iPhone 连 Mac 时 Finder 左侧可看到并拷出

## 三、架构

```
「浏览」页
  WKWebView 加载视频资源站点 (cookie 共享, 登录态/付费内容自动解锁)
  ├ 注入嗅探 JS (atDocumentStart): Hook XHR/fetch + performance 历史 + video/source DOM 扫描
  │     → window.webkit.messageHandlers 回传 m3u8 → 按钮激活
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
```

**为什么播放要绕本地 HTTP 服务**：AVFoundation 无法直接播文件版 m3u8，也无法播裸 TS 合并文件（iOS 上没有 ffmpeg）。本地回环 HTTP + 重写播放列表是 iOS 离线 HLS 的标准做法；切片下载时已解密，播放列表去掉了 KEY 行。

与 Python 版同源能力：AES-128 解密（缺省 IV 按 media sequence 规范推导，修正了 Python 版全 0 的 bug）、多级列表、`EXT-X-BYTERANGE`（Python 版未支持）、fMP4 init 段、同名加 (1) 后缀。切片失败即任务失败，不做缺洞合并。

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

## 六、文件清单

| 文件 | 职责 |
|---|---|
| `SmartDownloader/App.swift` | 入口，启动时预启本地媒体服务（根目录只留这一个 Swift 文件） |
| `SmartDownloader/Shared/` | 跨域纯数据与设计系统：`DramaModels` / `DownloadModels` / `DesignTokens`（含 `designFrame`） |
| `SmartDownloader/Drama/` | 剧集域：`DramaDetailData`（接口 DTO）、`DramaAPI` / `DramaCache` / `DramaMetaHarvester` / `DramaFavorites`（Service）、`DramaPageViewModel`（VM）、`DramaDetailView`（View）、`DramaNativePage`（组装根） |
| `SmartDownloader/Downloads/` | 下载域：`Downloader`（核心 + 任务/队列 + 两级库扫描）、`DownloadsViewModel`、`DownloadsView` |
| `SmartDownloader/Browser/` | 浏览域：`BrowserView`（含 `WebViewContainer`）、`WebViewStore`（VM）、`SnifferScript`（注入 JS） |
| `SmartDownloader/Infra/` | 系统能力：`LocalMediaServer`（回环 HTTP，Range）、`WebKitFetcher`（WKDownload 兜底，过 TLS 指纹 WAF） |
| `SmartDownloader/player/` | 播放域，五层齐全（详见 `HANDOFF.md` §3） |
| `SmartDownloader/Components/` | 全局通用 UI（`ToastView`） |
| `SmartDownloader/video_auto.py` | → 仓库根 video_auto.py 的 symlink，随包携带供 DramaAPI 解析账号/AES 常量（改动只需改仓库根一处） |
| `SmartDownloader/Info.plist` | ATS 放行 / 文件共享 / 横竖屏 |
| `SmartDownloader/Media.xcassets` | 资源目录（App Icon，sd.png 1024x1024） |
| `smoke/` | 冒烟测试工具（coretest / playtest / videocli / fetchtest，仅 macOS） |

工程文件为 Xcode 26 新格式（文件夹同步组），无需 xcodegen：新 Swift 文件放进**对应域目录**即自动参与编译（根目录只留 `App.swift`，规则见 `AGENTS.md`「目录」）。`Info.plist` 必须留在根（`INFOPLIST_FILE` 写死路径），`iOS/LaunchSplashView.swift` 是显式工程引用、不在同步文件夹内。
