import Foundation
import CoreMotion

// MARK: - 姿态判稳触发器（Service，UIKit+Combine 路线的姿态源）
//
// 设备稳定转横 → 自动进全屏；稳定回竖 → 退出。无任何按钮入口（抖音式信息流形态）。
//
// 为什么不用 UIDevice.orientation 通知：App 已锁竖屏后系统不再产生方向事件，
// 且系统方向在 45° 边界附近会抖动（此前窗口反复翻转的实证）。这里用 CoreMotion
// 重力向量算**连续倾角**，自己做滞后阈值 + 稳定窗：
//   - 进入阈值 55° / 退出阈值 28°（滞后带覆盖 45° 抖动区，来回倾不反复进出）；
//   - 倾角持续满足阈值 0.6s 才触发（快速甩动不误触发）；
//   - 设备接近平放（重力集中在 z 轴）时倾角不可信，跳过判定。
// 仅横屏片源（宽>高）响应转横——竖屏片源转横全屏只是一条细竖条，没有意义。
// 主线程约定：motion 回调固定 .main，状态只在主线程访问。

final class PlayerOrientationTrigger {
    private let playback: DramaPlayerViewModel
    private let motion = CMMotionManager()
    /// 当前正在积累的稳定目标（nil = 无）；true = 进全屏，false = 退出
    private var pendingTarget: Bool?
    private var stableSince: Date?

    /// 进入全屏阈值（度，相对竖屏持机）
    private let enterThreshold: Double = 55
    /// 退出阈值（度）：滞后带下沿
    private let exitThreshold: Double = 28
    /// 稳定窗：倾角持续满足阈值达此时长才触发
    private let stableInterval: TimeInterval = 0.6
    /// 设备接近平放判定：重力水平分量低于此值时跳过（倾角不可信）
    private let minUprightMagnitude: Double = 0.55

    init(playback: DramaPlayerViewModel) {
        self.playback = playback
    }

    func start() {
        guard motion.isDeviceMotionAvailable else {
            print("PLAYER_DBG [Orientation] trigger SKIP reason=noDeviceMotion")
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let dm = motion else { return }
            self.consume(gravityX: dm.gravity.x, gravityY: dm.gravity.y, gravityZ: dm.gravity.z)
        }
        print("PLAYER_DBG [Orientation] trigger started interval=\(motion.deviceMotionUpdateInterval)")
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        pendingTarget = nil
        stableSince = nil
    }

    // MARK: 私有

    private func consume(gravityX x: Double, gravityY y: Double, gravityZ z: Double) {
        let horizontal = (x * x + y * y).squareRoot()
        guard horizontal > minUprightMagnitude else {
            // 平放/斜提：倾角不可信，稳定积累作废
            resetStability()
            return
        }
        // 0° = 竖屏持机；±90° = 横屏（左右两个方向都算横屏内容方向）
        let angleDeg = atan2(x, -y) * 180 / .pi
        let absAngle = abs(angleDeg)

        if playback.isFullscreen {
            // 全屏中：回竖稳（滞后带下沿）才退出
            if absAngle <= exitThreshold {
                accumulate(target: false)
            } else {
                resetStability()
            }
        } else {
            // 竖屏中：仅横屏片源 + 已就绪，稳定越进入阈值才进入
            guard playback.videoIsLandscape, playback.isReady else {
                resetStability()
                return
            }
            if absAngle >= enterThreshold {
                accumulate(target: true)
            } else {
                resetStability()
            }
        }
    }

    private func accumulate(target: Bool) {
        let now = Date()
        if pendingTarget != target {
            pendingTarget = target
            stableSince = now
            return
        }
        guard let since = stableSince else {
            stableSince = now
            return
        }
        guard now.timeIntervalSince(since) >= stableInterval else { return }
        resetStability()
        print("PLAYER_DBG [Orientation] stable \(target ? "landscape→enter" : "portrait→exit")")
        if target {
            playback.enterFullscreen()
        } else {
            playback.exitFullscreen()
        }
    }

    private func resetStability() {
        pendingTarget = nil
        stableSince = nil
    }
}
