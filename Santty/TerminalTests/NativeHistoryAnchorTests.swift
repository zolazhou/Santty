import AppKit
import SwiftTerm
import XCTest
@testable import Santty

final class NativeHistoryAnchorCoreTests: XCTestCase {
    private func lines(_ range: Range<Int>, tail: String = "abcdefghijklmnopqrstuvwxyz") -> String {
        range.map { String(format: "L%03d:", $0) + tail + "\r\n" }.joined()
    }

    private func present(_ driver: GhosttyVTDriver, previous: NativeViewport? = nil,
                         offset: CGFloat? = nil) throws -> NativeTerminalPresentation {
        try XCTUnwrap(driver.presentation(rowHeight: 20, viewportHeight: 80, previous: previous, requestedOffset: offset))
    }

    private func row(_ p: NativeTerminalPresentation, delta: Int = 0) throws -> String {
        try XCTUnwrap(p.frame.rows[p.viewport.firstRow + delta]).cells.compactMap(\.text).joined()
    }

    func testReflowPreservesOriginalCellAndFractionAcrossRepeatedWidthChanges() throws {
        let driver = try GhosttyVTDriver(columns: 12, rows: 4)
        driver.feed(lines(0..<80))
        let bottom = try present(driver)
        let reading = try present(driver, previous: bottom.viewport, offset: 31 * 20 + 5)
        let original = try row(reading)
        let letter = try XCTUnwrap(reading.frame.rows[31]?.cells[0].text)
        try driver.resize(columns: 16, rows: 4)
        let wider = try present(driver, previous: reading.viewport)
        guard case let .preserved(column) = wider.anchor else { return XCTFail("must preserve a content cell") }
        XCTAssertGreaterThan(column, 0, "a continuation row becomes an interior cell after reflow")
        XCTAssertEqual(wider.frame.rows[wider.viewport.firstRow]?.cells[column].text, letter)
        XCTAssertEqual(wider.viewport.fraction, 5, accuracy: 0.001)
        // Diagnostic sampling must not replace the presentation's reference.
        _ = try driver.snapshot(topRow: 0)
        let fractional = try present(driver, previous: wider.viewport, offset: wider.viewport.offset + 2)
        XCTAssertEqual(fractional.anchor, wider.anchor)
        try driver.resize(columns: 12, rows: 4)
        let restored = try present(driver, previous: fractional.viewport)
        XCTAssertEqual(try row(restored), original)
        XCTAssertEqual(restored.viewport.firstRow, 31)
        XCTAssertEqual(restored.viewport.fraction, 7, accuracy: 0.001)
    }

    func testUserScrollIsRelativeToPublishedContentWhilePruningIsPending() throws {
        let driver = try GhosttyVTDriver(columns: 80, rows: 4, scrollbackLines: 2000)
        driver.feed(lines(0..<4000))
        let bottom = try present(driver)
        let reading = try present(driver, previous: bottom.viewport, offset: CGFloat(bottom.frame.totalRows / 2) * 20 + 5)
        let expected = try row(reading, delta: 2)
        var appended = 0
        repeat {
            driver.feed(lines((4000 + appended)..<(4100 + appended)))
            appended += 100
        } while try driver.totalRows == bottom.frame.totalRows + appended && appended < 3000
        XCTAssertLessThan(try driver.totalRows, bottom.frame.totalRows + appended)
        let moved = try present(driver, previous: reading.viewport, offset: reading.viewport.offset + 40)
        XCTAssertEqual(try row(moved), expected)
        XCTAssertLessThan(moved.viewport.firstRow, reading.viewport.firstRow)
        XCTAssertEqual(moved.viewport.fraction, 5, accuracy: 0.001)
    }

