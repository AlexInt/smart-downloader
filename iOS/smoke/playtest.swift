// 端到端播放验证（仅 macOS 运行）：
// 启动内置本地 HTTP 服务，用 AVFoundation 加载本地 HLS 文件夹的播放列表。
// 用法: SMARTDOWNLOADER_DIR=<Downloads根目录> ./playtest <HLS文件夹路径>
// 注意: playbackURL 的 completion 在主线程 —— 不能信号量阻塞主线程（会死锁），让出 RunLoop 等。
import AVFoundation

@main
struct PlayTest {
    static func main() {
        let folder = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: "out/smoke_test", isDirectory: true)

        var playlistURL: URL?
        var urlDone = false
        LocalMediaServer.shared.playbackURL(forFolder: folder) { url in
            playlistURL = url
            urlDone = true
        }
        let urlDeadline = Date().addingTimeInterval(15)
        while !urlDone && Date() < urlDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        guard let url = playlistURL else {
            print("RESULT: SERVER-FAILED")
            return
        }
        print("PLAYLIST URL: \(url)")
        guard url.scheme == "http" else {
            print("RESULT: SERVER-FAILED")
            return
        }
        let asset = AVURLAsset(url: url)
        // 资产加载 async 岛（Apple 非废弃加载 API 只有 async load）：结果写标志位，主线程 RunLoop 等
        var loadDone = false
        var loadedDuration: CMTime?
        var loadError: Error?
        Task { @MainActor in
            do {
                loadedDuration = try await asset.load(.duration)
            } catch {
                loadError = error
            }
            loadDone = true
        }
        let loadDeadline = Date().addingTimeInterval(15)
        while !loadDone && Date() < loadDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        if let loadError {
            print("RESULT: LOAD-FAILED \(loadError.localizedDescription)")
            return
        }
        guard let duration = loadedDuration else {
            print("RESULT: LOAD-FAILED notLoaded/timeout")
            return
        }
        print("ASSET: duration=\(CMTimeGetSeconds(duration))s")

        // 真实播放验证：AVPlayer 播放并观察进度推进
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.play()
        for _ in 0..<75 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if player.timeControlStatus == .playing { break }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let time = CMTimeGetSeconds(player.currentTime())
        if player.timeControlStatus == .playing && time > 0.5 {
            print("RESULT: PLAYING currentTime=\(String(format: "%.2f", time))s")
        } else {
            print("RESULT: NOT-PLAYING control=\(player.timeControlStatus.rawValue) time=\(time) itemStatus=\(item.status.rawValue) error=\(item.error?.localizedDescription ?? "nil")")
        }
    }
}