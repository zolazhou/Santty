import Foundation
import XCTest
@testable import Santty

/// Fixed Kitty wire vectors through the pinned precompiled VT, not a second
/// parser or expected values made by the tested API. No user terminal/files.
final class NativeImageSnapshotTests: XCTestCase {
    private let red = "\u{1b}_Ga=T,f=24,s=1,v=1,i=7,p=3,c=2,r=2,C=1;/wAA\u{1b}\\"
    private func make(limits: NativeImageSnapshotLimits = .init()) throws -> GhosttyVTDriver {
        let driver = try GhosttyVTDriver(columns: 12, rows: 6, imageLimits: limits)
        try driver.resize(columns: 12, rows: 6, cellWidth: 8, cellHeight: 16)
        return driver
    }
    private func frame(_ driver: GhosttyVTDriver, top: Int = 0) throws -> NativeImageSnapshot {
        try driver.snapshot(topRow: top).imageSnapshot
    }

    func testRawRGBPixelsAndResolvedGeometryAreAvailableAtRuntime() throws {
        let driver = try make()
        driver.feed("\u{1b}[2;3H")
        let reply = String(decoding: driver.feed(red), as: UTF8.self)
        XCTAssertTrue(reply.contains("i=7") && reply.contains(";OK"), reply)
        let snapshot = try frame(driver), image = try XCTUnwrap(snapshot.images[7])
        XCTAssertEqual(image.rgba, [255, 0, 0, 255])
        XCTAssertEqual(image.width, 1); XCTAssertEqual(image.height, 1)
        XCTAssertNotEqual(image.generation, 0)
        XCTAssertFalse(snapshot.limited)
        let placement = try XCTUnwrap(snapshot.placements.first)
        XCTAssertEqual(snapshot.placements.count, 1)
        XCTAssertEqual(placement.placementID, 3)
        XCTAssertEqual(placement.kind, .fixed)
        XCTAssertEqual(placement.layer, .aboveText)
        XCTAssertEqual(placement.column, 2); XCTAssertEqual(placement.row, 1)
        XCTAssertEqual(placement.columns, 2); XCTAssertEqual(placement.rows, 2)
        XCTAssertEqual(placement.pixelWidth, 16); XCTAssertEqual(placement.pixelHeight, 32)
        XCTAssertEqual(placement.sourceWidth, 1); XCTAssertEqual(placement.sourceHeight, 1)
    }

    func testRGBAAndSourceCropOffsetsRemainDistinctFromDestinationPixels() throws {
        let driver = try make()
        // 2x2: red, green / blue, white. Base64 fixed using Python stdlib.
        driver.feed("\u{1b}_Ga=T,f=32,s=2,v=2,i=7,p=3,x=1,y=0,w=1,h=2,X=1,Y=2,c=2,r=2,C=1;/wAA/wD/AP8AAP///////w==\u{1b}\\")
        let snapshot = try frame(driver)
        XCTAssertEqual(snapshot.images[7]?.rgba, [255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255])
        let placement = try XCTUnwrap(snapshot.placements.first)
        XCTAssertEqual(placement.sourceX, 1); XCTAssertEqual(placement.sourceY, 0)
        XCTAssertEqual(placement.sourceWidth, 1); XCTAssertEqual(placement.sourceHeight, 2)
        XCTAssertEqual(placement.offsetX, 1); XCTAssertEqual(placement.offsetY, 2)
        XCTAssertGreaterThan(placement.pixelWidth, 0); XCTAssertGreaterThan(placement.pixelHeight, 0)
    }

    func testCacheUsesContentGenerationAndOwnedPixelsSurviveReplacementResetAndFree() throws {
        var old: NativeTerminalImage?
        do {
            let driver = try make()
            driver.feed(red)
            let first = try frame(driver), again = try frame(driver)
            old = try XCTUnwrap(first.images[7])
            XCTAssertTrue(old === again.images[7], "unchanged captured images must share owned pixels")
            XCTAssertEqual(first.revision, again.revision)
            driver.feed("\u{1b}_Ga=T,f=24,s=1,v=1,i=7,p=3,c=2,r=2,C=1;AP8A\u{1b}\\")
            let changed = try frame(driver), green = try XCTUnwrap(changed.images[7])
            XCTAssertNotEqual(green.generation, old?.generation)
            XCTAssertNotEqual(changed.revision, first.revision)
            XCTAssertEqual(green.rgba, [0,255,0,255])
            XCTAssertEqual(old?.rgba, [255,0,0,255])
            driver.reset()
            XCTAssertTrue(try frame(driver).images.isEmpty)
        }
        XCTAssertEqual(old?.rgba, [255,0,0,255], "no C pointer can be retained in the frame")
    }

