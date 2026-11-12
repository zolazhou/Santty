import AppKit
import Foundation
import XCTest
@testable import SanttyTerminalLab

/// Fixed wire/time vectors adapted from SwiftTerm KittyGraphicsParityTests /
/// KittyGraphicsHardeningTests at 28c6d1d9 (MIT), verified separately against
/// the frozen VT with Tools/probe-vt-image-api.c. No host animation model.
enum NativeAnimationFixture {
    static let finite = "\u{1b}[?25l\u{1b}_Ga=T,f=32,s=1,v=1,i=7,p=3,c=2,r=2,C=1;/wAA/w==\u{1b}\\"
        + "\u{1b}_Ga=f,f=32,s=1,v=1,i=7,z=150,X=1;AP8A/w==\u{1b}\\"
        + "\u{1b}_Ga=f,f=32,s=1,v=1,i=7,z=200,X=1;AAD//w==\u{1b}\\"
        + "\u{1b}_Ga=a,i=7,r=1,z=100,s=3,c=1,v=2\u{1b}\\"
}

final class NativeImageAnimationTests: XCTestCase {
    private func draw(_ driver: GhosttyVTDriver) throws -> NativeTerminalFrame {
        try XCTUnwrap(driver.presentation(rowHeight: 16, viewportHeight: 96, previous: nil)).frame
    }

    func testVTDeadlinesGenerationsFiniteLoopAndOwnedOldPixels() throws {
        let clock = NativeAnimationTestClock()
        let driver = try GhosttyVTDriver(columns: 12, rows: 6, animationClock: { clock.milliseconds })
        driver.feed(NativeAnimationFixture.finite)
        let first = try XCTUnwrap(draw(driver).imageSnapshot.images[7])
        XCTAssertEqual(first.rgba, [255,0,0,255])
        XCTAssertEqual(driver.imageAnimationWake, .init(deadlineMilliseconds: 101, delayMilliseconds: 100))
        clock.set(100)
        XCTAssertTrue(try draw(driver).imageSnapshot.images[7] === first)
        clock.set(101)
        let green = try XCTUnwrap(draw(driver).imageSnapshot.images[7])
        XCTAssertEqual(green.rgba, [0,255,0,255]); XCTAssertNotEqual(green.generation, first.generation)
        XCTAssertEqual(driver.imageAnimationWake?.deadlineMilliseconds, 251)
        clock.set(251)
        XCTAssertEqual(try draw(driver).imageSnapshot.images[7]?.rgba, [0,0,255,255])
        XCTAssertEqual(driver.imageAnimationWake?.deadlineMilliseconds, 451)
        clock.set(1000)
        XCTAssertEqual(try draw(driver).imageSnapshot.images[7]?.rgba, [0,0,255,255])
        XCTAssertNil(driver.imageAnimationWake)
        XCTAssertEqual(first.rgba, [255,0,0,255]); XCTAssertEqual(green.rgba, [0,255,0,255])
    }

    func testLateCallsAdvanceOneFrameWithoutCatchupAndClockNeverRewinds() throws {
        let clock = NativeAnimationTestClock()
        let driver = try GhosttyVTDriver(columns: 12, rows: 6, animationClock: { clock.milliseconds })
        driver.feed(NativeAnimationFixture.finite + "\u{1b}_Ga=a,i=7,v=1\u{1b}\\")
        _ = try draw(driver)
        clock.set(10_000)
        let green = try XCTUnwrap(draw(driver).imageSnapshot.images[7])
        XCTAssertEqual(green.rgba, [0,255,0,255])
        XCTAssertEqual(driver.imageAnimationWake?.deadlineMilliseconds, 10_150)
        XCTAssertTrue(try draw(driver).imageSnapshot.images[7] === green)
        clock.set(0)
        XCTAssertTrue(try draw(driver).imageSnapshot.images[7] === green)
        XCTAssertEqual(driver.imageAnimationWake?.delayMilliseconds, 150)
        clock.set(10_150)
        XCTAssertEqual(try draw(driver).imageSnapshot.images[7]?.rgba, [0,0,255,255])
        clock.set(10_350)
        XCTAssertEqual(try draw(driver).imageSnapshot.images[7]?.rgba, [255,0,0,255])
    }

