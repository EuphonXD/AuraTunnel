import Foundation

/// Identifiers shared by the containing app and Packet Tunnel extension.
/// Change these three values together if the App ID changes.
enum SharedConfiguration {
    static let appGroupIdentifier = "group.com.shaolihuang.auratunnel"
    static let providerBundleIdentifier = "com.shaolihuang.auratunnel.PacketTunnel"
    static let tunnelDescription = "AuraTunnel"
    static let urlScheme = "auratunnel"
    static let keychainAccessGroupInfoKey = "AuraTunnelKeychainAccessGroup"
}

enum TunnelTransport: String, Codable, Sendable, CaseIterable {
    case tcp
    case udp
}

enum ProxyProtocolKind: String, Codable, Sendable, CaseIterable {
    case shadowsocks
    case socks5
    case vmess
    case vless
    case trojan
    case hysteria2

    var displayName: String {
        switch self {
        case .shadowsocks: "Shadowsocks"
        case .socks5: "SOCKS5"
        case .vmess: "VMess"
        case .vless: "VLESS"
        case .trojan: "Trojan"
        case .hysteria2: "Hysteria 2"
        }
    }
}

/// Routing policy shared by the containing app and Packet Tunnel process.
/// Raw values are stable because they are persisted in the App Group.
enum AuraRouteMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case smart
    case configuration
    case proxy
    case direct
    case scenario

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: "智能分流"
        case .configuration: "规则配置"
        case .proxy: "全局代理"
        case .direct: "全部直连"
        case .scenario: "场景模式"
        }
    }

    var detail: String {
        switch self {
        case .smart: "中国大陆常用网站直连，其他流量通过代理"
        case .configuration: "优先采用你保存的代理与直连域名规则"
        case .proxy: "所有网站和 App 流量都通过当前代理节点"
        case .direct: "所有流量绕过代理，VPN 只保留虚拟通道"
        case .scenario: "常用境外社交与流媒体走代理，其余流量直连"
        }
    }

    var symbol: String {
        switch self {
        case .smart: "point.3.connected.trianglepath.dotted"
        case .configuration: "doc.text.magnifyingglass"
        case .proxy: "shield.lefthalf.filled"
        case .direct: "arrow.right"
        case .scenario: "square.grid.2x2"
        }
    }
}

/// Small, bounded rule configuration. Domain suffixes are normalized before
/// entering Leaf so rule matching never allocates or parses text per packet.
struct RoutingRuleConfiguration: Codable, Equatable, Sendable {
    var directDomainSuffixes: [String]
    var proxyDomainSuffixes: [String]

