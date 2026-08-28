import NetworkExtension
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var vpnManager: VPNManager
    @EnvironmentObject private var importCoordinator: NodeImportCoordinator
    @EnvironmentObject private var connectivityTester: NodeConnectivityTester
    @EnvironmentObject private var preferences: AppPreferences

    let onScan: () -> Void
    let onOpenLibrary: () -> Void

    @State private var collapsedSubscriptionIDs: Set<UUID> = []
    @State private var deletionTarget: LibraryDeletionTarget?
    @State private var nodeActionSheet: NodeActionSheet?
    @State private var subscriptionActionSheet: SubscriptionActionSheet?
    @State private var nodeActionError: NodeActionError?
    @State private var showHiddenNodes = false

    var body: some View {
        ZStack {
            AuraScreenBackground()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 18) {
                        connectionHero
                        if let failure = importCoordinator.lastImportFailure {
                            importFailureCard(failure)
                        }
                        if let report = importCoordinator.lastImportReport {
                            importReceipt(report)
                        }
                        if vpnManager.selectedProfile != nil {
                            systemConfigurationCard
                        }
                        if let error = vpnManager.lastErrorMessage {
                            operationErrorCard(error)
                        }
                        routeModeCard

                        if vpnManager.profiles.isEmpty {
                            emptyNodeCard
                        } else {
                            nodeListCard
                                .id("aura-node-list")
                        }

                        forwardingNotice
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .onChange(of: vpnManager.profiles.count) { count in
                    guard count > 0 else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("aura-node-list", anchor: .top)
                    }
                }
            }
        }
        .navigationTitle("AuraTunnel")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: onScan) {
                    Image(systemName: "qrcode.viewfinder")
                }
                .accessibilityLabel("扫码导入")

                Button(action: onOpenLibrary) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("打开节点库")
            }
        }
        .onAppear(perform: synchronizeExpansionPreference)
        .onChange(of: preferences.expandSubscriptions) { _ in
            synchronizeExpansionPreference()
        }
        .confirmationDialog(
            "确认删除",
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { _ in }
            ),
            titleVisibility: .visible,
            presenting: deletionTarget
        ) { target in
            Button(target.actionTitle, role: .destructive) {
                deletionTarget = nil
                Task { await performDeletion(target) }
            }
            Button("取消", role: .cancel) {
                deletionTarget = nil
            }
        } message: { target in
            Text(target.message)
        }
        .sheet(item: $nodeActionSheet) { sheet in
            NodeActionSheetView(
                sheet: sheet,
                onSave: { profile, name, rawURI in
                    try await vpnManager.updateProfile(profile, displayName: name, rawURI: rawURI)
                },
                onDelete: { profile in
                    await performDeletion(.profile(profile))
                }
            )
        }
        .sheet(item: $subscriptionActionSheet) { sheet in
            SubscriptionActionSheetView(
                sheet: sheet,
                onRename: { subscription, name in
                    try await vpnManager.updateSubscription(subscription, displayName: name)
                },
                onDelete: { subscription in
                    await performDeletion(.subscription(subscription))
                }
            )
        }
        .alert(item: $nodeActionError) { error in
            Alert(
                title: Text("节点操作失败"),
                message: Text(error.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var connectionHero: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [AuraPalette.midnight, AuraPalette.ocean, AuraPalette.aqua.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .stroke(.white.opacity(0.10), lineWidth: 22)
                .frame(width: 180, height: 180)
                .offset(x: 72, y: -82)

            Circle()
                .fill(.white.opacity(0.07))
                .frame(width: 110, height: 110)
                .offset(x: -250, y: 150)

            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label {
                        Text(LocalizedStringKey(statusTitle))
                    } icon: {
                        Image(systemName: statusSymbol)
                    }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Text(LocalizedStringKey(preferences.routeMode.title))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AuraPalette.ice)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.10), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let name = vpnManager.selectedProfile?.name {
                        Text(name)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    } else {
                        Text("选择你的第一条路径")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    Text(selectedNodeDetail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }

                Button {
                    if vpnManager.isStartingTunnel || vpnManager.isConnectedOrConnecting {
                        vpnManager.disconnect()
                    } else {
                        Task { await vpnManager.connect() }
                    }
                } label: {
                    HStack {
                        if vpnManager.isStartingTunnel {
                            ProgressView()
                                .tint(AuraPalette.midnight)
                        } else {
                            Image(systemName: vpnManager.isConnectedOrConnecting ? "stop.fill" : "power")
                        }
                        Text(LocalizedStringKey(connectionButtonTitle))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.bold))
                    }
                    .font(.headline)
                    .foregroundStyle(AuraPalette.midnight)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.94))
                .disabled(
                    vpnManager.isLoading ||
                    vpnManager.selectedProfile == nil ||
                    (!vpnManager.isConnectedOrConnecting && !vpnManager.canEstablishRealTunnel)
                )
            }
            .padding(22)
        }
        .frame(minHeight: 242)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: AuraPalette.ocean.opacity(0.22), radius: 20, y: 10)
    }

    private var routeModeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            AuraSectionHeader(title: "全局路由", detail: "规则已保存到本机")

            NavigationLink {
                RouteModePickerView()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: preferences.routeMode.symbol)
                        .font(.title3)
                        .foregroundStyle(AuraPalette.aqua)
                        .frame(width: 36, height: 36)
                        .background(AuraPalette.aqua.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(preferences.routeMode.title))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(LocalizedStringKey(preferences.routeMode.detail))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .auraCard()
    }

    private var systemConfigurationCard: some View {
        HStack(spacing: 12) {
            Image(systemName: vpnManager.isConfigured ? "checkmark.shield.fill" : "lock.shield")
                .font(.title3)
                .foregroundStyle(vpnManager.isConfigured ? .green : AuraPalette.aqua)

            VStack(alignment: .leading, spacing: 3) {
                Text(vpnManager.isConfigured ? "系统 VPN 已准备" : "准备系统 VPN")
                    .font(.subheadline.weight(.semibold))
                Text(vpnManager.isConfigured ? "iOS 已保存 AuraTunnel 的 Packet Tunnel 配置" : "由 iOS 弹出一次 VPN 配置授权，不会立即连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if !vpnManager.isConfigured {
                Button("准备") {
                    Task { await vpnManager.installSystemConfiguration() }
                }
                .buttonStyle(.borderedProminent)
                .tint(AuraPalette.ocean)
                .disabled(vpnManager.isLoading)
            }
        }
        .padding(14)
        .auraCard(cornerRadius: 17)
    }

    private func operationErrorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .auraCard(cornerRadius: 17)
    }

    private func importFailureCard(_ failure: NodeImportFailure) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.doc.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("节点导入未完成")
                    .font(.subheadline.weight(.semibold))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button {
                importCoordinator.clearImportFailure()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭导入错误")
        }
        .padding(14)
        .auraCard(cornerRadius: 17)
    }

    private func importReceipt(_ report: NodeImportReport) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.isRefresh ? "订阅已刷新" : "节点已保存")
                    .font(.subheadline.weight(.semibold))
                Text("\(report.title) · 本次 \(report.importedCount) 个 · 节点库共 \(report.totalCount) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(14)
        .auraCard(cornerRadius: 17)
    }

    private var emptyNodeCard: some View {
        VStack(spacing: 2) {
            AuraEmptyState(
                symbol: "point.3.filled.connected.trianglepath.dotted",
                title: "节点库还是空的",
                message: "扫描二维码或从剪贴板导入订阅，节点会直接显示在这里。"
            )

            HStack(spacing: 12) {
                Button("扫码", systemImage: "qrcode.viewfinder", action: onScan)
                    .buttonStyle(.borderedProminent)
                    .tint(AuraPalette.ocean)
                PasteButton(payloadType: String.self) { values in
                    importCoordinator.receive(payload: values.first)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(importCoordinator.isImporting)
            }
            Button("打开节点库", systemImage: "square.stack.3d.up", action: onOpenLibrary)
                .buttonStyle(.bordered)
                .padding(.top, 10)
            .padding(.bottom, 22)
        }
        .auraCard()
    }

    private var nodeListCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("可用路径")
                        .font(.headline)
                    Text("\(displayedProfiles.count) / \(vpnManager.profiles.count) 个节点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if hiddenItemCount > 0 {
                    Button {
                        showHiddenNodes.toggle()
                    } label: {
                        Image(systemName: showHiddenNodes ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .accessibilityLabel(showHiddenNodes ? "收起隐藏项目" : "显示 \(hiddenItemCount) 个隐藏项目")
                }
                Button {
                    connectivityTester.testAll(
                        displayedProfiles,
                        timeoutSeconds: preferences.testTimeoutSeconds,
                        maximumConcurrentTests: preferences.maximumConcurrentTests
                    )
                } label: {
                    Label("全部测速", systemImage: "gauge.with.dots.needle.50percent")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(AuraPalette.ocean)
                .disabled(connectivityTester.isRunning)
            }
            .padding(16)

            Divider()

            LazyVStack(spacing: 0) {
                ForEach(displayedSubscriptions) { subscription in
                    subscriptionHeader(subscription)

                    if !collapsedSubscriptionIDs.contains(subscription.id) {
                        ForEach(profiles(for: subscription)) { profile in
                            Divider().padding(.leading, 50)
                            nodeRow(profile)
                        }
                    }

                    Divider()
                }

                if !ungroupedProfiles.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "tray.full.fill")
                            .foregroundStyle(AuraPalette.aqua)
                            .frame(width: 24)
                        Text(vpnManager.subscriptions.isEmpty ? "本地节点" : "单独导入")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(ungroupedProfiles.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)

                    ForEach(ungroupedProfiles) { profile in
                        Divider().padding(.leading, 50)
                        nodeRow(profile)
                    }
                }

                Label(
                    "测速是 TCP 端口握手，不代表代理认证已经完成。",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(16)
            }
        }
        .auraCard()
    }

    private func subscriptionHeader(_ subscription: SubscriptionProfile) -> some View {
        HStack(spacing: 8) {
            Button {
                toggle(subscription.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: collapsedSubscriptionIDs.contains(subscription.id) ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AuraPalette.aqua)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(subscription.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("\(profiles(for: subscription).count) 个 · \(subscription.sourceHost)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await importCoordinator.refresh(subscription, using: vpnManager) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AuraPalette.ocean)
            .disabled(importCoordinator.isImporting)
            .accessibilityLabel("更新订阅 \(subscription.name)")

            Button {
                Task { await presentSubscriptionAction(.url, for: subscription) }
            } label: {
                Image(systemName: "info.circle")
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AuraPalette.ocean)
            .accessibilityLabel("查看订阅详情 \(subscription.name)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            subscriptionActionMenu(for: subscription)
        }
    }

    @ViewBuilder
    private func subscriptionActionMenu(for subscription: SubscriptionProfile) -> some View {
        Button("测试", systemImage: "paperplane") {
            connectivityTester.testAll(
                allProfiles(for: subscription),
                timeoutSeconds: preferences.testTimeoutSeconds,
                maximumConcurrentTests: preferences.maximumConcurrentTests
            )
        }
        .disabled(connectivityTester.isRunning || allProfiles(for: subscription).isEmpty)

        Button("更新", systemImage: "arrow.clockwise") {
            Task { await importCoordinator.refresh(subscription, using: vpnManager) }
        }
        .disabled(importCoordinator.isImporting)

        Button("分享", systemImage: "square.and.arrow.up") {
            Task { await presentSubscriptionAction(.share, for: subscription) }
        }
        Button("URL", systemImage: "link") {
            Task { await presentSubscriptionAction(.url, for: subscription) }
        }

        Divider()

        Button("编辑", systemImage: "square.and.pencil") {
            subscriptionActionSheet = .edit(subscription)
        }
        Button(
            subscription.isHidden == true ? "取消隐藏" : "隐藏",
            systemImage: subscription.isHidden == true ? "eye" : "eye.slash"
        ) {
            Task {
                _ = await vpnManager.setSubscriptionHidden(
                    subscription,
                    hidden: subscription.isHidden != true
                )
            }
        }

        Divider()

        Button("二维码", systemImage: "qrcode") {
            Task { await presentSubscriptionAction(.qr, for: subscription) }
        }
        Button("复制地址", systemImage: "doc.on.doc") {
            Task { await copySubscriptionImportURI(subscription) }
        }
        PasteButton(payloadType: String.self) { values in
            importCoordinator.receive(payload: values.first)
        }
        .disabled(importCoordinator.isImporting)

        Divider()

        Button("删除", systemImage: "trash", role: .destructive) {
            deletionTarget = .subscription(subscription)
        }
    }

    private func nodeRow(_ profile: TunnelProfile) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await vpnManager.selectProfile(profile) }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(profile.id == vpnManager.selectedProfile?.id ? AuraPalette.aqua : Color.secondary.opacity(0.14))
                            .frame(width: 30, height: 30)
                        Image(systemName: profile.id == vpnManager.selectedProfile?.id ? "checkmark" : "network")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(profile.id == vpnManager.selectedProfile?.id ? AuraPalette.midnight : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if profile.isHidden == true {
                            Label("已隐藏", systemImage: "eye.slash")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(profile.proxyProtocol.displayName) · \(profile.serverHost):\(profile.serverPort)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                connectivityTester.test(
                    profile,
                    timeoutSeconds: preferences.testTimeoutSeconds,
                    maximumConcurrentTests: preferences.maximumConcurrentTests
                )
            } label: {
                connectivityLabel(for: profile)
                    .frame(minWidth: 56, minHeight: 38, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("测试节点 \(profile.name)")

            Button {
                Task { await presentNodeAction(.detail, for: profile) }
            } label: {
                Image(systemName: "info.circle")
                    .frame(width: 32, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AuraPalette.ocean)
            .accessibilityLabel("查看节点详情 \(profile.name)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            nodeActionMenu(for: profile)
        }
    }

    @ViewBuilder
    private func nodeActionMenu(for profile: TunnelProfile) -> some View {
        Button("测试", systemImage: "paperplane") {
            connectivityTester.test(
                profile,
                timeoutSeconds: preferences.testTimeoutSeconds,
                maximumConcurrentTests: preferences.maximumConcurrentTests
            )
        }

        if let subscription = subscription(containing: profile) {
            Button("更新", systemImage: "arrow.clockwise") {
                Task { await importCoordinator.refresh(subscription, using: vpnManager) }
            }
        }

        Button("分享", systemImage: "square.and.arrow.up") {
            Task { await presentNodeAction(.share, for: profile) }
        }
        Button("URL", systemImage: "link") {
            Task { await presentNodeAction(.url, for: profile) }
        }

        Divider()

        Button("编辑", systemImage: "square.and.pencil") {
            Task { await presentNodeAction(.edit, for: profile) }
        }
        Button(
            profile.isHidden == true ? "取消隐藏" : "隐藏",
            systemImage: profile.isHidden == true ? "eye" : "eye.slash"
        ) {
            Task {
                _ = await vpnManager.setProfileHidden(profile, hidden: profile.isHidden != true)
            }
        }

        Divider()

        Button("二维码", systemImage: "qrcode") {
            Task { await presentNodeAction(.qr, for: profile) }
        }
        Button("复制地址", systemImage: "doc.on.doc") {
            Task { await copyNodeURL(profile) }
        }
        PasteButton(payloadType: String.self) { values in
            importCoordinator.receive(payload: values.first)
        }
        .disabled(importCoordinator.isImporting)

        Divider()

        Button("删除", systemImage: "trash", role: .destructive) {
            deletionTarget = .profile(profile)
        }
    }

    @ViewBuilder
    private func connectivityLabel(for profile: TunnelProfile) -> some View {
        switch connectivityTester.state(for: profile.id) {
        case .queued, .testing:
            ProgressView().controlSize(.small)
        case .reachable(let milliseconds):
            Text("\(milliseconds) ms")
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
        case .timedOut:
            Text("超时")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        case .failed:
            Text("失败")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        case .udpOnly:
            Text("UDP")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        case nil:
            Image(systemName: "gauge.with.dots.needle.33percent")
                .foregroundStyle(AuraPalette.ocean)
        }
    }

    private var forwardingNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                .foregroundStyle(AuraPalette.aqua)
            Text("Leaf 转发核心已接入公开 PacketFlow API，支持 VMess、VLESS、Trojan、Shadowsocks 与 SOCKS5；不支持的节点会在启动前明确拒绝。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func profiles(for subscription: SubscriptionProfile) -> [TunnelProfile] {
        if let nodeIDs = subscription.nodeIDs {
            let identifiers = Set(nodeIDs)
            return vpnManager.profiles.filter {
                identifiers.contains($0.id) && (showHiddenNodes || $0.isHidden != true)
            }
        }
        return vpnManager.subscriptions.count == 1
            ? vpnManager.profiles.filter { showHiddenNodes || $0.isHidden != true }
            : []
    }

    private func allProfiles(for subscription: SubscriptionProfile) -> [TunnelProfile] {
        if let nodeIDs = subscription.nodeIDs {
            let identifiers = Set(nodeIDs)
            return vpnManager.profiles.filter { identifiers.contains($0.id) }
        }
        return vpnManager.subscriptions.count == 1 ? vpnManager.profiles : []
    }

    private var displayedSubscriptions: [SubscriptionProfile] {
        vpnManager.subscriptions.filter { showHiddenNodes || $0.isHidden != true }
    }

    private var ungroupedProfiles: [TunnelProfile] {
        if vpnManager.subscriptions.count == 1,
           vpnManager.subscriptions[0].nodeIDs == nil {
            return []
        }
        let groupedIDs = Set(vpnManager.subscriptions.flatMap { $0.nodeIDs ?? [] })
        return vpnManager.profiles.filter {
            !groupedIDs.contains($0.id) && (showHiddenNodes || $0.isHidden != true)
        }
    }

    private var displayedProfiles: [TunnelProfile] {
        vpnManager.profiles.filter { showHiddenNodes || $0.isHidden != true }
    }

    private var hiddenItemCount: Int {
        vpnManager.profiles.lazy.filter { $0.isHidden == true }.count
            + vpnManager.subscriptions.lazy.filter { $0.isHidden == true }.count
    }

    private func subscription(containing profile: TunnelProfile) -> SubscriptionProfile? {
        vpnManager.subscriptions.first { subscription in
            if let nodeIDs = subscription.nodeIDs {
                return nodeIDs.contains(profile.id)
            }
            return vpnManager.subscriptions.count == 1
        }
    }

    private enum NodeActionKind {
        case detail
        case share
        case url
        case edit
        case qr
    }

    private enum SubscriptionActionKind {
        case share
        case url
        case qr
    }

    private func presentNodeAction(_ kind: NodeActionKind, for profile: TunnelProfile) async {
        do {
            let rawURI = try await vpnManager.rawURI(for: profile)
            switch kind {
            case .detail: nodeActionSheet = .detail(profile, rawURI)
            case .share: nodeActionSheet = .share(profile, rawURI)
            case .url: nodeActionSheet = .url(profile, rawURI)
            case .edit: nodeActionSheet = .edit(profile, rawURI)
            case .qr: nodeActionSheet = .qr(profile, rawURI)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            nodeActionError = NodeActionError(message: message)
        }
    }

    private func copyNodeURL(_ profile: TunnelProfile) async {
        do {
            UIPasteboard.general.string = try await vpnManager.rawURI(for: profile)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            nodeActionError = NodeActionError(message: message)
        }
    }

    private func presentSubscriptionAction(
        _ kind: SubscriptionActionKind,
        for subscription: SubscriptionProfile
    ) async {
        do {
            switch kind {
            case .share:
                subscriptionActionSheet = .share(
                    subscription,
                    try await vpnManager.importURI(for: subscription)
                )
            case .url:
                subscriptionActionSheet = .url(
                    subscription,
                    try await vpnManager.rawURL(for: subscription)
                )
            case .qr:
                subscriptionActionSheet = .qr(
                    subscription,
                    try await vpnManager.importURI(for: subscription)
                )
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            nodeActionError = NodeActionError(message: message)
        }
    }

    private func copySubscriptionImportURI(_ subscription: SubscriptionProfile) async {
        do {
            UIPasteboard.general.string = try await vpnManager.importURI(for: subscription)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            nodeActionError = NodeActionError(message: message)
        }
    }

    private func toggle(_ id: UUID) {
        if collapsedSubscriptionIDs.contains(id) {
            collapsedSubscriptionIDs.remove(id)
        } else {
            collapsedSubscriptionIDs.insert(id)
        }
    }

    private func synchronizeExpansionPreference() {
        collapsedSubscriptionIDs = preferences.expandSubscriptions
            ? []
            : Set(vpnManager.subscriptions.map(\.id))
    }

    private func performDeletion(_ target: LibraryDeletionTarget) async {
        switch target {
        case .profile(let profile):
            if await vpnManager.deleteProfile(profile) {
                connectivityTester.forget(profileIDs: [profile.id])
            }
        case .subscription(let subscription):
            let profileIDs = Set(profiles(for: subscription).map(\.id))
            if await vpnManager.deleteSubscription(subscription) {
                connectivityTester.forget(profileIDs: profileIDs)
                collapsedSubscriptionIDs.remove(subscription.id)
            }
        }
    }

    private var selectedNodeDetail: String {
        guard let profile = vpnManager.selectedProfile else {
            return "扫码或从节点库导入配置"
        }
        return "\(profile.proxyProtocol.displayName) · \(profile.serverHost):\(profile.serverPort)"
    }

    private var statusTitle: String {
        if vpnManager.isStartingTunnel {
            return "正在建立安全通道"
        }
        return switch vpnManager.status {
        case .connected: "通道已建立"
        case .connecting: "正在建立通道"
        case .disconnecting: "正在安全断开"
        case .reasserting: "正在恢复通道"
        case .disconnected: "当前未连接"
        case .invalid: "等待连接"
        @unknown default: "状态未知"
        }
    }

    private var statusSymbol: String {
        if vpnManager.isStartingTunnel { return "hourglass" }
        return vpnManager.isConnectedOrConnecting ? "shield.checkered" : "circle.dotted"
    }

    private var connectionButtonTitle: String {
        if vpnManager.isStartingTunnel { return "取消启动" }
        if vpnManager.isConnectedOrConnecting {
            return "断开连接"
        }
        if vpnManager.selectedProfile == nil { return "请先选择节点" }
        return vpnManager.canEstablishRealTunnel ? "建立安全通道" : "当前节点暂不支持"
    }
}

private enum LibraryDeletionTarget: Identifiable {
    case profile(TunnelProfile)
    case subscription(SubscriptionProfile)

    var id: String {
        switch self {
        case .profile(let profile): "profile-\(profile.id.uuidString)"
        case .subscription(let subscription): "subscription-\(subscription.id.uuidString)"
        }
    }

    var actionTitle: String {
        switch self {
        case .profile: "删除节点"
        case .subscription: "删除订阅及专属节点"
        }
    }

    var message: String {
        switch self {
        case .profile(let profile):
            "将从本机删除“\(profile.name)”及其认证信息；此操作不会影响远端订阅服务。"
        case .subscription(let subscription):
            "将删除“\(subscription.name)”和仅属于它的节点；被其他订阅共同引用的节点会保留。"
        }
    }
}