    func testSnapshotsAndParsingDoNotTickOrSelectAnotherFrame() throws {
        let clock = NativeAnimationTestClock()
        let driver = try GhosttyVTDriver(columns: 12, rows: 6, animationClock: { clock.milliseconds })
        driver.feed(NativeAnimationFixture.finite)
        let first = try draw(driver)
        clock.set(5000)
        driver.feed("text\u{1b}[5n")
        XCTAssertEqual(try driver.snapshot(topRow: 0).imageSnapshot.images[7]?.generation, first.imageSnapshot.images[7]?.generation)
        XCTAssertEqual(try draw(driver).imageSnapshot.images[7]?.rgba, [0,255,0,255])
    }

    func testHoldPreventsTicksAndRepliesKeepDraining() throws {
        let clock = NativeAnimationTestClock()
        let driver = try GhosttyVTDriver(columns: 12, rows: 6, animationClock: { clock.milliseconds })
        driver.feed(NativeAnimationFixture.finite)
        let first = try draw(driver)
        let reply = driver.feed("\u{1b}[?2026h\u{1b}[5n")
        XCTAssertEqual(reply, Data("\u{1b}[0n".utf8))
        clock.set(5000)
        XCTAssertNil(try driver.presentation(rowHeight: 16, viewportHeight: 96, previous: nil))
        XCTAssertTrue(try driver.snapshot(topRow: 0).imageSnapshot.images[7] === first.imageSnapshot.images[7])
        driver.feed("\u{1b}[?2026l")
        XCTAssertEqual(try draw(driver).imageSnapshot.images[7]?.rgba, [0,255,0,255])
    }

    func testStopDeleteActiveScreenSwitchAndResetClearDeadlines() throws {
        let clock = NativeAnimationTestClock()
        let driver = try GhosttyVTDriver(columns: 12, rows: 6, animationClock: { clock.milliseconds })
        driver.feed(NativeAnimationFixture.finite)
        _ = try draw(driver)
        driver.feed("\u{1b}_Ga=a,i=7,s=1\u{1b}\\")
        _ = try draw(driver); XCTAssertNil(driver.imageAnimationWake)
        driver.feed("\u{1b}_Ga=a,i=7,s=3\u{1b}\\")
        _ = try draw(driver); XCTAssertNotNil(driver.imageAnimationWake)
        driver.feed("\u{1b}[?1049h")
        XCTAssertTrue(try draw(driver).imageSnapshot.images.isEmpty); XCTAssertNil(driver.imageAnimationWake)
        driver.feed("\u{1b}[?1049l")
        XCTAssertNotNil(try draw(driver).imageSnapshot.images[7]); XCTAssertNotNil(driver.imageAnimationWake)
        driver.feed("\u{1b}_Ga=d,d=I,i=7\u{1b}\\")
        XCTAssertTrue(try draw(driver).imageSnapshot.images.isEmpty); XCTAssertNil(driver.imageAnimationWake)
        driver.feed(NativeAnimationFixture.finite)
        _ = try draw(driver); XCTAssertNotNil(driver.imageAnimationWake)
        driver.reset()
        XCTAssertNil(driver.imageAnimationWake); XCTAssertTrue(try draw(driver).imageSnapshot.images.isEmpty)
    }

    func testPNGAnimationFrameIsDecodedByVTAndChangesGeneration() throws {
        let clock = NativeAnimationTestClock()
        let driver = try GhosttyVTDriver(columns: 12, rows: 6, animationClock: { clock.milliseconds })
        let root = Data([255,0,0,255, 255,0,0,255, 255,0,0,255, 255,0,0,255]).base64EncodedString()
        let png = NativePNGFixtures.vectors[0]
        driver.feed("\u{1b}_Ga=T,f=32,s=2,v=2,i=7,p=3,c=2,r=2,C=1;\(root)\u{1b}\\"
            + "\u{1b}_Ga=f,f=100,i=7,z=150,X=1;\(png.encoded)\u{1b}\\"
            + "\u{1b}_Ga=a,i=7,r=1,z=100,s=3,c=1,v=2\u{1b}\\")
        let before = try XCTUnwrap(draw(driver).imageSnapshot.images[7])
        clock.set(101)
        let after = try XCTUnwrap(draw(driver).imageSnapshot.images[7])
        XCTAssertEqual(after.rgba, png.rgba)
        XCTAssertNotEqual(before.generation, after.generation)
    }

