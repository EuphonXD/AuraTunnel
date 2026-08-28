import SwiftUI

struct ConfigurationView: View {
    @EnvironmentObject private var vpnManager: VPNManager
    @State private var configuration = SharedStore.loadTunnelConfiguration()
    @State private var isConfirmingReset = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            AuraScreenBackground()

            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 0) {
                        Button {
                            isConfirmingReset = true
                        } label: {
                            configurationAction(
                                title: "恢复默认配置",
                                detail: "重建大陆直连、境外代理与 DNS 安全默认值",
                                symbol: "arrow.uturn.backward.circle"
                            )
                        }
                        .buttonStyle(.plain)

                        Divider().padding(.leading, 56)

                        NavigationLink {
                            RoutingRulesEditorView()
                        } label: {
                            configurationAction(
                                title: "测试与编辑规则",
                                detail: "检查直连域名和代理域名的优先顺序",
                                symbol: "testtube.2"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .auraCard()

                    VStack(alignment: .leading, spacing: 10) {
                        AuraSectionHeader(title: "本地配置", detail: "内置并保存到 App Group")

                        NavigationLink {
                            ConfigurationDetailView()
                        } label: {
                            HStack(spacing: 13) {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(configuration.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("IPv4 稳定模式 · \(configuration.routingRules.directDomainSuffixes.count + configuration.routingRules.proxyDomainSuffixes.count) 条域名规则")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "checkmark")
                                    .foregroundStyle(AuraPalette.aqua)
                                Image(systemName: "info.circle")
                                    .foregroundStyle(AuraPalette.ocean)
                            }
                            .padding(16)
                            .auraCard(cornerRadius: 18)
                        }
                        .buttonStyle(.plain)

                        Text("default.conf 是当前运行配置。修改网络选项后，已连接的隧道会安全重启。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("配置")
        .onAppear { configuration = SharedStore.loadTunnelConfiguration() }
        .confirmationDialog(
            "恢复 default.conf？",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("恢复默认配置", role: .destructive) {
                Task { await restoreDefault() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会替换通用设置、规则、Host 和 URL 重写；节点及订阅不会删除。")
        }
        .alert(
            "配置操作失败",
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

    private func configurationAction(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .foregroundStyle(AuraPalette.aqua)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .contentShape(Rectangle())
    }

    @MainActor
    private func restoreDefault() async {
        do {
            try SharedStore.saveTunnelConfiguration(.builtIn)
            configuration = .builtIn
            await vpnManager.restartTunnelForRouteChangeIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ConfigurationDetailView: View {
    @State private var configuration = SharedStore.loadTunnelConfiguration()

    var body: some View {
        List {
            Section {
                NavigationLink("通用") { GeneralConfigurationEditorView() }
                    .badge(generalOptionCount)
                NavigationLink("规则") { RoutingRulesEditorView() }
                    .badge(configuration.routingRules.directDomainSuffixes.count + configuration.routingRules.proxyDomainSuffixes.count)
                NavigationLink("Hosts") { HostOverridesEditorView() }
                    .badge(configuration.hosts.count)
                NavigationLink("URL 重写") { URLRewriteEditorView() }
                    .badge(configuration.urlRewrites.count)
            }

            Section("高级配置") {
                LabeledContent("头部重写", value: "0")
                LabeledContent("正文重写", value: "0")
                LabeledContent("本地映射", value: "0")
                LabeledContent("HTTPS 解密", value: "关闭")
                LabeledContent("脚本", value: "0")
                LabeledContent("代理分组", value: "0")
            }

            Section("配置工具") {
                LabeledContent("规则集 URL", value: "0")
                LabeledContent("脚本 URL", value: "0")
                NavigationLink("编辑规则纯文本") { RoutingRulesEditorView() }
                LabeledContent("编译配置", value: "运行时自动校验")
                LabeledContent("扩展", value: "AuraTunnel")
            }

            Section {
                Text("URL 重写仅保存和导出规则。AuraTunnel 不会冒充 HTTPS 解密：没有用户安装并信任的证书时，系统 Packet Tunnel 无法改写加密正文。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(configuration.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { configuration = SharedStore.loadTunnelConfiguration() }
    }

    private var generalOptionCount: Int {
        3 + configuration.general.dnsServers.count
            + configuration.general.fallbackDNSServers.count
            + configuration.general.bypassProxyAddresses.count
            + configuration.general.tunBypassRoutes.count
            + configuration.general.alwaysRealIPDomains.count
            + configuration.general.hijackDNSEndpoints.count
    }
}

private struct GeneralConfigurationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vpnManager: VPNManager
    @State private var general = SharedStore.loadTunnelConfiguration().general
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("启用 IPv6", isOn: $general.ipv6Enabled)
                Toggle("首选 IPv6", isOn: $general.preferIPv6)
                    .disabled(!general.ipv6Enabled)
                Toggle("私有 IP 应答", isOn: $general.privateIPAnswers)
            } header: {
                Text("IP 与 DNS")
            } footer: {
                Text("IPv6 默认关闭，以兼容只有 IPv4 出口的 VMess、Shadowsocks 和 SOCKS 节点。")
            }

            multilineSection(
                title: "DNS 覆写",
                footer: "每行一个 DNS IP。智能、规则和直连模式优先使用。",
                text: listBinding(\.dnsServers),
                minimumHeight: 80
            )
            multilineSection(
                title: "备用 DNS",
                footer: "全局代理恢复使用真实 DNS，避免 Fake DNS 未就绪时整机断网。",
                text: listBinding(\.fallbackDNSServers),
                minimumHeight: 80
            )
            multilineSection(
                title: "跳过代理",
                footer: "局域网、系统探测域名和需要直接访问的地址。",
                text: listBinding(\.bypassProxyAddresses),
                minimumHeight: 130
            )
            multilineSection(
                title: "TUN 旁路路由",
                footer: "保存到 default.conf；当前版本由 Leaf 的直连规则处理，避免与虚拟网卡地址冲突。",
                text: listBinding(\.tunBypassRoutes),
                minimumHeight: 150
            )
            multilineSection(
                title: "总是真实 IP",
                footer: "Fake DNS 会排除这些域名，保障局域网、Apple 与网络认证页面。",
                text: listBinding(\.alwaysRealIPDomains),
                minimumHeight: 110
            )
            multilineSection(
                title: "劫持 DNS",
                footer: "每行一个 IP:端口；作为配置记录，不进行高频轮询。",
                text: listBinding(\.hijackDNSEndpoints),
                minimumHeight: 80
            )
        }
        .navigationTitle("通用")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
            }
        }
        .alert(
            "无法保存通用配置",
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

    private func multilineSection(
        title: String,
        footer: String,
        text: Binding<String>,
        minimumHeight: CGFloat
    ) -> some View {
        Section {
            TextEditor(text: text)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minHeight: minimumHeight)
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    private func listBinding(
        _ keyPath: WritableKeyPath<TunnelGeneralConfiguration, [String]>
    ) -> Binding<String> {
        Binding(
            get: { general[keyPath: keyPath].joined(separator: "\n") },
            set: { general[keyPath: keyPath] = $0.components(separatedBy: .newlines) }
        )
    }

    @MainActor
    private func save() async {
        var configuration = SharedStore.loadTunnelConfiguration()
        configuration.general = general.normalized()
        do {
            try SharedStore.saveTunnelConfiguration(configuration)
            await vpnManager.restartTunnelForRouteChangeIfNeeded()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct HostOverridesEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hosts = SharedStore.loadTunnelConfiguration().hosts
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach($hosts) { $entry in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("域名，例如 localhost", text: $entry.hostname)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("IP 地址，例如 127.0.0.1", text: $entry.address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("启用", isOn: $entry.isEnabled)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { hosts.remove(atOffsets: $0) }

                Button("添加 Host", systemImage: "plus") {
                    hosts.append(HostOverride(hostname: "", address: ""))
                }
            } footer: {
                Text("Host 会写入 Leaf DNS hosts 表；DNS 查询命中时直接返回指定地址。")
            }
        }
        .navigationTitle("Hosts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
            }
        }
        .alert(
            "无法保存 Hosts",
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

    private func save() {
        var configuration = SharedStore.loadTunnelConfiguration()
        configuration.hosts = hosts
        do {
            try SharedStore.saveTunnelConfiguration(configuration)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct URLRewriteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rules = SharedStore.loadTunnelConfiguration().urlRewrites
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach($rules) { $rule in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("正则表达式", text: $rule.pattern, axis: .vertical)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("重写目标", text: $rule.replacement, axis: .vertical)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        HStack {
                            Text("状态码")
                            Spacer()
                            TextField("302", value: $rule.statusCode, format: .number)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                                .frame(width: 64)
                            Toggle("启用", isOn: $rule.isEnabled)
                                .labelsHidden()
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { rules.remove(atOffsets: $0) }

                Button("添加 URL 重写", systemImage: "plus") {
                    rules.append(URLRewriteRule(pattern: "", replacement: "https://"))
                }
            } footer: {
                Text("规则会保存并随配置备份。HTTPS 内容不会在没有受信任证书的情况下被静默解密。")
            }
        }
        .navigationTitle("URL 重写")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
            }
        }
        .alert(
            "无法保存 URL 重写",
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

    private func save() {
        var configuration = SharedStore.loadTunnelConfiguration()
        configuration.urlRewrites = rules
        do {
            try SharedStore.saveTunnelConfiguration(configuration)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