    func testStraightAlphaAndGeometryOnlyResizePreserveOwnedImageIdentity() throws {
        let driver = try make()
        driver.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=7,p=3,c=2,r=2,C=1;/wAAgA==\u{1b}\\")
        let before = try frame(driver), image = try XCTUnwrap(before.images[7])
        XCTAssertEqual(image.rgba, [255,0,0,128], "pixels are straight alpha, not premultiplied")
        try driver.resize(columns: 12, rows: 6, cellWidth: 12, cellHeight: 20)
        let after = try frame(driver), placement = try XCTUnwrap(after.placements.first)
        XCTAssertTrue(after.images[7] === image)
        XCTAssertEqual(placement.pixelWidth, 24); XCTAssertEqual(placement.pixelHeight, 40)
        XCTAssertNotEqual(before.placementGeneration, after.placementGeneration)
        XCTAssertNotEqual(before.revision, after.revision)
    }

    func testChunkCompletionDoesNotNegativeCacheMissingPixels() throws {
        let driver = try make()
        driver.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=7,p=3,C=1,m=1;/wAA\u{1b}\\")
        XCTAssertTrue(try frame(driver).placements.isEmpty)
        driver.feed("\u{1b}_Gm=0;/w==\u{1b}\\")
        XCTAssertEqual(try frame(driver).images[7]?.rgba, [255,0,0,255])
    }

    func testCompressionIsHandledByVTNotTheConsumer() throws {
        let driver = try make()
        // Python zlib.compress([255,0,0]); adapter only sees decoded pixels.
        driver.feed("\u{1b}_Ga=T,f=24,o=z,s=1,v=1,i=7,p=3,C=1;eJz7z8AAAAMAAQA=\u{1b}\\")
        XCTAssertEqual(try frame(driver).images[7]?.rgba, [255,0,0,255])
    }

    func testDeleteAndAlternateScreensKeepIdentityIsolated() throws {
        let driver = try make()
        driver.feed(red)
        let old = try XCTUnwrap(frame(driver).images[7])
        driver.feed("\u{1b}[?1049h")
        XCTAssertTrue(try frame(driver).images.isEmpty)
        driver.feed("\u{1b}_Ga=T,f=24,s=1,v=1,i=7,p=3,C=1;AP8A\u{1b}\\")
        let alt = try XCTUnwrap(frame(driver).images[7])
        XCTAssertNotEqual(old.generation, alt.generation)
        driver.feed("\u{1b}[?1049l")
        XCTAssertEqual(try frame(driver).images[7]?.generation, old.generation)
        driver.feed("\u{1b}_Ga=d,d=I,i=7\u{1b}\\")
        XCTAssertTrue(try frame(driver).images.isEmpty)
        XCTAssertTrue(try frame(driver).placements.isEmpty)
    }

    func testHistoryCaptureReportsAbsoluteRowsAndKeepsOnlyCapturedImages() throws {
        let driver = try make()
        driver.feed(red)
        driver.feed("\u{1b}[6;1H" + String(repeating: "\r\n", count: 20))
        let liveTop = try driver.totalRows - driver.rows
        XCTAssertTrue(try frame(driver, top: liveTop).images.isEmpty)
        let history = try frame(driver)
        XCTAssertEqual(history.placements.first?.row, 0)
        XCTAssertEqual(history.images[7]?.rgba, [255,0,0,255])
        XCTAssertTrue(try frame(driver, top: liveTop).images.isEmpty)
    }

    func testLayersAndVirtualPlaceholdersAreResolvedByVT() throws {
        let driver = try make()
        try driver.resize(columns: 12, rows: 6, cellWidth: 8, cellHeight: 8)
        driver.feed("\u{1b}_Ga=T,U=1,f=24,i=7,s=4,v=4,c=4,r=4,q=2;" + String(repeating: "/wAA", count: 16) + "\u{1b}\\\u{1b}[38;2;0;0;7m\u{10eeee}\u{305}\u{305}")
        let first = try frame(driver)
        let virtual = try XCTUnwrap(first.placements.first)
        XCTAssertEqual(try frame(driver).placements, first.placements, "consuming dirty flags must not lose virtual metadata")
        XCTAssertEqual(virtual.kind, .virtual)
        XCTAssertEqual(virtual.layer, .belowText); XCTAssertEqual(virtual.z, -1)
        driver.feed("\u{1b}[H\u{1b}_Ga=T,f=24,s=1,v=1,i=8,z=-1073741825,C=1;/wAA\u{1b}\\")
        driver.feed("\u{1b}[H\u{1b}_Ga=T,f=24,s=1,v=1,i=9,z=1,C=1;/wAA\u{1b}\\")
        XCTAssertEqual(try frame(driver).placements.map(\.layer), [.belowBackground, .belowText, .aboveText])
    }

