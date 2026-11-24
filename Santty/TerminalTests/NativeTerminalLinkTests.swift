import AppKit
import XCTest
@testable import Santty

final class NativeTerminalLinkCoreTests: XCTestCase {
    func testConservativePolicyRejectsExecutableLocalInvisibleAndCredentialTargets() {
        for value in ["", "relative/file", "/tmp/a", "file:///tmp/a", "file://remote/private/a", "javascript:alert(1)",
                      "data:text/html,<script>", "x-apple.systempreferences:anything", "ssh://host", "https://", "mailto:",
                      "https://exa mple.com", "https://example.com/\n", "https://example.com/%0A",
                      "https://example.com/%00", "https://example.com/%C2%85", "https://example.com/\u{202e}spoof",
                      "https://example.com/%E2%80%AEspoof", "https://trusted@attacker.example/",
                      "https://user:password@example.com", "https://example.com/%not-valid"] {
            XCTAssertNil(NativeTerminalLink.url(value), value)
        }
        for value in ["https://example.com/path?q=1#anchor", "http://localhost:3000", "mailto:hello@example.com",
                      "https://example.com/中文", "https://example.com/a%20b"] {
            XCTAssertNotNil(NativeTerminalLink.url(value), value)
        }
        XCTAssertNil(NativeTerminalLink.url("https://example.com/" + String(repeating: "x", count: NativeTerminalLink.maximumBytes)))
    }

    func testOSC8OwnsUnicodeWrappedTargetsAndURIOnlyChangesInvalidateRows() throws {
        let driver = try GhosttyVTDriver(columns: 4, rows: 4)
        driver.feed("\u{1b}]8;id=one;https://example.com/one\u{1b}\\中e\u{301}ab\u{1b}]8;;\u{1b}\\")
        let first = try driver.snapshot(topRow: 0)
        XCTAssertEqual(first.rows[0]?.cells[0].hyperlink, "https://example.com/one")
        XCTAssertEqual(first.rows[0]?.cells[2].hyperlink, "https://example.com/one")
        XCTAssertEqual(first.rows[1]?.cells[0].hyperlink, "https://example.com/one")
        driver.reset()
        driver.feed("\u{1b}]8;;https://example.com/a\u{7}x\u{1b}]8;;\u{7}")
        let a = try driver.snapshot(topRow: 0)
        driver.feed("\r\u{1b}]8;;https://example.com/b\u{7}x\u{1b}]8;;\u{7}")
        let b = try driver.snapshot(topRow: 0)
        XCTAssertEqual(a.rows[0]?.cells[0].text, b.rows[0]?.cells[0].text)
        XCTAssertEqual(a.rows[0]?.cells[0].hyperlink, "https://example.com/a")
        XCTAssertEqual(b.rows[0]?.cells[0].hyperlink, "https://example.com/b")
        XCTAssertFalse(a.rows[0] === b.rows[0])
        driver.reset()
        XCTAssertEqual(first.rows[0]?.cells[0].hyperlink, "https://example.com/one", "owned URI outlives the C row")
        for uri in ["https://example.com/\u{e9}", "https://example.com/e\u{301}"] {
            driver.feed("\r\u{1b}]8;;\(uri)\u{1b}\\x\u{1b}]8;;\u{1b}\\")
            let stored = try XCTUnwrap(driver.snapshot(topRow: 0).rows[0]?.cells[0].hyperlink)
            XCTAssertEqual(Array(stored.utf8), Array(uri.utf8), "row reuse must not normalize distinct URL bytes")
        }
    }

