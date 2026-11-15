import AppKit
import GhosttyVt
import XCTest
@testable import Santty

private final class StreamClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func now() -> TimeInterval { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

private final class StreamBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func append(_ data: Data) { lock.withLock { value.append(data) } }
    var data: Data { lock.withLock { value } }
}

@MainActor
final class NativeTerminalStreamTests: XCTestCase {
    private func text(_ driver: GhosttyVTDriver) throws -> String {
        try driver.snapshot(topRow: 0).rows.sorted { $0.key < $1.key }
            .map { $0.value.cells.compactMap(\.text).joined() }.joined(separator: "\n")
    }

    func testRenderHoldAcrossBatchesStillParsesAndReplies() throws {
        let clock = StreamClock()
        let driver = try GhosttyVTDriver(columns: 40, rows: 4, clock: { clock.now() })
        driver.feed("before")
        XCTAssertTrue(try text(driver).contains("before"))
        driver.feed("\u{1b}[?2026h\r\nafter")
        XCTAssertNotNil(driver.renderHoldRemaining)
        XCTAssertFalse(try text(driver).contains("after"))
        XCTAssertEqual(String(decoding: driver.feed("\u{1b}[5n"), as: UTF8.self), "\u{1b}[0n")
        driver.feed("\u{1b}[?2026l")
        XCTAssertNil(driver.renderHoldRemaining)
        XCTAssertTrue(try text(driver).contains("after"))
    }

    func testResetFollowedImmediatelyByAHoldDoesNotPublishPartialRestore() throws {
        let driver = try GhosttyVTDriver(columns: 40, rows: 4)
        driver.feed("old")
        driver.reset()
        driver.feed("\u{1b}[?2026hpartial-restore")
        XCTAssertFalse(try text(driver).contains("partial"))
        driver.feed("\u{1b}[?2026l")
        XCTAssertTrue(try text(driver).contains("partial-restore"))
    }

    func testUnterminatedHoldExpiresWithoutMoreOutputAndResizeReleasesIt() throws {
        let clock = StreamClock()
        let driver = try GhosttyVTDriver(columns: 40, rows: 4, clock: { clock.now() })
        driver.feed("before")
        _ = try driver.snapshot(topRow: 0)
        driver.feed("\u{1b}[?2026h\r\nafter")
        clock.advance(1.1)
        XCTAssertNil(driver.renderHoldRemaining)
        XCTAssertTrue(try text(driver).contains("after"))
        driver.feed("\u{1b}[?2026h")
        XCTAssertNotNil(driver.renderHoldRemaining)
        try driver.resize(columns: 50, rows: 5)
        XCTAssertNil(driver.renderHoldRemaining)
    }

    func testGhosttyOwnsKeyboardPasteAndFocusModes() throws {
        let driver = try GhosttyVTDriver()
        XCTAssertEqual(try driver.encodeKey(GHOSTTY_KEY_ARROW_UP), Data("\u{1b}[A".utf8))
        driver.feed("\u{1b}[?1h")
        XCTAssertEqual(try driver.encodeKey(GHOSTTY_KEY_ARROW_UP), Data("\u{1b}OA".utf8))
        XCTAssertEqual(try driver.encodeKey(GHOSTTY_KEY_C, text: "c", modifiers: GhosttyMods(GHOSTTY_MODS_CTRL)), Data([3]))
        XCTAssertEqual(try driver.encodeFocus(true), Data())
        driver.feed("\u{1b}[?1004h\u{1b}[?2004h")
        XCTAssertEqual(try driver.encodeFocus(true), Data("\u{1b}[I".utf8))
        XCTAssertEqual(try driver.encodePaste("a\nb"), Data("\u{1b}[200~a\nb\u{1b}[201~".utf8))
        driver.feed("\u{1b}[?2004l")
        XCTAssertEqual(try driver.encodePaste("a\nb"), Data("a\rb".utf8))
        // Kitty release reporting is taken from live VT modes, not a copied
        // flags layout or the platform key-up event's numeric convention.
        driver.feed("\u{1b}[>3u")
        let release = try driver.encodeKey(GHOSTTY_KEY_A, text: "a",
            action: GHOSTTY_KEY_ACTION_RELEASE, unshiftedCodepoint: 97)
        XCTAssertFalse(release.isEmpty)
        driver.feed("\u{1b}[2h")
        XCTAssertTrue(try driver.encodeKey(GHOSTTY_KEY_A, text: "a").isEmpty)
        driver.feed("\u{1b}[2l")
        XCTAssertFalse(try driver.encodeKey(GHOSTTY_KEY_A, text: "a").isEmpty)
    }

    func testSizeQueriesUseLatestCellAndViewportDimensions() throws {
        let driver = try GhosttyVTDriver(columns: 80, rows: 24)
        try driver.resize(columns: 90, rows: 30, cellWidth: 10, cellHeight: 20)
        let replies = driver.feed("\u{1b}[16t\u{1b}[18t")
        XCTAssertEqual(String(decoding: replies, as: UTF8.self), "\u{1b}[6;20;10t\u{1b}[8;30;90t")
    }

    func testParsingAndRepliesCompleteBeforeMainActorPresentation() throws {
        let driver = try GhosttyVTDriver()
        let bytes = StreamBytes()
        let presented = expectation(description: "coalesced presentation")
        presented.expectedFulfillmentCount = 1
        let output = NativeTerminalOutput(driver: driver) { _ in presented.fulfill() }
        output.bind(writer: { bytes.append($0) })
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<100 { output.receive(Data("output\r\n\u{1b}[5n".utf8)) }
            XCTAssertTrue(output.waitForPendingOutput())
            done.signal()
        }
        // Deliberately don't service the main actor: parsing and automatic
        // replies must still finish. Only UI publication may wait.
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(bytes.data.count, 100 * Data("\u{1b}[0n".utf8).count)
        wait(for: [presented], timeout: 2)
    }

    func testNonZeroBasedDataSlicesAreParsedWithoutIndexAssumptions() throws {
        let driver = try GhosttyVTDriver(columns: 40, rows: 4)
        let output = NativeTerminalOutput(driver: driver) { _ in }
        let data = Data("ignore:hello".utf8).dropFirst(7)
        output.receive(data)
        XCTAssertTrue(try text(driver).contains("hello"))
    }

    func testDisconnectedInputIsNotQueuedForReconnect() throws {
        let output = NativeTerminalOutput(driver: try GhosttyVTDriver()) { _ in }
        let bytes = StreamBytes()
        output.bind(writer: { bytes.append($0) })
        XCTAssertFalse(try output.sendText("must-not-replay"))
        output.setInputEnabled(true)
        XCTAssertTrue(try output.sendText("new"))
        output.setInputEnabled(false)
        XCTAssertFalse(try output.paste("must-not-replay-either"))
        XCTAssertEqual(String(decoding: bytes.data, as: UTF8.self), "new")
    }

    func testHoldTimeoutRefreshesViewWithoutAnotherChunk() async throws {
        let driver = try GhosttyVTDriver()
        let view = NativeTerminalScrollView(driver: driver, frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        view.refresh(resizeTerminal: true)
        view.feed("before")
        view.feed("\u{1b}[?2026h\r\nafter")
        XCTAssertFalse(view.source.lines.values.contains { $0[0].getText() == "a" })
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(view.source.lines.values.contains { $0[0].getText() == "a" })
    }
}
