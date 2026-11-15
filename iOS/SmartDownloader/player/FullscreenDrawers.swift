import UIKit

// MARK: - 横屏右侧抽屉（画布 22:77 倍速 / 22:78 选集）
//
// 两个抽屉是**全屏旋转容器的子视图**，与 PlayerFullscreenControlsView 同一坐标空间
//（本地 x = 844 长轴、本地 y = 390 短轴），随容器一起自转，故自己不做旋转变换。
//
// 画布几何（全部实读，勿凭目测调整）：
//   22:77 倍速  300×390 r36 底 #1C1E1F。档位 15px #E8E6DF（画布六档，2026-11-15 起五档），
//               行高 22（选中 46），行矩形 x=18 w=228，文字中心 x=132；
//               选中行 r10 #35393B + 文字 #F2F0EA Medium。
//   22:78 选集  300×390 r36 底 #101214，pad18。标题行 @(18,18) 216×32（关闭 20×20 内 12×12 叉，
//               描边 1.8）；网格 @(18,64) 228×321 —— 4 列 46×46 r9 gap9，底 #25282B、
//               数字 14px Inter #E8E6DF；当前集底 #2A2422 + 描边 #A04D42 a0.5 + 数字 #A05243
//               Medium + 右侧 4×4 r2 播放点（gap 3）。
//
// 面板右缘比画布右缘再出血 36（画布 x 580…880 vs 844）：右侧 36 被容器裁掉，
// 内容区 18…246 恰好落在可见区内且左右留白各约 19 —— 这是画布刻意的「贴边出血」，
// 保证内容两侧对称，不是错位。

/// 抽屉种类（画布 22:72 倍速抽屉态 / 22:73 选集抽屉态）
enum FullscreenDrawerKind {
    case rate
    case episodes
}

// MARK: - 横屏几何（控制层与抽屉共用同一套换算，避免两处漂移）

/// 画布 844×390 → 全屏容器本地坐标。
///
/// 容器 bounds = 视频整幅矩形（长边铺满屏幕长边），横屏时**两侧溢出**屏幕被裁，
/// 本地 y 的中央 `screenShort` 段才是屏幕可见区（spill = 上下各溢出多少）。
/// 设计稿是「整屏」口径（x 0…844 覆盖整个屏幕），故 x 直接按容器宽等比，
/// 不再按安全区平移——设计把返回键放在 x=98、面板右缘出血 36，本身就避开了灵动岛与
/// 横条区；再平移一次会让整层控件系统性偏移（与设计稿对不上）。
struct FullscreenLayoutGeometry {
    static let design = CGSize(width: 844, height: 390)

    let containerSize: CGSize
    let localInsets: UIEdgeInsets
    let screenSize: CGSize

    var spill: CGFloat { max(0, (containerSize.height - min(screenSize.width, screenSize.height)) / 2) }
    var visibleTop: CGFloat { spill }
    var visibleBottom: CGFloat { containerSize.height - spill }
    /// 画布宽 → 容器宽
    var sx: CGFloat { containerSize.width / Self.design.width }
    /// 画布高 → 可见区高
    var sy: CGFloat { max((visibleBottom - visibleTop) / Self.design.height, 0.01) }

    func X(_ designX: CGFloat) -> CGFloat { designX * sx }
    func Y(_ designY: CGFloat) -> CGFloat { visibleTop + designY * sy }

    /// 抽屉面板 frame：画布 22:77 / 22:78 的 x=580 w=300 h=390，右缘 880 出血 36 由容器裁掉。
    /// 转体到另一侧时「右侧」落在灵动岛那一边：把面板按岛宽（>36 的部分）整体内移，
    /// 否则面板中段的集数会被岛挖掉
    var drawerFrame: CGRect {
        let islandGuard = max(0, localInsets.right - 36)
        return CGRect(x: X(580) - islandGuard, y: visibleTop,
                      width: 300 * sx, height: 390 * sy)
    }

    /// 选集抽屉态的视频矩形：画布 22:76 的 560×302 @(56,44) r2
    var shrunkVideoFrame: CGRect {
        CGRect(x: X(56), y: Y(44), width: 560 * sx, height: 302 * sy)
    }
}

// MARK: - 面板基类

/// 右侧抽屉面板：内部按画布 300×390 设计坐标排布，外部 frame 由控制器按横屏几何给出。
/// 不裁剪（圆角由容器统一裁切，避免与 container.clipsToBounds 语义打架）
class FullscreenDrawerPanel: UIView {
    static let designSize = CGSize(width: 300, height: 390)

