import Foundation
import NetworkExtension

struct TunnelUserNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case connectionFailed
        case connectionTimedOut
        case unexpectedDisconnect
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
}

/// Main-app facade for the system-owned Packet Tunnel configuration.
/// All mutable UI state stays on MainActor; no packet work ever enters this process.
@MainActor
final class VPNManager: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var selectedProfile: TunnelProfile?
    @Published private(set) var profiles: [TunnelProfile]
    @Published private(set) var subscriptions: [SubscriptionProfile]
    @Published private(set) var isLoading = false
    @Published private(set) var isStartingTunnel = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var userNotice: TunnelUserNotice?

    private var manager: NETunnelProviderManager?
    private var pendingConnectionAttempt = false
    private var connectionAttemptID: UUID?
    private var hasObservedConnectionTransition = false
    private var connectionTimeoutTask: Task<Void, Never>?
    private var hasConnectedSession = false
    private var userRequestedDisconnect = false
    // NotificationCenter's Objective-C token is not Sendable. Access is confined
    // to MainActor except synchronous teardown after the instance becomes unreachable.
    nonisolated(unsafe) private var statusObserver: NSObjectProtocol?

    init() {
        selectedProfile = SharedStore.loadSelectedProfile()
        profiles = SharedStore.loadProfiles()
        subscriptions = SharedStore.loadSubscriptions()
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatus()
            }
        }

        Task { [weak self] in
            await self?.loadConfiguration()
        }
    }

    deinit {
        connectionTimeoutTask?.cancel()
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    var isConfigured: Bool {
        guard manager != nil, let selectedProfile else { return false }
        return manager?.isEnabled == true && isSystemConfigurationCurrent(for: selectedProfile)
    }

    var isConnectedOrConnecting: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    var canEstablishRealTunnel: Bool {
        selectedProfile.map { ForwardingCapability.supports($0.proxyProtocol) } ?? false
    }

    /// Loads only configurations created by this app, then selects our provider bundle.
    func loadConfiguration() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first { candidate in
                guard let proto = candidate.protocolConfiguration as? NETunnelProviderProtocol else {
                    return false
                }
                return proto.providerBundleIdentifier == SharedConfiguration.providerBundleIdentifier
            }
            selectedProfile = SharedStore.loadSelectedProfile()
            profiles = SharedStore.loadProfiles()
            subscriptions = SharedStore.loadSubscriptions()
            refreshStatus()
            lastErrorMessage = nil
        } catch {
            record(error)
        }
    }

    /// Saves the selected node into the App Group and updates the system VPN profile.
    /// Call this only after explicit user intent because iOS may show a VPN permission sheet.
    func saveConfiguration(for profile: TunnelProfile) async throws {
        try validate(profile)
        let previousProfile = SharedStore.loadSelectedProfile()
        try SharedStore.saveSelectedProfile(profile)

        let targetManager = manager ?? NETunnelProviderManager()
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = SharedConfiguration.providerBundleIdentifier
        tunnelProtocol.serverAddress = profile.serverHost
        tunnelProtocol.providerConfiguration = profile.providerConfiguration

        targetManager.localizedDescription = SharedConfiguration.tunnelDescription
        targetManager.protocolConfiguration = tunnelProtocol
        targetManager.isEnabled = true

        // Save, then reload: NetworkExtension preferences are system-owned and the
        // reloaded object is the authoritative configuration used by startVPNTunnel().
        do {
            try await targetManager.saveToPreferences()
            try await targetManager.loadFromPreferences()
        } catch {
            if let previousProfile {
                try? SharedStore.saveSelectedProfile(previousProfile)
            } else {
                try? SharedStore.removeSelectedProfile()
            }
            throw error
        }

        manager = targetManager
        selectedProfile = profile
        refreshStatus()
        lastErrorMessage = nil
    }

    func connect() async {
        guard !isLoading, !isStartingTunnel else { return }
        if manager == nil {
            await loadConfiguration()
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            guard let selectedProfile else {
                throw VPNManagerError.configurationMissing
            }
            guard ForwardingCapability.supports(selectedProfile.proxyProtocol) else {
                throw VPNManagerError.unsupportedProtocol(selectedProfile.proxyProtocol)
            }

            // Importing and selecting nodes are local operations. Install/update
            // the system VPN profile only when the user explicitly connects, so a
            // denied permission sheet can never make an imported list disappear.
            if !isSystemConfigurationCurrent(for: selectedProfile) || manager?.isEnabled != true {
                try await saveConfiguration(for: selectedProfile)
            }

            guard let manager else {
                throw VPNManagerError.configurationMissing
            }

            // Always reload before starting so a Settings-app change cannot leave us
            // using a stale in-memory preference object.
            try await manager.loadFromPreferences()
            lastErrorMessage = nil
            let attemptID = UUID()
            userRequestedDisconnect = false
            hasConnectedSession = false
            connectionAttemptID = attemptID
            pendingConnectionAttempt = true
            hasObservedConnectionTransition = false
            isStartingTunnel = true
            SharedStore.saveRuntimeSnapshot(
                TunnelRuntimeSnapshot(
                    state: .preparing,
                    updatedAt: .now,
                    packetCount: 0,
                    byteCount: 0,
                    message: "App 已请求 iOS 启动 PacketTunnel",
                    attemptID: attemptID,
                    appBuild: Self.bundleBuild
                )
            )
            try manager.connection.startVPNTunnel(
                options: [
                    "attemptID": attemptID.uuidString as NSString,
                    "appBuild": Self.bundleBuild as NSString,
                ]
            )
            refreshStatus()
            if pendingConnectionAttempt {
                scheduleConnectionTimeout()
            }
        } catch {
            cancelConnectionTimeout()
            pendingConnectionAttempt = false
            connectionAttemptID = nil
            hasObservedConnectionTransition = false
            hasConnectedSession = false
            isStartingTunnel = false
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastErrorMessage = message
            publishConnectionFailureNotice(message)
            refreshStatus()
        }
    }

    func importNodes(_ candidates: [ImportedNodeCandidate]) async throws {
        try await importCandidates(candidates, subscription: nil)
    }

    func importSubscription(
        _ subscription: ImportedSubscriptionCandidate,
        nodes: [ImportedNodeCandidate]
    ) async throws {
        try await importCandidates(nodes, subscription: subscription)
    }

    func disconnect() {
        cancelConnectionTimeout()
        userRequestedDisconnect = true
        hasConnectedSession = false
        pendingConnectionAttempt = false
        connectionAttemptID = nil
        hasObservedConnectionTransition = false
        isStartingTunnel = false
        manager?.connection.stopVPNTunnel()
        refreshStatus()
    }

    /// Route changes are infrequent user actions. A bounded wait in the main app
    /// avoids racing a new start against iOS tearing down the previous provider;
    /// no polling or timer is introduced into the packet extension.
    func restartTunnelForRouteChangeIfNeeded() async {
        guard isConnectedOrConnecting else { return }
        disconnect()
        for _ in 0..<15 {
            let current = manager?.connection.status ?? .invalid
            if current == .disconnected || current == .invalid { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await connect()
    }

    /// Explicitly prepares the system-owned VPN profile and triggers Apple's
    /// authorization sheet when needed. This does not start the tunnel.
    func installSystemConfiguration() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            guard let selectedProfile else {
                throw VPNManagerError.configurationMissing
            }
            try await saveConfiguration(for: selectedProfile)
        } catch {
            record(error)
        }
    }

    func selectProfile(_ profile: TunnelProfile) async {
        do {
            try validate(profile)
            try SharedStore.saveSelectedProfile(profile)
            selectedProfile = profile
            lastErrorMessage = nil
        } catch {
            record(error)
        }
    }

    func rawURI(for profile: TunnelProfile) async throws -> String {
        let reference = profile.credentialReference
        let data = try await Task.detached(priority: .userInitiated) {
            try SharedKeychain.load(reference: reference)
        }.value
        guard let value = String(data: data, encoding: .utf8) else {
            throw VPNManagerError.invalidProfile("节点 URL 不是有效的 UTF-8 文本。")
        }
        return value
    }

    func rawURL(for subscription: SubscriptionProfile) async throws -> String {
        let reference = subscription.credentialReference
        let data = try await Task.detached(priority: .userInitiated) {
            try SharedKeychain.load(reference: reference)
        }.value
        guard let value = String(data: data, encoding: .utf8),
              let url = URL(string: value),
              url.scheme?.lowercased() == "https" else {
            throw VPNManagerError.invalidProfile("订阅 URL 已损坏，请删除后重新导入。")
        }
        return value
    }

    func makeConfigurationBackup() async throws -> Data {
        let profiles = profiles
        let subscriptions = subscriptions
        let selectedProfileID = selectedProfile?.id
        let routeMode = SharedStore.loadRouteMode()
        let routingRules = SharedStore.loadRoutingRules()
        let tunnelConfiguration = SharedStore.loadTunnelConfiguration()
        let appVersion = Self.displayVersion
        return try await Task.detached(priority: .userInitiated) {
            try ConfigurationBackupService.makeArchiveData(
                profiles: profiles,
                subscriptions: subscriptions,
                selectedProfileID: selectedProfileID,
                routeMode: routeMode,
                routingRules: routingRules,
                tunnelConfiguration: tunnelConfiguration,
                appVersion: appVersion
            )
        }.value
    }

    func restoreConfigurationBackup(_ data: Data) async throws {
        guard !isConnectedOrConnecting else {
            throw ConfigurationBackupError.tunnelMustBeStopped
        }
        let material = try await Task.detached(priority: .userInitiated) {
            try ConfigurationBackupService.prepareRestore(from: data)
        }.value

        let oldProfiles = SharedStore.loadProfiles()
        let oldSubscriptions = SharedStore.loadSubscriptions()
        let oldSelectedProfile = SharedStore.loadSelectedProfile()
        let oldRouteMode = SharedStore.loadRouteMode()
        let oldRoutingRules = SharedStore.loadRoutingRules()
        let oldTunnelConfiguration = SharedStore.loadTunnelConfiguration()
        let keychainBackups = try await Task.detached(priority: .userInitiated) {
            try SharedKeychain.replaceBatch(material.secrets)
        }.value

        do {
            try SharedStore.saveProfiles(material.profiles)
            try SharedStore.saveSubscriptions(material.subscriptions)
            if let selected = material.selectedProfile {
                try SharedStore.saveSelectedProfile(selected)
            } else {
                try SharedStore.removeSelectedProfile()
            }
            SharedStore.saveRouteMode(material.routeMode)
            try SharedStore.saveTunnelConfiguration(material.tunnelConfiguration)
        } catch {
            try? SharedStore.saveProfiles(oldProfiles)
            try? SharedStore.saveSubscriptions(oldSubscriptions)
            if let oldSelectedProfile {
                try? SharedStore.saveSelectedProfile(oldSelectedProfile)
            } else {
                try? SharedStore.removeSelectedProfile()
            }
            SharedStore.saveRouteMode(oldRouteMode)
            var restoredConfiguration = oldTunnelConfiguration
            restoredConfiguration.routingRules = oldRoutingRules
            try? SharedStore.saveTunnelConfiguration(restoredConfiguration)
            try? await Task.detached(priority: .userInitiated) {
                try SharedKeychain.restore(keychainBackups)
            }.value
            throw error
        }

        let restoredReferences = Set(material.secrets.map(\.reference))
        let staleReferences = Set(
            oldProfiles.map(\.credentialReference) + oldSubscriptions.map(\.credentialReference)
        ).subtracting(restoredReferences)
        await Task.detached(priority: .utility) {
            for reference in staleReferences { try? SharedKeychain.remove(reference: reference) }
        }.value

        profiles = material.profiles
        subscriptions = material.subscriptions
        selectedProfile = material.selectedProfile
        lastErrorMessage = nil
    }

    /// Portable representation accepted by AuraTunnel/Shadowrocket-style importers.
    func importURI(for subscription: SubscriptionProfile) async throws -> String {
        let rawURL = try await rawURL(for: subscription)
        let encoded = Data(rawURL.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let allowed = CharacterSet.urlFragmentAllowed.subtracting(CharacterSet(charactersIn: "#%"))
        let title = subscription.name.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? subscription.sourceHost
        return "sub://\(encoded)#\(title)"
    }

    func updateSubscription(_ subscription: SubscriptionProfile, displayName: String) async throws {
        guard !isLoading else { throw VPNManagerError.operationInProgress }
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw VPNManagerError.invalidProfile("订阅名称不能为空。")
        }

        let oldSubscriptions = subscriptions
        guard let index = oldSubscriptions.firstIndex(where: { $0.id == subscription.id }) else {
            throw VPNManagerError.invalidProfile("该订阅已不存在。")
        }
        var updatedSubscriptions = oldSubscriptions
        updatedSubscriptions[index].name = normalizedName
        try SharedStore.saveSubscriptions(updatedSubscriptions)
        subscriptions = updatedSubscriptions
        lastErrorMessage = nil
    }

    @discardableResult
    func setSubscriptionHidden(_ subscription: SubscriptionProfile, hidden: Bool) async -> Bool {
        guard !isLoading else { return false }
        let oldSubscriptions = subscriptions
        guard let index = oldSubscriptions.firstIndex(where: { $0.id == subscription.id }) else {
            return false
        }
        var updatedSubscriptions = oldSubscriptions
        updatedSubscriptions[index].isHidden = hidden
        do {
            try SharedStore.saveSubscriptions(updatedSubscriptions)
            subscriptions = updatedSubscriptions
            lastErrorMessage = nil
            return true
        } catch {
            record(error)
            return false
        }
    }

    /// Updates the display name and optionally replaces the full original URI.
    /// Parsing the URI again keeps protocol-specific credentials and endpoint
    /// summaries consistent instead of editing security fields independently.
    func updateProfile(
        _ original: TunnelProfile,
        displayName: String,
        rawURI: String
    ) async throws {
        guard !isLoading else { throw VPNManagerError.operationInProgress }
        isLoading = true
        defer { isLoading = false }

        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw VPNManagerError.invalidProfile("节点名称不能为空。")
        }
        let normalizedURI = rawURI.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = try NodeImportParser.parse(normalizedURI)
        guard case .node(let candidate) = parsed else {
            throw VPNManagerError.invalidProfile("编辑节点时不能填写订阅 URL。")
        }

        var replacement = candidate.profile
        replacement.name = normalizedName
        replacement.isHidden = original.isHidden
        try validate(replacement)

        let oldProfiles = profiles
        let oldSubscriptions = subscriptions
        let oldSelection = selectedProfile
        guard oldProfiles.contains(where: { $0.id == original.id }) else {
            throw VPNManagerError.invalidProfile("要编辑的节点已不存在。")
        }

        let secret = KeychainSecret(
            reference: replacement.credentialReference,
            data: Data(normalizedURI.utf8)
        )
        let backups = try await Task.detached(priority: .userInitiated) {
            try SharedKeychain.replaceBatch([secret])
        }.value

        var mergedProfiles = Dictionary(uniqueKeysWithValues: oldProfiles.map { ($0.id, $0) })
        mergedProfiles.removeValue(forKey: original.id)
        mergedProfiles[replacement.id] = replacement
        let updatedProfiles = mergedProfiles.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let updatedSubscriptions = oldSubscriptions.map { subscription in
            var updated = subscription
            let originalIDs: [UUID]
            if let nodeIDs = subscription.nodeIDs {
                originalIDs = nodeIDs
            } else if oldSubscriptions.count == 1 {
                originalIDs = oldProfiles.map(\.id)
            } else {
                originalIDs = []
            }

            var seen: Set<UUID> = []
            let replacedIDs = originalIDs.compactMap { identifier -> UUID? in
                let value = identifier == original.id ? replacement.id : identifier
                return seen.insert(value).inserted ? value : nil
            }
            updated.nodeIDs = replacedIDs
            updated.nodeCount = replacedIDs.count
            return updated
        }
        let updatedSelection = oldSelection?.id == original.id ? replacement : oldSelection

        do {
            try persistLibrary(
                profiles: updatedProfiles,
                subscriptions: updatedSubscriptions,
                selectedProfile: updatedSelection,
                rollbackProfiles: oldProfiles,
                rollbackSubscriptions: oldSubscriptions,
                rollbackSelectedProfile: oldSelection
            )
        } catch {
            try? await Task.detached(priority: .utility) {
                try SharedKeychain.restore(backups)
            }.value
            record(error)
            throw error
        }

        if configuredProfileID == original.id,
           isConnectedOrConnecting,
           replacement.id != original.id {
            disconnect()
        }
        if replacement.credentialReference != original.credentialReference {
            await removeUnusedSecrets([original.credentialReference])
        }
        lastErrorMessage = nil
    }

    @discardableResult
    func setProfileHidden(_ profile: TunnelProfile, hidden: Bool) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }

        let oldProfiles = profiles
        let oldSubscriptions = subscriptions
        let oldSelection = selectedProfile
        guard let index = oldProfiles.firstIndex(where: { $0.id == profile.id }) else {
            return false
        }
        var updatedProfiles = oldProfiles
        updatedProfiles[index].isHidden = hidden
        let updatedSelection: TunnelProfile?
        if hidden, oldSelection?.id == profile.id {
            updatedSelection = updatedProfiles.first { $0.isHidden != true }
        } else if oldSelection?.id == profile.id {
            updatedSelection = updatedProfiles[index]
        } else {
            updatedSelection = oldSelection
        }

        do {
            try persistLibrary(
                profiles: updatedProfiles,
                subscriptions: oldSubscriptions,
                selectedProfile: updatedSelection,
                rollbackProfiles: oldProfiles,
                rollbackSubscriptions: oldSubscriptions,
                rollbackSelectedProfile: oldSelection
            )
            lastErrorMessage = nil
            return true
        } catch {
            record(error)
            return false
        }
    }

    /// Deletes one imported node from the local library and every subscription
    /// membership that references it. The currently selected node falls back to
    /// the next remaining profile; no VPN permission prompt is triggered here.
    @discardableResult
    func deleteProfile(_ profile: TunnelProfile) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }

        let oldProfiles = profiles
        guard oldProfiles.contains(where: { $0.id == profile.id }) else { return true }
        let oldSubscriptions = subscriptions
        let oldSelection = selectedProfile
        let updatedProfiles = oldProfiles.filter { $0.id != profile.id }
        let updatedSubscriptions = oldSubscriptions.map { subscription in
            var updated = subscription
            let originalNodeIDs: [UUID]
            if let nodeIDs = subscription.nodeIDs {
                originalNodeIDs = nodeIDs
            } else if oldSubscriptions.count == 1 {
                // Migrate the original v1 subscription shape while deleting.
                originalNodeIDs = oldProfiles.map(\.id)
            } else {
                originalNodeIDs = []
            }
            let remainingNodeIDs = originalNodeIDs.filter { $0 != profile.id }
            updated.nodeIDs = remainingNodeIDs
            updated.nodeCount = remainingNodeIDs.count
            return updated
        }
        let updatedSelection: TunnelProfile?
        if let oldSelection, oldSelection.id != profile.id {
            updatedSelection = oldSelection
        } else {
            updatedSelection = updatedProfiles.first
        }

        do {
            try persistLibrary(
                profiles: updatedProfiles,
                subscriptions: updatedSubscriptions,
                selectedProfile: updatedSelection,
                rollbackProfiles: oldProfiles,
                rollbackSubscriptions: oldSubscriptions,
                rollbackSelectedProfile: oldSelection
            )

            if configuredProfileID == profile.id, isConnectedOrConnecting {
                disconnect()
            }
            await removeUnusedSecrets([profile.credentialReference])
            lastErrorMessage = nil
            return true
        } catch {
            record(error)
            return false
        }
    }

    /// Deletes a subscription and the nodes that belong only to that subscription.
    /// Nodes shared by another subscription are retained.
    @discardableResult
    func deleteSubscription(_ subscription: SubscriptionProfile) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }

        let oldProfiles = profiles
        let oldSubscriptions = subscriptions
        let oldSelection = selectedProfile
        guard oldSubscriptions.contains(where: { $0.id == subscription.id }) else { return true }

        let subscriptionNodeIDs: Set<UUID>
        if let nodeIDs = subscription.nodeIDs {
            subscriptionNodeIDs = Set(nodeIDs)
        } else if oldSubscriptions.count == 1 {
            subscriptionNodeIDs = Set(oldProfiles.map(\.id))
        } else {
            // Ambiguous legacy data: remove the source but preserve nodes rather
            // than risk deleting profiles owned by another subscription.
            subscriptionNodeIDs = []
        }

        let otherNodeIDs = Set(
            oldSubscriptions
                .filter { $0.id != subscription.id }
                .flatMap { $0.nodeIDs ?? [] }
        )
        let removedNodeIDs = subscriptionNodeIDs.subtracting(otherNodeIDs)
        let removedProfiles = oldProfiles.filter { removedNodeIDs.contains($0.id) }
        let updatedProfiles = oldProfiles.filter { !removedNodeIDs.contains($0.id) }
        let updatedSubscriptions = oldSubscriptions.filter { $0.id != subscription.id }
        let updatedSelection: TunnelProfile?
        if let oldSelection, !removedNodeIDs.contains(oldSelection.id) {
            updatedSelection = oldSelection
        } else {
            updatedSelection = updatedProfiles.first
        }

        do {
            try persistLibrary(
                profiles: updatedProfiles,
                subscriptions: updatedSubscriptions,
                selectedProfile: updatedSelection,
                rollbackProfiles: oldProfiles,
                rollbackSubscriptions: oldSubscriptions,
                rollbackSelectedProfile: oldSelection
            )

            if let configuredProfileID,
               removedNodeIDs.contains(configuredProfileID),
               isConnectedOrConnecting {
                disconnect()
            }
            await removeUnusedSecrets(
                [subscription.credentialReference] + removedProfiles.map(\.credentialReference)
            )
            lastErrorMessage = nil
            return true
        } catch {
            record(error)
            return false
        }
    }

    func removeConfiguration() async {
        guard let manager else { return }
        do {
            cancelConnectionTimeout()
            pendingConnectionAttempt = false
            connectionAttemptID = nil
            hasObservedConnectionTransition = false
            userRequestedDisconnect = true
            hasConnectedSession = false
            isStartingTunnel = false
            try await manager.removeFromPreferences()
            self.manager = nil
            status = .invalid
            lastErrorMessage = nil
        } catch {
            record(error)
        }
    }

    /// On-demand IPC only. Never poll this at packet frequency or on a tight timer.
    func requestRuntimeSnapshot() async -> TunnelRuntimeSnapshot {
        guard
            let session = manager?.connection as? NETunnelProviderSession,
            status == .connected,
            let request = try? JSONEncoder().encode(TunnelIPCCommand.runtimeSnapshot)
        else {
            return SharedStore.loadRuntimeSnapshot()
        }

        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(request) { response in
                    let snapshot = response.flatMap {
                        try? JSONDecoder().decode(TunnelRuntimeSnapshot.self, from: $0)
                    } ?? SharedStore.loadRuntimeSnapshot()
                    continuation.resume(returning: snapshot)
                }
            } catch {
                continuation.resume(returning: SharedStore.loadRuntimeSnapshot())
            }
        }
    }

    private func refreshStatus() {
        let previousStatus = status
        let updatedStatus = manager?.connection.status ?? .invalid
        status = updatedStatus

        if updatedStatus == .connected {
            cancelConnectionTimeout()
            pendingConnectionAttempt = false
            hasObservedConnectionTransition = true
            hasConnectedSession = true
            userRequestedDisconnect = false
            isStartingTunnel = false
            lastErrorMessage = nil
        } else if pendingConnectionAttempt,
                  (updatedStatus == .connecting || updatedStatus == .reasserting) {
            // startVPNTunnel() can return while the status is still disconnected.
            // Only a later connecting/reasserting event proves the system has begun
            // the attempt; this avoids a false failure/connecting UI flash.
            hasObservedConnectionTransition = true
            isStartingTunnel = true
        } else if pendingConnectionAttempt,
                  hasObservedConnectionTransition,
                  (updatedStatus == .disconnected || updatedStatus == .invalid) {
            cancelConnectionTimeout()
            let failedAttemptID = connectionAttemptID
            pendingConnectionAttempt = false
            isStartingTunnel = false
            lastErrorMessage = connectionFailureMessage(
                attemptID: failedAttemptID,
                fallback: "Packet Tunnel 启动后已退出，请在活动页查看扩展返回的具体原因。"
            )
            hasConnectedSession = false
            if let lastErrorMessage {
                publishConnectionFailureNotice(lastErrorMessage)
            }
            connectionAttemptID = nil
        } else if hasConnectedSession,
                  !userRequestedDisconnect,
                  (updatedStatus == .disconnected || updatedStatus == .invalid) {
            cancelConnectionTimeout()
            let failedAttemptID = connectionAttemptID
            pendingConnectionAttempt = false
            connectionAttemptID = nil
            hasObservedConnectionTransition = false
            hasConnectedSession = false
            isStartingTunnel = false
            let transition = previousStatus == .reasserting ? "恢复连接时意外退出" : "连接已意外断开"
            let message = connectionFailureMessage(
                attemptID: failedAttemptID,
                fallback: transition + "。请检查当前网络和节点状态，或在活动页查看扩展诊断。"
            )
            lastErrorMessage = message
            if TunnelAlertSettings.showsUnexpectedDisconnectAlerts {
                userNotice = TunnelUserNotice(
                    kind: .unexpectedDisconnect,
                    title: "VPN 连接已断开",
                    message: message
                )
            }
        }
    }

    /// A single delayed deadline guards a system transition that never arrives.
    /// This is not polling and creates no recurring CPU wakeups in either process.
    private func scheduleConnectionTimeout() {
        cancelConnectionTimeout()
        let timeoutSeconds = TunnelAlertSettings.connectionTimeoutSeconds
        connectionTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
            } catch {
                return
            }
            guard let self, self.pendingConnectionAttempt else { return }

            let timedOutAttemptID = self.connectionAttemptID
            self.pendingConnectionAttempt = false
            self.hasObservedConnectionTransition = false
            self.hasConnectedSession = false
            self.userRequestedDisconnect = true
            self.isStartingTunnel = false
            self.manager?.connection.stopVPNTunnel()
            self.lastErrorMessage = self.connectionFailureMessage(
                attemptID: timedOutAttemptID,
                fallback: "连接在 " + String(timeoutSeconds) + " 秒内未完成。请检查节点可用性，并在活动页查看扩展诊断。"
            )
            if TunnelAlertSettings.showsConnectionFailureAlerts,
               let lastErrorMessage = self.lastErrorMessage {
                self.userNotice = TunnelUserNotice(
                    kind: .connectionTimedOut,
                    title: "VPN 连接超时",
                    message: lastErrorMessage
                )
            }
            self.connectionAttemptID = nil
            self.connectionTimeoutTask = nil
        }
    }

    private func cancelConnectionTimeout() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
    }

    private func connectionFailureMessage(attemptID: UUID?, fallback: String) -> String {
        let snapshot = SharedStore.loadRuntimeSnapshot()
        if let attemptID {
            guard snapshot.attemptID == attemptID else { return fallback }
        }
        if snapshot.state == .failed,
           let message = snapshot.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        if snapshot.state == .preparing,
           let stage = snapshot.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stage.isEmpty {
            return "Packet Tunnel 在“\(stage)”阶段退出。"
        }
        return fallback
    }

    func dismissUserNotice() {
        userNotice = nil
    }

    private func publishConnectionFailureNotice(_ message: String) {
        guard TunnelAlertSettings.showsConnectionFailureAlerts else { return }
        userNotice = TunnelUserNotice(
            kind: .connectionFailed,
            title: "无法建立 VPN 连接",
            message: message
        )
    }

    private static var bundleBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    private static var displayVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "\(version) (\(bundleBuild))"
    }

    private var configuredProfileID: UUID? {
        guard
            let tunnelProtocol = manager?.protocolConfiguration as? NETunnelProviderProtocol,
            let value = tunnelProtocol.providerConfiguration?["profileID"] as? String
        else {
            return nil
        }
        return UUID(uuidString: value)
    }

    private func isSystemConfigurationCurrent(for profile: TunnelProfile) -> Bool {
        guard
            let tunnelProtocol = manager?.protocolConfiguration as? NETunnelProviderProtocol,
            tunnelProtocol.providerBundleIdentifier == SharedConfiguration.providerBundleIdentifier,
            let configuration = tunnelProtocol.providerConfiguration,
            configuration["profileID"] as? String == profile.id.uuidString,
            configuration["serverHost"] as? String == profile.serverHost,
            configuration["serverPort"] as? Int == Int(profile.serverPort),
            configuration["proxyProtocol"] as? String == profile.proxyProtocol.rawValue
        else {
            return false
        }
        return true
    }

    private func importCandidates(
        _ candidates: [ImportedNodeCandidate],
        subscription: ImportedSubscriptionCandidate?
    ) async throws {
        var seenCandidateIDs = Set<UUID>()
        let uniqueCandidates = candidates.filter {
            seenCandidateIDs.insert($0.id).inserted
        }
        guard let first = uniqueCandidates.first else {
            throw VPNManagerError.invalidProfile("没有可以导入的节点")
        }

        let oldProfiles = SharedStore.loadProfiles()
        let oldSubscriptions = SharedStore.loadSubscriptions()
        let oldSelectedProfile = SharedStore.loadSelectedProfile()
        var secrets = uniqueCandidates.map {
            KeychainSecret(reference: $0.profile.credentialReference, data: $0.protectedPayload)
        }
        if let subscription {
            secrets.append(
                KeychainSecret(
                    reference: subscription.credentialReference,
                    data: subscription.protectedPayload
                )
            )
        }

        let backups = try await Task.detached(priority: .userInitiated) {
            try SharedKeychain.replaceBatch(secrets)
        }.value

        do {
            var mergedProfiles: [UUID: TunnelProfile] = [:]
            for profile in oldProfiles {
                mergedProfiles[profile.id] = profile
            }

            // A subscription refresh replaces that subscription's node set. Remove
            // disappeared nodes unless another subscription still references them.
            // This prevents stale servers from leaking into the standalone-node list.
            var retiredCredentialReferences: [String] = []
            if let subscription,
               let previous = oldSubscriptions.first(where: { $0.id == subscription.id }) {
                let previousNodeIDs: Set<UUID>
                if let storedIDs = previous.nodeIDs {
                    previousNodeIDs = Set(storedIDs)
                } else if oldSubscriptions.count == 1 {
                    // Backward-compatible migration for builds that stored only a count.
                    previousNodeIDs = Set(oldProfiles.map(\.id))
                } else {
                    previousNodeIDs = []
                }

                let incomingNodeIDs = Set(uniqueCandidates.map(\.id))
                let otherSubscriptionNodeIDs = Set(
                    oldSubscriptions
                        .filter { $0.id != subscription.id }
                        .flatMap { $0.nodeIDs ?? [] }
                )
                let retiredNodeIDs = previousNodeIDs
                    .subtracting(incomingNodeIDs)
                    .subtracting(otherSubscriptionNodeIDs)

                for profile in oldProfiles where retiredNodeIDs.contains(profile.id) {
                    retiredCredentialReferences.append(profile.credentialReference)
                    mergedProfiles.removeValue(forKey: profile.id)
                }
            }

            for candidate in uniqueCandidates {
                var incomingProfile = candidate.profile
                // Refreshing a subscription must not silently undo a local
                // hide choice for an otherwise identical stable node.
                incomingProfile.isHidden = mergedProfiles[candidate.profile.id]?.isHidden
                mergedProfiles[candidate.profile.id] = incomingProfile
            }
            let updatedProfiles = mergedProfiles.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            try SharedStore.saveProfiles(updatedProfiles)

            var updatedSubscriptions = oldSubscriptions
            if let subscription {
                var stored = subscription.storedProfile(nodes: uniqueCandidates)
                stored.isHidden = oldSubscriptions.first(where: { $0.id == stored.id })?.isHidden
                updatedSubscriptions.removeAll { $0.id == stored.id }
                updatedSubscriptions.append(stored)
                updatedSubscriptions.sort {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                try SharedStore.saveSubscriptions(updatedSubscriptions)
            }

            // Persist the default selection locally. Installing a
            // NETunnelProviderManager profile belongs to explicit connect intent.
            try SharedStore.saveSelectedProfile(first.profile)
            profiles = updatedProfiles
            subscriptions = updatedSubscriptions
            selectedProfile = first.profile
            lastErrorMessage = nil

            // Cleanup is deliberately off MainActor and outside the persistence
            // transaction. A failed deletion leaves only an inaccessible orphaned
            // Keychain item; it must not roll back a successfully refreshed list.
            if !retiredCredentialReferences.isEmpty {
                let references = retiredCredentialReferences
                Task.detached(priority: .utility) {
                    for reference in references {
                        try? SharedKeychain.remove(reference: reference)
                    }
                }
            }
        } catch {
            try? SharedStore.saveProfiles(oldProfiles)
            try? SharedStore.saveSubscriptions(oldSubscriptions)
            if let oldSelectedProfile {
                try? SharedStore.saveSelectedProfile(oldSelectedProfile)
            } else {
                try? SharedStore.removeSelectedProfile()
            }
            try? await Task.detached(priority: .utility) {
                try SharedKeychain.restore(backups)
            }.value
            throw error
        }
    }

    private func validate(_ profile: TunnelProfile) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VPNManagerError.invalidProfile("节点名称不能为空")
        }
        guard !profile.serverHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VPNManagerError.invalidProfile("服务器地址不能为空")
        }
        guard profile.serverPort > 0 else {
            throw VPNManagerError.invalidProfile("服务器端口无效")
        }
        guard !profile.credentialReference.isEmpty else {
            throw VPNManagerError.invalidProfile("节点认证信息引用无效")
        }
    }

    private func persistLibrary(
        profiles updatedProfiles: [TunnelProfile],
        subscriptions updatedSubscriptions: [SubscriptionProfile],
        selectedProfile updatedSelectedProfile: TunnelProfile?,
        rollbackProfiles: [TunnelProfile],
        rollbackSubscriptions: [SubscriptionProfile],
        rollbackSelectedProfile: TunnelProfile?
    ) throws {
        do {
            try SharedStore.saveProfiles(updatedProfiles)
            try SharedStore.saveSubscriptions(updatedSubscriptions)
            if let updatedSelectedProfile {
                try SharedStore.saveSelectedProfile(updatedSelectedProfile)
            } else {
                try SharedStore.removeSelectedProfile()
            }
        } catch {
            try? SharedStore.saveProfiles(rollbackProfiles)
            try? SharedStore.saveSubscriptions(rollbackSubscriptions)
            if let rollbackSelectedProfile {
                try? SharedStore.saveSelectedProfile(rollbackSelectedProfile)
            } else {
                try? SharedStore.removeSelectedProfile()
            }
            throw error
        }

        profiles = updatedProfiles
        subscriptions = updatedSubscriptions
        selectedProfile = updatedSelectedProfile
    }

    private func removeUnusedSecrets(_ references: [String]) async {
        let activeReferences = Set(profiles.map(\.credentialReference))
            .union(subscriptions.map(\.credentialReference))
        let removableReferences = Set(references).subtracting(activeReferences)
        guard !removableReferences.isEmpty else { return }

        await Task.detached(priority: .utility) {
            for reference in removableReferences {
                try? SharedKeychain.remove(reference: reference)
            }
        }.value
    }

    private func record(_ error: Error) {
        lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        refreshStatus()
    }
}

enum VPNManagerError: LocalizedError {
    case configurationMissing
    case unsupportedProtocol(ProxyProtocolKind)
    case invalidProfile(String)
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "请先导入并保存一个服务器节点。"
        case .unsupportedProtocol(let kind):
            return "当前 Leaf 核心暂不支持 \(kind.displayName) 节点，请选择 VMess、VLESS、Trojan、Shadowsocks 或 SOCKS5。"
        case .invalidProfile(let message):
            return message
        case .operationInProgress:
            return "另一项节点或 VPN 操作正在进行，请稍候。"
        }
    }
}
