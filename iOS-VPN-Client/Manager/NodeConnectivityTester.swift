import Combine
import Foundation
import Network

enum NodeConnectivityState: Equatable, Sendable {
    case queued
    case testing
    case reachable(milliseconds: Int)
    case timedOut
    case failed
    case udpOnly
}

/// User-triggered endpoint reachability checks for the containing app.
///
/// This intentionally performs one TCP handshake only. It does not claim that
/// VMess/VLESS authentication or full proxy forwarding has succeeded. Tests are
/// capped at three concurrent connections and a three-to-eight-second deadline
/// so a large subscription cannot create sustained CPU/radio load.
@MainActor
final class NodeConnectivityTester: ObservableObject {
    @Published private(set) var results: [UUID: NodeConnectivityState] = [:]

    private var maximumConcurrentTests = 1
    private var timeoutNanoseconds: UInt64 = 5_000_000_000
    private let connectionQueue = DispatchQueue(
        label: "com.shaolihuang.auratunnel.connectivity",
        qos: .utility
    )
    /// ArraySlice advances its start index on removeFirst(), avoiding repeated
    /// O(n) element shifts when a large subscription is tested sequentially.
    private var pendingProfiles: ArraySlice<TunnelProfile> = []
    private var activeConnections: [UUID: NWConnection] = [:]
    private var startTimes: [UUID: UInt64] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    var isRunning: Bool {
        !pendingProfiles.isEmpty || !activeConnections.isEmpty
    }

    func state(for profileID: UUID) -> NodeConnectivityState? {
        results[profileID]
    }

    func test(
        _ profile: TunnelProfile,
        timeoutSeconds: Int,
        maximumConcurrentTests: Int
    ) {
        guard activeConnections[profile.id] == nil else { return }
        configure(timeoutSeconds: timeoutSeconds, maximumConcurrentTests: maximumConcurrentTests)
        var updatedQueue = pendingProfiles.filter { $0.id != profile.id }
        updatedQueue.insert(profile, at: 0)
        pendingProfiles = updatedQueue[...]
        results[profile.id] = .queued
        drainQueue()
    }

    func testAll(
        _ profiles: [TunnelProfile],
        timeoutSeconds: Int,
        maximumConcurrentTests: Int
    ) {
        guard !isRunning else { return }
        configure(timeoutSeconds: timeoutSeconds, maximumConcurrentTests: maximumConcurrentTests)
        pendingProfiles = profiles[...]
        for profile in profiles {
            results[profile.id] = .queued
        }
        drainQueue()
    }

    func forget(profileIDs: Set<UUID>) {
        guard !profileIDs.isEmpty else { return }
        pendingProfiles = pendingProfiles.filter { !profileIDs.contains($0.id) }[...]
        for profileID in profileIDs {
            if let connection = activeConnections.removeValue(forKey: profileID) {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            startTimes.removeValue(forKey: profileID)
            timeoutTasks.removeValue(forKey: profileID)?.cancel()
            results.removeValue(forKey: profileID)
        }
        drainQueue()
    }

    private func drainQueue() {
        while activeConnections.count < maximumConcurrentTests,
              !pendingProfiles.isEmpty {
            let profile = pendingProfiles.removeFirst()

            // A UDP NWConnection becoming ready does not prove the remote peer
            // replied. Do not report a misleading latency for UDP-only nodes.
            guard profile.transport == .tcp else {
                results[profile.id] = .udpOnly
                continue
            }

            start(profile)
        }
    }

    private func start(_ profile: TunnelProfile) {
        guard let port = NWEndpoint.Port(rawValue: profile.serverPort) else {
            results[profile.id] = .failed
            drainQueue()
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(profile.serverHost),
            port: port,
            using: .tcp
        )
        activeConnections[profile.id] = connection
        startTimes[profile.id] = DispatchTime.now().uptimeNanoseconds
        results[profile.id] = .testing

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                self?.handle(state, profileID: profile.id, connection: connection)
            }
        }
        connection.start(queue: connectionQueue)

        let timeout = timeoutNanoseconds
        timeoutTasks[profile.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(profileID: profile.id, connection: connection, result: .timedOut)
        }
    }

    private func configure(timeoutSeconds: Int, maximumConcurrentTests: Int) {
        self.maximumConcurrentTests = min(max(maximumConcurrentTests, 1), 3)
        let seconds = min(max(timeoutSeconds, 3), 8)
        timeoutNanoseconds = UInt64(seconds) * 1_000_000_000
    }

    private func handle(
        _ state: NWConnection.State,
        profileID: UUID,
        connection: NWConnection
    ) {
        switch state {
        case .ready:
            let startedAt = startTimes[profileID] ?? DispatchTime.now().uptimeNanoseconds
            let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
            let milliseconds = max(1, Int(elapsed / 1_000_000))
            finish(
                profileID: profileID,
                connection: connection,
                result: .reachable(milliseconds: milliseconds)
            )
        case .failed:
            finish(profileID: profileID, connection: connection, result: .failed)
        default:
            break
        }
    }

    private func finish(
        profileID: UUID,
        connection: NWConnection,
        result: NodeConnectivityState
    ) {
        guard activeConnections[profileID] === connection else { return }
        activeConnections.removeValue(forKey: profileID)
        startTimes.removeValue(forKey: profileID)
        timeoutTasks.removeValue(forKey: profileID)?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        results[profileID] = result
        drainQueue()
    }
}
