// 下载核心冒烟测试（仅 macOS 运行，不属于 App 产物）
// 用法: SMARTDOWNLOADER_DIR=<输出目录> ./coretest [m3u8地址]
//       SMARTDOWNLOADER_DIR=<空目录> ./coretest --library   # 两级库扫描检查（剧目录/散装/已下载集检测）
// 注意: 顶层代码运行在主线程，任务也是 @MainActor —— 不能用信号量阻塞主线程等待（会死锁），
//       必须让出 RunLoop 轮询。
import Foundation

let arguments = CommandLine.arguments
let libraryOnly = arguments.contains("--library")
let testURL = arguments.count > 1 && !libraryOnly
    ? arguments[1]
    : "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/gear1/prog_index.m3u8"

var finished = false

@MainActor
func runLibraryCheck() {
    let fm = FileManager.default
    let dir = DownloadEngine.downloadsDir
    // 造两级结构: 剧名/第NN集/playlist.m3u8 + 散装条目 + 残缺集(无 playlist, 不应计入)
    func makeHLS(_ path: String) {
        let folder = dir.appendingPathComponent(path, isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "#EXTM3U\n".write(to: folder.appendingPathComponent("playlist.m3u8"),
                               atomically: true, encoding: .utf8)
    }
    makeHLS("剧A/第01集")
    makeHLS("剧A/第02集")
    try? fm.createDirectory(at: dir.appendingPathComponent("剧A/第03集", isDirectory: true),
                            withIntermediateDirectories: true)
    makeHLS("散装电影")
    try? Data().write(to: dir.appendingPathComponent("movie.mp4"))

    let manager = DownloadManager()
    let series = manager.tasks.filter { $0.seriesName == "剧A" }
    let standalone = manager.tasks.filter { $0.seriesName == nil }
    let downloaded = manager.downloadedEpisodeSorts(forSeries: "剧A").sorted()
    print("LIBRARY: series_eps=\(series.map(\.title).sorted())")
    print("LIBRARY: standalone=\(standalone.count)")
    print("LIBRARY: downloadedSorts=\(downloaded)")
    let ok = series.count == 2 && standalone.count == 2 && downloaded == [1, 2]
    print(ok ? "RESULT: DONE" : "RESULT: FAILED (期望 series=2 standalone=2 sorts=[1,2])")

    // 旧散装收编: 顶层 "剧A 第03集"(带 playlist) 应搬进 剧A/第03集(1)（同号残缺目录已存在 → (1) 后缀）
    makeHLS("剧A 第03集")
    manager.collectLegacyEpisodes(forSeries: "剧A")
    manager.refreshLibrary()
    let series2 = manager.tasks.filter { $0.seriesName == "剧A" }
    let downloaded2 = manager.downloadedEpisodeSorts(forSeries: "剧A").sorted()
    print("LIBRARY: 收编后 series_eps=\(series2.map(\.title).sorted()) downloaded=\(downloaded2)")
    let ok2 = series2.count == 3 && downloaded2 == [1, 2, 3]
    print(ok2 ? "RESULT: DONE" : "RESULT: FAILED (期望收编后 series=3 sorts=[1,2,3])")

    // 剧集缓存 DB: 存 → 读 round-trip + 下载状态对账 + 集数更新合并
    var ok3 = true
    let cacheInfo = DramaInfo(name: "缓存测试剧", updateStatus: "更新中",
                              episodes: [DramaEpisode(id: 11, sort: 1, playable: true),
                                         DramaEpisode(id: 12, sort: 2, playable: false)])
    DramaCache.saveInfo(site: "https://smoke.test", dramaID: "999", info: cacheInfo)
    DramaCache.savePageMeta(site: "https://smoke.test", dramaID: "999",
                            update: ["ogImage": "https://smoke.test/cover.jpg", "desc": "简介文本"])
    DramaCache.markDownloaded(site: "https://smoke.test", dramaID: "999", episodeID: 11, folder: "第01集")
    DramaCache.reconcileDownloaded(site: "https://smoke.test", dramaID: "999", folders: [1: "第01集"])
    if let entry = DramaCache.load(site: "https://smoke.test", dramaID: "999") {
        let ep11 = entry.episodes.first { $0.id == 11 }
        let ep12 = entry.episodes.first { $0.id == 12 }
        print("CACHE: eps=\(entry.episodes.count) cover=\(entry.cover ?? "?") ep11.downloaded=\(ep11?.downloaded ?? false) folder=\(ep11?.folder ?? "?") ep12.downloaded=\(ep12?.downloaded ?? false)")
        ok3 = entry.episodes.count == 2 && ep11?.downloaded == true && ep11?.folder == "第01集"
            && ep12?.downloaded == false && entry.cover == "https://smoke.test/cover.jpg"
    } else { ok3 = false }

    // 集数更新：网络刷新返回 3 集（新增 id 13）→ 合并且已下载标记保留、更新状态刷新
    let fresh = DramaInfo(name: "缓存测试剧", updateStatus: "完结",
                          episodes: cacheInfo.episodes + [DramaEpisode(id: 13, sort: 3, playable: true)])
    DramaCache.saveInfo(site: "https://smoke.test", dramaID: "999", info: fresh)
    DramaCache.reconcileDownloaded(site: "https://smoke.test", dramaID: "999", folders: [1: "第01集"])
    if let entry = DramaCache.load(site: "https://smoke.test", dramaID: "999") {
        let ep11 = entry.episodes.first { $0.id == 11 }
        let ep13 = entry.episodes.first { $0.id == 13 }
        print("CACHE: 更新后 eps=\(entry.episodes.count) ep11.downloaded=\(ep11?.downloaded ?? false) ep13=\(ep13?.playable ?? false) status=\(entry.updateStatus ?? "?")")
        ok3 = ok3 && entry.episodes.count == 3 && ep11?.downloaded == true
            && ep13?.downloaded == false && entry.updateStatus == "完结"
    } else { ok3 = false }
    print(ok3 ? "RESULT: DONE" : "RESULT: FAILED (缓存 round-trip 失败)")
    finished = true
}

Task { @MainActor in
    if libraryOnly {
        runLibraryCheck()
        return
    }
    let title = arguments.count > 2 ? arguments[2] : "smoke_test"
    let task = DownloadTask(url: testURL, title: title)
    await DownloadEngine().run(task: task)
    switch task.state {
    case .done:
        print("\nRESULT: DONE -> \(task.outputURL?.path ?? "?")")
    case .failed(let message):
        print("\nRESULT: FAILED: \(message)")
    default:
        print("\nRESULT: \(task.state)")
    }
    finished = true
}

// 主线程让出 RunLoop，驱动 MainActor 任务；最长等 8 分钟
let deadline = Date().addingTimeInterval(480)
var lastPrint = ""
while !finished && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
}
if !finished { print("\nRESULT: TIMEOUT (8min)") }
