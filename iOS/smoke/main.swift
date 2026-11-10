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