    func testImplicitSchemeURLsUseFixedRangesAndTrimSurroundingPunctuation() throws {
        let driver = try GhosttyVTDriver(columns: 100, rows: 4)
        for (text, column, uri) in [
            ("see (https://example.com/a).", 8, "https://example.com/a"),
            ("http://localhost:3000/a?q=1#b,", 10, "http://localhost:3000/a?q=1#b"),
            ("mailto:hello@example.com", 10, "mailto:hello@example.com"),
            ("HTTPS://example.com/a(b)", 12, "HTTPS://example.com/a(b)"),
            ("https://[2001:db8::1]:443/path", 12, "https://[2001:db8::1]:443/path"),
        ] {
            driver.reset(); driver.feed(text)
            let match = try XCTUnwrap(NativeTerminalLinkMatcher.match(in: driver.snapshot(topRow: 0), column: column, row: 0), text)
            XCTAssertEqual(match.uri, uri)
            XCTAssertFalse(match.isExplicit)
        }
        driver.reset(); driver.feed("https://example.com/a https://example.com/b")
        let frame = try driver.snapshot(topRow: 0)
        XCTAssertEqual(NativeTerminalLinkMatcher.match(in: frame, column: 2, row: 0)?.ranges, [0: 0..<21])
        XCTAssertEqual(NativeTerminalLinkMatcher.match(in: frame, column: 25, row: 0)?.uri, "https://example.com/b")
        XCTAssertNil(NativeTerminalLinkMatcher.match(in: frame, column: 21, row: 0))
    }

    func testImplicitMappingUsesUTF16WideCellsCombiningMarksAndVTSoftWraps() throws {
        let driver = try GhosttyVTDriver(columns: 12, rows: 8)
        driver.feed("中文e\u{301} https://example.com/a")
        let frame = try driver.snapshot(topRow: 0)
        for (column, row) in [(6, 0), (4, 1), (1, 2)] {
            let match = try XCTUnwrap(NativeTerminalLinkMatcher.match(in: frame, column: column, row: row))
            XCTAssertEqual(match.uri, "https://example.com/a")
            XCTAssertEqual(match.ranges, [0: 6..<12, 1: 0..<12, 2: 0..<3])
        }
        let wide = try GhosttyVTDriver(columns: 17, rows: 5)
        wide.feed("https://e.test/a中b")
        let wrapped = try wide.snapshot(topRow: 0)
        XCTAssertTrue(try XCTUnwrap(wrapped.rows[0]?.cells[16]).isWrapSpacer)
        let match = try XCTUnwrap(NativeTerminalLinkMatcher.match(in: wrapped, column: 1, row: 1))
        XCTAssertEqual(match.uri, "https://e.test/a中b")
        XCTAssertEqual(match.ranges, [0: 0..<16, 1: 0..<3])
        driver.reset(); driver.feed("https://e.x\r\n/other")
        XCTAssertNil(NativeTerminalLinkMatcher.match(in: try driver.snapshot(topRow: 0), column: 1, row: 1))
    }

    func testImplicitDetectionNeverOpensUnsafeOrUnsupportedWordPrefixes() throws {
        let driver = try GhosttyVTDriver(columns: 100, rows: 4)
        for text in ["file:///tmp/a", "ssh://host", "javascript:https://example.com/a", "https://user@evil.example",
                     "https://example.com/%0a", "https://example.com/%E2%80%AEa", "https://example.com/\u{202e}a",
                     "https://example.com/a|b", "https://example.com/a\\b", "https://[" + String(repeating: "a", count: 1024)] {
            driver.reset(); driver.feed(text)
            XCTAssertNil(NativeTerminalLinkMatcher.match(in: try driver.snapshot(topRow: 0), column: 2, row: 0), text)
        }
        driver.reset()
        driver.feed("\u{1b}]8;;javascript:alert(1)\u{1b}\\https://example.com/a\u{1b}]8;;\u{1b}\\")
        let explicit = try XCTUnwrap(NativeTerminalLinkMatcher.match(in: driver.snapshot(topRow: 0), column: 2, row: 0))
        XCTAssertTrue(explicit.isExplicit)
        XCTAssertEqual(explicit.uri, "javascript:alert(1)", "unsafe OSC 8 must not fall back to the visible URL")
    }

