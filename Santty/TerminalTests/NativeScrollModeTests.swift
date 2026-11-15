import AppKit
import XCTest
@testable import Santty

final class NativeScrollModeTests: XCTestCase {
    private func begin(_ driver: GhosttyVTDriver) throws {
        XCTAssertNotNil(try driver.performScrollMode(.begin))
        _ = try driver.performScrollMode(.move(.top))
    }

    func testPinnedPhysicalWordMotionVectorsMatchTheExistingMainPolicy() throws {
        let driver = try GhosttyVTDriver(columns: 24, rows: 2)
        driver.feed("  foo_bar/path.txt  next\r\n\r\n final")
        try begin(driver)
        let vectors: [(NativeScrollMovement, NativeScrollCell)] = [
            (.wordForward(big:false), .init(column:2,row:0)), (.wordEnd(big:false), .init(column:8,row:0)),
            (.wordForward(big:false), .init(column:9,row:0)), (.wordForward(big:false), .init(column:10,row:0)),
            (.wordEnd(big:false), .init(column:13,row:0)), (.wordEnd(big:true), .init(column:17,row:0)),
            (.wordBackward(big:false), .init(column:15,row:0)), (.wordBackward(big:false), .init(column:14,row:0)),
            (.wordBackward(big:true), .init(column:2,row:0)), (.wordForward(big:true), .init(column:20,row:0)),
            (.wordEnd(big:false), .init(column:23,row:0)), (.wordForward(big:false), .init(column:1,row:2)),
            (.wordBackward(big:false), .init(column:20,row:0)), (.firstNonblank, .init(column:2,row:0)),
            (.wordBackward(big:false), .init(column:0,row:0)), (.wordBackward(big:false), .init(column:0,row:0)),
            (.bottom, .init(column:0,row:2)), (.wordEnd(big:false), .init(column:5,row:2)),
            (.wordForward(big:false), .init(column:23,row:2)), (.wordEnd(big:false), .init(column:23,row:2))]
        for (movement, expected) in vectors {
            let state = try XCTUnwrap(driver.performScrollMode(.move(movement)))
            XCTAssertEqual(state.cell, expected, "\(movement)")
            XCTAssertTrue((state.viewport..<(state.viewport + state.rows)).contains(state.cell.row))
        }
    }

    func testCellReadsUseVTWidthsGraphemesAndAreNotFullHistoryOrAXLines() throws {
        let driver = try GhosttyVTDriver(columns: 8, rows: 2)
        driver.feed("a界🙂e\u{301}\r\nlast")
        XCTAssertEqual(try driver.readScrollModeCell(column:1,row:0)?.text, "界")
        XCTAssertEqual(try driver.readScrollModeCell(column:1,row:0)?.width, 2)
        XCTAssertEqual(try driver.readScrollModeCell(column:2,row:0)?.width, 0)
        XCTAssertEqual(try driver.readScrollModeCell(column:5,row:0)?.text, "e\u{301}")
        XCTAssertNil(try driver.readScrollModeCell(column:-1,row:0)); XCTAssertNil(try driver.readScrollModeCell(column:8,row:0))
        XCTAssertNil(try driver.readScrollModeCell(column:0,row:99))
        try begin(driver)
        for expected in [1,3] { XCTAssertEqual(try driver.performScrollMode(.move(.right))?.cell.column, expected) }
        for expected in [1,0] { XCTAssertEqual(try driver.performScrollMode(.move(.left))?.cell.column, expected) }
    }

    func testCursorNeverStopsOnAWideTailIncludingLineEndAndVerticalTravel() throws {
        let driver = try GhosttyVTDriver(columns: 4, rows: 2)
        driver.feed("ab界\r\na界x")
        try begin(driver)
        XCTAssertEqual(try driver.performScrollMode(.move(.lineEnd))?.cell.column, 2)
        XCTAssertEqual(try driver.performScrollMode(.move(.right))?.cell.column, 2)
        let down = try XCTUnwrap(driver.performScrollMode(.move(.down)))
        XCTAssertEqual(down.cell, .init(column:1,row:1))
        XCTAssertEqual(try driver.performScrollMode(.move(.right))?.cell.column, 3)
    }

    func testSoftWrapNavigationIsPhysicalWhileCopyFormattingIsVTLogicalText() throws {
        let driver = try GhosttyVTDriver(columns:4, rows:2)
        driver.feed("abcdEFGH")
        XCTAssertEqual(try driver.readScreenText(), "abcdEFGH")
        try begin(driver)
        _ = try driver.performScrollMode(.toggleSelection(linewise:true))
        XCTAssertEqual(try driver.readScrollModeSelection(), "abcd")
        _ = try driver.performScrollMode(.move(.wordForward(big:true)))
        XCTAssertEqual(try driver.scrollModeState?.cell, .init(column:0,row:1))
        XCTAssertEqual(try driver.readScrollModeSelection(), "abcdEFGH")
    }