    static let builtIn = RoutingRuleConfiguration(
        directDomainSuffixes: [
            "cn", "中国", "公司", "网络",
            "baidu.com", "baidubce.com", "bdimg.com", "bdstatic.com", "hao123.com",
            "qq.com", "qpic.cn", "gtimg.cn", "gtimg.com", "myqcloud.com",
            "weixin.qq.com", "wechat.com", "weixinbridge.com", "qcloud.com",
            "alibaba.com", "alibabacloud.com", "alicdn.com", "aliyun.com", "aliyuncs.com",
            "alipay.com", "alipayobjects.com", "taobao.com", "taobaocdn.com", "tmall.com",
            "tmall.hk", "1688.com", "cainiao.com", "uc.cn", "ucweb.com",
            "jd.com", "jdcdn.com", "360.cn", "360.com", "qhimg.com", "so.com",
            "163.com", "126.com", "netease.com", "sina.com.cn", "sinaimg.cn", "weibo.com",
            "bilibili.com", "bilivideo.com", "acgvideo.com", "iqiyi.com", "qiyi.com",
            "youku.com", "ykimg.com", "mgtv.com", "douban.com", "doubanio.com",
            "douyin.com", "douyinvod.com", "byteimg.com", "bytedance.com", "toutiao.com",
            "snssdk.com", "ixigua.com", "huoshan.com", "kuaishou.com", "gifshow.com",
            "zhihu.com", "zhimg.com", "xiaohongshu.com", "xhscdn.com", "smzdm.com",
            "meituan.com", "dianping.com", "sankuai.com", "ele.me", "elemecdn.com",
            "amap.com", "autonavi.com", "gaode.com", "baidumap.com", "mapbar.com",
            "ctrip.com", "tripcdn.com", "qunar.com", "12306.cn", "didiglobal.com",
            "didi.cn", "hellobike.com", "sf-express.com", "zto.com", "yto.net.cn",
            "mi.com", "xiaomi.com", "mi-img.com", "miui.com", "huawei.com",
            "huaweicloud.com", "honor.com", "vivo.com", "vivo.com.cn", "oppo.com",
            "oppo.cn", "realme.com", "oneplus.com", "lenovo.com.cn", "zte.com.cn",
            "pinduoduo.com", "yangkeduo.com", "suning.com", "vip.com", "dangdang.com",
            "eastmoney.com", "10jqka.com.cn", "xueqiu.com", "cmbchina.com", "icbc.com.cn",
            "ccb.com", "abchina.com", "boc.cn", "unionpay.com", "95516.com",
            "gov.cn", "xinhuanet.com", "people.com.cn", "cctv.com", "chinanews.com.cn",
            "csdn.net", "gitee.com", "juejin.cn", "segmentfault.com", "oschina.net",
            "apple.com", "apple.com.cn", "icloud.com", "icloud.com.cn", "mzstatic.com",
            "cdn-apple.com", "aaplimg.com", "akadns.net", "microsoft.com", "windowsupdate.com",
        ],
        proxyDomainSuffixes: [
            "google.com", "google.co", "googleapis.com", "googleusercontent.com", "gstatic.com",
            "googlevideo.com", "ggpht.com", "googleblog.com", "googlesyndication.com",
            "googleadservices.com", "gmail.com", "withgoogle.com", "android.com",
            "youtube.com", "youtube-nocookie.com", "youtu.be", "ytimg.com", "youtu.be",
            "facebook.com", "facebook.net", "fbcdn.net", "fb.com", "messenger.com",
            "instagram.com", "cdninstagram.com", "threads.net", "whatsapp.com", "whatsapp.net",
            "tiktok.com", "tiktokv.com", "tiktokcdn.com", "tiktokcdn-us.com", "muscdn.com",
            "byteoversea.com", "ibytedtos.com", "ibyteimg.com", "ttwstatic.com",
            "twitter.com", "x.com", "twimg.com", "periscope.tv", "t.co",
            "telegram.org", "telegram.me", "t.me", "telegra.ph", "tdesktop.com",
            "reddit.com", "redd.it", "redditmedia.com", "redditstatic.com", "tumblr.com",
            "netflix.com", "netflix.net", "nflxvideo.net", "nflximg.net", "nflxext.com",
            "disneyplus.com", "disney-plus.net", "hulu.com", "max.com", "hbomax.com",
            "primevideo.com", "amazonvideo.com", "spotify.com", "scdn.co", "deezer.com",
            "twitch.tv", "ttvnw.net", "jtvnw.net", "vimeo.com", "vimeocdn.com",
            "github.com", "githubusercontent.com", "githubassets.com", "github.io",
            "gitlab.com", "bitbucket.org", "npmjs.com", "docker.com", "docker.io",
            "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com",
            "anthropic.com", "claude.ai", "perplexity.ai", "gemini.google.com",
            "cloudflare.com", "cloudflare-dns.com", "cloudfront.net", "fastly.net",
            "discord.com", "discordapp.com", "discordapp.net", "discordcdn.com",
            "wikipedia.org", "wikimedia.org", "archive.org", "medium.com", "substack.com",
            "nytimes.com", "bbc.com", "bbc.co.uk", "cnn.com", "reuters.com", "bloomberg.com",
            "wsj.com", "economist.com", "theguardian.com", "washingtonpost.com",
            "dropbox.com", "dropboxapi.com", "notion.so", "notion.site", "slack.com",
            "line.me", "line-apps.com", "kakao.com", "naver.com", "proton.me",
            "signal.org", "torproject.org", "quora.com", "pinterest.com", "pinimg.com",
        ]
    )

    func normalized(maximumPerList: Int = 512) -> RoutingRuleConfiguration {
        RoutingRuleConfiguration(
            directDomainSuffixes: Self.normalize(directDomainSuffixes, limit: maximumPerList),
            proxyDomainSuffixes: Self.normalize(proxyDomainSuffixes, limit: maximumPerList)
        )
    }

    private static func normalize(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(min(values.count, limit))
        for value in values {
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            guard !normalized.isEmpty,
                  normalized.count <= 253,
                  normalized.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
                  }),
                  seen.insert(normalized).inserted
            else { continue }
            result.append(normalized)
            if result.count == limit { break }
        }
        return result
    }
}

