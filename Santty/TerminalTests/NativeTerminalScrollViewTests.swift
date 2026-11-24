import AppKit
import SwiftTerm
import XCTest
@testable import Santty

@MainActor
final class NativeTerminalScrollViewTests: XCTestCase {
    private func makeView() throws -> (NSWindow, NativeTerminalScrollView) {
        let driver = try GhosttyVTDriver(columns: 80, rows: 10)
        let view = NativeTerminalScrollView(driver: driver, frame: NSRect(x: 0, y: 0, width: 640, height: 245))
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.refresh(resizeTerminal: true)
        view.feed((0..<1000).map { "line-\($0) 中文\r\n" }.joined())
        return (window, view)
    }

    func testScrollViewVirtualizesSurfaceAndPreservesFractionalPosition() throws {
        let (window, view) = try makeView()
        defer { window.contentView = nil }
        let h = view.renderer.cellSize.height
        view.contentView.scroll(to: NSPoint(x: 0, y: 5 * h + 5))
        XCTAssertNil(view.lastError)
        XCTAssertEqual(view.renderer.frame.minY, 5 * h)
        XCTAssertEqual(view.contentView.bounds.minY - view.renderer.frame.minY, 5, accuracy: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(view.documentView).frame.height, view.contentSize.height * 10)
        XCTAssertLessThanOrEqual(view.renderer.frame.height, view.contentSize.height + 3 * h)
        XCTAssertLessThanOrEqual(view.source.lines.count, view.driver.rows + 4)
        XCTAssertEqual(view.cell(atViewportPoint: NSPoint(x: 1, y: h - 5))?.row, 6)
    }

    func testFractionalMovementDoesNotReconvertRows() throws {
        let (window, view) = try makeView()
        defer { window.contentView = nil }
        let h = view.renderer.cellSize.height
        view.contentView.scroll(to: NSPoint(x: 0, y: 5 * h + 2))
        let before = view.source.convertedRows
        view.contentView.scroll(to: NSPoint(x: 0, y: 5 * h + 7))
        XCTAssertEqual(view.source.convertedRows, before)
        XCTAssertEqual(view.contentView.bounds.minY - view.renderer.frame.minY, 7, accuracy: 0.01)
    }

    func testOutputDoesNotStealHistoryPositionAndBottomFollows() throws {
        let (window, view) = try makeView()
        defer { window.contentView = nil }
        let oldBottom = view.contentView.bounds.minY
        view.feed("more\r\n")
        XCTAssertGreaterThan(view.contentView.bounds.minY, oldBottom)
        view.contentView.scroll(to: NSPoint(x: 0, y: 105))
        view.feed("more again\r\n")
        XCTAssertEqual(view.contentView.bounds.minY, 105, accuracy: 0.01)
    }

    func testScrollingUpStaysMonotonicDuringSpinnerAndOutputUpdates() throws {
        for output in ["\r\u{1b}[2Kspinner", "new output\r\n"] {
            let (window, view) = try makeView()
            defer { window.contentView = nil }
            for _ in 0..<100 {
                let requested = view.contentView.bounds.minY - 2
                view.contentView.scroll(to: NSPoint(x: 0, y: requested))
                view.feed(output)
                XCTAssertEqual(view.contentView.bounds.minY, requested, accuracy: 0.01)
                XCTAssertNil(view.lastError)
            }
        }
    }

