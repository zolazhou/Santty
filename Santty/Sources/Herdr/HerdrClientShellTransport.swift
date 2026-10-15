import Foundation
import Darwin

struct HerdrShellPacket: Sendable {
    let message: HerdrShellServerMessage
    let surfaceCodec: String?
    let byteCount: Int
    let decodedByteCount: Int
    let payloadReadSeconds: TimeInterval
    let decodeSeconds: TimeInterval
    let enqueuedAt: TimeInterval
}

struct HerdrShellConnectionLost: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

// Blocking socket I/O stays on workers; credits include queued packets and partial writes.
final class HerdrClientShellTransport: @unchecked Sendable {
    struct QueueUsage: Encodable, Sendable {
        let queuedReadPayloadBytes: Int
        let queuedWriteFrameBytes: Int
        let peakReadPayloadBytes: Int
        let peakWriteFrameBytes: Int
        let queuedDecodedBytes: Int
        let peakDecodedBytes: Int
    }
    static let queueBudget = 64 * 1024 * 1024
    static let decodedQueueBudget = 256 * 1024 * 1024
    private static let maximumQueuedPackets = 256
    let serviceIdentity: HerdrServiceIdentity
    let messages: AsyncThrowingStream<HerdrShellPacket, Error>
    private let continuation: AsyncThrowingStream<HerdrShellPacket, Error>.Continuation
    private let lock = NSCondition()
    private let writer = DispatchQueue(label: "Santty.Herdr.shell.writer")
    private var readFD: CInt
    private let writeFD: CInt
    private let bridge: HerdrSSHBridge?
    private let endpoint: HerdrEndpoint?
    private var stopped = false
    private var queuedWriteBytes = 0
    private var queuedReadBytes = 0
    private var queuedReadPackets = 0
    private var peakReadBytes = 0
    private var peakWriteBytes = 0
    private var queuedDecodedBytes = 0
    private var peakDecodedBytes = 0

    var queueUsage: QueueUsage {
        lock.lock(); defer { lock.unlock() }
        return .init(queuedReadPayloadBytes: queuedReadBytes, queuedWriteFrameBytes: queuedWriteBytes,
                     peakReadPayloadBytes: peakReadBytes, peakWriteFrameBytes: peakWriteBytes,
                     queuedDecodedBytes: queuedDecodedBytes, peakDecodedBytes: peakDecodedBytes)
    }

    init(socketPath: String, endpoint: HerdrEndpoint? = nil, connection: (fd: CInt, bridge: HerdrSSHBridge)? = nil, requestedReuse: Bool = HerdrShellHello.requestSurfaceReuse, requestedScroll: Bool = HerdrShellHello.requestSurfaceScroll, requestedDelta: Bool = HerdrShellHello.requestSurfaceDelta) throws {
        self.endpoint = endpoint
        let fd: CInt
        do {
            if let connection { fd = connection.fd; bridge = connection.bridge }
            else if let endpoint, endpoint.machine != nil {
                let connection = try HerdrSSHBridge.connect(endpoint: endpoint, lane: .client)
                fd = connection.fd; bridge = connection.bridge
            } else { fd = try CLITransport.connect(to: socketPath); bridge = nil }
        }
        catch let error as CLIConnectionError where error.isRecoverable {
            throw HerdrShellConnectionLost(message: "Cannot connect to Herdr client socket: \(error.localizedDescription)")
        }
        catch let error as HerdrSSHFailure { throw error }
        catch { throw CLIError("Cannot connect to Herdr client socket: \(error.localizedDescription)") }
        do {
            if let endpoint, endpoint.machine != nil { serviceIdentity = .remote(endpoint: endpoint, bootID: "") }
            else { serviceIdentity = try HerdrServiceIdentity.read(socket: fd) }
        }
        catch { close(fd); throw error }
        let duplicate = dup(fd)
        guard duplicate >= 0 else { close(fd); throw CLIError("Cannot duplicate Herdr client socket") }
        readFD = fd; writeFD = duplicate
        _ = fcntl(duplicate, F_SETFD, FD_CLOEXEC)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        let stream = AsyncThrowingStream<HerdrShellPacket, Error>.makeStream(bufferingPolicy: .bufferingOldest(Self.maximumQueuedPackets))
        messages = stream.stream; continuation = stream.continuation
        continuation.onTermination = { [weak self] _ in self?.stop() }
        DispatchQueue.global(qos: .userInitiated).async { [self] in readLoop(fd, requestedReuse: requestedReuse, requestedScroll: requestedScroll, requestedDelta: requestedDelta) }
    }

    func consume(_ packet: HerdrShellPacket) {
        lock.lock()
        queuedReadBytes -= packet.byteCount; queuedDecodedBytes -= packet.decodedByteCount
        queuedReadPackets -= 1
        assert(queuedReadBytes >= 0 && queuedDecodedBytes >= 0 && queuedReadPackets >= 0)
        lock.signal()
        lock.unlock()
    }

