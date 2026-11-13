import Darwin
import Foundation
@testable import SwiftTerm
import XCTest

/// Forces the pre-reader scheduling gap at the real fork/channel seam. Bytes
/// and the short program are unchanged; delays exist only in fault injection.
final class NativeLocalPTYLaunchTests: XCTestCase {
    func testShortChildOutputSurvivesAStalledParentBeforeReaderStartup() throws {
        let ended = expectation(description: "owned short child finished")
        let probe = LaunchCaptureProbe(ended: ended)
        let process = LocalProcess(delegate: probe, dispatchQueue: DispatchQueue(label: "santty.pty.late-reader"), directDelivery: true,
            duplicateDescriptor: { fd in
                Thread.sleep(forTimeInterval: 1.2) // exceed kernel hangup window before any reader exists
                return fcntl(fd, F_DUPFD_CLOEXEC, 3)
            })
        process.completeAvailableOutputOnExit = true
        defer { process.terminateTerminal(force: true) }
        try process.startProcessChecked(executable: "/usr/bin/printf", args: ["FINAL-TAIL"], environment: ["PATH=/usr/bin:/bin"]).get()
        wait(for: [ended], timeout: 5)
        XCTAssertEqual(probe.bytes, Data("FINAL-TAIL".utf8))
        XCTAssertEqual(probe.code, 0)
        XCTAssertEqual(process.outputDrainComplete, true)
    }

    func testRapidUnacknowledgedShortChildrenInDirectAndQueuedDelivery() throws {
        for queued in [false, true] {
            for iteration in 0..<12 {
                let ended = expectation(description: "short launch \(queued) / \(iteration)")
                let probe = LaunchCaptureProbe(ended: ended)
                let process = LocalProcess(delegate: probe, dispatchQueue: DispatchQueue(label: "santty.pty.rapid"), directDelivery: !queued)
                process.completeAvailableOutputOnExit = true
                defer { process.terminateTerminal(force: true) }
                try process.startProcessChecked(executable: "/usr/bin/printf", args: ["FINAL-TAIL"], environment: ["PATH=/usr/bin:/bin"]).get()
                wait(for: [ended], timeout: 5)
                XCTAssertEqual(probe.bytes, Data("FINAL-TAIL".utf8))
                XCTAssertEqual(probe.code, 0)
                XCTAssertEqual(process.outputDrainComplete, true)
            }
        }
    }