    /// 水平/纵向缩放（画布 844×390 → 真实可见区，两轴比例差 <0.5%，仍分开算更准）
    private(set) var scaleX: CGFloat = 1
    private(set) var scaleY: CGFloat = 1
    /// 线宽/圆角/格子的等比基准（取两轴较小值，避免非等比拉伸变形）
    var designScale: CGFloat { min(scaleX, scaleY) }

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scaleX = bounds.width / Self.designSize.width
        scaleY = bounds.height / Self.designSize.height
        var size = Self.designSize
        size.width *= scaleX
        size.height *= scaleY
        layoutContent(size: size)
    }

    /// 子类按画布坐标排布：入参为已缩放的面板尺寸
    func layoutContent(size: CGSize) {}
}

// MARK: - 倍速抽屉 22:77

final class RateDrawerPanel: FullscreenDrawerPanel {
    /// 当前档位（决定哪一行高亮 + 46 高的位置）
    var currentRate: Double = 1.0 {
        didSet {
            guard abs(currentRate - oldValue) > 0.001 else { return }
            applySelection()
            setNeedsLayout()
        }
    }
    var onSelect: ((Double) -> Void)?

    private let selectedRow = UIView()
    private var rows: [UIButton] = []

    /// 画布纵向切片（相对面板顶）。2026-11-15 移除 3.0× 后档位由 6 变 5，硬编码的
    /// 六个行顶会把整块下半截空出来 —— 改为按档位数在 22…368 内均分（见 layoutContent）
    private enum L {
        static let panelHeight: CGFloat = 390
        static let verticalPadding: CGFloat = 22
        static let normalHeight: CGFloat = 22
        static let selectedHeight: CGFloat = 46
        static let rowLeading: CGFloat = 18
        static let rowWidth: CGFloat = 228
        static let rowCorner: CGFloat = 10
        static let fontSize: CGFloat = 15
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(hex: "#1C1E1F")
        selectedRow.backgroundColor = UIColor(hex: "#35393B")
        selectedRow.isUserInteractionEnabled = false
        addSubview(selectedRow)

        for (index, rate) in DramaPlayerViewModel.rateOptions.enumerated() {
            let button = UIButton(type: .custom)
            button.tag = index
            button.setTitle(playbackRateLabel(rate), for: .normal)
            button.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
            button.accessibilityLabel = playbackRateLabel(rate)
            addSubview(button)
            rows.append(button)
        }
        applySelection()
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    override func layoutContent(size: CGSize) {
        let sx = scaleX, sy = scaleY, s = designScale
        let count = max(rows.count, 1)
        // 档位在面板内均分（画布 22:77 是六档等距切片，档位数变了就按同样节奏重排）
        let slot = (L.panelHeight - L.verticalPadding * 2) / CGFloat(count)
        var selectedTop: CGFloat = 0
        for (index, button) in rows.enumerated() {
            let rate = DramaPlayerViewModel.rateOptions[index]
            let selected = abs(rate - currentRate) < 0.001
            let h = selected ? L.selectedHeight : L.normalHeight
            let top = L.verticalPadding + slot * CGFloat(index) + (slot - h) / 2
            button.frame = CGRect(x: L.rowLeading * sx, y: top * sy,
                                  width: L.rowWidth * sx, height: h * sy)
            button.titleLabel?.font = selected
                ? UIFont.systemFont(ofSize: L.fontSize * s, weight: .medium)
                : UIFont.systemFont(ofSize: L.fontSize * s, weight: .regular)
            if selected { selectedTop = top }
        }
        selectedRow.frame = CGRect(x: L.rowLeading * sx, y: selectedTop * sy,
                                   width: L.rowWidth * sx, height: L.selectedHeight * sy)
        selectedRow.layer.cornerRadius = L.rowCorner * s
    }

    private func applySelection() {
        for (index, button) in rows.enumerated() {
            let rate = DramaPlayerViewModel.rateOptions[index]
            let selected = abs(rate - currentRate) < 0.001
            button.setTitleColor(selected ? UIColor(hex: "#F2F0EA") : UIColor(hex: "#E8E6DF"),
                                 for: .normal)
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
        }
    }

