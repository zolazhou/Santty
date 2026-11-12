import AppKit
import Metal
@testable import SwiftTerm
import XCTest
@testable import SanttyTerminalLab

@MainActor
final class NativeImageRenderingTests: XCTestCase {
    func testCoreGraphicsPaintsPNGTransportPixels() throws { try png(.coreGraphics) }
    func testMetalPaintsPNGTransportPixels() throws { try png(.metal) }

    private func png(_ backend: ImageRaster.Backend) throws {
        let raster = try ImageRaster(backend)
        raster.driver.feed("\u{1b}[?25l\u{1b}_Ga=T,f=100,i=7,p=3,c=4,r=4,C=1;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\u{1b}\\")
        let frame = try raster.apply(), placement = try XCTUnwrap(frame.imageSnapshot.placements.first)
        let pixels = try raster.pixels(), rect = raster.pixelRect(placement, in: pixels, top: frame.topRow)
        assertColor(pixels.sample(rect, x: 0.5, y: 0.5), .red)
        let vector = NativePNGFixtures.vectors[0]
        raster.driver.feed("\u{1b}[H\u{1b}_Ga=T,f=100,i=7,p=3,c=4,r=4,C=1;\(vector.encoded)\u{1b}\\")
        let next = try raster.apply(), p = try XCTUnwrap(next.imageSnapshot.placements.first)
        let rgba = try raster.pixels(), r = raster.pixelRect(p, in: rgba, top: next.topRow)
        assertColor(rgba.sample(r, x: 0.25, y: 0.25), .red)
        assertColor(rgba.sample(r, x: 0.75, y: 0.25), .green)
        assertColor(rgba.sample(r, x: 0.25, y: 0.75), .blue)
        assertColor(rgba.sample(r, x: 0.75, y: 0.75), .white)
        // PNG low/zero alpha must compose exactly like decoded RGBA input.
        let alpha = NativePNGFixtures.vectors[1]
        raster.driver.feed("\u{1b}[H\u{1b}_Ga=d,d=I,i=7,q=2\u{1b}\\\u{1b}_Ga=T,f=24,s=1,v=1,i=8,p=1,z=-1,c=4,r=4,C=1;AAD/\u{1b}\\\u{1b}_Ga=T,f=100,i=7,p=3,z=1,c=4,r=4,C=1;\(alpha.encoded)\u{1b}\\")
        try raster.apply()
        let blended = try raster.pixels()
        assertColor(blended.sample(r, x: 0.25, y: 0.25), .blue)
        assertColor(blended.sample(r, x: 0.75, y: 0.25), .blue)
        assertColor(blended.sample(r, x: 0.25, y: 0.75), .blue)
        assertColor(blended.sample(r, x: 0.75, y: 0.75), .red)
    }

    func testCoreGraphicsPaintsOwnedVTImageAtItsExactPixelSize() throws { try exactSize(.coreGraphics) }
    func testMetalPaintsOwnedVTImageAtItsExactPixelSize() throws { try exactSize(.metal) }

    func testCoreGraphicsImageOrientationCropAndAlpha() throws { try cropAndAlpha(.coreGraphics) }
    func testMetalImageOrientationCropAndAlpha() throws { try cropAndAlpha(.metal) }
    func testCoreGraphicsThreeImageLayers() throws { try layers(.coreGraphics) }
    func testMetalThreeImageLayers() throws { try layers(.metal) }
    func testCoreGraphicsImageOnlyReplacementDeleteAndCacheEviction() throws { try lifetime(.coreGraphics) }
    func testMetalImageOnlyReplacementDeleteAndCacheEviction() throws { try lifetime(.metal) }
    func testCoreGraphicsHistoryAndNegativeOriginClipping() throws { try history(.coreGraphics) }
    func testMetalHistoryAndNegativeOriginClipping() throws { try history(.metal) }
    func testCoreGraphicsResolvedVirtualSliceDoesNotDrawPlaceholderText() throws { try virtual(.coreGraphics) }
    func testMetalResolvedVirtualSliceDoesNotDrawPlaceholderText() throws { try virtual(.metal) }

    func testCoreGraphicsKeepsDegenerateVirtualCropLimitedAndSuppressesItsGlyph() throws { try degenerate(.coreGraphics) }
    func testMetalKeepsDegenerateVirtualCropLimitedAndSuppressesItsGlyph() throws { try degenerate(.metal) }

