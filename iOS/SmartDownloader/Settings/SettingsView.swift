import SwiftUI

/// 设置页（画布 24:43「设置页 · 纸本」，390×844）。
///
/// 纸本轨的二级页：宣纸底 + 自绘导航栏（返回箭头 / 衬线标题 / 恢复默认）+ 三组设置。
/// 几何全部取自画布节点实读，间距是按设计稿逐行实测标定的（不是目测）：
/// 导航栏 63 = padding 10 + 内容 43 + padding 10，分隔线 1；
/// 组标行高 16、行 40、脚注行高 14（fs10 × 1.4）、组间 4、组间细线 1。
///
/// 现在是「我的」页的二级页（`ProfileView` 身份行齿轮 push 进入），
/// **导航栈由 ProfileView 提供，本页不要自建 NavigationStack**；
/// 系统导航栏被隐藏（设计稿是自绘顶栏），右滑返回由 `swipeBackEnabled()` 补回。
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SettingsViewModel()

    /// 「启动进入」选择面板（设计稿行尾是「›」，语义为推入选择页，用底部面板承接）
    @State private var showsLaunchPicker = false
    /// 恢复默认会清掉用户自建的站点，先确认
    @State private var showsRestoreConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                launchGroup
                dramaGroup
                quickLinkGroup
                versionFooter
            }
            .padding(.horizontal, DWLayout.edge)
            .padding(.top, 6)          // 30:2 分组列表 padding top
            .padding(.bottom, 24)
        }
        .background(DWColor.paper.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { navigationBar }
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackEnabled()
        // 站点编辑器（新增/修改共用）
        .sheet(item: $viewModel.draft) { draft in
            QuickLinkEditorSheet(viewModel: viewModel, draft: draft)
        }
        .confirmationDialog("恢复默认设置？", isPresented: $showsRestoreConfirm, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) { viewModel.restoreDefaults() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("启动进入、剧集页开关与快捷站点都会回到出厂状态，自建的站点会被清掉。")
        }
    }

    // MARK: - 24:56 导航栏（返回 / 设置 / 恢复默认）

    private var navigationBar: some View {
        VStack(spacing: 0) {
            // 标题不是「页面水平居中」：设计稿实测标题墨迹 x 148…205（中心 177），
            // 而页面中心是 195 —— 它是居中于「返回箭头右沿」与「恢复默认左沿」之间。
            // 用两个等分 Spacer 复现这条规则，别改成 ZStack 居中（会右移 18pt）。
            HStack(spacing: 0) {
                Button { dismiss() } label: {
                    ChevronShape(pointsLeft: true)
                        .stroke(DWColor.paperInk,
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 8.5, height: 17)
                        .frame(width: 12, height: 20)          // 24:147 箭头框：布局宽固定 12
                        .padding(.vertical, 11)                // 只上下扩命中区，不影响标题定位
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")

                Spacer(minLength: 8)

                Text("设置")                                    // 24:57 衬线 fs30
                    .font(DWFont.serif(30, .medium))
                    .foregroundStyle(DWColor.paperInk)

                Spacer(minLength: 8)

                Button { showsRestoreConfirm = true } label: {
                    Text("恢复默认")                            // 30:1 fs12 #5A5F60
                        .font(DWFont.cn(12))
                        .foregroundStyle(DWColor.paperIcon)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DWLayout.edge)
            .frame(height: 63)

            Rectangle()                                          // 24:67 分隔细线
                .fill(DWColor.paperDivider)
                .frame(height: 1)
        }
        .background(DWColor.paper)
        // 选择面板挂在顶栏上：与页面主 sheet（站点编辑器）分属两棵子树，互不抢占
        .sheet(isPresented: $showsLaunchPicker) {
            LaunchTabPicker(selection: $viewModel.launchTab)
        }
    }

    // MARK: - 分组 · 启动（30:3）

    private var launchGroup: some View {
        SettingsGroup("启动", topPadding: 8) {
            PaperRow(action: { showsLaunchPicker = true }) {
                HStack(spacing: 0) {
                    Text("启动进入")                              // 30:6 fs14
                        .font(DWFont.cn(14))
                        .foregroundStyle(DWColor.paperInk)
                    Spacer(minLength: 8)
                    Text(viewModel.launchTab.title)               // 30:7 fs13
                        .font(DWFont.cn(13))
                        .foregroundStyle(DWColor.paperInkSub)
                    ChevronShape()                                // 30:8 箭头 8×14（矢量本体 6×12）
                        .stroke(DWColor.paperLineIdle,
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 6, height: 12)
                        .padding(.leading, 6)                     // 贴太近会和值字糊成一个字
                }
            }
        } footnote: {
            SettingsFootnote("下次冷启动生效，当前会话不会自动跳转。")
        }
    }

    // MARK: - 分组 · 剧集页（30:12）

    private var dramaGroup: some View {
        SettingsGroup("剧集页", topPadding: 10) {
            PaperRow(action: nil) {                                 // 整行不可点：只有开关响应
                HStack(spacing: 0) {
                    Text("打开 Web 剧集页")                        // 30:15
                        .font(DWFont.cn(14))
                        .foregroundStyle(DWColor.paperInk)
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            viewModel.useWebDramaPage.toggle()
                        }
                    } label: {
                        PaperSwitch(isOn: viewModel.useWebDramaPage)   // 30:16 40×24
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开 Web 剧集页")
                    .accessibilityValue(viewModel.useWebDramaPage ? "开启" : "关闭")
                }
            }
        } footnote: {
            SettingsFootnote("关闭（默认）：点进剧集用原生剧集页。开启：浏览页内直接打开网页版剧集页（保留网页的播放/解锁能力），立即生效。")
        }
    }

    // MARK: - 分组 · 浏览页快捷站点（30:20）

    private var quickLinkGroup: some View {
        SettingsGroup("浏览页快捷站点", topPadding: 10, showsRule: false) {
            if viewModel.links.isEmpty {
                Text("还没有站点，点下面添加。")
                    .font(DWFont.cn(10))
                    .foregroundStyle(DWColor.paperInkSub)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(viewModel.links) { link in
                quickLinkRow(link)                              // 30:22
            }
            PaperRow(action: { viewModel.beginAdd() }) {        // 30:31 添加站点
                HStack(spacing: 8) {
                    PlusShape()
                        .stroke(DWColor.paperIcon,
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(width: 12, height: 12)
                        .frame(width: 14, height: 14)
                    Text("添加站点")
                        .font(DWFont.cn(14))
                        .foregroundStyle(DWColor.paperIcon)
                }
            }
        } footnote: {
            SettingsFootnote("标签显示在网址栏下方，网址是点它要访问的地址；圆圈单选「默认加载」，再点一次取消默认，改回「恢复上次访问页」。")
        }
    }

    /// 单行：标签 + 默认标记 …… 网址 + 单选圆圈。
    /// 两个 Button 平级放在 HStack 里（不嵌套）—— 整行进编辑器、圆圈改默认，
    /// 嵌套 Button 时内层点击会被外层吞掉。
    private func quickLinkRow(_ link: QuickLink) -> some View {
        HStack(spacing: 8) {
            Button { viewModel.beginEdit(link) } label: {
                HStack(spacing: 8) {
                    Text(link.name)                              // 30:23 fs14
                        .font(DWFont.cn(14))
                        .foregroundStyle(DWColor.paperInk)
                        .lineLimit(1)
                    if viewModel.isDefault(link) {
                        Text("默认")                              // 30:24 朱砂 16% 底 / 30:25 fs9
                            .font(DWFont.cn(9, .medium))
                            .foregroundStyle(DWColor.paperCinnabar)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DWColor.paperCinnabar.opacity(0.16), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    Text(link.url)                               // 30:27 fs11
                        .font(DWFont.cn(11))
                        .foregroundStyle(DWColor.paperInkSub)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { viewModel.toggleDefault(link) } label: {
                DefaultDot(isOn: viewModel.isDefault(link))      // 30:28 圆圈 20×20
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isDefault(link) ? "取消默认加载" : "设为默认加载")
        }
    }

    // MARK: - 页脚（30:36）

    private var versionFooter: some View {
        Text(Self.versionLine)                                    // 30:37 fs9 #B9BCB9 居中
            .font(DWFont.cn(9))
            .foregroundStyle(DWColor.paperLineIdle)
            .frame(maxWidth: .infinity)
            .frame(height: 13)
            .padding(.top, 14)
            .padding(.bottom, 10)
    }

    /// 版本号读 Bundle，不写死（画布上的 1.0.0(12) 只是排版示意）
    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "SmartDownloader · \(version) (\(build))"
    }
}

// MARK: - 分组容器

/// 组标 + 若干行 + 脚注 + 组间细线，子项统一 4pt 间距（画布 30:3 的 gap 4）。
private struct SettingsGroup<Content: View, Footnote: View>: View {
    let label: String
    let topPadding: CGFloat
    var showsRule: Bool = true
    let content: Content
    let footnote: Footnote

    init(_ label: String, topPadding: CGFloat, showsRule: Bool = true,
         @ViewBuilder content: () -> Content,
         @ViewBuilder footnote: () -> Footnote) {
        self.label = label
        self.topPadding = topPadding
        self.showsRule = showsRule
        self.content = content()
        self.footnote = footnote()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(DWFont.cn(11))
                .foregroundStyle(DWColor.paperInkSub)
                .frame(height: 16)
            content
            footnote
            if showsRule {
                Rectangle()
                    .fill(DWColor.paperRule)
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, topPadding)
    }
}

/// 固定 40pt 高的设置行；给 action 就整行可点（按钮语义，带无障碍与按压反馈）
private struct PaperRow<Content: View>: View {
    let action: (() -> Void)?
    let content: Content

    init(action: (() -> Void)?, @ViewBuilder content: () -> Content) {
        self.action = action
        self.content = content()
    }

    var body: some View {
        if let action {
            Button(action: action) {
                content.frame(maxWidth: .infinity, alignment: .leading).frame(height: 40)
            }
            .buttonStyle(.plain)
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading).frame(height: 40)
        }
    }
}

/// 组脚注：fs10 + 行高 14（0.4em 行距换成 lineSpacing 2）
private struct SettingsFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DWFont.cn(10))
            .lineSpacing(2)
            .foregroundStyle(DWColor.paperInkSub)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 控件

/// 自定义开关（画布 30:16：轨道 40×24 圆角 12、钮 20×20 圆角 10、关态内边距 2）
private struct PaperSwitch: View {
    let isOn: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isOn { Spacer(minLength: 0) }
            Circle()
                .fill(DWColor.paperKnob)
                .frame(width: 20, height: 20)
            if !isOn { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 2)
        .frame(width: 40, height: 24)
        .background(Capsule().fill(isOn ? DWColor.paperCinnabar : DWColor.paperSwitchOff))
    }
}

/// 单选圆圈（画布 30:28）：选中 = 朱砂实心 17 + 纸白勾；未选 = 同尺寸描边圈
private struct DefaultDot: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            if isOn {
                Circle()
                    .fill(DWColor.paperCinnabar)
                    .frame(width: 17, height: 17)
                CheckShape()
                    .stroke(DWColor.paperKnob,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 8, height: 6)
            } else {
                Circle()
                    .stroke(DWColor.paperLineIdle, lineWidth: 1.5)
                    .frame(width: 17, height: 17)
            }
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: - 路径

/// 尖角。返回按钮要「‹」（尖朝左），行尾要「›」（尖朝右），方向搞反语义就反了。
/// 框多大画多大，描边粗细由调用方给。
private struct ChevronShape: Shape {
    /// true = 尖角朝左「‹」；false（默认）= 尖角朝右「›」
    var pointsLeft: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsLeft {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        return path
    }
}

/// 勾：在给定框内偏右压低，视觉重心才落在圆心
private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.06))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.04, y: rect.minY + rect.height * 0.06))
        return path
    }
}

