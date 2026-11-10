// 下载核心冒烟测试（仅 macOS 运行，不属于 App 产物）
// 用法: SMARTDOWNLOADER_DIR=<输出目录> ./coretest [m3u8地址]
// 注意: 顶层代码运行在主线程，任务也是 @MainActor —— 不能用信号量阻塞主线程等待（会死锁），
//       必须让出 RunLoop 轮询。
import Foundation

let arguments = CommandLine.arguments
let testURL = arguments.count > 1
    ? arguments[1]
    : "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/gear1/prog_index.m3u8"

var finished = false

Task { @MainActor in
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
