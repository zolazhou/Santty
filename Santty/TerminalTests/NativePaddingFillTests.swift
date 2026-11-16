import AppKit
import XCTest
@testable import Santty

@MainActor
final class NativePaddingFillTests: XCTestCase {
    private let red = NativeRGB(red: 255, green: 0, blue: 0)
    private let green = NativeRGB(red: 0, green: 255, blue: 0)
    private let blue = NativeRGB(red: 0, green: 0, blue: 255)

    @MainActor
    private final class Fixture {
        let terminal: NativeTerminalScrollView
        let host: NativeTerminalAppearanceHost
        let window: NSWindow
        let theme: NativeTerminalTheme
        init(mode: TerminalPaddingFill = .automatic, padding: CGFloat = 8, opacity: CGFloat = 0) throws {
            terminal = NativeTerminalScrollView(driver: try GhosttyVTDriver())
            host = NativeTerminalAppearanceHost(terminal: terminal)
            window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 180),
                styleMask: [], backing: .buffered, defer: false)
            window.contentView = host
            theme = .init(name: "padding vector", foreground: .init(red: 255, green: 255, blue: 255),
                background: .init(red: 128, green: 64, blue: 32), cursor: nil, cursorText: nil,
                selectionForeground: nil, selectionBackground: nil,
                palette: [2: .init(red: 0, green: 255, blue: 0)])
            try host.apply(.init(theme: theme, padding: padding, paddingFill: mode, backgroundOpacity: opacity))
            let cell = terminal.renderer.cellSize
            host.setFrameSize(.init(width: cell.width * 6 + 3 + padding * 2,
                                    height: cell.height * 4 + 5 + padding * 2))
            host.layoutSubtreeIfNeeded()
            terminal.refresh(resizeTerminal: true)
            XCTAssertEqual(terminal.driver.columns, 6)
            XCTAssertEqual(terminal.driver.rows, 4)
        }
        isolated deinit { window.contentView = nil }
        func mode(_ value: TerminalPaddingFill, opacity: CGFloat = 0) throws {
            try host.apply(.init(theme: theme, padding: terminal.settings!.padding,
                                paddingFill: value, backgroundOpacity: opacity))
        }
        func screen() {
            terminal.feed("\u{1b}[?1049h\u{1b}[?25l\u{1b}[48;2;255;0;0m\u{1b}[2J" +
                "\u{1b}[4;1H\u{1b}[48;2;0;0;255m\u{1b}[2K" +
                "\u{1b}[4;4H\u{1b}[48;2;0;255;0m\u{1b}[K")
        }
    }

    /// Execute the actual AppKit painter in an explicitly sRGB bitmap. The
    /// display-dependent cacheDisplay profile otherwise changes RGB vectors.
    private func pixel(_ view: NSView, _ point: NSPoint) throws -> NSColor {
        let width = Int(ceil(view.bounds.width)), height = Int(ceil(view.bounds.height))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let x = min(width - 1, max(0, Int(point.x))), y = min(height - 1, max(0, Int(point.y)))
        let offset = y * context.bytesPerRow + x * 4
        let alpha = CGFloat(bytes[offset + 3]) / 255
        func channel(_ index: Int) -> CGFloat { alpha == 0 ? 0 : CGFloat(bytes[offset + index]) / 255 / alpha }
        return NSColor(srgbRed: channel(0), green: channel(1), blue: channel(2), alpha: alpha)
    }
    private func assertColor(_ actual: NSColor, _ expected: NativeRGB, alpha: CGFloat = 1,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.redComponent, CGFloat(expected.red) / 255, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, CGFloat(expected.green) / 255, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, CGFloat(expected.blue) / 255, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, alpha, accuracy: 0.02, file: file, line: line)
    }

    func testActualPixelsExtendOnlySidesWithoutPaintingTopBottomOrCells() throws {
        let f = try Fixture()
        f.screen()
        let fill = f.host.paddingFillView, h = fill.bounds.height
        let cell = f.terminal.renderer.cellSize
        assertColor(try pixel(fill, .init(x: 1, y: 8 + cell.height * 1.5)), red)
        assertColor(try pixel(fill, .init(x: 1, y: 8 + cell.height * 3.5)), blue)
        assertColor(try pixel(fill, .init(x: fill.bounds.width - 1, y: 8 + cell.height * 3.5)), green)
        for x in [CGFloat(1), fill.bounds.midX, fill.bounds.width - 1] {
            XCTAssertEqual(try pixel(fill, .init(x: x, y: 1)).alphaComponent, 0, accuracy: 0.01)
            XCTAssertEqual(try pixel(fill, .init(x: x, y: h - 1)).alphaComponent, 0, accuracy: 0.01)
        }
        XCTAssertEqual(try pixel(fill, .init(x: 10, y: 10)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertNil(fill.hitTest(.init(x: 1, y: 1)))
        XCTAssertNil(f.terminal.remainderFillView.hitTest(.zero))
    }

    func testZeroPaddingFillsOnlyRightRemainderForBothEngines() throws {
        for metal in [false, true] {
            let f = try Fixture(padding: 0)
            try f.terminal.setMetal(metal)
            f.screen()
            XCTAssertEqual(f.terminal.frame, f.host.bounds)
            let fill = f.terminal.remainderFillView
            let clip = fill.convert(f.terminal.contentView.bounds, from: f.terminal.contentView)
            let cell = f.terminal.renderer.cellSize
            assertColor(try pixel(fill, .init(x: clip.maxX - 1, y: clip.minY + cell.height * 1.5)), red)
            assertColor(try pixel(fill, .init(x: clip.maxX - 1, y: clip.minY + cell.height * 3.5)), green)
            for x in [clip.minX + cell.width, clip.maxX - 1] {
                XCTAssertEqual(try pixel(fill, .init(x: x, y: clip.maxY - 1)).alphaComponent, 0, accuracy: 0.01,
                               "Do not stretch status-line backgrounds vertically into incomplete-row space")
            }
            XCTAssertEqual(try pixel(fill, .init(x: clip.minX + 1, y: clip.minY + 1)).alphaComponent, 0, accuracy: 0.01)
        }
    }

    func testModesScreenExitAndResetClearOldPixelsWithoutResizeOrFocus() throws {
        let f = try Fixture()
        f.terminal.feed("\u{1b}[48;2;255;0;0m\u{1b}[2J")
        let fill = f.host.paddingFillView
        let point = NSPoint(x: 1, y: 8 + f.terminal.renderer.cellSize.height * 0.5)
        XCTAssertEqual(try pixel(fill, point).alphaComponent, 0, accuracy: 0.01)
        XCTAssertTrue(fill.isHidden)
        XCTAssertTrue(f.terminal.remainderFillView.isHidden)
        let before = f.terminal.viewport
        let responder = f.window.firstResponder
        var resizes = 0
        f.terminal.onViewportChange = { _ in resizes += 1 }
        try f.mode(.always)
        XCTAssertFalse(fill.isHidden)
        assertColor(try pixel(fill, point), red)
        f.screen()
        try f.mode(.off)
        XCTAssertTrue(fill.isHidden)
        XCTAssertEqual(try pixel(fill, point).alphaComponent, 0, accuracy: 0.01)
        try f.mode(.automatic)
        assertColor(try pixel(fill, point), red)
        f.terminal.feed("\u{1b}[?1049l")
        XCTAssertEqual(try pixel(fill, point).alphaComponent, 0, accuracy: 0.01)
        XCTAssertEqual(f.terminal.viewport, before)
        XCTAssertEqual(resizes, 0)
        XCTAssertTrue(f.window.firstResponder === responder)
        f.screen()
        f.terminal.resetPresentation()
        XCTAssertEqual(try pixel(fill, point).alphaComponent, 0, accuracy: 0.01)
    }

    func testPaletteInverseAndSelectionUseProgramBackgroundNotHighlight() throws {
        let f = try Fixture()
        f.screen()
        f.terminal.feed("\u{1b}[2;1H\u{1b}[0;32;7m \u{1b}[0m")
        let fill = f.host.paddingFillView
        let point = NSPoint(x: 1, y: 8 + f.terminal.renderer.cellSize.height * 1.5)
        assertColor(try pixel(fill, point), green)
        try f.terminal.driver.selectAll()
        f.terminal.refresh()
        assertColor(try pixel(fill, point), green)
        f.terminal.feed("\u{1b}]4;2;rgb:00/00/ff\u{7}")
        assertColor(try pixel(fill, point), blue)
    }

    func testTranslucentDefaultIsExtendedOnlyOutsideViewport() throws {
        let f = try Fixture(mode: .always, opacity: 0.25)
        f.terminal.feed("\u{1b}[?25l\u{1b}[0m\u{1b}[2J")
        assertColor(try pixel(f.host.paddingFillView, .init(x: 1, y: 10)), f.theme.background, alpha: 0.25)
        let fill = f.terminal.remainderFillView
        let clip = fill.convert(f.terminal.contentView.bounds, from: f.terminal.contentView)
        XCTAssertEqual(try pixel(fill, .init(x: clip.maxX - 1, y: clip.maxY - 1)).alphaComponent, 0, accuracy: 0.01,
                       "Do not composite default-background opacity twice")
    }

    func testSynchronizedOutputKeepsPublishedEdgesUntilHoldEnds() throws {
        let f = try Fixture()
        f.screen()
        let fill = f.host.paddingFillView
        let point = NSPoint(x: 1, y: 8 + f.terminal.renderer.cellSize.height * 0.5)
        f.terminal.feed("\u{1b}[?2026h\u{1b}[48;2;0;0;255m\u{1b}[2J")
        assertColor(try pixel(fill, point), red)
        f.terminal.feed("\u{1b}[?2026l")
        assertColor(try pixel(fill, point), blue)
    }

    func testProductionHostInsetsOnlyClipViewAndKeepsScrollerAtPaneEdge() throws {
        let terminal = NativeTerminalScrollView(driver: try GhosttyVTDriver())
        let host = TerminalPaneHostView(paneID: UUID(), terminalView: terminal)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 320),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        let theme = try NativeThemeCatalog.bundled().defaultTheme
        terminal.autohidesScrollers = false
        for padding: CGFloat in [0, 8, 24, 0] {
            try terminal.applySettings(.init(theme: theme, padding: padding))
            host.layoutSubtreeIfNeeded()
            terminal.tile()
            terminal.refresh(resizeTerminal: true)
            XCTAssertEqual(host.convert(terminal.bounds, from: terminal), host.bounds)
            let clip = host.convert(terminal.contentView.bounds, from: terminal.contentView)
            XCTAssertEqual(clip, host.bounds.insetBy(dx: padding, dy: padding))
            let scroller = try XCTUnwrap(terminal.verticalScroller)
            let rect = host.convert(scroller.bounds, from: scroller)
            XCTAssertEqual(rect.maxX, host.bounds.maxX, accuracy: 0.01)
            XCTAssertEqual(rect.minY, host.bounds.minY, accuracy: 0.01)
            XCTAssertEqual(rect.height, host.bounds.height, accuracy: 0.01)
        }
        XCTAssertTrue(terminal.outerPaddingFill === host.paddingFillView)
        XCTAssertTrue(terminal.remainderFillView.superview === terminal.renderer.superview)
        XCTAssertTrue(terminal.renderer.superview?.subviews.last === terminal.remainderFillView,
                      "Remainder decoration belongs in the document, below the scroll view's scroller")
    }

    func testHistoryEdgesTrackFractionalScrollWithoutNewRowConversions() throws {
        let f = try Fixture(mode: .always)
        f.terminal.feed((0..<100).map { row in
            "\u{1b}[48;2;\(row % 2 == 0 ? "255;0;0" : "0;0;255")m\u{1b}[2Krow-\(row)\r\n"
        }.joined())
        let h = f.terminal.renderer.cellSize.height
        f.terminal.contentView.scroll(to: .init(x: 0, y: 20.25 * h))
        f.terminal.reflectScrolledClipView(f.terminal.contentView)
        let viewport = try XCTUnwrap(f.terminal.presentedViewport)
        XCTAssertEqual(viewport.offset, 20.25 * h, accuracy: 0.01)
        let fill = f.host.paddingFillView
        assertColor(try pixel(fill, .init(x: 1, y: 8 + h * 0.25)), red)
        assertColor(try pixel(fill, .init(x: 1, y: 8 + h)), blue)
        let converted = f.terminal.source.convertedRows
        f.terminal.contentView.scroll(to: .init(x: 0, y: 20.5 * h))
        f.terminal.reflectScrolledClipView(f.terminal.contentView)
        XCTAssertEqual(f.terminal.source.convertedRows, converted)
        assertColor(try pixel(fill, .init(x: 1, y: 8 + h * 0.75)), blue)
    }

    func testPreferenceDefaultInvalidPersistenceResetAndNativeSnapshot() throws {
        let name = "santty-padding-fill.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(TerminalSettings.readPaddingFill(from: defaults), .automatic)
        XCTAssertNil(defaults.object(forKey: "terminal.paddingFill"))
        defaults.set("future-value", forKey: "terminal.paddingFill")
        XCTAssertEqual(TerminalSettings.readPaddingFill(from: defaults), .automatic)
        let changed = expectation(forNotification: TerminalSettings.didChangeNotification, object: nil)
        changed.expectedFulfillmentCount = 2
        TerminalSettings.setPaddingFill(.always, defaults: defaults)
        let catalog = try NativeThemeCatalog.bundled()
        XCTAssertEqual(NativeTerminalSettings.preferences(defaults, catalog: catalog).paddingFill, .always)
        TerminalSettings.resetPaddingFill(defaults: defaults)
        XCTAssertEqual(TerminalSettings.readPaddingFill(from: defaults), .automatic)
        XCTAssertNil(defaults.object(forKey: "terminal.paddingFill"))
        wait(for: [changed], timeout: 1)
    }
}