/// 加号（画布 30:32，矢量本体 12×12）
private struct PlusShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

// MARK: - 启动进入选择面板

/// 设计稿只有行尾「›」，面板沿用同一套纸本语言：衬线标题 + 行 + 朱砂勾。
private struct LaunchTabPicker: View {
    @Binding var selection: MainTab
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("启动进入")
                .font(DWFont.serif(20, .medium))
                .foregroundStyle(DWColor.paperInk)
                .padding(.top, 22)
                .padding(.bottom, 16)

            Rectangle()
                .fill(DWColor.paperDivider)
                .frame(height: 1)

            VStack(spacing: 0) {
                ForEach(MainTab.allCases) { tab in
                    Button {
                        selection = tab
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Text(tab.title)
                                .font(DWFont.cn(15))
                                .foregroundStyle(DWColor.paperInk)
                            Spacer(minLength: 0)
                            if selection == tab {
                                CheckShape()
                                    .stroke(DWColor.paperCinnabar,
                                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                                    .frame(width: 13, height: 9)
                            }
                        }
                        .frame(height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if tab != MainTab.allCases.last {
                        Rectangle()
                            .fill(DWColor.paperRule)
                            .frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, DWLayout.edge)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(DWColor.paper.ignoresSafeArea())
        .presentationDetents([.height(252)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - 快捷站点编辑器（新增 / 修改共用）

private struct QuickLinkEditorSheet: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var name: String
    @State private var url: String

    init(viewModel: SettingsViewModel, draft: QuickLink) {
        self.viewModel = viewModel
        _name = State(initialValue: draft.name)
        _url = State(initialValue: draft.url)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(viewModel.draftIsNew ? "添加站点" : "编辑站点")
                    .font(DWFont.serif(17, .medium))
                    .foregroundStyle(DWColor.paperInk)

                HStack(spacing: 0) {
                    Button("取消") { viewModel.draft = nil }
                        .font(DWFont.cn(14))
                        .foregroundStyle(DWColor.paperIcon)
                    Spacer(minLength: 0)
                    Button("完成") { viewModel.commitDraft(name: name, url: url) }
                        .font(DWFont.cn(14, .medium))
                        .foregroundStyle(canCommit ? DWColor.paperCinnabar : DWColor.paperLineIdle)
                        .disabled(!canCommit)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DWLayout.edge)
            .frame(height: 56)

            Rectangle()
                .fill(DWColor.paperDivider)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 24) {
                field("标签", placeholder: "例如 苹果", text: $name)
                field("网址", placeholder: "例如 https://example.com", text: $url, keyboard: .URL)
            }
            .padding(.horizontal, DWLayout.edge)
            .padding(.top, 26)

            if viewModel.draftIsNew == false {
                Button("删除该站点") { viewModel.deleteDraft() }
                    .font(DWFont.cn(14))
                    .foregroundStyle(DWColor.paperCinnabar)
                    .padding(.top, 30)
            }

            Spacer(minLength: 0)
        }
        .background(DWColor.paper.ignoresSafeArea())
        .presentationDetents([.height(viewModel.draftIsNew ? 270 : 318)])
    }

    /// 纸本风输入位：小号组标字 + 无边框输入 + 一条细线，不用系统 Form 的灰底圆角块
    private func field(_ label: String, placeholder: String, text: Binding<String>,
                       keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(DWFont.cn(11))
                .foregroundStyle(DWColor.paperInkSub)
            TextField(placeholder, text: text)
                .font(DWFont.cn(15))
                .foregroundStyle(DWColor.paperInk)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            Rectangle()
                .fill(DWColor.paperRule)
                .frame(height: 1)
        }
    }

    private var canCommit: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty && !trimmedURL.isEmpty
    }
}