    func testBoundedFrameNeverTurnsAClippedURLIntoAnOpenablePrefix() throws {
        let driver = try GhosttyVTDriver(columns: 16, rows: 4)
        driver.feed("https://example.com/" + String(repeating: "x", count: 200))
        let clipped = try driver.snapshot(topRow: 0)
        XCTAssertLessThan(try XCTUnwrap(clipped.rows.keys.max()), clipped.totalRows - 1)
        XCTAssertNil(NativeTerminalLinkMatcher.match(in: clipped, column: 2, row: 0))
    }

    func testOverBudgetExplicitTargetCannotFallBackToItsVisibleLabel() throws {
        let driver = try GhosttyVTDriver(columns: 80, rows: 4)
        let uri = "https://example.com/" + String(repeating: "x", count: 1000)
        driver.feed("\u{1b}]8;;\(uri)\u{1b}\\" + String(repeating: "https://e.x ", count: 25))
        let frame = try driver.snapshot(topRow: 0)
        let dropped = try XCTUnwrap(frame.rows.keys.sorted().compactMap { row -> (Int, Int)? in
            guard let cells = frame.rows[row]?.cells,
                  let column = cells.firstIndex(where: { $0.hasExplicitHyperlink && $0.hyperlink == nil && $0.text == "h" }) else { return nil }
            return (row, column)
        }.first)
        XCTAssertNil(NativeTerminalLinkMatcher.match(in: frame, column: dropped.1, row: dropped.0))
    }

    func testURIPayloadBudgetBoundsSnapshotsIncludingReusedRows() throws {
        let base = "https://example.com/"
        let uri = base + String(repeating: "x", count: 1024 - base.utf8.count)
        let driver = try GhosttyVTDriver(columns: 80, rows: 4)
        driver.feed("\u{1b}]8;;\(uri)\u{1b}\\" + String(repeating: "z", count: 200))
        for _ in 0..<2 {
            let frame = try driver.snapshot(topRow: 0)
            let bytes = frame.rows.values.reduce(0) { $0 + $1.hyperlinkBytes }
            XCTAssertGreaterThan(bytes, 0)
            XCTAssertLessThanOrEqual(bytes, NativeTerminalLink.frameByteBudget)
        }
        driver.reset()
        let oversized = base + String(repeating: "x", count: NativeTerminalLink.maximumBytes)
        driver.feed("\u{1b}]8;;\(oversized)\u{1b}\\z")
        XCTAssertNil(try driver.snapshot(topRow: 0).rows[0]?.cells[0].hyperlink)
    }
}