    func testFailedInputChannelNeverExecutesThePreparedProgram() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("must-not-execute")
        let ended = expectation(description: "no termination callback for checked launch failure")
        ended.isInverted = true
        let probe = LaunchCaptureProbe(ended: ended)
        let process = LocalProcess(delegate: probe, dispatchQueue: DispatchQueue(label: "santty.pty.failed-prepare"), directDelivery: true,
            duplicateDescriptor: { _ in
                // Deterministically exposes old exec-before-failure behavior;
                // never a production startup delay or a changed wire fixture.
                Thread.sleep(forTimeInterval: 0.3)
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
                errno = EMFILE
                return -1
            })
        process.completeAvailableOutputOnExit = true
        let result = process.startProcessChecked(executable: "/bin/sh", args: ["-c", "printf BAD > must-not-execute"],
            environment: ["PATH=/usr/bin:/bin"], currentDirectory: root.path)
        if case .failure(.writeChannelFailed(EMFILE)) = result {} else { XCTFail("expected typed channel refusal: \(result)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(process.shellPid, 0); XCTAssertEqual(process.childfd, -1)
        wait(for: [ended], timeout: 0.05)
    }

    func testCancellationDuringPreparationNeverExecutesTheProgram() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ended = expectation(description: "cancelled prepared child reaped")
        let probe = LaunchCaptureProbe(ended: ended), reference = LaunchCancelReference()
        let process = LocalProcess(delegate: probe, dispatchQueue: DispatchQueue(label: "santty.pty.cancel-prepare"), directDelivery: true,
            duplicateDescriptor: { fd in reference.cancel(); return fcntl(fd, F_DUPFD_CLOEXEC, 3) })
        reference.install(process)
        process.completeAvailableOutputOnExit = true
        try process.startProcessChecked(executable: "/bin/sh", args: ["-c", "printf BAD > must-not-execute"],
            environment: ["PATH=/usr/bin:/bin"], currentDirectory: root.path).get()
        wait(for: [ended], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-execute").path))
        XCTAssertEqual(probe.bytes, Data())
        XCTAssertFalse(process.running)
    }

    func testOutputSurvivesDelayedCaptureAfterTheProgramHasActuallyWrittenIt() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 640, ws_ypixel: 384)
        let launch = try XCTUnwrap(PseudoTerminalHelpers.prepareFork(andExec: "/bin/sh",
            args: ["sh", "-c", "printf FINAL-TAIL; : > attempted-exit"], env: ["PATH=/usr/bin:/bin"],
            currentDirectory: root.path, desiredWindowSize: &size, preserveOutput: true))
        var gate = launch.gateFd, stillOwned = true
        defer {
            if gate >= 0 { close(gate) }
            close(launch.masterFd); close(launch.slaveFd)
            if stillOwned { kill(launch.pid, SIGKILL); var status: Int32 = 0; _ = waitpid(launch.pid, &status, 0) }
        }
        XCTAssertNil(launch.setupError)
        var ready: UInt8 = 1
        XCTAssertEqual(write(gate, &ready, 1), 1); close(gate); gate = -1
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("attempted-exit").path) { break }
            usleep(10_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("attempted-exit").path))
        Thread.sleep(forTimeInterval: 1.2) // test deliberately withholds all master reads AFTER the write
        XCTAssertEqual(fcntl(launch.masterFd, F_SETFL, fcntl(launch.masterFd, F_GETFL, 0) | O_NONBLOCK), 0)
        var bytes = [UInt8](repeating: 0, count: 64)
        let n = read(launch.masterFd, &bytes, bytes.count)
        XCTAssertEqual(n, 10)
        if n >= 0 { XCTAssertEqual(Data(bytes.prefix(n)), Data("FINAL-TAIL".utf8)) }
        var status: Int32 = 0, waited: pid_t = 0
        for _ in 0..<500 {
            waited = waitpid(launch.pid, &status, WNOHANG)
            if waited != 0 { break }
            usleep(10_000)
        }
        if waited == launch.pid || (waited == -1 && errno == ECHILD) { stillOwned = false }
        XCTAssertEqual(waited, launch.pid); XCTAssertEqual(status, 0)
    }

    func testPreparedGateAbortAndDescriptorFlags() throws {
        try preparedGate(killBeforeRelease: false)
    }

    func testDeadPreparedChildReturnsEPIPEWithoutChangingGlobalSignals() throws {
        try preparedGate(killBeforeRelease: true)
    }

    private func preparedGate(killBeforeRelease: Bool) throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 640, ws_ypixel: 384)
        let launch = try XCTUnwrap(PseudoTerminalHelpers.prepareFork(andExec: "/bin/sh",
            args: ["sh", "-c", "printf BAD > must-not-execute"], env: ["PATH=/usr/bin:/bin"],
            currentDirectory: root.path, desiredWindowSize: &size, preserveOutput: true))
        var gate = launch.gateFd, stillOwned = true
        defer {
            if gate >= 0 { close(gate) }
            close(launch.masterFd); close(launch.slaveFd)
            // This test alone reaps this positive direct child. Never signal
            // after a successful reap or ECHILD, which permits PID reuse.
            if stillOwned { kill(launch.pid, SIGKILL); var status: Int32 = 0; _ = waitpid(launch.pid, &status, 0) }
        }
        XCTAssertNil(launch.setupError)
        XCTAssertGreaterThanOrEqual(gate, 3)
        XCTAssertGreaterThanOrEqual(launch.slaveFd, 0)
        XCTAssertNotEqual(fcntl(gate, F_GETFD, 0) & FD_CLOEXEC, 0)
        XCTAssertNotEqual(fcntl(launch.slaveFd, F_GETFD, 0) & FD_CLOEXEC, 0)
        XCTAssertEqual(fcntl(gate, F_GETNOSIGPIPE, 0), 1)
        if killBeforeRelease { XCTAssertEqual(kill(launch.pid, SIGKILL), 0) }
        else { close(gate); gate = -1 } // EOF abort is not exec permission
        var status: Int32 = 0, waited: pid_t = 0
        for _ in 0..<500 {
            waited = waitpid(launch.pid, &status, WNOHANG)
            if waited != 0 { break }
            usleep(10_000)
        }
        if waited == launch.pid || (waited == -1 && errno == ECHILD) { stillOwned = false }
        XCTAssertEqual(waited, launch.pid)
        if killBeforeRelease {
            XCTAssertEqual(status & 0x7f, SIGKILL)
            var ready: UInt8 = 1
            XCTAssertEqual(write(gate, &ready, 1), -1)
            XCTAssertEqual(errno, EPIPE) // fd-local suppression, not signal(SIGPIPE, SIG_IGN)
        } else { XCTAssertEqual((status >> 8) & 0xff, 127) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-execute").path))
    }

    private func privateRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("santty-pty-launch-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    func testForcedCloseCannotRetireAKeeperBeforeItsParserCallbackReturns() throws {
        try forcedClose(changeNextLaunch: false)
    }

    func testChangingNextLaunchPreferenceCannotDowngradeTheActiveGuard() throws {
        try forcedClose(changeNextLaunch: true)
    }

    private func forcedClose(changeNextLaunch: Bool) throws {
        let ended = expectation(description: "owned forced close finished")
        let entered = expectation(description: "owned parser held")
        let gate = DispatchSemaphore(value: 0)
        let probe = LaunchCaptureProbe(ended: ended, entered: entered, gate: gate)
        let process = LocalProcess(delegate: probe, dispatchQueue: DispatchQueue(label: "santty.pty.close-capture"), directDelivery: true)
        process.completeAvailableOutputOnExit = true
        defer { gate.signal(); process.terminateTerminal(force: true) }
        try process.startProcessChecked(executable: "/bin/sh", args: ["-c", "stty -echo; printf HELD; IFS= read -r go"], environment: ["PATH=/usr/bin:/bin"]).get()
        wait(for: [entered], timeout: 5)
        if changeNextLaunch { process.completeAvailableOutputOnExit = false }
        process.terminateTerminal(force: true)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(probe.didEnd, "explicit close must not overtake the borrowed callback in guarded mode")
        let start = DispatchTime.now().uptimeNanoseconds
        process.terminateTerminal(force: true)
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 250_000_000)
        gate.signal()
        wait(for: [ended], timeout: 5)
        XCTAssertEqual(probe.returned.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(probe.bytes, Data("HELD".utf8))
        XCTAssertEqual(process.outputDrainComplete, false)
    }
}

