import SwiftUI

struct RouteModePickerView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        ZStack {
            AuraScreenBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("选择流量处理方式")
                            .font(.title2.weight(.bold))
                        Text("名称直接说明实际行为；切换后，正在连接的 VPN 会安全重连并应用新规则。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        ForEach(AuraRouteMode.allCases) { mode in
                            Button {
                                preferences.routeMode = mode
                            } label: {
                                HStack(alignment: .top, spacing: 14) {
                                    Image(systemName: mode.symbol)
                                        .font(.headline)
                                        .foregroundStyle(
                                            preferences.routeMode == mode ? AuraPalette.aqua : AuraPalette.ocean
                                        )
                                        .frame(width: 30, height: 30)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(LocalizedStringKey(mode.title))
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(LocalizedStringKey(mode.detail))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 8)
                                    if preferences.routeMode == mode {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(AuraPalette.aqua)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if mode != AuraRouteMode.allCases.last {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                    .auraCard()

                    NavigationLink {
                        RoutingRulesEditorView()
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundStyle(AuraPalette.aqua)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("编辑规则配置")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("管理直连和代理域名；会包含在配置备份文件中")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(16)
                        .auraCard()
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
        }
        .navigationTitle("全局路由")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RoutingRulesEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vpnManager: VPNManager
    @State private var directDomains: String
    @State private var proxyDomains: String
    @State private var selectedList: RuleList = .direct
    @State private var errorMessage: String?
    @FocusState private var isEditorFocused: Bool

    init() {
        let configuration = SharedStore.loadRoutingRules()
        _directDomains = State(initialValue: configuration.directDomainSuffixes.joined(separator: "\n"))
        _proxyDomains = State(initialValue: configuration.proxyDomainSuffixes.joined(separator: "\n"))
    }

    var body: some View {
        ZStack {
            AuraScreenBackground()

            VStack(alignment: .leading, spacing: 12) {
                Picker("规则类型", selection: $selectedList) {
                    ForEach(RuleList.allCases) { list in
                        Label(LocalizedStringKey(list.title), systemImage: list.symbol)
                            .tag(list)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Label(LocalizedStringKey(selectedList.title), systemImage: selectedList.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selectedList == .direct ? AuraPalette.ocean : AuraPalette.aqua)
                    Spacer()
                    HStack(spacing: 3) {
                        Text("\(activeLineCount)")
                        Text("条")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                TextEditor(text: activeText)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isEditorFocused)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(AuraPalette.aqua.opacity(0.16), lineWidth: 1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(LocalizedStringKey(selectedList.helpText))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("恢复中国大陆常用默认规则") {
                    directDomains = RoutingRuleConfiguration.builtIn.directDomainSuffixes.joined(separator: "\n")
                    proxyDomains = RoutingRuleConfiguration.builtIn.proxyDomainSuffixes.joined(separator: "\n")
                }
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .navigationTitle("编辑规则")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { isEditorFocused = false }
            }
        }
        .alert(
            "无法保存规则",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var activeText: Binding<String> {
        switch selectedList {
        case .direct: $directDomains
        case .proxy: $proxyDomains
        }
    }

    private var activeLineCount: Int {
        lines(in: selectedList == .direct ? directDomains : proxyDomains)
            .lazy
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    private func save() async {
        let configuration = RoutingRuleConfiguration(
            directDomainSuffixes: lines(in: directDomains),
            proxyDomainSuffixes: lines(in: proxyDomains)
        ).normalized()
        do {
            try SharedStore.saveRoutingRules(configuration)
            await vpnManager.restartTunnelForRouteChangeIfNeeded()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func lines(in value: String) -> [String] {
        value.components(separatedBy: .newlines)
    }

    private enum RuleList: String, CaseIterable, Identifiable {
        case direct
        case proxy

        var id: String { rawValue }

        var title: String {
            switch self {
            case .direct: "直连域名"
            case .proxy: "代理域名"
            }
        }

        var symbol: String {
            switch self {
            case .direct: "arrow.right"
            case .proxy: "shield.lefthalf.filled"
            }
        }

        var helpText: String {
            switch self {
            case .direct: "每行一个域名后缀，例如 cn 或 baidu.com。匹配后不经过代理节点。"
            case .proxy: "每行一个域名后缀。规则配置和场景模式会优先让这些网站经过代理。"
            }
        }
    }
}
