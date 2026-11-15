import UIKit
import Combine
import AVFoundation

// MARK: - 全屏控制层（UIKit，横屏坐标空间，挂在全屏容器内随容器自转）
//
// 按画布 22:1「观影控件层」（844×390）1:1 重做。三栏布局，全部坐标来自画布节点实读：
//   顶栏：返回 18×20 @(98,30)｜剧名与集数 13px serif @(122,30)｜更多 16×20 @(745,31)
//   中部：亮度 26×26 @(106,180)｜暂停双竖条 48×48 @(398,174)｜锁 44×44 @(734,118)｜音量 44×44 @(734,172)
//   底栏：播放/暂停 20×20 @(98,310)（原画布此位是「下一集」，2026-11-15 用户改）
//        ｜当前时间 @(132,311)｜进度轨道 556×2 @(206,318) + 圆点 @(264,315)
//        ｜总时长 @(774,311)｜点赞 @(98,344)｜收藏 @(176,344)｜倍速 @(596,347)｜1080P @(658,347)｜选集 @(726,347)
//   字幕：23px Noto Sans SC Bold 居中 @(326,330)
//
// 配色：全白（#FFFFFF）+ 朱砂进度点（#A05243）。旧版用的 #FF5A5F 进度 / #F5C451 金色激活线
// 属已废弃的深色轨，本次全部弃用。
//
// 可见性 = 手动呼出（点按/进入全屏，3s 自动收起）或 scrubbing（seek 中常驻）。
// insets 为容器本地坐标的安全区（由控制器按旋转方向从窗口安全区映射，避灵动岛）。

/// 全屏容器本地坐标的 UIColor 便捷初始化（与 Shared/DesignTokens 同色值口径）
extension UIColor {
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

    // MARK: 顶栏
    private let backButton = UIButton(type: .custom)
    private let backGlyph = PlayerFullscreenControlsView.makeBackGlyph()
    private let titleLabel = UILabel()
    private let moreButton = UIButton(type: .custom)
    private let moreGlyph = PlayerFullscreenControlsView.makeMoreGlyph()

    // MARK: 中部
    private let brightnessButton = UIButton(type: .custom)
    private let brightnessGlyph = PlayerFullscreenControlsView.makeBrightnessGlyph()
    private let playPauseButton = UIButton(type: .custom)
    private let playGlyph = PlayerFullscreenControlsView.makePlayGlyph()
    private let pauseGlyph = PlayerFullscreenControlsView.makePauseGlyph()
    private let lockButton = UIButton(type: .custom)
    private let lockGlyph = PlayerFullscreenControlsView.makeLockGlyph()
    private let volumeButton = UIButton(type: .custom)
    private let volumeGlyph = PlayerFullscreenControlsView.makeVolumeGlyph()

    // MARK: 底栏
    // 播放/暂停（原画布 22:41「下一集」的位置）：用户 2026-11-15 点名——进度条左边这个位置
    // 应该是播放/暂停，而且必须跟着播放态翻面。「下一集」移到顶栏「更多」菜单里（功能不丢）。
    private let barPlayButton = UIButton(type: .custom)
    private let barPlayGlyph = PlayerFullscreenControlsView.makeBarPlayGlyph()
    private let barPauseGlyph = PlayerFullscreenControlsView.makeBarPauseGlyph()
    private let currentTimeLabel = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let progressDot = UIView()
    private let totalTimeLabel = UILabel()
    // 点赞 / 收藏：只留图标（用户 2026-11-15：数字移除，本地只记状态不报数）
    private let likeButton = UIButton(type: .custom)
    private let likeGlyph = PlayerFullscreenControlsView.makeHeartGlyph()
    private let saveButton = UIButton(type: .custom)
    private let saveGlyph = PlayerFullscreenControlsView.makeStarGlyph()
    private let rateButton = UIButton(type: .custom)
    private let qualityButton = UIButton(type: .custom)
    private let episodeButton = UIButton(type: .custom)

    // MARK: 字幕
    private let subtitleLabel = UILabel()

    // MARK: 压暗
    private let topScrim = CAGradientLayer()
    private let bottomScrim = CAGradientLayer()
    private let topScrimView = UIView()
    private let bottomScrimView = UIView()

    /// 压暗这两层不随控件一起淡出（画布 22:2 / 22:3 属于画面语言，不是控件）
    private var scrimLayers: [CAGradientLayer] { [topScrim, bottomScrim] }

    /// 容器本地安全区（控制器按旋转方向映射）
    var localInsets: UIEdgeInsets = .zero {
        didSet { setNeedsLayout() }
    }
    /// 手动呼出态（点按/进入全屏置位，3s 后收起）
    private var userVisible = false
    private var hideWork: DispatchWorkItem?
    /// 当前播放进度（0…1），布局进度条与圆点用
    private var progress: CGFloat = 0
    /// 布局对账日志只打一次
    private var didLogLayout = false
    /// 可见性状态翻转才打日志（降噪）
    private var lastLoggedVisible: Bool?

    // MARK: 回调（由控制器接线）

    var onBack: (() -> Void)?
    /// 更多菜单（从左下角弹出：从头播放 / 清屏 / 静音）
    var onMore: ((UIView) -> Void)?
    /// 倍速（横屏用右侧抽屉，画布 22:72）
    var onRateTapped: (() -> Void)?
    /// 选集（横屏用右侧抽屉，画布 22:73）
    var onEpisodeTapped: (() -> Void)?
    /// 下一集
    // 下一集按钮已移入顶栏「更多」菜单（2026-11-15），控制层不再单独发这个回调
    /// 清晰度（本地 HLS 只有单一清晰度，点击给出说明 toast）
    var onQualityTapped: (() -> Void)?

