import AppKit
import GhosttyVt
import XCTest
@testable import Santty

private final class InteractionBytes: @unchecked Sendable {
    private let lock = NSLock(); private var bytes = Data()
    var data: Data { lock.withLock { bytes } }
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
}
@MainActor
final class TerminalPaneInteractionTests: XCTestCase {
    private func fixture() throws -> NativeTerminalScrollView {
        let view = NativeTerminalScrollView(driver:try GhosttyVTDriver(),frame:.init(x:0,y:0,width:640,height:250))
        view.feed("fixture"); return view
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
        XCTFail("Owned native interaction timed out"); throw NativeLocalPTYError.shutdownTimeout
    }
    func testTerminalLinkValidation() {
        for text in ["","relative/path","https://","https://example.com/\n","https://exa mple.com","/tmp/a b.txt"] {
            XCTAssertNil(TerminalPaneController.linkURL(text),text)
        }
        for text in ["https://example.com/path?q=1#anchor","http://localhost:3000","mailto:hello@example.com"] {
            XCTAssertEqual(TerminalPaneController.linkURL(text)?.absoluteString,text)
        }
    }
    func testCommandClickOSC8LinkOpensThroughPane() throws {
        let view = try fixture(), driver = view.driver
        driver.reset(); view.feed("\u{1b}]8;;https://example.com\u{1b}\\click here\u{1b}]8;;\u{1b}\\\r\n")
        let frame = try driver.snapshot(topRow:0)
        XCTAssertEqual(frame.rows[0]?.cells[0].hyperlink,"https://example.com")
        let window = NSWindow(contentRect:view.frame,styleMask:[],backing:.buffered,defer:false)
        window.contentView = view; defer { window.contentView = nil }
        var opened:[URL] = []; view.openLink = { opened.append($0); return true }
        let point = CGPoint(x:view.renderer.cellSize.width*4,y:view.documentVisibleRect.minY+view.renderer.cellSize.height/2)
        let location = try XCTUnwrap(view.documentView).convert(point,to:nil)
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with:type,location:location,modifierFlags:.command,timestamp:1,
                windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
            if type == .leftMouseDown { view.renderer.mouseDown(with:event) } else { view.renderer.mouseUp(with:event) }
        }
        XCTAssertEqual(opened.map(\.absoluteString),["https://example.com"])
    }
    func testSurfaceAttachUsesCurrentWindowOcclusion() throws {
        let view = try fixture(), output = NativeTerminalOutput(driver:view.driver) { _ in }
        view.renderer.output = output
        let window = NSWindow(contentRect:view.frame,styleMask:[],backing:.buffered,defer:false)
        window.contentView = view; defer { window.contentView = nil }
        XCTAssertFalse(window.occlusionState.contains(.visible))
        view.parsedOutput(reset:false); XCTAssertFalse(view.canAutoscrollScrollMode); XCTAssertTrue(view.hasPendingOutput)
        window.contentView = nil; window.contentView = view
        XCTAssertFalse(view.canAutoscrollScrollMode)
    }
    func testPaneAttachmentReportsSurfaceVisibilityAcrossContainerChanges() throws {
        let view = try fixture(), host = TerminalPaneHostView(paneID:UUID(),terminalView:view)
        let window = NSWindow(contentRect:view.frame,styleMask:[],backing:.buffered,defer:false)
        window.contentView = host; XCTAssertTrue(view.window === window)
        window.contentView = nil; XCTAssertNil(view.window)
        window.contentView = host; XCTAssertTrue(view.window === window)
        window.contentView = nil
    }
    func testDetachedPaneKeepsProcessingOutputAndRestoresScrollback() throws {
        let view = try fixture(), output = NativeTerminalOutput(driver:view.driver) { _ in }
        view.renderer.output = output
        output.receive(Data((1...500).map { "hidden-row-\($0)\r\n" }.joined().utf8))
        XCTAssertTrue(output.waitForPendingOutput())
        let text = try view.driver.readScreenText()
        XCTAssertTrue(text.contains("hidden-row-1\n")); XCTAssertTrue(text.contains("hidden-row-500"))
        XCTAssertFalse(view.canAutoscrollScrollMode)
    }
    func testPromptSubmissionPastesTextThenSendsEnter() async throws {
        let f = try PrivatePaneFixture()
        do {
            XCTAssertFalse(f.pane.submitPrompt("not running"))
            f.pane.startIfNeeded(); f.pane.fitToSize()
            try await wait { f.owner.acceptsInput }
            let bytes = InteractionBytes()
            f.owner.output.bindChecked { bytes.append($0); return true }
            f.owner.output.receive(Data("\u{1b}[?2004h".utf8))
            XCTAssertTrue(f.pane.submitPrompt("hello\nworld"))
            XCTAssertEqual(bytes.data,Data("\u{1b}[200~hello\nworld\u{1b}[201~\r".utf8))
            try await f.stop()
        } catch { try? await f.stop(); throw error }
    }

    func testScrollWordMotionsRespectPunctuationWhitespaceAndBufferBounds() {
        let lines = [Array("  foo_bar/path.txt  next"), [], Array(" final")]
        var cursor = NativeScrollNavigation(cell: .init(column: 0, row: 0), viewport: 0,
                                      columns: 24, rows: 2, total: lines.count)
        let steps: [(NativeScrollMovement, NativeScrollCell)] = [
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
        var cursor = NativeScrollNavigation(cell: .init(column: 4, row: 50), viewport: 45,
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

    func testNativeScrollSelectionAcrossHistoryPreservesUnicodeAndDoesNotSendInput() throws {
        let view = try fixture(), driver = view.driver, bytes = InteractionBytes()
        driver.reset()
        let sample = "A中👩🏽‍💻e\u{301}Z", words = "  foo_bar/path.txt  next"
        view.feed("\u{1b}[?1003h\u{1b}[?1006h\u{1b}[31m"+sample+"\u{1b}[0m\r\n"+words+"\r\n"+(1...60).map { "row \($0)\r\n" }.joined())
        let output = NativeTerminalOutput(driver:driver) { _ in }; output.bindChecked { bytes.append($0); return true }
        output.setInputEnabled(true); view.renderer.output = output; view.renderer.inputEnabled = true
        XCTAssertTrue(view.scrollModeController.enter())
        _ = try driver.performScrollMode(.move(.top))
        _ = try driver.performScrollMode(.toggleSelection(linewise:true))
        _ = try driver.performScrollMode(.move(.bottom))
        let selected = try XCTUnwrap(driver.readScrollModeSelection())
        XCTAssertTrue(selected.hasPrefix(sample+"\n")); XCTAssertTrue(selected.contains("row 15")); XCTAssertTrue(selected.contains("row 60"))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(view.scrollModeController.copy(to:board))
        XCTAssertEqual(board.string(forType:.string),selected)
        XCTAssertNotNil(view.scrollModeController.overlay.flashRect)
        XCTAssertFalse(try output.sendText("must not reach program")); XCTAssertTrue(bytes.data.isEmpty)
        view.scrollModeController.exit()
    }
    func testTiledTerminalFocusRequestsWorkspaceFocus() {
        let pane = TerminalPaneController(); var ids:[UUID] = []; pane.onFocusRequest = { ids.append($0) }
        pane.updatePresentation(isFocused:false); pane.reflectTerminalFocus(true); XCTAssertEqual(ids,[pane.id])
    }
    func testFloatingTerminalFocusKeepsPaneFloating() {
        let pane = TerminalPaneController(); var count = 0; pane.onFocusRequest = { _ in count+=1 }
        pane.updatePresentation(isFocused:false,isFloating:true); pane.reflectTerminalFocus(true); XCTAssertEqual(count,0)
    }
    func testTerminalBlurDoesNotRequestWorkspaceFocus() {
        let pane = TerminalPaneController(); var count = 0; pane.onFocusRequest = { _ in count+=1 }
        pane.reflectTerminalFocus(false); XCTAssertEqual(count,0)
    }
    func testAlreadyFocusedTerminalKeepsSameWorkspacePaneFocused() {
        let pane = TerminalPaneController(); var ids:[UUID] = []; pane.onFocusRequest = { ids.append($0) }
        pane.updatePresentation(isFocused:true); pane.reflectTerminalFocus(true); XCTAssertEqual(ids,[pane.id])
    }
    func testClickingHostPaddingRequestsWorkspaceFocus() throws {
        let view = try fixture(), host = TerminalPaneHostView(paneID:UUID(),terminalView:view)
        var ids:[UUID] = []; host.onFocusRequest = { ids.append($0) }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:[],timestamp:1,windowNumber:0,
            context:nil,eventNumber:1,clickCount:1,pressure:1))
        host.mouseDown(with:event); XCTAssertEqual(ids,[host.paneID])
    }
    func testHostDoesNotObserveTerminalClicksWithGestureRecognizer() throws {
        let host = TerminalPaneHostView(paneID:UUID(),terminalView:try fixture())
        XCTAssertTrue(host.gestureRecognizers.isEmpty)
    }
    func testPrimaryMouseSequencesReachTerminalView() throws {
        let view = try fixture(); var events:[NSEvent.EventType] = []
        view.renderer.onPointerEvent = { events.append($0.type); return true }
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseDragged,.leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with:type,location:.zero,modifierFlags:[],timestamp:1,windowNumber:0,
                context:nil,eventNumber:1,clickCount:1,pressure:1))
            switch type { case .leftMouseDown: view.renderer.mouseDown(with:event)
            case .leftMouseDragged: view.renderer.mouseDragged(with:event)
            default: view.renderer.mouseUp(with:event) }
        }
        XCTAssertEqual(events,[.leftMouseDown,.leftMouseDragged,.leftMouseUp])
    }
}