/// General options persisted as the built-in `default.conf`. IPv6 deliberately
/// defaults to off because many imported proxy chains only provide a reliable
/// IPv4 egress; capturing IPv6 in that state creates a silent traffic black hole.
struct TunnelGeneralConfiguration: Codable, Equatable, Sendable {
    var ipv6Enabled: Bool
    var preferIPv6: Bool
    var privateIPAnswers: Bool
    var dnsServers: [String]
    var fallbackDNSServers: [String]
    var bypassProxyAddresses: [String]
    var tunBypassRoutes: [String]
    var alwaysRealIPDomains: [String]
    var hijackDNSEndpoints: [String]

    static let builtIn = TunnelGeneralConfiguration(
        ipv6Enabled: false,
        preferIPv6: false,
        privateIPAnswers: true,
        dnsServers: ["223.5.5.5", "119.29.29.29"],
        fallbackDNSServers: ["1.1.1.1", "8.8.8.8"],
        bypassProxyAddresses: [
            "localhost", "*.local", "captive.apple.com", "10.0.0.0/8",
            "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
            "172.16.0.0/12", "192.168.0.0/16",
        ],
        tunBypassRoutes: [
            "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
            "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
            "224.0.0.0/4", "240.0.0.0/4", "::1/128", "fc00::/7", "fe80::/10",
        ],
        alwaysRealIPDomains: [
            "localhost", "*.local", "captive.apple.com", "*.apple.com",
            "*.icloud.com", "*.icloud.com.cn",
        ],
        hijackDNSEndpoints: ["8.8.8.8:53", "1.1.1.1:53"]
    )

    func normalized() -> TunnelGeneralConfiguration {
        TunnelGeneralConfiguration(
            ipv6Enabled: ipv6Enabled,
            preferIPv6: ipv6Enabled && preferIPv6,
            privateIPAnswers: privateIPAnswers,
            dnsServers: Self.normalizedStrings(dnsServers, limit: 8, fallback: Self.builtIn.dnsServers),
            fallbackDNSServers: Self.normalizedStrings(
                fallbackDNSServers,
                limit: 8,
                fallback: Self.builtIn.fallbackDNSServers
            ),
            bypassProxyAddresses: Self.normalizedStrings(bypassProxyAddresses, limit: 64),
            tunBypassRoutes: Self.normalizedStrings(tunBypassRoutes, limit: 64),
            alwaysRealIPDomains: Self.normalizedStrings(alwaysRealIPDomains, limit: 128),
            hijackDNSEndpoints: Self.normalizedStrings(hijackDNSEndpoints, limit: 16)
        )
    }

    private static func normalizedStrings(
        _ values: [String],
        limit: Int,
        fallback: [String] = []
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(min(values.count, limit))
        for rawValue in values {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty,
                  value.count <= 253,
                  seen.insert(value).inserted else { continue }
            result.append(value)
            if result.count == limit { break }
        }
        return result.isEmpty ? fallback : result
    }
}

struct HostOverride: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var hostname: String
    var address: String
    var isEnabled: Bool = true
}

struct URLRewriteRule: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var pattern: String
    var replacement: String
    var statusCode: Int = 302
    var isEnabled: Bool = true
}

struct TunnelConfigurationProfile: Codable, Equatable, Sendable {
    var name: String
    var general: TunnelGeneralConfiguration
    var routingRules: RoutingRuleConfiguration
    var hosts: [HostOverride]
    var urlRewrites: [URLRewriteRule]

    static let builtIn = TunnelConfigurationProfile(
        name: "default.conf",
        general: .builtIn,
        routingRules: .builtIn,
        hosts: [HostOverride(hostname: "localhost", address: "127.0.0.1")],
        urlRewrites: [
            URLRewriteRule(
                pattern: #"^https?://(www\.)?g\.cn(/.*)?$"#,
                replacement: "https://www.google.com$2"
            ),
            URLRewriteRule(
                pattern: #"^https?://(www\.)?google\.cn(/.*)?$"#,
                replacement: "https://www.google.com$2"
            ),
        ]
    )

