// OSC 52 vectors/payload policy adapted from herdr-app a547b16c, vt.rs
// (Apache-2.0; Licenses/Herdr-app.txt). The current ABI denies the original
// synchronous write; an offer is a separate explicit user copy, never SUCCESS.
import AppKit
import GhosttyVt
import XCTest
@testable import SanttyTerminalLab

private final class ClipboardClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func now() -> TimeInterval { lock.withLock { value } }
    func advance() { lock.withLock { value += NativeClipboardInbox.maximumAge + 1 } }
}

final class NativeClipboardCoreTests: XCTestCase {
    private func write(_ text: String) -> String { "\u{1b}]52;c;\(Data(text.utf8).base64EncodedString())\u{7}" }

    func testDefaultDenyAndFragmentedUnicodeOffers() throws {
        let driver = try GhosttyVTDriver()
        driver.feed(write("not authorized")); XCTAssertNil(driver.clipboardOffer)
        driver.setClipboardCaptureEnabled(true)
        driver.feed("\u{1b}]52;c;aGVs"); XCTAssertNil(driver.clipboardOffer)
        driver.feed("bG8=\u{7}"); XCTAssertEqual(driver.clipboardOffer?.payload, .text("hello"))
        driver.feed("\u{1b}]52;c;8J+YgA==\u{1b}\\")
        XCTAssertEqual(driver.clipboardOffer?.payload, .text("😀"))
        for selector in "01234567" {
            driver.feed("\u{1b}]52;\(selector);aGk=\u{7}")
            XCTAssertEqual(driver.clipboardOffer?.payload, .text("hi"))
        }
        driver.discardClipboardOffers()
        for payload in ["\u{1b}]52;p;aGk=\u{7}", "\u{1b}]52;s;aGk=\u{7}",
                        "\u{1b}]52;c;%%%\u{7}", "\u{1b}]52;c;/w==\u{7}", "\u{1b}]52;c;AA==\u{7}"] {
            driver.feed(payload)
            XCTAssertNil(driver.clipboardOffer)
        }
    }

    func testDecodedLimitAndRecoveryDoNotDependOnDrawing() throws {
        let driver = try GhosttyVTDriver()
        driver.setClipboardCaptureEnabled(true)
        driver.feed(write(String(repeating: "x", count: NativeClipboardInbox.maximumBytes)))
        XCTAssertEqual(driver.clipboardOffer?.byteCount, NativeClipboardInbox.maximumBytes)
        driver.discardClipboardOffers()
        driver.feed(write(String(repeating: "x", count: NativeClipboardInbox.maximumBytes + 1)))
        XCTAssertNil(driver.clipboardOffer)
        driver.feed(write("recovered"))
        XCTAssertEqual(driver.clipboardOffer?.payload, .text("recovered"))
        XCTAssertEqual(driver.feed("\u{1b}[5n"), Data("\u{1b}[0n".utf8))
    }

    func testExpiryResetRISAndSingleLastOffer() throws {
        let clock = ClipboardClock()
        let driver = try GhosttyVTDriver(clock: { clock.now() })
        driver.setClipboardCaptureEnabled(true)
        driver.feed(write("a") + write("b"))
        let offer = try XCTUnwrap(driver.clipboardOffer)
        XCTAssertEqual(offer.payload, .text("b"))
        clock.advance(); XCTAssertNil(driver.claimClipboardOffer(offer.id))
        driver.feed(write("reset")); driver.reset(); XCTAssertNil(driver.clipboardOffer)
        driver.feed(write("RIS") + "\u{1b}c"); XCTAssertNil(driver.clipboardOffer)
        driver.feed(write("off")); driver.setClipboardCaptureEnabled(false); XCTAssertNil(driver.clipboardOffer)
        driver.setClipboardCaptureEnabled(true); XCTAssertNil(driver.clipboardOffer)
    }

    func testReadRequestsAreDeniedAndKittyWritesAreNeverAcknowledgedAsCommitted() throws {
        let driver = try GhosttyVTDriver()
        driver.setClipboardCaptureEnabled(true)
        XCTAssertTrue(driver.feed("\u{1b}]52;c;?\u{7}").isEmpty)
        let read = driver.feed("\u{1b}]5522;type=read:id=r;dGV4dC9wbGFpbg==\u{1b}\\")
        XCTAssertTrue(String(decoding: read, as: UTF8.self).contains("EPERM"))
        XCTAssertNil(driver.clipboardOffer)
        let packets = "\u{1b}]5522;type=write:id=w\u{1b}\\"
            + "\u{1b}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\u{1b}\\"
            + "\u{1b}]5522;type=wdata\u{1b}\\"
        let reply = String(decoding: driver.feed(packets), as: UTF8.self)
        XCTAssertTrue(reply.contains("EPERM"))
        XCTAssertFalse(reply.contains("DONE"))
        XCTAssertEqual(driver.clipboardOffer?.payload, .text("hi"))
    }

