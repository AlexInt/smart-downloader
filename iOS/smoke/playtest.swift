// 端到端播放验证（仅 macOS 运行）：
// 启动内置本地 HTTP 服务，用 AVFoundation 加载本地 HLS 文件夹的播放列表。
// 用法: SMARTDOWNLOADER_DIR=<Downloads根目录> ./playtest <HLS文件夹路径>
import AVFoundation

@main
struct PlayTest {
    static func main() async throws {
        let folder = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: "out/smoke_test", isDirectory: true)

        let url = await LocalMediaServer.shared.playbackURL(forFolder: folder)
        print("PLAYLIST URL: \(url)")
        guard url.scheme == "http" else {
            print("RESULT: SERVER-FAILED")
            return
        }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            print("ASSET: duration=\(CMTimeGetSeconds(duration))s")
        } catch {
            print("RESULT: LOAD-FAILED \(error.localizedDescription)")
            return
        }

        // 真实播放验证：AVPlayer 播放并观察进度推进
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.play()
        for _ in 0..<75 {
            try await Task.sleep(nanoseconds: 200_000_000)
            if player.timeControlStatus == .playing { break }
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let time = CMTimeGetSeconds(player.currentTime())
        if player.timeControlStatus == .playing && time > 0.5 {
            print("RESULT: PLAYING currentTime=\(String(format: "%.2f", time))s")
        } else {
            print("RESULT: NOT-PLAYING control=\(player.timeControlStatus.rawValue) time=\(time) itemStatus=\(item.status.rawValue) error=\(item.error?.localizedDescription ?? "nil")")
        }
    }
}
