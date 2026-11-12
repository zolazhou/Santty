import AppKit
import Metal
@testable import SwiftTerm
import XCTest
@testable import SanttyTerminalLab

/// Owned VT cells through the actual external renderer. No screen capture,
/// application activation, user terminal, or second emulator is involved.
@MainActor
final class NativeTerminalStyleTests: XCTestCase {
    func testCoreGraphicsPaintsVTOverlineOnBlankCells() throws { try overline(.coreGraphics) }
    func testMetalPaintsVTOverlineOnBlankCells() throws { try overline(.metal) }
    func testFocusedHollowCursorIsAnOutlineInCoreGraphics() throws { try hollow(.coreGraphics) }
    func testFocusedHollowCursorIsAnOutlineInMetal() throws { try hollow(.metal) }
    func testWideTailHollowCursorInCoreGraphics() throws { try hollow(.coreGraphics, wide: true) }
    func testWideTailHollowCursorInMetal() throws { try hollow(.metal, wide: true) }
    func testCoreGraphicsOverlineGeometryColorAndShapedCells() throws { try geometry(.coreGraphics) }
    func testMetalOverlineGeometryColorAndShapedCells() throws { try geometry(.metal) }
    func testCoreGraphicsOverlineSelectionHoverPaletteAndConceal() throws { try interactions(.coreGraphics) }
    func testMetalOverlineSelectionHoverPaletteAndConceal() throws { try interactions(.metal) }

    func testOverlineUsesAnIndependentInternedAttributeWithoutWideningPackedCells() {
        let store = TerminalRowStore()
        let row = store.makeLine(columns: 4)
        let plain = Attribute(foreground: .defaultColor, background: .ansi256(code: 2), style: [])
        let over = Attribute(foreground: .defaultColor, background: .ansi256(code: 2), style: [], hasOverline: true)
        XCTAssertNotEqual(plain, over)
        XCTAssertEqual(MemoryLayout<PackedCell>.size, 8)
        XCTAssertTrue(store.setCell(row, column: 0, text: nil, width: 1, attribute: plain))
        XCTAssertTrue(store.setCell(row, column: 1, text: nil, width: 1, attribute: over))
        XCTAssertTrue(store.setCell(row, column: 2, text: " ", width: 1, attribute: plain))
        XCTAssertTrue(store.setCell(row, column: 3, text: " ", width: 1, attribute: over))
        XCTAssertFalse(row[0].attribute.hasOverline)
        XCTAssertTrue(row[1].attribute.hasOverline, "nil colored cells must not use the style-dropping background shortcut")
        XCTAssertFalse(row[2].attribute.hasOverline)
        XCTAssertTrue(row[3].attribute.hasOverline, "the intern key must distinguish the boolean")
        XCTAssertEqual(row[1].attribute.bg, .ansi256(code: 2))
        let all = Attribute(foreground: .ansi256(code: 1), background: .defaultColor,
            style: CharacterStyle(rawValue: .max), underlineStyle: .curly,
            underlineColor: .ansi256(code: 3), hasOverline: true)
        XCTAssertTrue(store.setCell(row, column: 0, text: "x", width: 1, attribute: all))
        XCTAssertEqual(row[0].attribute, all, "all eight legacy flags and underline data must survive together")
    }

    func testVTDefaultHollowBlinkAndProgramOverrideRemainAuthoritative() throws {
        let raster = try StyleRaster(.coreGraphics)
        try raster.driver.setDefaultCursorStyle(.hollow, blinking: true)
        raster.driver.feed("\u{1b}[0 q")
        var frame = try raster.driver.snapshot(topRow: 0)
        XCTAssertEqual(frame.cursor.shape, .hollow)
        XCTAssertTrue(frame.cursor.blinking)
        raster.view.hasFocus = true
        try raster.apply()
        raster.source.withFrame { frame, _, _ in
            XCTAssertTrue(frame.cursorHollow)
            XCTAssertEqual(frame.cursorStyle, .blinkBlock)
        }
        let caret = try XCTUnwrap(raster.view.subviews.compactMap { $0 as? CaretView }.first)
        XCTAssertTrue(caret.forceHollow)
        XCTAssertNotNil(caret.layer?.animation(forKey: "opacity"))
        raster.driver.feed("\u{1b}[6 q")
        try raster.driver.setDefaultCursorStyle(.block, blinking: false)
        frame = try raster.driver.snapshot(topRow: 0)
        XCTAssertEqual(frame.cursor.shape, .bar, "setting defaults must not replace the program's DECSCUSR override")
        XCTAssertFalse(frame.cursor.blinking)
        raster.driver.feed("\u{1b}[0 q")
        try raster.apply()
        raster.source.withFrame { frame, _, _ in
            XCTAssertFalse(frame.cursorHollow)
            XCTAssertEqual(frame.cursorStyle, .steadyBlock)
        }
        XCTAssertNil(caret.layer?.animation(forKey: "opacity"))
    }