    func testAllZeroGapFramesDoNotArmAHostBusyLoop() throws {
        let driver = try GhosttyVTDriver(columns: 12, rows: 6)
        driver.feed(NativeAnimationFixture.finite
            + "\u{1b}_Ga=a,i=7,r=1,z=-1\u{1b}\\\u{1b}_Ga=a,i=7,r=2,z=-1\u{1b}\\\u{1b}_Ga=a,i=7,r=3,z=-1\u{1b}\\")
        _ = try draw(driver)
        XCTAssertNil(driver.imageAnimationWake)
    }

    func testZeroGapFramesUseVTPolicyWithoutHostPolling() throws {
        let clock = NativeAnimationTestClock()
        let driver = try GhosttyVTDriver(columns: 12, rows: 6, animationClock: { clock.milliseconds })
        driver.feed(NativeAnimationFixture.finite + "\u{1b}_Ga=a,i=7,r=2,z=-1\u{1b}\\")
        _ = try draw(driver)
        clock.set(101)
        XCTAssertEqual(try draw(driver).imageSnapshot.images[7]?.rgba, [0,0,255,255])
        XCTAssertEqual(driver.imageAnimationWake?.deadlineMilliseconds, 301)
    }
}

/// Owned synthetic window visibility, not GUI automation or device acceptance.
@MainActor
final class NativeAnimationTestWindow: NSWindow {
    var testVisible = true
    override var isVisible: Bool { testVisible }
    override var occlusionState: NSWindow.OcclusionState { testVisible ? [.visible] : [] }
}

@MainActor
final class NativeImageAnimationViewTests: XCTestCase {
    private func make(_ clock: NativeAnimationTestClock) throws -> (NativeTerminalScrollView, NativeAnimationTestWindow) {
        let driver = try GhosttyVTDriver(animationClock: { clock.milliseconds })
        let view = NativeTerminalScrollView(driver: driver, frame: CGRect(x: 0, y: 0, width: 640, height: 240), applicationIsHidden: { false })
        let window = NativeAnimationTestWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.feed(NativeAnimationFixture.finite)
        return (view, window)
    }

    func testVisibilityOcclusionHideDetachAndDisplaySleepCancelAndResume() throws {
        let clock = NativeAnimationTestClock(), (view, window) = try make(clock)
        defer { view.resetPresentation(); window.contentView = nil }
        let responder = window.firstResponder
        XCTAssertEqual(view.scheduledImageAnimationDeadline, 101)
        window.testVisible = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertNil(view.scheduledImageAnimationDeadline)
        clock.set(5000)
        XCTAssertEqual(view.presentedFrame?.imageSnapshot.images[7]?.rgba, [255,0,0,255])
        window.testVisible = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertEqual(view.presentedFrame?.imageSnapshot.images[7]?.rgba, [0,255,0,255])
        XCTAssertEqual(view.scheduledImageAnimationDeadline, 5150)
        view.isHidden = true; XCTAssertNil(view.scheduledImageAnimationDeadline)
        view.isHidden = false; XCTAssertNotNil(view.scheduledImageAnimationDeadline)
        view.setDisplaysAsleep(true); XCTAssertNil(view.scheduledImageAnimationDeadline)
        view.setDisplaysAsleep(false); XCTAssertNotNil(view.scheduledImageAnimationDeadline)
        XCTAssertTrue(window.firstResponder === responder)
        window.contentView = nil; XCTAssertNil(view.scheduledImageAnimationDeadline)
    }

    func testHiddenFixtureCanCaptureButNeverStartsOrAdvancesAnimation() throws {
        let clock = NativeAnimationTestClock()
        let driver = try GhosttyVTDriver(animationClock: { clock.milliseconds })
        let view = NativeTerminalScrollView(driver: driver, frame: CGRect(x: 0, y: 0, width: 640, height: 240), applicationIsHidden: { false })
        view.refresh(resizeTerminal: true)
        view.feed(NativeAnimationFixture.finite)
        clock.set(5000); view.refresh()
        XCTAssertNil(view.scheduledImageAnimationDeadline); XCTAssertNil(driver.imageAnimationWake)
        XCTAssertEqual(view.presentedFrame?.imageSnapshot.images[7]?.rgba, [255,0,0,255])
    }