    func testSelectionHitRebasesWhenParsingPrunesBeforeTheNextPresentation() throws {
        let driver = try GhosttyVTDriver(columns: 80, rows: 4, scrollbackLines: 2000)
        driver.feed(lines(0..<4000))
        let bottom = try present(driver)
        let reading = try present(driver, previous: bottom.viewport, offset: CGFloat(bottom.frame.totalRows / 2) * 20 + 5)
        let expected = String(try row(reading, delta: 2).prefix(5))
        var appended = 0
        repeat {
            driver.feed(lines((4000 + appended)..<(4100 + appended)))
            appended += 100
        } while try driver.totalRows == bottom.frame.totalRows + appended && appended < 3000
        XCTAssertLessThan(try driver.totalRows, bottom.frame.totalRows + appended)
        for (step, x, time): (NativeSelectionInput.Step, CGFloat, Double) in [(.press, 1, 1), (.drag, 49, 1.01), (.release, 49, 1.02)] {
            let event = NativeSelectionInput(step: step, column: Int(x / 10), row: reading.viewport.firstRow + 2,
                position: CGPoint(x: x, y: 45), cell: CGSize(width: 10, height: 20), viewportHeight: 80,
                time: time, doubleClickInterval: 0.5)
            XCTAssertTrue(try driver.select(event, relativeTo: reading.viewport))
        }
        XCTAssertEqual(try driver.selectedText(), expected)
    }

    func testSelectionHitOnDiscardedOrResetPresentationIsDropped() throws {
        let driver = try GhosttyVTDriver(columns: 80, rows: 4, scrollbackLines: 2000)
        driver.feed(lines(0..<4000))
        let bottom = try present(driver)
        let reading = try present(driver, previous: bottom.viewport, offset: 500 * 20)
        let event = NativeSelectionInput(step: .press, column: 0, row: 500, position: .zero,
            cell: CGSize(width: 10, height: 20), viewportHeight: 80, time: 1, doubleClickInterval: 0.5)
        driver.feed(lines(4000..<12000))
        XCTAssertFalse(try driver.select(event, relativeTo: reading.viewport))
        _ = try present(driver, previous: reading.viewport)
        driver.feed("\u{1b}c" + lines(0..<80))
        XCTAssertFalse(try driver.select(event, relativeTo: reading.viewport))
        XCTAssertNil(try driver.selectedText())
    }

    func testLostReferenceClampsToOldestInsteadOfReusingAnUnrelatedRowIndex() throws {
        let driver = try GhosttyVTDriver(columns: 80, rows: 4, scrollbackLines: 2000)
        driver.feed(lines(0..<4000))
        let bottom = try present(driver)
        let reading = try present(driver, previous: bottom.viewport, offset: 500 * 20 + 5)
        driver.feed(lines(4000..<12000))
        let lost = try present(driver, previous: reading.viewport)
        XCTAssertEqual(lost.viewport.firstRow, 0)
        XCTAssertEqual(lost.viewport.offset, 0)
        XCTAssertEqual(lost.anchor, .oldestAvailable)
        XCTAssertNotEqual(try row(lost), try row(reading))
        let again = try present(driver, previous: lost.viewport, offset: 40)
        XCTAssertEqual(again.viewport.firstRow, 2, "fallback establishes a usable new reference")
    }

    func testFollowBottomAndScrollBackUseTheLastPublishedFrame() throws {
        let driver = try GhosttyVTDriver(columns: 40, rows: 4)
        driver.feed(lines(0..<80))
        let bottom = try present(driver)
        driver.feed(lines(80..<90))
        let back = try present(driver, previous: bottom.viewport, offset: bottom.viewport.offset - 40)
        XCTAssertEqual(back.viewport.firstRow, bottom.viewport.firstRow - 2)
        XCTAssertFalse(back.viewport.isAtBottom)
        let live = try present(driver, previous: back.viewport, offset: back.viewport.maximumOffset)
        XCTAssertTrue(live.viewport.isAtBottom)
        XCTAssertEqual(live.anchor, .following)
        XCTAssertEqual(live.viewport.offset, CGFloat(live.frame.totalRows - 4) * 20)
    }

    func testResetDoesNotCarryOldElasticTravelIntoTheNewScreen() throws {
        let driver = try GhosttyVTDriver(columns: 40, rows: 4)
        driver.feed(lines(0..<80))
        let bottom = try present(driver)
        let elastic = try present(driver, previous: bottom.viewport, offset: -10)
        XCTAssertEqual(elastic.viewport.offset, -10)
        driver.feed("\u{1b}c" + lines(100..<180))
        let reset = try present(driver, previous: elastic.viewport)
        XCTAssertEqual(reset.viewport.offset, reset.viewport.maximumOffset)
        XCTAssertTrue(reset.viewport.isAtBottom)
    }