private final class LaunchCancelReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var process: LocalProcess?
    func install(_ value: LocalProcess) { lock.withLock { process = value } }
    func cancel() { lock.withLock { process }?.terminate() }
}

private final class LaunchCaptureProbe: LocalProcessDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let ended: XCTestExpectation
    private var data = Data()
    private var status: Int32?
    private var received = false
    private var finished = false
    private let entered: XCTestExpectation?
    private let gate: DispatchSemaphore?
    let returned = DispatchSemaphore(value: 0)
    init(ended: XCTestExpectation, entered: XCTestExpectation? = nil, gate: DispatchSemaphore? = nil) {
        self.ended = ended; self.entered = entered; self.gate = gate
    }
    var bytes: Data { lock.withLock { data } }
    var code: Int32? { lock.withLock { status } }
    var didEnd: Bool { lock.withLock { finished } }
    func dataReceived(slice: ArraySlice<UInt8>) {
        let owned = Data(slice)
        let first = lock.withLock { let first = !received; received = true; return first }
        if first { entered?.fulfill(); gate?.wait() }
        lock.withLock { data.append(owned) }
        if first { returned.signal() }
    }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { lock.withLock { status = exitCode; finished = true }; ended.fulfill() }
    func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 640, ws_ypixel: 384) }
}
