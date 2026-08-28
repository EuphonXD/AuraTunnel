import Foundation

/// Run manually with:
/// swiftc Shared/SharedConfiguration.swift \
///   iOS-VPN-Client/Manager/NodeImportParser.swift \
///   Documentation/ImportParserSmoke.swift -o /tmp/auratunnel-import-smoke
@main
enum ImportParserSmoke {
    static func main() throws {
        let vmessObject: [String: Any] = [
            "v": "2",
            "ps": "Import Smoke",
            "add": "example.com",
            "port": "443",
            "id": "db4df817-72cc-4a14-9ee8-a4448ca0e13f",
            "aid": "0",
            "net": "ws",
            "tls": "tls",
        ]
        let json = try JSONSerialization.data(withJSONObject: vmessObject)
        let vmessURI = "vmess://\(json.base64EncodedString())"

        guard case .node(let node) = try NodeImportParser.parse(vmessURI) else {
            fatalError("Expected VMess node")
        }
        precondition(node.profile.name == "Import Smoke")
        precondition(node.profile.serverHost == "example.com")
        precondition(node.profile.serverPort == 443)
        precondition(node.profile.proxyProtocol == .vmess)

        let subscriptionURL = "https://example.com/subscription?format=shadowrocket"
        let encodedURL = Data(subscriptionURL.utf8).base64EncodedString()
        guard case .subscription(let subscription) = try NodeImportParser.parse(
            "sub://\(encodedURL)#Smoke%20Subscription"
        ) else {
            fatalError("Expected subscription")
        }
        precondition(subscription.name == "Smoke Subscription")
        precondition(subscription.url.absoluteString == subscriptionURL)

        let clipboardText = "朋友分享的订阅：\nsub://\(encodedURL)#Smoke%20Subscription\n复制完成。"
        guard case .subscription(let extracted) = try NodeImportParser.parse(clipboardText) else {
            fatalError("Expected subscription extracted from surrounding clipboard text")
        }
        precondition(extracted.url.absoluteString == subscriptionURL)
        precondition(extracted.id == subscription.id)

        guard case .node(let repeatedNode) = try NodeImportParser.parse("  \(vmessURI)  ") else {
            fatalError("Expected repeated VMess node")
        }
        precondition(repeatedNode.id == node.id)

        let encodedBody = Data("\(vmessURI)\n".utf8).base64EncodedString()
        let decodedBody = NodeImportParser.decodeSubscriptionBody(Data(encodedBody.utf8))
        precondition(decodedBody == vmessURI)

        print("AuraTunnel import parser smoke test passed")
    }
}