    // 画布几何常量（844×390 基准，落到实际容器时按宽高比换算）
    private enum M {
        static let design = CGSize(width: 844, height: 390)
        /// 顶栏基线 y（画布返回 y=30 h=20 → 中心 40）
        static let topRowMidY: CGFloat = 40
        /// 左栏起点（画布返回 x=98）
        static let leadingX: CGFloat = 98
        /// 右栏起点（画布更多 x=745 w=16 → 右缘 761，距右 83）
        static let trailingX: CGFloat = 745
        /// 底部进度条 y（画布 318）
        static let trackY: CGFloat = 318
        static let trackLeading: CGFloat = 206
        /// 轨道右缘 = 206 + 556（画布 22:46 轨道 556 宽）。
        /// **不能写成总时长右缘（774+45=819）**：那会让轨道从「00:24」底下穿过去，
        /// 时间数字压在一条白线上（2026-11-15 用户实机实报）。总时长起点在 774，留 12pt 间隙。
        static let trackTrailing: CGFloat = 762
        /// 时间文字与轨道端点的间隙（左右同一口径，2026-11-15 用户要求收紧）
        static let timeGap: CGFloat = 10
        /// 互动行 y（画布 344 h=22 → 中心 355）
        static let actionMidY: CGFloat = 355
        /// 右栏工具 y（画布 347）
        static let toolMidY: CGFloat = 355
    }