    func testNativeScrollFractionKeepsImageFrameBoundedAndDoesNotStealFocus() throws {
        let view = NativeTerminalScrollView(driver: try GhosttyVTDriver(), frame: CGRect(x: 0, y: 0, width: 640, height: 245))
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        view.feed("\u{1b}[?25l\u{1b}_Ga=T,f=24,s=1,v=1,i=7,p=3,c=4,r=4,C=1;/wAA\u{1b}\\\u{1b}[999;1H" + String(repeating: "\r\n", count: 100))
        let h = view.renderer.cellSize.height
        view.contentView.scroll(to: CGPoint(x: 0, y: 2.25 * h))
        let image = try XCTUnwrap(view.presentedFrame?.imageSnapshot.images[7])
        let conversions = view.source.convertedRows, responder = window.firstResponder
        view.source.withFrame { frame, _, _ in
            XCTAssertEqual(frame.kitty?.placements.first?.geometry.row, -2)
        }
        view.contentView.scroll(to: CGPoint(x: 0, y: 2.75 * h))
        XCTAssertTrue(view.presentedFrame?.imageSnapshot.images[7] === image)
        XCTAssertEqual(view.source.convertedRows, conversions)
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertLessThanOrEqual(view.renderer.frame.height, view.contentSize.height + 3 * h)
    }

    func testPresentationResetClearsPicturesEvenDuringAHeldReconnectRestore() throws {
        let view = NativeTerminalScrollView(driver: try GhosttyVTDriver(), frame: CGRect(x: 0, y: 0, width: 640, height: 245))
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        view.feed("\u{1b}[?25l\u{1b}_Ga=T,f=24,s=1,v=1,i=7,p=3,c=4,r=4,C=1;/wAA\u{1b}\\")
        view.source.withFrame { frame, _, _ in XCTAssertFalse(frame.kitty?.placements.isEmpty ?? true) }
        view.driver.reset()
        view.driver.feed("\u{1b}[?2026hrestoring")
        view.parsedOutput(reset: true)
        view.renderer.presentExternalFrame() // a queued frame tick while output is held
        view.source.withFrame { frame, _, _ in
            XCTAssertNil(frame.kitty)
            XCTAssertEqual(frame.rows, 0)
        }
        XCTAssertNil(view.presentedFrame)
        view.driver.feed("\u{1b}[?2026l")
        view.refresh()
        view.source.withFrame { frame, _, _ in XCTAssertNil(frame.kitty) }
    }

    private func degenerate(_ backend: ImageRaster.Backend) throws {
        let raster = try ImageRaster(backend)
        raster.driver.feed("\u{1b}[?25l\u{1b}_Ga=T,U=1,f=24,s=1,v=1,i=7,c=4,r=4,q=2;/wAA\u{1b}\\\u{1b}[38;5;7;4;53m\u{10eeee}\u{305}\u{305}")
        let frame = try raster.apply()
        XCTAssertTrue(frame.imageSnapshot.limited)
        raster.source.withFrame { frame, _, _ in XCTAssertNil(frame.kitty) }
        XCTAssertNil(try raster.pixels().bounds { max($0[0], $0[1], $0[2]) > 30 && $0[3] > 180 })
    }

    func testResolvedGeometryVectorsAtOneAndTwoTimesScaleKeepLegacyDefault() {
        func placement(_ size: KittyGraphicsPixelSize?) -> KittyGraphicsRenderPlacement {
            .init(token: 1, placementId: 0, imageId: 7, visibleSource: .init(x: 0, y: 0, width: 2, height: 2),
                geometry: .init(column: -1, row: -2, columns: 3, rows: 4), pixelOffsetX: 3, pixelOffsetY: 5,
                zIndex: 0, isVirtual: false, insertionOrder: 0, resolvedSize: size)
        }
        let p = placement(.init(width: 13, height: 29))
        XCTAssertEqual(p.destinationRect(cellWidth: 7.5, cellHeight: 12.5, imageScale: 1, screenRow: 0,
            lineOrigin: CGPoint(x: 0, y: 25)), CGRect(x: -4.5, y: 28.5, width: 13, height: 29))
        XCTAssertEqual(p.destinationRect(cellWidth: 7.5, cellHeight: 12.5, imageScale: 2, screenRow: 0,
            lineOrigin: CGPoint(x: 0, y: 25)), CGRect(x: -6, y: 45.5, width: 6.5, height: 14.5))
        XCTAssertEqual(placement(nil).destinationRect(cellWidth: 7.5, cellHeight: 12.5, imageScale: 1,
            screenRow: 0, lineOrigin: CGPoint(x: 0, y: 25)), CGRect(x: -4.5, y: 17.5, width: 19.5, height: 45))
    }

