import Foundation

/// Converts the original imported URI into Leaf's in-memory JSON format.
/// Secrets are read once during tunnel startup and never enter App Group defaults.
enum LeafConfigurationBuilder {
    static func makeConfiguration(for profile: TunnelProfile) throws -> String {
        let protectedPayload = try SharedKeychain.load(reference: profile.credentialReference)
        guard let rawURI = String(data: protectedPayload, encoding: .utf8) else {
            throw LeafConfigurationError.invalidCredential
        }
        let tunnelConfiguration = SharedStore.loadTunnelConfiguration()
        return try makeConfiguration(
            for: profile,
            rawURI: rawURI,
            routeMode: SharedStore.loadRouteMode(),
            routingRules: tunnelConfiguration.routingRules,
            general: tunnelConfiguration.general,
            hostOverrides: tunnelConfiguration.hosts
        )
    }

    /// Internal test seam that avoids Keychain I/O. The runtime path above is
    /// still the only production entry point used by PacketTunnelProvider.
    static func makeConfiguration(
        for profile: TunnelProfile,
        rawURI: String,
        routeMode: AuraRouteMode = .proxy,
        routingRules: RoutingRuleConfiguration = .builtIn,
        general: TunnelGeneralConfiguration = .builtIn,
        hostOverrides: [HostOverride] = TunnelConfigurationProfile.builtIn.hosts
    ) throws -> String {
        guard ForwardingCapability.supports(profile.proxyProtocol) else {
            throw LeafConfigurationError.unsupportedProtocol(profile.proxyProtocol)
        }

        let outbounds: [[String: Any]]
        switch profile.proxyProtocol {
        case .vmess:
            outbounds = try makeVMessOutbounds(rawURI, profile: profile)
        case .vless:
            outbounds = try makeVLESSOutbounds(rawURI, profile: profile)
        case .trojan:
            outbounds = try makeTrojanOutbounds(rawURI, profile: profile)
        case .shadowsocks:
            outbounds = try makeShadowsocksOutbounds(rawURI, profile: profile)
        case .socks5:
            outbounds = try makeSOCKSOutbounds(rawURI, profile: profile)
        case .hysteria2:
            throw LeafConfigurationError.unsupportedProtocol(.hysteria2)
        }

        let routingPlan = makeRoutingPlan(
            mode: routeMode,
            configuration: routingRules.normalized(),
            general: general.normalized()
        )
        let directOutbound: [String: Any] = ["protocol": "direct", "tag": "direct"]
        let dropOutbound: [String: Any] = ["protocol": "drop", "tag": "drop"]
        let allOutbounds: [[String: Any]]
        if routingPlan.defaultTarget == "direct" {
            allOutbounds = [directOutbound] + outbounds + [dropOutbound]
        } else {
            allOutbounds = outbounds + [directOutbound, dropOutbound]
        }

        var tunSettings: [String: Any] = [
            // -2 selects AuraTunnel's public NEPacketTunnelFlow bridge.
            // It never extracts Apple's private TUN file descriptor.
            "fd": -2,
            "tun2socks": "lwip",
        ]
        if routingPlan.usesFakeDNS {
            // Fake DNS retains the original domain for TCP and UDP routing and
            // prevents a poisoned/slow mainland DNS answer from bypassing rules.
            // Exclude local/Apple bootstrap names so captive portals and iCloud
            // continue receiving real addresses even while smart rules are used.
            tunSettings["fakeDnsExclude"] = routingPlan.fakeDNSExclusions
        }

        var hostMap: [String: [String]] = [:]
        for entry in hostOverrides where entry.isEnabled {
            let host = entry.hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let address = entry.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, !address.isEmpty else { continue }
            hostMap[host, default: []].append(address)
        }
        var dnsObject: [String: Any] = ["servers": routingPlan.dnsServers]
        if !hostMap.isEmpty { dnsObject["hosts"] = hostMap }

        let object: [String: Any] = [
            // Extension logs are intentionally disabled. Never log imported URI
            // contents or raw packets from the forwarding process.
            "log": ["level": "none"],
            "dns": dnsObject,
            "inbounds": [[
                "protocol": "tun",
                "tag": "packet-flow",
                "settings": tunSettings,
            ]],
            // Leaf uses the first outbound as the default when no rule matches;
            // the ordering above is therefore part of the routing policy.
            "outbounds": allOutbounds,
            "router": [
                "domainResolve": false,
                "rules": routingPlan.rules,
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let value = String(data: data, encoding: .utf8) else {
            throw LeafConfigurationError.invalidGeneratedConfiguration
        }
        return value
    }

    private struct RoutingPlan {
        let defaultTarget: String
        let usesFakeDNS: Bool
        let fakeDNSExclusions: [String]
        let dnsServers: [String]
        let rules: [[String: Any]]
    }

    private static func makeRoutingPlan(
        mode: AuraRouteMode,
        configuration: RoutingRuleConfiguration,
        general: TunnelGeneralConfiguration
    ) -> RoutingPlan {
        let privateNetworks = [
            "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
            "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
            "224.0.0.0/4", "240.0.0.0/4", "::1/128", "fc00::/7", "fe80::/10",
        ]
        let privateRule: [String: Any] = ["ip": privateNetworks, "target": "direct"]
        let directDomainRule: [String: Any] = [
            "domainSuffix": configuration.directDomainSuffixes,
            "target": "direct",
        ]
        let proxyDomainRule: [String: Any] = [
            "domainSuffix": configuration.proxyDomainSuffixes,
            "target": "proxy",
        ]

        switch mode {
        case .proxy:
            return RoutingPlan(
                defaultTarget: "proxy",
                // Build 5's real-DNS global route is the known-stable baseline.
                // Fake DNS remains available for modes that need domain rules.
                usesFakeDNS: false,
                fakeDNSExclusions: [],
                dnsServers: general.fallbackDNSServers,
                rules: [privateRule]
            )
        case .direct:
            return RoutingPlan(
                defaultTarget: "direct",
                usesFakeDNS: false,
                fakeDNSExclusions: [],
                dnsServers: general.dnsServers,
                rules: []
            )
        case .smart:
            return RoutingPlan(
                defaultTarget: "proxy",
                usesFakeDNS: true,
                fakeDNSExclusions: general.alwaysRealIPDomains,
                // Only direct destinations need local resolution. Proxied
                // domains stay as domains and are resolved by the proxy side.
                dnsServers: general.dnsServers,
                rules: [privateRule, directDomainRule]
            )
        case .configuration:
            return RoutingPlan(
                defaultTarget: "proxy",
                usesFakeDNS: true,
                fakeDNSExclusions: general.alwaysRealIPDomains,
                dnsServers: general.dnsServers,
                rules: [privateRule, proxyDomainRule, directDomainRule]
            )
        case .scenario:
            return RoutingPlan(
                defaultTarget: "direct",
                usesFakeDNS: true,
                fakeDNSExclusions: general.alwaysRealIPDomains,
                dnsServers: general.dnsServers,
                rules: [privateRule, proxyDomainRule]
            )
        }
    }

    private static func makeVMessOutbounds(
        _ rawURI: String,
        profile: TunnelProfile
    ) throws -> [[String: Any]] {
        guard rawURI.lowercased().hasPrefix("vmess://"),
              let jsonData = decodeBase64(String(rawURI.dropFirst("vmess://".count))),
              let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            throw LeafConfigurationError.invalidURI("VMess Base64 JSON 无效")
        }

        let host = try requiredString(object["add"], field: "add")
        let port = try requiredPort(object["port"])
        let uuid = try requiredString(object["id"], field: "id")
        guard UUID(uuidString: uuid) != nil else {
            throw LeafConfigurationError.invalidURI("VMess UUID 无效")
        }
        let alterID = integer(object["aid"]) ?? 0
        guard alterID >= 0 else {
            throw LeafConfigurationError.invalidURI("VMess alterId 无效")
        }
        try verifyEndpoint(host: host, port: port, profile: profile)

        let requestedSecurity = string(object["scy"])?.lowercased() ?? "auto"
        let security: String
        switch requestedSecurity {
        case "auto", "", "aes-128-gcm":
            // ARM devices accelerate AES-GCM; this is the lowest-CPU default.
            security = "aes-128-gcm"
        case "chacha20-poly1305", "chacha20-ietf-poly1305":
            security = requestedSecurity
        default:
            throw LeafConfigurationError.invalidURI("不支持 VMess 加密方式：\(requestedSecurity)")
        }

        let network = (string(object["net"]) ?? "tcp").lowercased()
        guard network == "tcp" || network == "ws" || network == "websocket" else {
            throw LeafConfigurationError.unsupportedTransport(network)
        }
        let tlsEnabled = ["tls", "true", "1"].contains(
            (string(object["tls"]) ?? "").lowercased()
        )
        let core: [String: Any] = [
            "protocol": "vmess",
            "tag": "proxy-core",
            "settings": [
                "address": host,
                "port": port,
                "uuid": uuid,
                // Non-zero alterId selects Leaf's already implemented legacy
                // VMess header mode; body encryption remains the requested AEAD.
                "security": alterID == 0 ? security : "legacy-\(security)",
            ],
        ]
        return makeTransportChain(
            core: core,
            tlsEnabled: tlsEnabled,
            serverName: firstNonEmpty(string(object["sni"]), string(object["host"]), host),
            insecure: boolean(object["allowInsecure"]) ?? false,
            alpn: csvValues(object["alpn"]),
            webSocket: network == "ws" || network == "websocket",
            webSocketPath: string(object["path"]),
            webSocketHost: string(object["host"])
        )
    }

    private static func makeVLESSOutbounds(
        _ rawURI: String,
        profile: TunnelProfile
    ) throws -> [[String: Any]] {
        let components = try standardComponents(rawURI, schemes: ["vless"])
        guard let uuid = components.user, UUID(uuidString: uuid) != nil else {
            throw LeafConfigurationError.invalidURI("VLESS UUID 无效")
        }
        if let flow = query("flow", in: components), !flow.isEmpty {
            throw LeafConfigurationError.invalidURI("当前 Leaf 构建暂不支持 VLESS flow=\(flow)")
        }
        let host = try requiredHost(components)
        let port = try requiredPort(components.port)
        try verifyEndpoint(host: host, port: port, profile: profile)
        let network = (query("type", in: components) ?? "tcp").lowercased()
        guard network == "tcp" || network == "ws" || network == "websocket" else {
            throw LeafConfigurationError.unsupportedTransport(network)
        }
        let security = (query("security", in: components) ?? "none").lowercased()
        guard security == "none" || security == "tls" else {
            throw LeafConfigurationError.invalidURI("当前 Leaf 构建不支持 VLESS security=\(security)")
        }
        let core: [String: Any] = [
            "protocol": "vless",
            "tag": "proxy-core",
            "settings": ["address": host, "port": port, "uuid": uuid],
        ]
        return makeTransportChain(
            core: core,
            tlsEnabled: security == "tls",
            serverName: firstNonEmpty(query("sni", in: components), query("host", in: components), host),
            insecure: queryBool("allowInsecure", in: components) ?? false,
            alpn: csvValues(query("alpn", in: components)),
            webSocket: network == "ws" || network == "websocket",
            webSocketPath: query("path", in: components),
            webSocketHost: query("host", in: components)
        )
    }

    private static func makeTrojanOutbounds(
        _ rawURI: String,
        profile: TunnelProfile
    ) throws -> [[String: Any]] {
        let components = try standardComponents(rawURI, schemes: ["trojan"])
        guard let password = components.user?.removingPercentEncoding, !password.isEmpty else {
            throw LeafConfigurationError.invalidURI("Trojan 密码为空")
        }
        let host = try requiredHost(components)
        let port = try requiredPort(components.port)
        try verifyEndpoint(host: host, port: port, profile: profile)
        let network = (query("type", in: components) ?? "tcp").lowercased()
        guard network == "tcp" || network == "ws" || network == "websocket" else {
            throw LeafConfigurationError.unsupportedTransport(network)
        }
        let core: [String: Any] = [
            "protocol": "trojan",
            "tag": "proxy-core",
            "settings": ["address": host, "port": port, "password": password],
        ]
        return makeTransportChain(
            core: core,
            tlsEnabled: true,
            serverName: firstNonEmpty(query("sni", in: components), query("host", in: components), host),
            insecure: queryBool("allowInsecure", in: components) ?? false,
            alpn: csvValues(query("alpn", in: components)),
            webSocket: network == "ws" || network == "websocket",
            webSocketPath: query("path", in: components),
            webSocketHost: query("host", in: components)
        )
    }

    private static func makeShadowsocksOutbounds(
        _ rawURI: String,
        profile: TunnelProfile
    ) throws -> [[String: Any]] {
        guard rawURI.lowercased().hasPrefix("ss://") else {
            throw LeafConfigurationError.invalidURI("Shadowsocks 链接无效")
        }
        let withoutFragment = String(rawURI.split(separator: "#", maxSplits: 1)[0])
        let components: URLComponents
        if let parsed = URLComponents(string: withoutFragment), parsed.host != nil {
            components = parsed
        } else {
            let encoded = String(withoutFragment.dropFirst("ss://".count))
                .split(separator: "?", maxSplits: 1)
                .first
                .map(String.init) ?? ""
            guard let decoded = decodeBase64(encoded),
                  let value = String(data: decoded, encoding: .utf8),
                  let parsed = URLComponents(string: "ss://\(value)"),
                  parsed.host != nil else {
                throw LeafConfigurationError.invalidURI("Shadowsocks 旧版 Base64 链接无效")
            }
            components = parsed
        }
        let host = try requiredHost(components)
        let port = try requiredPort(components.port)
        try verifyEndpoint(host: host, port: port, profile: profile)

        let decodedUserInfo: String
        if let user = components.user,
           let decoded = decodeBase64(user),
           let value = String(data: decoded, encoding: .utf8) {
            decodedUserInfo = value
        } else if let user = components.user, let password = components.password {
            decodedUserInfo = "\(user):\(password)"
        } else {
            throw LeafConfigurationError.invalidURI("Shadowsocks 认证信息无效")
        }
        guard let separator = decodedUserInfo.firstIndex(of: ":") else {
            throw LeafConfigurationError.invalidURI("Shadowsocks 缺少加密方式或密码")
        }
        let method = String(decodedUserInfo[..<separator])
        let password = String(decodedUserInfo[decodedUserInfo.index(after: separator)...])
        guard !method.isEmpty, !password.isEmpty else {
            throw LeafConfigurationError.invalidURI("Shadowsocks 缺少加密方式或密码")
        }
        return [[
            "protocol": "shadowsocks",
            "tag": "proxy",
            "settings": ["address": host, "port": port, "method": method, "password": password],
        ]]
    }

    private static func makeSOCKSOutbounds(
        _ rawURI: String,
        profile: TunnelProfile
    ) throws -> [[String: Any]] {
        let components = try standardComponents(rawURI, schemes: ["socks", "socks5"])
        let host = try requiredHost(components)
        let port = try requiredPort(components.port ?? 1_080)
        try verifyEndpoint(host: host, port: port, profile: profile)
        var settings: [String: Any] = ["address": host, "port": port]
        if let username = components.user?.removingPercentEncoding, !username.isEmpty {
            settings["username"] = username
        }
        if let password = components.password?.removingPercentEncoding, !password.isEmpty {
            settings["password"] = password
        }
        return [["protocol": "socks", "tag": "proxy", "settings": settings]]
    }

    private static func makeTransportChain(
        core: [String: Any],
        tlsEnabled: Bool,
        serverName: String,
        insecure: Bool,
        alpn: [String]?,
        webSocket: Bool,
        webSocketPath: String?,
        webSocketHost: String?
    ) -> [[String: Any]] {
        guard tlsEnabled || webSocket else {
            var directCore = core
            directCore["tag"] = "proxy"
            return [directCore]
        }

        var actors: [String] = []
        var components: [[String: Any]] = []
        if tlsEnabled {
            actors.append("proxy-tls")
            var tlsSettings: [String: Any] = [
                "serverName": serverName,
                "insecure": insecure,
            ]
            if let alpn, !alpn.isEmpty { tlsSettings["alpn"] = alpn }
            components.append([
                "protocol": "tls", "tag": "proxy-tls", "settings": tlsSettings,
            ])
        }
        if webSocket {
            actors.append("proxy-ws")
            var headers: [String: String] = [:]
            if let webSocketHost, !webSocketHost.isEmpty { headers["Host"] = webSocketHost }
            var settings: [String: Any] = ["path": normalizedPath(webSocketPath)]
            if !headers.isEmpty { settings["headers"] = headers }
            components.append([
                "protocol": "websocket", "tag": "proxy-ws", "settings": settings,
            ])
        }
        actors.append("proxy-core")
        return [[
            "protocol": "chain",
            "tag": "proxy",
            "settings": ["actors": actors],
        ]] + components + [core]
    }

    private static func standardComponents(
        _ rawURI: String,
        schemes: Set<String>
    ) throws -> URLComponents {
        guard let components = URLComponents(string: rawURI),
              let scheme = components.scheme?.lowercased(),
              schemes.contains(scheme) else {
            throw LeafConfigurationError.invalidURI("节点链接格式无效")
        }
        return components
    }

    private static func requiredHost(_ components: URLComponents) throws -> String {
        guard let host = components.host, !host.isEmpty else {
            throw LeafConfigurationError.invalidURI("节点缺少服务器地址")
        }
        return host
    }

    private static func requiredPort(_ value: Any?) throws -> Int {
        guard let port = integer(value), (1...65_535).contains(port) else {
            throw LeafConfigurationError.invalidURI("节点端口无效")
        }
        return port
    }

    private static func requiredString(_ value: Any?, field: String) throws -> String {
        guard let value = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw LeafConfigurationError.invalidURI("节点缺少 \(field)")
        }
        return value
    }