    func normalized() -> TunnelConfigurationProfile {
        let normalizedHosts = hosts.prefix(256).compactMap { entry -> HostOverride? in
            var value = entry
            value.hostname = value.hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            value.address = value.address.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.hostname.isEmpty || value.address.isEmpty ? nil : value
        }
        let normalizedRewrites = urlRewrites.prefix(128).compactMap { entry -> URLRewriteRule? in
            var value = entry
            value.pattern = value.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            value.replacement = value.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            value.statusCode = (300...399).contains(value.statusCode) ? value.statusCode : 302
            return value.pattern.isEmpty || value.replacement.isEmpty ? nil : value
        }
        return TunnelConfigurationProfile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "default.conf" : name,
            general: general.normalized(),
            routingRules: routingRules.normalized(),
            hosts: Array(normalizedHosts),
            urlRewrites: Array(normalizedRewrites)
        )
    }
}

struct TunnelProfile: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var serverHost: String
    var serverPort: UInt16
    var transport: TunnelTransport
    var proxyProtocol: ProxyProtocolKind
    var credentialReference: String
    /// Optional keeps profiles written by earlier builds decodable.
    var isHidden: Bool?

    init(
        id: UUID = UUID(),
        name: String,
        serverHost: String,
        serverPort: UInt16,
        transport: TunnelTransport,
        proxyProtocol: ProxyProtocolKind = .socks5,
        credentialReference: String = "",
        isHidden: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.transport = transport
        self.proxyProtocol = proxyProtocol
        self.credentialReference = credentialReference
        self.isHidden = isHidden
    }

    var providerConfiguration: [String: Any] {
        [
            "profileID": id.uuidString,
            "serverHost": serverHost,
            "serverPort": Int(serverPort),
            "transport": transport.rawValue,
            "proxyProtocol": proxyProtocol.rawValue,
            "credentialReference": credentialReference,
        ]
    }
}

struct SubscriptionProfile: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var sourceHost: String
    var credentialReference: String
    var lastUpdatedAt: Date
    var nodeCount: Int
    /// Optional for backward compatibility with subscriptions stored by earlier builds.
    var nodeIDs: [UUID]?
    /// Local presentation preference. The subscription and its nodes remain stored.
    var isHidden: Bool? = nil
}

enum ForwardingCapability {
    /// Leaf is integrated through the public PacketFlow API. Hysteria 2 is not
    /// part of the deliberately small iOS feature set.
    static let isImplemented = true
    static let supportedProtocols: Set<ProxyProtocolKind> = [
        .vmess, .vless, .trojan, .shadowsocks, .socks5,
    ]

    static func supports(_ kind: ProxyProtocolKind) -> Bool {
        isImplemented && supportedProtocols.contains(kind)
    }
}

enum TunnelRuntimeState: String, Codable, Sendable {
    case inactive
    case preparing
    case connected
    case stopping
    case failed
}

struct TunnelRuntimeSnapshot: Codable, Equatable, Sendable {
    var state: TunnelRuntimeState
    var updatedAt: Date
    var packetCount: UInt64
    var byteCount: UInt64
    var message: String?
    /// Correlates a main-app start request with exactly one provider lifecycle.
    /// Optional fields keep snapshots from older installed builds decodable.
    var attemptID: UUID? = nil
    var appBuild: String? = nil
    var extensionBuild: String? = nil

    static let inactive = TunnelRuntimeSnapshot(
        state: .inactive,
        updatedAt: .now,
        packetCount: 0,
        byteCount: 0,
        message: nil
    )
}

enum TunnelIPCCommand: String, Codable, Sendable {
    case runtimeSnapshot
}

/// Low-frequency App Group persistence. This is deliberately not used per packet.
enum SharedStore {
    private static let selectedProfileKey = "selectedTunnelProfile.v1"
    private static let profilesKey = "tunnelProfiles.v1"
    private static let subscriptionsKey = "subscriptionProfiles.v1"
    private static let routeModeKey = "routeMode.v1"
    private static let routingRulesKey = "routingRules.v1"
    private static let tunnelConfigurationKey = "tunnelConfiguration.v1"
    // v2 intentionally drops stale pre-Leaf failure receipts from early builds.
    private static let runtimeSnapshotKey = "runtimeSnapshot.v2"

    static func saveSelectedProfile(_ profile: TunnelProfile) throws {
        let data = try JSONEncoder().encode(profile)
        try defaults().set(data, forKey: selectedProfileKey)
    }

    static func removeSelectedProfile() throws {
        try defaults().removeObject(forKey: selectedProfileKey)
    }

    static func saveProfiles(_ profiles: [TunnelProfile]) throws {
        let data = try JSONEncoder().encode(profiles)
        try defaults().set(data, forKey: profilesKey)
    }