@MainActor
final class NativeTerminalLinkViewTests: XCTestCase {
    private func setup(_ uri: String, label: String = "click here", explicit: Bool = true) throws -> (NSWindow, NativeTerminalScrollView, LinkBytes) {
        let view = NativeTerminalScrollView(driver: try GhosttyVTDriver(), frame: NSRect(x: 0, y: 0, width: 640, height: 245))
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        let text = explicit ? "\u{1b}]8;;\(uri)\u{1b}\\\(label)\u{1b}]8;;\u{1b}\\" : uri
        view.feed("\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1006h" + text)
        let bytes = LinkBytes(), output = NativeTerminalOutput(driver: view.driver) { _ in }
        output.bind(writer: { bytes.append($0) }); output.setInputEnabled(true)
        view.renderer.output = output; view.renderer.inputEnabled = true
        return (window, view, bytes)
    }
    private func event(_ type: NSEvent.EventType, _ window: NSWindow, _ view: NativeTerminalScrollView,
                       x: CGFloat = 0.5, command: Bool = true) throws -> NSEvent {
        let point = CGPoint(x: view.renderer.cellSize.width * x,
            y: view.documentVisibleRect.minY + view.renderer.cellSize.height / 2)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: try XCTUnwrap(view.documentView).convert(point, to: nil),
            modifierFlags: command ? .command : [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testPlainURLCommandClickOpensWithoutOSC8AndDoesNotSendInput() throws {
        let (window, view, bytes) = try setup("https://example.com/path", explicit: false)
        defer { window.contentView = nil }
        var opened: [URL] = []; view.openLink = { opened.append($0); return true }
        view.renderer.mouseDown(with: try event(.leftMouseDown, window, view, x: 10))
        view.renderer.mouseUp(with: try event(.leftMouseUp, window, view, x: 10))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/path"])
        XCTAssertTrue(bytes.data.isEmpty)
    }

    func testCommandHoverActuallyUnderlinesTheLinkAndClearsIt() throws {
        let (window, view, bytes) = try setup("https://example.com/target")
        defer { window.contentView = nil }
        view.renderer.mouseMoved(with: try event(.mouseMoved, window, view))
        XCTAssertTrue(try XCTUnwrap(view.source.lines[0]?[0].attribute.style).contains(.underline))
        view.renderer.mouseMoved(with: try event(.mouseMoved, window, view, command: false))
        XCTAssertFalse(try XCTUnwrap(view.source.lines[0]?[0].attribute.style).contains(.underline))
        XCTAssertTrue(bytes.data.isEmpty)
    }

    func testStationaryPointerGetsUnderlineWhenCommandIsPressed() throws {
        let (window, view, _) = try setup("https://example.com/path", explicit: false)
        defer { window.contentView = nil }
        view.renderer.mouseMoved(with: try event(.mouseMoved, window, view, x: 10, command: false))
        let flags = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero,
            modifierFlags: .command, timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
        view.renderer.flagsChanged(with: flags)
        XCTAssertTrue(try XCTUnwrap(view.source.lines[0]?[10].attribute.style).contains(.underline))
    }

    func testHoverProducesActualCoreGraphicsPixelsAndMouseExitRestoresThem() throws {
        let (window, view, _) = try setup("https://example.com/path", explicit: false)
        defer { window.contentView = nil }
        func pixels() throws -> Data {
            let bitmap = try XCTUnwrap(view.renderer.bitmapImageRepForCachingDisplay(in: view.renderer.bounds))
            view.renderer.cacheDisplay(in: view.renderer.bounds, to: bitmap)
            return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let originalFrame = try XCTUnwrap(view.presentedFrame)
        let converted = view.source.convertedRows
        let original = try pixels()
        let responder = window.firstResponder
        view.renderer.mouseMoved(with: try event(.mouseMoved, window, view, x: 10))
        XCTAssertNotEqual(try pixels(), original, "a tooltip/attribute assertion alone is not visible underlining")
        XCTAssertEqual(view.source.convertedRows, converted + 1, "only the decorated row should be rebuilt")
        XCTAssertTrue(view.presentedFrame?.rows[0] === originalFrame.rows[0], "hover must not sample new VT output")
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertFalse(view.renderer.linkCursorRects.isEmpty)
        view.renderer.mouseExited(with: try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
            modifierFlags: .command, timestamp: 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil)))
        XCTAssertEqual(try pixels(), original)
        XCTAssertTrue(view.renderer.linkCursorRects.isEmpty)
        XCTAssertNil(view.renderer.toolTip)
    }

    func testDeferredHoverClearIsNotLostWhenTheNextEventHasTheSameEmptyRange() throws {
        let (window, view, _) = try setup("https://example.com/path", explicit: false)
        defer { window.contentView = nil }
        view.renderer.mouseMoved(with: try event(.mouseMoved, window, view, x: 10))
        XCTAssertTrue(try XCTUnwrap(view.source.lines[0]?[10].attribute.style).contains(.underline))
        // No hidden connected surface may draw just because focus/reset changes.
        let converted = view.source.convertedRows
        view.renderer.resetInputState()
        XCTAssertTrue(view.source.highlightedLink.isEmpty)
        XCTAssertEqual(view.source.convertedRows, converted)
        view.renderer.mouseMoved(with: try event(.mouseMoved, window, view, x: 10, command: false))
        XCTAssertFalse(try XCTUnwrap(view.source.lines[0]?[10].attribute.style).contains(.underline))
    }

    func testUnpresentedPlainURLRewriteAndResetCannotOpenStaleText() throws {
        for (original, change) in [
            ("https://example.com/old", "\rhttps://example.com/new"),
            ("https://example.com/\u{e9}", "\rhttps://example.com/e\u{301}"),
            ("https://example.com/old", "\u{1b}c"),
        ] {
            let (window, view, bytes) = try setup(original, explicit: false)
            defer { window.contentView = nil }
            var opened = false; view.openLink = { _ in opened = true; return true }
            view.renderer.mouseDown(with: try event(.leftMouseDown, window, view, x: 10))
            view.driver.feed(change)
            view.renderer.mouseUp(with: try event(.leftMouseUp, window, view, x: 10))
            XCTAssertFalse(opened, change)
            XCTAssertTrue(bytes.data.isEmpty)
        }
    }

    func testStationaryHoverRehitsAfterFractionalScrollFontAndWidthChanges() throws {
        let (window, view, _) = try setup("https://example.com/path", explicit: false)
        defer { window.contentView = nil }
        view.renderer.output = nil // a fixture view, not a hidden connected surface
        view.reset(with: (0..<200).map { "https://example.com/item-\($0)\r\n" }.joined())
        let h = view.renderer.cellSize.height
        view.contentView.scroll(to: CGPoint(x: 0, y: 20.25 * h))
        view.renderer.mouseMoved(with: try event(.mouseMoved, window, view, x: 10))
        XCTAssertEqual(view.renderer.toolTip, "https://example.com/item-20")
        let frame = try XCTUnwrap(view.presentedFrame)
        view.contentView.scroll(to: CGPoint(x: 0, y: 20.75 * h))
        XCTAssertEqual(view.renderer.toolTip, "https://example.com/item-21")
        XCTAssertEqual(Set(view.source.highlightedLink.keys), [21])
        XCTAssertTrue(view.presentedFrame?.rows[20] === frame.rows[20], "fraction-only rehit must reuse the published frame")
        view.renderer.font = .monospacedSystemFont(ofSize: 19, weight: .regular)
        view.setFrameSize(NSSize(width: 420, height: 245))
        view.layoutSubtreeIfNeeded(); view.refresh(resizeTerminal: true)
        XCTAssertEqual(view.renderer.toolTip, "https://example.com/item-21")
        var opened: [URL] = []; view.openLink = { opened.append($0); return true }
        view.renderer.mouseDown(with: try event(.leftMouseDown, window, view, x: 10))
        view.renderer.mouseUp(with: try event(.leftMouseUp, window, view, x: 10))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/item-21"])
    }

    func testCommandReleaseClearsHoverWithoutRemovingProgramUnderlines() throws {
        let (window, view, _) = try setup("https://example.com/path", label: "\u{1b}[4:2mclick\u{1b}[0m here")
        defer { window.contentView = nil }
        view.renderer.mouseMoved(with: try event(.mouseMoved, window, view))
        let released = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
        view.renderer.flagsChanged(with: released)
        XCTAssertTrue(view.source.highlightedLink.isEmpty)
        XCTAssertEqual(view.source.lines[0]?[0].attribute.underlineStyle.rawValue, 2)
        XCTAssertFalse(try XCTUnwrap(view.source.lines[0]?[6].attribute.style).contains(.underline))
        XCTAssertNil(view.renderer.toolTip)
    }

    func testExplicitCmdClickOpensOnlyOnReleaseAndNeverAlsoReportsMouse() throws {
        let (window, view, bytes) = try setup("https://example.com/actual-target", label: "not the target")
        defer { window.contentView = nil }
        var opened: [URL] = []; view.openLink = { opened.append($0); return true }
        view.renderer.mouseDown(with: try event(.leftMouseDown, window, view))
        XCTAssertTrue(opened.isEmpty)
        view.renderer.mouseUp(with: try event(.leftMouseUp, window, view))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/actual-target"])
        XCTAssertTrue(bytes.data.isEmpty)
    }

    func testUnsafeCmdClickIsConsumedWithoutOpeningOrProgramInput() throws {
        for uri in ["javascript:alert(1)", "file:///tmp/private", "file://remote/tmp/private", "https://user@evil.example"] {
            let (window, view, bytes) = try setup(uri)
            defer { window.contentView = nil }
            var opened = false; view.openLink = { _ in opened = true; return true }
            view.renderer.mouseDown(with: try event(.leftMouseDown, window, view))
            view.renderer.mouseUp(with: try event(.leftMouseUp, window, view))
            XCTAssertFalse(opened, uri)
            XCTAssertTrue(bytes.data.isEmpty, uri)
        }
    }

    func testCommandGestureWithoutALinkCannotLeakAsAnOrdinaryProgramClick() throws {
        let (window, view, bytes) = try setup("https://example.com")
        defer { window.contentView = nil }
        view.driver.feed("\u{1b}[?1003h")
        view.renderer.mouseMoved(with: try event(.mouseMoved, window, view, x: 40))
        view.renderer.mouseDown(with: try event(.leftMouseDown, window, view, x: 40))
        view.renderer.mouseUp(with: try event(.leftMouseUp, window, view, x: 40))
        XCTAssertTrue(bytes.data.isEmpty)
    }

    func testTinyClickMovementAcrossAdjacentLinkCellsStillOpens() throws {
        let (window, view, bytes) = try setup("https://example.com/target")
        defer { window.contentView = nil }
        var opened = false; view.openLink = { _ in opened = true; return true }
        view.renderer.mouseDown(with: try event(.leftMouseDown, window, view, x: 0.95))
        view.renderer.mouseUp(with: try event(.leftMouseUp, window, view, x: 1.05))
        XCTAssertTrue(opened)
        XCTAssertTrue(bytes.data.isEmpty)
    }

    func testWideTailCmdClickResolvesToItsHead() throws {
        let (window, view, bytes) = try setup("https://example.com/wide", label: "中")
        defer { window.contentView = nil }
        var opened = false; view.openLink = { _ in opened = true; return true }
        view.renderer.mouseDown(with: try event(.leftMouseDown, window, view, x: 1.5))
        view.renderer.mouseUp(with: try event(.leftMouseUp, window, view, x: 1.5))
        XCTAssertTrue(opened); XCTAssertTrue(bytes.data.isEmpty)
    }

    func testDragOrChangedTargetOrResetDoesNotOpenStalePress() throws {
        for scenario in 0..<5 {
            let (window, view, _) = try setup(scenario == 4 ? "https://example.com/\u{e9}" : "https://example.com/old")
            defer { window.contentView = nil }
            var opened = false; view.openLink = { _ in opened = true; return true }
            view.renderer.mouseDown(with: try event(.leftMouseDown, window, view))
            if scenario == 0 { view.renderer.mouseDragged(with: try event(.leftMouseDragged, window, view, x: 5)) }
            if scenario == 1 { view.driver.feed("\r\u{1b}]8;;https://example.com/new\u{1b}\\click here\u{1b}]8;;\u{1b}\\") }
            if scenario == 2 { view.driver.reset() }
            if scenario == 3 { view.renderer.onInputActivity?() }
            if scenario == 4 { view.driver.feed("\r\u{1b}]8;;https://example.com/e\u{301}\u{1b}\\click here\u{1b}]8;;\u{1b}\\") }
            view.renderer.mouseUp(with: try event(.leftMouseUp, window, view))
            XCTAssertFalse(opened)
        }
    }

    func testPlainClickAndOrphanReleaseNeverOpenLink() throws {
        let (window, view, _) = try setup("https://example.com")
        defer { window.contentView = nil }
        var opened = false; view.openLink = { _ in opened = true; return true }
        view.renderer.mouseUp(with: try event(.leftMouseUp, window, view))
        view.renderer.mouseDown(with: try event(.leftMouseDown, window, view, command: false))
        view.renderer.mouseUp(with: try event(.leftMouseUp, window, view, command: false))
        XCTAssertFalse(opened)
    }
}

private final class LinkBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func append(_ data: Data) { lock.withLock { value.append(data) } }
    var data: Data { lock.withLock { value } }
}
