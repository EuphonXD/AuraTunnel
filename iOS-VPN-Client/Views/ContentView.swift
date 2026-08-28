import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var vpnManager: VPNManager
    @EnvironmentObject private var importCoordinator: NodeImportCoordinator
    @EnvironmentObject private var preferences: AppPreferences
    @State private var selectedTab: AuraTab = .home
    @State private var isShowingScanner = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(
                    onScan: { isShowingScanner = true },
                    onOpenLibrary: { selectedTab = .library }
                )
            }
            .tag(AuraTab.home)
            .tabItem { Label("连接", systemImage: "wave.3.right.circle.fill") }

            NavigationStack {
                LibraryView(onScan: { isShowingScanner = true })
            }
            .tag(AuraTab.library)
            .tabItem { Label("节点库", systemImage: "square.stack.3d.up.fill") }

            NavigationStack {
                ConfigurationView()
            }
            .tag(AuraTab.configuration)
            .tabItem { Label("配置", systemImage: "folder.fill") }

            NavigationStack {
                ActivityView()
            }
            .tag(AuraTab.activity)
            .tabItem { Label("活动", systemImage: "chart.xyaxis.line") }

            NavigationStack {
                SettingsView()
            }
            .tag(AuraTab.settings)
            .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
        }
        .tint(AuraPalette.aqua)
        .overlay {
            if let stage = importCoordinator.importStage {
                importProgressOverlay(stage)
            }
        }
        .onChange(of: importCoordinator.lastImportReport?.id) { _ in
            guard importCoordinator.lastImportReport?.isRefresh == false else { return }
            selectedTab = .home
        }
        .onChange(of: preferences.routeMode) { _ in
            Task { await vpnManager.restartTunnelForRouteChangeIfNeeded() }
        }
        .onOpenURL { url in
            importCoordinator.receive(externalURL: url)
        }
        .sheet(isPresented: $isShowingScanner) {
            QRCodeScannerView {
                isShowingScanner = false
                importCoordinator.receive(payload: $0)
            } onCancel: {
                isShowingScanner = false
            }
            .ignoresSafeArea()
        }
        .alert(
            "确认导入",
            isPresented: Binding(
                get: { importCoordinator.pendingCandidate != nil },
                // Alert buttons own cancellation/confirmation. Clearing the
                // candidate from this setter races the async import task because
                // SwiftUI may dismiss the alert before the Task starts.
                set: { _ in }
            ),
            presenting: importCoordinator.pendingCandidate
        ) { candidate in
            Button("取消", role: .cancel) {
                importCoordinator.cancelPendingImport()
            }
            Button("导入") {
                Task {
                    await importCoordinator.confirmImport(candidate, using: vpnManager)
                }
            }
        } message: { candidate in
            Text(candidate.confirmationMessage)
        }
        .alert(item: $importCoordinator.notice) { notice in
            Alert(
                title: Text(notice.kind == .success ? "导入完成" : "导入失败"),
                message: Text(notice.message),
                dismissButton: .default(Text("好"))
            )
        }
        .alert(
            item: Binding(
                get: { vpnManager.userNotice },
                set: { notice in
                    if notice == nil { vpnManager.dismissUserNotice() }
                }
            )
        ) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                primaryButton: .default(Text("查看活动")) {
                    vpnManager.dismissUserNotice()
                    selectedTab = .activity
                },
                secondaryButton: .cancel(Text("稍后")) {
                    vpnManager.dismissUserNotice()
                }
            )
        }
    }

    private func importProgressOverlay(_ stage: NodeImportStage) -> some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(AuraPalette.aqua)
                Text(stage.title)
                    .font(.headline)
                Text(stage.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 22))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(stage.title)，\(stage.detail)")
        }
    }
}

private enum AuraTab: Hashable {
    case home
    case library
    case configuration
    case activity
    case settings
}

#Preview {
    ContentView()
        .environmentObject(VPNManager())
        .environmentObject(NodeImportCoordinator())
        .environmentObject(NodeConnectivityTester())
        .environmentObject(AppPreferences())
}
