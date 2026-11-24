import AppKit
import Foundation
import XCTest
@testable import Santty

final class NativeReadSnapshotTests: XCTestCase {
    func testEmptyScreenAndFormatterLimits() throws {
        let driver = try GhosttyVTDriver()
        XCTAssertEqual(try driver.readScreenText(maximumBytes: 0), "")
        driver.feed("abcde")
        XCTAssertEqual(try driver.readScreenText(maximumBytes: 5), "abcde")
        XCTAssertThrowsError(try driver.readScreenText(maximumBytes: 4)) { XCTAssertEqual($0 as? NativeReadSnapshotError, .tooLarge) }
        XCTAssertThrowsError(try driver.readScreenText(maximumBytes: -1)) { XCTAssertEqual($0 as? NativeReadSnapshotError, .invalidLimit) }
        XCTAssertThrowsError(try driver.readScreenText(maximumBytes: GhosttyVTReadSnapshot.maximumBytes + 1))
        XCTAssertEqual(try driver.readScreenText(), "abcde", "refusal discards its partial result, not terminal data")
    }

    func testCompleteRetainedHistoryNotThePublishedViewport() throws {
        let driver = try GhosttyVTDriver(columns: 100, rows: 5)
        let lines = (0..<6000).map { "row-\($0) 界 e\u{301} 🐱" }
        driver.feed(lines.joined(separator: "\r\n"))
        let old = try driver.snapshot(topRow: 40)
        XCTAssertFalse(old.rows.values.contains { $0.cells.compactMap(\.text).joined().contains("row-5999") })
        XCTAssertEqual(try driver.readScreenText(), lines.joined(separator: "\n"))
    }

    func testFixedLogicalLinesWideCombiningZWJSpacesAndEmptyRows() throws {
        let driver = try GhosttyVTDriver(columns: 4, rows: 2)
        driver.feed("ABCDEFGHI\r\n\r\nQ  ")
        XCTAssertEqual(try driver.readScreenText(), "ABCDEFGHI\n\nQ")
        driver.reset()
        let unicode = "12345中🙂e\u{301}abc 👩🏽‍💻"
        driver.feed("\u{1b}[?2027h" + unicode + "\r\nsecond\r\n\r\n")
        XCTAssertEqual(Array(try driver.readScreenText().utf8), Array((unicode + "\nsecond").utf8))
    }

    func testReadIgnoresAndPreservesTheUsersSelectionAndReadingViewport() throws {
        let driver = try GhosttyVTDriver(columns: 30, rows: 4)
        driver.feed("hello world\r\nsecond")
        func event(_ step: NativeSelectionInput.Step, _ column: Int, _ time: Double) -> NativeSelectionInput {
            .init(step: step, column: column, row: 0, position: .init(x: CGFloat(column * 10) + (column == 0 ? 1 : 9), y: 5),
                  cell: .init(width: 10, height: 20), viewportHeight: 80, time: time, doubleClickInterval: 0.5)
        }
        try driver.select(event(.press, 0, 1)); try driver.select(event(.drag, 4, 1.01)); try driver.select(event(.release, 4, 1.02))
        let selected = try driver.selectedText(), before = try driver.snapshot(topRow: 0)
        XCTAssertEqual(selected, "hello")
        XCTAssertEqual(try driver.readScreenText(), "hello world\nsecond")
        XCTAssertEqual(try driver.selectedText(), selected)
        XCTAssertEqual(try driver.snapshot(topRow: 0).selection, before.selection)
    }

