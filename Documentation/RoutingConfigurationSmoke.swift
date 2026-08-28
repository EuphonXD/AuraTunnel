import Foundation

/// Run manually with:
/// swiftc Shared/SharedConfiguration.swift Shared/SharedKeychain.swift \
///   PacketTunnel/Core/LeafConfigurationBuilder.swift \
///   Documentation/RoutingConfigurationSmoke.swift -o /tmp/auratunnel-routing-smoke
@main
enum RoutingConfigurationSmoke {
    static func main() throws {
        let vmessObject: [String: Any] = [
            "v": "2",
            "ps": "Routing Smoke",
            "add": "example.com",
            "port": "443",
            "id": "db4df817-72cc-4a14-9ee8-a4448ca0e13f",
            "aid": "0",
            "scy": "aes-128-gcm",
            "net": "ws",
            "host": "example.com",
            "path": "/ws",
            "tls": "tls",
        ]
        let encoded = try JSONSerialization.data(withJSONObject: vmessObject).base64EncodedString()
        let rawURI = "vmess://\(encoded)"
        let profile = TunnelProfile(
            name: "Routing Smoke",
            serverHost: "example.com",
            serverPort: 443,
            transport: .tcp,
            proxyProtocol: .vmess,
            credentialReference: "unused"
        )

        for mode in AuraRouteMode.allCases {
            let value = try LeafConfigurationBuilder.makeConfiguration(
                for: profile,
                rawURI: rawURI,
                routeMode: mode,
                routingRules: .builtIn
            )
            let data = try require(value.data(using: .utf8))
            let root = try require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let outbounds = try require(root["outbounds"] as? [[String: Any]])
            let firstTag = try require(outbounds.first?["tag"] as? String)
            let inbound = try require((root["inbounds"] as? [[String: Any]])?.first)
            let settings = try require(inbound["settings"] as? [String: Any])
            let router = try require(root["router"] as? [String: Any])
            let rules = try require(router["rules"] as? [[String: Any]])
            let dns = try require(root["dns"] as? [String: Any])
            let dnsServers = try require(dns["servers"] as? [String])

            switch mode {
            case .proxy:
                precondition(firstTag == "proxy")
                precondition(settings["fakeDnsInclude"] == nil)
                precondition(settings["fakeDnsExclude"] == nil)
                precondition(dnsServers.first == "1.1.1.1")
            case .direct:
                precondition(firstTag == "direct")
                precondition(rules.isEmpty)
            case .smart:
                precondition(firstTag == "proxy")
                precondition((settings["fakeDnsExclude"] as? [String])?.contains("localhost") == true)
                precondition(dnsServers.first == "223.5.5.5")
                precondition(rules.contains { $0["target"] as? String == "direct" })
            case .configuration:
                precondition(firstTag == "proxy")
                precondition(rules.contains { $0["target"] as? String == "proxy" })
                precondition(rules.contains { $0["target"] as? String == "direct" })
            case .scenario:
                precondition(firstTag == "direct")
                precondition(rules.contains { $0["target"] as? String == "proxy" })
            }
        }

        print("AuraTunnel routing configuration smoke test passed")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw SmokeError.missingValue }
        return value
    }

    private enum SmokeError: Error {
        case missingValue
    }
}