    func testResetRISAndScreenSwitchCannotResurrectOldReferences() throws {
        let driver = try GhosttyVTDriver(columns: 40, rows: 4)
        driver.feed(lines(0..<80))
        var p = try present(driver)
        p = try present(driver, previous: p.viewport, offset: 20 * 20 + 5)
        driver.feed("\u{1b}[!p") // DECSTR is not a full reset.
        p = try present(driver, previous: p.viewport)
        XCTAssertEqual(p.viewport.firstRow, 20)
        driver.feed("\u{1b}[?1049halternate")
        let alternate = try present(driver, previous: p.viewport)
        XCTAssertTrue(alternate.frame.isAlternateScreen)
        driver.feed("\u{1b}[?1049l")
        p = try present(driver, previous: alternate.viewport)
        XCTAssertTrue(p.viewport.isAtBottom)
        p = try present(driver, previous: p.viewport, offset: 20 * 20)
        driver.feed("\u{1b}c" + lines(100..<180))
        p = try present(driver, previous: p.viewport)
        XCTAssertTrue(p.viewport.isAtBottom, "RIS invalidates even if the screen kind stays primary")
        p = try present(driver, previous: p.viewport, offset: 20 * 20)
        driver.reset(); driver.feed(lines(200..<280))
        p = try present(driver, previous: p.viewport)
        XCTAssertTrue(p.viewport.isAtBottom, "reconnect/reset never restores a previous session's anchor")
    }

