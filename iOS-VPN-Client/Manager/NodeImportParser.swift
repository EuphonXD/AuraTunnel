import CryptoKit
import Foundation

struct ImportedNodeCandidate: Identifiable, Sendable {
    let id: UUID
    let profile: TunnelProfile
    let protectedPayload: Data
}

struct ImportedSubscriptionCandidate: Identifiable, Sendable {
    let id: UUID
    let name: String
    let url: URL
    let sourceHost: String
    let credentialReference: String
    let protectedPayload: Data

    func storedProfile(nodes: [ImportedNodeCandidate]) -> SubscriptionProfile {
        SubscriptionProfile(
            id: id,
            name: name,
            sourceHost: sourceHost,
            credentialReference: credentialReference,
            lastUpdatedAt: .now,
            nodeCount: nodes.count,
            nodeIDs: nodes.map(\.id)
        )
    }
}

enum ImportedConfigurationCandidate: Identifiable, Sendable {
    case node(ImportedNodeCandidate)
    case subscription(ImportedSubscriptionCandidate)

    var id: UUID {
        switch self {
        case .node(let candidate): candidate.id
        case .subscription(let candidate): candidate.id
        }
    }

    var confirmationMessage: String {
        switch self {
        case .node(let candidate):
            "\(candidate.profile.proxyProtocol.displayName)\n" +
            "\(candidate.profile.serverHost):\(candidate.profile.serverPort)\n\n" +
            "认证信息将安全保存到共享 Keychain。"
        case .subscription(let candidate):
            "订阅：\(candidate.name)\n" +
            "来源：\(candidate.sourceHost)\n\n" +
            "确认后将下载订阅并批量导入其中支持的节点。"
        }
    }
}

enum NodeImportParser {
    private static let maximumPayloadBytes = 16 * 1_024
    private static let maximumUntrustedTextBytes = 256 * 1_024
    private static let supportedSchemePattern =
        #"(?i)(?:sub|ss|socks|socks5|vmess|vless|trojan|hysteria2|hy2)://[^\s<>\"']+"#

    static func parse(_ untrustedPayload: String) throws -> ImportedConfigurationCandidate {
        let untrustedText = untrustedPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !untrustedText.isEmpty else {
            throw NodeImportError.emptyPayload
        }
        guard untrustedText.utf8.count <= maximumUntrustedTextBytes else {
            throw NodeImportError.payloadTooLarge
        }

        // Clipboard content often includes a label or surrounding chat text.
        // Extract exactly one supported URI without scanning arbitrary URLs.
        let payload = extractSupportedPayload(from: untrustedText) ?? untrustedText
        guard payload.utf8.count <= maximumPayloadBytes else {
            throw NodeImportError.payloadTooLarge
        }

        let scheme = payload.prefix { $0 != ":" }.lowercased()
        if scheme == "sub" {
            return .subscription(try parseSubscription(payload))
        }

        let parsed: ParsedEndpoint
        switch scheme {
        case "ss":
            parsed = try parseShadowsocks(payload)
        case "socks", "socks5":
            parsed = try parseStandardURL(payload, kind: .socks5, defaultPort: 1_080)
        case "vmess":
            parsed = try parseVMess(payload)
        case "vless":
            parsed = try parseStandardURL(payload, kind: .vless, defaultPort: 443)
        case "trojan":
            parsed = try parseStandardURL(payload, kind: .trojan, defaultPort: 443)
        case "hysteria2", "hy2":
            parsed = try parseStandardURL(payload, kind: .hysteria2, defaultPort: 443)
        default:
            throw NodeImportError.unsupportedScheme(scheme)
        }

        guard let protectedPayload = payload.data(using: .utf8) else {
            throw NodeImportError.invalidEncoding
        }
        let id = deterministicID(for: protectedPayload)
        let credentialReference = "node.\(id.uuidString.lowercased())"
        let profile = TunnelProfile(
            id: id,
            name: parsed.name,
            serverHost: parsed.host,
            serverPort: parsed.port,
            transport: parsed.transport,
            proxyProtocol: parsed.kind,
            credentialReference: credentialReference
        )

        return .node(
            ImportedNodeCandidate(id: id, profile: profile, protectedPayload: protectedPayload)
        )
    }

