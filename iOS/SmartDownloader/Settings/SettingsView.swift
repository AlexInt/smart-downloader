import SwiftUI

/// 设置页：条目 1「启动进入」选哪个 tab；条目 2 浏览页快捷站点的多对 key/value 配置。
/// View 只做渲染与意图转发，清洗与落盘在 SettingsViewModel 与 Service 层。
/// 作为不透明覆盖层盖在保活容器上（见 App.swift），自身不带背景。
struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        NavigationStack {
            List {
                launchSection
                dramaRouteSection
                quickLinkSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("恢复默认") { viewModel.restoreDefaults() }
                        .font(.caption)
                }
            }
            .sheet(item: $viewModel.draft) { draft in
                QuickLinkEditorSheet(viewModel: viewModel, draft: draft)
            }
        }
    }

    /// 条目 1：启动落在哪个 tab
    private var launchSection: some View {
        Section {
            Picker("启动进入", selection: $viewModel.launchTab) {
                ForEach(MainTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.icon).tag(tab)
                }
            }
        } header: {
            Text("启动")
        } footer: {
            Text("下次冷启动生效，当前会话不会自动跳转。")
        }
    }

    /// 条目 2：剧集页路由模式（原生 / Web）
    private var dramaRouteSection: some View {
        Section {
            Toggle("打开 Web 剧集页", isOn: $viewModel.useWebDramaPage)
        } header: {
            Text("剧集页")
        } footer: {
            Text("关闭（默认）：点进剧集用原生剧集页。开启：在浏览页内直接打开网页版剧集页（保留网页的播放/解锁能力），立即生效。")
        }
    }

    /// 条目 3：快捷站点，多对 key/value，可增可改可删
    private var quickLinkSection: some View {
        Section {
            if viewModel.links.isEmpty {
                Text("暂无站点，点下方按钮添加。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(viewModel.links) { link in
                quickLinkRow(link)
            }
            Button("添加站点") { viewModel.beginAdd() }
        } header: {
            Text("浏览页快捷站点")
        } footer: {
            Text("key 显示在网址栏下方，value 是点它要访问的网址；标签行超出屏宽可左右滑动。\n未手动选择时默认选中第一项，下次启动浏览区直接加载它。点右侧圆圈可改选；再点一次取消默认，改回「恢复上次访问页」。")
        }
    }

    /// 单行：左显 key + 默认标记、右显 value，点行进编辑器；右侧圆圈单选「默认加载」，左滑删除。
    /// 两个 Button 平级放在 HStack 里（不嵌套），避免 List 行点击被外层 Button 整行吞掉。
    private func quickLinkRow(_ link: QuickLink) -> some View {
        HStack(spacing: 8) {
            Button { viewModel.beginEdit(link) } label: {
                HStack(spacing: 8) {
                    Text(link.name)
                        .lineLimit(1)
                    if viewModel.isDefault(link) {
                        Text("默认")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(DWColor.gold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DWColor.gold.opacity(0.16), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    Text(link.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { viewModel.toggleDefault(link) } label: {
                Image(systemName: viewModel.isDefault(link) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(viewModel.isDefault(link) ? DWColor.gold : .secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isDefault(link) ? "取消默认加载" : "设为默认加载")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                viewModel.remove(link)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

/// 快捷站点编辑器（新增/修改共用）：两个输入框分别对应 key 与 value。
private struct QuickLinkEditorSheet: View {
    @ObservedObject var viewModel: SettingsViewModel
    let draft: QuickLink
    @State private var name: String
    @State private var url: String

    init(viewModel: SettingsViewModel, draft: QuickLink) {
        self.viewModel = viewModel
        self.draft = draft
        _name = State(initialValue: draft.name)
        _url = State(initialValue: draft.url)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("key（标签显示名）").font(.caption).foregroundStyle(.secondary)
                        TextField("例如 苹果", text: $name)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("value（访问网址）").font(.caption).foregroundStyle(.secondary)
                        TextField("例如 https://example.com", text: $url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                } footer: {
                    Text("网址不带 http 前缀时按 https 访问。")
                }
                if viewModel.draftIsNew == false {
                    Button("删除该站点", role: .destructive) { viewModel.deleteDraft() }
                }
            }
            .navigationTitle(viewModel.draftIsNew ? "添加站点" : "编辑站点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { viewModel.draft = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { viewModel.commitDraft(name: name, url: url) }
                        .disabled(canCommit == false)
                }
            }
        }
    }

    private var canCommit: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty && !trimmedURL.isEmpty
    }
}
