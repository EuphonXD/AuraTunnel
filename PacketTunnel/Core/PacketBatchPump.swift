import Foundation
import NetworkExtension

/// Keeps exactly one asynchronous TUN read outstanding and forwards each
/// system-provided packet array as one batch. No per-packet Task or queue hop.
final class PacketBatchPump: @unchecked Sendable {
    typealias BatchHandler = (_ packets: [Data], _ protocolNumbers: [NSNumber]) -> Void

    /// The upstream writer coalesces writes to this capacity with a short
    /// latency deadline. `readPackets` itself has no minimum-size control.
    static let targetWriteBatchCapacity = 64

    private let packetFlow: NEPacketTunnelFlow
    private let handler: BatchHandler
    private let stateLock = NSLock()
    private var running = false

    init(packetFlow: NEPacketTunnelFlow, handler: @escaping BatchHandler) {
        self.packetFlow = packetFlow
        self.handler = handler
    }

    func start() {
        stateLock.lock()
        guard !running else {
            stateLock.unlock()
            return
        }
        running = true
        stateLock.unlock()

        readNextBatch()
    }

    func stop() {
        stateLock.lock()
        running = false
        stateLock.unlock()
    }

    private func readNextBatch() {
        guard isRunning else { return }

        packetFlow.readPackets { [weak self] packets, protocolNumbers in
            guard let self, self.isRunning else { return }

            // Data instances are passed through directly. Autorelease scope prevents
            // transient Foundation objects from accumulating in the extension.
            autoreleasepool {
                self.handler(packets, protocolNumbers)
            }

            // readPackets completes asynchronously, so this recursion does not grow
            // the stack and avoids polling or a timer-driven wake-up loop.
            self.readNextBatch()
        }
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }
}