    private static func verifyEndpoint(host: String, port: Int, profile: TunnelProfile) throws {
        guard host.caseInsensitiveCompare(profile.serverHost) == .orderedSame,
              port == Int(profile.serverPort) else {
            throw LeafConfigurationError.invalidURI("节点摘要与安全存储中的原始链接不一致")
        }
    }

    private static func query(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func queryBool(_ name: String, in components: URLComponents) -> Bool? {
        guard let value = query(name, in: components)?.lowercased() else { return nil }
        return ["1", "true", "yes"].contains(value)
    }

    private static func normalizedPath(_ value: String?) -> String {
        guard let value = value?.removingPercentEncoding, !value.isEmpty else { return "/" }
        return value.hasPrefix("/") ? value : "/\(value)"
    }

    private static func csvValues(_ value: Any?) -> [String]? {
        guard let raw = string(value) else { return nil }
        let values = raw.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return nil
    }

    private static func decodeBase64(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if let fragment = normalized.firstIndex(of: "#") {
            normalized = String(normalized[..<fragment])
        }
        let remainder = normalized.utf8.count % 4
        if remainder != 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters])
    }
}

enum LeafConfigurationError: LocalizedError {
    case invalidCredential
    case invalidGeneratedConfiguration
    case invalidURI(String)
    case unsupportedProtocol(ProxyProtocolKind)
    case unsupportedTransport(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            "无法从共享 Keychain 读取节点原始配置。"
        case .invalidGeneratedConfiguration:
            "无法生成 Leaf 运行配置。"
        case .invalidURI(let message):
            message
        case .unsupportedProtocol(let kind):
            "当前转发核心暂不支持 \(kind.displayName) 节点。"
        case .unsupportedTransport(let transport):
            "当前 Leaf 构建暂不支持传输层：\(transport)。"
        }
    }
}