    func testHoldCancelsAnimationThenReleaseSchedulesFreshDeadline() throws {
        let clock = NativeAnimationTestClock(), (view, window) = try make(clock)
        defer { view.resetPresentation(); window.contentView = nil }
        view.feed("\u{1b}[?2026h")
        XCTAssertNil(view.scheduledImageAnimationDeadline)
        clock.set(101)
        view.feed("\u{1b}[?2026l")
        XCTAssertEqual(view.presentedFrame?.imageSnapshot.images[7]?.rgba, [0,255,0,255])
        XCTAssertEqual(view.scheduledImageAnimationDeadline, 251)
        view.driver.reset(); view.parsedOutput(reset: true)
        XCTAssertNil(view.scheduledImageAnimationDeadline)
        XCTAssertTrue(view.presentedFrame?.imageSnapshot.images.isEmpty == true)
    }

    func testHiddenHoldCancellationRetainsAPendingRefreshEvenWithoutImages() throws {
        let view = NativeTerminalScrollView(driver: try GhosttyVTDriver(), frame: CGRect(x: 0, y: 0, width: 640, height: 240), applicationIsHidden: { false })
        let window = NativeAnimationTestWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { view.resetPresentation(); window.contentView = nil }
        view.feed("before\u{1b}[?2026h\r\nheld-text")
        window.testVisible = false; view.presentPendingOutput()
        XCTAssertTrue(view.hasPendingOutput)
        view.driver.feed("\u{1b}[?2026l")
        window.testVisible = true; view.presentPendingOutput()
        XCTAssertFalse(view.hasPendingOutput)
        XCTAssertTrue(view.presentedFrame?.rows.values.contains { $0.cells.compactMap(\.text).joined().contains("held-text") } == true)
    }

    func testNoVisibleImagePlacementsMeansNoWakeWhileReadingOtherRows() throws {
        let clock = NativeAnimationTestClock(), (view, window) = try make(clock)
        defer { view.resetPresentation(); window.contentView = nil }
        view.feed("\u{1b}[999;1H" + String(repeating: "history\r\n", count: 100))
        XCTAssertTrue(view.presentedFrame?.imageSnapshot.placements.isEmpty == true)
        XCTAssertNil(view.scheduledImageAnimationDeadline)
        view.contentView.scroll(to: .zero)
        XCTAssertFalse(view.presentedFrame?.imageSnapshot.placements.isEmpty ?? true)
        XCTAssertNotNil(view.scheduledImageAnimationDeadline)
    }

    func testFractionalClipStopsTinyOffscreenImageWithoutCapturingNewRows() throws {
        let clock = NativeAnimationTestClock()
        let view = NativeTerminalScrollView(driver: try GhosttyVTDriver(animationClock: { clock.milliseconds }),
            frame: CGRect(x: 0, y: 0, width: 640, height: 240), applicationIsHidden: { false })
        let window = NativeAnimationTestWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { view.resetPresentation(); window.contentView = nil }
        // A natural 1-pixel image, then enough history to permit within-row
        // clipping past that image. No altered animation timing/control vector.
        view.feed(NativeAnimationFixture.finite.replacingOccurrences(of: ",c=2,r=2", with: "")
            + "\u{1b}[999;1H" + String(repeating: "history\r\n", count: 100))
        view.contentView.scroll(to: .zero)
        XCTAssertNotNil(view.scheduledImageAnimationDeadline)
        let converted = view.source.convertedRows
        view.contentView.scroll(to: CGPoint(x: 0, y: 2))
        XCTAssertEqual(view.source.convertedRows, converted)
        XCTAssertFalse(view.presentedFrame?.imageSnapshot.placements.isEmpty ?? true, "image remains in captured overscan")
        XCTAssertNil(view.scheduledImageAnimationDeadline)
    }

