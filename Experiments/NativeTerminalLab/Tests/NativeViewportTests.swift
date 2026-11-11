import AppKit
import XCTest
@testable import SanttyTerminalLab

final class NativeViewportTests: XCTestCase {
    func testFractionalOffsetAndBoundedSurface() {
        let view = NativeViewport(rowHeight: 20, viewportHeight: 245, totalRows: 100_000, offset: 105)
        XCTAssertEqual(view.firstRow, 5)
        XCTAssertEqual(view.fraction, 5)
        XCTAssertEqual(view.renderOrigin, 100)
        XCTAssertLessThanOrEqual(view.renderHeight, 245 + 3 * 20)
        XCTAssertEqual(view.documentHeight, 2_000_000)
        XCTAssertEqual(view.row(atViewportY: 0), 5)
        XCTAssertEqual(view.row(atViewportY: 15), 6)
    }

    func testElasticPositionsDoNotChangeLogicalRows() {
        let above = NativeViewport(rowHeight: 20, viewportHeight: 200, totalRows: 100, offset: -30)
        XCTAssertEqual(above.firstRow, 0)
        XCTAssertNil(above.row(atViewportY: 10))
        XCTAssertEqual(above.row(atViewportY: 40), 0)
        let below = NativeViewport(rowHeight: 20, viewportHeight: 200, totalRows: 100, offset: 1830)
        XCTAssertEqual(below.firstRow, 90)
        XCTAssertNil(below.row(atViewportY: 180))
        XCTAssertTrue(below.isAtBottom)
        XCTAssertEqual(below.offsetAfterUpdate(totalRows: 110, viewportHeight: 200, rowHeight: 20), 2000)
    }

    func testAppendFollowsBottomButDoesNotInterruptHistoryReading() {
        let bottom = NativeViewport(rowHeight: 20, viewportHeight: 200, totalRows: 100, offset: 1800)
        XCTAssertEqual(bottom.offsetAfterUpdate(totalRows: 110, viewportHeight: 200, rowHeight: 20), 2000)
        let history = NativeViewport(rowHeight: 20, viewportHeight: 200, totalRows: 100, offset: 105)
        XCTAssertEqual(history.offsetAfterUpdate(totalRows: 110, viewportHeight: 200, rowHeight: 20), 105)
        XCTAssertEqual(history.offsetAfterUpdate(totalRows: 110, viewportHeight: 200, rowHeight: 40), 210)
    }

    func testShortDocumentAndHistoryShrinkClampSafely() {
        let empty = NativeViewport(rowHeight: 20, viewportHeight: 200, totalRows: 0, offset: 0)
        XCTAssertEqual(empty.documentHeight, 200)
        XCTAssertEqual(empty.maximumOffset, 0)
        XCTAssertNil(empty.row(atViewportY: 0))
        let history = NativeViewport(rowHeight: 20, viewportHeight: 200, totalRows: 100, offset: 1000)
        XCTAssertEqual(history.offsetAfterUpdate(totalRows: 20, viewportHeight: 200, rowHeight: 20), 200)
    }

    func testInvalidFloatingPointInputCannotReachIntegerConversion() {
        let view = NativeViewport(rowHeight: .nan, viewportHeight: .infinity, totalRows: -1, offset: .nan)
        XCTAssertEqual(view.rowHeight, 1)
        XCTAssertEqual(view.firstRow, 0)
        XCTAssertEqual(view.renderRows, 2)
    }
}