    func testSpinnerSynchronizedUpdateDoesNotUndoUserScroll() throws {
        let (window, view) = try makeView()
        defer { window.contentView = nil }
        let h = view.renderer.cellSize.height
        view.contentView.scroll(to: NSPoint(x: 0, y: 100 * h + 5))
        let published = try XCTUnwrap(view.presentedViewport)
        let screenY = view.renderer.frame.minY - view.contentView.bounds.minY
        let converted = view.source.convertedRows
        let axValue = view.renderer.accessibilityValue() as? String
        let axFrame = view.renderer.accessibilityFrame(for: NSRange(location: 0, length: 4))
        view.feed("\u{1b}[?2026h\r\u{1b}[2Kspinner")
        XCTAssertNotNil(view.driver.renderHoldRemaining)
        var requested = view.contentView.bounds.minY
        for distance: CGFloat in [h, h / 4, h * 3] {
            requested -= distance
            view.contentView.scroll(to: NSPoint(x: 0, y: requested))
            view.refresh()
            XCTAssertEqual(view.contentView.bounds.minY, requested, accuracy: 0.01,
                           "a spinner redraw must not push user scrolling back down")
            XCTAssertEqual(view.renderer.frame.minY - view.contentView.bounds.minY, screenY, accuracy: 0.01,
                           "the held frame stays pinned, not relabeled as different history rows")
            XCTAssertEqual(view.presentedViewport, published)
            XCTAssertEqual(view.source.convertedRows, converted)
            XCTAssertEqual(view.renderer.accessibilityValue() as? String, axValue)
            XCTAssertEqual(view.renderer.accessibilityFrame(for: NSRange(location: 0, length: 4)), axFrame)
            XCTAssertNotNil(view.driver.renderHoldRemaining, "scrolling must not end synchronized output")
        }
        view.feed("\u{1b}[?2026l")
        XCTAssertEqual(view.contentView.bounds.minY, requested, accuracy: 0.01)
        XCTAssertEqual(view.presentedViewport?.offset, requested)
        XCTAssertEqual(view.renderer.frame.minY, floor(requested / h) * h, accuracy: 0.01)
        XCTAssertNil(view.lastError)
    }

    func testScrollBackDuringHeldOutputDoesNotResumeBottomFollowing() throws {
        let (window, view) = try makeView()
        defer { window.contentView = nil }
        let requested = view.contentView.bounds.minY - 2 * view.renderer.cellSize.height
        view.feed("\u{1b}[?2026h" + String(repeating: "more output\r\n", count: 30))
        view.contentView.scroll(to: NSPoint(x: 0, y: requested))
        view.feed("\u{1b}[?2026l")
        XCTAssertEqual(view.contentView.bounds.minY, requested, accuracy: 0.01)
        XCTAssertFalse(view.isAtLiveBottom)
    }

    func testHeldScrollTimeoutAppliesFractionalMotionWithoutAnotherChunk() async throws {
        let (window, view) = try makeView()
        defer { window.contentView = nil }
        view.contentView.scroll(to: NSPoint(x: 0, y: 100 * view.renderer.cellSize.height + 5))
        let requested = view.contentView.bounds.minY - 2
        view.feed("\u{1b}[?2026hspinner")
        view.contentView.scroll(to: NSPoint(x: 0, y: requested))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(view.presentedViewport?.offset, requested)
        XCTAssertEqual(view.contentView.bounds.minY - view.renderer.frame.minY, 3, accuracy: 0.01,
                       "release must restore renderer geometry even for motion within one row")
        XCTAssertNil(view.driver.renderHoldRemaining)
    }

    func testResetDiscardsHeldScrollIntentAndItsFrameTranslation() throws {
        let (window, view) = try makeView()
        defer { window.contentView = nil }
        view.feed("\u{1b}[?2026hspinner")
        view.contentView.scroll(to: NSPoint(x: 0, y: 100 * view.renderer.cellSize.height + 5))
        view.reset(with: "new screen")
        XCTAssertEqual(view.contentView.bounds.minY, 0)
        XCTAssertEqual(view.renderer.frame.minY, 0)
        XCTAssertEqual(view.presentedViewport?.offset, 0)
        XCTAssertEqual(view.source.lines[0]?[0].getText(), "n")
    }

    func testResizeAndResetDoNotKeepOldRowsOrCreateHugeSurface() throws {
        let (window, view) = try makeView()
        defer { window.contentView = nil }
        view.setFrameSize(NSSize(width: 480, height: 360))
        view.layoutSubtreeIfNeeded()
        view.refresh(resizeTerminal: true)
        XCTAssertNil(view.lastError)
        view.reset(with: "reset")
        XCTAssertEqual(view.contentView.bounds.minY, 0, accuracy: 0.01)
        XCTAssertEqual(view.source.lines[0]?[0].getText(), "r")
        XCTAssertLessThan(view.renderer.frame.height, 500)
    }

