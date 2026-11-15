import Foundation
import XCTest
@testable import Santty

final class NativeTerminalMetadataTests: XCTestCase {
    func testFragmentedUnicodeTitleAndRawRemoteDirectoryAreOwnedNotParsedPaths() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("\u{1b}]2;中文 e")
        XCTAssertEqual(driver.metadata.title, "")
        driver.feed("\u{301} 🐱\u{1b}\\\u{1b}]7;file://remote.example/tmp/a%20b\u{7}")
        let owned = driver.metadata
        XCTAssertEqual(owned.title, "中文 e\u{301} 🐱")
        XCTAssertEqual(owned.rawWorkingDirectory, "file://remote.example/tmp/a%20b")
        driver.reset()
        XCTAssertEqual(owned.rawWorkingDirectory, "file://remote.example/tmp/a%20b", "owned snapshot survives reset/free")
        XCTAssertEqual(driver.metadata.title, ""); XCTAssertEqual(driver.metadata.rawWorkingDirectory, "")
        XCTAssertGreaterThan(driver.metadata.resetEpoch, owned.resetEpoch)
    }

    func testDeduplicationUsesExactUTF8RatherThanCanonicalEquality() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("\u{1b}]2;é\u{7}")
        let first = driver.metadata
        driver.feed("\u{1b}]2;é\u{7}")
        XCTAssertEqual(driver.metadata, first)
        driver.feed("\u{1b}]2;e\u{301}\u{7}")
        XCTAssertGreaterThan(driver.metadata.revision, first.revision)
        XCTAssertEqual(Array(try XCTUnwrap(driver.metadata.title).utf8), [101, 204, 129])
    }

    func testMetadataChangesDuringRenderHoldWithoutPublishingNewCells() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("old"); let before = try driver.snapshot(topRow: 0)
        driver.feed("\u{1b}[?2026hnew\u{1b}]2;held title\u{7}\u{1b}]7;/raw/no-filesystem-query\u{7}")
        XCTAssertEqual(driver.metadata.title, "held title")
        XCTAssertEqual(driver.metadata.rawWorkingDirectory, "/raw/no-filesystem-query")
        XCTAssertEqual(try driver.snapshot(topRow: 0).rows[0]?.cells, before.rows[0]?.cells)
        XCTAssertNotNil(driver.renderHoldRemaining)
    }

    func testRISAndHostResetClearMetadataAndRevisionEvenWithoutPainting() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("\u{1b}]2;old\u{7}\u{1b}]7;file:///old\u{7}")
        let before = driver.metadata
        driver.feed("\u{1b}c")
        XCTAssertEqual(driver.metadata.title, ""); XCTAssertEqual(driver.metadata.rawWorkingDirectory, "")
        XCTAssertGreaterThan(driver.metadata.revision, before.revision)
        let reset = driver.metadata
        driver.reset()
        XCTAssertGreaterThan(driver.metadata.revision, reset.revision)
        XCTAssertGreaterThan(driver.metadata.resetEpoch, reset.resetEpoch)
    }

    func testCopyBoundaryRefusesOversizeAndInvalidUTF8AndOwnsItsBytes() {
        var bytes: [UInt8] = [195, 169]
        let owned = bytes.withUnsafeBufferPointer { NativeTerminalMetadata.copy(bytes: $0.baseAddress, count: $0.count) }
        bytes[0] = 65
        XCTAssertEqual(owned, "é")
        let large = [UInt8](repeating: 120, count: NativeTerminalMetadata.maximumBytes + 1)
        XCTAssertNil(large.withUnsafeBufferPointer { NativeTerminalMetadata.copy(bytes: $0.baseAddress, count: $0.count) })
        XCTAssertNil([UInt8(255)].withUnsafeBufferPointer { NativeTerminalMetadata.copy(bytes: $0.baseAddress, count: $0.count) })
        XCTAssertNil(NativeTerminalMetadata.copy(bytes: nil, count: -1))
        XCTAssertNil(NativeTerminalMetadata.copy(bytes: nil, count: 1))
        XCTAssertEqual(NativeTerminalMetadata.copy(bytes: nil, count: 0), "")
    }

    func testLargeMetadataIsBoundedAndRecoversWithAnExplicitClear() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("\u{1b}]2;" + String(repeating: "x", count: NativeTerminalMetadata.maximumBytes + 1) + "\u{7}")
        // Independent C confirms the pin rejects this OSC before the host
        // boundary. Retain that original vector rather than pretending the
        // adapter's 16 KiB cap fired. Its copy boundary is tested separately.
        XCTAssertEqual(driver.metadata.title, "")
        driver.feed("\u{1b}]2;recovered\u{7}\u{1b}]7;\u{7}")
        XCTAssertEqual(driver.metadata.title, "recovered")
        XCTAssertEqual(driver.metadata.rawWorkingDirectory, "")
        XCTAssertEqual(driver.feed("\u{1b}[5n"), Data("\u{1b}[0n".utf8))
    }
}

@MainActor
final class NativeMetadataPublicationTests: XCTestCase {
    func testBackgroundParsingAndRepliesDoNotWaitForMainActorMetadataDelivery() async throws {
        let driver = try GhosttyVTDriver()
        var snapshots: [NativeTerminalMetadata] = []
        let output = NativeTerminalOutput(driver: driver) { _ in }
        output.onMetadataChange = { value in snapshots.append(value); XCTAssertTrue(Thread.isMainThread) }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.receive(Data("\u{1b}]2;hidden\u{7}\u{1b}]7;file://remote.invalid/path\u{7}".utf8))
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(driver.metadata.title, "hidden")
        XCTAssertTrue(snapshots.isEmpty, "main actor is still intentionally occupied")
        for _ in 0..<100 { if !snapshots.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].rawWorkingDirectory, "file://remote.invalid/path")
        output.receive(Data("ordinary output".utf8))
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(snapshots.count, 1, "text-only output does not duplicate metadata")
    }

    func testQueuedOldMetadataCannotLeakAcrossResetAndCallbacksAreOutsideTheVTLock() async throws {
        let driver = try GhosttyVTDriver()
        var snapshots: [NativeTerminalMetadata] = []
        let output = NativeTerminalOutput(driver: driver) { _ in }
        output.onMetadataChange = { value in
            snapshots.append(value)
            // Reentrant driver access is legal: C callback only dirties state,
            // no user callback or main dispatch occurs under the parser lock.
            XCTAssertEqual(driver.metadata, value)
            let read = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { _ = driver.metadata; read.signal() }
            XCTAssertEqual(read.wait(timeout: .now() + 1), .success, "callback must not hold the VT lock against another thread")
        }
        output.receive(Data("\u{1b}]2;must not publish\u{7}".utf8))
        output.reset()
        for _ in 0..<100 { if !snapshots.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(snapshots.count, 1); XCTAssertEqual(snapshots[0].title, "")
        XCTAssertGreaterThan(snapshots[0].resetEpoch, 0)
    }
}