    func testInclusiveCharacterLinewiseReverseCancelAndFormattingLimit() throws {
        let driver = try GhosttyVTDriver(columns:12, rows:3)
        driver.feed("one two\r\nsecond\r\nthird")
        try begin(driver)
        _ = try driver.performScrollMode(.toggleSelection(linewise:false))
        XCTAssertEqual(try driver.readScrollModeSelection(), "o")
        for _ in 0..<2 { _ = try driver.performScrollMode(.move(.right)) }
        XCTAssertEqual(try driver.readScrollModeSelection(), "one")
        _ = try driver.performScrollMode(.toggleSelection(linewise:true))
        _ = try driver.performScrollMode(.move(.down))
        XCTAssertEqual(try driver.readScrollModeSelection(), "one two\nsecond")
        XCTAssertThrowsError(try driver.readScrollModeSelection(limit:3))
        let frame = try driver.snapshot(topRow:0)
        XCTAssertFalse(frame.selection.isEmpty, "core selection is the real renderer selection")
        _ = try driver.performScrollMode(.cancelSelection)
        XCTAssertNil(try driver.readScrollModeSelection())
        _ = try driver.performScrollMode(.toggleSelection(linewise:true))
        _ = try driver.performScrollMode(.move(.up))
        XCTAssertEqual(try driver.readScrollModeSelection(), "one two\nsecond")
        _ = try driver.performScrollMode(.toggleSelection(linewise:true))
        XCTAssertNil(try driver.readScrollModeSelection())
    }

    func testLongHistoryCharacterAndLineSelectionUseCoreNotPublishedRows() throws {
        let driver = try GhosttyVTDriver(columns:80, rows:5)
        driver.feed((0..<6000).map { "row-\($0) 界🙂\r\n" }.joined())
        try begin(driver)
        _ = try driver.performScrollMode(.toggleSelection(linewise:true))
        _ = try driver.performScrollMode(.move(.bottom))
        let text = try XCTUnwrap(driver.readScrollModeSelection())
        XCTAssertTrue(text.hasPrefix("row-0 界🙂\n")); XCTAssertTrue(text.hasSuffix("row-5999 界🙂"))
        XCTAssertEqual(text.split(separator:"\n").count, 6000)
        XCTAssertEqual(try driver.scrollModeState?.viewport, (try driver.totalRows) - driver.rows)
    }

    func testTrackedCursorPreservesContentAcrossReflowButSelectionIsCancelled() throws {
        let driver = try GhosttyVTDriver(columns:10, rows:2)
        driver.feed("ABCDEFGHIJKLMNO")
        try begin(driver)
        for _ in 0..<7 { _ = try driver.performScrollMode(.move(.right)) }
        _ = try driver.performScrollMode(.toggleSelection(linewise:false))
        XCTAssertEqual(try driver.readScrollModeSelection(), "H")
        try driver.resize(columns:5, rows:2)
        let state = try XCTUnwrap(driver.scrollModeState)
        XCTAssertEqual(try driver.readScrollModeCell(column:state.cell.column,row:state.cell.row)?.text, "H")
        XCTAssertNil(state.selection); XCTAssertNil(try driver.readScrollModeSelection())
    }

    func testLostReferenceFallsToOldestAndDoesNotRetargetOldColumnSelection() throws {
        let driver = try GhosttyVTDriver(columns:20, rows:2, scrollbackLines:10)
        driver.feed((0..<100).map { "prune-\($0)\r\n" }.joined())
        try begin(driver)
        for _ in 0..<6 { _ = try driver.performScrollMode(.move(.right)) }
        _ = try driver.performScrollMode(.toggleSelection(linewise:true))
        driver.feed((100..<10_000).map { "prune-\($0)\r\n" }.joined())
        let state = try XCTUnwrap(driver.scrollModeState)
        XCTAssertEqual(state.cell, .init(column:0,row:0)); XCTAssertEqual(state.viewport,0)
        XCTAssertNil(state.selection); XCTAssertNil(try driver.readScrollModeSelection())
        XCTAssertFalse(try driver.readScreenText().hasPrefix("prune-0\n"))
    }

