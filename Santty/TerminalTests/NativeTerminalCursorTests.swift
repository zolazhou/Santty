import AppKit
import Metal
@testable import SwiftTerm
import XCTest
@testable import Santty

@MainActor
final class NativeTerminalCursorTests: XCTestCase {
    private func litPixels(in view: NSView) throws -> Int {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var lit = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   max(color.redComponent, color.greenComponent, color.blueComponent) > 0.5,
                   color.alphaComponent > 0.5 { lit += 1 }
            }
        }
        return lit
    }

    func testCoreGraphicsDrawsCursorOnBlankPromptCell() throws {
        let driver = try GhosttyVTDriver(columns: 40, rows: 8)
        let view = NativeTerminalScrollView(driver: driver, frame: NSRect(x: 0, y: 0, width: 640, height: 245))
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        view.feed("$ ")
        let frame = try driver.snapshot(topRow: 0)
        XCTAssertTrue(frame.cursor.visible, "Ghostty must expose the default shell cursor")
        XCTAssertEqual(frame.cursor.column, 2)
        let renderer = view.renderer
        // Exercise AppKit's normal view drawing, not a direct drawCursor call:
        // an attached CaretView with the right frame can still paint nothing.
        for style in [2, 4, 6] { // steady block, underline and bar
            view.feed("\u{1b}[\(style) q")
            for focused in [true, false] {
                renderer.hasFocus = focused
                renderer.presentExternalFrame()
                let caret = try XCTUnwrap(renderer.subviews.compactMap { $0 as? CaretView }.first)
                XCTAssertFalse(caret.isHidden)
                XCTAssertTrue(renderer.bounds.contains(caret.frame))
                XCTAssertGreaterThan(try litPixels(in: caret), 10,
                    "AppKit must paint the cursor: style=\(style), focused=\(focused)")
            }
        }
        view.feed("\u{1b}[?25l")
        XCTAssertFalse(renderer.subviews.contains { $0 is CaretView }, "Respect program-requested cursor hiding")
        view.feed("\u{1b}[?25h")
        let restored = try XCTUnwrap(renderer.subviews.compactMap { $0 as? CaretView }.first)
        XCTAssertGreaterThan(try litPixels(in: restored), 10)
    }

    func testCursorStaysInLiveViewportAndIsAbsentFromOlderHistory() throws {
        let driver = try GhosttyVTDriver()
        let view = NativeTerminalScrollView(driver: driver, frame: NSRect(x: 0, y: 0, width: 640, height: 245))
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        view.feed(String(repeating: "history\r\n", count: 100) + "$ ")
        let caret = try XCTUnwrap(view.renderer.subviews.compactMap { $0 as? CaretView }.first)
        XCTAssertTrue(view.renderer.visibleRect.contains(caret.frame))
        view.contentView.scroll(to: .zero)
        XCTAssertFalse(view.renderer.subviews.contains { $0 is CaretView })
        view.scrollToLiveScreen()
        let restored = try XCTUnwrap(view.renderer.subviews.compactMap { $0 as? CaretView }.first)
        XCTAssertTrue(view.renderer.visibleRect.contains(restored.frame))
        XCTAssertGreaterThan(try litPixels(in: restored), 10)
    }

    func testCursorInOverscanUsesActivePositionAndWideCharacterHead() throws {
        let driver = try GhosttyVTDriver(columns: 8, rows: 4)
        driver.feed(String(repeating: "row\r\n", count: 10) + "中\u{1b}[2G")
        let total = try driver.totalRows
        let frame = try driver.snapshot(topRow: total - driver.rows - 1)
        XCTAssertNotNil(frame.rows[total - 1], "Overscan includes the cursor row below Ghostty's viewport")
        XCTAssertTrue(frame.cursor.visible)
        XCTAssertEqual(frame.cursor.line, total - 1)
        XCTAssertEqual(frame.cursor.column, 0, "A cursor on a wide tail must draw over the character's head")
        XCTAssertFalse(try driver.snapshot(topRow: 0).cursor.visible, "Older history has no live cursor")
    }

    func testMetalDrawsCursorAndRespectsVisibilityWithoutCoreGraphicsCaret() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              MetalTerminalRenderer.shaderLibraryIsAvailable else { throw XCTSkip("Metal unavailable") }
        let driver = try GhosttyVTDriver(columns: 20, rows: 4)
        driver.feed("$ \u{1b}[2 q")
        let source = SwiftTermFrameSource()
        let view = TerminalRenderView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.caretColor = .white
        view.hasFocus = true
        view.bidiHostPolicy = .legacyLeftToRight
        view.setFrameSize(NSSize(width: view.cellSize.width * 20, height: view.cellSize.height * 4))
        view.frameSource = source
        let target = TerminalMetalLayerView(frame: view.bounds)
        target.renderDevice = device
        target.metalLayer.framebufferOnly = false
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        target.renderContentsScale = scale
        target.renderDrawableSize = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
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
        let visible = try pixels()
        driver.feed("\u{1b}[?25l")
        let hidden = try pixels()
        XCTAssertGreaterThan(zip(visible, hidden).filter { $0 != $1 }.count, 10,
                             "The Metal cursor must paint pixels independently of the AppKit caret")
        driver.feed("\u{1b}[?25h")
        XCTAssertEqual(try pixels(), visible)
    }
}