    func testMetalCropClampMatchesAcrossPersistentAndAggregatedBuffers() throws {
        let raster = try ImageRaster(.metal)
        raster.driver.feed("\u{1b}[?25l\u{1b}_Ga=T,f=32,s=2,v=2,i=7,p=3,x=1,w=1,h=2,c=4,r=4,C=1;/wAA/wD/AP8AAP///////w==\u{1b}\\")
        raster.view.metalBufferingMode = .perRowPersistent
        let frame = try raster.apply(), p = try XCTUnwrap(frame.imageSnapshot.placements.first)
        let persistent = try raster.pixels(), rect = raster.pixelRect(p, in: persistent, top: frame.topRow)
        assertColor(persistent.color(Int(rect.minX) + 2, Int(rect.minY + rect.height / 4)), .green)
        raster.view.metalBufferingMode = .perFrameAggregated
        try raster.apply()
        XCTAssertTrue(try raster.pixels().bytes == persistent.bytes)
    }

    func testResolvedCoreGraphicsCropsShareOneBoundedFullImageCache() throws {
        let raster = try ImageRaster(.coreGraphics)
        raster.driver.feed("\u{1b}[?25l\u{1b}_Ga=T,f=32,s=2,v=2,i=7,p=1,c=4,r=2,C=1;/wAA/wD/AP8AAP///////w==\u{1b}\\")
        for p in 2...60 { raster.driver.feed("\u{1b}_Ga=p,i=7,p=\(p),x=\(p % 2),y=\(p % 2),w=1,h=1,c=2,r=2,C=1\u{1b}\\") }
        try raster.apply(); _ = try raster.pixels()
        XCTAssertEqual(raster.cacheCount, 1, "do not retain a near-full bitmap copy for every cropped placement")
    }

    private func cropAndAlpha(_ backend: ImageRaster.Backend) throws {
        let raster = try ImageRaster(backend)
        raster.driver.feed("\u{1b}[?25l\u{1b}_Ga=T,f=32,s=2,v=2,i=7,p=3,c=6,r=4,C=1;/wAA/wD/AP8AAP///////w==\u{1b}\\")
        let frame = try raster.apply(), p = try XCTUnwrap(frame.imageSnapshot.placements.first)
        let pixels = try raster.pixels(), rect = raster.pixelRect(p, in: pixels, top: frame.topRow)
        assertColor(pixels.sample(rect, x: 0.25, y: 0.25), .red)
        assertColor(pixels.sample(rect, x: 0.75, y: 0.25), .green)
        assertColor(pixels.sample(rect, x: 0.25, y: 0.75), .blue)
        assertColor(pixels.sample(rect, x: 0.75, y: 0.75), .white)
        raster.driver.feed("\u{1b}[H\u{1b}_Ga=p,i=7,p=3,x=1,y=0,w=1,h=2,c=4,r=4,C=1\u{1b}\\")
        let cropFrame = try raster.apply(), crop = try XCTUnwrap(cropFrame.imageSnapshot.placements.first)
        let cropped = try raster.pixels(), cropRect = raster.pixelRect(crop, in: cropped, top: cropFrame.topRow)
        assertColor(cropped.color(Int(cropRect.minX) + 2, Int(cropRect.minY + cropRect.height / 4)), .green)
        assertColor(cropped.sample(cropRect, x: 0.5, y: 0.75), .white)
        for row in 0...1 {
            raster.driver.feed("\u{1b}[H\u{1b}_Ga=p,i=7,p=3,x=0,y=\(row),w=2,h=1,c=4,r=2,C=1\u{1b}\\")
            let f = try raster.apply(), p = try XCTUnwrap(f.imageSnapshot.placements.first)
            let image = try raster.pixels(), r = raster.pixelRect(p, in: image, top: f.topRow)
            assertColor(image.sample(r, x: 0.25, y: 0.5), row == 0 ? .red : .blue)
            assertColor(image.sample(r, x: 0.75, y: 0.5), row == 0 ? .green : .white)
        }
        // Opaque blue background image, then half-red / fully transparent green.
        raster.driver.reset()
        raster.driver.feed("\u{1b}[?25l\u{1b}_Ga=T,f=24,s=1,v=1,i=8,p=1,z=-1,c=4,r=2,C=1;AAD/\u{1b}\\")
        let back = try raster.apply(), bp = try XCTUnwrap(back.imageSnapshot.placements.first)
        let blue = try raster.pixels(), br = raster.pixelRect(bp, in: blue, top: back.topRow)
        raster.driver.feed("\u{1b}[H\u{1b}_Ga=T,f=32,s=2,v=1,i=7,p=3,z=1,c=4,r=2,C=1;/wAAgAD/AAA=\u{1b}\\")
        try raster.apply()
        let blended = try raster.pixels(), half = blended.sample(br, x: 0.25, y: 0.5)
        XCTAssertTrue(half[0] > 60 && half[0] < 220 && half[2] > 60 && half[2] < 220 && half[1] < 60)
        let transparent = blended.sample(br, x: 0.75, y: 0.5), unchanged = blue.sample(br, x: 0.75, y: 0.5)
        XCTAssertTrue(zip(transparent, unchanged).allSatisfy { abs(Int($0) - Int($1)) <= 2 }, "transparent source must leave the background intact")
    }

