import AppKit
import XCTest
@testable import SanttyTerminalLab

final class NativeSelectionCoreTests: XCTestCase {
    private func event(_ step: NativeSelectionInput.Step, column: Int, row: Int = 0,
                       time: Double = 1, right: Bool = false) -> NativeSelectionInput {
        .init(step: step, column: column, row: row,
              position: CGPoint(x: CGFloat(column * 10) + (right ? 9 : 1), y: CGFloat(row * 20) + 5),
              cell: CGSize(width: 10, height: 20), viewportHeight: 80, time: time, doubleClickInterval: 0.5)
    }

    func testCoreOwnsSingleWordAndLineSelection() throws {
        let driver = try GhosttyVTDriver(columns: 30, rows: 4)
        driver.feed("hello world")
        try driver.select(event(.press, column: 0))
        XCTAssertNil(try driver.selectedText())
        try driver.select(event(.drag, column: 4, time: 1.01, right: true))
        XCTAssertEqual(try driver.selectedText(), "hello")
        try driver.select(event(.release, column: 4, time: 1.02))
        driver.cancelSelectionGesture()
        try driver.select(event(.press, column: 1, time: 2))
        try driver.select(event(.release, column: 1, time: 2.01))
        try driver.select(event(.press, column: 1, time: 2.1))
        XCTAssertEqual(try driver.selectedText(), "hello")
        try driver.select(event(.release, column: 1, time: 2.11))
        try driver.select(event(.press, column: 1, time: 2.2))
        XCTAssertEqual(try driver.selectedText(), "hello world")
    }

    func testCopyPreservesGraphemesWideCellsAndSoftWraps() throws {
        let driver = try GhosttyVTDriver(columns: 8, rows: 4)
        let text = "12345中🙂e\u{301}abc\r\nsecond"
        driver.feed(text)
        try driver.selectAll()
        XCTAssertEqual(try driver.selectedText(), "12345中🙂e\u{301}abc\nsecond")
        XCTAssertThrowsError(try driver.selectedText(limit: 3))
        let frame = try driver.snapshot(topRow: 0)
        XCTAssertFalse(frame.selection.isEmpty)
        driver.clearSelection()
        XCTAssertTrue(try driver.snapshot(topRow: 0).selection.isEmpty)
    }

    func testSelectedHistorySurvivesViewportMovementButNotResetOrScreenSwitch() throws {
        let driver = try GhosttyVTDriver(columns: 80, rows: 10)
        driver.feed((0..<6000).map { "row-\($0) 中文🙂\r\n" }.joined())
        try driver.selectAll()
        _ = try driver.snapshot(topRow: 100)
        let text = try XCTUnwrap(driver.selectedText())
        XCTAssertTrue(text.contains("row-0 中文🙂"))
        XCTAssertTrue(text.contains("row-5999 中文🙂"))
        driver.feed("\u{1b}[?1049h")
        XCTAssertNil(try driver.selectedText())
        driver.feed("\u{1b}[?1049l")
        XCTAssertNil(try driver.selectedText())
        try driver.selectAll()
        driver.reset()
        XCTAssertNil(try driver.selectedText())
    }
}

@MainActor
final class NativeSelectionViewTests: XCTestCase {
    private func click(_ type: NSEvent.EventType, window: NSWindow, view: NSView, point: CGPoint, time: Double) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testNativeDragHighlightAndExplicitClipboardCopy() throws {
        let driver = try GhosttyVTDriver()
        let view = NativeTerminalScrollView(driver: driver, frame: NSRect(x: 0, y: 0, width: 640, height: 245))
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded(); view.feed("hello world")
        func pixels() throws -> Data {
            let renderer = view.renderer
            let bitmap = try XCTUnwrap(renderer.bitmapImageRepForCachingDisplay(in: renderer.bounds))
            renderer.cacheDisplay(in: renderer.bounds, to: bitmap)
            return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let unselected = try pixels()
        let document = try XCTUnwrap(view.documentView)
        let cell = view.renderer.cellSize
        view.renderer.mouseDown(with: try click(.leftMouseDown, window: window, view: document, point: CGPoint(x: 1, y: 5), time: 1))
        view.renderer.mouseDragged(with: try click(.leftMouseDragged, window: window, view: document, point: CGPoint(x: 4.9 * cell.width, y: 5), time: 1.1))
        view.renderer.mouseUp(with: try click(.leftMouseUp, window: window, view: document, point: CGPoint(x: 4.9 * cell.width, y: 5), time: 1.2))
        XCTAssertEqual(try driver.selectedText(), "hello")
        XCTAssertNotEqual(try pixels(), unselected, "Core Graphics must actually paint the selection")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.copySelection(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "hello")
        XCTAssertNotEqual(view.source.lines[0]?[0].attribute.bg, view.source.lines[0]?[7].attribute.bg)
        driver.clearSelection(); view.refresh()
        XCTAssertEqual(view.source.lines[0]?[0].attribute.bg, view.source.lines[0]?[7].attribute.bg)
        XCTAssertEqual(try pixels(), unselected)
    }

    func testAppKitDoubleAndTripleClicksKeepTheirClickSequenceAcrossRelease() throws {
        let view = NativeTerminalScrollView(driver: try GhosttyVTDriver(), frame: NSRect(x: 0, y: 0, width: 640, height: 245))
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded(); view.feed("hello world")
        let document = try XCTUnwrap(view.documentView)
        let point = CGPoint(x: view.renderer.cellSize.width * 1.1, y: 5)
        for (index, time) in [1.0, 1.1, 1.2].enumerated() {
            view.renderer.mouseDown(with: try click(.leftMouseDown, window: window, view: document, point: point, time: time))
            if index == 1 { XCTAssertEqual(try view.driver.selectedText(), "hello") }
            if index == 2 { XCTAssertEqual(try view.driver.selectedText(), "hello world") }
            view.renderer.mouseUp(with: try click(.leftMouseUp, window: window, view: document, point: point, time: time + 0.01))
        }
    }

    func testSelectionAutoscrollUsesNativeDocumentAndClampsBounds() throws {
        let driver = try GhosttyVTDriver()
        let view = NativeTerminalScrollView(driver: driver, frame: NSRect(x: 0, y: 0, width: 640, height: 245))
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded(); view.feed(String(repeating: "history row\r\n", count: 200))
        let document = try XCTUnwrap(view.documentView)
        let top = view.documentVisibleRect.minY
        view.renderer.mouseDown(with: try click(.leftMouseDown, window: window, view: document,
                                               point: CGPoint(x: 1, y: top + 30), time: 1))
        view.renderer.mouseDragged(with: try click(.leftMouseDragged, window: window, view: document,
                                                  point: CGPoint(x: 80, y: top - 40), time: 1.1))
        view.autoscrollSelectionStep()
        XCTAssertLessThan(view.contentView.bounds.minY, top)
        XCTAssertGreaterThanOrEqual(view.contentView.bounds.minY, 0)
        view.renderer.mouseUp(with: try click(.leftMouseUp, window: window, view: document,
                                             point: CGPoint(x: 80, y: view.documentVisibleRect.minY + 5), time: 1.2))
        XCTAssertNotNil(try driver.selectedText())
    }
}