    func testAppendDoesNotMoveCursorToTailAndHostResetRISAndScreensExitMode() throws {
        let driver = try GhosttyVTDriver(columns:40, rows:3)
        driver.feed((0..<100).map { "line-\($0)\r\n" }.joined())
        try begin(driver)
        _ = try driver.performScrollMode(.toggleSelection(linewise:true))
        driver.feed("new-tail\r\n")
        XCTAssertEqual(try driver.scrollModeState?.cell.row,0)
        XCTAssertEqual(try driver.readScrollModeSelection(), "line-0")
        driver.feed("\u{1b}[?1049h")
        XCTAssertNil(try driver.scrollModeState)
        driver.feed("\u{1b}[?1049l")
        XCTAssertNil(try driver.scrollModeState)
        try begin(driver); driver.feed("\u{1b}c")
        XCTAssertNil(try driver.scrollModeState)
        try begin(driver); driver.reset()
        XCTAssertNil(try driver.scrollModeState)
    }

    func testHoldSuspendsCommandsAndCopyButEndIsAlwaysAvailable() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("old")
        try begin(driver)
        _ = try driver.performScrollMode(.toggleSelection(linewise:false))
        driver.feed("\u{1b}[?2026h-new")
        XCTAssertNil(try driver.performScrollMode(.move(.right)))
        XCTAssertNil(try driver.readScrollModeSelection())
        XCTAssertNotNil(driver.renderHoldRemaining)
        XCTAssertEqual(try driver.readScrollModeCell(column:3,row:0)?.text, "-")
        _ = try driver.performScrollMode(.end)
        driver.feed("\u{1b}[?2026l")
        XCTAssertNil(try driver.scrollModeState)
    }

    func testWordScanBudgetRefusesRatherThanCommitsAPartialMotion() throws {
        let driver = try GhosttyVTDriver(columns:80, rows:5)
        driver.feed(String(repeating:"\r\n",count:1000) + "end")
        try begin(driver)
        _ = try driver.performScrollMode(.toggleSelection(linewise:true))
        let old = try driver.scrollModeState
        XCTAssertThrowsError(try driver.performScrollMode(.move(.wordForward(big:false)))) {
            XCTAssertEqual($0 as? NativeScrollModeError, .readBudget)
        }
        XCTAssertEqual(try driver.scrollModeState, old)
    }

    func testSameWriteScreenRoundTripRetainsOnlyTheValidPrimaryRefAndCancelsSelection() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("primary-content")
        try begin(driver)
        for _ in 0..<4 { _ = try driver.performScrollMode(.move(.right)) }
        _ = try driver.performScrollMode(.toggleSelection(linewise:false))
        let old = try XCTUnwrap(driver.scrollModeState)
        driver.feed("\u{1b}[?1049h\u{1b}[HALT\u{1b}[?1049l")
        let fresh = try XCTUnwrap(driver.scrollModeState)
        XCTAssertEqual(fresh.cell,old.cell)
        XCTAssertNil(fresh.selection); XCTAssertNil(try driver.readScrollModeSelection())
        XCTAssertEqual(try driver.readScrollModeCell(column:fresh.cell.column,row:fresh.cell.row)?.text,"a")
    }

    func testHiddenOldBottomWithTheSameTotalCannotRetargetTheCursorToUnseenTail() throws {
        let driver = try GhosttyVTDriver(columns:80,rows:15,scrollbackLines:2000)
        func lines(_ range: Range<Int>) -> String { range.map { "seed-\($0)\r\n" }.joined() }
        driver.feed(lines(0..<4000))
        let old = try XCTUnwrap(driver.presentation(rowHeight:16,viewportHeight:250,previous:nil))
        let oldTotal = old.viewport.totalRows
        var written = 0
        while written < 8000 {
            driver.feed(lines((4000+written)..<(4100+written))); written += 100
            if try driver.totalRows < oldTotal + written { break }
        }
        let after = try driver.totalRows
        XCTAssertLessThan(after,oldTotal,"fixture must actually prune before checking equal-total drift")
        let restore = oldTotal-after
        if restore > 0 { driver.feed(lines((4000+written)..<(4000+written+restore))) }
        XCTAssertEqual(try driver.totalRows,oldTotal)
        let mode = try XCTUnwrap(driver.performScrollMode(.begin,relativeTo:old.viewport))
        XCTAssertLessThan(mode.cell.row,oldTotal-driver.rows,"old bottom is tracked content, not permission to reveal the current live cursor")
    }

    func testExplicitPresentationResolvesModeAndCapturesBoundedRowsAtomically() throws {
        let driver = try GhosttyVTDriver(columns:40,rows:5)
        driver.feed((0..<6000).map { "row-\($0)\r\n" }.joined())
        try begin(driver)
        _ = try driver.performScrollMode(.move(.pageDown))
        _ = try driver.performScrollMode(.toggleSelection(linewise:true))
        let result = try XCTUnwrap(driver.scrollModePresentation(rowHeight:16,viewportHeight:83.5))
        let mode = result.state, frame = result.presentation.frame
        XCTAssertLessThanOrEqual(frame.rows.count,12)
        XCTAssertTrue(try XCTUnwrap(frame.rows[mode.cell.row]).cells.compactMap(\.text).joined().contains("row-5"))
        XCTAssertFalse(frame.selection.isEmpty)
        XCTAssertEqual(result.presentation.viewport.firstRow,mode.viewport)
    }

    func testExternalSelectionTransferCannotMakeModeCopyAnotherOwnersSelection() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("hello world")
        try begin(driver)
        _ = try driver.performScrollMode(.toggleSelection(linewise:false))
        driver.clearSelection()
        XCTAssertNil(try driver.scrollModeState?.selection)
        XCTAssertNil(try driver.readScrollModeSelection())
        _ = try driver.performScrollMode(.toggleSelection(linewise:false))
        try driver.selectAll()
        XCTAssertNil(try driver.scrollModeState)
        XCTAssertNil(try driver.readScrollModeSelection())
        XCTAssertEqual(try driver.selectedText(), "hello world")
    }

    func testPageHalfAndBoundaryMovesRevealOnlyTheProposedPhysicalViewport() throws {
        let driver = try GhosttyVTDriver(columns:20, rows:6)
        driver.feed((0..<60).map { "line-\($0)\r\n" }.joined())
        let original = try XCTUnwrap(driver.performScrollMode(.begin))
        _ = try driver.performScrollMode(.move(.top))
        XCTAssertEqual(try driver.performScrollMode(.move(.halfDown))?.cell.row,3)
        XCTAssertEqual(try driver.performScrollMode(.move(.pageDown))?.cell.row,9)
        XCTAssertEqual(try driver.performScrollMode(.move(.halfUp))?.cell.row,6)
        XCTAssertEqual(try driver.performScrollMode(.move(.pageUp))?.cell.row,0)
        XCTAssertEqual(try driver.performScrollMode(.move(.up))?.cell.row,0)
        _ = try driver.performScrollMode(.move(.bottom))
        XCTAssertEqual(try driver.performScrollMode(.move(.down))?.cell.row,60)
        _ = try driver.performScrollMode(.end)
        // No scroll_viewport call has occurred: a fresh begin samples the
        // original core viewport, not our proposed reveal plan.
        XCTAssertEqual(try driver.performScrollMode(.begin)?.viewport, original.viewport)
    }

    func testParallelParsingCellReadsAndMovesKeepReferencesInsideTheDriverLock() throws {
        let driver = try GhosttyVTDriver(columns:80, rows:5)
        driver.feed("seed\r\n")
        try begin(driver)
        let done = DispatchGroup(); done.enter()
        DispatchQueue.global().async {
            for i in 0..<300 { driver.feed("new-\(i) 界🙂\r\n") }
            done.leave()
        }
        for _ in 0..<100 {
            _ = try driver.performScrollMode(.move(.down))
            _ = try driver.performScrollMode(.move(.up))
            XCTAssertNotNil(try driver.readScrollModeCell(column:0,row:0))
        }
        XCTAssertEqual(done.wait(timeout:.now()+5), .success)
        XCTAssertTrue(try driver.readScreenText().contains("new-299"))
    }

    func testReadingAndMovingDoNotRevealOrTickAnimationOrEmitProgramInput() throws {
        let clock = NativeAnimationTestClock()
        let driver = try GhosttyVTDriver(columns:12, rows:6, animationClock:{clock.milliseconds})
        driver.feed(NativeAnimationFixture.finite + "text")
        let before = try XCTUnwrap(driver.presentation(rowHeight:16,viewportHeight:96,previous:nil)).frame
        let deadline = driver.imageAnimationWake?.deadlineMilliseconds
        clock.set(5000)
        try begin(driver)
        _ = try driver.performScrollMode(.toggleSelection(linewise:true))
        _ = try driver.performScrollMode(.move(.bottom))
        _ = try driver.readScrollModeSelection()
        XCTAssertEqual(driver.imageAnimationWake?.deadlineMilliseconds, deadline)
        XCTAssertTrue(try driver.snapshot(topRow:0).imageSnapshot.images[7] === before.imageSnapshot.images[7])
        _ = try driver.performScrollMode(.end)
        XCTAssertEqual(driver.feed("\u{1b}[5n"), Data("\u{1b}[0n".utf8), "only the actual program query yields a reply")
    }
}
