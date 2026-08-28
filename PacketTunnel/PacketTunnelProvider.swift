import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private var packetPump: PacketBatchPump?
    private var forwardingEngine: LeafForwardingEngine?
    private var packetWriter: LeafPacketWriter?
    private let statisticsLock = NSLock()
    private var packetCount: UInt64 = 0
    private var byteCount: UInt64 = 0
    private var currentAttemptID: UUID?
    private var currentAppBuild: String?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Apple's override supplies a legacy non-Sendable callback while
        // setTunnelNetworkSettings uses a @Sendable closure in Swift 6.
        // This lifecycle-only box serializes and consumes the callback once.
        let completion = TunnelStartCompletion(completionHandler)

        currentAttemptID = (options?["attemptID"] as? NSString)
            .map(String.init)
            .flatMap(UUID.init(uuidString:))
        currentAppBuild = (options?["appBuild"] as? NSString).map(String.init)
        statisticsLock.lock()
        packetCount = 0
        byteCount = 0
        statisticsLock.unlock()
        saveRuntimeSnapshot(state: .preparing, message: "扩展已启动，正在加载所选节点")

        guard let profile = SharedStore.loadSelectedProfile() else {
            let error = PacketTunnelError.configurationMissing
            saveFailure(error)
            completion.call(error)
            return
        }

        guard ForwardingCapability.supports(profile.proxyProtocol) else {
            let error = PacketTunnelError.unsupportedProtocol(profile.proxyProtocol)
            saveFailure(error)
            completion.call(error)
            return
        }

        let routeMode = SharedStore.loadRouteMode()
        let tunnelConfiguration = SharedStore.loadTunnelConfiguration()

        let leafConfiguration: String
        do {
            leafConfiguration = try LeafConfigurationBuilder.makeConfiguration(for: profile)
        } catch {
            saveFailure(error)
            completion.call(error)
            return
        }

        saveRuntimeSnapshot(state: .preparing, message: "节点配置已通过校验，正在配置虚拟网卡")

        let settings = makeTunnelNetworkSettings(
            routeMode: routeMode,
            general: tunnelConfiguration.general
        )
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completion.call(PacketTunnelError.providerReleased)
                return
            }

            if let error {
                self.saveFailure(error)
                completion.call(error)
                return
            }

            self.saveRuntimeSnapshot(state: .preparing, message: "虚拟网卡已就绪，正在启动 Leaf 转发核心")
            let writer = LeafPacketWriter(packetFlow: self.packetFlow)
            let engine = LeafForwardingEngine()
            self.packetWriter = writer
            self.forwardingEngine = engine
            engine.start(
                configuration: leafConfiguration,
                writer: writer,
                completion: { [weak self] error in
                    guard let self else {
                        completion.call(PacketTunnelError.providerReleased)
                        return
                    }
                    if let error {
                        self.forwardingEngine?.stop()
                        self.packetWriter?.stop()
                        self.forwardingEngine = nil
                        self.packetWriter = nil
                        self.saveFailure(error)
                        completion.call(error)
                        return
                    }

                    let pump = PacketBatchPump(packetFlow: self.packetFlow) { [weak self] packets, protocols in
                        self?.handleOutboundBatch(packets, protocolNumbers: protocols)
                    }
                    self.packetPump = pump
                    pump.start()

                    self.saveRuntimeSnapshot(
                        state: .connected,
                        message: "Leaf 已接管 PacketFlow · \(profile.proxyProtocol.displayName) · \(routeMode.title)"
                    )
                    completion.call(nil)
                },
                onUnexpectedExit: { [weak self] error in
                    guard let self else { return }
                    self.saveFailure(error)
                    self.cancelTunnelWithError(error)
                }
            )
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        // iOS calls stopTunnel after a startup error. Preserve the failure
        // receipt in that path so the containing app can show the real Leaf or
        // configuration error instead of silently replacing it with inactive.
        let previousSnapshot = SharedStore.loadRuntimeSnapshot()
        let preserveFailure = previousSnapshot.state == .failed
        if !preserveFailure {
            saveRuntimeSnapshot(state: .stopping, message: "正在安全停止转发核心")
        }

        packetPump?.stop()
        packetPump = nil
        forwardingEngine?.stop()
        forwardingEngine = nil
        packetWriter?.stop()
        packetWriter = nil

        // No per-packet logging and no forced UserDefaults synchronization here.
        if !preserveFailure {
            saveRuntimeSnapshot(state: .inactive, message: "隧道已停止")
        }
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard
            let command = try? JSONDecoder().decode(TunnelIPCCommand.self, from: messageData),
            command == .runtimeSnapshot
        else {
            completionHandler?(nil)
            return
        }

        var snapshot = SharedStore.loadRuntimeSnapshot()
        statisticsLock.lock()
        snapshot.packetCount = packetCount
        snapshot.byteCount = byteCount
        statisticsLock.unlock()
        let response = try? JSONEncoder().encode(snapshot)
        completionHandler?(response)
    }

    private func makeTunnelNetworkSettings(
        routeMode: AuraRouteMode,
        general: TunnelGeneralConfiguration
    ) -> NEPacketTunnelNetworkSettings {
        // This value describes the virtual tunnel peer and must be a valid IP
        // address. The proxy server may be a DNS hostname and belongs only in
        // Leaf's outbound configuration; passing it here makes iOS reject the
        // settings with Invalid NETunnelNetworkSettings tunnelRemoteAddress.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")

        let ipv4 = NEIPv4Settings(
            addresses: ["10.0.0.2"],
            subnetMasks: ["255.255.255.0"]
        )
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        // IPv6 is opt-in in default.conf. Many imported VMess/SS chains expose
        // only IPv4 egress; unconditionally capturing IPv6 black-holes otherwise
        // healthy IPv4 sessions and was the Build 6 no-internet regression.
        if general.ipv6Enabled {
            let ipv6 = NEIPv6Settings(
                addresses: ["fd00:6175:7261::2"],
                networkPrefixLengths: [64]
            )
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        }

        let dnsServers: [String]
        switch routeMode {
        case .smart, .configuration, .scenario:
            // A benchmark range address is intentionally intercepted by Leaf's
            // fake DNS and is never sent to the public network.
            dnsServers = ["198.18.0.1"]
        case .proxy:
            dnsServers = general.fallbackDNSServers
        case .direct:
            dnsServers = general.dnsServers
        }
        let dns = NEDNSSettings(servers: dnsServers)
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        // 1360 leaves headroom for nested VMess/WebSocket/TLS without forcing
        // the tiny packet rate of 1280 on IPv4-only tunnels.
        settings.mtu = 1_360
        settings.tunnelOverheadBytes = 96
        return settings
    }

    private func handleOutboundBatch(_ packets: [Data], protocolNumbers: [NSNumber]) {
        // PacketFlow already provides a system batch. Leaf consumes the existing
        // contiguous Data buffers synchronously and performs only the one ownership
        // copy required to cross into its bounded Rust channel.
        _ = protocolNumbers
        let accepted = forwardingEngine?.submit(packets) ?? 0
        guard accepted > 0 else { return }
        let acceptedBytes = packets.prefix(accepted).reduce(into: UInt64(0)) {
            $0 += UInt64($1.count)
        }
        statisticsLock.lock()
        packetCount &+= UInt64(accepted)
        byteCount &+= acceptedBytes
        statisticsLock.unlock()
    }

    private func saveFailure(_ error: Error) {
        saveRuntimeSnapshot(state: .failed, message: error.localizedDescription)
    }

    /// Lifecycle-only diagnostics. This never runs in the packet hot path and
    /// therefore does not add per-packet IPC, logging or storage wakeups.
    private func saveRuntimeSnapshot(state: TunnelRuntimeState, message: String?) {
        statisticsLock.lock()
        let packets = packetCount
        let bytes = byteCount
        statisticsLock.unlock()
        SharedStore.saveRuntimeSnapshot(
            TunnelRuntimeSnapshot(
                state: state,
                updatedAt: .now,
                packetCount: packets,
                byteCount: bytes,
                message: message,
                attemptID: currentAttemptID,
                appBuild: currentAppBuild,
                extensionBuild: Self.bundleBuild
            )
        )
    }

    private static var bundleBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}

private final class TunnelStartCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Error?) -> Void)?

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func call(_ error: Error?) {
        lock.lock()
        let pendingHandler = handler
        handler = nil
        lock.unlock()
        pendingHandler?(error)
    }
}

enum PacketTunnelError: LocalizedError {
    case providerReleased
    case configurationMissing
    case unsupportedProtocol(ProxyProtocolKind)

    var errorDescription: String? {
        switch self {
        case .providerReleased:
            "Packet Tunnel provider was released while starting."
        case .configurationMissing:
            "未找到已选择的节点，请返回 App 重新导入或选择。"
        case .unsupportedProtocol(let kind):
            "当前 Leaf 核心不支持 \(kind.displayName) 节点。"
        }
    }
}