    func testInternalPaddingKeepsFractionalHistoryCoordinatesAndBoundedRenderer() throws {
        let (window, view) = try makeView()
        defer { window.contentView = nil }
        let theme = try NativeThemeCatalog.bundled().defaultTheme
        try view.applySettings(.init(theme: theme, padding: 24))
        let h = view.renderer.cellSize.height
        let offset = 5 * h + 5
        view.contentView.scroll(to: NSPoint(x: 0, y: offset))
        let converted = view.source.convertedRows
        for _ in 0..<3 {
            view.tile()
            view.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(view.contentView.frame, view.bounds.insetBy(dx: 24, dy: 24))
        XCTAssertEqual(view.contentView.bounds.minY, offset, accuracy: 0.01)
        XCTAssertEqual(view.renderer.frame.minY, 5 * h, accuracy: 0.01)
        XCTAssertEqual(view.source.convertedRows, converted, "tiling must not reinterpret clip resizing as scrolling")
        XCTAssertEqual(view.cell(atViewportPoint: NSPoint(x: 1, y: h - 5))?.row, 6)
        let document = try XCTUnwrap(view.documentView)
        let clip = view.convert(view.contentView.bounds, from: view.contentView)
        let y = view.isFlipped ? clip.minY + h - 5 : clip.maxY - (h - 5)
        let point = document.convert(NSPoint(x: clip.minX + 1, y: y), from: view)
        XCTAssertEqual(point.x, 1, accuracy: 0.01)
        XCTAssertEqual(point.y, offset + h - 5, accuracy: 0.01)
        XCTAssertEqual(view.driver.columns, Int(view.contentSize.width / view.renderer.cellSize.width))
        XCTAssertEqual(view.driver.rows, Int(view.contentSize.height / h))
        XCTAssertEqual(view.viewport.widthPixels, UInt32(view.contentSize.width * (window.backingScaleFactor)))
        XCTAssertLessThanOrEqual(view.renderer.frame.height, view.contentSize.height + 3 * h)
        XCTAssertFalse(view.isAtLiveBottom)
        view.scrollToLiveScreen()
        XCTAssertTrue(view.isAtLiveBottom)
        XCTAssertEqual(view.contentView.bounds.minY,
                       try XCTUnwrap(view.documentView).frame.height - view.contentSize.height, accuracy: 0.01)
    }

    func testAdapterRetainsRowsAndMapsAttributesWithoutASecondParser() throws {
        let driver = try GhosttyVTDriver(columns: 20, rows: 4)
        driver.feed("\u{1b}[1;4;31mA\u{1b}[0m中e\u{301}")
        let source = SwiftTermFrameSource()
        source.apply(try driver.snapshot(topRow: 0), topLine: 0, renderRows: 4)
        let row = try XCTUnwrap(source.lines[0])
        let before = source.convertedRows
        source.apply(try driver.snapshot(topRow: 0), topLine: 0, renderRows: 4)
        XCTAssertTrue(source.lines[0] === row)
        XCTAssertEqual(source.convertedRows, before)
        XCTAssertTrue(row[0].attribute.style.contains([.bold, .underline]))
        XCTAssertEqual(row[0].attribute.fg, .ansi256(code: 1))
        XCTAssertEqual(row[0].attribute.bg, .defaultColor,
                       "default background is not SwiftTerm's defaultInvertedColor")
        XCTAssertEqual(row[1].width, 2)
        XCTAssertEqual(row[2].width, 0)
        XCTAssertEqual(row[3].getText(), "e\u{301}")
    }

    func testCoreGraphicsActuallyDrawsExternalGrid() throws {
        let (window, view) = try makeView()
        defer { window.contentView = nil }
        view.contentView.scroll(to: .zero)
        view.renderer.presentExternalFrame()
        let renderer = view.renderer
        let bitmap = try XCTUnwrap(renderer.bitmapImageRepForCachingDisplay(in: renderer.bounds))
        renderer.cacheDisplay(in: renderer.bounds, to: bitmap)
        var lit = 0
        for y in 0..<min(bitmap.pixelsHigh, 40) {
            for x in 0..<min(bitmap.pixelsWide, 300) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   max(color.redComponent, color.greenComponent, color.blueComponent) > 0.5 {
                    lit += 1
                }
            }
        }
        XCTAssertGreaterThan(lit, 10, "external grid must draw glyphs, not just a blank background")
        let background = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 2, y: 2)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(max(background.redComponent, background.greenComponent, background.blueComponent), 0.5,
                          "an unwritten cell must use the terminal background, not its foreground")
    }
}
