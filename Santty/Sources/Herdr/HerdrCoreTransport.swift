import Foundation

struct HerdrCoreError: Error, LocalizedError, Sendable {
    let kind: String
    let message: String
    var errorDescription: String? { message }
    init(_ message: String, kind: String = "connection") { self.message = message; self.kind = kind }
}

struct HerdrCoreHello: Decodable, Sendable {
    struct Identity: Codable, Sendable, Equatable { let id: String; let name: String }
    let generation: Int
    let framed: Bool
    let core: Identity
    let methods: [String]
    let version: String?
}

struct HerdrCoreReply<Value: Decodable & Sendable>: Decodable, Sendable {
    struct Failure: Decodable, Sendable {
        struct Details: Decodable, Sendable { let kind: String? }
        let message: String
        let data: Details?
    }
    let result: Value?
    let error: Failure?
    func get() throws -> Value {
        if let error { throw HerdrCoreError(error.message, kind: error.data?.kind ?? "rpc") }
        guard let result else { throw HerdrCoreError("herdr-core returned no result", kind: "protocol") }
        return result
    }
}

struct HerdrCoreFrame: Sendable, Equatable {
    let channel: UInt32
    let kind: UInt8
    let payload: Data
    static let maximumPayload = 16 * 1024 * 1024

    func encoded() -> Data {
        Self.little(channel) + Data([kind]) + Self.little(UInt32(payload.count)) + payload
    }
    static func header(_ bytes: Data) throws -> (UInt32, UInt8, Int) {
        guard bytes.count == 9 else { throw HerdrCoreError("Invalid core frame header", kind: "protocol") }
        let channel = bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        let length = bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 5, as: UInt32.self)) }
        guard length <= maximumPayload else { throw HerdrCoreError("Oversized core frame", kind: "protocol") }
        return (channel, bytes[bytes.startIndex + 4], Int(length))
    }
    static func little<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