    func testInboxRejectsUnsupportedOrMalformedAtomicRepresentations() {
        let inbox = NativeClipboardInbox()
        inbox.setEnabled(true)
        Array("text/plain".utf8).withUnsafeBufferPointer { mime in
            var content = GhosttyClipboardContent(mime: .init(ptr: mime.baseAddress, len: mime.count), data: .init(ptr: nil, len: 0))
            withUnsafePointer(to: &content) { pointer in
                var request = GhosttyClipboardWrite()
                request.location = GHOSTTY_CLIPBOARD_LOCATION_STANDARD
                request.contents = pointer; request.contents_len = 1; request.granted = true
                XCTAssertEqual(inbox.capture(request, now: 0), GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED)
                XCTAssertEqual(inbox.current(now: 0)?.payload, .text(""), "a grant cannot bypass explicit review")
                request.contents_len = 2
                XCTAssertEqual(inbox.capture(request, now: 0), GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED)
                XCTAssertNil(inbox.current(now: 0))
                request.contents_len = 0
                XCTAssertEqual(inbox.capture(request, now: 0), GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED)
                XCTAssertEqual(inbox.current(now: 0)?.payload, .clear)
            }
            content.data.len = Int.max
            withUnsafePointer(to: &content) { pointer in
                var request = GhosttyClipboardWrite()
                request.location = GHOSTTY_CLIPBOARD_LOCATION_STANDARD; request.contents = pointer; request.contents_len = 1
                XCTAssertEqual(inbox.capture(request, now: 0), GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA)
                XCTAssertNil(inbox.current(now: 0))
            }
        }
    }

    func testOfferPreviewEscapesInvisibleAndControlCharacters() {
        let offer = NativeClipboardOffer(id: UUID(), payload: .text("ok\u{1b}\n\u{202e}bad"), createdAt: 0)
        XCTAssertEqual(offer.preview, "ok\\u{1b}\\u{a}\\u{202e}bad")
        XCTAssertEqual(NativeClipboardOffer(id: UUID(), payload: .text(String(repeating: "x", count: 1000)), createdAt: 0).preview.count, 257)
    }
}

private final class ClipboardBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var data: Data { lock.withLock { bytes } }
}

@MainActor
final class NativeClipboardReviewTests: XCTestCase {
    private func output() throws -> NativeTerminalOutput {
        let output = NativeTerminalOutput(driver: try GhosttyVTDriver()) { _ in }
        output.bind(writer: { _ in }); output.setInputEnabled(true)
        return output
    }
    private func offer(_ text: String, _ output: NativeTerminalOutput) throws -> NativeClipboardOffer {
        output.receive(Data("\u{1b}]52;c;\(Data(text.utf8).base64EncodedString())\u{7}".utf8))
        return try XCTUnwrap(output.clipboardOffer)
    }

    func testBackgroundClipboardParsingAndRepliesNeverWaitForMainActorApproval() throws {
        let output = try output(), done = DispatchSemaphore(value: 0), bytes = ClipboardBytes()
        output.bind(writer: { bytes.append($0) })
        DispatchQueue.global().async {
            output.receive(Data("\u{1b}]52;c;aGk=\u{7}\u{1b}[5n".utf8))
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(output.clipboardOffer?.payload, .text("hi"))
        XCTAssertEqual(bytes.data, Data("\u{1b}[0n".utf8))
    }

    func testClipboardUntouchedUntilExactExplicitApprovalAndCannotReplay() throws {
        let output = try output(), pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("unchanged", forType: .string)
        let a = try offer("offered", output)
        XCTAssertEqual(pasteboard.string(forType: .string), "unchanged")
        XCTAssertTrue(NativeClipboardReview.copy(id: a.id, output: output, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "offered")
        pasteboard.clearContents(); pasteboard.setString("later clipboard", forType: .string)
        XCTAssertFalse(NativeClipboardReview.copy(id: a.id, output: output, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "later clipboard")
    }

    func testReplacementOfflineRebindAndResetInvalidateAlreadyOpenReview() throws {
        let output = try output(), pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("unchanged", forType: .string)
        let a = try offer("a", output), b = try offer("b", output)
        XCTAssertFalse(NativeClipboardReview.copy(id: a.id, output: output, to: pasteboard))
        XCTAssertTrue(NativeClipboardReview.copy(id: b.id, output: output, to: pasteboard))
        let offline = try offer("offline", output)
        output.setInputEnabled(false); output.setInputEnabled(true)
        XCTAssertFalse(NativeClipboardReview.copy(id: offline.id, output: output, to: pasteboard))
        let rebound = try offer("rebound", output)
        output.bind(writer: { _ in })
        XCTAssertFalse(NativeClipboardReview.copy(id: rebound.id, output: output, to: pasteboard))
        let reset = try offer("reset", output); output.reset()
        XCTAssertFalse(NativeClipboardReview.copy(id: reset.id, output: output, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "b")
    }

    func testEmptyOSC52ClearRequiresExplicitApprovalToo() throws {
        let output = try output(), pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("unchanged", forType: .string)
        let empty = try offer("", output)
        XCTAssertEqual(empty.payload, .clear)
        XCTAssertEqual(pasteboard.string(forType: .string), "unchanged")
        XCTAssertTrue(NativeClipboardReview.copy(id: empty.id, output: output, to: pasteboard))
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testKittyEmptyTextRepresentationIsNotAClipboardClear() throws {
        let output = try output(), pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        output.receive(Data(("\u{1b}]5522;type=write\u{1b}\\"
            + "\u{1b}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;\u{1b}\\"
            + "\u{1b}]5522;type=wdata\u{1b}\\").utf8))
        let empty = try XCTUnwrap(output.clipboardOffer)
        XCTAssertEqual(empty.payload, .text(""))
        XCTAssertTrue(NativeClipboardReview.copy(id: empty.id, output: output, to: pasteboard))
        XCTAssertEqual(pasteboard.data(forType: .string), Data())
    }
}
