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
3. 点击开始下载 → 切到「下载」页看进度（6 并发）
4. 点击已完成条目**直接播放**；左滑删除（同时删除沙盒文件）
5. 文件位置：App 沙盒 `Documents/Downloads/<剧名>/`。已开启文件共享，iPhone 连 Mac 时 Finder 左侧可看到并拷出

## 三、架构

```
「浏览」页
  WKWebView 加载视频资源站点 (cookie 共享, 登录态/付费内容自动解锁)
  └ 注入嗅探 JS (atDocumentStart): Hook XHR/fetch + performance 历史 + video/source DOM 扫描
      → window.webkit.messageHandlers 回传 m3u8 → 按钮激活
「下载」DownloadEngine (Swift 版 M3U8Downloader)
  拉清单(多级选最高码率) → 预取 AES-128 密钥 → 6 并发切片下载(重试/Range/解密)
  → 保存为「本地 HLS 文件夹」: playlist.m3u8(重写,去 KEY 行) + seg_*.ts(+init.mp4)
  URLSession 被掐(连接层错误)时自动降级 WebKitFetcher(WKDownload, Safari 同源 TLS 栈)
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
- 安全按「个人使用」标准：信任所有证书 + ATS 全放行（用户已确认此取舍）

## 五、冒烟测试（Mac 上验证核心，不需手机）

```bash
cd iOS/smoke

# 1. 下载核心: 真实下载 Apple bipbop 测试流(BYTERANGE+多码率), 产出 out/smoke_test/ 本地 HLS 文件夹
swiftc -O -o coretest main.swift ../SmartDownloader/Downloader.swift ../SmartDownloader/WebKitFetcher.swift
SMARTDOWNLOADER_DIR="$PWD/out" ./coretest
# 期望: RESULT: DONE -> .../out/smoke_test/playlist.m3u8
# 加 SMARTDOWNLOADER_FORCE_WEBKIT=1 强制走 WebKit 兜底通道，验证 WKDownload 链路

# 2. 播放验证: 启动内置本地服务, AVPlayer 实际播放并确认进度推进
swiftc -O -o playtest playtest.swift ../SmartDownloader/LocalMediaServer.swift ../SmartDownloader/Downloader.swift ../SmartDownloader/WebKitFetcher.swift
SMARTDOWNLOADER_DIR="$PWD/out" ./playtest out/smoke_test
# 期望: RESULT: PLAYING currentTime=1.xx s

# 3. 站点连通诊断: 用 App 同款 URLSession 栈测任意 URL（--browser 加 Safari 头）
swiftc -O -o fetchtest fetchtest.swift
./fetchtest "<任意URL>" --browser

# 4. 真实剧集端到端: 用 App 同款栈调站点接口取新鲜 m3u8(站点地址从剧集页 URL 解析), 再交给 coretest 下载
swiftc -O -o videocli videocli.swift ../SmartDownloader/Downloader.swift ../SmartDownloader/WebKitFetcher.swift
./videocli "<剧集页URL>"    # 输出 M3U8: <url>
SMARTDOWNLOADER_DIR="$PWD/out" ./coretest "<该url>" ep1

# 5. App 嗅探链路(可选): 临时把 BrowserView 默认起始页(about:blank)改为 http://127.0.0.1:8899/test.html,
#    运行 `python3 -m http.server 8899` 后在模拟器跑 App, 按钮应亮起「下载视频 (1)」
```

## 六、文件清单

| 文件 | 职责 |
|---|---|
| `SmartDownloader/App.swift` | 入口，启动时预启本地媒体服务 |
| `SmartDownloader/BrowserView.swift` | 浏览页：WKWebView + 嗅探脚本注入(内嵌 JS) + 下载按钮 |
| `SmartDownloader/Downloader.swift` | 下载核心 + 任务/队列管理 |
| `SmartDownloader/WebKitFetcher.swift` | WebKit 网络栈兜底（WKDownload，过 TLS 指纹 WAF） |
| `SmartDownloader/LocalMediaServer.swift` | 回环 HTTP 服务（Range 支持，仅 127.0.0.1） |
| `SmartDownloader/DownloadsView.swift` | 下载列表 + AVKit 播放页 |
| `SmartDownloader/Info.plist` | ATS 放行 / 文件共享 / 横竖屏 |
| `SmartDownloader/Media.xcassets` | 资源目录（App Icon，sd.png 1024x1024） |
| `smoke/` | 冒烟测试工具（coretest / playtest / videocli / fetchtest，仅 macOS） |

工程文件为 Xcode 26 新格式（文件夹同步组），无需 xcodegen，添加新 Swift 文件直接放进 `SmartDownloader/` 即自动参与编译。