    @objc private func rowTapped(_ sender: UIButton) {
        let index = sender.tag
        guard index >= 0, index < DramaPlayerViewModel.rateOptions.count else { return }
        let rate = DramaPlayerViewModel.rateOptions[index]
        print("PLAYER_DBG [Drawer] rate select \(rate)×")
        onSelect?(rate)
    }
}

// MARK: - 选集抽屉 22:78

final class EpisodeDrawerPanel: FullscreenDrawerPanel {
    /// 面板格子（集号是真实集号；状态含已下载/下载中/未开放）
    private(set) var items: [EpisodePanelItem] = []
    /// 标题位置的一次性提示（下载入队 / 站点未开放…），nil 时显示「选集」
    private var hint: String? {
        didSet { if hint != oldValue { setNeedsLayout() } }
    }
    private(set) var current: Int = 0
    var onSelect: ((Int) -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .custom)
    private let closeGlyph = DrawerCloseGlyphView()
    private let scrollView = UIScrollView()
    private let gridView = UIView()
    private var cells: [EpisodeCellView] = []
    /// rebuild 后待滚到可见的集号（layout 完成才能算 frame）
    private var pendingScrollIndex: Int?

    private enum L {
        static let padding: CGFloat = 18
        static let titleTop: CGFloat = 18
        static let titleHeight: CGFloat = 32
        static let titleWidth: CGFloat = 216
        static let closeBox: CGFloat = 20
        static let closeBoxTop: CGFloat = 6
        static let closeGlyph: CGFloat = 12
        static let gridTop: CGFloat = 64
        static let gridBottomInset: CGFloat = 5
        static let gridWidth: CGFloat = 228
        static let cell: CGFloat = 46
        static let cellGap: CGFloat = 9
        static let cellRadius: CGFloat = 9
        static let columns = 4
        static let numberFont: CGFloat = 14
        static let dot: CGFloat = 4
        static let dotGap: CGFloat = 3
        static let titleFont: CGFloat = 17
        /// 提示文案字号（比标题小一档：标题位临时让给提示，不能撑破 216 宽）
        static let hintFont: CGFloat = 12
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(hex: "#101214")

        titleLabel.text = "选集"
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        addSubview(titleLabel)

        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = "关闭"
        closeButton.addSubview(closeGlyph)
        addSubview(closeButton)

        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        addSubview(scrollView)
        scrollView.addSubview(gridView)
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    override func layoutContent(size: CGSize) {
        let sx = scaleX, sy = scaleY, s = designScale

        closeButton.frame = CGRect(x: L.padding * sx,
                                   y: (L.titleTop + L.closeBoxTop) * sy,
                                   width: L.closeBox * s, height: L.closeBox * s)
        closeGlyph.frame = CGRect(x: (L.closeBox - L.closeGlyph) / 2 * s,
                                  y: (L.closeBox - L.closeGlyph) / 2 * s,
                                  width: L.closeGlyph * s, height: L.closeGlyph * s)

        if let hint {
            titleLabel.text = hint
            titleLabel.font = .systemFont(ofSize: L.hintFont * s, weight: .medium)
            titleLabel.textColor = UIColor(hex: "#A05243")
        } else {
            titleLabel.text = "选集"
            titleLabel.font = PlayerFullscreenControlsView.serifFont(L.titleFont * s, weight: .medium)
            titleLabel.textColor = .white
        }
        titleLabel.frame = CGRect(x: L.padding * sx, y: L.titleTop * sy,
                                  width: L.titleWidth * sx, height: L.titleHeight * sy)

        // 网格在滚动视图里的坐标（0 起）：列 stride 55，格 46
        let cell = L.cell * s
        let gap = L.cellGap * s
        let strideX = cell + gap
        for (i, cellView) in cells.enumerated() {
            let row = i / L.columns
            let col = i % L.columns
            cellView.frame = CGRect(x: CGFloat(col) * strideX,
                                    y: CGFloat(row) * strideX,
                                    width: cell, height: cell)
            cellView.designScale = s
        }
        let rowCount = (cells.count + L.columns - 1) / L.columns
        let contentHeight = rowCount > 0 ? CGFloat(rowCount) * strideX - gap : 0
        // 画布：网格左缘 x=18、宽 228，但滚动视图铺满面板内宽，让格子仍从 18 起
        let gridTop = L.gridTop * sy
        let gridHeight = max(size.height - gridTop - L.gridBottomInset * sy, 1)
        scrollView.frame = CGRect(x: L.padding * sx, y: gridTop,
                                  width: L.gridWidth * sx, height: gridHeight)
        gridView.frame = CGRect(x: 0, y: 0,
                                width: L.gridWidth * sx, height: contentHeight)
        scrollView.contentSize = CGSize(width: L.gridWidth * sx, height: contentHeight)
        // 格子按 s 缩放后总宽 = (46*4+9*3)*s ≈ 228*s；滚动视图宽 228*sx，差在 1pt 内
        if let target = pendingScrollIndex {
            pendingScrollIndex = nil
            scrollToVisible(index: target)
        }
    }

