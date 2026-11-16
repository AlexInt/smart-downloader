import UIKit
import MediaPlayer
import AVFoundation

// MARK: - 全屏亮度 / 音量（Service，2026-11-16 手势 A 档）
//
// 两条触发路径共用本能力：
//   ① 全屏竖滑调节：左半亮度、右半音量（此前全屏竖滑完全空手）
//   ② 全屏控制层亮度按钮：一键最亮 ↔ 还原（原先是只打日志的死钮）
// VM 层不 import UIKit（AGENTS 分层约束），故系统能力封装在这里；
// 控制器/控制层（UIKit）直接调用，指示浮层的显示由调用方自管。

/// 音量调节：iOS 无公开 setter，行业标准做法是驱动隐藏 MPVolumeView 里的
/// UISlider——**视图必须挂在窗口树上才生效**，attach 时零影响地藏进宿主。
final class PlayerBrightnessVolume {

    static let shared = PlayerBrightnessVolume()
    private init() {}

    private var volumeView: MPVolumeView?
    private var volumeSliderMissingLogged = false
    /// 亮度按钮「一键最亮」的还原点：按最亮前记下当时的亮度，再按还原

    // MARK: 音量

    /// 把音量桥挂进窗口树（宿主 = 全屏容器，进全屏 attach、退出随容器销毁）。
    /// 零尺寸 + 贴出屏外 + alpha≈0：不挡触摸、不可见，只求 slider 可用。
    func attachVolumeBridge(to host: UIView) {
        guard volumeView == nil else { return }
        let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 10, height: 10))
        view.alpha = 0.01
        host.addSubview(view)
        volumeView = view
        volumeSliderMissingLogged = false
        print("PLAYER_DBG [Service] volumeBridge attached host=\(type(of: host))")
    }

    /// 当前系统音量（0…1）。AVAudioSession.outputVolume 只读查询，无需激活会话
    var volume: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else {
            if !volumeSliderMissingLogged {
                volumeSliderMissingLogged = true
                print("PLAYER_DBG [Service] volume SET FAIL reason=noSlider attached=\(volumeView != nil)")
            }
            return
        }
        slider.value = clamped
        print("PLAYER_DBG [Service] volume → \(Int(clamped * 100))%")
    }

    // MARK: 亮度

    /// 当前屏幕亮度（0…1）。UIScreen.main 已废弃（工程要求零警告），
    /// 从视图所在 window 的 screen 取；window 不在场退 1（不做调节）
    func brightness(in window: UIWindow?) -> CGFloat {
        window?.screen.brightness ?? 1
    }

    func setBrightness(_ level: CGFloat, in window: UIWindow?) {
        guard let screen = window?.screen else {
            print("PLAYER_DBG [Service] brightness SET FAIL reason=noWindow")
            return
        }
        screen.brightness = min(max(level, 0), 1)
        print("PLAYER_DBG [Service] brightness → \(Int(screen.brightness * 100))%")
    }

}
