import Foundation

/// Optional live check for a user-owned subscription without persisting or
/// printing its URL, credentials, node hosts, or node names.
///
/// AURATUNNEL_SUBSCRIPTION='sub://...' /tmp/auratunnel-subscription-smoke
@main
enum SubscriptionImportSmoke {
    static func main() async throws {
        guard let raw = ProcessInfo.processInfo.environment["AURATUNNEL_SUBSCRIPTION"] else {
            fatalError("AURATUNNEL_SUBSCRIPTION is required")
        }
        guard case .subscription(let subscription) = try NodeImportParser.parse(raw) else {
            fatalError("Expected a sub:// payload")
        }
        let nodes = try await SubscriptionImporter.fetchNodes(from: subscription)
        var counts: [ProxyProtocolKind: Int] = [:]
        for node in nodes {
            counts[node.profile.proxyProtocol, default: 0] += 1
            guard let rawURI = String(data: node.protectedPayload, encoding: .utf8) else {
                fatalError("Invalid imported node UTF-8")
            }
            _ = try LeafConfigurationBuilder.makeConfiguration(
                for: node.profile,
                rawURI: rawURI
            )
        }
        let summary = ProxyProtocolKind.allCases.compactMap { kind in
            counts[kind].map { "\(kind.displayName)=\($0)" }
        }.joined(separator: ", ")
        print("AuraTunnel live subscription import and Leaf conversion passed: \(nodes.count) nodes [\(summary)]")
    }
}