    func testApplicationHiddenGateNeverTicksAndRestartsOnlyWhenVisible() throws {
        let clock = NativeAnimationTestClock()
        let state = NativeAnimationApplicationState()
        let view = NativeTerminalScrollView(driver: try GhosttyVTDriver(animationClock: { clock.milliseconds }),
            frame: CGRect(x: 0, y: 0, width: 640, height: 240), applicationIsHidden: { state.hidden })
        let window = NativeAnimationTestWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { view.resetPresentation(); window.contentView = nil }
        view.feed(NativeAnimationFixture.finite)
        XCTAssertNotNil(view.scheduledImageAnimationDeadline)
        state.hidden = true; view.presentPendingOutput()
        XCTAssertNil(view.scheduledImageAnimationDeadline)
        clock.set(5000)
        view.presentPendingOutput()
        XCTAssertEqual(view.presentedFrame?.imageSnapshot.images[7]?.rgba, [255,0,0,255])
        state.hidden = false; view.presentPendingOutput()
        XCTAssertEqual(view.presentedFrame?.imageSnapshot.images[7]?.rgba, [0,255,0,255])
        XCTAssertNotNil(view.scheduledImageAnimationDeadline)
    }

    func testLoopingDeadlineTaskDoesNotRetainViewOrDriver() throws {
        weak var weakView: NativeTerminalScrollView?
        weak var weakDriver: GhosttyVTDriver?
        let window = NativeAnimationTestWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 240), styleMask: [], backing: .buffered, defer: false)
        try autoreleasepool {
            let view = NativeTerminalScrollView(driver: try GhosttyVTDriver(), frame: window.contentRect(forFrameRect: window.frame), applicationIsHidden: { false })
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            view.feed(NativeAnimationFixture.finite + "\u{1b}_Ga=a,i=7,r=1,z=60000,v=1\u{1b}\\")
            XCTAssertNotNil(view.scheduledImageAnimationDeadline)
            weakView = view; weakDriver = view.driver
            window.contentView = nil
        }
        XCTAssertNil(weakView); XCTAssertNil(weakDriver)
    }

    func testPendingAnimationNeverBlocksBackgroundParsingRepliesOrCreditBarrier() throws {
        let clock = NativeAnimationTestClock(), (view, window) = try make(clock)
        defer { view.resetPresentation(); window.contentView = nil }
        let bytes = NativeAnimationBytes()
        let output = NativeTerminalOutput(driver: view.driver) { [weak view] reset in view?.parsedOutput(reset: reset) }
        output.bind(writer: { bytes.append($0) })
        view.renderer.output = output
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.receive(Data(String(repeating: "output\r\n\u{1b}[5n", count: 3000).utf8))
            XCTAssertTrue(output.waitForPendingOutput())
            done.signal()
        }
        // Intentionally occupy the main actor. The deadline/presentation may
        // wait; transport parsing, replies and its credit barrier must finish.
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(bytes.count, 3000 * Data("\u{1b}[0n".utf8).count)
    }

    func testRealDeadlineRefreshesWithoutMoreOutputAndFinitePlaybackStops() async throws {
        let driver = try GhosttyVTDriver()
        let view = NativeTerminalScrollView(driver: driver, frame: CGRect(x: 0, y: 0, width: 640, height: 240), applicationIsHidden: { false })
        let window = NativeAnimationTestWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { view.resetPresentation(); window.contentView = nil }
        let green = expectation(description: "deadline displays green"), stopped = expectation(description: "finite playback stops")
        var sawGreen = false, sawStop = false
        view.onStatusChange = { _ in
            let rgba = view.presentedFrame?.imageSnapshot.images[7]?.rgba
            if rgba == [0,255,0,255], !sawGreen { sawGreen = true; green.fulfill() }
            if rgba == [0,0,255,255], driver.imageAnimationWake == nil, !sawStop { sawStop = true; stopped.fulfill() }
        }
        view.feed(NativeAnimationFixture.finite)
        await fulfillment(of: [green, stopped], timeout: 2)
        XCTAssertNil(view.scheduledImageAnimationDeadline)
    }
}

@MainActor
private final class NativeAnimationApplicationState { var hidden = false }

private final class NativeAnimationBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func append(_ data: Data) { lock.withLock { value.append(data) } }
    var count: Int { lock.withLock { value.count } }
}

final class NativeAnimationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: UInt64 = 1
    var milliseconds: UInt64 { lock.withLock { time } }
    func set(_ value: UInt64) { lock.withLock { time = value } }
}
