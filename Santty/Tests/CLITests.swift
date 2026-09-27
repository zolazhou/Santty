import AppKit
import GhosttyTerminal
import XCTest

@testable import Santty

final class CLITests: XCTestCase {
    func testSearchThenReadUsesTheSameLineNumbers() throws {
        let text = "ready\nError: first\n\nerror: second\nregex.* is literal\n完成\n"
        let paneID = UUID()
        let search = try CLITextSnapshot.response(
            text,
            request: CLIRequest(
                command: "search", paneID: paneID, query: "error", ignoreCase: true, limit: 1))
        XCTAssertEqual(search.matches?.map(\.line), [2])
        XCTAssertEqual(search.matches?.first?.text, "Error: first")
        XCTAssertEqual(search.totalMatches, 2)
        XCTAssertEqual(search.totalLines, 6)
        XCTAssertEqual(search.truncated, true)

        let range = try CLITextSnapshot.response(
            text,
            request: CLIRequest(
                command: "read", paneID: paneID, startLine: 2, endLine: 4))
        XCTAssertEqual(range.text, "Error: first\n\nerror: second")
        XCTAssertEqual(range.startLine, 2)
        XCTAssertEqual(range.endLine, 4)
        XCTAssertEqual(range.totalLines, search.totalLines)
        XCTAssertEqual(range.truncated, false)
        let tail = try CLITextSnapshot.response(
            text,
            request: CLIRequest(
                command: "read", paneID: paneID, tail: 2))
        XCTAssertEqual(tail.startLine, 5)
        XCTAssertEqual(tail.endLine, 6)
        let literal = try CLITextSnapshot.response(
            text,
            request: CLIRequest(
                command: "search", paneID: paneID, query: ".*"))
        XCTAssertEqual(literal.matches?.map(\.line), [5])
        let sensitive = try CLITextSnapshot.response(
            text,
            request: CLIRequest(
                command: "search", paneID: paneID, query: "error"))
        XCTAssertEqual(sensitive.matches?.map(\.line), [4])
        let missing = try CLITextSnapshot.response(
            text,
            request: CLIRequest(
                command: "search", paneID: paneID, query: "missing"))
        XCTAssertEqual(missing.matches?.count, 0)
        XCTAssertEqual(missing.totalMatches, 0)
        XCTAssertEqual(missing.truncated, false)
    }

    func testRangesAndSearchRespectBoundaries() throws {
        let paneID = UUID()
        let empty = try CLITextSnapshot.response(
            "",
            request: CLIRequest(
                command: "search", paneID: paneID, query: "x"))
        XCTAssertEqual(empty.totalLines, 0)
        let clamped = try CLITextSnapshot.response(
            "one\ntwo",
            request: CLIRequest(
                command: "read", paneID: paneID, startLine: 2, endLine: 100))
        XCTAssertEqual(clamped.text, "two")
        XCTAssertEqual(clamped.endLine, 2)
        XCTAssertThrowsError(
            try CLITextSnapshot.response(
                "one",
                request: CLIRequest(
                    command: "read", paneID: paneID, startLine: 2, endLine: 3)))
        for request in [
            CLIRequest(command: "read", paneID: paneID, startLine: 0, endLine: 3),
            CLIRequest(command: "read", paneID: paneID, startLine: 3, endLine: 2),
            CLIRequest(command: "read", paneID: paneID, startLine: 1),
            CLIRequest(command: "read", paneID: paneID, startLine: 1, endLine: Int.max),
            CLIRequest(command: "read", paneID: paneID, tail: 5, startLine: 1, endLine: 3),
            CLIRequest(command: "search", paneID: paneID, query: ""),
            CLIRequest(command: "search", paneID: paneID, query: "a\nb"),
            CLIRequest(command: "search", paneID: paneID, query: "x", limit: 0),
            CLIRequest(command: "list", startLine: 1, endLine: 2),
        ] {
            XCTAssertThrowsError(try request.validate())
        }
        let huge = "x" + String(repeating: "😀", count: 100_000)
        let search = try CLITextSnapshot.response(
            huge + "\nx",
            request: CLIRequest(
                command: "search", paneID: paneID, query: "x"))
        XCTAssertEqual(search.totalMatches, 2)
        XCTAssertEqual(search.matches?.count, 1)
        XCTAssertEqual(search.matches?.first?.truncated, true)
        XCTAssertEqual(search.truncated, true)
        let range = try CLITextSnapshot.response(
            huge,
            request: CLIRequest(
                command: "read", paneID: paneID, startLine: 1, endLine: 1))
        XCTAssertEqual(range.text, search.matches?.first?.text)
        XCTAssertLessThanOrEqual(try XCTUnwrap(range.text).utf8.count, CLITextSnapshot.maximumBytes)
        XCTAssertFalse(try XCTUnwrap(range.text).contains("�"))
        XCTAssertEqual(range.startLine, 1)
        XCTAssertEqual(range.endLine, 1)
        XCTAssertEqual(range.truncated, true)
    }

    func testLimitsPreserveBlankLinesAndUnicode() throws {
        let response = try CLITextSnapshot.response(
            "old\n中文\n\nlast\n\n", request: CLIRequest(command: "read", paneID: UUID(), tail: 3))
        XCTAssertEqual(response.text, "中文\n\nlast")
        XCTAssertEqual(response.truncated, true)
        let large = try CLITextSnapshot.response(
            String(repeating: "😀", count: 100_000),
            request: CLIRequest(command: "read", paneID: UUID(), tail: 1))
        XCTAssertLessThanOrEqual(try XCTUnwrap(large.text).utf8.count, CLITextSnapshot.maximumBytes)
        XCTAssertFalse(try XCTUnwrap(large.text).contains("�"))
        XCTAssertEqual(large.truncated, true)
        XCTAssertEqual(
            try CLITextSnapshot.response(
                "", request: CLIRequest(command: "read", paneID: UUID(), tail: 1)
            ).text, "")
        XCTAssertThrowsError(try CLIRequest(command: "read", paneID: UUID(), tail: 0).validate())
        XCTAssertThrowsError(
            try CLIRequest(command: "read", paneID: UUID(), tail: 10_001).validate())
        XCTAssertThrowsError(try CLIRequest(command: "read").validate())
        XCTAssertThrowsError(try CLIRequest(command: "execute").validate())
    }