    func testActiveAlternateScreenResetAndPruningNeverReturnAStoredOldMirror() throws {
        let driver = try GhosttyVTDriver(columns: 20, rows: 2, scrollbackLines: 10)
        driver.feed((0..<100).map { "prune-\($0)\r\n" }.joined())
        // Preserve the original 100-row vector: the frozen core retains it
        // despite a limit of 10, because pruning is page-granular (C probe).
        XCTAssertTrue(try driver.readScreenText().contains("prune-0\n"))
        driver.feed((100..<10_000).map { "prune-\($0)\r\n" }.joined())
        let primary = try driver.readScreenText()
        XCTAssertFalse(primary.contains("prune-0\n")); XCTAssertTrue(primary.contains("prune-9999"))
        driver.feed("\u{1b}[?1049h\u{1b}[Halt-only")
        XCTAssertEqual(try driver.readScreenText(), "alt-only")
        driver.feed("\u{1b}[?1049l")
        XCTAssertEqual(try driver.readScreenText(), primary)
        driver.reset(); XCTAssertEqual(try driver.readScreenText(), "")
        driver.feed("new-root"); XCTAssertEqual(try driver.readScreenText(), "new-root")
    }

    func testHoldReadSeesCurrentParsedTextButDoesNotEndHoldOrPublishCells() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("old"); let before = try driver.snapshot(topRow: 0)
        driver.feed("\u{1b}[?2026h-new\u{1b}]2;current metadata\u{7}")
        let metadata = driver.metadata, hold = driver.renderHoldRemaining
        XCTAssertEqual(try driver.readScreenText(), "old-new")
        XCTAssertEqual(try driver.snapshot(topRow: 0).rows[0]?.cells, before.rows[0]?.cells)
        XCTAssertEqual(driver.metadata, metadata)
        XCTAssertNotNil(hold); XCTAssertNotNil(driver.renderHoldRemaining)
    }

    func testConcealIsFormatterPlaintextNotTheAXRedactionPolicy() throws {
        let driver = try GhosttyVTDriver(columns: 4, rows: 2)
        driver.feed("A\u{1b}[8mSECRET\u{1b}[0mZ")
        XCTAssertEqual(try driver.readScreenText(), "ASECRETZ")
        // CLI/plain copy is deliberately not advertised as the read-only AX
        // page, which suppresses concealed cells and image placeholder glyphs.
    }

    func testReadDoesNotTickAnimationAdvanceGenerationOrChangeDeadline() throws {
        let clock = NativeAnimationTestClock()
        let driver = try GhosttyVTDriver(columns: 12, rows: 6, animationClock: { clock.milliseconds })
        driver.feed(NativeAnimationFixture.finite + "text")
        let first = try XCTUnwrap(driver.presentation(rowHeight: 16, viewportHeight: 96, previous: nil)).frame
        let deadline = driver.imageAnimationWake
        clock.set(5000)
        XCTAssertEqual(try driver.readScreenText(), "text")
        XCTAssertEqual(driver.imageAnimationWake?.deadlineMilliseconds, deadline?.deadlineMilliseconds)
        // Delay is derived from NOW by the getter; advancing the test clock
        // legitimately changes 100 ms to 0 without ticking the animation.
        XCTAssertEqual(driver.imageAnimationWake?.delayMilliseconds, 0)
        XCTAssertTrue(try driver.snapshot(topRow: 0).imageSnapshot.images[7] === first.imageSnapshot.images[7])
        let advanced = try XCTUnwrap(driver.presentation(rowHeight: 16, viewportHeight: 96, previous: nil)).frame
        XCTAssertEqual(advanced.imageSnapshot.images[7]?.rgba, [0,255,0,255], "only presentation advances VT animation")
    }

    func testConcurrentParsingAndReadAreWholeDriverTransactions() throws {
        let driver = try GhosttyVTDriver(columns: 120, rows: 5)
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async {
            for i in 0..<300 { driver.feed("complete-\(i)-界🐱\r\n") }
            done.leave()
        }
        for _ in 0..<100 {
            let text = try driver.readScreenText()
            let rows = text.split(separator: "\n")
            XCTAssertTrue(rows.allSatisfy { $0.hasPrefix("complete-") && $0.hasSuffix("-界🐱") })
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(try driver.readScreenText().hasSuffix("complete-299-界🐱"))
    }
}