    func testPinnedCoreZeroSourceExtentIsReportedAsLimitedNotInventedByTheAdapter() throws {
        // The independent C probe reports a placement with 0x0 source crop
        // for this enlarged first slice, not an absent stored image. Keep the
        // original vector; don't invent a second placeholder/crop resolver.
        let driver = try make()
        try driver.resize(columns: 12, rows: 6, cellWidth: 8, cellHeight: 8)
        driver.feed("\u{1b}_Ga=T,U=1,f=24,i=7,s=1,v=1,c=4,r=4,q=2;/wAA\u{1b}\\\u{1b}[38;5;7m\u{10eeee}\u{305}\u{305}")
        let missing = try frame(driver)
        XCTAssertGreaterThan(missing.storageGeneration, 0)
        XCTAssertTrue(missing.limited)
        XCTAssertEqual(missing.images[7]?.rgba, [255,0,0,255])
        XCTAssertTrue(missing.placements.isEmpty, "revisit the limitation if VT supplies a drawable source crop")
    }

    func testRelativePlacementCoordinatesAreAlreadyResolvedByVT() throws {
        let driver = try make()
        driver.feed("\u{1b}[2;3H" + red)
        driver.feed("\u{1b}_Ga=T,f=24,s=1,v=1,i=8,p=4,P=7,Q=3,H=1,V=1,C=1;AP8A\u{1b}\\")
        let relative = try XCTUnwrap(frame(driver).placements.first { $0.imageID == 8 })
        XCTAssertEqual(relative.kind, .relative)
        XCTAssertEqual(relative.column, 3); XCTAssertEqual(relative.row, 2)
    }

    func testSynchronizedHoldKeepsOwnedImagesWhileParsingAndRepliesContinue() throws {
        let driver = try make()
        driver.feed(red)
        let old = try XCTUnwrap(frame(driver).images[7])
        let replies = driver.feed("\u{1b}[?2026h\u{1b}_Ga=T,f=24,s=1,v=1,i=7,p=3,C=1;AP8A\u{1b}\\")
        XCTAssertTrue(String(decoding: replies, as: UTF8.self).contains(";OK"))
        XCTAssertTrue(try frame(driver).images[7] === old)
        driver.feed("\u{1b}[?2026l")
        XCTAssertEqual(try frame(driver).images[7]?.rgba, [0,255,0,255])
        XCTAssertEqual(old.rgba, [255,0,0,255])
    }

    func testSnapshotBudgetsAreObservableWithoutChangingProtocolAcceptance() throws {
        let driver = try make(limits: .init(bytes: 3, placements: 1024))
        XCTAssertTrue(String(decoding: driver.feed(red), as: UTF8.self).contains(";OK"))
        let limited = try frame(driver)
        XCTAssertTrue(limited.limited)
        XCTAssertTrue(limited.images.isEmpty)
        let placements = try make(limits: .init(bytes: 1024, placements: 1))
        placements.feed(red)
        placements.feed("\u{1b}_Ga=p,i=7,p=4,c=2,r=2,C=1\u{1b}\\")
        let capped = try frame(placements)
        XCTAssertTrue(capped.limited)
        XCTAssertEqual(capped.placements.count, 1)
    }

    func testNonDirectMediaCannotReadOrUnlinkAnOwnedSentinel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("santty-image-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tty-graphics-protocol-\(UUID())")
        try Data([255,0,0]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let encoded = Data(file.path.utf8).base64EncodedString()
        for medium in ["f", "t", "s"] {
            let driver = try make()
            let reply = String(decoding: driver.feed("\u{1b}_Ga=T,t=\(medium),f=24,s=1,v=1,i=7;\(encoded)\u{1b}\\"), as: UTF8.self)
            XCTAssertFalse(reply.contains(";OK"), medium)
            XCTAssertFalse(reply.isEmpty, "VT must reject, not silently advertise a usable transport")
            XCTAssertTrue(try frame(driver).images.isEmpty)
            XCTAssertEqual(try Data(contentsOf: file), Data([255,0,0]))
        }
    }

    func testStartupPNGDecoderAcceptsTheIndependentHerdrRedFixture() throws {
        let driver = try make()
        // herdr-app's independent 1x1 red PNG fixture, not a local file.
        let reply = String(decoding: driver.feed("\u{1b}_Ga=T,f=100,i=7,q=0;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\u{1b}\\"), as: UTF8.self)
        XCTAssertFalse(reply.isEmpty)
        XCTAssertTrue(reply.contains(";OK"), reply)
        XCTAssertEqual(try frame(driver).images[7]?.rgba, [255, 0, 0, 255])
    }
}
