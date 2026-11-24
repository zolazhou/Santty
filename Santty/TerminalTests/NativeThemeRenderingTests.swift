import AppKit
import Metal
@testable import SwiftTerm
import XCTest
@testable import Santty

@MainActor
final class NativeThemeRenderingTests: XCTestCase {
    func testCoreGraphicsThemeSelectionAndOpacityHaveActualPixels() throws { try appearance(metal: false) }
    func testMetalThemeSelectionAndOpacityHaveActualPixels() throws { try appearance(metal: true) }
    func testCoreGraphicsUsesThemeCursorTextRatherThanBackground() throws { try caret(metal: false) }
    func testMetalUsesThemeCursorTextRatherThanBackground() throws { try caret(metal: true) }

    private func theme(palette: NativeRGB) -> NativeTerminalTheme {
        .init(name: "owned pixel vector", foreground: .init(red: 255, green: 255, blue: 255),
            background: .init(red: 255, green: 0, blue: 0), cursor: .init(red: 0, green: 0, blue: 255),
            cursorText: .init(red: 0, green: 255, blue: 0), selectionForeground: .init(red: 255, green: 255, blue: 255),
            selectionBackground: .init(red: 0, green: 0, blue: 255), palette: [1: palette])
    }
    private func appearance(metal: Bool) throws {
        let raster = try ThemeRaster(metal: metal)
        let green = NativeRGB(red: 0, green: 255, blue: 0)
        try raster.terminal.applySettings(.init(theme: theme(palette: green), padding: 0, backgroundOpacity: 1))
        raster.terminal.feed("\u{1b}[?25l\u{1b}[31mMMMM")
        var pixels = try raster.pixels()
        XCTAssertGreaterThan(pixels.dominant(0), 100)
        XCTAssertGreaterThan(pixels.dominant(1), 10, "palette 1 is green, not a renderer default")
        try raster.terminal.driver.selectAll(); raster.terminal.refresh()
        pixels = try raster.pixels()
        XCTAssertGreaterThan(pixels.dominant(2), 20, "actual selection background must use theme blue")
        raster.terminal.driver.clearSelection()
        raster.terminal.driver.feed("\u{1b}[0m\u{1b}[2J")
        try raster.terminal.applySettings(.init(theme: theme(palette: green), padding: 0, backgroundOpacity: 0.25))
        pixels = try raster.pixels()
        XCTAssertTrue(pixels.bytes.enumerated().contains { $0.offset % 4 == 3 && (60...68).contains($0.element) },
                      "default background must be translucent in actual \(metal ? "Metal" : "CG") pixels")
    }
    private func caret(metal: Bool) throws {
        let raster = try ThemeRaster(metal: metal)
        try raster.terminal.applySettings(.init(theme: theme(palette: .init(red: 255, green: 255, blue: 255)), padding: 0,
            backgroundOpacity: 1, cursorBlink: false))
        raster.terminal.feed("MMMM\u{1b}[H")
        raster.terminal.renderer.hasFocus = true
        raster.terminal.refresh()
        let pixels = try raster.pixels()
        XCTAssertGreaterThan(pixels.dominant(2), 15, "caret background is blue")
        XCTAssertGreaterThan(pixels.dominant(1), 5, "only the theme's caret text is green")
    }
}

@MainActor
private final class ThemeRaster {
    struct Pixels {
        let bytes: [UInt8]
        func dominant(_ channel: Int) -> Int {
            var count = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let value = Int(bytes[i + channel])
                let other1 = Int(bytes[i + (channel + 1) % 3])
                let other2 = Int(bytes[i + (channel + 2) % 3])
                if value > 150 && value > other1 + 50 && value > other2 + 50 && bytes[i + 3] > 150 { count += 1 }
            }
            return count
        }
    }
    let terminal: NativeTerminalScrollView
    private let window: NSWindow
    private let target: TerminalMetalLayerView?
    private let renderer: MetalTerminalRenderer?
    init(metal: Bool) throws {
        terminal = NativeTerminalScrollView(driver: try GhosttyVTDriver(), frame: .init(x: 0, y: 0, width: 320, height: 120))
        window = NSWindow(contentRect: terminal.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = terminal
        if metal {
            let t = TerminalMetalLayerView(frame: terminal.renderer.bounds)
            t.renderDevice = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            t.metalLayer.framebufferOnly = false
            t.renderContentsScale = window.backingScaleFactor
            target = t
            let r = try MetalTerminalRenderer(target: t)
            r.waitForCompletionAfterCommit = true; r.capturesRenderedTexture = true
            renderer = r
        } else { target = nil; renderer = nil }
    }
    isolated deinit { window.contentView = nil }
    func pixels() throws -> Pixels {
        let view = terminal.renderer
        if let target, let renderer {
            target.frame = view.bounds
            target.renderDrawableSize = .init(width: view.bounds.width * window.backingScaleFactor,
                                             height: view.bounds.height * window.backingScaleFactor)
            XCTAssertTrue(view.renderSnapshotForMetal(renderer: renderer, target: target))
            let texture = try XCTUnwrap(renderer.lastRenderedTexture)
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
            if texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb {
                for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }
            }
            return .init(bytes: bytes)
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        // AppKit's cacheDisplay is the content bitmap, including its caret;
        // the shared CG painter deliberately clears default-background pixels.
        // Compose that actual bitmap over the actual layer background using
        // Core Animation. A hidden view's backing contents may not yet have
        // been committed, so rendering its live layer alone samples stale data.
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let composed = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: composed))
        let layer = CALayer()
        layer.bounds = view.bounds
        layer.backgroundColor = view.layer?.backgroundColor
        layer.contents = bitmap.cgImage
        context.cgContext.clear(view.bounds)
        layer.render(in: context.cgContext)
        var bytes: [UInt8] = []
        for y in 0..<composed.pixelsHigh { for x in 0..<composed.pixelsWide {
            let c = try XCTUnwrap(composed.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            bytes += [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { UInt8(min(255, max(0, ($0 * 255).rounded()))) }
        } }
        return .init(bytes: bytes)
    }
}
