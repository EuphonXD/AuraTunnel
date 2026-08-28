import Combine
import Foundation

@MainActor
final class NodeImportCoordinator: ObservableObject {
    @Published var pendingCandidate: ImportedConfigurationCandidate?
    @Published var notice: NodeImportNotice?
    @Published private(set) var lastImportReport: NodeImportReport?
    @Published private(set) var lastImportFailure: NodeImportFailure?
    @Published private(set) var isImporting = false
    @Published private(set) var importStage: NodeImportStage?

    func receive(payload: String?) {
        do {
            guard let payload else { throw NodeImportError.emptyPayload }
            pendingCandidate = try NodeImportParser.parse(payload)
        } catch {
            notice = .error(error.localizedDescription)
        }
    }

    func receive(externalURL: URL) {
        do {
            pendingCandidate = try NodeImportParser.parseExternalURL(externalURL)
        } catch {
            notice = .error(error.localizedDescription)
        }
    }

    func cancelPendingImport() {
        pendingCandidate = nil
    }

    func confirmImport(
        _ candidate: ImportedConfigurationCandidate,
        using vpnManager: VPNManager
    ) async {
        guard !isImporting else { return }
        if pendingCandidate?.id == candidate.id {
            pendingCandidate = nil
        }
        isImporting = true
        lastImportReport = nil
        lastImportFailure = nil
        defer {
            importStage = nil
            isImporting = false
        }

        do {
            switch candidate {
            case .node(let node):
                importStage = .saving(nodeCount: 1)
                try await vpnManager.importNodes([node])
                importStage = .verifying(nodeCount: 1)
                try verifyPersistence(of: [node], in: vpnManager)
                lastImportReport = NodeImportReport(
                    title: node.profile.name,
                    importedCount: 1,
                    totalCount: vpnManager.profiles.count,
                    isRefresh: false
                )
                notice = .success("已导入节点“\(node.profile.name)”，正在打开节点列表。")
            case .subscription(let subscription):
                importStage = .downloading(subscriptionName: subscription.name)
                let nodes = try await SubscriptionImporter.fetchNodes(from: subscription)
                importStage = .saving(nodeCount: nodes.count)
                try await vpnManager.importSubscription(subscription, nodes: nodes)
                importStage = .verifying(nodeCount: nodes.count)
                try verifyPersistence(of: nodes, in: vpnManager)
                lastImportReport = NodeImportReport(
                    title: subscription.name,
                    importedCount: nodes.count,
                    totalCount: vpnManager.profiles.count,
                    isRefresh: false
                )
                notice = .success("已从“\(subscription.name)”保存 \(nodes.count) 个节点，正在打开节点列表。")
            }
        } catch {
            let message = userFacingMessage(for: error)
            lastImportFailure = NodeImportFailure(message: message)
            notice = .error(message)
        }
    }

    func refresh(_ storedSubscription: SubscriptionProfile, using vpnManager: VPNManager) async {
        guard !isImporting else { return }
        isImporting = true
        lastImportReport = nil
        lastImportFailure = nil
        importStage = .downloading(subscriptionName: storedSubscription.name)
        defer {
            importStage = nil
            isImporting = false
        }

        do {
            let protectedPayload = try await Task.detached(priority: .userInitiated) {
                try SharedKeychain.load(reference: storedSubscription.credentialReference)
            }.value
            guard
                let value = String(data: protectedPayload, encoding: .utf8),
                let url = URL(string: value),
                url.scheme?.lowercased() == "https"
            else {
                throw SubscriptionImportError.invalidEncoding
            }

            let candidate = ImportedSubscriptionCandidate(
                id: storedSubscription.id,
                name: storedSubscription.name,
                url: url,
                sourceHost: storedSubscription.sourceHost,
                credentialReference: storedSubscription.credentialReference,
                protectedPayload: protectedPayload
            )
            let nodes = try await SubscriptionImporter.fetchNodes(from: candidate)
            importStage = .saving(nodeCount: nodes.count)
            try await vpnManager.importSubscription(candidate, nodes: nodes)
            importStage = .verifying(nodeCount: nodes.count)
            try verifyPersistence(of: nodes, in: vpnManager)
            lastImportReport = NodeImportReport(
                title: candidate.name,
                importedCount: nodes.count,
                totalCount: vpnManager.profiles.count,
                isRefresh: true
            )
            notice = .success("已更新“\(candidate.name)”，共 \(nodes.count) 个节点")
        } catch {
            let message = userFacingMessage(for: error)
            lastImportFailure = NodeImportFailure(message: message)
            notice = .error(message)
        }
    }

    func clearImportFailure() {
        lastImportFailure = nil
    }

    private func verifyPersistence(
        of nodes: [ImportedNodeCandidate],
        in vpnManager: VPNManager
    ) throws {
        let expectedIDs = Set(nodes.map(\.id))
        let publishedIDs = Set(vpnManager.profiles.map(\.id))
        let persistedIDs = Set(SharedStore.loadProfiles().map(\.id))
        guard expectedIDs.isSubset(of: publishedIDs),
              expectedIDs.isSubset(of: persistedIDs) else {
            throw NodeImportPersistenceError.verificationFailed(
                expected: expectedIDs.count,
                published: expectedIDs.intersection(publishedIDs).count,
                persisted: expectedIDs.intersection(persistedIDs).count
            )
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}

enum NodeImportStage: Equatable {
    case downloading(subscriptionName: String)
    case saving(nodeCount: Int)
    case verifying(nodeCount: Int)

    var title: String {
        switch self {
        case .downloading:
            "正在下载订阅"
        case .saving:
            "正在保存节点"
        case .verifying:
            "正在校验导入结果"
        }
    }

    var detail: String {
        switch self {
        case .downloading(let subscriptionName):
            "\(subscriptionName) · 最长等待 30 秒"
        case .saving(let nodeCount):
            "正在安全写入 \(nodeCount) 个节点"
        case .verifying(let nodeCount):
            "核对内存与 App Group 中的 \(nodeCount) 个节点"
        }
    }
}

struct NodeImportReport: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let importedCount: Int
    let totalCount: Int
    let isRefresh: Bool
    let completedAt = Date()
}

struct NodeImportFailure: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let occurredAt = Date()
}

enum NodeImportPersistenceError: LocalizedError {
    case verificationFailed(expected: Int, published: Int, persisted: Int)

    var errorDescription: String? {
        switch self {
        case .verificationFailed(let expected, let published, let persisted):
            "节点持久化校验失败：解析 \(expected) 个、内存可见 \(published) 个、App Group 已保存 \(persisted) 个。请在设置－运行诊断中检查签名能力。"
        }
    }
}

struct NodeImportNotice: Identifiable {
    enum Kind {
        case success
        case error
    }

    let id = UUID()
    let kind: Kind
    let message: String

    static func success(_ message: String) -> NodeImportNotice {
        NodeImportNotice(kind: .success, message: message)
    }

    static func error(_ message: String) -> NodeImportNotice {
        NodeImportNotice(kind: .error, message: message)
    }
}
