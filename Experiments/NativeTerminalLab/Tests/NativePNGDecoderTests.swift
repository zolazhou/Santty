import Darwin
import Foundation
import GhosttyVt
import XCTest
@testable import SanttyTerminalLab

final class NativePNGDecoderTests: XCTestCase {
    private func decoded(_ data: Data, probe: PNGAllocatorProbe = .init()) -> (Bool, GhosttySysImage, [UInt8]) {
        probe.withAllocator { allocator in
            var image = GhosttySysImage()
            let accepted = data.withUnsafeBytes { raw in
                NativePNGDecoder.decode(allocator: allocator, data: raw.bindMemory(to: UInt8.self).baseAddress,
                    count: raw.count, output: &image)
            }
            let pixels = image.data.map { Array(UnsafeBufferPointer(start: $0, count: image.data_len)) } ?? []
            if let pixels = image.data { ghostty_free(allocator, pixels, image.data_len) }
            // No pointer into an already freed output escapes this helper.
            image.data = nil
            return (accepted, image, pixels)
        }
    }

    func testIndependentColorDepthPaletteTransparencyAndAdam7Vectors() throws {
        for vector in NativePNGFixtures.vectors {
            let probe = PNGAllocatorProbe(), data = try XCTUnwrap(Data(base64Encoded: vector.encoded))
            let (ok, image, pixels) = decoded(data, probe: probe)
            XCTAssertTrue(ok, vector.name)
            XCTAssertEqual(Int(image.width), vector.width, vector.name)
            XCTAssertEqual(Int(image.height), vector.height, vector.name)
            XCTAssertEqual(pixels, vector.rgba, vector.name)
            XCTAssertEqual(probe.allocations, [vector.width * vector.height * 4], vector.name)
            XCTAssertEqual(probe.frees, probe.allocations, vector.name)
            XCTAssertTrue(probe.live.isEmpty, vector.name)
        }
    }

    func testTerminalF100UsesPNGDimensionsAndCopiesOwnedPixels() throws {
        for vector in NativePNGFixtures.vectors {
            let driver = try GhosttyVTDriver(columns: 12, rows: 6)
            // No s/v dimensions: PNG is authoritative, not terminal guesses.
            let response = String(decoding: driver.feed("\u{1b}_Ga=T,f=100,i=7,p=3,c=2,r=2;\(vector.encoded)\u{1b}\\"), as: UTF8.self)
            XCTAssertTrue(response.contains(";OK"), vector.name + response)
            let image = try XCTUnwrap(driver.snapshot(topRow: 0).imageSnapshot.images[7], vector.name)
            XCTAssertEqual(image.width, vector.width, vector.name)
            XCTAssertEqual(image.height, vector.height, vector.name)
            XCTAssertEqual(image.rgba, vector.rgba, vector.name)
            let placement = try XCTUnwrap(driver.snapshot(topRow: 0).imageSnapshot.placements.first)
            XCTAssertEqual(placement.pixelWidth, 16, "pre-layout metrics must match the 8x16 size callback")
            XCTAssertEqual(placement.pixelHeight, 32)
            driver.reset()
            XCTAssertEqual(image.rgba, vector.rgba, "owned bytes survive reset")
        }
    }

    func testChunkedPNGOnlyAppearsWhenCompleteAndReplacesGeneration() throws {
        let driver = try GhosttyVTDriver(columns: 12, rows: 6)
        let first = NativePNGFixtures.vectors[0], second = NativePNGFixtures.vectors[1]
        driver.feed("\u{1b}_Ga=T,f=100,i=7,p=3,c=2,r=2;\(first.encoded)\u{1b}\\")
        let old = try XCTUnwrap(driver.snapshot(topRow: 0).imageSnapshot.images[7])
        let cut = second.encoded.index(second.encoded.startIndex, offsetBy: 32)
        driver.feed("\u{1b}[H\u{1b}_Ga=T,f=100,i=7,p=3,c=2,r=2,m=1;\(second.encoded[..<cut])\u{1b}\\")
        // Pinned VT retires the old same-ID image at transmission start,
        // independently confirmed by the raw-image C probe. Do not retain a
        // stale adapter texture or claim atomic replacement it cannot provide.
        XCTAssertNil(try driver.snapshot(topRow: 0).imageSnapshot.images[7])
        XCTAssertEqual(old.rgba, first.rgba)
        driver.feed("\u{1b}_Gm=0;\(second.encoded[cut...])\u{1b}\\")
        let new = try XCTUnwrap(driver.snapshot(topRow: 0).imageSnapshot.images[7])
        XCTAssertNotEqual(old.generation, new.generation)
        XCTAssertEqual(new.rgba, second.rgba)
        XCTAssertEqual(old.rgba, first.rgba)
    }

    func testAllocatorRefusalIsHonoredWithoutPublishingOutput() throws {
        let probe = PNGAllocatorProbe(); probe.refuse = true
        let data = try XCTUnwrap(Data(base64Encoded: NativePNGFixtures.vectors[0].encoded))
        let (ok, image, bytes) = decoded(data, probe: probe)
        XCTAssertFalse(ok); XCTAssertEqual(image.width, 0); XCTAssertEqual(image.data_len, 0)
        XCTAssertTrue(bytes.isEmpty); XCTAssertEqual(probe.allocations, [16]); XCTAssertTrue(probe.frees.isEmpty)
    }

    func testMalformedPixelDecodeReleasesTheExactSuppliedAllocation() {
        let probe = PNGAllocatorProbe()
        let (ok, image, bytes) = decoded(NativePNGFixtures.badDeflate, probe: probe)
        XCTAssertFalse(ok); XCTAssertEqual(image.data_len, 0); XCTAssertTrue(bytes.isEmpty)
        XCTAssertEqual(probe.allocations, [4])
        XCTAssertEqual(probe.frees, [4]); XCTAssertTrue(probe.live.isEmpty)
    }

