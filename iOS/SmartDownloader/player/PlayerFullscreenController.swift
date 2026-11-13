import UIKit
import AVFoundation
import Combine

// MARK: - 全屏播放控制器（UIKit + Combine）
//
// 对齐 ZFPlayer / SJVideoPlayer「旋转横屏（rotate）」模式：App 锁竖屏、系统界面不转，
// 「全屏」= 全屏容器 transform 旋转 90° + 等比放大铺满屏幕的连续动画——
// 视频从竖屏内的 letterbox 条「跟随旋转慢慢变大」，退出反向动画。
//
// 职责：
// - 订阅 `playback.$isFullscreen`（Combine），驱动进/出动画；动画期间的最新意图收敛。
// - videoLayer 在 feed surface 与全屏容器之间搬运（AVPlayer 不间断，无重载）。
// - 全屏容器挂在 keyWindow 上（覆盖一切、不随内容滚动），随播放页销毁立即还原。
// 控制层（A-4）挂进全屏容器；进/出触发由姿态服务（A-5）调 VM 意图，本类不自判姿态。

/// 全屏容器：bounds 即横屏坐标空间（旋转后铺满竖屏屏幕），videoLayer 在 layoutSubviews 跟随
final class FullscreenPlayerView: UIView {
    var videoLayer: AVPlayerLayer?
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        videoLayer?.frame = bounds
        onLayout?()
    }
}

final class PlayerFullscreenController: NSObject {
    private let playback: DramaPlayerViewModel
    private unowned let surface: PlayerSurfaceUIView
    private var container: FullscreenPlayerView?
    private var cancellables = Set<AnyCancellable>()
    private var isAnimating = false
    /// 动画期间的最新意图（连续触发以最后为准，不排队跳变）
    private var pendingTarget: Bool?

    init(playback: DramaPlayerViewModel, surface: PlayerSurfaceUIView) {
        self.playback = playback
        self.surface = surface
        super.init()
        playback.$isFullscreen
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] full in self?.handle(full) }
            .store(in: &cancellables)
    }

    /// 播放页销毁：立即还原 videoLayer 并移除 window 上的全屏容器（无动画）
    func teardown() {
        cancellables.removeAll()
        guard container != nil else { return }
        restoreVideoLayer()
        container?.removeFromSuperview()
        container = nil
        print("PLAYER_DBG [Fullscreen] teardown restored")
    }

    // MARK: 私有

    private func handle(_ full: Bool) {
        guard !isAnimating else {
            pendingTarget = full
            return
        }
        full ? performEnter() : performExit()
    }

    /// 进入：容器从活跃卡 surface 的窗口 frame 出发，旋转 90° + 放大铺满
    private func performEnter() {
        guard container == nil, let window = surface.window else {
            print("PLAYER_DBG [Fullscreen] enter SKIP reason=noWindowOrAlready")
            return
        }
        isAnimating = true
        let startFrame = surface.convert(surface.bounds, to: window)
        let container = FullscreenPlayerView(frame: startFrame)
        container.backgroundColor = .black
        container.clipsToBounds = true

        // videoLayer 搬家（唯一宿主切换）：动画前先落位到起点，无空帧
        surface.videoLayer.removeFromSuperlayer()
        container.videoLayer = surface.videoLayer
        container.layer.addSublayer(surface.videoLayer)
        surface.videoLayer.frame = container.bounds
        surface.videoLayer.videoGravity = .resizeAspectFill   // 全屏铺满（横屏片源轻微上下裁切）

        window.addSubview(container)
        self.container = container

        let screenSize = window.bounds.size
        print("PLAYER_DBG [Fullscreen] enter from=\(startFrame) screen=\(screenSize)")
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut], animations: {
            // bounds 换成横屏尺寸 + 中心居中 + 旋转 90°：旋转后足迹恰好铺满竖屏屏幕
            container.bounds = CGRect(origin: .zero, size: CGSize(width: screenSize.height, height: screenSize.width))
            container.center = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
            container.transform = CGAffineTransform(rotationAngle: .pi / 2)
        }, completion: { [weak self] _ in
            guard let self else { return }
            self.isAnimating = false
            print("PLAYER_DBG [Fullscreen] enter done")
            self.flushPending()
        })
    }

    /// 退出：反向动画回活跃卡 surface 的窗口 frame，完成后 videoLayer 搬回
    private func performExit() {
        guard let container, let window = surface.window else {
            container?.removeFromSuperview()
            self.container = nil
            return
        }
        isAnimating = true
        let targetFrame = surface.convert(surface.bounds, to: window)
        print("PLAYER_DBG [Fullscreen] exit to=\(targetFrame)")
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut], animations: {
            container.transform = .identity
            container.bounds = CGRect(origin: .zero, size: targetFrame.size)
            container.center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        }, completion: { [weak self] _ in
            guard let self else { return }
            self.restoreVideoLayer()
            container.removeFromSuperview()
            self.container = nil
            self.isAnimating = false
            print("PLAYER_DBG [Fullscreen] exit done")
            self.flushPending()
        })
    }

    private func restoreVideoLayer() {
        let layer = surface.videoLayer
        layer.removeFromSuperlayer()
        surface.layer.addSublayer(layer)
        layer.frame = surface.bounds
        layer.videoGravity = PlayerPagingScrollView.videoGravity(for: playback)
    }

    private func flushPending() {
        guard let pending = pendingTarget else { return }
        pendingTarget = nil
        if pending != playback.isFullscreen {
            handle(pending)
        }
    }
}