    func send(_ message: HerdrShellClientMessage) throws {
        let data = try message.encoded()
        lock.lock()
        guard !stopped, data.count <= Self.queueBudget - queuedWriteBytes else {
            let full = !stopped; lock.unlock()
            let error = CLIError(full ? "Herdr shell write queue is full; input was not replayed" : "Herdr shell is disconnected")
            if full { stop(error) }; throw error
        }
        queuedWriteBytes += data.count
        peakWriteBytes = max(peakWriteBytes, queuedWriteBytes)
        writer.async { [self] in
            defer { lock.lock(); queuedWriteBytes -= data.count; lock.unlock() }
            guard isActive else { return }
            do {
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        guard isActive else { throw CLIError("Herdr shell write cancelled") }
                        let count = Darwin.write(writeFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw HerdrShellConnectionLost(message: "Herdr shell write failed or timed out; input was not replayed") }
                        offset += count
                    }
                }
            } catch { stop(error) }
        }
        lock.unlock()
    }

    func detach() {
        try? send(.detach)
        writer.async { [self] in stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.stop() }
    }

    func stop(_ error: (any Error)? = nil) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.broadcast()
        if error != nil, let endpoint, bridge != nil { HerdrSSHBridge.invalidate(endpoint) }
        if readFD >= 0 { _ = shutdown(readFD, SHUT_RDWR) }
        bridge?.stop()
        writer.async { [self] in close(writeFD) }
        lock.unlock()
        continuation.finish(throwing: error)
    }

    private var isActive: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }

    private func readLoop(_ fd: CInt, requestedReuse: Bool, requestedScroll: Bool, requestedDelta: Bool) {
        defer {
            lock.lock(); readFD = -1; close(fd); lock.unlock()
        }
        do {
            var surfaceDecoder = HerdrClientShellSurfaceDecoder(requestedReuse: requestedReuse, requestedScroll: requestedScroll, requestedDelta: requestedDelta)
            while isActive {
                // Pause the socket reader so bursts remain bounded without dropping ordered events.
                lock.lock()
                while !stopped && queuedReadPackets >= Self.maximumQueuedPackets { lock.wait() }
                guard !stopped else { lock.unlock(); return }
                queuedReadPackets += 1
                lock.unlock()
                let prefix = try readExactly(4, from: fd)
                var length: UInt32 = 0
                for i in 0..<4 { length |= UInt32(prefix[i]) << (i * 8) }
                guard length > 0, length <= HerdrShellWire.maximumFrameBytes else { throw CLIError("Invalid Herdr shell frame length") }
                let bytes = Int(length)
                lock.lock()
                while !stopped && bytes > Self.queueBudget - queuedReadBytes { lock.wait() }
                guard !stopped else { lock.unlock(); return }
                queuedReadBytes += bytes
                peakReadBytes = max(peakReadBytes, queuedReadBytes)
                lock.unlock()
                let readAt = ProcessInfo.processInfo.systemUptime
                let payload = try readExactly(bytes, from: fd)
                let decodeAt = ProcessInfo.processInfo.systemUptime
                let wireMessage = try HerdrShellWire.decode(payload)
                let message = try surfaceDecoder.decode(wireMessage)
                let decodedAt = ProcessInfo.processInfo.systemUptime
                // Charge retained grids conservatively even when several messages share their rows.
                let decodedBytes = message.estimatedDecodedBytes
                guard decodedBytes <= Self.decodedQueueBudget else {
                    throw CLIError("Herdr shell decoded receive queue exceeds budget")
                }
                lock.lock()
                while !stopped && decodedBytes > Self.decodedQueueBudget - queuedDecodedBytes { lock.wait() }
                guard !stopped else { lock.unlock(); return }
                queuedDecodedBytes += decodedBytes
                peakDecodedBytes = max(peakDecodedBytes, queuedDecodedBytes)
                lock.unlock()
                switch continuation.yield(.init(message: message, surfaceCodec: wireMessage.surfaceCodec, byteCount: bytes, decodedByteCount: decodedBytes,
                    payloadReadSeconds: decodeAt - readAt, decodeSeconds: decodedAt - decodeAt,
                    enqueuedAt: ProcessInfo.processInfo.systemUptime)) {
                case .enqueued: break
                case .dropped: throw CLIError("Herdr shell event queue is full")
                case .terminated: stop(); return
                @unknown default: throw CLIError("Herdr shell event delivery failed")
                }
            }
        } catch {
            if let bridge, !bridge.errorSummary.isEmpty { stop(HerdrSSHFailure(message: "Herdr SSH: " + bridge.errorSummary)) }
            else { stop(error) }
        }
    }

    private func readExactly(_ count: Int, from fd: CInt) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                guard isActive else { throw CancellationError() }
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if n > 0 { offset += n; continue }
                if n < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw HerdrShellConnectionLost(message: n == 0 ? "Herdr shell stream closed" : "Herdr shell read failed")
            }
        }
        return data
    }
}