    func testBackgroundParsingAndAnchorCaptureRemainOneAtomicOperation() async throws {
        let driver = try GhosttyVTDriver(columns: 80, rows: 4, scrollbackLines: 2000)
        driver.feed(lines(0..<4000))
        let bottom = try present(driver)
        var p = try present(driver, previous: bottom.viewport, offset: CGFloat(bottom.frame.totalRows / 2) * 20 + 5)
        var expected = try row(p)
        let chunks = (0..<100).map { Data(lines((4000 + $0 * 50)..<(4050 + $0 * 50)).utf8) }
        let writer = Task.detached {
            for chunk in chunks {
                try Task.checkCancellation()
                driver.feed(chunk)
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        defer { writer.cancel() }
        for _ in 0..<150 {
            p = try present(driver, previous: p.viewport)
            let actual = try row(p)
            if p.anchor == .oldestAvailable { expected = actual }
            XCTAssertEqual(actual, expected, "a frame must come from the same state that resolved its anchor")
            XCTAssertLessThanOrEqual(p.frame.rows.count, driver.rows + 4)
            try await Task.sleep(for: .milliseconds(1))
        }
        try await writer.value
    }

    func testSynchronizedOutputDoesNotRetargetOrPublishTheAnchor() throws {
        let driver = try GhosttyVTDriver(columns: 40, rows: 4)
        driver.feed(lines(0..<80))
        let bottom = try present(driver)
        let reading = try present(driver, previous: bottom.viewport, offset: 20 * 20 + 5)
        driver.feed("\u{1b}[?2026h" + lines(80..<90))
        XCTAssertNil(try driver.presentation(rowHeight: 20, viewportHeight: 80, previous: reading.viewport, requestedOffset: 0))
        driver.feed("\u{1b}[?2026l")
        let released = try present(driver, previous: reading.viewport)
        XCTAssertEqual(try row(released), try row(reading))
        XCTAssertEqual(released.viewport.offset, reading.viewport.offset)
    }
}

@MainActor
final class NativeHistoryAnchorViewTests: XCTestCase {
    private func lines(_ range: Range<Int>) -> String {
        range.map { "history-\($0) 中文🙂\r\n" }.joined()
    }

    private func makeView() throws -> (NSWindow, NativeTerminalScrollView) {
        let driver = try GhosttyVTDriver(scrollbackLines: 2000)
        let view = NativeTerminalScrollView(driver: driver, frame: NSRect(x: 0, y: 0, width: 640, height: 245))
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.refresh(resizeTerminal: true)
        view.feed(lines(0..<4000))
        return (window, view)
    }

    private func firstText(_ view: NativeTerminalScrollView) -> String {
        let row = Int(floor(view.contentView.bounds.minY / view.renderer.cellSize.height))
        return (0..<view.driver.columns).compactMap { view.source.lines[row]?[$0].getText() }.joined()
            .trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    private func prune(_ view: NativeTerminalScrollView) throws -> Int {
        let total = try view.driver.totalRows
        var appended = 0
        repeat {
            view.feed(lines((4000 + appended)..<(4100 + appended)))
            appended += 100
        } while try view.driver.totalRows == total + appended && appended < 3000
        XCTAssertLessThan(try view.driver.totalRows, total + appended)
        return appended
    }

    private func mouse(_ type: NSEvent.EventType, _ window: NSWindow, _ view: NativeTerminalScrollView,
                       x: CGFloat, y: CGFloat, time: Double) throws -> NSEvent {
        let document = try XCTUnwrap(view.documentView)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: document.convert(CGPoint(x: x, y: y), to: nil),
            modifierFlags: [], timestamp: time, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testLostContentClampsAndCanScrollAgainWithoutStealingFocus() throws {
        let (window, view) = try makeView()
        defer { window.contentView = nil }
        let h = view.renderer.cellSize.height
        view.contentView.scroll(to: CGPoint(x: 0, y: 400 * h + h / 4))
        let before = firstText(view), responder = try XCTUnwrap(window.firstResponder)
        view.feed(lines(4000..<12000))
        XCTAssertEqual(view.contentView.bounds.minY, 0)
        XCTAssertNotEqual(firstText(view), before)
        XCTAssertTrue(window.firstResponder === responder)
        view.contentView.scroll(to: CGPoint(x: 0, y: 2 * h))
        XCTAssertEqual(view.contentView.bounds.minY, 2 * h, accuracy: 0.01)
        XCTAssertTrue(firstText(view).hasPrefix("history-"))
    }

    func testWidthAndFontReflowKeepTheSameContentAndFraction() throws {
        let driver = try GhosttyVTDriver()
        let view = NativeTerminalScrollView(driver: driver, frame: NSRect(x: 0, y: 0, width: 960, height: 245))
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        view.feed((0..<800).map { String(format: "tag%04d|", $0) + String(repeating: "abcdefghijk", count: 7) + "\r\n" }.joined())
        let oldHeight = view.renderer.cellSize.height
        view.contentView.scroll(to: CGPoint(x: 0, y: 240 * oldHeight + oldHeight / 4))
        let tag = String(firstText(view).prefix(8))
        XCTAssertEqual(tag, "tag0240|")
        for (width, font): (CGFloat, CGFloat) in [(400, 13), (400, 19), (960, 13)] {
            view.renderer.font = .monospacedSystemFont(ofSize: font, weight: .regular)
            view.setFrameSize(NSSize(width: width, height: 245))
            view.layoutSubtreeIfNeeded(); view.refresh(resizeTerminal: true)
            XCTAssertTrue(firstText(view).hasPrefix(tag), "reflow must preserve the original content cell")
            let h = view.renderer.cellSize.height
            XCTAssertEqual(view.contentView.bounds.minY.truncatingRemainder(dividingBy: h), h / 4, accuracy: 0.51)
            XCTAssertLessThanOrEqual(view.renderer.frame.height, view.contentSize.height + 3 * h)
            XCTAssertLessThanOrEqual(view.source.lines.count, driver.rows + 4)
            XCTAssertNil(view.lastError)
        }
    }

    func testHeightOnlyResizePreservesReadingOrBottomFollowing() throws {
        let (window, view) = try makeView()
        defer { window.contentView = nil }
        view.setFrameSize(NSSize(width: 640, height: 180)); view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.isAtLiveBottom)
        XCTAssertEqual(view.driver.rows, Int(view.contentSize.height / view.renderer.cellSize.height))
        let maximum = try XCTUnwrap(view.documentView).frame.height - view.contentSize.height
        XCTAssertEqual(view.contentView.bounds.minY, maximum, accuracy: 0.51)
        view.contentView.scroll(to: CGPoint(x: 0, y: 400 * view.renderer.cellSize.height + 4))
        let text = firstText(view)
        view.setFrameSize(NSSize(width: 640, height: 300)); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(firstText(view), text)
        XCTAssertFalse(view.isAtLiveBottom)
    }

    func testSelectionAndExplicitCopyRemainOnTheSameContentAfterPruning() throws {
        let (window, view) = try makeView()
        defer { window.contentView = nil }
        let h = view.renderer.cellSize.height, w = view.renderer.cellSize.width
        view.contentView.scroll(to: CGPoint(x: 0, y: CGFloat(try view.driver.totalRows / 2) * h + h / 4))
        let y = view.contentView.bounds.minY + h / 2
        view.renderer.mouseDown(with: try mouse(.leftMouseDown, window, view, x: w / 10, y: y, time: 1))
        view.renderer.mouseDragged(with: try mouse(.leftMouseDragged, window, view, x: 12.9 * w, y: y, time: 1.1))
        view.renderer.mouseUp(with: try mouse(.leftMouseUp, window, view, x: 12.9 * w, y: y, time: 1.2))
        let selected = try XCTUnwrap(view.driver.selectedText())
        XCTAssertTrue(selected.hasPrefix("history-"))
        try prune(view)
        XCTAssertEqual(try view.driver.selectedText(), selected)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.copySelection(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), selected)
        // A new click must also address the pixels now displayed, not merely
        // preserve a selection whose own endpoints were already tracked.
        let expected = String(firstText(view).prefix(13)).trimmingCharacters(in: .whitespaces)
        let movedY = view.contentView.bounds.minY + h / 2
        view.renderer.mouseDown(with: try mouse(.leftMouseDown, window, view, x: w / 10, y: movedY, time: 3))
        view.renderer.mouseDragged(with: try mouse(.leftMouseDragged, window, view, x: 12.9 * w, y: movedY, time: 3.1))
        view.renderer.mouseUp(with: try mouse(.leftMouseUp, window, view, x: 12.9 * w, y: movedY, time: 3.2))
        XCTAssertEqual(try view.driver.selectedText()?.trimmingCharacters(in: .whitespaces), expected)
    }

    func testDragAutoscrollAfterPruningCopiesTheExpectedOriginalLines() throws {
        let (window, view) = try makeView()
        defer { window.contentView = nil }
        let h = view.renderer.cellSize.height, w = view.renderer.cellSize.width
        view.contentView.scroll(to: CGPoint(x: 0, y: CGFloat(try view.driver.totalRows / 2) * h + h / 4))
        let marker = try XCTUnwrap(Int(firstText(view).split(separator: " ")[0].dropFirst("history-".count)))
        view.renderer.mouseDown(with: try mouse(.leftMouseDown, window, view, x: w / 10,
            y: view.contentView.bounds.minY + h / 2, time: 1))
        view.renderer.mouseDragged(with: try mouse(.leftMouseDragged, window, view, x: w / 10,
            y: view.contentView.bounds.minY - 40, time: 1.1))
        try prune(view)
        let oldOffset = view.contentView.bounds.minY
        view.autoscrollSelectionStep()
        let distance = Int(((oldOffset - view.contentView.bounds.minY) / h).rounded())
        XCTAssertGreaterThan(distance, 0)
        let copied = try XCTUnwrap(view.driver.selectedText())
        let expected = lines((marker - distance)..<marker).replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertEqual(copied.trimmingCharacters(in: .newlines), expected.trimmingCharacters(in: .newlines))
        view.renderer.mouseUp(with: try mouse(.leftMouseUp, window, view, x: w / 10,
            y: view.contentView.bounds.minY - 40, time: 1.2))
    }

    func testSurvivingHistoryContentStaysAtTopWhenEarlierPagesArePruned() throws {
        let (window, view) = try makeView()
        defer { window.contentView = nil }
        let total = try view.driver.totalRows, h = view.renderer.cellSize.height
        view.contentView.scroll(to: CGPoint(x: 0, y: CGFloat(total / 2) * h + h / 4))
        let text = firstText(view), offset = view.contentView.bounds.minY
        XCTAssertTrue(text.hasPrefix("history-"))
        try prune(view)
        XCTAssertEqual(firstText(view), text, "a numeric row index is not a content anchor")
        XCTAssertLessThan(view.contentView.bounds.minY, offset)
        XCTAssertEqual(view.contentView.bounds.minY.truncatingRemainder(dividingBy: h), h / 4, accuracy: 0.01)
        XCTAssertNil(view.lastError)
    }
}