    static func loadProfiles() -> [TunnelProfile] {
        guard
            let data = defaultsIfAvailable()?.data(forKey: profilesKey),
            let profiles = try? JSONDecoder().decode([TunnelProfile].self, from: data)
        else {
            return []
        }
        return profiles
    }

    static func saveSubscriptions(_ subscriptions: [SubscriptionProfile]) throws {
        let data = try JSONEncoder().encode(subscriptions)
        try defaults().set(data, forKey: subscriptionsKey)
    }

    static func loadSubscriptions() -> [SubscriptionProfile] {
        guard
            let data = defaultsIfAvailable()?.data(forKey: subscriptionsKey),
            let subscriptions = try? JSONDecoder().decode([SubscriptionProfile].self, from: data)
        else {
            return []
        }
        return subscriptions
    }

    static func loadSelectedProfile() -> TunnelProfile? {
        guard
            let data = defaultsIfAvailable()?.data(forKey: selectedProfileKey),
            let profile = try? JSONDecoder().decode(TunnelProfile.self, from: data)
        else {
            return nil
        }
        return profile
    }

    static func saveRouteMode(_ mode: AuraRouteMode) {
        defaultsIfAvailable()?.set(mode.rawValue, forKey: routeModeKey)
    }

    static func loadRouteMode() -> AuraRouteMode {
        guard let value = defaultsIfAvailable()?.string(forKey: routeModeKey) else {
            return .smart
        }
        return AuraRouteMode(rawValue: value) ?? .smart
    }

    static func saveRoutingRules(_ configuration: RoutingRuleConfiguration) throws {
        let normalized = configuration.normalized()
        let data = try JSONEncoder().encode(normalized)
        try defaults().set(data, forKey: routingRulesKey)
        var profile = loadTunnelConfiguration()
        profile.routingRules = normalized
        let profileData = try JSONEncoder().encode(profile.normalized())
        try defaults().set(profileData, forKey: tunnelConfigurationKey)
    }

    static func loadRoutingRules() -> RoutingRuleConfiguration {
        guard let data = defaultsIfAvailable()?.data(forKey: routingRulesKey),
              let configuration = try? JSONDecoder().decode(RoutingRuleConfiguration.self, from: data)
        else {
            return .builtIn
        }
        return configuration.normalized()
    }

    static func saveTunnelConfiguration(_ configuration: TunnelConfigurationProfile) throws {
        let normalized = configuration.normalized()
        let data = try JSONEncoder().encode(normalized)
        let rulesData = try JSONEncoder().encode(normalized.routingRules)
        let storage = try defaults()
        storage.set(data, forKey: tunnelConfigurationKey)
        storage.set(rulesData, forKey: routingRulesKey)
    }

    static func loadTunnelConfiguration() -> TunnelConfigurationProfile {
        guard let data = defaultsIfAvailable()?.data(forKey: tunnelConfigurationKey),
              let configuration = try? JSONDecoder().decode(TunnelConfigurationProfile.self, from: data)
        else {
            var builtIn = TunnelConfigurationProfile.builtIn
            builtIn.routingRules = loadRoutingRules()
            return builtIn
        }
        return configuration.normalized()
    }

    static func saveRuntimeSnapshot(_ snapshot: TunnelRuntimeSnapshot) {
        guard
            let defaults = defaultsIfAvailable(),
            let data = try? JSONEncoder().encode(snapshot)
        else {
            return
        }

        defaults.set(data, forKey: runtimeSnapshotKey)
        // Do not call synchronize(); forcing disk I/O adds latency and energy cost.
    }

    static func loadRuntimeSnapshot() -> TunnelRuntimeSnapshot {
        guard
            let data = defaultsIfAvailable()?.data(forKey: runtimeSnapshotKey),
            let snapshot = try? JSONDecoder().decode(TunnelRuntimeSnapshot.self, from: data)
        else {
            return .inactive
        }
        return snapshot
    }

    private static func defaults() throws -> UserDefaults {
        guard let defaults = defaultsIfAvailable() else {
            throw SharedStoreError.appGroupUnavailable
        }
        return defaults
    }

    private static func defaultsIfAvailable() -> UserDefaults? {
        UserDefaults(suiteName: SharedConfiguration.appGroupIdentifier)
    }
}

enum SharedStoreError: LocalizedError {
    case appGroupUnavailable

    var errorDescription: String? {
        "App Group \(SharedConfiguration.appGroupIdentifier) is unavailable. Check both targets' entitlements."
    }
}
