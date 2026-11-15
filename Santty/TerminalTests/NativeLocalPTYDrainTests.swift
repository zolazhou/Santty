import Darwin
import Foundation
@testable import SwiftTerm
import XCTest

/// Private children + a parser gate distinguish collected bytes from bytes the
/// kernel may discard at hangup. No existing terminal or user process is used.
final class NativeLocalPTYDrainTests: XCTestCase {
    func testNaturalExitWaitsForTheParserAndDeliversEveryCapturedTailByte() throws {
        try capturedTail(complete: true)
    }

    func testExplicitCloseCancelsTheFiniteDrainWithoutJoiningTheCaller() throws {
        try capturedTail(complete: true, cancel: true)
    }

    func testLegacyBoundedPolicyStillReportsItsCutoff() throws {
        try capturedTail(complete: false)
    }

    func testCompatibilityQueuedDeliveryAlsoDrainsBeforeTermination() throws {
        try capturedTail(complete: true, queued: true)
    }

    private func capturedTail(complete: Bool, cancel: Bool = false, queued: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("santty-pty-drain-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<16_384).map { UInt8(65 + $0 % 26) }) + Data("FINAL-CAPTURED-TAIL".utf8)
        try payload.write(to: root.appendingPathComponent("payload"))
        let entered = expectation(description: "owned first batch held in parser")
        let terminated = expectation(description: "owned child termination")
        let gate = DispatchSemaphore(value: 0)
        let probe = PTYDrainProbe(entered: entered, terminated: terminated, gate: gate)
        let process = LocalProcess(delegate: probe, dispatchQueue: DispatchQueue(label: "santty.pty.drain-events"), directDelivery: !queued)
        process.completeAvailableOutputOnExit = complete
        defer { gate.signal(); process.terminateTerminal(force: true) }
        let script = "stty -echo -onlcr; printf PREFIX; IFS= read -r go; cat payload; : > ready; IFS= read -r done"
        if case .failure(let error) = process.startProcessChecked(executable: "/bin/sh", args: ["-c", script], environment: ["PATH=/usr/bin:/bin"], currentDirectory: root.path) {
            XCTFail("Owned launch failed: \(error)"); return
        }
        wait(for: [entered], timeout: 5)
        process.send(data: Array("go\n".utf8)[...])
        XCTAssertTrue(eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) })
        // The root is still waiting for our second token: this descriptor
        // cannot retire/reuse. Observe that the kernel tail has been gathered
        // before permitting exit, isolating parser deadline loss from HUP loss.
        let fd = process.childfd
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertTrue(eventually {
            var available: Int32 = -1
            // Darwin TIOCOUTQ: _IOR('t', 115, int), not FIONREAD.
            return ioctl(fd, UInt(0x40047473), &available) == 0 && available == 0
        })
        process.send(data: Array("done\n".utf8)[...])
        if !queued { XCTAssertTrue(eventually { process.shellPid == 0 }) }
        // Deliberately exceed the old 0.5s parser deadline; not a production
        // delay or an increased acceptance timeout. Exit must remain pending.
        Thread.sleep(forTimeInterval: 0.8)
        if complete { XCTAssertFalse(probe.didTerminate, "termination overtook the held parser") }
        if cancel {
            let start = DispatchTime.now().uptimeNanoseconds
            process.terminateTerminal(force: true)
            XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 250_000_000, "close must not join a held parser")
            XCTAssertFalse(probe.didTerminate, "cancellation must not let callback teardown overtake the held parser")
        }
        gate.signal()
        wait(for: [terminated], timeout: 5)
        XCTAssertEqual(probe.firstReturned.wait(timeout: .now() + 5), .success)
        if complete && !cancel {
            XCTAssertEqual(probe.bytes, Data("PREFIX".utf8) + payload)
        } else {
            XCTAssertEqual(probe.bytes, Data("PREFIX".utf8))
        }
        XCTAssertFalse(process.running)
        XCTAssertEqual(process.outputDrainComplete, complete && !cancel)
    }

    func testDescendantHoldingTheSlaveDoesNotDelayNaturalExitUntilEOF() throws {
        try descendantFence()
    }

    private func descendantFence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("santty-pty-fence-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("rescue").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let rescue = open(fifo, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        let lease = open(root.appendingPathComponent("lease").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(rescue, 0); XCTAssertGreaterThanOrEqual(lease, 0)
        defer { close(rescue); close(lease) }
        let worker = """
        import os, fcntl, signal, time
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        signal.alarm(7)  # owned-test rescue only; never a production deadline
        lease = open('lease', 'r+b', buffering=0)
        fcntl.flock(lease, fcntl.LOCK_EX)
        rescue = os.open('rescue', os.O_RDONLY | os.O_NONBLOCK)
        open('holder-ready', 'w').close()
        try:
            while True:
                try:
                    if os.read(rescue, 1): break
                except BlockingIOError: pass
                time.sleep(0.005)
        except OSError: pass  # closed owned master, not a cached-PID kill
        """
        try worker.write(to: root.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
        let entered = expectation(description: "owned parser held")
        let terminated = expectation(description: "owned root terminates without descendant EOF")
        let gate = DispatchSemaphore(value: 0)
        let probe = PTYDrainProbe(entered: entered, terminated: terminated, gate: gate)
        let process = LocalProcess(delegate: probe, dispatchQueue: DispatchQueue(label: "santty.pty.fence"), directDelivery: true)
        process.completeAvailableOutputOnExit = true
        defer {
            gate.signal(); process.terminateTerminal(force: true)
            var token: UInt8 = 1; _ = write(rescue, &token, 1)
            _ = eventually { flock(lease, LOCK_EX | LOCK_NB) == 0 }
        }
        let script = "stty -echo -onlcr; trap '' HUP; printf PREFIX; IFS= read -r go; /usr/bin/python3 worker.py & while [ ! -e holder-ready ]; do :; done; IFS= read -r done; exit 23"
        if case .failure(let error) = process.startProcessChecked(executable: "/bin/sh", args: ["-c", script], environment: ["PATH=/usr/bin:/bin"], currentDirectory: root.path) {
            XCTFail("Owned fence launch failed: \(error)"); return
        }
        wait(for: [entered], timeout: 5)
        process.send(data: Array("go\n".utf8)[...])
        XCTAssertTrue(eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent("holder-ready").path) })
        XCTAssertNotEqual(flock(lease, LOCK_EX | LOCK_NB), 0, "owned descendant must hold its lease before exit")
        process.send(data: Array("done\n".utf8)[...])
        XCTAssertTrue(eventually { process.shellPid == 0 })
        XCTAssertNotEqual(flock(lease, LOCK_EX | LOCK_NB), 0, "owned descendant must still hold its lease")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(probe.didTerminate)
        gate.signal()
        wait(for: [terminated], timeout: 5)
        XCTAssertEqual(process.outputDrainComplete, true)
        XCTAssertEqual(probe.bytes, Data("PREFIX".utf8))
        XCTAssertNotEqual(flock(lease, LOCK_EX | LOCK_NB), 0, "EOF is still held open, not the completion condition")
    }

    func testPTYFenceIncludesKernelOutputThatFIONREADDoesNotMeasure() throws {
        var master: Int32 = -1, slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        XCTAssertEqual(fcntl(slave, F_SETFL, fcntl(slave, F_GETFL, 0) | O_NONBLOCK), 0)
        let entered = expectation(description: "PTY parser held")
        let gate = DispatchSemaphore(value: 0)
        let probe = FinitePipelineProbe(entered: entered, gate: gate)
        let pipeline = TerminalIOPipeline(fd: master, delegate: probe)
        let state = DrainTestState(), done = DispatchGroup(), draining = DispatchGroup()
        let writer = slave
        pipeline.start()
        var prefix: UInt8 = 88
        XCTAssertEqual(write(slave, &prefix, 1), 1)
        wait(for: [entered], timeout: 5)
        done.enter()
        Thread {
            let bytes = [UInt8](repeating: 88, count: 4096)
            bytes.withUnsafeBytes { buffer in
                while !state.stop {
                    let n = write(writer, buffer.baseAddress, buffer.count)
                    if n > 0 { state.add(n) }
                    else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { usleep(1000) }
                    else { break }
                }
            }
            done.leave()
        }.start()
        defer {
            state.stop = true; gate.signal(); pipeline.cancelDrain()
            if done.wait(timeout: .now() + 5) == .success { close(slave) }
            else { XCTFail("do not close/reuse descriptor under a live writer") }
            pipeline.shutdown()
        }
        // Backpressure fills the ring and leaves bytes in the kernel. Stable
        // progress is a fixture observation, not a production startup delay.
        XCTAssertTrue(eventually {
            let before = state.produced
            usleep(20_000)
            var queued: Int32 = -1
            return before > 0 && before == state.produced && ioctl(master, UInt(0x40047473), &queued) == 0 && queued > 0
        })
        state.stop = true
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        var input: Int32 = -1, output: Int32 = -1
        XCTAssertEqual(ioctl(master, UInt(0x4004667f), &input), 0)
        XCTAssertEqual(ioctl(master, UInt(0x40047473), &output), 0)
        XCTAssertEqual(input, 0); XCTAssertGreaterThan(output, 0)
        draining.enter()
        Thread { state.result = pipeline.completeAvailableOutputAndShutdown(); draining.leave() }.start()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertNil(state.result)
        gate.signal()
        XCTAssertEqual(draining.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(state.result, true)
        XCTAssertEqual(probe.total, state.produced + 1, "all output, including the kernel queue, must survive the fence")
        XCTAssertTrue(probe.valid)
    }

    func testLiveProducerCannotExtendThePipelineByteFence() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        let writer = fds[1]
        XCTAssertEqual(fcntl(writer, F_SETFL, fcntl(writer, F_GETFL, 0) | O_NONBLOCK), 0)
        XCTAssertEqual(fcntl(writer, F_SETNOSIGPIPE, 1), 0) // owned fd only, no global signal mutation
        let entered = expectation(description: "pipeline parser held")
        let gate = DispatchSemaphore(value: 0)
        let probe = FinitePipelineProbe(entered: entered, gate: gate)
        let pipeline = TerminalIOPipeline(fd: fds[0], delegate: probe)
        let state = DrainTestState()
        let producerDone = DispatchGroup(), drainDone = DispatchGroup()
        producerDone.enter()
        pipeline.start()
        Thread {
            let bytes = [UInt8](repeating: 88, count: 4096)
            bytes.withUnsafeBytes { buffer in
                while !state.stop {
                    let n = write(writer, buffer.baseAddress, buffer.count)
                    if n > 0 { state.add(n) }
                    else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { usleep(1000) }
                    else { break }
                }
            }
            producerDone.leave()
        }.start()
        defer {
            state.stop = true; gate.signal(); pipeline.cancelDrain()
            if producerDone.wait(timeout: .now() + 5) == .success { close(writer) }
            else { XCTFail("owned nonblocking producer did not stop; do not reuse its descriptor") }
            pipeline.shutdown()
        }
        wait(for: [entered], timeout: 5)
        drainDone.enter()
        Thread { state.result = pipeline.completeAvailableOutputAndShutdown(); drainDone.leave() }.start()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertNil(state.result, "finite bytes must still await the held parser")
        gate.signal()
        XCTAssertEqual(drainDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(state.result, true)
        XCTAssertEqual(producerDone.wait(timeout: .now() + 5), .success, "completion closes the reader despite a continuously open writer")
        XCTAssertGreaterThan(probe.total, 0)
        XCTAssertTrue(probe.valid)
        XCTAssertLessThanOrEqual(probe.total, 6 * TerminalIOPipeline.bufferCapacity)
        XCTAssertLessThanOrEqual(probe.total, state.produced)
    }

    private func eventually(_ test: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if test() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return false
    }
}