    init(playback: DramaPlayerViewModel) {
        self.playback = playback
        super.init(frame: .zero)
        setupViews()
        bind()
        updateVisibility(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    // MARK: 视图装配

    private func setupViews() {
        // 压暗（画布 22:2 顶 h96 a0.66→0 / 22:3 底 y250 h140 a0→0.78）
        topScrim.colors = [UIColor.black.withAlphaComponent(0.66).cgColor, UIColor.clear.cgColor]
        topScrim.startPoint = CGPoint(x: 0.5, y: 0)
        topScrim.endPoint = CGPoint(x: 0.5, y: 1)
        topScrimView.layer.addSublayer(topScrim)
        topScrimView.isUserInteractionEnabled = false
        addSubview(topScrimView)

        bottomScrim.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.78).cgColor]
        bottomScrim.startPoint = CGPoint(x: 0.5, y: 0)
        bottomScrim.endPoint = CGPoint(x: 0.5, y: 1)
        bottomScrimView.layer.addSublayer(bottomScrim)
        bottomScrimView.isUserInteractionEnabled = false
        addSubview(bottomScrimView)

        // 顶栏
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.addSubview(backGlyph)
        addSubview(backButton)

        titleLabel.font = Self.serifFont(13, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
        moreButton.addSubview(moreGlyph)
        addSubview(moreButton)

        // 中部
        brightnessButton.addTarget(self, action: #selector(brightnessTapped), for: .touchUpInside)
        brightnessButton.addSubview(brightnessGlyph)
        addSubview(brightnessButton)

        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        playPauseButton.addSubview(playGlyph)
        playPauseButton.addSubview(pauseGlyph)
        addSubview(playPauseButton)

        lockButton.addTarget(self, action: #selector(lockTapped), for: .touchUpInside)
        lockButton.addSubview(lockGlyph)
        addSubview(lockButton)

        volumeButton.addTarget(self, action: #selector(volumeTapped), for: .touchUpInside)
        volumeButton.addSubview(volumeGlyph)
        addSubview(volumeButton)

        // 字幕（画布 22:40：23px Noto Sans SC Bold，居中）
        subtitleLabel.font = Self.sansFont(23, weight: .bold)
        subtitleLabel.textColor = .white
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 1
        subtitleLabel.isHidden = true
        addSubview(subtitleLabel)

        // 底栏
        barPlayButton.addTarget(self, action: #selector(barPlayTapped), for: .touchUpInside)
        barPlayButton.addSubview(barPlayGlyph)
        barPlayButton.addSubview(barPauseGlyph)
        addSubview(barPlayButton)

        currentTimeLabel.font = Self.monoFont(11)
        currentTimeLabel.textColor = .white
        currentTimeLabel.textAlignment = .right   // 贴轨道左端（layoutSubviews 里落位）
        addSubview(currentTimeLabel)

        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.45)
        addSubview(progressTrack)
        progressFill.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        progressTrack.addSubview(progressFill)
        // 进度圆点：画布 22:47 是白色 8×8（横屏没有用朱砂；朱砂只出现在竖屏 2:129）
        progressDot.backgroundColor = .white
        progressDot.layer.cornerRadius = 4
        addSubview(progressDot)

        totalTimeLabel.font = Self.monoFont(11)
        totalTimeLabel.textColor = .white
        totalTimeLabel.textAlignment = .left    // 贴轨道右端（layoutSubviews 里落位）
        addSubview(totalTimeLabel)

        // 点赞（画布 22:49：心形 18；数字已按用户要求移除，只记本地状态不报数）
        likeButton.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        likeButton.addSubview(likeGlyph)
        addSubview(likeButton)

        // 收藏（画布 22:60：星形 18；同上，无数字）
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        saveButton.addSubview(saveGlyph)
        addSubview(saveButton)

        // 右栏工具（画布 22:68「倍速」12px / 22:69「1080P」12px Inter Medium / 22:70「选集」12px）
        configureTool(rateButton, title: "倍速", font: Self.sansFont(12, weight: .regular),
                      action: #selector(rateTapped))
        configureTool(qualityButton, title: "1080P", font: Self.monoFont(12, weight: .medium),
                      action: #selector(qualityTapped))
        configureTool(episodeButton, title: "选集", font: Self.sansFont(12, weight: .regular),
                      action: #selector(episodeTapped))

        // 无障碍
        backButton.accessibilityLabel = "返回"
        moreButton.accessibilityLabel = "更多"
        brightnessButton.accessibilityLabel = "亮度"
        lockButton.accessibilityLabel = "锁定"
        volumeButton.accessibilityLabel = "音量"
        playPauseButton.accessibilityLabel = "播放"
        barPlayButton.accessibilityLabel = "暂停"
        rateButton.accessibilityLabel = "倍速"
        qualityButton.accessibilityLabel = "清晰度"
        episodeButton.accessibilityLabel = "选集"
        likeButton.accessibilityLabel = "点赞"
        saveButton.accessibilityLabel = "收藏"
    }

    private func configureTool(_ button: UIButton, title: String, font: UIFont, action: Selector) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = font
        button.addTarget(self, action: action, for: .touchUpInside)
        addSubview(button)
    }

    // MARK: 状态绑定

    private func bind() {
        playback.$currentTimeText
            .sink { [weak self] in self?.currentTimeLabel.text = $0 }
            .store(in: &cancellables)
        playback.$durationText
            .sink { [weak self] in self?.totalTimeLabel.text = $0 }
            .store(in: &cancellables)
        playback.$progress
            .map { CGFloat($0) }
            .removeDuplicates { abs($0 - $1) < 0.001 }
            .sink { [weak self] in
                self?.progress = $0
                self?.setNeedsLayout()
            }
            .store(in: &cancellables)
        // 播放态：暂停时显示播放三角，播放中显示双竖条（画布 22:28 画的是双竖条 = 播放中）
        // 中部大按钮与底栏进度条左侧的按钮共用一个状态，两边必须同步翻面
        playback.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in
                guard let self else { return }
                self.playGlyph.isHidden = playing
                self.pauseGlyph.isHidden = !playing
                self.playPauseButton.accessibilityLabel = playing ? "暂停" : "播放"
                self.barPlayGlyph.isHidden = playing
                self.barPauseGlyph.isHidden = !playing
                self.barPlayButton.accessibilityLabel = playing ? "暂停" : "播放"
                print("PLAYER_DBG [Fullscreen] isPlaying=\(playing) → bar glyph \(playing ? "pause" : "play")")
            }
            .store(in: &cancellables)
        playback.$isMuted
            .removeDuplicates()
            .sink { [weak self] muted in
                self?.volumeGlyph.isMuted = muted
            }
            .store(in: &cancellables)
        // 点赞 / 收藏点亮：朱砂（与竖屏同一语义色）
        playback.$liked
            .removeDuplicates()
            .sink { [weak self] liked in
                self?.likeGlyph.tintColor = liked ? UIColor(hex: "#A05243") : .white
            }
            .store(in: &cancellables)
        playback.$saved
            .removeDuplicates()
            .sink { [weak self] saved in
                self?.saveGlyph.tintColor = saved ? UIColor(hex: "#A05243") : .white
            }
            .store(in: &cancellables)
        // 倍速文案：默认档显示「倍速」，选过档位显示「1.5×」
        playback.$playbackRate
            .sink { [weak self] rate in
                let title = abs(rate - 1.0) < 0.001 ? "倍速" : "\(Self.trimmed(rate))×"
                self?.rateButton.setTitle(title, for: .normal)
            }
            .store(in: &cancellables)
        playback.$isScrubbing
            .sink { [weak self] _ in self?.updateVisibility(animated: true) }
            .store(in: &cancellables)
    }

    // MARK: 可见性

    /// 点按/进入全屏呼出，3s 自动收起；seek 中强制可见。
    /// 锁定态（画布 22:31）例外：只呼出「解锁」这一枚，否则锁了以后无法解开
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

    /// 外部操作（打开抽屉/选中档位）后重新计时，别让控件在手势中途消失
    func keepVisible() {
        showTransient()
    }

    /// 锁定态下手动收起呼出层（抽屉打开时用：抽屉自带关闭，不需要解锁钮叠在上面）
    func hideTransient() {
        userVisible = false
        hideWork?.cancel()
        hideWork = nil
        updateVisibility(animated: true)
    }

    /// 锁定态翻转后重算可见性（控制器订阅 $isFullscreenLocked 调）
    func refreshLockState() {
        updateVisibility(animated: true)
    }

    /// 锁定解锁状态（画布 22:31 锁图标：锁定后用实心锁+朱砂底提示，解开则回到半透明底）
    func updateLockAppearance(locked: Bool) {
        lockGlyph.isLocked = locked
    }

    private func updateVisibility(animated: Bool) {
        let locked = playback.isFullscreenLocked
        // 锁定态：点按只呼出解锁钮，其余一律不显示（含压暗——锁屏看电影不该有控件噪点）
        let visible = locked ? userVisible : (userVisible || playback.isScrubbing)
        if visible != lastLoggedVisible {
            lastLoggedVisible = visible
            print("PLAYER_DBG [Fullscreen] controls visible=\(visible) user=\(userVisible) scrub=\(playback.isScrubbing) locked=\(locked)")
        }
        let alpha: CGFloat = visible ? 1 : 0
        let normalControls: [UIView] = [
            backButton, titleLabel, moreButton,
            brightnessButton, playPauseButton,
            barPlayButton, currentTimeLabel, totalTimeLabel,
            likeButton, saveButton,
            rateButton, qualityButton, episodeButton,
            subtitleLabel, progressTrack, progressDot
        ]
        var controls = normalControls
        controls.append(volumeButton)
        controls.append(lockButton)
        let apply = {
            normalControls.forEach { $0.alpha = locked ? 0 : alpha }
            // 锁定态呼出层只有解锁钮；未锁定则跟随正常可见性
            self.volumeButton.alpha = locked ? 0 : alpha
            self.lockButton.alpha = alpha
            // 压暗不随控件淡出：画布把压暗当画面语言（全屏看电影时上下留暗是常态）
            // 但清屏/锁定态应更克制——只在可见时给暗，避免整片灰
            self.topScrimView.alpha = locked ? 0 : alpha
            self.bottomScrimView.alpha = locked ? 0 : alpha
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: apply)
        } else {
            apply()
        }
    }

    // MARK: 布局（横屏本地坐标，frame 直排）

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        // 容器足迹=视频整幅矩形，横屏时两侧溢出屏幕被裁；本地 y 的中央 screenShort 段才是
        // 屏幕可见区。几何换算与抽屉共用 FullscreenLayoutGeometry，避免两处漂移
        let screenSize = window?.bounds.size ?? .zero
        let geo = FullscreenLayoutGeometry(containerSize: bounds.size,
                                           localInsets: localInsets,
                                           screenSize: screenSize)
        let spill = geo.spill
        let s = min(geo.sx, geo.sy)
        /// 画布 x（844 长轴）→ 容器 x
        func X(_ designX: CGFloat) -> CGFloat { geo.X(designX) }
        /// 画布 y（390 短轴）→ 容器 y
        func Y(_ designY: CGFloat) -> CGFloat { geo.Y(designY) }

        // 压暗层
        topScrimView.frame = CGRect(x: 0, y: 0, width: w, height: min(Y(96), bounds.height))
        topScrim.frame = topScrimView.bounds
        bottomScrimView.frame = CGRect(x: 0, y: Y(250), width: w, height: max(bounds.height - Y(250), 1))
        bottomScrim.frame = bottomScrimView.bounds

        // ── 顶栏 ──
        // 返回：画布 18×20 @(98,30)，命中区 44
        backButton.frame = centered(at: CGPoint(x: X(107), y: Y(40)), size: 44)
        backGlyph.frame = CGRect(x: (44 - 18) / 2, y: (44 - 20) / 2, width: 18, height: 20)
        // 剧名与集数：画布 197×19 @(122,30)
        titleLabel.frame = CGRect(x: X(122), y: Y(30), width: min(197 * geo.sx, w - X(122) - 70), height: 19 * s)
        titleLabel.font = Self.serifFont(13 * s, weight: .medium)
        // 更多：画布 16×20 @(745,31)，命中区 44
        moreButton.frame = centered(at: CGPoint(x: X(753), y: Y(41)), size: 44)
        moreGlyph.frame = CGRect(x: (44 - 16) / 2, y: (44 - 20) / 2, width: 16, height: 20)

        // ── 中部 ──
        // 亮度：画布 26×26 @(106,180)，命中区 44
        brightnessButton.frame = centered(at: CGPoint(x: X(119), y: Y(193)), size: 44)
        brightnessGlyph.frame = CGRect(x: (44 - 26) / 2, y: (44 - 26) / 2, width: 26, height: 26)
        // 暂停/播放：画布 48×48 @(398,174)，命中区 48（本身够大，不再扩）
        playPauseButton.frame = CGRect(x: X(398), y: Y(174), width: 48 * s, height: 48 * s)
        let glyph48 = CGRect(origin: .zero, size: playPauseButton.bounds.size)
        pauseGlyph.frame = glyph48
        // 播放三角：同尺寸容器内居中（画布只给了暂停态）
        playGlyph.frame = glyph48
        // 锁 / 音量：画布 44×44 @(734,118) / @(734,172)
        lockButton.frame = CGRect(x: X(734), y: Y(118), width: 44 * s, height: 44 * s)
        lockGlyph.frame = lockButton.bounds
        volumeButton.frame = CGRect(x: X(734), y: Y(172), width: 44 * s, height: 44 * s)
        volumeGlyph.frame = volumeButton.bounds
        lockGlyph.glyphScale = s
        volumeGlyph.glyphScale = s
        brightnessGlyph.glyphScale = s

        // 字幕：画布 184×33 @(326,330)，水平居中
        let subtitleW = min(184 * geo.sx, w - 40)
        subtitleLabel.frame = CGRect(x: (w - subtitleW) / 2, y: Y(330), width: subtitleW, height: 33 * s)
        subtitleLabel.font = Self.sansFont(23 * s, weight: .bold)

        // ── 底栏 ──
        // 播放/暂停：占原「下一集」位（画布 20×20 @(98,310)，命中区 44）
        barPlayButton.frame = centered(at: CGPoint(x: X(108), y: Y(320)), size: 44)
        let barGlyphRect = CGRect(x: (44 - 20) / 2, y: (44 - 20) / 2, width: 20, height: 20)
        barPlayGlyph.frame = barGlyphRect
        barPauseGlyph.frame = barGlyphRect
        barPlayGlyph.glyphScale = s
        barPauseGlyph.glyphScale = s
        // 当前时间 / 总时长：都贴着自己那一侧的轨道端点，间隙统一 10（2026-11-15 用户要求收紧——
        // 画布原坐标 132 / 774 是从整条画面排的，轨道改短后左 41pt、右 24pt 的空当太散）。
        // 左标右对齐、右标左对齐，数字跟着轨道走，换机型缩放时不会漂。
        let timeW = 70 * geo.sx
        currentTimeLabel.textAlignment = .right
        currentTimeLabel.frame = CGRect(x: X(M.trackLeading - M.timeGap) - timeW,
                                        y: Y(311), width: timeW, height: 14 * s)
        currentTimeLabel.font = Self.monoFont(11 * s)
        // 进度轨道：画布 556×2 @(206,318)
        let trackX = X(M.trackLeading)
        let trackRight = X(M.trackTrailing)
        let trackW = max(trackRight - trackX, 1)
        let trackH = max(2 * s, 2)
        progressTrack.frame = CGRect(x: trackX, y: Y(M.trackY), width: trackW, height: trackH)
        progressTrack.layer.cornerRadius = trackH / 2
        let fillW = min(max(progress, 0), 1) * trackW
        progressFill.frame = CGRect(x: 0, y: 0, width: fillW, height: trackH)
        progressFill.layer.cornerRadius = trackH / 2
        // 圆点 8×8 @(264,315)：中心落在轨道中线上
        let dotSize = max(8 * s, 8)
        progressDot.frame = CGRect(x: trackX + fillW - dotSize / 2,
                                   y: Y(M.trackY) + trackH / 2 - dotSize / 2,
                                   width: dotSize, height: dotSize)
        progressDot.layer.cornerRadius = dotSize / 2
        totalTimeLabel.textAlignment = .left
        totalTimeLabel.frame = CGRect(x: X(M.trackTrailing + M.timeGap),
                                      y: Y(311), width: timeW, height: 14 * s)
        totalTimeLabel.font = Self.monoFont(11 * s)

        // 点赞 / 收藏：只留图标（数字已移除），画布 18×18 @(98,344) / @(176,344)
        layoutAction(button: likeButton, glyph: likeGlyph,
                     designX: 98, designMidY: M.actionMidY, scale: s, X: X, Y: Y)
        layoutAction(button: saveButton, glyph: saveGlyph,
                     designX: 176, designMidY: M.actionMidY, scale: s, X: X, Y: Y)

        // 右栏工具：倍速 @596 / 1080P @658 / 选集 @726，y=347（中心 355）
        layoutTool(rateButton, designX: 596, designW: 24, scale: s, X: X, Y: Y)
        layoutTool(qualityButton, designX: 658, designW: 36, scale: s, X: X, Y: Y)
        layoutTool(episodeButton, designX: 726, designW: 24, scale: s, X: X, Y: Y)

        // 一次性布局对账日志（排障用，按约定保留）
        if !didLogLayout {
            didLogLayout = true
            print("PLAYER_DBG [CHECK] fullscreenControls bounds=\(bounds) spill=\(spill) s=\(String(format: "%.3f", s)) track=\(progressTrack.frame) insets=\(localInsets)")
        }
    }

    // MARK: 布局辅助

    private func centered(at center: CGPoint, size: CGFloat) -> CGRect {
        CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }

    private func layoutAction(button: UIButton, glyph: FullscreenGlyphView,
                              designX: CGFloat, designMidY: CGFloat,
                              scale s: CGFloat,
                              X: (CGFloat) -> CGFloat, Y: (CGFloat) -> CGFloat) {
        // 画布：图标 18，命中区图标 +10。数字已移除，整体只有一枚图标
        let iconSize = 18 * s
        let midY = Y(designMidY)
        button.frame = CGRect(x: X(designX) - 5, y: midY - iconSize / 2 - 5,
                              width: iconSize + 10, height: iconSize + 10)
        glyph.frame = CGRect(x: 5, y: 5, width: iconSize, height: iconSize)
        glyph.glyphScale = s
    }

    private func layoutTool(_ button: UIButton, designX: CGFloat, designW: CGFloat,
                            scale s: CGFloat,
                            X: (CGFloat) -> CGFloat, Y: (CGFloat) -> CGFloat) {
        let midY = Y(M.toolMidY)
        // 命中区 60×40，文字按画布原位
        button.frame = CGRect(x: X(designX) - 12, y: midY - 20,
                              width: max(designW * s, 24) + 24, height: 40)
        button.titleLabel?.font = button.titleLabel?.font.withSize(12 * s)
    }

    // MARK: 动作

    @objc private func backTapped() {
        print("PLAYER_DBG [Fullscreen] back icon → exitFullscreen")
        onBack?()
    }

    @objc private func moreTapped() {
        print("PLAYER_DBG [Fullscreen] more tap → menu")
        keepVisible()
        onMore?(moreButton)
    }

    @objc private func brightnessTapped() {
        print("PLAYER_DBG [Fullscreen] brightness tap")
        keepVisible()
    }

    @objc private func playPauseTapped() {
        print("PLAYER_DBG [CHECK] fullscreen playPause tap → togglePlayback")
        playback.togglePlayback()
        keepVisible()
    }

    @objc private func lockTapped() {
        print("PLAYER_DBG [Fullscreen] lock tap locked=\(!playback.isFullscreenLocked)")
        playback.isFullscreenLocked.toggle()
        lockGlyph.isLocked = playback.isFullscreenLocked
        // 锁定后控件一律不显示（含点按呼出），由 updateVisibility 统一裁决
        userVisible = false
        hideWork?.cancel()
        updateVisibility(animated: true)
        // 解锁瞬间给一次呼出（否则解开后整层空白，用户以为卡了）
        if !playback.isFullscreenLocked { showTransient() }
    }

    @objc private func volumeTapped() {
        print("PLAYER_DBG [CHECK] fullscreen volume tap → isMuted=\(!playback.isMuted)")
        playback.isMuted.toggle()
        keepVisible()
    }

    @objc private func barPlayTapped() {
        print("PLAYER_DBG [CHECK] fullscreen bar play/pause tap → togglePlayback (isPlaying=\(playback.isPlaying))")
        playback.togglePlayback()
        keepVisible()
    }

    @objc private func rateTapped() {
        print("PLAYER_DBG [Fullscreen] rate tap → rate drawer")
        onRateTapped?()
        keepVisible()
    }

    @objc private func qualityTapped() {
        print("PLAYER_DBG [Fullscreen] quality tap")
        onQualityTapped?()
        keepVisible()
    }

    @objc private func episodeTapped() {
        print("PLAYER_DBG [Fullscreen] episode tap → episode drawer")
        onEpisodeTapped?()
        keepVisible()
    }

    @objc private func likeTapped() {
        print("PLAYER_DBG [CHECK] fullscreen like tap → \(!playback.liked)")
        playback.liked.toggle()
        keepVisible()
    }

    @objc private func saveTapped() {
        print("PLAYER_DBG [CHECK] fullscreen save tap → \(!playback.saved)")
        playback.saved.toggle()
        keepVisible()
    }

    // MARK: 外部数据注入（控制器在进入/切集时调用）

    /// 剧名与集数（画布 22:16「都重生了谁谈恋爱啊第一季  第8集」，两空格分隔）
    func updateTitle(series: String, index: Int) {
        titleLabel.text = "\(series)  第\(index)集"
    }

    /// 字幕（画布 22:40）：无字幕轨时整块隐藏
    func updateSubtitle(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        subtitleLabel.text = (trimmed?.isEmpty == false) ? trimmed : nil
        subtitleLabel.isHidden = subtitleLabel.text == nil
    }

    // MARK: 字体与文案

    /// 衬线（画布用 Noto Serif SC；未内置字体时退回系统衬线，与 DWFont.serif 同口径）
    static func serifFont(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
        if let descriptor = UIFont.systemFont(ofSize: size, weight: weight)
            .fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    static func sansFont(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func monoFont(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    private static func trimmed(_ rate: Double) -> String {
        String(format: "%.2f", rate)
            .replacingOccurrences(of: "0$", with: "")
            .replacingOccurrences(of: "\\.$", with: "")
    }

    // MARK: 图标构件（按画布几何绘制，尺寸随 glyphScale 缩放）
    //
    // 全部用 CGContext 直绘（不用 SwiftUI 的 Path / StrokeStyle——那是 SwiftUI 类型，
    // 在 UIKit 的 CGContext 闭包里不可用）。坐标一律取画布设计值 × 容器换算系数 s。

    /// 描边一条路径（统一 round cap/join：画布全部图标都是圆头线）
    private static func stroke(_ ctx: CGContext, _ path: CGPath, _ color: UIColor,
                               width: CGFloat, cap: CGLineCap = .round) {
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineJoin(.round)
        ctx.setLineCap(cap)
        ctx.strokePath()
    }

    /// 填充一条路径
    private static func fill(_ ctx: CGContext, _ path: CGPath, _ color: UIColor) {
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    static func makeBackGlyph() -> FullscreenGlyphView {
        // 画布 22:15：7×14 的 V 形箭臂，描边 1.8
        FullscreenGlyphView { ctx, size, color in
            let s = size.width / 18
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 11.5 * s, y: 3 * s))
            path.addLine(to: CGPoint(x: 4.5 * s, y: 10 * s))
            path.addLine(to: CGPoint(x: 11.5 * s, y: 17 * s))
            stroke(ctx, path, color, width: 1.8 * s)
        }
    }

    static func makeMoreGlyph() -> FullscreenGlyphView {
        // 画布 22:21：三枚 2.8 圆点，竖向 y=2.6 / 8.6 / 14.6
        FullscreenGlyphView { ctx, size, color in
            let s = size.width / 16
            for y in [2.6, 8.6, 14.6] {
                let rect = CGRect(x: (16 - 2.8) / 2 * s, y: y * s,
                                  width: 2.8 * s, height: 2.8 * s)
                fill(ctx, CGPath(ellipseIn: rect, transform: nil), color)
            }
        }
    }

    static func makeBrightnessGlyph() -> FullscreenGlyphView {
        // 画布 22:25：日心 9.2 @(8.4,8.4) + 8 条射线到 20.8，描边 1.7
        FullscreenGlyphView { ctx, size, color in
            let s = size.width / 26
            let core = CGRect(x: 8.4 * s, y: 8.4 * s, width: 9.2 * s, height: 9.2 * s)
            stroke(ctx, CGPath(ellipseIn: core, transform: nil), color, width: 1.7 * s)
            let c = CGPoint(x: 13 * s, y: 13 * s)
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                let ray = CGMutablePath()
                ray.move(to: CGPoint(x: c.x + cos(a) * 7.6 * s, y: c.y + sin(a) * 7.6 * s))
                ray.addLine(to: CGPoint(x: c.x + cos(a) * 10.4 * s, y: c.y + sin(a) * 10.4 * s))
                stroke(ctx, ray, color, width: 1.7 * s)
            }
        }
    }

    static func makePauseGlyph() -> FullscreenGlyphView {
        // 画布 22:28：两条 7×32 r3.5 白色竖条，x=14 / x=27，y=8
        FullscreenGlyphView { ctx, size, color in
            let s = size.width / 48
            for x in [14.0, 27.0] {
                let bar = CGRect(x: x * s, y: 8 * s, width: 7 * s, height: 32 * s)
                let path = CGPath(roundedRect: bar, cornerWidth: 3.5 * s,
                                  cornerHeight: 3.5 * s, transform: nil)
                fill(ctx, path, color)
            }
        }
    }

    static func makePlayGlyph() -> FullscreenGlyphView {
        // 画布未给播放态；按同尺寸容器画一个饱满三角（与竖屏 19:58 同一造型语言）
        FullscreenGlyphView { ctx, size, color in
            let s = size.width / 48
            let tri = CGMutablePath()
            tri.move(to: CGPoint(x: 16 * s, y: 10 * s))
            tri.addLine(to: CGPoint(x: 36 * s, y: 24 * s))
            tri.addLine(to: CGPoint(x: 16 * s, y: 38 * s))
            tri.closeSubpath()
            fill(ctx, tri, color)
        }
    }

    static func makeLockGlyph() -> LockGlyphView {
        LockGlyphView()
    }

    static func makeVolumeGlyph() -> VolumeGlyphView {
        VolumeGlyphView()
    }

    static func makeBarPlayGlyph() -> FullscreenGlyphView {
        // 底栏播放/暂停（原 22:41 位，20×20 框）：播放三角 7×11 居中偏移 1 视觉配重
        FullscreenGlyphView { ctx, size, color in
            let s = size.width / 20
            let tri = CGMutablePath()
            tri.move(to: CGPoint(x: 6 * s, y: 4.5 * s))
            tri.addLine(to: CGPoint(x: 15 * s, y: 10 * s))
            tri.addLine(to: CGPoint(x: 6 * s, y: 15.5 * s))
            tri.closeSubpath()
            fill(ctx, tri, color)
        }
    }

    static func makeBarPauseGlyph() -> FullscreenGlyphView {
        // 双竖条 2.6×11 r1.3，x=6.2 / 11.2，与播放三角同视觉重量
        FullscreenGlyphView { ctx, size, color in
            let s = size.width / 20
            for x in [6.2, 11.2] {
                let bar = CGRect(x: x * s, y: 4.5 * s, width: 2.6 * s, height: 11 * s)
                fill(ctx, CGPath(roundedRect: bar, cornerWidth: 1.3 * s,
                                 cornerHeight: 1.3 * s, transform: nil), color)
            }
        }
    }

    static func makeHeartGlyph() -> FullscreenGlyphView {
        // 画布 22:50：18×18 内 14×12 实心心 @(2,3.5)
        FullscreenGlyphView { ctx, size, color in
            let s = size.width / 18
            let w = 14 * s, h = 12 * s, x = 2 * s, y = 3.5 * s
            let heart = CGMutablePath()
            heart.move(to: CGPoint(x: x + w / 2, y: y + h))
            heart.addCurve(to: CGPoint(x: x, y: y + h * 0.32),
                           control1: CGPoint(x: x + w * 0.22, y: y + h * 0.78),
                           control2: CGPoint(x: x, y: y + h * 0.58))
            heart.addCurve(to: CGPoint(x: x + w / 2, y: y + h * 0.22),
                           control1: CGPoint(x: x, y: y + h * 0.02),
                           control2: CGPoint(x: x + w * 0.34, y: y - h * 0.06))
            heart.addCurve(to: CGPoint(x: x + w, y: y + h * 0.32),
                           control1: CGPoint(x: x + w * 0.66, y: y - h * 0.06),
                           control2: CGPoint(x: x + w, y: y + h * 0.02))
            heart.addCurve(to: CGPoint(x: x + w / 2, y: y + h),
                           control1: CGPoint(x: x + w, y: y + h * 0.58),
                           control2: CGPoint(x: x + w * 0.78, y: y + h * 0.78))
            heart.closeSubpath()
            fill(ctx, heart, color)
        }
    }

    static func makeStarGlyph() -> FullscreenGlyphView {
        // 画布 22:61：18×18 内 14×13.4 实心五角星 @(2,1.8)
        FullscreenGlyphView { ctx, size, color in
            let s = size.width / 18
            let rect = CGRect(x: 2 * s, y: 1.8 * s, width: 14 * s, height: 13.4 * s)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outerR = rect.width / 2
            let innerR = outerR * 0.42
            let star = CGMutablePath()
            for i in 0..<10 {
                let r = i.isMultiple(of: 2) ? outerR : innerR
                let a = -Double.pi / 2 + Double(i) * .pi / 5
                let p = CGPoint(x: center.x + cos(a) * r,
                                y: center.y + sin(a) * r * (rect.height / rect.width))
                if i == 0 { star.move(to: p) } else { star.addLine(to: p) }
            }
            star.closeSubpath()
            fill(ctx, star, color)
        }
    }
}

// MARK: - 可描边图标视图（SwiftUI Canvas 思路的 UIKit 版）

/// 用 CGContext 绘制、随 tintColor 变色的图标。尺寸由外部 frame 决定，
/// glyphScale 用于在容器缩放时同步线宽（画布坐标 1:1 落在 44/48/26 的容器里）。
class FullscreenGlyphView: UIView {
    typealias Draw = (CGContext, CGSize, UIColor) -> Void

    private let draw: Draw
    private let drawsBackground: Bool
    var glyphScale: CGFloat = 1 {
        didSet { setNeedsDisplay() }
    }

    override var tintColor: UIColor! {
        didSet { setNeedsDisplay() }
    }

    init(drawsBackground: Bool = false, draw: @escaping Draw) {
        self.draw = draw
        self.drawsBackground = drawsBackground
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
        tintColor = .white
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        // UIKit 绘制上下文本身就是「左上原点、y 向下」，与画布坐标同向——不做翻转。
        // （这里不翻译 CTM：翻一次会把整枚图标上下颠倒）
        if drawsBackground {
            let radius = 11 * (bounds.width / 44)
            UIColor(hex: "#8C9190").withAlphaComponent(0.42).setFill()
            UIBezierPath(roundedRect: bounds, cornerRadius: radius).fill()
        }
        draw(ctx, bounds.size, tintColor)
    }
}

/// 音量图标（画布 22:36：喇叭 10×18 @(14,13) 描边 2 + 声波；静音时画斜线）
final class VolumeGlyphView: FullscreenGlyphView {
    var isMuted = false {
        didSet { setNeedsDisplay() }
    }

    init() {
        super.init(drawsBackground: true) { _, _, _ in }
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        // UIKit 上下文即「左上原点、y 向下」，与画布同向，不翻转
        let s = bounds.width / 44
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        // 喇叭轮廓（画布 22:36：10×18 @(14,13)，描边 2）
        let horn = CGMutablePath()
        horn.move(to: P(14, 19))
        horn.addLine(to: P(18, 19))
        horn.addLine(to: P(24, 13))
        horn.addLine(to: P(24, 31))
        horn.addLine(to: P(18, 25))
        horn.addLine(to: P(14, 25))
        horn.closeSubpath()
        ctx.addPath(horn)
        ctx.setStrokeColor(tintColor.cgColor)
        ctx.setLineWidth(2 * s)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.strokePath()
        if isMuted {
            // 静音：一道斜线贯穿（3:36 右侧的声波位置）
            ctx.move(to: P(15, 15))
            ctx.addLine(to: P(31, 31))
            ctx.setStrokeColor(tintColor.cgColor)
            ctx.setLineWidth(2.2 * s)
            ctx.setLineCap(.round)
            ctx.strokePath()
        } else {
            // 声波：7×14 @(28,15) 的两段弧，简化为一段外弧
            ctx.addArc(center: P(24, 22), radius: 9 * s,
                       startAngle: -55 * .pi / 180, endAngle: 55 * .pi / 180, clockwise: false)
            ctx.setStrokeColor(tintColor.cgColor)
            ctx.setLineWidth(1.8 * s)
            ctx.setLineCap(.round)
            ctx.strokePath()
        }
    }
}

/// 锁图标（画布 22:31：底 44 r11 #8C9190 a0.42；锁梁 @(17,11) 描边 2、
/// 锁体 14×13 r2.5 @(15,19) 描边 2、锁孔竖线 3.5）。
/// 锁定态：底换朱砂（#A05243 a0.55）并高亮锁孔，一眼可辨「已经锁上了」
final class LockGlyphView: FullscreenGlyphView {
    var isLocked = false {
        didSet {
            guard isLocked != oldValue else { return }
            setNeedsDisplay()
        }
    }

    init() {
        super.init(drawsBackground: false) { _, _, _ in }
        // 锁定态由自己绘制，但底色的圆角/颜色在 draw 里；这里只需允许交互外的重绘
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let s = bounds.width / 44

        // 底（画布 a0.42 灰；锁定态换朱砂）
        let bg = isLocked
            ? UIColor(hex: "#A05243").withAlphaComponent(0.55)
            : UIColor(hex: "#8C9190").withAlphaComponent(0.42)
        bg.setFill()
        UIBezierPath(roundedRect: bounds, cornerRadius: 11 * s).fill()

        // UIKit 上下文即「左上原点、y 向下」，与画布同向，不翻转
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        ctx.setStrokeColor(tintColor.cgColor)
        ctx.setLineWidth(2 * s)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // 锁梁：从 y=19 竖直上升到 y=15，拱过顶部再回到 y=19
        ctx.move(to: P(17, 19))
        ctx.addLine(to: P(17, 15))
        ctx.addArc(center: P(22, 15), radius: 5 * s,
                   startAngle: .pi, endAngle: 0, clockwise: false)
        ctx.addLine(to: P(27, 19))
        ctx.strokePath()
        // 锁体 14×13 r2.5 @(15,19)
        ctx.addPath(UIBezierPath(roundedRect: CGRect(x: 15 * s, y: 19 * s,
                                                     width: 14 * s, height: 13 * s),
                                 cornerRadius: 2.5 * s).cgPath)
        ctx.strokePath()
        // 锁孔竖线
        ctx.move(to: P(22, 24))
        ctx.addLine(to: P(22, 27.5))
        ctx.strokePath()
    }
}
