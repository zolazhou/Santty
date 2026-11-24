import AppKit
import XCTest
@testable import Santty

@MainActor
final class NativePointerViewTests: XCTestCase {
    private func setup() throws -> (NSWindow, NativeTerminalScrollView, PointerBytes) {
        let view = NativeTerminalScrollView(driver: try GhosttyVTDriver(), frame: NSRect(x: 0, y: 0, width: 640, height: 245))
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.feed(String(repeating: "history row\r\n", count: 100) + "\u{1b}[?1000h\u{1b}[?1006h")
        let bytes = PointerBytes()
        let output = NativeTerminalOutput(driver: view.driver) { _ in }
        output.bind(writer: { bytes.append($0) }); output.setInputEnabled(true)
        view.renderer.output = output; view.renderer.inputEnabled = true
        return (window, view, bytes)
    }

    private func mouse(_ type: NSEvent.EventType, window: NSWindow, view: NativeTerminalScrollView,
                       column: CGFloat = 1.5, row: CGFloat = 1.25, shift: Bool = false) throws -> NSEvent {
        let total = try view.driver.totalRows
        let document = try XCTUnwrap(view.documentView), cell = view.renderer.cellSize
        let point = CGPoint(x: column * cell.width, y: CGFloat(total - view.driver.rows) * cell.height + row * cell.height)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: document.convert(point, to: nil),
            modifierFlags: shift ? .shift : [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testProgramButtonKeepsItsOwnerWhileTypingAndShiftChanges() throws {
        let (window, view, bytes) = try setup()
        defer { window.contentView = nil }
        let offset = view.contentView.bounds.minY
        view.renderer.mouseDown(with: try mouse(.leftMouseDown, window: window, view: view))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        view.renderer.keyDown(with: key)
        view.renderer.mouseUp(with: try mouse(.leftMouseUp, window: window, view: view, shift: true))
        XCTAssertEqual(bytes.data, Data("\u{1b}[<0;2;2Ma\u{1b}[<4;2;2m".utf8))
        XCTAssertEqual(view.contentView.bounds.minY, offset)
        XCTAssertNil(try view.driver.selectedText())
    }

    func testHoverDoesNotCreateAnOrphanReleaseOnFocusReset() throws {
        let (window, view, bytes) = try setup()
        defer { window.contentView = nil }
        view.driver.feed("\u{1b}[?1003h")
        view.renderer.mouseMoved(with: try mouse(.mouseMoved, window: window, view: view))
        XCTAssertFalse(bytes.data.isEmpty)
        let hover = bytes.data
        view.renderer.resetInputState()
        XCTAssertEqual(bytes.data, hover)
    }

    func testShiftSelectionDoesNotSendProgramInput() throws {
        let (window, view, bytes) = try setup()
        defer { window.contentView = nil }
        view.renderer.mouseDown(with: try mouse(.leftMouseDown, window: window, view: view, column: 0.1, shift: true))
        view.renderer.mouseDragged(with: try mouse(.leftMouseDragged, window: window, view: view, column: 6.9, shift: true))
        view.renderer.mouseUp(with: try mouse(.leftMouseUp, window: window, view: view, column: 6.9))
        XCTAssertTrue(bytes.data.isEmpty)
        XCTAssertNotNil(try view.driver.selectedText())
    }

    func testProgramWheelDoesNotAlsoMoveNativeHistory() throws {
        let (window, view, bytes) = try setup()
        defer { window.contentView = nil }
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                       wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        let offset = view.contentView.bounds.minY
        view.scrollWheel(with: event)
        XCTAssertFalse(bytes.data.isEmpty)
        XCTAssertEqual(view.contentView.bounds.minY, offset)
        let count = bytes.data.count
        view.driver.feed("\u{1b}[?1000l")
        // A windowless synthetic CG event does not drive AppKit's native
        // scrolling in a hidden test window. Verify the dispatch boundary;
        // the override forwards this original event only on a true result.
        XCTAssertTrue(view.routeWheel(event))
        XCTAssertEqual(bytes.data.count, count)
    }
}

private final class PointerBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var data: Data { lock.withLock { bytes } }
}
