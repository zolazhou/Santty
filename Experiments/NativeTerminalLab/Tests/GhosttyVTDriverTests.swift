import Foundation
import XCTest
@testable import SanttyTerminalLab

@MainActor
final class GhosttyVTDriverTests: XCTestCase {
    func testUnicodeWidthsStylesAndGraphemes() throws {
        let driver = try GhosttyVTDriver(columns: 40, rows: 4)
        driver.feed("\u{1b}[?2027h\u{1b}[1;3;4:3;38;2;10;20;30mA\u{1b}[0m中e\u{301}👩🏽‍💻")
        let frame = try driver.snapshot(topRow: 0)
        let row = try XCTUnwrap(frame.rows[0])
        XCTAssertEqual(row.cells[0].text, "A")
        XCTAssertTrue(row.cells[0].style.contains([.bold, .italic]))
        XCTAssertEqual(row.cells[0].foreground, .rgb(.init(red: 10, green: 20, blue: 30)))
        XCTAssertEqual(row.cells[0].underline, 3)
        XCTAssertEqual(row.cells[1].text, "中")
        XCTAssertEqual(row.cells[1].width, 2)
        XCTAssertEqual(row.cells[2].width, 0)
        XCTAssertEqual(row.cells[3].text, "e\u{301}")
        XCTAssertEqual(row.cells[4].text, "👩🏽‍💻")
        XCTAssertEqual(row.cells[4].width, 2)
    }

    func testUTF8AndEscapeSequencesCanArriveOneByteAtATime() throws {
        let split = try GhosttyVTDriver(columns: 40, rows: 4)
        let whole = try GhosttyVTDriver(columns: 40, rows: 4)
        let data = Data("\u{1b}[?2027h\u{1b}[31m中文e\u{301}👩🏽‍💻\u{1b}[0m".utf8)
        for byte in data { split.feed(Data([byte])) }
        whole.feed(data)
        XCTAssertEqual(try split.snapshot(topRow: 0).rows[0]?.cells,
                       try whole.snapshot(topRow: 0).rows[0]?.cells)
    }

    func testSnapshotsOwnTheirDataAndReuseUnchangedRows() throws {
        let driver = try GhosttyVTDriver(columns: 20, rows: 4)
        driver.feed("hello\r\nworld")
        let first = try driver.snapshot(topRow: 0)
        let unchanged = try driver.snapshot(topRow: 0)
        XCTAssertTrue(first.rows[0] === unchanged.rows[0])
        driver.feed("\u{1b}[1;1HX")
        let changed = try driver.snapshot(topRow: 0)
        XCTAssertEqual(first.rows[0]?.cells[0].text, "h")
        XCTAssertEqual(changed.rows[0]?.cells[0].text, "X")
        XCTAssertFalse(first.rows[0] === changed.rows[0])
        XCTAssertTrue(first.rows[1] === changed.rows[1])
    }

    func testScrollbackAndOverscanAreRetainedWithoutCopyingAllHistory() throws {
        let driver = try GhosttyVTDriver(columns: 80, rows: 10)
        driver.feed((0..<6000).map { "row-\($0) " + String(repeating: "x", count: 65) + "\r\n" }.joined())
        XCTAssertGreaterThanOrEqual(try driver.totalRows, 6000)
        let top = try driver.snapshot(topRow: 0)
        XCTAssertEqual(top.rows[0]?.cells.prefix(5).compactMap(\.text).joined(), "row-0")
        XCTAssertLessThanOrEqual(top.rows.count, 14)
        XCTAssertNotNil(top.rows[12], "below-viewport rows are needed for fractional scrolling")
        let moved = try driver.snapshot(topRow: 3)
        XCTAssertTrue(top.rows[3] === moved.rows[3])
        let bottom = try driver.snapshot(topRow: Int.max)
        XCTAssertLessThanOrEqual(bottom.rows.count, 14)
        XCTAssertGreaterThan(bottom.topRow, 5900)
    }

    func testWrapContinuationMapping() throws {
        let driver = try GhosttyVTDriver(columns: 4, rows: 3)
        driver.feed("abcdef")
        let frame = try driver.snapshot(topRow: 0)
        XCTAssertFalse(try XCTUnwrap(frame.rows[0]).isWrapped)
        XCTAssertTrue(try XCTUnwrap(frame.rows[1]).isWrapped)
    }

    func testPaletteChangeAndErasedBackground() throws {
        let driver = try GhosttyVTDriver(columns: 10, rows: 3)
        driver.feed("\u{1b}[31mA\u{1b}[0m")
        let before = try driver.snapshot(topRow: 0)
        driver.feed("\u{1b}]4;1;rgb:12/34/56\u{7}\u{1b}[2;1H\u{1b}[44m\u{1b}[2K")
        let after = try driver.snapshot(topRow: 0)
        XCTAssertEqual(after.rows[0]?.cells[0].foreground, .palette(1))
        XCTAssertNotEqual(before.palette[1], after.palette[1])
        XCTAssertEqual(after.palette[1], .init(red: 0x12, green: 0x34, blue: 0x56))
        XCTAssertEqual(after.rows[1]?.cells[0].background, .palette(4))
        driver.feed("\u{1b}]4;4;rgb:ab/cd/ef\u{7}")
        let recolored = try driver.snapshot(topRow: 0)
        XCTAssertEqual(recolored.rows[1]?.cells[0].background, .palette(4))
        XCTAssertEqual(recolored.palette[4], .init(red: 0xab, green: 0xcd, blue: 0xef))
    }

    func testAlternateScreenResetAndResize() throws {
        let driver = try GhosttyVTDriver(columns: 10, rows: 3)
        driver.feed("primary\u{1b}[?1049halternate")
        XCTAssertTrue(try driver.snapshot(topRow: 0).isAlternateScreen)
        driver.feed("\u{1b}[?1049l")
        XCTAssertFalse(try driver.snapshot(topRow: 0).isAlternateScreen)
        try driver.resize(columns: 20, rows: 5)
        XCTAssertEqual(try driver.snapshot(topRow: 0).rows[0]?.cells.count, 20)
        driver.reset()
        XCTAssertNil(try driver.snapshot(topRow: 0).rows[0]?.cells[0].text)
    }

    func testInvalidSizeIsRejectedBeforeCallingC() throws {
        XCTAssertThrowsError(try GhosttyVTDriver(columns: 0, rows: 24))
        let driver = try GhosttyVTDriver()
        XCTAssertThrowsError(try driver.resize(columns: 80, rows: 0))
        XCTAssertEqual(driver.rows, 24)
    }
}