private final class PTYDrainProbe: LocalProcessDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var callbacks = 0
    private var ended = false
    let firstReturned = DispatchSemaphore(value: 0)
    private let entered: XCTestExpectation
    private let terminated: XCTestExpectation
    private let gate: DispatchSemaphore
    init(entered: XCTestExpectation, terminated: XCTestExpectation, gate: DispatchSemaphore) {
        self.entered = entered; self.terminated = terminated; self.gate = gate
    }
    var bytes: Data { lock.withLock { output } }
    var didTerminate: Bool { lock.withLock { ended } }
    func dataReceived(slice: ArraySlice<UInt8>) {
        let owned = Data(slice)
        let first = lock.withLock { callbacks += 1; return callbacks == 1 }
        if first { entered.fulfill(); gate.wait() }
        lock.withLock { output.append(owned) }
        if first { firstReturned.signal() }
    }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        lock.withLock { ended = true }; terminated.fulfill()
    }
    func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 640, ws_ypixel: 384) }
}

private final class FinitePipelineProbe: TerminalIOPipelineDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var allValid = true
    private let entered: XCTestExpectation
    private let gate: DispatchSemaphore
    init(entered: XCTestExpectation, gate: DispatchSemaphore) { self.entered = entered; self.gate = gate }
    var total: Int { lock.withLock { count } }
    var valid: Bool { lock.withLock { allValid } }
    func pipeline(_ pipeline: TerminalIOPipeline, received data: Span<UInt8>) {
        var correct = true
        for i in 0..<data.count { if data[i] != 88 { correct = false; break } }
        let first = lock.withLock { let first = count == 0; count += data.count; allValid = allValid && correct; return first }
        if first { entered.fulfill(); gate.wait() }
    }
    func pipelineDidReachEOF(_ pipeline: TerminalIOPipeline) {}
}

private final class DrainTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var drained: Bool?
    private var count = 0
    var stop: Bool { get { lock.withLock { stopped } } set { lock.withLock { stopped = newValue } } }
    var result: Bool? { get { lock.withLock { drained } } set { lock.withLock { drained = newValue } } }
    var produced: Int { lock.withLock { count } }
    func add(_ bytes: Int) { lock.withLock { count += bytes } }
}