    private func layers(_ backend: ImageRaster.Backend) throws {
        let raster = try ImageRaster(backend)
        // Declare the palette fixture rather than assuming the VT theme's
        // ANSI green/blue are saturated RGB primaries.
        raster.driver.feed("\u{1b}]4;2;rgb:00/ff/00\u{7}\u{1b}]4;4;rgb:00/00/ff\u{7}\u{1b}[?25l\u{1b}[32;44mH   \u{1b}[0m\u{1b}[H\u{1b}_Ga=T,f=24,s=1,v=1,i=7,p=3,z=-1073741825,c=4,r=2,C=1;/wAA\u{1b}\\")
        try raster.apply()
        var pixels = try raster.pixels()
        let scale = CGFloat(pixels.width) / raster.view.bounds.width
        let x = Int(raster.view.cellSize.width * 2.5 * scale), y = Int(raster.view.cellSize.height * scale / 2)
        assertColor(pixels.color(x, y), .blue)
        raster.driver.feed("\u{1b}[H\u{1b}_Ga=p,i=7,p=3,z=-1,c=4,r=2,C=1\u{1b}\\")
        let layerFrame = try raster.apply(); pixels = try raster.pixels()
        XCTAssertEqual(layerFrame.palette[2], NativeRGB(red: 0, green: 255, blue: 0))
        assertColor(pixels.color(x, y), .red)
        XCTAssertNotNil(pixels.bounds { isColor($0, .green) }, "below-text image must not cover the glyph")
        raster.driver.feed("\u{1b}[H\u{1b}_Ga=p,i=7,p=3,z=1,c=4,r=2,C=1\u{1b}\\")
        try raster.apply(); pixels = try raster.pixels()
        XCTAssertNil(pixels.bounds { isColor($0, .green) }, "above-text image must cover the glyph")
    }

    private func lifetime(_ backend: ImageRaster.Backend) throws {
        let raster = try ImageRaster(backend)
        raster.driver.feed("\u{1b}[?25l\u{1b}_Ga=T,f=24,s=1,v=1,i=7,p=3,c=3,r=2,C=1;/wAA\u{1b}\\")
        try raster.apply(); XCTAssertNotNil(try raster.pixels().bounds { isColor($0, .red) })
        let conversions = raster.source.convertedRows
        raster.driver.feed("\u{1b}_Ga=T,f=24,s=1,v=1,i=7,p=3,c=3,r=2,C=1;AP8A\u{1b}\\")
        try raster.apply(); XCTAssertNotNil(try raster.pixels().bounds { isColor($0, .green) })
        XCTAssertEqual(raster.source.convertedRows, conversions, "image-only changes should not rebuild text")
        XCTAssertEqual(raster.cacheCount, 1)
        raster.driver.feed("\u{1b}_Ga=d,d=I,i=7\u{1b}\\")
        try raster.apply(); XCTAssertNil(try raster.pixels().bounds { isColor($0, .green) })
        XCTAssertEqual(raster.cacheCount, 0)
        raster.driver.feed("\u{1b}_Ga=T,f=24,s=1,v=1,i=7,p=3,C=1;/wAA\u{1b}\\\u{1b}[?1049h\u{1b}[?25l")
        try raster.apply(); XCTAssertNil(try raster.pixels().bounds { isColor($0, .red) })
        raster.driver.feed("\u{1b}[?1049l\u{1b}[?25l")
        try raster.apply(); XCTAssertNotNil(try raster.pixels().bounds { isColor($0, .red) })
        raster.driver.reset(); raster.driver.feed("\u{1b}[?25l")
        try raster.apply(); XCTAssertNil(try raster.pixels().bounds { isColor($0, .red) })
        XCTAssertEqual(raster.cacheCount, 0)
    }

