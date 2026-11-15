import AppKit
import Metal
@testable import SwiftTerm
import XCTest
@testable import Santty

/// Uses the pinned renderer's existing test readback seam. No windows are
/// shown and neither a shell nor a Herdr connection is needed.
@MainActor
final class NativeTerminalMetalTests: XCTestCase {
    func testGhosttyFrameProducesMetalPixelsAndTracksPaletteChanges() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              MetalTerminalRenderer.shaderLibraryIsAvailable else {
            throw XCTSkip("Metal is not available on this Mac.")
        }
        let driver = try GhosttyVTDriver(columns: 20, rows: 4)
        driver.feed("\u{1b}[?25l\u{1b}[31mMMMM中文\u{1b}[0m")
        let source = SwiftTermFrameSource()
        let view = TerminalRenderView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.bidiHostPolicy = .legacyLeftToRight
        view.setFrameSize(NSSize(width: view.cellSize.width * 20, height: view.cellSize.height * 4))
        view.frameSource = source
        source.apply(try driver.snapshot(topRow: 0), topLine: 0, renderRows: 4)

        let target = TerminalMetalLayerView(frame: view.bounds)
        target.renderDevice = device
        target.metalLayer.framebufferOnly = false
        // Match the external view's Retina scale; a 1× test texture would
        // clip the 2× glyphs outside the drawable and falsely look blank.
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        target.renderContentsScale = scale
        target.renderDrawableSize = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true

        func pixels() throws -> [UInt8] {
            XCTAssertTrue(view.renderSnapshotForMetal(renderer: renderer, target: target))
            let texture = try XCTUnwrap(renderer.lastRenderedTexture)
            let bytesPerRow = texture.width * 4
            var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
            bytes.withUnsafeMutableBytes { raw in
                texture.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                    from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            }
            return bytes
        }

        let before = try pixels()
        var peak = 0
        var lit = 0
        for index in stride(from: 0, to: before.count, by: 4) {
            let sum = Int(before[index]) + Int(before[index + 1]) + Int(before[index + 2])
            peak = max(peak, sum)
            if sum > 100 { lit += 1 }
        }
        let color = try driver.snapshot(topRow: 0).palette[1]
        XCTAssertGreaterThan(lit, 10, "Metal must actually render glyphs: peak=\(peak), palette1=\(color)")

        driver.feed("\u{1b}]4;1;rgb:00/ff/00\u{7}")
        source.apply(try driver.snapshot(topRow: 0), topLine: 0, renderRows: 4)
        let after = try pixels()
        XCTAssertFalse(before == after, "cached rows must respect a new palette")
    }

    func testMetalSelectionPixelsAppearAndClearWithOwnedRows() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              MetalTerminalRenderer.shaderLibraryIsAvailable else { throw XCTSkip("Metal unavailable") }
        let driver = try GhosttyVTDriver(columns: 20, rows: 4)
        driver.feed("\u{1b}[?25lhello world")
        let source = SwiftTermFrameSource()
        let view = TerminalRenderView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.frameSource = source
        view.nativeBackgroundColor = .black; view.nativeForegroundColor = .white
        view.setFrameSize(NSSize(width: view.cellSize.width * 20, height: view.cellSize.height * 4))
        let target = TerminalMetalLayerView(frame: view.bounds)
        target.renderDevice = device; target.metalLayer.framebufferOnly = false
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        target.renderContentsScale = scale
        target.renderDrawableSize = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true; renderer.capturesRenderedTexture = true
        func pixels() throws -> [UInt8] {
            source.apply(try driver.snapshot(topRow: 0), topLine: 0, renderRows: 4)
            XCTAssertTrue(view.renderSnapshotForMetal(renderer: renderer, target: target))
            let texture = try XCTUnwrap(renderer.lastRenderedTexture)
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            bytes.withUnsafeMutableBytes { raw in
                texture.getBytes(raw.baseAddress!, bytesPerRow: texture.width * 4,
                    from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            }
            return bytes
        }
        let before = try pixels()
        try driver.selectAll()
        let selected = try pixels()
        XCTAssertFalse(selected == before)
        source.selectionBackground = NativeRGB(red: 10, green: 130, blue: 20)
        XCTAssertFalse(try pixels() == selected, "selection color changes must invalidate cached owned rows")
        driver.clearSelection()
        XCTAssertEqual(try pixels(), before)
        source.highlightedLink = [0: 0..<5]
        XCTAssertNotEqual(try pixels(), before, "hover must produce real Metal underline pixels")
        source.highlightedLink = [:]
        XCTAssertEqual(try pixels(), before, "clearing hover must invalidate the same cached rows")
    }

    func testMetalSurfaceRemainsViewportSizedAndCanReturnToCoreGraphics() throws {
        guard MTLCreateSystemDefaultDevice() != nil,
              MetalTerminalRenderer.shaderLibraryIsAvailable else { throw XCTSkip("Metal unavailable") }
        let driver = try GhosttyVTDriver()
        let view = NativeTerminalScrollView(driver: driver, frame: NSRect(x: 0, y: 0, width: 640, height: 245))
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        view.feed((0..<2000).map { "row-\($0)\r\n" }.joined())
        try view.setMetal(true)
        XCTAssertTrue(view.renderer.isUsingMetalRenderer)
        let surface = try XCTUnwrap(view.renderer.subviews.compactMap { $0 as? TerminalMetalLayerView }.first)
        XCTAssertLessThanOrEqual(surface.bounds.height, view.contentSize.height + view.renderer.cellSize.height * 3)
        XCTAssertLessThan(surface.renderDrawableSize.height,
                          view.contentSize.height * window.backingScaleFactor * 2)
        view.contentView.scroll(to: NSPoint(x: 0, y: 105))
        XCTAssertEqual(view.contentView.bounds.minY, 105, accuracy: 0.01)
        try view.setMetal(false)
        XCTAssertFalse(view.renderer.isUsingMetalRenderer)
        XCTAssertNil(view.lastError)
    }
}