    private func geometry(_ backend: StyleRaster.Backend) throws {
        let raster = try StyleRaster(backend)
        for (text, fontFlags) in [("ab", "0"), ("Wi", "1;3"), ("中", "0"), ("e\u{301}", "0")] {
            raster.driver.reset()
            let prefix = "\u{1b}[?25l\u{1b}[2;3H\u{1b}[\(fontFlags);38;2;255;0;0;58;2;0;0;255m"
            raster.driver.feed(prefix + text)
            try raster.apply()
            let before = try raster.pixels()
            raster.driver.feed(prefix + "\u{1b}[53m" + text + "\u{1b}[55m")
            try raster.apply()
            let decorated = try raster.pixels()
            let added = stride(from: 0, to: decorated.bytes.count, by: 4).filter {
                Int(decorated.bytes[$0]) > Int(before.bytes[$0]) + 100
            }
            XCTAssertGreaterThan(added.count, 10, "\(backend): \(text)")
            let expected = try referenceColor(backend, red: 1, green: 0, blue: 0)
            XCTAssertTrue(added.allSatisfy { matches(decorated, at: $0, color: expected) },
                          "overline follows the backend's foreground color, not SGR 58 blue")
            let top = Int((raster.view.cellSize.height * CGFloat(decorated.height) / raster.view.bounds.height).rounded())
            XCTAssertTrue(added.allSatisfy { (top - 1)...(top + 3) ~= $0 / 4 / decorated.width },
                          "overline must stay inside the top of its row: \(backend), \(text)")
        }
    }

    private func interactions(_ backend: StyleRaster.Backend) throws {
        let raster = try StyleRaster(backend)
        raster.driver.feed("\u{1b}[?25l\u{1b}[31;53mx   ")
        try raster.apply()
        let red = try raster.pixels()
        raster.driver.feed("\u{1b}]4;1;rgb:00/ff/00\u{7}")
        try raster.apply()
        let green = try raster.pixels()
        XCTAssertFalse(red.bytes == green.bytes, "palette-only output must recolor the decoration cache")
        raster.source.selectionForeground = .init(red: 0, green: 0, blue: 255)
        raster.source.selectionBackground = .init(red: 0, green: 0, blue: 0)
        try raster.driver.selectAll()
        raster.source.highlightedLink = [0: 0..<4]
        try raster.apply()
        let selected = try raster.pixels()
        XCTAssertNotNil(try raster.driver.snapshot(topRow: 0).selection[0], "selectAll legitimately has no range in an all-blank terminal")
        XCTAssertTrue(try XCTUnwrap(raster.source.lines[0]?[0].attribute.hasOverline))
        XCTAssertTrue(try XCTUnwrap(raster.source.lines[0]?[0].attribute.style).contains(.underline))
        let expected = try referenceColor(backend, red: 0, green: 0, blue: 1)
        XCTAssertTrue(stride(from: 0, to: min(selected.bytes.count, selected.width * 3 * 4), by: 4).contains {
            matches(selected, at: $0, color: expected)
        }, "selected overline at the row top must use selection foreground")
        raster.driver.clearSelection(); raster.source.highlightedLink = [:]
        try raster.apply()
        XCTAssertTrue(try raster.pixels().bytes == green.bytes)
        raster.driver.reset()
        raster.driver.feed("\u{1b}[?25l\u{1b}[8;53m    ")
        try raster.apply()
        XCTAssertEqual(try raster.pixels().litCount, 0, "conceal hides overline as well as glyphs")
    }

