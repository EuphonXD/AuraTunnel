import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var vpnManager: VPNManager
    @State private var exportDocument: AuraTunnelBackupDocument?
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var isPreparingBackup = false
    @State private var backupNotice: BackupNotice?

    var body: some View {
        ZStack {
            AuraScreenBackground()

            ScrollView {
                VStack(spacing: 22) {
                    languageCard
                    appearanceCard
                    backupCard
                    testingCard
                    behaviorCard
                    connectionAlertsCard
                    safetyCard
                    aboutCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("设置")
        .fileExporter(
            isPresented: $isExportingBackup,
            document: exportDocument,
            contentType: .auraTunnelBackup,
            defaultFilename: backupFileName
        ) { result in
            switch result {
            case .success:
                backupNotice = BackupNotice(title: "备份完成", message: "配置文件已保存，可放在 iCloud Drive 中跨设备恢复。")
            case .failure(let error):
                backupNotice = BackupNotice(title: "备份失败", message: error.localizedDescription)
            }
            exportDocument = nil
        }
        .fileImporter(
            isPresented: $isImportingBackup,
            allowedContentTypes: [.auraTunnelBackup, .json],
            allowsMultipleSelection: false
        ) { result in
            restoreBackup(from: result)
        }
        .alert(item: $backupNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            AuraSectionHeader(title: "语言 / Language")
            Picker("语言 / Language", selection: $preferences.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .pickerStyle(.segmented)
            Text("语言会立即在 App 内切换，不需要前往系统设置。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .auraCard()
    }

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            AuraSectionHeader(title: "外观")
            Picker("外观", selection: $preferences.appearance) {
                ForEach(AuraAppearance.allCases) { appearance in
                    Text(LocalizedStringKey(appearance.title)).tag(appearance)
                }
            }
            .pickerStyle(.segmented)

            Text("AuraTunnel 使用自己的深海与极光配色，并保留系统动态字体和深色模式适配。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .auraCard()
    }

    private var testingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            AuraSectionHeader(title: "节点测试")
                .padding(.bottom, 8)

            settingsRow(symbol: "timer", title: "超时时间") {
                Picker("超时时间", selection: $preferences.testTimeoutSeconds) {
                    Text("3 秒").tag(3)
                    Text("5 秒").tag(5)
                    Text("8 秒").tag(8)
                }
                .labelsHidden()
            }

            Divider().padding(.leading, 42)

            settingsRow(symbol: "leaf.fill", title: "低功耗测速") {
                Toggle("低功耗测速", isOn: $preferences.lowPowerTesting)
                    .labelsHidden()
            }

            Text(preferences.lowPowerTesting ? "节点按顺序测试，减少同时唤醒无线电与调度器。" : "最多同时测试 3 个节点，完成更快但瞬时功耗更高。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
        }
        .padding(16)
        .auraCard()
    }

    private var backupCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            AuraSectionHeader(title: "iCloud 与配置文件")
                .padding(.bottom, 8)

            Button {
                createBackup()
            } label: {
                backupRow(
                    symbol: "icloud.and.arrow.up",
                    title: "备份到 iCloud Drive",
                    detail: "导出节点、订阅、规则和当前选择"
                )
            }
            .buttonStyle(.plain)
            .disabled(isPreparingBackup)

            Divider().padding(.leading, 42)

            Button {
                isImportingBackup = true
            } label: {
                backupRow(
                    symbol: "icloud.and.arrow.down",
                    title: "从配置文件恢复",
                    detail: "选择 iCloud Drive 中的 AuraTunnel 备份"
                )
            }
            .buttonStyle(.plain)
            .disabled(isPreparingBackup || vpnManager.isConnectedOrConnecting)

            Text("备份文件包含节点认证信息，请只保存在你自己的 iCloud Drive；恢复前需要先断开 VPN。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
        }
        .padding(16)
        .auraCard()
    }

    private func backupRow(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            if isPreparingBackup && symbol == "icloud.and.arrow.up" {
                ProgressView().frame(width: 24)
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(AuraPalette.aqua)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Text(LocalizedStringKey(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func createBackup() {
        guard !isPreparingBackup else { return }
        isPreparingBackup = true
        Task {
            defer { isPreparingBackup = false }
            do {
                let data = try await vpnManager.makeConfigurationBackup()
                exportDocument = AuraTunnelBackupDocument(data: data)
                isExportingBackup = true
            } catch {
                backupNotice = BackupNotice(title: "备份失败", message: error.localizedDescription)
            }
        }
    }

    private func restoreBackup(from result: Result<[URL], Error>) {
        Task {
            do {
                let urls = try result.get()
                guard let url = urls.first else { return }
                let data = try await Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    return try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                try await vpnManager.restoreConfigurationBackup(data)
                preferences.routeMode = SharedStore.loadRouteMode()
                backupNotice = BackupNotice(
                    title: "恢复完成",
                    message: "节点、订阅和路由规则已经恢复。连接 VPN 前请先确认所选节点。"
                )
            } catch {
                backupNotice = BackupNotice(title: "恢复失败", message: error.localizedDescription)
            }
        }
    }

    private var backupFileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "AuraTunnel-\(formatter.string(from: .now)).aurabackup"
    }

    private var behaviorCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            AuraSectionHeader(title: "使用习惯")
                .padding(.bottom, 8)

            settingsRow(symbol: "rectangle.expand.vertical", title: "默认展开订阅") {
                Toggle("默认展开订阅", isOn: $preferences.expandSubscriptions)
                    .labelsHidden()
            }

            Divider().padding(.leading, 42)

            NavigationLink {
                RouteModePickerView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: preferences.routeMode.symbol)
                        .foregroundStyle(AuraPalette.aqua)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("全局路由")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Text(LocalizedStringKey(preferences.routeMode.title))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .auraCard()
    }

    private var connectionAlertsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            AuraSectionHeader(title: "连接提醒")
                .padding(.bottom, 8)

            settingsRow(symbol: "hourglass", title: "连接等待上限") {
                Picker("连接等待上限", selection: $preferences.connectionTimeoutSeconds) {
                    Text("10 秒").tag(10)
                    Text("15 秒").tag(15)
                    Text("20 秒").tag(20)
                    Text("30 秒").tag(30)
                }
                .labelsHidden()
            }

            Divider().padding(.leading, 42)

            settingsRow(symbol: "exclamationmark.triangle", title: "连接失败提醒") {
                Toggle("连接失败提醒", isOn: $preferences.showConnectionFailureAlerts)
                    .labelsHidden()
            }

            Divider().padding(.leading, 42)

            settingsRow(symbol: "bolt.slash", title: "意外断开提醒") {
                Toggle("意外断开提醒", isOn: $preferences.showUnexpectedDisconnectAlerts)
                    .labelsHidden()
            }

            Text("仅在连接状态发生变化时提醒，不会在后台轮询，也不会上传连接记录。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
        }
        .padding(16)
        .auraCard()
    }

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            AuraSectionHeader(title: "安全与诊断")
                .padding(.bottom, 8)

            NavigationLink {
                DiagnosticsView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "stethoscope")
                        .foregroundStyle(AuraPalette.aqua)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("运行诊断")
                            .foregroundStyle(.primary)
                        Text("权限、App Group、配置和扩展状态")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 42)

            NavigationLink {
                VPNDataDisclosureView(onAccept: nil)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(AuraPalette.aqua)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("隐私政策与 VPN 数据说明")
                            .foregroundStyle(.primary)
                        Text("查看隧道、节点、相机与剪贴板的数据处理方式")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 42)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(AuraPalette.aqua)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text("隐私边界")
                        .font(.subheadline.weight(.semibold))
                    Text("剪贴板只在点击后读取；节点密钥保存到共享 Keychain；扩展内没有逐包日志。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 11)
        }
        .padding(16)
        .auraCard()
    }

    private var aboutCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AuraPalette.ocean, AuraPalette.aqua],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 54, height: 54)
                Image(systemName: "wave.3.right")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("AuraTunnel")
                    .font(.headline)
                Text("轻量、透明、失败关闭的网络工具")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("版本 \(appVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(16)
        .auraCard()
    }

    private func settingsRow<Trailing: View>(
        symbol: String,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(AuraPalette.aqua)
                .frame(width: 24)
            Text(LocalizedStringKey(title))
                .font(.subheadline)
            Spacer()
            trailing()
        }
        .padding(.vertical, 11)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

private struct BackupNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct DiagnosticsView: View {
    @EnvironmentObject private var vpnManager: VPNManager

    var body: some View {
        ZStack {
            AuraScreenBackground()

            ScrollView {
                VStack(spacing: 18) {
                    diagnosticCard(
                        title: "代理转发核心",
                        value: ForwardingCapability.isImplemented ? "已启用" : "尚未启用",
                        symbol: "cpu",
                        tint: ForwardingCapability.isImplemented ? .green : .orange
                    )
                    diagnosticCard(
                        title: "系统 VPN 配置",
                        value: vpnManager.isConfigured ? "已安装" : "尚未安装",
                        symbol: "network.badge.shield.half.filled",
                        tint: vpnManager.isConfigured ? .green : .secondary
                    )
                    diagnosticCard(
                        title: "相机权限",
                        value: cameraPermissionTitle,
                        symbol: "camera.fill",
                        tint: cameraPermissionTint
                    )
                    diagnosticCard(
                        title: "App Group",
                        value: SharedConfiguration.appGroupIdentifier,
                        symbol: "person.2.badge.gearshape.fill",
                        tint: AuraPalette.aqua
                    )
                    diagnosticCard(
                        title: "本机配置",
                        value: "\(vpnManager.subscriptions.count) 个订阅 · \(vpnManager.profiles.count) 个节点",
                        symbol: "externaldrive.fill",
                        tint: AuraPalette.ocean
                    )
                }
                .padding(16)
            }
        }
        .navigationTitle("运行诊断")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func diagnosticCard(title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.semibold))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(15)
        .auraCard(cornerRadius: 18)
    }

    private var cameraPermissionTitle: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: "已授权"
        case .denied: "已拒绝"
        case .restricted: "受系统限制"
        case .notDetermined: "尚未请求"
        @unknown default: "未知"
        }
    }

    private var cameraPermissionTint: Color {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .green
        case .denied, .restricted: .red
        default: .secondary
        }
    }
}
