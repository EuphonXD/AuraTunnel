import Foundation
import leaf

private let auraLeafOutputCallback: @convention(c) (
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutableRawPointer?
) -> Void = { bytes, count, context in
    guard let bytes, count > 0, let context else { return }
    let writer = Unmanaged<LeafPacketWriter>.fromOpaque(context).takeUnretainedValue()
    writer.enqueue(bytes: bytes, count: count)
}

/// Owns Leaf's blocking single-thread runtime on one dedicated queue.
/// One startup deadline is used for readiness; there is no recurring poll.
final class LeafForwardingEngine: @unchecked Sendable {
    private let runtimeID: UInt16 = 1
    private let runtimeQueue = DispatchQueue(
        label: "com.shaolihuang.auratunnel.leaf-runtime",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var stopping = false
    private var started = false
    private var lastExitCode: Int32?
    private var unexpectedExit: (@Sendable (Error) -> Void)?

    func start(
        configuration: String,
        writer: LeafPacketWriter,
        completion: @escaping @Sendable (Error?) -> Void,
        onUnexpectedExit: @escaping @Sendable (Error) -> Void
    ) {
        let validationCode = configuration.withCString { pointer in
            leaf_test_config_string(pointer)
        }
        guard validationCode == 0 else {
            completion(LeafEngineError.invalidConfiguration(validationCode))
            return
        }

        stateLock.lock()
        guard !started else {
            stateLock.unlock()
            completion(LeafEngineError.alreadyStarted)
            return
        }
        stopping = false
        lastExitCode = nil
        unexpectedExit = onUnexpectedExit
        stateLock.unlock()

        let context = Unmanaged.passUnretained(writer).toOpaque()
        guard leaf_set_packet_output_callback(auraLeafOutputCallback, context) else {
            completion(LeafEngineError.callbackRegistrationFailed)
            return
        }

        runtimeQueue.async { [weak self] in
            guard let self else { return }
            let result = configuration.withCString { pointer in
                leaf_run_with_config_string(self.runtimeID, pointer)
            }

            self.stateLock.lock()
            self.lastExitCode = result
            let shouldReport = self.started && !self.stopping
            let handler = self.unexpectedExit
            self.started = false
            self.stateLock.unlock()
            if shouldReport {
                handler?(LeafEngineError.unexpectedExit(result))
            }
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(120)) {
            if leaf_is_running(self.runtimeID) {
                self.stateLock.lock()
                self.started = true
                self.stateLock.unlock()
                completion(nil)
            } else {
                self.stateLock.lock()
                let code = self.lastExitCode ?? -1
                self.stateLock.unlock()
                leaf_clear_packet_output_callback()
                completion(LeafEngineError.startFailed(code))
            }
        }
    }

    @discardableResult
    func submit(_ packets: [Data]) -> Int {
        guard !packets.isEmpty else { return 0 }
        var descriptors: [leaf_packet_t] = []
        descriptors.reserveCapacity(packets.count)
        return inputPackets(packets[...], descriptors: &descriptors)
    }

    func stop() {
        stateLock.lock()
        stopping = true
        unexpectedExit = nil
        let wasStarted = started || leaf_is_running(runtimeID)
        stateLock.unlock()

        // Clear the callback before releasing Swift objects that Rust could call.
        leaf_clear_packet_output_callback()
        if wasStarted { _ = leaf_shutdown(runtimeID) }
    }

    private func inputPackets(
        _ packets: ArraySlice<Data>,
        descriptors: inout [leaf_packet_t]
    ) -> Int {
        guard let first = packets.first else {
            return descriptors.withUnsafeBufferPointer { buffer in
                Int(leaf_input_packets(buffer.baseAddress, buffer.count))
            }
        }
        return first.withUnsafeBytes { bytes in
            let pointer = bytes.bindMemory(to: UInt8.self).baseAddress
            descriptors.append(leaf_packet_t(data: pointer, len: bytes.count))
            return inputPackets(packets.dropFirst(), descriptors: &descriptors)
        }
    }
}

enum LeafEngineError: LocalizedError {
    case invalidConfiguration(Int32)
    case callbackRegistrationFailed
    case alreadyStarted
    case startFailed(Int32)
    case unexpectedExit(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let code):
            "Leaf 节点配置校验失败（错误码 \(code)）。"
        case .callbackRegistrationFailed:
            "Leaf PacketFlow 回调注册失败。"
        case .alreadyStarted:
            "Leaf 转发核心已启动。"
        case .startFailed(let code):
            "Leaf 转发核心启动失败（错误码 \(code)）。"
        case .unexpectedExit(let code):
            "Leaf 转发核心意外退出（错误码 \(code)）。"
        }
    }
}
