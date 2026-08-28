import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let auraTunnelBackup = UTType(
        exportedAs: "com.shaolihuang.auratunnel.backup",
        conformingTo: .json
    )
}

struct AuraTunnelBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.auraTunnelBackup, .json] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              data.count <= ConfigurationBackupService.maximumArchiveBytes else {
            throw ConfigurationBackupError.invalidArchive
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ConfigurationRestoreMaterial: Sendable {
    let profiles: [TunnelProfile]
    let subscriptions: [SubscriptionProfile]
    let selectedProfile: TunnelProfile?
    let routeMode: AuraRouteMode
    let routingRules: RoutingRuleConfiguration
    let tunnelConfiguration: TunnelConfigurationProfile
    let secrets: [KeychainSecret]
}

enum ConfigurationBackupService {
    static let maximumArchiveBytes = 4 * 1_024 * 1_024
    private static let maximumNodeCount = 500
    private static let maximumSubscriptionCount = 100

    private struct Archive: Codable {
        let formatVersion: Int
        let createdAt: Date
        let appVersion: String
        let selectedProfileID: UUID?
        let routeMode: AuraRouteMode
        let routingRules: RoutingRuleConfiguration
        /// Optional keeps Build 6 archives restorable.
        let tunnelConfiguration: TunnelConfigurationProfile?
        let nodes: [ArchivedNode]
        let subscriptions: [ArchivedSubscription]
    }

    private struct ArchivedNode: Codable {
        let profile: TunnelProfile
        let rawURI: String
    }

    private struct ArchivedSubscription: Codable {
        let profile: SubscriptionProfile
        let rawURL: String
    }

    static func makeArchiveData(
        profiles: [TunnelProfile],
        subscriptions: [SubscriptionProfile],
        selectedProfileID: UUID?,
        routeMode: AuraRouteMode,
        routingRules: RoutingRuleConfiguration,
        tunnelConfiguration: TunnelConfigurationProfile,
        appVersion: String
    ) throws -> Data {
        guard profiles.count <= maximumNodeCount,
              subscriptions.count <= maximumSubscriptionCount else {
            throw ConfigurationBackupError.archiveTooLarge
        }
        let nodes = try profiles.map { profile in
            let data = try SharedKeychain.load(reference: profile.credentialReference)
            guard let rawURI = String(data: data, encoding: .utf8) else {
                throw ConfigurationBackupError.invalidNode(profile.name)
            }
            return ArchivedNode(profile: profile, rawURI: rawURI)
        }
        let archivedSubscriptions = try subscriptions.map { subscription in
            let data = try SharedKeychain.load(reference: subscription.credentialReference)
            guard let rawURL = String(data: data, encoding: .utf8) else {
                throw ConfigurationBackupError.invalidSubscription(subscription.name)
            }
            return ArchivedSubscription(profile: subscription, rawURL: rawURL)
        }
        let archive = Archive(
            formatVersion: 1,
            createdAt: .now,
            appVersion: appVersion,
            selectedProfileID: selectedProfileID,
            routeMode: routeMode,
            routingRules: routingRules.normalized(),
            tunnelConfiguration: tunnelConfiguration.normalized(),
            nodes: nodes,
            subscriptions: archivedSubscriptions
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= maximumArchiveBytes else {
            throw ConfigurationBackupError.archiveTooLarge
        }
        return data
    }

    static func prepareRestore(from data: Data) throws -> ConfigurationRestoreMaterial {
        guard !data.isEmpty, data.count <= maximumArchiveBytes else {
            throw ConfigurationBackupError.invalidArchive
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive: Archive
        do {
            archive = try decoder.decode(Archive.self, from: data)
        } catch {
            throw ConfigurationBackupError.invalidArchive
        }
        guard archive.formatVersion == 1,
              archive.nodes.count <= maximumNodeCount,
              archive.subscriptions.count <= maximumSubscriptionCount else {
            throw ConfigurationBackupError.unsupportedVersion
        }

        var profileIDs = Set<UUID>()
        var profiles: [TunnelProfile] = []
        var secrets: [KeychainSecret] = []
        profiles.reserveCapacity(archive.nodes.count)
        secrets.reserveCapacity(archive.nodes.count + archive.subscriptions.count)

        for node in archive.nodes {
            guard case .node(let parsed) = try NodeImportParser.parse(node.rawURI),
                  parsed.id == node.profile.id,
                  parsed.profile.serverHost == node.profile.serverHost,
                  parsed.profile.serverPort == node.profile.serverPort,
                  parsed.profile.proxyProtocol == node.profile.proxyProtocol,
                  profileIDs.insert(node.profile.id).inserted else {
                throw ConfigurationBackupError.invalidNode(node.profile.name)
            }
            var restored = parsed.profile
            restored.name = node.profile.name
            restored.isHidden = node.profile.isHidden
            profiles.append(restored)
            secrets.append(
                KeychainSecret(reference: restored.credentialReference, data: parsed.protectedPayload)
            )
        }

        var subscriptionIDs = Set<UUID>()
        var subscriptions: [SubscriptionProfile] = []
        for archived in archive.subscriptions {
            guard let url = URL(string: archived.rawURL),
                  url.scheme?.lowercased() == "https",
                  !archived.profile.credentialReference.isEmpty,
                  subscriptionIDs.insert(archived.profile.id).inserted else {
                throw ConfigurationBackupError.invalidSubscription(archived.profile.name)
            }
            let validNodeIDs = (archived.profile.nodeIDs ?? []).filter(profileIDs.contains)
            var restored = archived.profile
            restored.nodeIDs = validNodeIDs
            restored.nodeCount = validNodeIDs.count
            subscriptions.append(restored)
            secrets.append(
                KeychainSecret(reference: restored.credentialReference, data: Data(archived.rawURL.utf8))
            )
        }

        let selectedProfile = archive.selectedProfileID.flatMap { selectedID in
            profiles.first(where: { $0.id == selectedID })
        }
        var tunnelConfiguration = archive.tunnelConfiguration ?? .builtIn
        // The standalone rule field remains authoritative for Build 6 archives.
        tunnelConfiguration.routingRules = archive.routingRules.normalized()
        return ConfigurationRestoreMaterial(
            profiles: profiles,
            subscriptions: subscriptions,
            selectedProfile: selectedProfile,
            routeMode: archive.routeMode,
            routingRules: archive.routingRules.normalized(),
            tunnelConfiguration: tunnelConfiguration.normalized(),
            secrets: secrets
        )
    }
}

enum ConfigurationBackupError: LocalizedError {
    case invalidArchive
    case unsupportedVersion
    case archiveTooLarge
    case invalidNode(String)
    case invalidSubscription(String)
    case tunnelMustBeStopped

    var errorDescription: String? {
        switch self {
        case .invalidArchive: "这不是有效的 AuraTunnel 配置备份文件。"
        case .unsupportedVersion: "备份文件版本不受当前 AuraTunnel 支持。"
        case .archiveTooLarge: "备份内容超过安全大小或数量限制。"
        case .invalidNode(let name): "备份中的节点“\(name)”校验失败。"
        case .invalidSubscription(let name): "备份中的订阅“\(name)”校验失败。"
        case .tunnelMustBeStopped: "恢复配置前请先断开 VPN。"
        }
    }
}
