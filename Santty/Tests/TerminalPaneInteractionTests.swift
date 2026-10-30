import AppKit
@testable import GhosttyTerminal
import XCTest
@testable import Santty

@MainActor
final class TerminalPaneInteractionTests: XCTestCase {
    func testTerminalLinkValidation() {
        for text in ["", "relative/path", "https://", "https://example.com/\n", "https://exa mple.com"] {
            XCTAssertNil(TerminalPaneController.linkURL(text), text)
        }
        for text in ["https://example.com/path?q=1#anchor", "http://localhost:3000", "mailto:hello@example.com"] {
            XCTAssertEqual(TerminalPaneController.linkURL(text)?.absoluteString, text)
        }
        XCTAssertEqual(TerminalPaneController.linkURL("/tmp/a b.txt")?.path, "/tmp/a b.txt")
    }

    func testCommandClickOSC8LinkOpensThroughPane() async throws {
        var opened: [URL] = []
        let pane = TerminalPaneController(openURL: { opened.append($0); return true })
        let terminal = try XCTUnwrap(pane.hostView.subviews.compactMap { $0 as? TerminalView }.first)
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = pane.hostView
        defer { window.contentView = nil }
        pane.hostView.layoutSubtreeIfNeeded()
        terminal.fitToSize()
        session.receive("\u{1b}]8;;https://example.com\u{1b}\\click here\u{1b}]8;;\u{1b}\\\r\n")
        XCTAssertTrue(session.waitForPendingOutput())
        let grid = try XCTUnwrap(terminal.scrollModeGrid)
        let scale = window.backingScaleFactor
        let point = terminal.convert(NSPoint(x: 2 + CGFloat(grid.cellWidthPixels) * 4 / scale,
            y: terminal.bounds.height - 2 - CGFloat(grid.cellHeightPixels) / (2 * scale)), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { terminal.mouseDown(with: event) }
            else { terminal.mouseUp(with: event) }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com"])
    }

    func testSurfaceAttachUsesCurrentWindowOcclusion() {
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminal.controller = TerminalController(configuration: TerminalDefaults.configuration)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = terminal
        defer { window.contentView = nil }
        XCTAssertFalse(window.occlusionState.contains(.visible))
        XCTAssertFalse(terminal.core.testHooks_isWindowVisible)
        window.contentView = nil
        window.contentView = terminal
        XCTAssertFalse(terminal.core.testHooks_isWindowVisible)
    }

    func testPaneAttachmentReportsSurfaceVisibilityAcrossContainerChanges() {
        let terminal = RecordingTerminalView(frame: .zero)
        let host = TerminalPaneHostView(paneID: PaneID(), terminalView: terminal)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        container.addSubview(host)
        let window = NSWindow(contentRect: container.frame, styleMask: [], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        XCTAssertEqual(terminal.surfaceVisibility.last, false)

        window.contentView = container
        XCTAssertEqual(terminal.surfaceVisibility.last, true)
        window.contentView = nil
        XCTAssertEqual(terminal.surfaceVisibility.last, false)
        window.contentView = container
        XCTAssertEqual(terminal.surfaceVisibility.last, true)
    }

    func testDetachedPaneKeepsProcessingOutputAndRestoresScrollback() async throws {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let titles = DetachedPaneTitleRecorder()
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        terminal.delegate = titles
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminal.controller = TerminalController(configuration: TerminalDefaults.configuration)
        let host = TerminalPaneHostView(paneID: PaneID(), terminalView: terminal)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        terminal.fitToSize()
        XCTAssertNotNil(terminal.scrollModeGrid)
        window.contentView = nil

        // More title callbacks than the mailbox holds must drain even with no attached view.
        session.receive((1...500).map { "\u{1b}]2;title-\($0)\u{7}hidden-row-\($0)\r\n" }.joined())
        for _ in 0..<100 {
            if titles.title == "title-500" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(titles.title, "title-500")
        XCTAssertTrue(session.waitForPendingOutput())
        XCTAssertTrue(terminal.readScreenText()?.contains("hidden-row-500") == true)

        window.contentView = host
        host.layoutSubtreeIfNeeded()
        terminal.fitToSize()
        let restored = try XCTUnwrap(terminal.readScreenText())
        XCTAssertTrue(restored.contains("hidden-row-1\n"))
        XCTAssertTrue(restored.contains("hidden-row-500"))
    }

    func testPromptSubmissionPastesTextThenSendsEnter() async throws {
        let input = ScrollModeInputRecorder()
        let session = InMemoryTerminalSession(write: { input.append($0) }, resize: { _ in })
        let pane = TerminalPaneController()
        XCTAssertFalse(pane.submitPrompt("no surface"))
        let terminal = try XCTUnwrap(pane.hostView.subviews.compactMap { $0 as? TerminalView }.first)
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = pane.hostView
        defer { window.contentView = nil }
        pane.hostView.layoutSubtreeIfNeeded()
        terminal.fitToSize()
        session.receive("\u{1b}[?2004h")
        XCTAssertTrue(session.waitForPendingOutput())

        XCTAssertTrue(pane.submitPrompt("hello\nworld"))
        let expected = "\u{1b}[200~hello\nworld\u{1b}[201~\r"
        for _ in 0..<100 {
            if input.data.count >= expected.utf8.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(String(decoding: input.data, as: UTF8.self), expected)
    }

    func testScrollWordMotionsRespectPunctuationWhitespaceAndBufferBounds() {
        let lines = [Array("  foo_bar/path.txt  next"), [], Array(" final")]
        var cursor = ScrollModeCursor(cell: .init(column: 0, row: 0), viewport: 0,
                                      columns: 24, rows: 2, total: lines.count)
        let steps: [(TerminalScrollMovement, ScrollModeCell)] = [
            (.wordForward(big: false), .init(column: 2, row: 0)),
            (.wordEnd(big: false), .init(column: 8, row: 0)),
            (.wordForward(big: false), .init(column: 9, row: 0)),
            (.wordForward(big: false), .init(column: 10, row: 0)),
            (.wordEnd(big: false), .init(column: 13, row: 0)),
            (.wordEnd(big: true), .init(column: 17, row: 0)),
            (.wordBackward(big: false), .init(column: 15, row: 0)),
            (.wordBackward(big: false), .init(column: 14, row: 0)),
            (.wordBackward(big: true), .init(column: 2, row: 0)),
            (.wordForward(big: true), .init(column: 20, row: 0)),
            (.wordEnd(big: false), .init(column: 23, row: 0)),
            (.wordForward(big: false), .init(column: 1, row: 2)),
            (.wordBackward(big: false), .init(column: 20, row: 0)),
            (.firstNonblank, .init(column: 2, row: 0)),
            (.wordBackward(big: false), .init(column: 0, row: 0)),
            (.wordBackward(big: false), .init(column: 0, row: 0)),
            (.bottom, .init(column: 0, row: 2)),
            (.wordEnd(big: false), .init(column: 5, row: 2)),
            (.wordForward(big: false), .init(column: 23, row: 2)),
            (.wordEnd(big: false), .init(column: 23, row: 2)),
        ]
        for (movement, expected) in steps {
            cursor.move(movement) { cell in
                let line = lines[cell.row]
                return cell.column < line.count ? String(line[cell.column]) : ""
            }
            XCTAssertEqual(cursor.cell, expected, "\(movement)")
            XCTAssertTrue((cursor.viewport..<(cursor.viewport + cursor.rows)).contains(cursor.cell.row))
        }
        cursor.move(.firstNonblank) { _ in "" }
        XCTAssertEqual(cursor.cell.column, 0)
        cursor.move(.wordForward(big: false)) { _ in nil }
        XCTAssertEqual(cursor.cell.column, 0)
    }

    func testScrollCursorMovesAndRevealsHistoryWithoutLeavingGrid() {
        var cursor = ScrollModeCursor(cell: .init(column: 4, row: 50), viewport: 45,
                                      columns: 10, rows: 10, total: 100)
        cursor.move(.pageUp)
        XCTAssertEqual(cursor.cell, .init(column: 4, row: 40))
        XCTAssertEqual(cursor.viewport, 40)
        cursor.move(.top)
        cursor.move(.left)
        XCTAssertEqual(cursor.cell, .init(column: 0, row: 0))
        cursor.move(.bottom)
        XCTAssertEqual(cursor.viewport, 90)
        cursor.move(.lineEnd)
        cursor.move(.right)
        cursor.move(.down)
        XCTAssertEqual(cursor.cell, .init(column: 9, row: 99))
    }

    func testNativeScrollSelectionAcrossHistoryPreservesUnicodeAndDoesNotSendInput() async throws {
        let input = ScrollModeInputRecorder()
        let session = InMemoryTerminalSession(write: { input.append($0) }, resize: { _ in })
        let configuration = TerminalConfiguration(startingFrom: TerminalDefaults.configuration) { builder in
            builder.withCustom("mouse-reporting", "false")
            builder.withCustom("cursor-click-to-move", "false")
            builder.withCustom("copy-on-select", "false")
            builder.withCustom("link-url", "false")
        }
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminal.controller = TerminalController(configuration: configuration, theme: TerminalDefaults.theme)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = terminal
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        terminal.fitToSize()
        XCTAssertNotNil(terminal.scrollModeGrid)
        // All-motion mouse reporting must not forward synthetic selection gestures.
        let sample = "A中👩🏽‍💻e\u{301}Z"
        let words = "  foo_bar/path.txt  next"
        session.receive("\u{1b}[?1003h\u{1b}[?1006h\u{1b}[31m" + sample + "\u{1b}[0m\r\n"
                        + words + "\r\n"
                        + (1...60).map { "row \($0)\r\n" }.joined())
        for _ in 0..<100 {
            if terminal.scrollModeViewport?.total ?? 0 > 60 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let viewport = try XCTUnwrap(terminal.scrollModeViewport)
        XCTAssertGreaterThan(viewport.total, 60)
        let view = TerminalScrollModeView(terminalView: terminal)
        view.move(.top)
        view.move(.wordForward(big: false))
        XCTAssertEqual(view.cursor.cell, .init(column: 3, row: 0))
        view.move(.wordForward(big: false))
        XCTAssertEqual(view.cursor.cell, .init(column: 5, row: 0))
        view.move(.wordEnd(big: false))
        XCTAssertEqual(view.cursor.cell, .init(column: 6, row: 0))
        view.move(.down)
        view.move(.firstNonblank)
        XCTAssertEqual(view.cursor.cell, .init(column: 2, row: 1))
        view.toggleSelection(linewise: false)
        view.move(.wordForward(big: true))
        view.move(.wordEnd(big: false))
        XCTAssertEqual(terminal.readScrollModeSelection(), String(words.dropFirst(2)))
        XCTAssertTrue(view.cancelSelection())
        view.move(.top)
        view.move(.right)
        for _ in 0..<3 {
            view.toggleSelection(linewise: false)
            XCTAssertEqual(terminal.readScrollModeSelection(), "中")
            XCTAssertTrue(view.cancelSelection())
        }
        view.move(.top)
        view.toggleSelection(linewise: false)
        view.move(.pageDown)
        view.move(.pageDown)
        let selected = try XCTUnwrap(terminal.readScrollModeSelection())
        XCTAssertTrue(selected.hasPrefix(sample + "\n"))
        XCTAssertTrue(selected.contains("row 15"))
        let cursor = view.cursor
        let pasteboard = NSPasteboard(name: .init("SanttyScrollTests-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        view.copySelection(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), selected)
        let flashLayer = try XCTUnwrap(view.layer?.sublayers?.first)
        XCTAssertNotNil(flashLayer.animation(forKey: "copyFlash"))
        view.copySelection(to: pasteboard)
        XCTAssertEqual(flashLayer.animationKeys(), ["copyFlash"])
        XCTAssertEqual(view.cursor.cell, cursor.cell)
        XCTAssertEqual(view.cursor.viewport, cursor.viewport)
        XCTAssertEqual(terminal.readScrollModeSelection(), selected)
        _ = view.cancelSelection()
        flashLayer.removeAllAnimations()
        view.copySelection(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), selected)
        XCTAssertNil(flashLayer.animation(forKey: "copyFlash"))
        view.move(.bottom)
        view.toggleSelection(linewise: true)
        view.move(.top)
        let backwards = try XCTUnwrap(terminal.readScrollModeSelection())
        XCTAssertTrue(backwards.hasPrefix(sample + "\n"))
        XCTAssertTrue(backwards.contains("row 60"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(input.data.isEmpty, "Selection sent input to the terminal: \(input.data as NSData)")
        terminal.paste(text: "probe")
        for _ in 0..<100 {
            if !input.data.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(String(decoding: input.data, as: UTF8.self), "probe")
    }

    func testTiledTerminalFocusRequestsWorkspaceFocus() {
        let paneID = PaneID()
        let controller = TerminalPaneController(id: paneID)
        var focusedPaneIDs: [PaneID] = []
        controller.onFocusRequest = { focusedPaneIDs.append($0) }

        controller.terminalDidChangeFocus(true)

        XCTAssertEqual(focusedPaneIDs, [paneID])
    }

    func testFloatingTerminalFocusKeepsPaneFloating() {
        let controller = TerminalPaneController()
        var focusedPaneIDs: [PaneID] = []
        controller.onFocusRequest = { focusedPaneIDs.append($0) }
        controller.updatePresentation(isFocused: true, isFloating: true)

        controller.terminalDidChangeFocus(true)

        XCTAssertTrue(focusedPaneIDs.isEmpty)
    }

    func testTerminalBlurDoesNotRequestWorkspaceFocus() {
        let controller = TerminalPaneController()
        var focusedPaneIDs: [PaneID] = []
        controller.onFocusRequest = { focusedPaneIDs.append($0) }

        controller.terminalDidChangeFocus(false)

        XCTAssertTrue(focusedPaneIDs.isEmpty)
    }

    func testAlreadyFocusedTerminalKeepsSameWorkspacePaneFocused() {
        let paneID = PaneID()
        let controller = TerminalPaneController(id: paneID)
        var focusedPaneID: PaneID? = paneID
        controller.onFocusRequest = { focusedPaneID = $0 }
        controller.updatePresentation(isFocused: true)

        controller.terminalDidChangeFocus(true)

        XCTAssertEqual(focusedPaneID, paneID)
    }

    func testClickingHostPaddingRequestsWorkspaceFocus() {
        let originalPadding = TerminalSettings.padding
        TerminalSettings.padding = 12
        defer { TerminalSettings.padding = originalPadding }

        let paneID = PaneID()
        let terminalView = RecordingTerminalView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 200)
        )
        let hostView = TerminalPaneHostView(paneID: paneID, terminalView: terminalView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        hostView.layoutSubtreeIfNeeded()

        var focusedPaneIDs: [PaneID] = []
        hostView.onFocusRequest = { focusedPaneIDs.append($0) }
        let paddingPoint = NSPoint(x: 6, y: hostView.bounds.midY)
        XCTAssertFalse(hostView.debugTerminalFrame.contains(paddingPoint))

        sendMouseEvent(
            .leftMouseDown,
            at: paddingPoint,
            in: window,
            eventNumber: 1,
            clickCount: 1
        )
        sendMouseEvent(
            .leftMouseUp,
            at: paddingPoint,
            in: window,
            eventNumber: 2,
            clickCount: 1
        )

        XCTAssertEqual(focusedPaneIDs, [paneID])
        XCTAssertTrue(terminalView.receivedMouseEvents.isEmpty)
    }

    func testHostDoesNotObserveTerminalClicksWithGestureRecognizer() {
        let terminalView = RecordingTerminalView(frame: .zero)
        let hostView = TerminalPaneHostView(paneID: PaneID(), terminalView: terminalView)

        XCTAssertFalse(hostView.gestureRecognizers.contains { $0 is NSClickGestureRecognizer })
    }

    func testPrimaryMouseSequencesReachTerminalView() {
        let terminalView = RecordingTerminalView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 200)
        )
        let hostView = TerminalPaneHostView(paneID: PaneID(), terminalView: terminalView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        hostView.layoutSubtreeIfNeeded()

        let start = NSPoint(x: hostView.debugTerminalFrame.midX, y: hostView.debugTerminalFrame.midY)
        let end = NSPoint(x: start.x + 40, y: start.y + 20)

        sendMouseEvent(.leftMouseDown, at: start, in: window, eventNumber: 1, clickCount: 1)
        sendMouseEvent(.leftMouseUp, at: start, in: window, eventNumber: 2, clickCount: 1)

        sendMouseEvent(.leftMouseDown, at: start, in: window, eventNumber: 3, clickCount: 1)
        sendMouseEvent(.leftMouseDragged, at: end, in: window, eventNumber: 4, clickCount: 1)
        sendMouseEvent(.leftMouseUp, at: end, in: window, eventNumber: 5, clickCount: 1)

        sendMouseEvent(.leftMouseDown, at: start, in: window, eventNumber: 6, clickCount: 1)
        sendMouseEvent(.leftMouseUp, at: start, in: window, eventNumber: 7, clickCount: 1)
        sendMouseEvent(.leftMouseDown, at: start, in: window, eventNumber: 8, clickCount: 2)
        sendMouseEvent(.leftMouseUp, at: start, in: window, eventNumber: 9, clickCount: 2)

        XCTAssertEqual(
            terminalView.receivedMouseEvents,
            [
                .down(clickCount: 1),
                .up(clickCount: 1),
                .down(clickCount: 1),
                .dragged(clickCount: 1),
                .up(clickCount: 1),
                .down(clickCount: 1),
                .up(clickCount: 1),
                .down(clickCount: 2),
                .up(clickCount: 2),
            ]
        )
    }

    private func sendMouseEvent(
        _ type: NSEvent.EventType,
        at location: NSPoint,
        in window: NSWindow,
        eventNumber: Int,
        clickCount: Int
    ) {
        guard
            let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: TimeInterval(eventNumber),
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumber,
                clickCount: clickCount,
                pressure: 1
            )
        else {
            return XCTFail("Failed to create mouse event")
        }

        window.sendEvent(event)
    }
}

@MainActor
private final class DetachedPaneTitleRecorder: TerminalSurfaceTitleDelegate {
    var title = ""
    func terminalDidChangeTitle(_ title: String) { self.title = title }
}

@MainActor
private final class RecordingTerminalView: TerminalView {
    enum ReceivedMouseEvent: Equatable {
        case down(clickCount: Int)
        case dragged(clickCount: Int)
        case up(clickCount: Int)
    }

    private(set) var receivedMouseEvents: [ReceivedMouseEvent] = []
    private(set) var surfaceVisibility: [Bool] = []

    override func setSurfaceVisible(_ visible: Bool) {
        surfaceVisibility.append(visible)
        super.setSurfaceVisible(visible)
    }

    override func mouseDown(with event: NSEvent) {
        receivedMouseEvents.append(.down(clickCount: event.clickCount))
    }

    override func mouseDragged(with event: NSEvent) {
        receivedMouseEvents.append(.dragged(clickCount: event.clickCount))
    }

    override func mouseUp(with event: NSEvent) {
        receivedMouseEvents.append(.up(clickCount: event.clickCount))
    }
}

private final class ScrollModeInputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var data: Data { lock.withLock { bytes } }
}