    private func referenceColor(_ backend: StyleRaster.Backend, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> [Int] {
        // SwiftTerm's existing CG color contract uses calibrated NSColor;
        // the Metal plain-run path uses direct RGB. Compare each to an
        // independent platform reference, not to its own renderer output.
        let color = backend == .coreGraphics
            ? try XCTUnwrap(NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1).usingColorSpace(.sRGB))
            : NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    private func matches(_ pixels: StyleRaster.Pixels, at index: Int, color: [Int]) -> Bool {
        (0..<3).allSatisfy { abs(Int(pixels.bytes[index + $0]) - color[$0]) <= 2 }
    }

    private func overline(_ backend: StyleRaster.Backend) throws {
        let raster = try StyleRaster(backend)
        raster.driver.feed("\u{1b}[?25l")
        try raster.apply()
        let before = try raster.pixels()
        raster.driver.feed("\u{1b}[53m    ")
        XCTAssertTrue(try XCTUnwrap(raster.driver.snapshot(topRow: 0).rows[0]?.cells[0]).style.contains(.overline))
        try raster.apply()
        let decorated = try raster.pixels()
        XCTAssertGreaterThan(decorated.litCount, before.litCount + 10, "SGR 53 must paint even without a glyph: \(backend)")
        raster.driver.feed("\r\u{1b}[55m    ")
        try raster.apply()
        XCTAssertTrue(try raster.pixels().bytes == before.bytes, "SGR 55 must clear cached decoration")
    }

    private func hollow(_ backend: StyleRaster.Backend, wide: Bool = false) throws {
        let raster = try StyleRaster(backend)
        raster.driver.feed(wide ? "\u{1b}[2;3H　\u{1b}[2;4H\u{1b}[2 q" : "\u{1b}[2;3H\u{1b}[2 q")
        raster.view.hasFocus = true
        try raster.apply(shape: .block)
        let filled = try raster.pixels(caretOnly: true)
        try raster.apply(shape: .hollow)
        let outline = try raster.pixels(caretOnly: true)
        XCTAssertTrue(raster.view.hasFocus, "hollow shape must not fake focus loss")
        XCTAssertGreaterThan(outline.litCount, 10)
        XCTAssertLessThan(outline.litCount, filled.litCount * 4 / 5, "focused hollow must not be a filled block: \(backend)")
        raster.view.hasFocus = false
        try raster.apply(shape: .block)
        XCTAssertTrue(try raster.pixels(caretOnly: true).bytes == outline.bytes,
                       "explicit hollow should reuse the renderer's existing inactive outline geometry")
        raster.view.hasFocus = true
        try raster.apply(shape: .block)
        XCTAssertTrue(try raster.pixels(caretOnly: true).bytes == filled.bytes)
        if wide {
            let caret = try XCTUnwrap(raster.view.subviews.compactMap { $0 as? CaretView }.first)
            XCTAssertEqual(caret.frame.width, raster.view.cellSize.width * 2, accuracy: 0.01)
            XCTAssertEqual(try raster.driver.snapshot(topRow: 0).cursor.column, 2)
        }
    }
}

@MainActor
private final class StyleRaster {
    enum Backend { case coreGraphics, metal }
    struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8] // RGBA, top row first
        var litCount: Int {
            stride(from: 0, to: bytes.count, by: 4).filter {
                max(bytes[$0], bytes[$0 + 1], bytes[$0 + 2]) > 127 && bytes[$0 + 3] > 127
            }.count
        }
    }
    let driver: GhosttyVTDriver
    let source = SwiftTermFrameSource()
    let view: TerminalRenderView
    let window: NSWindow
    private let target: TerminalMetalLayerView?
    private let metal: MetalTerminalRenderer?

    init(_ backend: Backend) throws {
        driver = try GhosttyVTDriver(columns: 12, rows: 3)
        view = TerminalRenderView(frame: .zero, font: .monospacedSystemFont(ofSize: 16, weight: .regular))
        view.nativeBackgroundColor = .black; view.nativeForegroundColor = .white; view.caretColor = .white
        view.bidiHostPolicy = .legacyLeftToRight
        view.setFrameSize(NSSize(width: view.cellSize.width * 12, height: view.cellSize.height * 3))
        window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.frameSource = source
        if backend == .metal {
            guard let device = MTLCreateSystemDefaultDevice(), MetalTerminalRenderer.shaderLibraryIsAvailable else {
                throw XCTSkip("Metal unavailable")
            }
            let surface = TerminalMetalLayerView(frame: view.bounds)
            surface.renderDevice = device; surface.metalLayer.framebufferOnly = false
            let scale = window.backingScaleFactor
            surface.renderContentsScale = scale
            surface.renderDrawableSize = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
            target = surface
            let renderer = try MetalTerminalRenderer(target: surface)
            renderer.waitForCompletionAfterCommit = true; renderer.capturesRenderedTexture = true
            metal = renderer
        } else { target = nil; metal = nil }
    }

    isolated deinit { window.contentView = nil }

    func apply(shape: NativeTerminalFrame.CursorShape? = nil) throws {
        let base = try driver.snapshot(topRow: 0)
        var cursor = base.cursor
        if let shape { cursor.shape = shape }
        let frame = NativeTerminalFrame(columns: base.columns, terminalRows: base.terminalRows,
            totalRows: base.totalRows, topRow: base.topRow, rows: base.rows, cursor: cursor,
            foreground: base.foreground, background: base.background, cursorColor: base.cursorColor,
            palette: base.palette, isAlternateScreen: base.isAlternateScreen, selection: base.selection)
        source.apply(frame, topLine: 0, renderRows: 3)
        view.presentExternalFrame()
    }

    func pixels(caretOnly: Bool = false) throws -> Pixels {
        if let target, let metal {
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
            return Pixels(width: texture.width, height: texture.height, bytes: bytes)
        }
        let subject: NSView = caretOnly ? try XCTUnwrap(view.subviews.compactMap { $0 as? CaretView }.first) : view
        let bitmap = try XCTUnwrap(subject.bitmapImageRepForCachingDisplay(in: subject.bounds))
        subject.cacheDisplay(in: subject.bounds, to: bitmap)
        var bytes: [UInt8] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                bytes += [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map {
                    UInt8(min(255, max(0, ($0 * 255).rounded())))
                }
            }
        }
        return Pixels(width: bitmap.pixelsWide, height: bitmap.pixelsHigh, bytes: bytes)
    }
}
