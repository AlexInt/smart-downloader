import AVFoundation
import UIKit

// MARK: - 切集冻帧 Service
//
// 为什么需要：切集 = `replaceCurrentItem`，AVPlayerLayer 会立刻丢掉旧画面、等新 item
// 解出首帧才重新有内容。竖屏卡片上压着一层加载渐变（`DramaPlayerView` 的渐变兜底），
// 这段空窗被渐变盖住；**全屏时视频层被搬到全屏容器里、没有那层渐变**，换 item 的那一下
// 就直接露出容器黑底 —— 用户实报「全屏用选集中集数切集时会闪一下」。
//
// 做法：每个 item 挂一个 `AVPlayerItemVideoOutput`（解码管线的旁路出口，不额外解码）。
// 切集**之前**把当前显示的那一帧同步取成 UIImage（已解码好的帧，~1-5ms），
// 交给 `PlayerSurfaceUIView` 的冻帧层盖住画面，新 item 就绪后 0.15s 淡出 → 全程无缝。
//
// 只在「视频层被搬走（全屏）」时使用：竖屏仍走原「藏条带 + 渐变交叉淡入」路径，
// 那条路径是竖屏调好的，不要合并。

final class PlaybackFreezeFrame {
    /// 当前挂在 item 上的视频输出（下次切集从这里取帧）
    private var output: AVPlayerItemVideoOutput?
    /// CIImage → CGImage 的上下文复用：每次切集都要转一帧，别每次新建。
    /// 用 lazy：CIContext 构造成本不低，没下载过任何一集时不该在 VM init 里付这笔钱
    private lazy var context = CIContext(options: [.cacheIntermediates: false])

    /// 给新 item 挂输出。**必须在 item 开始播之后就挂**（下一次切集才有帧可取）。
    func attach(to item: AVPlayerItem) {
        // 32BGRA：CIContext 转换最快；IOSurface 让缓冲区可直接落 GPU
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)
        self.output = output
        print("PLAYER_DBG [FreezeFrame] output attached")
    }

    /// 播放页退出 / 换播放器时清掉（item 已被释放，输出不再有用）
    func detach() {
        output = nil
    }

    /// 取 player **当前显示**的那一帧；没有可用帧（刚起播 / 纯音频 / 输出未就绪）返回 nil，
    /// 调用方按「没有冻帧」退化处理（不遮画面）。
    ///
    /// 取帧时间点按优先级试三个（暂停态常常只有「播放头时间」那一帧还在）：
    /// ① 宿主时钟 → item 时钟（最贴近观众正在看的那一帧）
    /// ② `player.currentTime()`（渲染时间轴，可能领先一小段）
    /// ③ `item.currentTime()`
    func snapshot(of player: AVPlayer) -> UIImage? {
        guard let output, let item = player.currentItem, item.status == .readyToPlay else {
            print("PLAYER_DBG [FreezeFrame] snapshot SKIP reason=noOutputOrItem")
            return nil
        }
        let hostTime = output.itemTime(forHostTime: CACurrentMediaTime())
        var candidates: [CMTime] = []
        if CMTimeGetSeconds(hostTime).isFinite { candidates.append(hostTime) }
        candidates.append(player.currentTime())
        candidates.append(item.currentTime())

        for (i, target) in candidates.enumerated() {
            guard CMTimeGetSeconds(target).isFinite else { continue }
            guard output.hasNewPixelBuffer(forItemTime: target),
                  let buffer = output.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: nil) else {
                print("PLAYER_DBG [FreezeFrame] snapshot MISS try=\(i) t=\(String(format: "%.2f", CMTimeGetSeconds(target)))")
                continue
            }
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let cg = context.createCGImage(ci, from: ci.extent) else {
                print("PLAYER_DBG [FreezeFrame] snapshot FAIL reason=createCGImage try=\(i)")
                continue
            }
            print("PLAYER_DBG [FreezeFrame] snapshot OK try=\(i) t=\(String(format: "%.2f", CMTimeGetSeconds(target))) size=\(cg.width)x\(cg.height)")
            return UIImage(cgImage: cg)
        }
        return nil
    }
}
