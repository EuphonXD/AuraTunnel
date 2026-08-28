import Darwin
import Foundation
@preconcurrency import NetworkExtension

/// Coalesces Leaf's packet callbacks before crossing back into PacketFlow.
/// The only unavoidable copy is from Leaf's callback buffer into Swift-owned
/// Data because the Rust pointer is valid only during the callback.
final class LeafPacketWriter: @unchecked Sendable {
    private struct PendingPacket {
        let data: Data
        let family: NSNumber
    }

    private struct PacketBatch {
        var data: [Data] = []
        var families: [NSNumber] = []

        var isEmpty: Bool { data.isEmpty }
    }

    private let packetFlow: NEPacketTunnelFlow
    private let writeQueue = DispatchQueue(
        label: "com.shaolihuang.auratunnel.packet-writer",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private let capacity = PacketBatchPump.targetWriteBatchCapacity
    private static let maximumPendingPackets = 256
    private let maximumPendingBytes = 2 * 1_024 * 1_024
    /// Fixed-capacity ring storage avoids `Array.removeFirst` memmoves in the
    /// callback hot path and puts a hard ceiling on queued packet ownership.
    private var ring: [PendingPacket?]
    private var head = 0
    private var pendingCount = 0
    private var pendingBytes = 0
    private var delayedFlush: DispatchWorkItem?
    private var stopped = false

    init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
        ring = Array(repeating: nil, count: Self.maximumPendingPackets)
    }

    func enqueue(bytes: UnsafePointer<UInt8>, count: Int) {
        guard count > 0, count <= 65_535 else { return }
        let version = bytes.pointee >> 4
        let family: NSNumber
        switch version {
        case 4: family = NSNumber(value: AF_INET)
        case 6: family = NSNumber(value: AF_INET6)
        default: return
        }

        // Required ownership transfer; never append or transform raw packets.
        let data = Data(bytes: bytes, count: count)
        var ready: PacketBatch?

        lock.lock()
        if !stopped {
            if pendingCount >= Self.maximumPendingPackets || pendingBytes + count > maximumPendingBytes {
                // Bound memory under downstream pressure. Dropping an old batch
                // is preferable to an extension jetsam or thermal spiral.
                _ = drainLocked(limit: capacity)
            }
            appendLocked(PendingPacket(data: data, family: family))
            if pendingCount >= capacity {
                delayedFlush?.cancel()
                delayedFlush = nil
                ready = drainLocked(limit: capacity)
            } else if delayedFlush == nil {
                let work = DispatchWorkItem { [weak self] in self?.flushPending() }
                delayedFlush = work
                // A short deadline provides latency without one dispatch wake-up
                // per packet. Full batches flush immediately.
                writeQueue.asyncAfter(deadline: .now() + .milliseconds(2), execute: work)
            }
        }
        lock.unlock()

        if let ready { submit(ready) }
    }

    func stop() {
        lock.lock()
        stopped = true
        delayedFlush?.cancel()
        delayedFlush = nil
        ring = []
        head = 0
        pendingCount = 0
        pendingBytes = 0
        lock.unlock()
    }

    private func flushPending() {
        lock.lock()
        delayedFlush = nil
        let ready = stopped ? PacketBatch() : drainLocked(limit: capacity)
        let needsAnotherFlush = !stopped && pendingCount > 0
        if needsAnotherFlush {
            let work = DispatchWorkItem { [weak self] in self?.flushPending() }
            delayedFlush = work
            writeQueue.asyncAfter(deadline: .now() + .milliseconds(2), execute: work)
        }
        lock.unlock()
        if !ready.isEmpty { submit(ready) }
    }

    private func appendLocked(_ packet: PendingPacket) {
        guard !ring.isEmpty, pendingCount < ring.count else { return }
        let index = (head + pendingCount) % ring.count
        ring[index] = packet
        pendingCount += 1
        pendingBytes += packet.data.count
    }

    private func drainLocked(limit: Int) -> PacketBatch {
        let count = min(limit, pendingCount)
        guard count > 0, !ring.isEmpty else { return PacketBatch() }
        var batch = PacketBatch()
        batch.data.reserveCapacity(count)
        batch.families.reserveCapacity(count)
        for offset in 0..<count {
            let index = (head + offset) % ring.count
            guard let packet = ring[index] else { continue }
            batch.data.append(packet.data)
            batch.families.append(packet.family)
            pendingBytes -= packet.data.count
            ring[index] = nil
        }
        head = (head + count) % ring.count
        pendingCount -= count
        return batch
    }

    private func submit(_ packets: PacketBatch) {
        let data = packets.data
        let families = packets.families
        writeQueue.async { [packetFlow] in
            autoreleasepool {
                _ = packetFlow.writePackets(data, withProtocols: families)
            }
        }
    }
}