    @MainActor
    func testListsInactiveTabsAndRejectsUnknownOrBrowserPanesWithoutChangingFocus() throws {
        let workspace = WorkspaceViewController()
        _ = workspace.view
        workspace.debugNewTab()
        let selected = workspace.debugSelectedTabID
        let pane = try XCTUnwrap(workspace.debugFocusedPaneID)
        workspace.debugPerformCommand(withID: "pane.browser.convert")
        let response = try workspace.handleCLIRequest(CLIRequest(command: "list"))
        XCTAssertEqual(response.tabs?.count, 2)
        XCTAssertEqual(response.tabs?.filter(\.isSelected).count, 1)
        XCTAssertThrowsError(
            try workspace.handleCLIRequest(CLIRequest(command: "read", paneID: pane)))
        XCTAssertThrowsError(
            try workspace.handleCLIRequest(CLIRequest(command: "read", paneID: UUID())))
        XCTAssertEqual(workspace.debugSelectedTabID, selected)
        XCTAssertEqual(workspace.debugFocusedPaneID, pane)
    }

    func testInstallIsIdempotentAndProtectsExistingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Santty.app")
        let helper = app.appendingPathComponent("Contents/Helpers/santty")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try CLIInstaller.install(appURL: app, homeURL: root)
        try CLIInstaller.install(appURL: app, homeURL: root)
        let link = root.appendingPathComponent(".local/bin/santty")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path), helper.path)
        try FileManager.default.removeItem(at: link)
        try Data("keep".utf8).write(to: link)
        XCTAssertThrowsError(try CLIInstaller.install(appURL: app, homeURL: root))
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "keep")
    }

    @MainActor
    func testBundledCLIConnectsToWorkspace() async throws {
        let server = CLIControlServer.shared
        let previousWorkspace = server.workspace
        let defaults = UserDefaults.standard
        let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previousArguments
        arguments["cliAccessEnabled"] = true
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let workspace = WorkspaceViewController()
        _ = workspace.view
        server.workspace = workspace
        server.start()
        defer {
            server.stop()
            server.workspace = previousWorkspace
            defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
            server.start()
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/santty")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        let path = CLITransport.socketPath
        func run(_ cliArguments: [String]) async throws -> (Int32, Data, Data) {
            try await Task.detached {
                let process = Process()
                process.executableURL = helper
                process.arguments = cliArguments + ["--socket", path]
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (
                    process.terminationStatus, data,
                    errors.fileHandleForReading.readDataToEndOfFile()
                )
            }.value
        }
        let result = try await run(["list", "--json"])
        XCTAssertEqual(result.0, 0, String(decoding: result.2, as: UTF8.self))
        guard result.0 == 0 else { return }
        let response = try JSONDecoder().decode(CLIResponse.self, from: result.1)
        XCTAssertEqual(response.tabs?.first?.id, workspace.debugSelectedTabID)
        XCTAssertEqual(response.tabs?.first?.panes.first?.id, workspace.debugFocusedPaneID)
        for args in [
            ["read", UUID().uuidString, "--start-line", "2", "--end-line", "4"],
            ["search", UUID().uuidString, "error", "--ignore-case", "--limit", "5"],
        ] {
            let failure = try await run(args)
            XCTAssertEqual(failure.0, 1)
            XCTAssertTrue(String(decoding: failure.2, as: UTF8.self).contains("Pane not found"))
        }
        let invalid = try await run([
            "read", UUID().uuidString, "--tail", "5", "--start-line", "1", "--end-line", "3",
        ])
        XCTAssertEqual(invalid.0, 1)
        XCTAssertTrue(String(decoding: invalid.2, as: UTF8.self).contains("cannot be combined"))

    }

    @MainActor
    func testGhosttySnapshotIncludesScrollbackAndDoesNotChangeViewportOrClipboard() async throws {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            throw XCTSkip("Ghostty's Metal renderer requires a logged-in graphical display.")
        }
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        terminal.controller = TerminalController(configuration: TerminalDefaults.configuration)
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        let window = NSWindow(
            contentRect: terminal.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = terminal
        defer { window.contentView = nil }
        terminal.fitToSize()
        session.receive((1...120).map { "server-log-\($0)\r\n" }.joined())
        for _ in 0..<100 {
            if terminal.readScreenText()?.contains("server-log-120") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let viewport = session.readViewportText()
        let clipboardChangeCount = NSPasteboard.general.changeCount
        let text = try XCTUnwrap(terminal.readScreenText())
        XCTAssertTrue(
            text.contains("server-log-1\n"), "Expected retained history: \(text.prefix(200))")
        XCTAssertTrue(text.contains("server-log-120"))
        XCTAssertFalse(viewport?.contains("server-log-1\n") ?? true)
        XCTAssertEqual(session.readViewportText(), viewport)
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardChangeCount)
        XCTAssertTrue(
            try CLITextSnapshot.response(
                text, request: CLIRequest(command: "read", paneID: UUID(), tail: 3)
            ).text?.contains("server-log-120") == true)
    }
}