    private func history(_ backend: ImageRaster.Backend) throws {
        let raster = try ImageRaster(backend)
        raster.driver.feed("\u{1b}[?25l\u{1b}_Ga=T,f=24,s=1,v=1,i=7,p=3,c=4,r=4,C=1;/wAA\u{1b}\\\u{1b}[6;1H" + String(repeating: "\r\n", count: 20))
        let live = try raster.driver.totalRows - raster.driver.rows
        try raster.apply(top: live)
        XCTAssertNil(try raster.pixels().bounds { isColor($0, .red) })
        let frame = try raster.apply(top: 2)
        XCTAssertLessThan(try XCTUnwrap(frame.imageSnapshot.placements.first).row - frame.topRow, 0)
        let bounds = try XCTUnwrap(raster.pixels().bounds { isColor($0, .red) })
        XCTAssertEqual(bounds.minY, 0, accuracy: 1)
        XCTAssertGreaterThan(bounds.height, 10)
        try raster.apply(top: live)
        XCTAssertNil(try raster.pixels().bounds { isColor($0, .red) })
        XCTAssertEqual(raster.cacheCount, 0)
    }

    private func virtual(_ backend: ImageRaster.Backend) throws {
        let raster = try ImageRaster(backend)
        let scale = raster.window.backingScaleFactor
        let width = Int((raster.view.cellSize.width * scale).rounded()) * 4
        let height = Int((raster.view.cellSize.height * scale).rounded()) * 4
        // An exact physical-grid source avoids the pinned fractional/zero
        // virtual crop case. That original case remains a separate rejection.
        raster.driver.feed("\u{1b}[?25l\u{1b}_Ga=T,U=1,f=24,s=\(width),v=\(height),i=7,c=4,r=4,q=2;" + String(repeating: "/wAA", count: width * height)
            + "\u{1b}\\\u{1b}[38;5;7;4;53m\u{10eeee}\u{305}\u{305}")
        let frame = try raster.apply()
        XCTAssertTrue(try XCTUnwrap(frame.rows[0]?.cells[0].isImagePlaceholder))
        XCTAssertNil(raster.source.lines[0]?[0].getCharacter().unicodeScalars.first.flatMap { $0.value == 0x10EEEE ? $0 : nil })
        XCTAssertFalse(try XCTUnwrap(raster.source.lines[0]?[0].attribute.style).contains(.underline))
        XCTAssertFalse(try XCTUnwrap(raster.source.lines[0]?[0].attribute.hasOverline))
        raster.source.withFrame { frame, _, _ in
            XCTAssertFalse(frame.kitty?.placements.isEmpty ?? true)
            XCTAssertTrue(frame.kitty?.placements.allSatisfy { !$0.isVirtual && $0.resolvedSize != nil } ?? false)
        }
        XCTAssertNotNil(try raster.pixels().bounds { isColor($0, .red) })
    }

    private enum Color { case red, green, blue, white }
    private func isColor(_ c: [UInt8], _ color: Color) -> Bool {
        switch color {
        case .red: return c[0] > 180 && c[1] < 100 && c[2] < 100 && c[3] > 180
        case .green: return c[1] > 180 && c[0] < 100 && c[2] < 100 && c[3] > 180
        case .blue: return c[2] > 180 && c[0] < 100 && c[1] < 100 && c[3] > 180
        case .white: return c[0] > 200 && c[1] > 200 && c[2] > 200 && c[3] > 180
        }
    }
    private func assertColor(_ c: [UInt8], _ color: Color, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(isColor(c, color), "expected \(color), got \(c)", file: file, line: line)
    }

    private func exactSize(_ backend: ImageRaster.Backend) throws {
        let raster = try ImageRaster(backend)
        raster.driver.feed("\u{1b}[?25l\u{1b}[2;3H\u{1b}_Ga=T,f=24,s=13,v=7,i=7,p=3,X=1,Y=3,C=1;"
            + String(repeating: "/wAA", count: 13 * 7) + "\u{1b}\\")
        let frame = try raster.apply()
        let placement = try XCTUnwrap(frame.imageSnapshot.placements.first)
        XCTAssertEqual(placement.pixelWidth, 13); XCTAssertEqual(placement.pixelHeight, 7)
        let pixels = try raster.pixels()
        let red = try XCTUnwrap(pixels.bounds(where: { $0[0] > 180 && $0[1] < 100 && $0[2] < 100 && $0[3] > 180 }), "image pixels must really be drawn: \(backend)")
        XCTAssertEqual(red.width, 13, accuracy: 1)
        XCTAssertEqual(red.height, 7, accuracy: 1)
        let scale = CGFloat(pixels.width) / raster.view.bounds.width
        XCTAssertEqual(red.minX, raster.view.cellSize.width * 2 * scale + 1, accuracy: 1)
        XCTAssertEqual(red.minY, raster.view.cellSize.height * scale + 3, accuracy: 1)
    }
}