/// One reader and writer per core; each stream consumes independently of the reader.
final class HerdrCoreTransport: @unchecked Sendable {
    private final class Stream: @unchecked Sendable {
        let queue = DispatchQueue(label: "Santty.herdr.stream", qos: .userInitiated)
        let receive: @Sendable (Result<HerdrCoreFrame, HerdrCoreError>) -> Void
        init(receive: @escaping @Sendable (Result<HerdrCoreFrame, HerdrCoreError>) -> Void) { self.receive = receive }
        func deliver(_ result: Result<HerdrCoreFrame, HerdrCoreError>) {
            queue.async { [receive] in receive(result) }
        }
    }
    let hello: HerdrCoreHello
    var executableURL: URL { process.executableURL! }
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let writer = DispatchQueue(label: "Santty.herdr.writer", qos: .userInitiated)
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var streams: [UInt32: Stream] = [:]
    private var early: [UInt32: [HerdrCoreFrame]] = [:]
    private var earlyBytes = 0
    private var retired: Set<UInt32> = []
    private var closed: HerdrCoreError?

    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
               "/opt/homebrew/bin", "/usr/local/bin"]
        for directory in paths where !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("hc")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw HerdrCoreError("Cannot find hc. Install herdr-core and make hc available on PATH.", kind: "not_installed")
    }

    /// Call off the main thread: process launch and the initial line handshake block.
    static func connect(executable: URL? = nil,
                        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> HerdrCoreTransport {
        let process = Process()
        process.executableURL = try executable ?? Self.executable(environment: environment)
        process.arguments = ["connect"]
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            try input.fileHandleForWriting.write(contentsOf: Data("{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"hello\",\"params\":{\"generation\":1,\"framed\":true}}\n".utf8))
            // Kill an unresponsive helper so even a stuck handshake releases its reader.
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
            defer { timeout.cancel() }
            var line = Data()
            while line.last != 10 {
                guard line.count < 1024 * 1024 else { throw HerdrCoreError("Oversized core hello", kind: "protocol") }
                line.append(try read(output.fileHandleForReading, count: 1))
            }
            let hello = try JSONDecoder().decode(HerdrCoreReply<HerdrCoreHello>.self, from: line).get()
            let required = ["terminal.run", "terminal.attach", "terminal.get", "terminal.kill", "events.subscribe"]
            guard hello.generation == 1, hello.framed, required.allSatisfy(hello.methods.contains) else {
                throw HerdrCoreError("This version of herdr-core is incompatible. Update hc.", kind: "needs_update")
            }
            let connection = HerdrCoreTransport(process: process, input: input.fileHandleForWriting,
                output: output.fileHandleForReading, hello: hello)
            DispatchQueue.global(qos: .userInitiated).async { connection.readLoop() }
            return connection
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    private init(process: Process, input: FileHandle, output: FileHandle, hello: HerdrCoreHello) {
        self.process = process; self.input = input; self.output = output; self.hello = hello
    }

    func call(method: String, params: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let id: Int? = lock.withLock {
                if let closed { continuation.resume(throwing: closed); return nil }
                nextID += 1
                pending[nextID] = continuation
                return nextID
            }
            guard let id else { return }
            do {
                let name = try JSONEncoder().encode(method)
                let payload = Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":".utf8)
                    + name + Data(",\"params\":".utf8) + params + Data("}".utf8)
                send(channel: 0, kind: 0, payload: payload)
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
                    self?.failRequest(id, error: HerdrCoreError("herdr-core request timed out; its result is unknown", kind: "timeout"))
                }
            } catch { failRequest(id, error: error) }
        }
    }

    func register(channel: UInt32, receive: @escaping @Sendable (Result<HerdrCoreFrame, HerdrCoreError>) -> Void) {
        let stream = Stream(receive: receive)
        lock.withLock {
            if let closed { stream.deliver(.failure(closed)); return }
            streams[channel] = stream
            for frame in early.removeValue(forKey: channel) ?? [] {
                earlyBytes -= frame.payload.count
                stream.deliver(.success(frame))
            }
        }
    }

    func detach(channel: UInt32) {
        lock.withLock {
            retired.insert(channel)
            streams.removeValue(forKey: channel)
            for frame in early.removeValue(forKey: channel) ?? [] { earlyBytes -= frame.payload.count }
        }
        send(channel: channel, kind: 2)
    }

    func send(channel: UInt32, kind: UInt8, payload: Data = Data()) {
        guard payload.count <= HerdrCoreFrame.maximumPayload else { fail(HerdrCoreError("Oversized outgoing frame")); return }
        let frame = HerdrCoreFrame(channel: channel, kind: kind, payload: payload).encoded()
        writer.async { [self] in
            guard lock.withLock({ closed == nil }) else { return }
            do { try input.write(contentsOf: frame) }
            catch { fail(HerdrCoreError("Lost herdr-core connection: \(error.localizedDescription)")) }
        }
    }

    func credit(channel: UInt32, bytes: Int) {
        send(channel: channel, kind: 1, payload: HerdrCoreFrame.little(UInt32(bytes)))
    }

    func close() { fail(HerdrCoreError("Core viewer disconnected")) }

    private func readLoop() {
        do {
            while lock.withLock({ closed == nil }) {
                // This worker stays alive for the connection; drain Foundation read buffers per frame.
                try autoreleasepool {
                    let (channel, kind, length) = try HerdrCoreFrame.header(Self.read(output, count: 9))
                    let payload = try Self.read(output, count: length)
                    if channel == 0 {
                        let reply = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
                        guard let id = reply?["id"] as? Int else { return }
                        let continuation = lock.withLock { pending.removeValue(forKey: id) }
                        continuation?.resume(returning: payload)
                    } else {
                        let frame = HerdrCoreFrame(channel: channel, kind: kind, payload: payload)
                        let overflow = lock.withLock {
                            if retired.contains(channel) { return false }
                            if let stream = streams[channel] { stream.deliver(.success(frame)); return false }
                            // Replies and stream registration race; credit bounds data before registration.
                            if earlyBytes + payload.count > 16 * 1024 * 1024 { return true }
                            early[channel, default: []].append(frame)
                            earlyBytes += payload.count
                            return early.count > 1024
                        }
                        if overflow { throw HerdrCoreError("Unclaimed core streams exceeded their buffer", kind: "protocol") }
                    }
                }
            }
        } catch { fail(HerdrCoreError("Lost herdr-core connection: \(error.localizedDescription)")) }
    }

    private static func read(_ handle: FileHandle, count: Int) throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            guard let chunk = try handle.read(upToCount: count - bytes.count), !chunk.isEmpty else {
                throw HerdrCoreError("Core stream ended")
            }
            bytes.append(chunk)
        }
        return bytes
    }
    private func failRequest(_ id: Int, error: Error) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(throwing: error)
    }
    private func fail(_ error: HerdrCoreError) {
        let state: ([CheckedContinuation<Data, Error>], [Stream])? = lock.withLock {
            guard closed == nil else { return nil }
            closed = error
            let state = (Array(pending.values), Array(streams.values))
            pending.removeAll(); streams.removeAll(); early.removeAll(); earlyBytes = 0
            return state
        }
        guard let state else { return }
        state.0.forEach { $0.resume(throwing: error) }
        state.1.forEach { $0.deliver(.failure(error)) }
        if process.isRunning { process.terminate() }
    }
}