    /// 应用一次面板快照（控制器订阅 `playback.episodePanelSubject` 后每次变化都调）：
    /// **集号列表变了才重建网格**，只是下载态/提示变化时就地重配每格——
    /// 否则下载进度每 0.3s 推进一次就重建整块网格，滚动位置会被拽回当前集并闪一下。
    func apply(state: EpisodePanelState, current: Int) {
        let sortsChanged = state.items.map(\.sort) != items.map(\.sort)
        items = state.items
        self.current = current
        hint = state.hint
        if sortsChanged {
            rebuildGrid()
        } else {
            for (cell, item) in zip(cells, items) {
                cell.configure(item: item, isCurrent: item.sort == current)
            }
        }
        setNeedsLayout()
    }

    private func rebuildGrid() {
        cells.forEach { $0.removeFromSuperview() }
        cells.removeAll()
        guard !items.isEmpty else {
            setNeedsLayout()
            return
        }
        for item in items {
            let cell = EpisodeCellView()
            cell.configure(item: item, isCurrent: item.sort == current)
            cell.onTap = { [weak self] in
                guard let self else { return }
                print("PLAYER_DBG [Drawer] episode select \(item.sort) current=\(self.current) phase=\(item.phase)")
                self.onSelect?(item.sort)
            }
            gridView.addSubview(cell)
            cells.append(cell)
        }
        pendingScrollIndex = current
        setNeedsLayout()
    }

    /// 打开/切集时把当前集滚进视野（画布静态稿是首屏，真实集数上千必须定位）
    private func scrollToVisible(index: Int) {
        guard let cell = cells.first(where: { $0.sort == index }) else { return }
        let inset = L.cellGap * designScale
        let rect = cell.frame.insetBy(dx: 0, dy: -inset * 3)
        scrollView.scrollRectToVisible(rect, animated: false)
    }

    /// 抽屉已上屏后再次定位（控制器在动画完成后调用，此时 frame 才最终稳定）
    func revealCurrent() {
        scrollToVisible(index: current)
    }