@MainActor
private final class ImageRaster {
    enum Backend { case coreGraphics, metal }
    struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8] // RGBA, top row first
        func color(_ x: Int, _ y: Int) -> [UInt8] {
            let i = (y * width + x) * 4
            return Array(bytes[i..<(i + 4)])
        }
        func sample(_ rect: CGRect, x: CGFloat, y: CGFloat) -> [UInt8] {
            color(Int(rect.minX + rect.width * x), Int(rect.minY + rect.height * y))
        }
        func bounds(where predicate: ([UInt8]) -> Bool) -> CGRect? {
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where predicate(color(x, y)) {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }
    let driver: GhosttyVTDriver
    let source = SwiftTermFrameSource()
    let view: TerminalRenderView
    let window: NSWindow
    let target: TerminalMetalLayerView?
    let metal: MetalTerminalRenderer?

    init(_ backend: Backend) throws {
        driver = try GhosttyVTDriver(columns: 12, rows: 6)
        view = TerminalRenderView(frame: .zero, font: .monospacedSystemFont(ofSize: 16, weight: .regular))
        view.nativeForegroundColor = .white; view.nativeBackgroundColor = .black
        view.bidiHostPolicy = .legacyLeftToRight
        view.setFrameSize(CGSize(width: view.cellSize.width * 12, height: view.cellSize.height * 6))
        window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view; view.frameSource = source
        let scale = window.backingScaleFactor
        try driver.resize(columns: 12, rows: 6, cellWidth: UInt32((view.cellSize.width * scale).rounded()),
                          cellHeight: UInt32((view.cellSize.height * scale).rounded()))
        if backend == .metal {
            guard let device = MTLCreateSystemDefaultDevice(), MetalTerminalRenderer.shaderLibraryIsAvailable else {
                throw XCTSkip("Metal unavailable")
            }
            let surface = TerminalMetalLayerView(frame: view.bounds)
            surface.renderDevice = device; surface.metalLayer.framebufferOnly = false
            surface.renderContentsScale = scale
            surface.renderDrawableSize = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
            target = surface
            let renderer = try MetalTerminalRenderer(target: surface)
            renderer.waitForCompletionAfterCommit = true; renderer.capturesRenderedTexture = true
            metal = renderer
        } else { target = nil; metal = nil }
    }

    isolated deinit { window.contentView = nil }

    var cacheCount: Int { metal?.capturedKittyTextureCount ?? view.kittyPlacementImageCache.withLock { $0.count } }
    func pixelRect(_ p: NativeImagePlacement, in pixels: Pixels, top: Int) -> CGRect {
        let scale = CGFloat(pixels.width) / view.bounds.width
        return CGRect(x: CGFloat(p.column) * view.cellSize.width * scale + CGFloat(p.offsetX),
            y: CGFloat(p.row - top) * view.cellSize.height * scale + CGFloat(p.offsetY),
            width: CGFloat(p.pixelWidth), height: CGFloat(p.pixelHeight))
    }

    @discardableResult
    func apply(top: Int = 0) throws -> NativeTerminalFrame {
        let frame = try driver.snapshot(topRow: top)
        source.apply(frame, topLine: frame.topRow, renderRows: 6)
        view.presentExternalFrame()
        return frame
    }

    func pixels() throws -> Pixels {
        if let metal, let target {
            XCTAssertTrue(view.renderSnapshotForMetal(renderer: metal, target: target))
            let texture = try XCTUnwrap(metal.lastRenderedTexture)
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            bytes.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                    from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            }
            if texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb {
                for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }
            }
            return .init(width: texture.width, height: texture.height, bytes: bytes)
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var bytes: [UInt8] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                bytes += [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map {
                    UInt8(min(255, max(0, ($0 * 255).rounded())))
                }
            }
        }
        return .init(width: bitmap.pixelsWide, height: bitmap.pixelsHigh, bytes: bytes)
    }
}
