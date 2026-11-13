import AppKit
import XCTest
@testable import SanttyTerminalLab

@MainActor
final class NativeTerminalAccessibilityTests: XCTestCase {
    private func make() throws -> NativeTerminalScrollView {
        let view = NativeTerminalScrollView(driver: try GhosttyVTDriver(), frame: CGRect(x: 0, y: 0, width: 640, height: 240))
        view.refresh(resizeTerminal: true)
        return view
    }

    func testInvalidAndSurrogateSplittingRangesAreRejectedWithoutOverflow() throws {
        let view = try make(); view.feed("a😀b")
        for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: Int.max, length: Int.max),
                      NSRange(location: -1, length: 1), NSRange(location: 0, length: -1),
                      NSRange(location: 2, length: 1), NSRange(location: 1, length: 1)] {
            XCTAssertNil(view.renderer.accessibilityString(for: range))
            XCTAssertEqual(view.renderer.accessibilityFrame(for: range), .zero)
        }
        XCTAssertEqual(view.renderer.accessibilityRange(for: -1).location, NSNotFound)
        XCTAssertEqual(view.renderer.accessibilityLine(for: Int.max), -1)
        XCTAssertEqual(view.renderer.accessibilityRange(forLine: -1).location, NSNotFound)
        XCTAssertEqual(view.renderer.accessibilityRange(for: CGPoint(x: CGFloat.nan, y: 0)).location, NSNotFound)
    }

    func testConcealedTextAndImagePlaceholdersAreNotExposedAsAXContent() throws {
        let view = try make()
        view.feed("before\u{1b}[8msecret\u{1b}[28mafter\r\n\u{1b}[38;5;7m\u{10eeee}\u{305}\u{305}label")
        let text = try XCTUnwrap(view.renderer.accessibilityValue() as? String)
        XCTAssertEqual(text, "beforeafter\nlabel")
        XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("\u{10eeee}"))
        XCTAssertFalse(view.renderer.accessibleTerminal.limited)
    }

    func testPhysicalSoftWrapLinesAndWideWrapSpacerMapToVTText() throws {
        let driver = try GhosttyVTDriver(columns: 8, rows: 4)
        driver.feed("1234567界x")
        let frame = try driver.snapshot(topRow: 0), model = NativeTerminalAccessibility(frame: frame)
        XCTAssertFalse(model.limited)
        XCTAssertEqual(model.text, "1234567\n界x")
        XCTAssertEqual(model.rangeForLine(0), NSRange(location: 0, length: 8))
        XCTAssertEqual(model.range(row: 1, column: 1), NSRange(location: 8, length: 1))
        XCTAssertEqual(model.line(for: 8), 1)
    }

    func testZeroWidthJoinerGraphemeAndCombiningSequenceHaveWholeCellRanges() throws {
        let view = try make(); view.feed("👩‍👩‍👦e\u{301}")
        let value = try XCTUnwrap(view.renderer.accessibilityValue() as? String)
        let familyLength = "👩‍👩‍👦".utf16.count
        XCTAssertEqual(value, "👩‍👩‍👦e\u{301}")
        for index in 0..<familyLength { XCTAssertEqual(view.renderer.accessibilityRange(for: index), NSRange(location: 0, length: familyLength)) }
        XCTAssertEqual(view.renderer.accessibilityRange(for: familyLength + 1), NSRange(location: familyLength, length: 2))
    }

    func testAXReadsStayOnThePublishedFrameThroughUnpresentedOutputAndHold() throws {
        let view = try make(); view.feed("shown")
        var notifications: [NSAccessibility.Notification] = []
        view.renderer.onAccessibilityNotification = { notifications.append($0) }
        view.driver.feed("\r\nunpublished")
        XCTAssertEqual(view.renderer.accessibilityValue() as? String, "shown")
        XCTAssertTrue(notifications.isEmpty)
        view.driver.feed("\u{1b}[?2026hpartial")
        view.refresh()
        XCTAssertEqual(view.renderer.accessibilityValue() as? String, "shown")
        view.driver.feed("\u{1b}[?2026l"); view.refresh()
        XCTAssertTrue((view.renderer.accessibilityValue() as? String)?.contains("unpublishedpartial") == true)
        XCTAssertTrue(notifications.contains(.valueChanged))
        view.resetPresentation()
        XCTAssertEqual(view.renderer.accessibilityValue() as? String, "")
    }

    func testAXReadsAndWritesDoNotMutateSelectionInputClipboardOrFirstResponder() throws {
        let view = try make(), bytes = AXTestBytes()
        let output = NativeTerminalOutput(driver: view.driver) { _ in }
        output.bind(writer: { bytes.append($0) }); output.setInputEnabled(true)
        view.renderer.output = output
        // Fixture presentation before binding output; a hidden connected view
        // deliberately does not publish output merely for an AX query.
        view.renderer.output = nil; view.feed("do not execute"); try view.driver.selectAll(); view.refresh(); view.renderer.output = output
        let selected = try view.driver.selectedText()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("private sentinel", forType: .string)
        view.renderer.setAccessibilityValue("unexpected input\n")
        view.renderer.setAccessibilitySelectedText("replacement")
        view.renderer.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 1))
        view.renderer.setAccessibilitySelectedTextRanges([NSValue(range: NSRange(location: 0, length: 1))])
        view.renderer.setAccessibilityFocused(true)
        _ = view.renderer.accessibilityAttributedString(for: NSRange(location: 0, length: 2))
        _ = view.renderer.accessibilitySelectedText()
        XCTAssertEqual(try view.driver.selectedText(), selected)
        XCTAssertEqual(view.renderer.accessibilitySelectedText(), selected)
        XCTAssertEqual(bytes.count, 0)
        XCTAssertEqual(board.string(forType: .string), "private sentinel")
        XCTAssertNil(view.window)
    }

    func testPointAndFrameRangesUseAppKitPointsWideCellsAndScreenCoordinates() throws {
        let view = try make()
        let window = NSWindow(contentRect: CGRect(x: 150, y: 220, width: 640, height: 240), styleMask: [], backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        view.feed("界😀e\u{301}")
        let responder = window.firstResponder, cell = view.renderer.cellSize
        let local = CGPoint(x: cell.width * 3.5, y: view.renderer.bounds.maxY - cell.height * 0.5)
        let screen = window.convertPoint(toScreen: view.renderer.convert(local, to: nil))
        XCTAssertEqual(view.renderer.accessibilityRange(for: screen), NSRange(location: 1, length: 2))
        let rect = view.renderer.accessibilityFrame(for: NSRange(location: 1, length: 2))
        XCTAssertEqual(rect.width, cell.width * 2, accuracy: 0.01)
        XCTAssertEqual(rect.height, cell.height, accuracy: 0.01)
        XCTAssertTrue(rect.contains(screen))
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertEqual(view.renderer.accessibilityChildren()?.count, 0)
        XCTAssertTrue((view.renderer.accessibilityHitTest(screen) as AnyObject?) === view.renderer)
    }

    func testNativeFractionalScrollClipsAXBoundsAndExcludesOverscanFromVisibleRange() throws {
        let view = try make()
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        view.feed((0..<200).map { String(format: "row%03d\r\n", $0) }.joined())
        view.contentView.scroll(to: .zero)
        let value = view.renderer.accessibilityValue() as? String
        let rows = view.source.convertedRows, h = view.renderer.cellSize.height
        var notifications: [NSAccessibility.Notification] = []
        view.renderer.onAccessibilityNotification = { notifications.append($0) }
        view.contentView.scroll(to: CGPoint(x: 0, y: h / 4))
        XCTAssertEqual(view.renderer.accessibilityValue() as? String, value)
        XCTAssertEqual(view.source.convertedRows, rows)
        XCTAssertFalse(notifications.contains(.valueChanged)); XCTAssertTrue(notifications.contains(.layoutChanged))
        XCTAssertEqual(view.renderer.accessibilityFrame(for: NSRange(location: 0, length: 6)).height, h * 0.75, accuracy: 0.01)
        XCTAssertLessThan(view.renderer.accessibilityVisibleCharacterRange().length, view.renderer.accessibilityNumberOfCharacters())
        XCTAssertEqual(view.renderer.accessibilitySelectedTextRange().location, NSNotFound, "live cursor is outside the published history page")
    }

    func testFormatterCacheAndAXNotificationsIgnoreImageOnlyAnimationTicks() throws {
        let clock = NativeAnimationTestClock(), driver = try GhosttyVTDriver(animationClock: { clock.milliseconds })
        let view = NativeTerminalInputView(frame: CGRect(x: 0, y: 0, width: 640, height: 240))
        driver.feed(NativeAnimationFixture.finite)
        let first = try XCTUnwrap(driver.presentation(rowHeight: 16, viewportHeight: 240, previous: nil)).frame
        view.publishAccessibility(first, topRow: first.topRow)
        var notifications: [NSAccessibility.Notification] = []
        view.onAccessibilityNotification = { notifications.append($0) }
        clock.set(101)
        let second = try XCTUnwrap(driver.presentation(rowHeight: 16, viewportHeight: 240, previous: nil)).frame
        view.publishAccessibility(second, topRow: second.topRow)
        XCTAssertTrue(first.accessibleText === second.accessibleText)
        XCTAssertTrue(notifications.isEmpty)
    }

    func testEmptyRowsCursorAndHardLineRangesRemainSafe() throws {
        let view = try make(); view.feed("a\r\n\r\nb\r\n")
        XCTAssertEqual(view.renderer.accessibilityValue() as? String, "a\n\nb")
        XCTAssertEqual(view.renderer.accessibilityRange(forLine: 1), NSRange(location: 2, length: 1))
        XCTAssertEqual(view.renderer.accessibilitySelectedTextRange(), NSRange(location: 4, length: 0))
        XCTAssertEqual(view.renderer.accessibilityInsertionPointLineNumber(), 3)
    }

    func testBoundedAXCaptureRefusesHugePagesWithoutStoppingTerminalRendering() throws {
        let driver = try GhosttyVTDriver(columns: 1024, rows: 257)
        let frame = try driver.snapshot(topRow: 0)
        XCTAssertTrue(frame.accessibleText.limited)
        XCTAssertEqual(frame.rows.count, 257)
        XCTAssertTrue(NativeTerminalAccessibility(frame: frame).limited)
        try driver.resize(columns: 80, rows: 24)
        XCTAssertFalse(try driver.snapshot(topRow: 0).accessibleText.limited)
        var small = try GhosttyVTDriver(columns: 8, rows: 4).snapshot(topRow: 0)
        small.accessibleText = NativeAXFormattedText(String(repeating: "x", count: GhosttyVTAccessibleText.maximumBytes + 1))
        XCTAssertTrue(NativeTerminalAccessibility(frame: small).limited)
    }

    func testUnicodeGraphemeModeStillUsesTheSameAXUTF16Contract() throws {
        let view = try make(); view.feed("\u{1b}[?2027h👩‍👩‍👦e\u{301}")
        let length = "👩‍👩‍👦".utf16.count
        for index in 0..<length { XCTAssertEqual(view.renderer.accessibilityRange(for: index), NSRange(location: 0, length: length)) }
        XCTAssertEqual(view.renderer.accessibilityString(for: NSRange(location: 0, length: length)), "👩‍👩‍👦")
    }

    func testCanonicalEquivalentOutputStillUpdatesUTF16AndValueNotification() throws {
        let view = try make(); view.feed("é")
        var changed = false
        view.renderer.onAccessibilityNotification = { if $0 == .valueChanged { changed = true } }
        view.feed("\r\u{1b}[Ke\u{301}")
        XCTAssertEqual(view.renderer.accessibilityNumberOfCharacters(), 2)
        XCTAssertTrue(changed)
        XCTAssertEqual(view.renderer.accessibilityRange(for: 1), NSRange(location: 0, length: 2))
    }

    func testMetalAndCoreGraphicsShareTheSameAXElementAndText() throws {
        let view = try make()
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        view.feed("one terminal element")
        let before = view.renderer.accessibilityValue() as? String
        try view.setMetal(true)
        XCTAssertEqual(view.renderer.accessibilityValue() as? String, before)
        XCTAssertEqual(view.renderer.accessibilityChildren()?.count, 0)
        XCTAssertTrue(NSAccessibility.unignoredDescendant(of: view.renderer) as AnyObject === view.renderer)
        try view.setMetal(false)
        XCTAssertEqual(view.renderer.accessibilityValue() as? String, before)
    }

    func testAXPageOnlySelectionDoesNotChangeTheFullVTSelectionOrHistoryViewport() throws {
        let view = try make()
        view.feed((0..<200).map { "history-\($0)\r\n" }.joined())
        view.contentView.scroll(to: .zero)
        try view.driver.selectAll(); view.refresh()
        let copied = try view.driver.selectedText(), viewport = view.presentedViewport
        let ax = try XCTUnwrap(view.renderer.accessibilitySelectedText())
        XCTAssertTrue(ax.contains("history-0")); XCTAssertFalse(ax.contains("history-199"))
        XCTAssertNotEqual(ax, copied)
        for _ in 0..<10 { _ = view.renderer.accessibilityVisibleCharacterRange(); _ = view.renderer.accessibilitySelectedText() }
        XCTAssertEqual(try view.driver.selectedText(), copied)
        XCTAssertEqual(view.presentedViewport?.offset, viewport?.offset)
    }

    func testLocalPreeditIsNotDuplicatedAsCommittedTerminalAXText() throws {
        let view = try make(); view.feed("committed")
        view.renderer.inputEnabled = true
        view.renderer.setMarkedText("local composition", selectedRange: NSRange(location: 0, length: 5), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.renderer.hasMarkedText())
        XCTAssertEqual(view.renderer.accessibilityValue() as? String, "committed")
        XCTAssertEqual(view.renderer.accessibilityChildren()?.count, 0)
        XCTAssertTrue(view.renderer.subviews.allSatisfy { !$0.isAccessibilityElement() })
        view.renderer.unmarkText()
    }

    func testFontResizeRefreshesAXGeometryAndAttributedFontWithoutInput() throws {
        let view = try make()
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        view.feed("界😀e\u{301}")
        let text = view.renderer.accessibilityValue() as? String
        let old = view.renderer.accessibilityFrame(for: NSRange(location: 1, length: 2))
        view.renderer.font = .monospacedSystemFont(ofSize: 20, weight: .regular)
        view.refresh(resizeTerminal: true)
        let next = view.renderer.accessibilityFrame(for: NSRange(location: 1, length: 2))
        XCTAssertEqual(view.renderer.accessibilityValue() as? String, text)
        XCTAssertGreaterThan(next.width, old.width)
        XCTAssertEqual(next.width, view.renderer.cellSize.width * 2, accuracy: 0.01)
        let attributed = try XCTUnwrap(view.renderer.accessibilityAttributedString(for: NSRange(location: 1, length: 2)))
        XCTAssertEqual((attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 20)
    }

    func testTerminalPublishesAReadOnlyTextAreaNotAnEditableValue() throws {
        let view = try make()
        XCTAssertTrue(view.renderer.isAccessibilityElement())
        XCTAssertEqual(view.renderer.accessibilityRole(), .textArea)
        for selector in ["accessibilityValue", "accessibilityStringForRange:", "accessibilityRangeForPosition:", "accessibilityFrameForRange:"] {
            XCTAssertTrue(view.renderer.isAccessibilitySelectorAllowed(NSSelectorFromString(selector)), selector)
        }
        XCTAssertFalse(view.renderer.isAccessibilitySelectorAllowed(#selector(NSAccessibilityProtocol.setAccessibilityValue(_:))))
    }

    func testAXValueSelectionAndUTF16RangesUsePublishedTerminalText() throws {
        let view = try make()
        view.feed("alpha\r\n界😀e\u{301}")
        let value = try XCTUnwrap(view.renderer.accessibilityValue() as? String)
        XCTAssertEqual(value, "alpha\n界😀e\u{301}")
        XCTAssertEqual(view.renderer.accessibilityNumberOfCharacters(), 11)
        XCTAssertEqual(view.renderer.accessibilityString(for: NSRange(location: 7, length: 2)), "😀")
        XCTAssertEqual(view.renderer.accessibilityRange(for: 8), NSRange(location: 7, length: 2))
        try view.driver.selectAll(); view.refresh()
        XCTAssertEqual(view.renderer.accessibilitySelectedText(), value)
        XCTAssertEqual(view.renderer.accessibilitySelectedTextRange(), NSRange(location: 0, length: 11))
    }
}
