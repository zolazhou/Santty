import AppKit
import GhosttyVt
import XCTest
@testable import SanttyTerminalLab

@MainActor
final class NativeHerdrSessionTests: XCTestCase {
    private func waitFor(_ stage: String = "private test session", _ condition: @escaping @MainActor () throws -> Bool) async throws {
        for _ in 0..<500 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(stage)")
        throw HerdrCoreError("Test timed out: \(stage)", kind: "test")
    }

    private func hasText(_ needle: String, in driver: GhosttyVTDriver) throws -> Bool {
        let total = try driver.totalRows
        let frame = try driver.snapshot(topRow: max(0, total - driver.rows))
        return frame.rows.values.contains { $0.cells.compactMap(\.text).joined().contains(needle) }
    }

    func testPrivateHerdrClipboardOffersAndLinksDrainAndDoNotReplayOnReconnect() async throws {
        let driver = try GhosttyVTDriver(columns: 120, rows: 30)
        let lab: NativeHerdrLab
        do { lab = try NativeHerdrLab(driver: driver) { _ in } }
        catch let error as HerdrCoreError where error.kind == "not_installed" { throw XCTSkip("hc is required") }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("unchanged", forType: .string)
        var resets = 0
        lab.session.onReset = { resets += 1 }
        do {
            try await lab.start(viewport: .init(columns: 120, rows: 30))
            try await waitFor { lab.session.state == .live }
            let binding = try XCTUnwrap(lab.session.binding)
            XCTAssertTrue(try lab.output.sendText(#"printf '\033]52;c;b2ZmZXJlZA==\007\033]8;;https://example.com/private\033\\private-link\033]8;;\033\\\n'"# + "\r"))
            try await waitFor("private clipboard offer") { lab.output.clipboardOffer?.payload == .text("offered") }
            let id = try XCTUnwrap(lab.output.clipboardOffer?.id)
            let frame = try driver.snapshot(topRow: max(0, driver.totalRows - driver.rows))
            XCTAssertTrue(frame.rows.values.contains { $0.cells.contains { $0.hyperlink == "https://example.com/private" } })
            XCTAssertEqual(pasteboard.string(forType: .string), "unchanged")
            // More than the stream's initial credit, while approval stays pending.
            XCTAssertTrue(try lab.output.sendText(#"awk 'BEGIN{for(i=0;i<3000;i++) print "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnop"; print "COPY-CREDIT-DONE"}'"# + "\r"))
            try await waitFor("output drains without clipboard approval") { try self.hasText("COPY-CREDIT-DONE", in: driver) }
            XCTAssertEqual(lab.output.clipboardOffer?.id, id)
            try await lab.reconnect()
            try await waitFor("clipboard reconnect") { lab.session.state == .live && resets >= 2 }
            XCTAssertEqual(lab.session.binding, binding)
            XCTAssertFalse(NativeClipboardReview.copy(id: id, output: lab.output, to: pasteboard))
            XCTAssertEqual(pasteboard.string(forType: .string), "unchanged")
            XCTAssertTrue(try lab.output.sendText(#"printf '\033]52;c;ZnJlc2g=\007'"# + "\r"))
            try await waitFor("fresh clipboard offer") { lab.output.clipboardOffer?.payload == .text("fresh") }
            let fresh = try XCTUnwrap(lab.output.clipboardOffer?.id)
            XCTAssertTrue(NativeClipboardReview.copy(id: fresh, output: lab.output, to: pasteboard))
            XCTAssertEqual(pasteboard.string(forType: .string), "fresh")
            try await lab.stop()
        } catch {
            try? await lab.stop()
            throw error
        }
    }

    func testShiftColonEntersCommandLineInPrivateCleanNeovim() async throws {
        try await checkCleanNeovimCommandLine(paste: false)
    }

    func testBracketedPasteExecutesInPrivateCleanNeovimCommandLine() async throws {
        try await checkCleanNeovimCommandLine(paste: true)
    }

    func testBracketedPasteIsLiteralTextInPrivateCleanNeovimNormalMode() async throws {
        try await checkCleanNeovimCommandLine(paste: true, bufferMode: "normal")
    }

    func testBracketedPasteIsLiteralTextInPrivateCleanNeovimInsertMode() async throws {
        try await checkCleanNeovimCommandLine(paste: true, bufferMode: "insert")
    }

    func testMouseClickAndWheelReachPrivateCleanNeovim() async throws {
        try await checkCleanNeovimCommandLine(paste: false, mouse: true)
    }

    private func checkCleanNeovimCommandLine(paste: Bool, bufferMode: String? = nil, mouse: Bool = false) async throws {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let nvim = paths.map({ URL(fileURLWithPath: $0).appendingPathComponent("nvim") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw XCTSkip("nvim is required") }
        let driver = try GhosttyVTDriver(columns: 120, rows: 30)
        let lab: NativeHerdrLab
        do { lab = try NativeHerdrLab(driver: driver) { _ in } }
        catch let error as HerdrCoreError where error.kind == "not_installed" { throw XCTSkip("hc is required") }
        let trace = lab.root.appendingPathComponent("nvim-command-trace")
        let wire = ControlInputBytes()
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func vimString(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        do {
            try await lab.start(viewport: .init(columns: 120, rows: 30))
            try await waitFor { lab.session.state == .live }
            let ready = lab.root.appendingPathComponent("nvim-ready")
            let result = lab.root.appendingPathComponent("nvim-command-result")
            let entered = lab.root.appendingPathComponent("nvim-command-line-entered")
            let onCommandLine = "autocmd CmdlineEnter : call timer_start(0, {-> writefile(['entered'], \(vimString(entered.path)))})"
            let startup = "autocmd VimEnter * call writefile(['ready'], \(vimString(ready.path)))"
            let buffer = lab.root.appendingPathComponent("nvim-buffer")
            let insert = lab.root.appendingPathComponent("nvim-insert-entered")
            let onBuffer = "autocmd TextChanged,TextChangedI * call writefile(getline(1,'$'), \(vimString(buffer.path)))"
            let onInsert = "autocmd InsertEnter * call timer_start(0, {-> writefile(['insert'], \(vimString(insert.path)))})"
            let cursor = lab.root.appendingPathComponent("nvim-mouse-cursor")
            let scroll = lab.root.appendingPathComponent("nvim-mouse-scroll")
            let mouseSetup = ["set mouse=a", "call setline(1, map(range(1,200), {_,n -> 'row-'.n}))",
                "autocmd CursorMoved * call writefile([string(line('.')),string(col('.'))], \(vimString(cursor.path)))",
                "autocmd WinScrolled * call writefile([string(line('w0'))], \(vimString(scroll.path)))"]
            let commandTrace = "autocmd CmdlineChanged : call writefile([getcmdline()], \(vimString(trace.path)))"
            let args = ([startup, onCommandLine, onBuffer, onInsert, commandTrace] + (mouse ? mouseSetup : [])).map { "--cmd " + quote($0) }.joined(separator: " ")
            XCTAssertTrue(try lab.output.sendText("\(quote(nvim.path)) --clean -n -i NONE \(args)\r"))
            try await waitFor("private clean nvim ready") { FileManager.default.fileExists(atPath: ready.path) }
            let session = lab.session!
            lab.output.bind(writer: { data in wire.append(data); session.writeInput(data) })
            let view = NativeTerminalInputView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
            view.output = lab.output
            view.inputEnabled = true
            if mouse {
                try await waitFor("nvim mouse protocol ready") { try driver.pointerModes.tracking && driver.renderHoldRemaining == nil }
                let modes = try driver.pointerModes
                let click = NativeMouseInput(action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_LEFT,
                    modifiers: 0, position: CGPoint(x: 15, y: 25), cell: CGSize(width: 10, height: 20), scale: 1,
                    anyButton: true, modes: modes)
                XCTAssertTrue(try lab.output.send(.mouse(click)))
                let release = NativeMouseInput(action: GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_LEFT,
                    modifiers: 0, position: click.position, cell: click.cell, scale: 1, anyButton: false, modes: modes)
                XCTAssertTrue(try lab.output.send(.mouse(release)))
                try await waitFor("nvim accepted mouse click") { (try? String(contentsOf: cursor, encoding: .utf8)) == "2\n2\n" }
                try await waitFor("nvim redraw completed") { driver.renderHoldRemaining == nil }
                XCTAssertTrue(try lab.output.send(.wheel(.init(route: .mouse, x: 0, y: -3, mouse: click))))
                try await waitFor("nvim accepted mouse wheel") {
                    let text = try? String(contentsOf: scroll, encoding: .utf8)
                    return Int(text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 > 1
                }
                try await lab.stop()
                return
            }
            if let bufferMode {
                if bufferMode == "insert" {
                    let i = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                        characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34))
                    view.keyDown(with: i)
                    try await waitFor("nvim insert event loop ready") { FileManager.default.fileExists(atPath: insert.path) }
                }
                let payload = ":q! 中文\nsecond-line"
                XCTAssertTrue(try driver.keyboardModes.bracketedPaste)
                XCTAssertTrue(try lab.output.paste(payload))
                try await waitFor("nvim literal paste in \(bufferMode)") {
                    (try? String(contentsOf: buffer, encoding: .utf8)) == payload + "\n"
                }
                XCTAssertEqual(lab.session.state, .live)
                try await lab.stop()
                return
            }
            let colon = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil,
                characters: ":", charactersIgnoringModifiers: ":", isARepeat: false, keyCode: 41))
            XCTAssertFalse(FileManager.default.fileExists(atPath: entered.path))
            view.keyDown(with: colon)
            try await waitFor("Shift-colon entered nvim command line") { FileManager.default.fileExists(atPath: entered.path) }
            let command = "call writefile(['command-executed'], \(vimString(result.path)))"
            if paste {
                XCTAssertTrue(try driver.keyboardModes.bracketedPaste)
                XCTAssertTrue(try lab.output.paste(command))
                let expectedWire = Data("\u{1b}[200~\(command)\u{1b}[201~".utf8)
                XCTAssertNotNil(wire.data.range(of: expectedWire), "native input sends the actual bracketed paste")
                // Nvim 0.12's vim.paste queues nvim_feedkeys in command mode.
                // A CR already in typeahead can execute before those keys.
                // Wait for the consumer's applied text, not a guessed delay.
                try await waitFor("nvim command-line paste applied") {
                    (try? String(contentsOf: trace, encoding: .utf8)) == command + "\n"
                }
            }
            else { view.insertText(command, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            view.keyDown(with: enter)
            try await waitFor("Shift-colon command executed by nvim") { FileManager.default.fileExists(atPath: result.path) }
            XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "command-executed\n")
            try await lab.stop()
        } catch {
            try? await lab.stop()
            throw error
        }
    }

    func testAppKitControlCInterruptsForegroundProgramInPrivateShell() async throws {
        let driver = try GhosttyVTDriver(columns: 120, rows: 30)
        let lab: NativeHerdrLab
        do { lab = try NativeHerdrLab(driver: driver) { _ in } }
        catch let error as HerdrCoreError where error.kind == "not_installed" { throw XCTSkip("hc is required") }
        do {
            try await lab.start(viewport: .init(columns: 120, rows: 30))
            try await waitFor { lab.session.state == .live }
            let view = NativeTerminalInputView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
            let sent = ControlInputBytes()
            let session = lab.session!
            let input = NativeTerminalOutput(driver: driver) { _ in }
            input.bind(writer: { data in sent.append(data); session.writeInput(data) })
            input.setInputEnabled(true)
            view.output = input
            view.inputEnabled = true
            XCTAssertTrue(try lab.output.sendText(#"sh -c 'trap '\''printf "NATIVE-INT-%s\n" CAUGHT; exit 0'\'' INT; printf "NATIVE-INT-%s\n" READY; while :; do sleep 1; done'"# + "\r"))
            try await waitFor("foreground program ready") { try self.hasText("NATIVE-INT-READY", in: driver) }
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil,
                characters: "\u{3}", charactersIgnoringModifiers: "\u{3}", isARepeat: false, keyCode: 8))
            view.keyDown(with: event)
            XCTAssertEqual(Array(sent.data), [3], "AppKit must send ETX, not CSI 3;5u, to the private shell")
            try await waitFor("foreground program caught SIGINT") { try self.hasText("NATIVE-INT-CAUGHT", in: driver) }
            XCTAssertTrue(try lab.output.sendText("printf 'NATIVE-INT-%s\\n' RETURNED\r"))
            try await waitFor("shell usable after SIGINT") { try self.hasText("NATIVE-INT-RETURNED", in: driver) }
            try await lab.stop()
        } catch {
            try? await lab.stop()
            throw error
        }
    }

    func testQuitRacingPrivateCoreStartupCoalescesCleanup() async throws {
        let lab: NativeHerdrLab
        do { lab = try NativeHerdrLab(driver: GhosttyVTDriver()) { _ in } }
        catch let error as HerdrCoreError where error.kind == "not_installed" {
            throw XCTSkip("hc is required")
        }
        let start = Task { try await lab.start(viewport: .init(columns: 80, rows: 24)) }
        // Let start enter its connection await, then race two independent
        // close callers (window quit and the explicit end-session action).
        await Task.yield()
        let first = Task { try await lab.stop() }
        let second = Task { try await lab.stop() }
        _ = try? await start.value
        try await first.value
        try await second.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: lab.root.path))
    }

    func testRealPrivateHerdrOutputInputCreditReconnectAndViewerClose() async throws {
        let driver = try GhosttyVTDriver(columns: 120, rows: 30)
        let lab: NativeHerdrLab
        do { lab = try NativeHerdrLab(driver: driver) { _ in } }
        catch let error as HerdrCoreError where error.kind == "not_installed" {
            throw XCTSkip("hc is required for the private real-core test")
        }
        do {
            var stateChanges: [HerdrTerminalSession.State] = []
            lab.onStateChange = { stateChanges.append($0) }
            try await lab.start(viewport: .init(columns: 120, rows: 30, cellWidthPixels: 8, cellHeightPixels: 16))
            try await waitFor { lab.session.state == .live }
            let binding = try XCTUnwrap(lab.session.binding)
            XCTAssertTrue(lab.root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
            XCTAssertNotEqual(lab.root.path, FileManager.default.homeDirectoryForCurrentUser.path)
            XCTAssertTrue(try lab.output.sendText("printf 'NATIVE-%s\\n' OK\r"))
            try await waitFor { try self.hasText("NATIVE-OK", in: driver) }
            XCTAssertTrue(try driver.snapshot(topRow: max(0, driver.totalRows - driver.rows)).cursor.visible,
                          "The real private shell must leave its cursor visible")
            XCTAssertTrue(try lab.output.sendText(#"printf 'NATIVE-HOME:%s\nNATIVE-SOCKET:%s\n' "$HOME" "${SANTTY_CONTROL_SOCKET-unset}""# + "\r"))
            try await waitFor { try self.hasText("NATIVE-HOME:" + lab.root.appendingPathComponent("home").path, in: driver) }
            XCTAssertTrue(try self.hasText("NATIVE-SOCKET:unset", in: driver))
            let stateCount = stateChanges.count
            XCTAssertTrue(try lab.output.sendText(#"printf '\033]2;NATIVE-%s\007' TITLE"# + "\r"))
            try await waitFor { lab.session.record?.title == "NATIVE-TITLE" }
            XCTAssertEqual(stateChanges.count, stateCount, "metadata refresh must not trigger focus-restoring state callbacks")

            // More than the stream's initial credit: progress must follow
            // parsing even though no renderer/frame source is attached.
            XCTAssertTrue(try lab.output.sendText("awk 'BEGIN { for(i=0;i<8000;i++) print i \" " + String(repeating: "x", count: 70) + "\"; print \"NATIVE-BURST-\" \"END\" }'\r"))
            try await waitFor { try self.hasText("NATIVE-BURST-END", in: driver) }
            XCTAssertGreaterThanOrEqual(try driver.totalRows, 6000)

            lab.updateViewport(.init(columns: 100, rows: 28, cellWidthPixels: 9, cellHeightPixels: 18))
            try driver.resize(columns: 100, rows: 28, cellWidth: 9, cellHeight: 18)
            try await waitFor {
                let record = lab.session.record
                return record?.cols == 100 && record?.rows == 28
            }

            let connection = try await lab.client.connection()
            struct List: Decodable, Sendable { let terminals: [HerdrCoreTerminal] }
            let before: List = try await HerdrCoreClient.request(connection, "terminal.list", ["all": true])

            // Core identity mismatch fails without inventing a replacement.
            let invalidDriver = try GhosttyVTDriver()
            let bad = HerdrTerminalSession(paneID: UUID(), cwd: nil,
                binding: .init(coreID: "not-the-core", address: binding.address),
                viewerOnly: true, client: lab.client,
                outputFactory: { _, _ in NativeTerminalOutput(driver: invalidDriver) { _ in } })
            bad.updateViewport(.init(columns: 100, rows: 28))
            bad.surfaceAttached(); bad.start()
            try await waitFor { if case .failed = bad.state { return true }; return false }
            try await bad.closeTerminal()
            let after: List = try await HerdrCoreClient.request(connection, "terminal.list", ["all": true])
            XCTAssertEqual(before.terminals.map(\.address).sorted(), after.terminals.map(\.address).sorted())

            let viewerDriver = try GhosttyVTDriver(columns: 100, rows: 28)
            let viewer = HerdrTerminalSession(paneID: UUID(), cwd: nil, binding: binding,
                viewerOnly: true, client: lab.client, outputFactory: { write, _ in
                    let output = NativeTerminalOutput(driver: viewerDriver) { _ in }
                    output.bind(writer: write)
                    return output
                })
            viewer.updateViewport(.init(columns: 100, rows: 28))
            viewer.surfaceAttached(); viewer.start()
            try await waitFor { viewer.state == .live }
            try await viewer.closeTerminal()
            let stillRunning = try await lab.client.terminal(binding)
            XCTAssertEqual(stillRunning.state, "live")

            try await lab.reconnect()
            try await waitFor { lab.session.state == .live }
            XCTAssertEqual(lab.session.binding, binding)
            XCTAssertTrue(try lab.output.sendText("printf 'RECONNECTED-%s\\n' OK\r"))
            try await waitFor { try self.hasText("RECONNECTED-OK", in: driver) }
            XCTAssertTrue(try driver.snapshot(topRow: max(0, driver.totalRows - driver.rows)).cursor.visible,
                          "Reconnect must restore the shell cursor")
            try await lab.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: lab.root.path))
        } catch {
            try? await lab.stop()
            throw error
        }
    }
}

private final class ControlInputBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var data: Data { lock.withLock { bytes } }
}
