import AppKit
import Darwin
import Foundation
import GhosttyVt
import SwiftTerm
import XCTest
@testable import SanttyTerminalLab

/// Independent owned-child checks around the standalone runner, never its
/// emulator-owning LocalProcessTerminalView or an existing user process.
final class NativeLocalPTYTests: XCTestCase {
    func testInvalidWorkingDirectoryFailsInsteadOfExecutingInTheParentDirectory() {
        let exited = expectation(description: "owned invalid-cwd child reaped")
        let delegate = PTYExitProbe { exited.fulfill() }
        let process = LocalProcess(delegate: delegate, dispatchQueue: DispatchQueue(label: "santty.pty.cwd-test"))
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("santty-missing-cwd-\(UUID())").path
        if case .failure(let error) = process.startProcessChecked(executable: "/bin/pwd", environment: ["PATH=/usr/bin:/bin"], currentDirectory: cwd) {
            XCTFail("Expected the child to report chdir/exec failure, got \(error)")
        }
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(delegate.status, 127)
        XCTAssertEqual(process.childfd, -1)
        XCTAssertEqual(process.shellPid, 0)
    }
}

@MainActor
final class NativeLocalPTYSessionTests: XCTestCase {
    private let viewport = TerminalStreamViewport(columns: 120, rows: 30, widthPixels: 960, heightPixels: 480, cellWidthPixels: 8, cellHeightPixels: 16)
    private func waitFor(_ stage: String, _ test: () throws -> Bool) async throws {
        for _ in 0..<500 {
            if try test() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Owned PTY timed out: \(stage)")
        throw NativeLocalPTYError.shutdownTimeout
    }
    private func text(_ lab: NativeLocalPTYLab, top: Int? = nil) throws -> String {
        let driver = lab.output.driver
        return try driver.snapshot(topRow: top ?? max(0, driver.totalRows - driver.rows)).rows.sorted { $0.key < $1.key }
            .map { $0.value.cells.compactMap(\.text).joined() }.joined(separator: "\n")
    }
    private func finished(_ lab: NativeLocalPTYLab) -> Bool { if case .exited = lab.state { return true }; return false }

    func testPrivateEnvironmentCwdTTYAndNormalizedNaturalExit() async throws {
        let lab = try NativeLocalPTYLab(driver: GhosttyVTDriver(), inheritedEnvironment: ["PATH":"/usr/bin:/bin", "BASH_ENV":"bad", "HC_SOCKET":"bad", "SANTTY_CONTROL_SOCKET":"bad", "SECRET_TOKEN":"bad"]) { _ in }
        do {
            XCTAssertNil(lab.environment["BASH_ENV"]); XCTAssertNil(lab.environment["HC_SOCKET"])
            XCTAssertNil(lab.environment["SANTTY_CONTROL_SOCKET"]); XCTAssertNil(lab.environment["SECRET_TOKEN"])
            let child = lab.home.appendingPathComponent("space cwd", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            try lab.start(viewport: viewport, args: ["-c", "printf 'PTY-READY\\n'; tty; pwd; read line; exit 7"], workingDirectory: child)
            try await waitFor("private ready") { try self.text(lab).contains("PTY-READY") }
            let info = try XCTUnwrap(lab.processInfo)
            XCTAssertGreaterThan(info.shellPid, 0)
            XCTAssertEqual(info.foregroundProcessGroupID, info.shellPid)
            XCTAssertEqual(info.foregroundPid, info.shellPid)
            XCTAssertTrue(try text(lab).contains(info.ttyName))
            XCTAssertEqual(info.workingDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, child.resolvingSymlinksInPath().path)
            XCTAssertTrue(try lab.output.sendText("done\r"))
            try await waitFor("natural exit") { self.finished(lab) }
            XCTAssertEqual(lab.state, .exited(7)); XCTAssertNil(lab.processInfo)
            XCTAssertFalse(try lab.output.sendText("must-not-replay"))
            XCTAssertThrowsError(try lab.start(viewport: self.viewport))
            let root = lab.root
            try await lab.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        } catch { try? await lab.stop(); throw error }
    }

    func testExecAndCwdFailuresExit127AndDoNotRunAFallbackShell() async throws {
        for badCwd in [false, true] {
            let lab = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in }
            do {
                try lab.start(viewport: viewport, executable: badCwd ? "/bin/pwd" : lab.root.appendingPathComponent("no-executable").path,
                    args: [], workingDirectory: badCwd ? lab.root.appendingPathComponent("no-directory") : nil)
                try await waitFor("exec/chdir failure") { self.finished(lab) }
                XCTAssertEqual(lab.state, .exited(127))
                try await lab.stop()
            } catch { try? await lab.stop(); throw error }
        }
    }

    func testEmbeddedNULIsRejectedBeforeForkAndFreshIdleCleanupWorks() async throws {
        let lab = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in }
        XCTAssertThrowsError(try lab.start(viewport: viewport, executable: "/bin/sh\0different"))
        XCTAssertEqual(lab.state, .idle)
        try await lab.stop(); try await lab.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lab.root.path))
    }

    func testPTYResizeReportsCellsAndPixelsThroughRealProgramAndVTReplies() async throws {
        let lab = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in }
        do {
            try lab.start(viewport: viewport, args: ["-c", "printf 'SIZE-READY\\n'; read line; stty size; printf '\\033[18t'; read answer; printf 'SIZE-DONE\\n'"])
            try await waitFor("size ready") { try self.text(lab).contains("SIZE-READY") }
            lab.updateViewport(.init(columns: 91, rows: 27, widthPixels: 910, heightPixels: 540, cellWidthPixels: 10, cellHeightPixels: 20))
            XCTAssertTrue(try lab.output.sendText("go\r"))
            try await waitFor("actual stty size") { try self.text(lab).contains("27 91") }
            // The program's read sees automatic query bytes (not replayed
            // user input). A newline completes its canonical read.
            XCTAssertTrue(try lab.output.sendText("\r"))
            try await waitFor("size done") { self.finished(lab) }
            XCTAssertTrue(try text(lab).contains("SIZE-DONE"))
            XCTAssertEqual(lab.output.driver.columns, 91); XCTAssertEqual(lab.output.driver.rows, 27)
            try await lab.stop()
        } catch { try? await lab.stop(); throw error }
    }

    func testLargeWideOutputAndFinalMarkerAreParsedBeforeExitNotification() async throws {
        let lab = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in }
        do {
            try lab.start(viewport: viewport, args: ["-c", "awk 'BEGIN{for(i=0;i<6000;i++) printf \"%04d abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghij\\n\",i; print \"PTY-FINAL-TAIL\"}'"])
            try await waitFor("wide burst exit") { self.finished(lab) }
            XCTAssertTrue(try text(lab).contains("PTY-FINAL-TAIL"))
            XCTAssertTrue(try text(lab, top: 0).contains("0000"))
            XCTAssertGreaterThanOrEqual(try lab.output.driver.totalRows, 6000)
            try await lab.stop()
        } catch { try? await lab.stop(); throw error }
    }

    func testForegroundGroupAndCwdTrackARealProgramAndCtrlCInterruptsIt() async throws {
        let lab = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in }
        do {
            try lab.start(viewport: viewport)
            try await waitFor("interactive shell") { lab.processInfo?.foregroundPid != nil }
            let shell = try XCTUnwrap(lab.processInfo?.shellPid)
            XCTAssertTrue(try lab.output.sendText("/bin/sleep 30\r"))
            try await waitFor("owned foreground program") {
                guard let info = lab.processInfo, let group = info.foregroundProcessGroupID else { return false }
                return group != shell && info.foregroundPid == group
            }
            let child = try XCTUnwrap(lab.processInfo)
            XCTAssertNotEqual(child.foregroundPid, shell)
            XCTAssertEqual(child.foregroundPid, child.foregroundProcessGroupID)
            XCTAssertTrue(try lab.output.sendKey(GHOSTTY_KEY_C, text: "c", modifiers: GhosttyMods(GHOSTTY_MODS_CTRL)))
            try await waitFor("shell regains foreground after SIGINT") { lab.processInfo?.foregroundPid == shell }
            try await lab.stop()
        } catch { try? await lab.stop(); throw error }
    }

    func testBoundedInputRejectsWholeOversizeWriteAndDoesNotReplayAfterExit() async throws {
        let lab = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in }
        do {
            try lab.start(viewport: viewport, args: ["-c", "read line; printf 'ACK:%s\\n' \"$line\""])
            XCTAssertFalse(try lab.output.sendText(String(repeating: "x", count: 1024 * 1024 + 1)))
            XCTAssertEqual(lab.lastWriteError, .inputBackpressure)
            XCTAssertEqual(lab.pendingInputBytes, 0)
            XCTAssertTrue(try lab.output.sendText("short\r"))
            try await waitFor("short accepted write") { self.finished(lab) }
            XCTAssertTrue(try text(lab).contains("ACK:short"))
            XCTAssertFalse(try lab.output.sendText("never queued")); XCTAssertEqual(lab.pendingInputBytes, 0)
            try await lab.stop()
        } catch { try? await lab.stop(); throw error }
    }

    func testRawChildReceivesLiteralUTF8EnterAndCtrlCBytes() async throws {
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }!
        let lab = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in }
        do {
            let source = "import os,tty; tty.setraw(0); os.write(1,b'RAW-READY'); d=b''\nwhile len(d)<4: d+=os.read(0,4-len(d))\nos.write(1,b'BYTES:'+d.hex().encode()+b'\\x1b[18t'); a=b''\nwhile not a.endswith(b't'): a+=os.read(0,64)\nos.write(1,b'QUERY:'+a.hex().encode())"
            try lab.start(viewport: viewport, executable: python, args: ["-c", source])
            try await waitFor("raw consumer") { try self.text(lab).contains("RAW-READY") }
            XCTAssertTrue(try lab.output.sendText("é"))
            XCTAssertTrue(try lab.output.sendKey(GHOSTTY_KEY_ENTER))
            XCTAssertTrue(try lab.output.sendKey(GHOSTTY_KEY_C, text: "c", modifiers: GhosttyMods(GHOSTTY_MODS_CTRL)))
            try await waitFor("raw bytes and exit") { self.finished(lab) }
            XCTAssertTrue(try text(lab).contains("BYTES:c3a90d03"))
            XCTAssertTrue(try text(lab).contains("QUERY:1b5b383b33303b31323074"), "CSI 8;30;120t must reach the raw consumer")
            try await lab.stop()
        } catch { try? await lab.stop(); throw error }
    }

    func testForegroundCwdChangesCanBeInheritedByAnotherOwnedSession() async throws {
        let first = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in }
        let second = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in }
        do {
            let directory = first.home.appendingPathComponent("next cwd", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try first.start(viewport: viewport)
            XCTAssertTrue(try first.output.sendText("cd '\(directory.path)'\r"))
            let target = directory.resolvingSymlinksInPath().path
            try await waitFor("actual changed cwd") {
                first.processInfo?.workingDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == target
            }
            let inherited = try XCTUnwrap(first.processInfo?.workingDirectory)
            try second.start(viewport: viewport, args: ["-c", "pwd"], workingDirectory: URL(fileURLWithPath: inherited))
            try await waitFor("inherited cwd child") { self.finished(second) }
            XCTAssertTrue(try text(second).contains(inherited))
            try await second.stop(); try await first.stop()
        } catch { try? await second.stop(); try? await first.stop(); throw error }
    }

    func testPublishedLocalPTYOutputUsesTheSameVTImageAndAXBoundary() async throws {
        let view = NativeTerminalScrollView(driver: try GhosttyVTDriver(), frame: CGRect(x: 0, y: 0, width: 640, height: 240), applicationIsHidden: { false })
        let window = NativeAnimationTestWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { view.resetPresentation(); window.contentView = nil }
        let lab = try NativeLocalPTYLab(driver: view.driver) { [weak view] reset in view?.parsedOutput(reset: reset) }
        view.renderer.output = lab.output
        view.onViewportChange = { [weak lab] viewport in lab?.updateViewport(viewport) }
        do {
            let png = NativePNGFixtures.vectors[0]
            try lab.start(viewport: view.viewport, args: ["-c", "printf '\\033[?25l\\033[2J\\033[H\\033_Ga=T,f=100,i=7,p=3,c=2,r=2,C=1,q=2;\(png.encoded)\\033\\\\LOCAL-AX'"])
            try await waitFor("actual local AX and PNG") { (view.renderer.accessibilityValue() as? String)?.contains("LOCAL-AX") == true && view.presentedFrame?.imageSnapshot.images[7]?.rgba == png.rgba }
            try await waitFor("local frontend natural exit") { self.finished(lab) }
            XCTAssertFalse(try lab.output.sendText("no replay"))
            try await lab.stop()
        } catch { try? await lab.stop(); throw error }
    }

    func testManySmallWritesAreBoundedWhileAChildDoesNotRead() async throws {
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }!
        let lab = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in }
        do {
            try lab.start(viewport: viewport, executable: python, args: ["-c", "import os,tty,time; tty.setraw(0); os.write(1,b'NOT-READING'); time.sleep(30)"])
            try await waitFor("non-reading raw child") { try self.text(lab).contains("NOT-READING") }
            var refused = false
            for _ in 0..<5000 {
                if try !lab.output.sendText(String(repeating: "x", count: 256)) { refused = true; break }
                XCTAssertLessThanOrEqual(lab.pendingInputBytes, 1024 * 1024)
            }
            XCTAssertTrue(refused); XCTAssertEqual(lab.lastWriteError, .inputBackpressure)
            try await lab.stop()
            XCTAssertEqual(lab.pendingInputBytes, 0)
        } catch { try? await lab.stop(); throw error }
    }

    func testImmediateCloseAfterLaunchNeverNeedsAPublishedPIDOrBlocksMain() async throws {
        let lab = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in }
        try lab.start(viewport: viewport, args: ["-c", "read line"])
        try await lab.stop()
        XCTAssertNil(lab.processInfo); XCTAssertFalse(FileManager.default.fileExists(atPath: lab.root.path))
        XCTAssertFalse(try lab.output.sendText("offline"))
    }

    func testUnexpectedOwnerReleaseStillClosesAndReapsTheOwnedSession() async throws {
        weak var weakLab: NativeLocalPTYLab?
        var directory: URL?
        try autoreleasepool {
            let lab = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in }
            try lab.start(viewport: viewport, args: ["-c", "read line"])
            weakLab = lab; directory = lab.root
        }
        XCTAssertNil(weakLab)
        let root = try XCTUnwrap(directory)
        try await waitFor("orphan owner cleanup") { !FileManager.default.fileExists(atPath: root.path) }
    }

    func testForceCloseSignalsTheOwnedForegroundGroupThroughItsPTY() async throws {
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }!
        let lab = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in }
        let fifo = lab.root.appendingPathComponent("rescue.fifo"), lease = lab.root.appendingPathComponent("owned.lease")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let control = Darwin.open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        let leaseFD = Darwin.open(lease.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(control, 0); XCTAssertGreaterThanOrEqual(leaseFD, 0)
        defer {
            // Rescue only this test's owned FIFO on failure, never a cached PID.
            // The assertion below is made before sending this backup token.
            var byte: UInt8 = 1; _ = Darwin.write(control, &byte, 1)
            Darwin.close(control); Darwin.close(leaseFD)
        }
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        do {
            let program = "import os,fcntl,signal; signal.signal(signal.SIGHUP,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN); f=os.open(\(String(reflecting: lease.path)),os.O_RDWR); fcntl.flock(f,fcntl.LOCK_EX); c=os.open(\(String(reflecting: fifo.path)),os.O_RDONLY); os.write(1,bytes.fromhex('464f524547524f554e442d4c45415345')); os.read(c,1)"
            try lab.start(viewport: viewport)
            XCTAssertTrue(try lab.output.sendText("\(quote(python)) -c \(quote(program))\r"))
            try await waitFor("foreground lease ready") {
                guard let info = lab.processInfo, let group = info.foregroundProcessGroupID else { return false }
                guard group != info.shellPid, info.foregroundPid == group else { return false }
                return try self.text(lab).contains("FOREGROUND-LEASE")
            }
            XCTAssertEqual(flock(leaseFD, LOCK_EX | LOCK_NB), -1)
            try await lab.stop()
            try await waitFor("owned foreground lease released by force close") { flock(leaseFD, LOCK_EX | LOCK_NB) == 0 }
            XCTAssertNil(lab.processInfo)
        } catch { try? await lab.stop(); throw error }
    }

    func testUnacknowledgedShortCommandPublishesLiteralTailThroughNativeVT() async throws {
        for _ in 0..<8 {
            let lab = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in }
            do {
                // No DSR, input gate, newline rewrite, shell startup hook, or
                // child-side acknowledgement makes this tiny program wait.
                try lab.start(viewport: viewport, executable: "/usr/bin/printf", args: ["FINAL-TAIL"])
                try await waitFor("unacknowledged short native command exit") { lab.state == .exited(0) }
                XCTAssertTrue(try text(lab).contains("FINAL-TAIL"))
                XCTAssertEqual(lab.outputDrainComplete, true)
                try await lab.stop()
                XCTAssertFalse(FileManager.default.fileExists(atPath: lab.root.path))
            } catch { try? await lab.stop(); throw error }
        }
    }

    func testNativePTYParsesRepliesAndCompletesNaturalDrainWhileMainActorIsBlocked() async throws {
        var publications = 0
        let lab = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in publications += 1 }
        let program = """
        import os, tty
        tty.setraw(0)
        def reply():
            data = b''
            while not data.endswith(b'R'): data += os.read(0, 32)
            return data
        os.write(1, b'\\x1b[6n')
        if reply() != b'\\x1b[1;1R': os._exit(91)
        text = b'PTY-MAIN-BLOCKED'
        os.write(1, text + b'\\x1b[6n')
        if reply() != b'\\x1b[1;' + str(len(text) + 1).encode() + b'R': os._exit(92)
        os._exit(27)
        """
        do {
            try lab.start(viewport: viewport, executable: "/usr/bin/python3", args: ["-c", program])
            // Intentionally no actor yield: parsing/replies/reap are not UI
            // work. The second DSR also proves the literal tail was parsed
            // before child exit, without a production delay or byte rewrite.
            for _ in 0..<500 {
                if lab.state == .exited(27) { break }
                usleep(10_000)
            }
            XCTAssertEqual(publications, 0)
            XCTAssertEqual(lab.state, .exited(27))
            XCTAssertEqual(lab.outputDrainComplete, true)
            XCTAssertTrue(try text(lab).contains("PTY-MAIN-BLOCKED"))
            try await lab.stop()
        } catch { try? await lab.stop(); throw error }
    }

    func testCoalescedCloseEscalatesOnlyTheOwnedIgnoringChildAndReapsIt() async throws {
        let lab = try NativeLocalPTYLab(driver: GhosttyVTDriver()) { _ in }
        do {
            try lab.start(viewport: viewport, args: ["-c", "trap '' HUP TERM; printf 'TRAPS-READY\\n'; while :; do :; done"])
            try await waitFor("owned traps ready") { try self.text(lab).contains("TRAPS-READY") }
            let pid = try XCTUnwrap(lab.processInfo?.shellPid)
            async let a: Void = lab.stop()
            async let b: Void = lab.stop()
            try await a; try await b
            XCTAssertNil(lab.processInfo); XCTAssertEqual(lab.state, .exited(nil))
            var status: Int32 = 0
            XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1); XCTAssertEqual(errno, ECHILD)
            XCTAssertFalse(FileManager.default.fileExists(atPath: lab.root.path))
        } catch { try? await lab.stop(); throw error }
    }
}

private final class PTYExitProbe: LocalProcessDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?
    private let onExit: @Sendable () -> Void
    init(onExit: @escaping @Sendable () -> Void) { self.onExit = onExit }
    var status: Int32? { lock.withLock { code } }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { lock.withLock { code = exitCode }; onExit() }
    func dataReceived(slice: ArraySlice<UInt8>) {}
    func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 640, ws_ypixel: 384) }
}