@MainActor
private final class ReadFocusSentinel: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class NativeCLIReadServiceTests: XCTestCase {
    func testSearchRangesTailAndLineNumbersReuseTheProductionCLITextBoundary() async throws {
        let driver = try GhosttyVTDriver(columns: 6, rows: 2), id = UUID()
        driver.feed("alpha-0123456789\r\n\r\nBeta 界\r\nlast")
        let reader = NativeTerminalReadService(paneID: id, driver: driver)
        let search = try await reader.response(.init(command: "search", paneID: id, query: "beta", ignoreCase: true))
        XCTAssertEqual(search.totalLines, 4); XCTAssertEqual(search.totalMatches, 1)
        XCTAssertEqual(search.matches?.first?.line, 3); XCTAssertEqual(search.matches?.first?.text, "Beta 界")
        let range = try await reader.response(.init(command: "read", paneID: id, startLine: 1, endLine: 3))
        XCTAssertEqual(range.text, "alpha-0123456789\n\nBeta 界")
        XCTAssertEqual(range.startLine, 1); XCTAssertEqual(range.endLine, 3)
        let tail = try await reader.response(.init(command: "read", paneID: id, tail: 2))
        XCTAssertEqual(tail.text, "Beta 界\nlast"); XCTAssertEqual(tail.totalLines, 4)
    }

    func testSearchLiteralUnicodeAndResultLimitKeepExistingSemantics() async throws {
        let driver = try GhosttyVTDriver(), id = UUID()
        driver.feed("é\r\ne\u{301}\r\nrepeat\r\nrepeat")
        let reader = NativeTerminalReadService(paneID: id, driver: driver)
        let unicode = try await reader.response(.init(command: "search", paneID: id, query: "é"))
        XCTAssertEqual(unicode.totalMatches, 1); XCTAssertEqual(unicode.matches?.first?.line, 1)
        let limited = try await reader.response(.init(command: "search", paneID: id, query: "repeat", limit: 1))
        XCTAssertEqual(limited.totalMatches, 2); XCTAssertEqual(limited.matches?.count, 1); XCTAssertEqual(limited.truncated, true)
        let emptyDriver = try GhosttyVTDriver()
        let empty = try await NativeTerminalReadService(paneID: id, driver: emptyDriver).response(.init(command: "read", paneID: id))
        XCTAssertEqual(empty.totalLines, 0); XCTAssertEqual(empty.text, "")
    }

    func testReadOnlyBoundaryRefusesMutationsWrongPaneAndInvalidReadRequests() async throws {
        let driver = try GhosttyVTDriver(), id = UUID(), reader = NativeTerminalReadService(paneID: UUID(), driver: try GhosttyVTDriver())
        for (request, code) in [(CLIRequest(command: "pane.send-text", paneID: id, text: "must not type"), "read_only"),
                               (CLIRequest(command: "list"), "read_only"), (CLIRequest(command: "read", paneID: id), "pane_changed")] {
            do { _ = try await reader.response(request); XCTFail("request must fail") }
            catch let error as CLIError { XCTAssertEqual(error.code, code) }
        }
        let correct = NativeTerminalReadService(paneID: id, driver: driver)
        do { _ = try await correct.response(.init(command: "read", paneID: id, startLine: 1, endLine: 0)); XCTFail("invalid range") } catch {}
        XCTAssertEqual(try driver.readScreenText(), "")
    }

    func testResponseCapAndUnicodeNeverTurnIntoAHistoryCaptureCap() async throws {
        let driver = try GhosttyVTDriver(columns: 250, rows: 4), id = UUID()
        let line = String(repeating: "界", count: 100)
        driver.feed((0..<1200).map { "\($0)-\(line)\r\n" }.joined())
        let reader = NativeTerminalReadService(paneID: id, driver: driver)
        let value = try await reader.response(.init(command: "read", paneID: id, tail: 10_000))
        XCTAssertEqual(value.totalLines, 1200)
        XCTAssertEqual(value.truncated, true)
        XCTAssertLessThanOrEqual(try XCTUnwrap(value.text).utf8.count, CLITextSnapshot.maximumBytes)
        XCTAssertTrue(value.text?.hasSuffix("1199-" + line) == true)
        let first = try await reader.response(.init(command: "read", paneID: id, startLine: 1, endLine: 1))
        XCTAssertEqual(first.text, "0-" + line, "response clipping did not discard oldest retained history")
    }

