import AppKit
import GhosttyVt
import XCTest
@testable import Santty

@MainActor
final class NativeTmuxSessionTests: XCTestCase {
    private func wait(_ stage: String, _ condition: () throws -> Bool) async throws {
        for _ in 0..<800 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Private tmux timed out: \(stage)")
        throw HerdrCoreError("Private tmux fixture timed out", kind: "test")
    }

    func testMouseSelectsPaneAndWheelEntersCopyModeInOwnedTmuxServer() async throws {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let tmux = paths.map({ URL(fileURLWithPath: $0).appendingPathComponent("tmux") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw XCTSkip("tmux is required") }
        let driver = try GhosttyVTDriver(columns: 120, rows: 30)
        let lab: NativeHerdrTestSession
        do { lab = try NativeHerdrTestSession(driver: driver) { _ in } }
        catch let error as HerdrCoreError where error.kind == "not_installed" { throw XCTSkip("hc is required") }
        let socket = lab.root.appendingPathComponent("tmux.sock")
        let selected = lab.root.appendingPathComponent("tmux-selected")
        let copied = lab.root.appendingPathComponent("tmux-copy-mode")
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let environment = ["HOME": lab.root.appendingPathComponent("home").path, "SHELL": "/bin/sh",
                           "PATH": tmux.deletingLastPathComponent().path + ":/usr/bin:/bin", "TERM": "xterm-256color"]
        func command(_ args: [String]) async throws -> String {
            try await Task.detached {
                let process = Process(), pipe = Pipe()
                process.executableURL = tmux; process.arguments = ["-S", socket.path] + args
                process.environment = environment; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
                defer { timeout.cancel() }
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw HerdrCoreError("Owned tmux command failed", kind: "test") }
                return String(decoding: data, as: UTF8.self)
            }.value
        }
        do {
            XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
            _ = try await command(["-f", "/dev/null", "new-session", "-d", "-s", "native-fixture", "-x", "120", "-y", "30"])
            guard FileManager.default.fileExists(atPath: socket.path) else {
                throw HerdrCoreError("Owned tmux socket was not created", kind: "isolation")
            }
            _ = try await command(["set-option", "-g", "mouse", "on"])
            _ = try await command(["split-window", "-h", "-t", "native-fixture"])
            _ = try await command(["set-hook", "-g", "after-select-pane", "run-shell \"printf '#{pane_index}' > \(selected.path)\""])
            _ = try await command(["set-hook", "-g", "after-copy-mode", "run-shell \"printf 'copy' > \(copied.path)\""])
            try await lab.start(viewport: .init(columns: 120, rows: 30))
            try await wait("core live") { lab.session.state == .live }
            XCTAssertTrue(try lab.output.sendText("\(quote(tmux.path)) -S \(quote(socket.path)) attach-session -t native-fixture\r"))
            try await wait("tmux mouse ready") { try driver.pointerModes.tracking && driver.renderHoldRemaining == nil }
            let active = try await command(["display-message", "-p", "-t", "native-fixture", "#{pane_index}"])
            XCTAssertEqual(active.trimmingCharacters(in: .whitespacesAndNewlines), "1")
            let mouse = NativeMouseInput(action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_LEFT,
                modifiers: 0, position: CGPoint(x: 15, y: 25), cell: CGSize(width: 10, height: 20), scale: 1,
                anyButton: true, modes: try driver.pointerModes)
            XCTAssertTrue(try lab.output.send(.mouse(mouse)))
            let release = NativeMouseInput(action: GHOSTTY_MOUSE_ACTION_RELEASE, button: mouse.button,
                modifiers: 0, position: mouse.position, cell: mouse.cell, scale: 1, anyButton: false, modes: mouse.modes)
            XCTAssertTrue(try lab.output.send(.mouse(release)))
            try await wait("tmux selected left pane") { (try? String(contentsOf: selected, encoding: .utf8)) == "0" }
            _ = try await command(["send-keys", "-t", "native-fixture:0.0", "seq 1 100", "Enter"])
            // Wait for that pane's output rather than relying on a fixed delay.
            try await wait("tmux output parsed") {
                let frame = try driver.snapshot(topRow: max(0, driver.totalRows - driver.rows))
                return frame.rows.values.contains { $0.cells.compactMap(\.text).joined().contains("100") }
                    && driver.renderHoldRemaining == nil
            }
            XCTAssertTrue(try lab.output.send(.wheel(.init(route: .mouse, x: 0, y: 3, mouse: mouse))))
            try await wait("tmux entered copy mode") { (try? String(contentsOf: copied, encoding: .utf8)) == "copy" }
            _ = try await command(["kill-server"])
            try await lab.stop()
        } catch {
            _ = try? await command(["kill-server"])
            try? await lab.stop()
            throw error
        }
    }
}
