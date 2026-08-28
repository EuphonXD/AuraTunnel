import Combine
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    var title: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
}

enum AuraAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// User-facing tunnel notices are read only when a connection state changes.
/// Keeping these values in standard UserDefaults avoids recurring timers or
/// IPC between the app and Packet Tunnel extension.
@MainActor
enum TunnelAlertSettings {
    static let defaultConnectionTimeoutSeconds = 15

    static var connectionTimeoutSeconds: Int {
        let stored = UserDefaults.standard.integer(forKey: Keys.connectionTimeoutSeconds)
        return [10, 15, 20, 30].contains(stored) ? stored : defaultConnectionTimeoutSeconds
    }

    static var showsConnectionFailureAlerts: Bool {
        UserDefaults.standard.object(forKey: Keys.showConnectionFailureAlerts) as? Bool ?? true
    }

    static var showsUnexpectedDisconnectAlerts: Bool {
        UserDefaults.standard.object(forKey: Keys.showUnexpectedDisconnectAlerts) as? Bool ?? true
    }

    enum Keys {
        static let connectionTimeoutSeconds = "preference.connectionTimeoutSeconds.v1"
        static let showConnectionFailureAlerts = "preference.showConnectionFailureAlerts.v1"
        static let showUnexpectedDisconnectAlerts = "preference.showUnexpectedDisconnectAlerts.v1"
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published var routeMode: AuraRouteMode {
        didSet {
            defaults.set(routeMode.rawValue, forKey: Keys.routeMode)
            SharedStore.saveRouteMode(routeMode)
        }
    }
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }
    @Published var appearance: AuraAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    @Published var testTimeoutSeconds: Int {
        didSet { defaults.set(testTimeoutSeconds, forKey: Keys.testTimeoutSeconds) }
    }
    @Published var lowPowerTesting: Bool {
        didSet { defaults.set(lowPowerTesting, forKey: Keys.lowPowerTesting) }
    }
    @Published var expandSubscriptions: Bool {
        didSet { defaults.set(expandSubscriptions, forKey: Keys.expandSubscriptions) }
    }
    @Published var connectionTimeoutSeconds: Int {
        didSet {
            let normalized = [10, 15, 20, 30].contains(connectionTimeoutSeconds)
                ? connectionTimeoutSeconds
                : TunnelAlertSettings.defaultConnectionTimeoutSeconds
            if normalized != connectionTimeoutSeconds {
                connectionTimeoutSeconds = normalized
                return
            }
            defaults.set(connectionTimeoutSeconds, forKey: TunnelAlertSettings.Keys.connectionTimeoutSeconds)
        }
    }
    @Published var showConnectionFailureAlerts: Bool {
        didSet {
            defaults.set(showConnectionFailureAlerts, forKey: TunnelAlertSettings.Keys.showConnectionFailureAlerts)
        }
    }
    @Published var showUnexpectedDisconnectAlerts: Bool {
        didSet {
            defaults.set(showUnexpectedDisconnectAlerts, forKey: TunnelAlertSettings.Keys.showUnexpectedDisconnectAlerts)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        routeMode = AuraRouteMode(
            rawValue: defaults.string(forKey: Keys.routeMode) ?? ""
        ) ?? .smart
        language = AppLanguage(
            rawValue: defaults.string(forKey: Keys.language) ?? ""
        ) ?? .simplifiedChinese
        appearance = AuraAppearance(
            rawValue: defaults.string(forKey: Keys.appearance) ?? ""
        ) ?? .system

        let storedTimeout = defaults.integer(forKey: Keys.testTimeoutSeconds)
        testTimeoutSeconds = [3, 5, 8].contains(storedTimeout) ? storedTimeout : 5
        lowPowerTesting = defaults.object(forKey: Keys.lowPowerTesting) as? Bool ?? true
        expandSubscriptions = defaults.object(forKey: Keys.expandSubscriptions) as? Bool ?? true
        connectionTimeoutSeconds = {
            let value = defaults.integer(forKey: TunnelAlertSettings.Keys.connectionTimeoutSeconds)
            return [10, 15, 20, 30].contains(value)
                ? value
                : TunnelAlertSettings.defaultConnectionTimeoutSeconds
        }()
        showConnectionFailureAlerts = defaults.object(
            forKey: TunnelAlertSettings.Keys.showConnectionFailureAlerts
        ) as? Bool ?? true
        showUnexpectedDisconnectAlerts = defaults.object(
            forKey: TunnelAlertSettings.Keys.showUnexpectedDisconnectAlerts
        ) as? Bool ?? true
        SharedStore.saveRouteMode(routeMode)
    }

    var maximumConcurrentTests: Int {
        lowPowerTesting ? 1 : 3
    }

    private enum Keys {
        static let routeMode = "preference.routeMode.v1"
        static let language = "preference.language.v1"
        static let appearance = "preference.appearance.v1"
        static let testTimeoutSeconds = "preference.testTimeoutSeconds.v1"
        static let lowPowerTesting = "preference.lowPowerTesting.v1"
        static let expandSubscriptions = "preference.expandSubscriptions.v1"
    }
}