    func testHiddenPublishedFrameAXFocusAndPrivateClipboardAreUntouched() async throws {
        let driver = try GhosttyVTDriver(), id = UUID()
        let view = NativeTerminalScrollView(driver: driver, frame: .init(x: 0, y: 0, width: 500, height: 240))
        view.feed((0..<300).map { "published-\($0)\r\n" }.joined())
        let scrollY = 40 * view.renderer.cellSize.height + 3
        view.contentView.scroll(to: CGPoint(x: 0, y: scrollY))
        view.reflectScrolledClipView(view.contentView)
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        let root = NSView(frame: view.frame), sentinel = ReadFocusSentinel()
        root.addSubview(view); root.addSubview(sentinel); window.contentView = root
        defer { window.contentView = nil }
        XCTAssertTrue(window.makeFirstResponder(sentinel))
        let before = view.presentedFrame, viewport = view.presentedViewport
        let ax = view.renderer.accessibilityValue() as? String
        XCTAssertGreaterThan(try XCTUnwrap(viewport?.clampedOffset), 0)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("unchanged", forType: .string)
        let output = NativeTerminalOutput(driver: driver) { _ in XCTFail("read must not request presentation") }
        view.renderer.output = output // detached/hidden connected view
        driver.feed(" hidden-new")
        let reader = NativeTerminalReadService(paneID: id, driver: driver)
        let response = try await reader.response(.init(command: "read", paneID: id, tail: 1))
        XCTAssertEqual(response.text, " hidden-new")
        XCTAssertEqual(view.presentedFrame?.rows[0]?.cells, before?.rows[0]?.cells)
        XCTAssertEqual(view.renderer.accessibilityValue() as? String, ax)
        XCTAssertEqual(board.string(forType: .string), "unchanged")
        XCTAssertTrue(window.firstResponder === sentinel)
        XCTAssertEqual(view.presentedViewport?.clampedOffset, viewport?.clampedOffset)
    }

    func testSnapshotBudgetFailureNeverReturnsAPartialSuccessfulReply() async throws {
        let driver = try GhosttyVTDriver(), id = UUID()
        driver.feed("abcdef")
        let reader = NativeTerminalReadService(paneID: id, driver: driver, maximumSnapshotBytes: 5)
        do { _ = try await reader.response(.init(command: "read", paneID: id)); XCTFail("budget refusal") }
        catch let error as CLIError { XCTAssertEqual(error.code, "snapshot_too_large") }
        XCTAssertEqual(try driver.readScreenText(), "abcdef")
    }

    func testFormattingAndSearchFinishWhileTheMainActorIsBlocked() async throws {
        let driver = try GhosttyVTDriver(), id = UUID()
        driver.feed((0..<6000).map { "line-\($0)\r\n" }.joined())
        let reader = NativeTerminalReadService(paneID: id, driver: driver)
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            defer { done.signal() }
            return try await reader.response(.init(command: "search", paneID: id, query: "line-5999"))
        }
        // Fault injection only: no MainActor run-loop progress is available.
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        let response = try await task.value
        XCTAssertEqual(response.matches?.first?.line, 6000)
    }

    func testCancelledReadDoesNotWaitForUIOrMutateTerminal() async throws {
        let driver = try GhosttyVTDriver(), id = UUID()
        driver.feed("keep")
        let reader = NativeTerminalReadService(paneID: id, driver: driver)
        let task = Task { try await reader.response(.init(command: "read", paneID: id)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled query") } catch is CancellationError {} catch { XCTFail("unexpected cancellation: \(error)") }
        XCTAssertEqual(try driver.readScreenText(), "keep")
    }
}
