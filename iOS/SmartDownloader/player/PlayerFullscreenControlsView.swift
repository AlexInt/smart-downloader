import UIKit
import Combine
import AVFoundation

// MARK: - 全屏控制层（UIKit，横屏坐标空间，挂在全屏容器内随容器自转）
//
// 对齐用户拍板：信息流没有全屏按钮；全屏态左上角返回 icon = 返回竖屏（exitFullscreen）。
// 内容：顶部 返回 icon（左上）/ 清屏+静音（右上）；底部 进度条 + 时间行（当前 | 剩余/总时长切换）。
// 状态全部经 Combine 订阅同一个 DramaPlayerViewModel（UIKit + Combine 的样板实现），
// 与竖屏卡片共用同一套状态与持久化，不另立状态源。
//
// 可见性 = 手动呼出（点按/进入全屏，3s 自动收起）或 scrubbing（seek 中常驻）。
// insets 为容器本地坐标的安全区（由控制器按旋转方向从窗口安全区映射，避灵动岛）。

/// 全屏容器本地坐标的 UIColor 便捷初始化（与 Shared/DesignTokens 同色值口径）
private extension UIColor {
    convenience init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255, alpha: 1)
    }
}

final class PlayerFullscreenControlsView: UIView {
    private let playback: DramaPlayerViewModel
    private var cancellables = Set<AnyCancellable>()

    // 顶部
    private let backButton = UIButton(type: .custom)
    private let cleanButton = UIButton(type: .custom)
    private let muteButton = UIButton(type: .custom)
    /// 静音时的金色斜线（与竖屏同一视觉语言）
    private let muteSlash = UIView()
    /// 清屏激活的金色斜线
    private let cleanSlash = UIView()
    // 底部
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let timeLabel = UILabel()
    private let timeButton = UIButton(type: .custom)

    /// 容器本地安全区（控制器按旋转方向映射）
    var localInsets: UIEdgeInsets = .zero { didSet { setNeedsLayout() } }
    /// 手动呼出态（点按/进入全屏置位，3s 后收起）
    private var userVisible = false
    private var hideWork: DispatchWorkItem?
    private var lastProgress: CGFloat = -1

    var onBack: (() -> Void)?

