import Darwin
import Foundation
import XCTest
@testable import Santty

final class HerdrCoreTransportTests: XCTestCase {
    func testFrameHeaderRoundTripAndPayloadLimit() throws {
        let frame = HerdrCoreFrame(channel: 42, kind: 3, payload: Data([80, 0, 24, 0]))
        let wire = frame.encoded()
        let (channel, kind, length) = try HerdrCoreFrame.header(Data(wire.prefix(9)))
        XCTAssertEqual(channel, 42)
        XCTAssertEqual(kind, 3)
        XCTAssertEqual(length, 4)
        XCTAssertEqual(Data(wire.dropFirst(9)), frame.payload)
        XCTAssertThrowsError(try HerdrCoreFrame.header(Data(repeating: 0, count: 8)))
        XCTAssertThrowsError(try HerdrCoreFrame.header(Data([0, 0, 0, 0, 0, 255, 255, 255, 127])))
    }

    @MainActor
    func testRealCoreMultiplexingCreditAndDisconnect() async throws {
        let executable: URL
        do { executable = try HerdrCoreTransport.executable() }
        catch { throw XCTSkip("hc is required for the real-core transport test") }
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("santty-hc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HC_") }
        env["HC_SESSION"] = "probe"
        env["HC_SOCKET"] = root.appendingPathComponent("core.sock").path
        env["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        env["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        env["XDG_RUNTIME_DIR"] = root.path
        let environment = env
        defer {
            let stop = Process()
            stop.executableURL = executable; stop.arguments = ["server", "stop"]; stop.environment = environment
            stop.standardOutput = FileHandle.nullDevice; stop.standardError = FileHandle.nullDevice
            do {
                try stop.run(); stop.waitUntilExit()
                XCTAssertEqual(stop.terminationStatus, 0)
                try FileManager.default.removeItem(at: root)
            } catch { XCTFail("Private core cleanup failed: \(error)") }
        }
        let transport = try await Task.detached { try HerdrCoreTransport.connect(executable: executable, environment: environment) }.value
        defer { transport.close() }
        func call<T: Decodable & Sendable>(_ method: String, _ params: [String: Any], as: T.Type) async throws -> T {
            let data = try JSONSerialization.data(withJSONObject: params)
            let reply = try await transport.call(method: method, params: data)
            return try JSONDecoder().decode(HerdrCoreReply<T>.self, from: reply).get()
        }
        struct Terminal: Decodable, Sendable { let address: String; let state: String }
        struct Attach: Decodable, Sendable { let channel: UInt32 }
        let script = "read -r trigger; awk 'BEGIN {for (i=0;i<2000000;i++) print \"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\"}'; echo TRANSPORT-DONE; exec /bin/cat"
        let terminal = try await call("terminal.run", ["argv": ["/bin/sh", "-c", script], "no_parent": true, "cwd": root.path], as: Terminal.self)
        let stalled = try await call("terminal.attach", ["terminal": terminal.address, "cols": 80, "rows": 24], as: Attach.self)
        let live = try await call("terminal.attach", ["terminal": terminal.address, "cols": 80, "rows": 24, "observe": true], as: Attach.self)
        let stoppedViewer = CoreStreamRecorder(), liveViewer = CoreStreamRecorder()
        transport.register(channel: stalled.channel) { result in stoppedViewer.receive(result) }
        transport.register(channel: live.channel) { result in
            liveViewer.receive(result)
            if case let .success(frame) = result, frame.kind == 0 {
                transport.credit(channel: frame.channel, bytes: frame.payload.count)
            }
        }
        let memoryBefore = try residentMemory()
        transport.send(channel: stalled.channel, kind: 0, payload: Data("go\n".utf8))
        for _ in 0..<500 {
            if liveViewer.done || liveViewer.failure != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(liveViewer.done, liveViewer.failure ?? "Live stream did not finish")
        XCTAssertLessThanOrEqual(stoppedViewer.bytes, 256 * 1024)
        XCTAssertGreaterThan(liveViewer.bytes, 256 * 1024)
        let record = try await call("terminal.get", ["terminal": terminal.address], as: Terminal.self)
        XCTAssertEqual(record.state, "live")
        let memoryAfter = try residentMemory()
        print("Transport consumed \(liveViewer.bytes) bytes; resident memory before=\(memoryBefore), after=\(memoryAfter)")
        XCTAssertLessThan(memoryAfter - min(memoryBefore, memoryAfter), 64 * 1024 * 1024,
                          "Consumed output must release its temporary Foundation buffers while the connection stays open")
        transport.detach(channel: stalled.channel)
        transport.detach(channel: live.channel)
        let detached = try await call("terminal.get", ["terminal": terminal.address], as: Terminal.self)
        XCTAssertEqual(detached.state, "live")
        transport.close()
        do {
            let _: Terminal = try await call("terminal.get", ["terminal": terminal.address], as: Terminal.self)
            XCTFail("Disconnected RPC must fail")
        } catch { XCTAssertEqual((error as? HerdrCoreError)?.kind, "connection") }
    }

    private func residentMemory() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw CLIError("Cannot measure transport resident memory: \(result)") }
        return info.resident_size
    }
}

private final class CoreStreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var byteCount = 0
    private var tail = Data()
    private var finished = false
    private var error: String?
    var bytes: Int { lock.withLock { byteCount } }
    var done: Bool { lock.withLock { finished } }
    var failure: String? { lock.withLock { error } }
    func receive(_ result: Result<HerdrCoreFrame, HerdrCoreError>) {
        lock.withLock {
            switch result {
            case let .success(frame):
                guard frame.kind == 0 else { return }
                byteCount += frame.payload.count
                tail.append(frame.payload)
                finished = finished || tail.range(of: Data("TRANSPORT-DONE".utf8)) != nil
                tail = Data(tail.suffix(64))
            case let .failure(failure): error = failure.localizedDescription
            }
        }
    }
}
