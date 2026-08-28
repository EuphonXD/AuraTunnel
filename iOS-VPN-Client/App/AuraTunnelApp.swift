import SwiftUI

@main
struct AuraTunnelApp: App {
    @StateObject private var vpnManager = VPNManager()
    @StateObject private var importCoordinator = NodeImportCoordinator()
    @StateObject private var connectivityTester = NodeConnectivityTester()
    @StateObject private var preferences = AppPreferences()
    @AppStorage("privacy.vpnDataDisclosureAccepted.v1") private var hasAcceptedVPNDataDisclosure = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasAcceptedVPNDataDisclosure {
                    ContentView()
                } else {
                    VPNDataDisclosureView {
                        hasAcceptedVPNDataDisclosure = true
                    }
                }
            }
                .environmentObject(vpnManager)
                .environmentObject(importCoordinator)
                .environmentObject(connectivityTester)
                .environmentObject(preferences)
                .environment(\.locale, preferences.language.locale)
                .preferredColorScheme(preferences.appearance.colorScheme)
        }
    }
}