    init(playback: DramaPlayerViewModel) {
        self.playback = playback
        super.init(frame: .zero)
        setupViews()
        bind()
        // 初始一致性：非清屏进度条常驻、清屏进度条隐藏；子控件 alpha 由本类统一管理，
        // 父视图 alpha 恒为 1（可见性只动子控件——父视图置 0 会连控制层一起藏死）
        updateVisibility(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    // MARK: 视图

    private func setupViews() {
        backButton.setImage(UIImage(named: "ic_back")?.withRenderingMode(.alwaysTemplate), for: .normal)
        backButton.tintColor = .white
        backButton.backgroundColor = .black.withAlphaComponent(0.35)
        backButton.layer.cornerRadius = 22
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        addSubview(backButton)

        cleanButton.setImage(UIImage(systemName: "rectangle"), for: .normal)
        cleanButton.tintColor = .white
        cleanButton.backgroundColor = .black.withAlphaComponent(0.35)
        cleanButton.layer.cornerRadius = 22
        cleanButton.addTarget(self, action: #selector(cleanTapped), for: .touchUpInside)
        addSubview(cleanButton)
        // 清屏激活的金色斜线（与竖屏同一视觉语言）
        cleanSlash.backgroundColor = UIColor(hex: "#F5C451")
        cleanSlash.layer.cornerRadius = 1.2
        cleanSlash.transform = CGAffineTransform(rotationAngle: .pi / 4)
        cleanSlash.isHidden = true
        cleanButton.addSubview(cleanSlash)

        muteButton.setImage(UIImage(named: "ic_sound")?.withRenderingMode(.alwaysTemplate), for: .normal)
        muteButton.tintColor = .white
        muteButton.backgroundColor = .black.withAlphaComponent(0.35)
        muteButton.layer.cornerRadius = 22
        muteButton.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)
        addSubview(muteButton)
        muteSlash.backgroundColor = UIColor(hex: "#F5C451")
        muteSlash.layer.cornerRadius = 1.4
        muteSlash.transform = CGAffineTransform(rotationAngle: .pi / 4)
        muteSlash.isHidden = true
        muteButton.addSubview(muteSlash)

        progressTrack.backgroundColor = .white.withAlphaComponent(0.30)
        progressTrack.layer.cornerRadius = 2
        addSubview(progressTrack)
        progressFill.backgroundColor = UIColor(hex: "#FF5A5F")
        progressFill.layer.cornerRadius = 2
        progressTrack.addSubview(progressFill)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = .white
        timeLabel.textAlignment = .left
        addSubview(timeLabel)

        timeButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeButton.setTitleColor(.white, for: .normal)
        timeButton.contentHorizontalAlignment = .right
        timeButton.addTarget(self, action: #selector(timeTapped), for: .touchUpInside)
        addSubview(timeButton)
    }

    // MARK: 状态绑定（UIKit + Combine）

    private func bind() {
        playback.$currentTimeText
            .sink { [weak self] in self?.timeLabel.text = $0 }
            .store(in: &cancellables)
        playback.$progress
            .map { CGFloat($0) }
            .removeDuplicates { abs($0 - $1) < 0.001 }
            .sink { [weak self] in self?.lastProgress = $0; self?.setNeedsLayout() }
            .store(in: &cancellables)
        playback.$showRemainingTime
            .sink { [weak self] _ in self?.updateTimeButton() }
            .store(in: &cancellables)
        playback.$durationText
            .sink { [weak self] _ in self?.updateTimeButton() }
            .store(in: &cancellables)
        playback.$remainingTimeText
            .sink { [weak self] _ in self?.updateTimeButton() }
            .store(in: &cancellables)
        playback.$isMuted
            .sink { [weak self] muted in
                self?.muteButton.tintColor = muted ? UIColor(hex: "#9A9AA5") : .white
                self?.muteSlash.isHidden = !muted
            }
            .store(in: &cancellables)
        playback.$isCleanScreen
            .sink { [weak self] clean in
                self?.cleanButton.tintColor = clean ? UIColor(hex: "#9A9AA5") : .white
                self?.cleanSlash.isHidden = !clean
            }
            .store(in: &cancellables)
        // seek 中进度条常驻（清屏下尤其需要）；其余时机跟随手动呼出
        playback.$isScrubbing
            .sink { [weak self] _ in self?.updateVisibility(animated: true) }
            .store(in: &cancellables)
        updateTimeButton()
    }

    private func updateTimeButton() {
        timeButton.setTitle(playback.showRemainingTime ? playback.remainingTimeText : playback.durationText,
                            for: .normal)
    }

    // MARK: 可见性

    /// 点按/进入全屏呼出，3s 自动收起；seek 中强制可见
    func showTransient() {
        userVisible = true
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.userVisible = false
            self?.updateVisibility(animated: true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        updateVisibility(animated: true)
    }

    private func updateVisibility(animated: Bool) {
        let visible = userVisible || playback.isScrubbing
        let actions = { [weak self] in
            self?.backButton.alpha = visible ? 1 : 0
            self?.cleanButton.alpha = visible ? 1 : 0
            self?.muteButton.alpha = visible ? 1 : 0
            self?.timeLabel.alpha = visible ? 1 : 0
            self?.timeButton.alpha = visible ? 1 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: actions)
        } else {
            actions()
        }
        // 进度条本体：非清屏常驻；清屏下跟随手动呼出（点按 3s）与 scrub——与竖屏 HUD 同口径
        let barVisible = !playback.isCleanScreen || userVisible || playback.isScrubbing
        let barActions = { [weak self] in
            self?.progressTrack.alpha = barVisible ? 1 : 0
            self?.progressFill.alpha = barVisible ? 1 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: barActions)
        } else {
            barActions()
        }
    }

    // MARK: 布局（横屏本地坐标，frame 直排）

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height

        // 顶部：返回 icon 左上；清屏/静音右上（44 命中区，间距 8）
        backButton.frame = CGRect(x: localInsets.left + 8, y: localInsets.top + 8, width: 44, height: 44)
        muteButton.frame = CGRect(x: w - localInsets.right - 52, y: localInsets.top + 8, width: 44, height: 44)
        cleanButton.frame = CGRect(x: muteButton.frame.minX - 52, y: localInsets.top + 8, width: 44, height: 44)
        muteSlash.frame = CGRect(x: 8.5, y: 20, width: 27, height: 2.6)
        cleanSlash.frame = CGRect(x: 8.5, y: 20, width: 27, height: 2.6)

        // 底部：进度条（横贯，44pt 高命中带）+ 时间行
        let barWidth = w - localInsets.left - localInsets.right - 16
        let rowY = h - localInsets.bottom - 34
        progressTrack.frame = CGRect(x: localInsets.left + 8, y: rowY - 10, width: barWidth, height: 4)
        let fillWidth = min(max(lastProgress, 0), 1) * barWidth
        progressFill.frame = CGRect(x: 0, y: 0, width: fillWidth, height: 4)
        timeLabel.frame = CGRect(x: localInsets.left + 8, y: rowY, width: 120, height: 22)
        timeButton.frame = CGRect(x: w - localInsets.right - 128, y: rowY, width: 120, height: 28)
    }

    // MARK: 动作

    @objc private func backTapped() {
        print("PLAYER_DBG [Fullscreen] back icon → exitFullscreen")
        onBack?()
    }

    @objc private func cleanTapped() {
        playback.isCleanScreen.toggle()
    }

    @objc private func muteTapped() {
        playback.isMuted.toggle()
    }

    @objc private func timeTapped() {
        playback.toggleTimeDisplay()
    }
}