    private static func extractSupportedPayload(from text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: supportedSchemePattern) else {
            return nil
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: fullRange),
              let range = Range(match.range, in: text) else {
            return nil
        }

        let trailingPunctuation = CharacterSet(charactersIn: ".,;!?，。；！？)]}》」』")
        return String(text[range]).trimmingCharacters(in: trailingPunctuation)
    }

    static func parseExternalURL(_ url: URL) throws -> ImportedConfigurationCandidate {
        guard url.scheme?.lowercased() == SharedConfiguration.urlScheme else {
            throw NodeImportError.invalidExternalURL
        }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.host?.lowercased() == "import" || components.path == "/import",
            let payload = components.queryItems?.first(where: {
                $0.name == "url" || $0.name == "node"
            })?.value
        else {
            throw NodeImportError.invalidExternalURL
        }
        return try parse(payload)
    }

    private static func parseSubscription(_ payload: String) throws -> ImportedSubscriptionCandidate {
        var body = String(payload.dropFirst("sub://".count))
        let fragment = body.split(separator: "#", maxSplits: 1).dropFirst().first.map(String.init)
        body = String(body.split(separator: "#", maxSplits: 1)[0])

        let decodedText: String
        if let percentDecoded = body.removingPercentEncoding,
           percentDecoded.lowercased().hasPrefix("https://") {
            decodedText = percentDecoded
        } else if
            let decodedData = decodeBase64(body),
            let value = String(data: decodedData, encoding: .utf8)
        {
            decodedText = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            throw NodeImportError.invalidSubscription("订阅地址的 Base64 内容无效")
        }

        guard
            let url = URL(string: decodedText),
            url.scheme?.lowercased() == "https",
            let host = url.host,
            !host.isEmpty,
            url.user == nil,
            url.password == nil
        else {
            throw NodeImportError.invalidSubscription("订阅必须是无内嵌账号的 HTTPS 地址")
        }

        guard let protectedPayload = decodedText.data(using: .utf8) else {
            throw NodeImportError.invalidEncoding
        }
        let id = deterministicID(for: protectedPayload)
        return ImportedSubscriptionCandidate(
            id: id,
            name: displayName(fragment, fallback: host),
            url: url,
            sourceHost: host,
            credentialReference: "subscription.\(id.uuidString.lowercased())",
            protectedPayload: protectedPayload
        )
    }

    private static func parseStandardURL(
        _ payload: String,
        kind: ProxyProtocolKind,
        defaultPort: Int
    ) throws -> ParsedEndpoint {
        guard
            let components = URLComponents(string: payload),
            let host = components.host,
            !host.isEmpty
        else {
            throw NodeImportError.invalidNode("无法读取服务器地址")
        }

        let port = try validatedPort(components.port ?? defaultPort)
        let transport: TunnelTransport
        if kind == .hysteria2 {
            transport = .udp
        } else {
            let network = components.queryItems?.first(where: {
                $0.name.lowercased() == "type" || $0.name.lowercased() == "network"
            })?.value?.lowercased()
            transport = network == "udp" || network == "quic" ? .udp : .tcp
        }

        return ParsedEndpoint(
            name: displayName(components.fragment, fallback: "\(kind.displayName) \(host)"),
            host: try validatedHost(host),
            port: port,
            transport: transport,
            kind: kind
        )
    }

    private static func parseShadowsocks(_ payload: String) throws -> ParsedEndpoint {
        if
            let components = URLComponents(string: payload),
            let host = components.host,
            !host.isEmpty,
            components.user != nil || components.port != nil
        {
            return ParsedEndpoint(
                name: displayName(components.fragment, fallback: "Shadowsocks \(host)"),
                host: try validatedHost(host),
                port: try validatedPort(components.port ?? 8_388),
                transport: .tcp,
                kind: .shadowsocks
            )
        }

        // Legacy form: ss://BASE64(method:password@host:port)#name
        var encoded = String(payload.dropFirst("ss://".count))
        let fragment = encoded.split(separator: "#", maxSplits: 1).dropFirst().first.map(String.init)
        encoded = String(encoded.split(separator: "#", maxSplits: 1)[0])
        encoded = String(encoded.split(separator: "?", maxSplits: 1)[0])

        guard
            let decodedData = decodeBase64(encoded),
            let decoded = String(data: decodedData, encoding: .utf8),
            let components = URLComponents(string: "ss://\(decoded)"),
            let host = components.host,
            !host.isEmpty
        else {
            throw NodeImportError.invalidNode("Shadowsocks 二维码格式无效")
        }

        return ParsedEndpoint(
            name: displayName(fragment, fallback: "Shadowsocks \(host)"),
            host: try validatedHost(host),
            port: try validatedPort(components.port ?? 8_388),
            transport: .tcp,
            kind: .shadowsocks
        )
    }

    private static func parseVMess(_ payload: String) throws -> ParsedEndpoint {
        let encoded = String(payload.dropFirst("vmess://".count))
        guard
            let jsonData = decodeBase64(encoded),
            let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let host = object["add"] as? String,
            !host.isEmpty,
            let portValue = integerValue(object["port"])
        else {
            throw NodeImportError.invalidNode("VMess 二维码内容无效")
        }

        let network = (object["net"] as? String)?.lowercased()
        let transport: TunnelTransport = network == "quic" || network == "udp" ? .udp : .tcp
        return ParsedEndpoint(
            name: displayName(object["ps"] as? String, fallback: "VMess \(host)"),
            host: try validatedHost(host),
            port: try validatedPort(portValue),
            transport: transport,
            kind: .vmess
        )
    }

    private static func decodeBase64(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.utf8.count % 4
        if remainder != 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters])
    }

    static func decodeSubscriptionBody(_ data: Data) -> String? {
        guard let direct = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = direct.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return trimmed
        }
        guard
            let decoded = decodeBase64(trimmed),
            let text = String(data: decoded, encoding: .utf8)
        else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deterministicID(for data: Data) -> UUID {
        let bytes = Array(SHA256.hash(data: data).prefix(16))
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-5\(hex.dropFirst(13).prefix(3))-a\(hex.dropFirst(17).prefix(3))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: value) ?? UUID()
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func validatedPort(_ value: Int) throws -> UInt16 {
        guard value > 0, value <= Int(UInt16.max) else {
            throw NodeImportError.invalidNode("服务器端口无效")
        }
        return UInt16(value)
    }

    private static func validatedHost(_ value: String) throws -> String {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 253 else {
            throw NodeImportError.invalidNode("服务器地址无效")
        }
        return host
    }

    private static func displayName(_ value: String?, fallback: String) -> String {
        let decoded = value?.removingPercentEncoding ?? value
        let name = decoded?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String((name.isEmpty ? fallback : name).prefix(80))
    }
}

private struct ParsedEndpoint {
    let name: String
    let host: String
    let port: UInt16
    let transport: TunnelTransport
    let kind: ProxyProtocolKind
}

enum NodeImportError: LocalizedError {
    case emptyPayload
    case payloadTooLarge
    case invalidEncoding
    case unsupportedScheme(String)
    case invalidNode(String)
    case invalidSubscription(String)
    case invalidExternalURL

    var errorDescription: String? {
        switch self {
        case .emptyPayload:
            "没有读取到节点内容。"
        case .payloadTooLarge:
            "二维码内容过大，已拒绝导入。"
        case .invalidEncoding:
            "节点文本编码无效。"
        case .unsupportedScheme(let scheme):
            scheme.isEmpty ? "无法识别节点协议。" : "暂不支持 \(scheme):// 节点。"
        case .invalidNode(let message):
            message
        case .invalidSubscription(let message):
            message
        case .invalidExternalURL:
            "外部导入链接格式应为 auratunnel://import?url=节点链接。"
        }
    }
}