    func testTruncatedAndNonPNGDataNeverPublishAnImage() throws {
        let valid = try XCTUnwrap(Data(base64Encoded: NativePNGFixtures.vectors[0].encoded))
        for data in [Data(), Data("not PNG".utf8), Data([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0]),
                     Data(valid.prefix(8)), Data(valid.prefix(32)), Data(valid.dropLast(12))] {
            let (ok, image, bytes) = decoded(data)
            XCTAssertFalse(ok, "truncated/non-PNG \(data.count) bytes")
            XCTAssertEqual(image.data_len, 0); XCTAssertTrue(bytes.isEmpty)
        }
    }

    func testDimensionExpandedByteAndEncodedByteLimitsPrecedePixelAllocation() {
        var tooLong = Data(repeating: 0, count: NativePNGDecoder.maximumEncodedBytes + 1)
        tooLong.replaceSubrange(0..<8, with: [137,80,78,71,13,10,26,10])
        for data in [NativePNGFixtures.tooWide, NativePNGFixtures.tooManyPixels, tooLong] {
            let probe = PNGAllocatorProbe()
            XCTAssertFalse(decoded(data, probe: probe).0)
            XCTAssertTrue(probe.allocations.isEmpty)
        }
    }

    func testAnimatedPNGIsExplicitlyRejectedInsteadOfClaimingPlayback() {
        let probe = PNGAllocatorProbe()
        XCTAssertFalse(decoded(NativePNGFixtures.animated, probe: probe).0)
        XCTAssertTrue(probe.allocations.isEmpty)
    }

    func testPNGInvalidInputFollowsVTRetirementAndDoesNotStopParsing() throws {
        let driver = try GhosttyVTDriver(columns: 80, rows: 6)
        let vector = NativePNGFixtures.vectors[0]
        driver.feed("\u{1b}_Ga=T,f=100,i=7,p=3,c=2,r=2;\(vector.encoded)\u{1b}\\")
        let old = try XCTUnwrap(driver.snapshot(topRow: 0).imageSnapshot.images[7])
        let reply = String(decoding: driver.feed("\u{1b}_Ga=T,f=100,i=7;\(NativePNGFixtures.badDeflate.base64EncodedString())\u{1b}\\still-parsing"), as: UTF8.self)
        XCTAssertFalse(reply.contains(";OK")); XCTAssertFalse(reply.isEmpty)
        let frame = try driver.snapshot(topRow: 0)
        XCTAssertNil(frame.imageSnapshot.images[7], "VT retires same-ID storage before validating replacement")
        XCTAssertEqual(old.rgba, vector.rgba, "previous owned pixels stay valid, not displayed as new content")
        XCTAssertTrue(frame.rows.values.contains { $0.cells.compactMap(\.text).joined().contains("still-parsing") })
    }

    func testNilArgumentsAndNegativeLengthFailSafely() {
        var image = GhosttySysImage()
        XCTAssertFalse(NativePNGDecoder.decode(allocator: nil, data: nil, count: 8, output: &image))
        let data = Data([137,80,78,71,13,10,26,10])
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self).baseAddress
            XCTAssertFalse(NativePNGDecoder.decode(allocator: nil, data: p, count: -1, output: &image))
            XCTAssertFalse(NativePNGDecoder.decode(allocator: nil, data: p, count: 8, output: nil))
        }
    }

    func testConcurrentDriversDecodeOnBackgroundQueuesWithIdempotentSystemSetup() {
        let errors = PNGErrors()
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            do {
                try GhosttyVTSystem.prepare()
                let vector = NativePNGFixtures.vectors[index % NativePNGFixtures.vectors.count]
                let driver = try GhosttyVTDriver(columns: 12, rows: 6)
                driver.feed("\u{1b}_Ga=T,f=100,i=7,p=3,c=2,r=2;\(vector.encoded)\u{1b}\\")
                if try driver.snapshot(topRow: 0).imageSnapshot.images[7]?.rgba != vector.rgba {
                    errors.append(vector.name)
                }
            } catch { errors.append(String(describing: error)) }
        }
        XCTAssertEqual(errors.values, [])
    }
}

private final class PNGErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ error: String) { lock.withLock { stored.append(error) } }
    var values: [String] { lock.withLock { stored } }
}

/// A private test allocator, never substituted for any running terminal's
/// allocator or process-global callbacks. Checks both allocation and release.
private final class PNGAllocatorProbe {
    var refuse = false
    var allocations: [Int] = [], frees: [Int] = []
    var live: [UInt: Int] = [:]
    func withAllocator<T>(_ body: (UnsafePointer<GhosttyAllocator>) -> T) -> T {
        var table = GhosttyAllocatorVtable()
        table.alloc = { context, count, _, _ in
            let probe = Unmanaged<PNGAllocatorProbe>.fromOpaque(context!).takeUnretainedValue()
            probe.allocations.append(count)
            guard !probe.refuse, let pointer = malloc(count) else { return nil }
            probe.live[UInt(bitPattern: pointer)] = count
            return pointer
        }
        table.free = { context, pointer, count, _, _ in
            let probe = Unmanaged<PNGAllocatorProbe>.fromOpaque(context!).takeUnretainedValue()
            probe.frees.append(count)
            XCTAssertEqual(probe.live.removeValue(forKey: UInt(bitPattern: pointer)), count)
            Darwin.free(pointer)
        }
        return withUnsafePointer(to: &table) { table in
            var allocator = GhosttyAllocator(ctx: Unmanaged.passUnretained(self).toOpaque(), vtable: table)
            return withUnsafePointer(to: &allocator, body)
        }
    }
}