    @objc private func closeTapped() {
        print("PLAYER_DBG [Drawer] episode close tap")
        onClose?()
    }
}

/// 单集格子（画布 22:92 / 22:98）
///
/// 状态口径与竖屏弹层、剧集页选集区一致（2026-11-15）：
/// 当前集 = 朱砂数字 + 点 + 朱砂描边；已下载 = 墨白数字；
/// 未下载且可下载 = 数字压暗 + 右下小下箭头；站点未开放 = 更淡且无箭头；
/// 排队/下载中/失败 = 朱砂或淡环。
final class EpisodeCellView: UIView {
    private(set) var sort: Int = 0
    private var item = EpisodePanelItem(sort: 0, phase: .idle, playable: true)
    private var isCurrent = false
    private let numberLabel = UILabel()
    private let dot = UIView()
    private let todoGlyph = EpisodeTodoGlyphView()
    private let ringLayer = CAShapeLayer()
    var onTap: (() -> Void)?
    var designScale: CGFloat = 1 {
        didSet {
            guard abs(designScale - oldValue) > 0.0001 else { return }
            applyStyle()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberLabel.textAlignment = .center
        addSubview(numberLabel)
        dot.isHidden = true
        addSubview(dot)
        todoGlyph.isHidden = true
        addSubview(todoGlyph)
        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.lineWidth = 2
        ringLayer.lineCap = .round
        ringLayer.strokeEnd = 1
        ringLayer.isHidden = true
        layer.addSublayer(ringLayer)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    func configure(item: EpisodePanelItem, isCurrent: Bool) {
        self.sort = item.sort
        self.item = item
        self.isCurrent = isCurrent
        numberLabel.text = "\(item.sort)"
        applyStyle()
        isAccessibilityElement = true
        accessibilityLabel = accessibilityLabel(item)
        accessibilityTraits = isCurrent ? [.button, .selected] : [.button]
    }

    private func accessibilityLabel(_ item: EpisodePanelItem) -> String {
        switch item.phase {
        case .done: return "第 \(item.sort) 集，已下载"
        case .queued, .active: return "第 \(item.sort) 集，正在下载"
        case .failed: return "第 \(item.sort) 集，下载失败"
        case .idle: return item.playable ? "第 \(item.sort) 集，未下载" : "第 \(item.sort) 集，站点未开放"
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = designScale
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 14 * s,
                                                     weight: isCurrent ? .medium : .regular)
        if isCurrent {
            // 画布 22:98：数字 @x15（宽 9）+ gap3 + 点 4 → 整体 16 居中
            let textW = ceil(numberLabel.intrinsicContentSize.width)
            let total = textW + 3 * s + 4 * s
            let x = (bounds.width - total) / 2
            numberLabel.frame = CGRect(x: x, y: 0, width: textW, height: bounds.height)
            dot.frame = CGRect(x: x + textW + 3 * s,
                               y: bounds.midY - 2 * s,
                               width: 4 * s, height: 4 * s)
        } else {
            numberLabel.frame = bounds
        }
        // 右下角未下载下箭头（7×8，离边 4）
        todoGlyph.frame = CGRect(x: bounds.width - 11 * s, y: bounds.height - 12 * s,
                                 width: 7 * s, height: 8 * s)
        // 进度环：描在格子内 1pt 处（圆角同步缩进，避免边缘被裁）
        let inset = 1 * s
        let ringRect = bounds.insetBy(dx: inset, dy: inset)
        ringLayer.frame = bounds
        ringLayer.lineWidth = 2 * s
        ringLayer.path = UIBezierPath(roundedRect: ringRect,
                                      cornerRadius: max(9 * s - inset, 1)).cgPath
    }

    private func applyStyle() {
        backgroundColor = UIColor(hex: isCurrent ? "#2A2422" : "#25282B")
        layer.cornerRadius = 9 * designScale
        layer.borderWidth = isCurrent ? 1 : 0
        layer.borderColor = isCurrent
            ? UIColor(hex: "#A04D42").withAlphaComponent(0.5).cgColor
            : UIColor.clear.cgColor
        numberLabel.textColor = numberColor
        dot.backgroundColor = UIColor(hex: "#A05243")
        dot.layer.cornerRadius = 2 * designScale
        dot.isHidden = !isCurrent
        todoGlyph.isHidden = !(item.phase == .idle && !isCurrent && item.playable)
        todoGlyph.color = UIColor(hex: "#C4C7C3")
        applyRing()
        setNeedsLayout()
    }

    private var numberColor: UIColor {
        if isCurrent { return UIColor(hex: "#A05243") }
        if item.isDownloaded { return UIColor(hex: "#E8E6DF") }
        return item.playable
            ? UIColor(hex: "#C4C7C3")
            : UIColor(hex: "#C4C7C3").withAlphaComponent(0.45)
    }

    private func applyRing() {
        switch item.phase {
        case .idle, .done:
            ringLayer.isHidden = true
        case .queued:
            ringLayer.isHidden = false
            ringLayer.strokeColor = UIColor(hex: "#C4C7C3").withAlphaComponent(0.32).cgColor
            ringLayer.strokeEnd = 1
        case .active(let progress):
            ringLayer.isHidden = false
            ringLayer.strokeColor = UIColor(hex: "#A05243").cgColor
            ringLayer.strokeEnd = CGFloat(min(max(progress, 0.03), 1))
        case .failed:
            ringLayer.isHidden = false
            ringLayer.strokeColor = UIColor(hex: "#A05243").cgColor
            ringLayer.strokeEnd = 1
        }
    }

    @objc private func tapped() {
        print("PLAYER_DBG [Drawer] cell tap sort=\(sort) phase=\(item.phase) playable=\(item.playable)")
        onTap?()
    }
}

/// 未下载格右下角的小下箭头（与竖屏弹层的 `EpisodeTodoGlyph` 同一形状）
final class EpisodeTodoGlyphView: UIView {
    var color: UIColor = UIColor(hex: "#C4C7C3") {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let w = bounds.width, h = bounds.height
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(max(1, w / 7))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: w * 0.5, y: 0))
        ctx.addLine(to: CGPoint(x: w * 0.5, y: h * 0.76))
        ctx.move(to: CGPoint(x: w * 0.16, y: h * 0.46))
        ctx.addLine(to: CGPoint(x: w * 0.5, y: h * 0.82))
        ctx.addLine(to: CGPoint(x: w * 0.84, y: h * 0.46))
        ctx.strokePath()
    }
}

// MARK: - 关闭叉（画布 22:89：20 内 12×12，描边 1.8）

final class DrawerCloseGlyphView: UIView {
    var designScale: CGFloat = 1 {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        // 画布 12×12 叉在 20×20 框内居中：线宽按 12 基准换算再乘全局缩放
        let base = bounds.width / 12
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(1.8 * base)
        ctx.setLineCap(.round)
        ctx.move(to: .zero)
        ctx.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
        ctx.move(to: CGPoint(x: bounds.width, y: 0))
        ctx.addLine(to: CGPoint(x: 0, y: bounds.height))
        ctx.strokePath()
    }
}
