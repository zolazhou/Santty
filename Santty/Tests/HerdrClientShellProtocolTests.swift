import Foundation
import AppKit
import GhosttyTerminal
import XCTest
@testable import Santty

final class HerdrClientShellProtocolTests: XCTestCase {
    private func surfaceReuseJSON() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/herdr-clientshell-reuse-v1.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func reuseMessage(_ json: [String: Any]) throws -> HerdrShellServerMessage {
        .control("endpoint.surface-reuse.v1", String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
    }
    private func reuseDecoder(scroll: Bool = false, delta: Bool = false) throws -> HerdrClientShellSurfaceDecoder {
        var decoder = HerdrClientShellSurfaceDecoder(requestedReuse: true, requestedScroll: scroll, requestedDelta: delta)
        _ = try decoder.decode(.control("endpoint.welcome.v1", #"{"generation":1,"server_version":"fixture","snapshot_codec":"shell.snapshot.v1","surface_codec":"shell.surface.v1","input_codec":"shell.input.semantic.v1","blob_codec":"shell.blob.v1","capabilities":["surface_interest","surface_reuse","surface_scroll","surface_delta"]}"#))
        return decoder
    }

    private enum DeltaPopup {
        case none
        case replace(String, String)
        case patch(String, String)
    }
    private func deltaBytes(baseProjection: UInt64 = 251, baseSurface: UInt64 = 65536,
                            rows: [(UInt16, UInt16, [String])] = [], popup: DeltaPopup = .none) throws -> Data {
        var writer = HerdrShellWriter()
        func cell(_ text: String, _ writer: inout HerdrShellWriter) throws {
            try writer.string(text); writer.uint(0); writer.uint(0); writer.uint(0); writer.bool(false); writer.bool(false)
        }
        func frame(_ width: UInt16, _ height: UInt16, _ writer: inout HerdrShellWriter) {
            writer.uint(0); writer.uint(UInt64(width)); writer.uint(UInt64(height)); writer.bool(false); writer.uint(0); writer.uint(0)
        }
        func spans(_ rows: [(UInt16, UInt16, [String])], _ writer: inout HerdrShellWriter) throws {
            writer.uint(UInt64(rows.count))
            for (x, y, cells) in rows {
                writer.uint(UInt64(x)); writer.uint(UInt64(y)); writer.uint(UInt64(cells.count))
                for text in cells { try cell(text, &writer) }
            }
        }
        writer.uint(baseProjection); writer.uint(baseSurface)
        try writer.string("boot"); writer.uint(baseProjection + 1); writer.uint(baseSurface + 1)
        frame(2, 3, &writer)
        writer.uint(1); try writer.string("w5:pA"); writer.uint(10)
        for _ in 0..<2 { writer.uint(0); writer.uint(0); writer.uint(2); writer.uint(3) }
        writer.bool(false); writer.bool(false); writer.bool(true); writer.bool(false); writer.bool(false); writer.bool(false)
        writer.uint(16); writer.uint(48); writer.uint(0)
        switch popup {
        case .none: writer.bool(false)
        case .replace(let id, _), .patch(let id, _):
            writer.bool(true); try writer.string(id); try writer.string("Delta popup")
            writer.bool(false); writer.bool(false); frame(1, 1, &writer)
            writer.bool(false); writer.bool(false); writer.uint(8); writer.uint(16)
        }
        writer.uint(0); writer.uint(0); writer.uint(0)
        try spans(rows, &writer)
        switch popup {
        case .none: writer.bool(false)
        case .replace(_, let text): writer.bool(true); writer.uint(1); writer.uint(1); try cell(text, &writer)
        case .patch(_, let text): writer.bool(true); writer.uint(0); try spans([(0, 0, [text])], &writer)
        }
        return writer.data
    }
    private func deltaMessage(_ bytes: Data) -> HerdrShellServerMessage {
        .control("endpoint.surface-delta.v1", bytes.base64EncodedString().replacingOccurrences(of: "=", with: ""))
    }

    func testDeltaRestoresSparseMainCellsAndPopupReplacePatchCloseReopen() throws {
        var decoder = try reuseDecoder(delta: true)
        _ = try decoder.decode(.surface(scrollBaseline()))
        guard case .surface(let opened) = try decoder.decode(deltaMessage(deltaBytes(rows: [(0, 0, ["X"])], popup: .replace("popup", "P")))) else {
            return XCTFail("Expected complete delta surface")
        }
        XCTAssertEqual(opened.frame.cells.map(\.symbol), ["X", "b", "c", "d", "e", "f"])
        XCTAssertEqual(opened.popup?.frame.cells.first?.symbol, "P")
        guard case .surface(let changed) = try decoder.decode(deltaMessage(deltaBytes(baseProjection: 252, baseSurface: 65537, popup: .patch("popup", "Q")))) else {
            return XCTFail("Expected patched popup")
        }
        XCTAssertEqual(changed.popup?.frame.cells.first?.symbol, "Q")
        XCTAssertEqual(changed.frame.cells, opened.frame.cells)
        guard case .surface(let closed) = try decoder.decode(deltaMessage(deltaBytes(baseProjection: 253, baseSurface: 65538))) else {
            return XCTFail("Expected closed popup")
        }
        XCTAssertNil(closed.popup)
        guard case .surface(let reopened) = try decoder.decode(deltaMessage(deltaBytes(baseProjection: 254, baseSurface: 65539, popup: .replace("new-popup", "R")))) else {
            return XCTFail("Expected replacement popup")
        }
        XCTAssertEqual(reopened.popup?.terminal_id, "new-popup")
        XCTAssertEqual(reopened.popup?.frame.cells.first?.symbol, "R")
    }

    func testDeltaRejectsUnnegotiatedOverlappingUnsortedAndInvalidLinkWithoutAdvancing() throws {
        let good = try deltaBytes(rows: [(0, 0, ["X"])])
        var disabled = try reuseDecoder()
        _ = try disabled.decode(.surface(scrollBaseline()))
        XCTAssertThrowsError(try disabled.decode(deltaMessage(good)))
        var badLink = good
        badLink[badLink.count - 2] = 1
        badLink.insert(0, at: badLink.count - 1)
        let bad = [good + Data([0]), badLink,
            try deltaBytes(baseSurface: 1), try deltaBytes(baseProjection: 1),
            try deltaBytes(rows: [(0, 0, ["x"]), (0, 0, ["y"])]),
            try deltaBytes(rows: [(0, 1, ["x"]), (0, 0, ["y"])]),
            try deltaBytes(rows: [(0, 3, ["x"])]), try deltaBytes(rows: [(0, 0, [])]),
            try deltaBytes(popup: .patch("popup", "P"))]
        for bytes in bad {
            var decoder = try reuseDecoder(delta: true)
            _ = try decoder.decode(.surface(scrollBaseline()))
            XCTAssertThrowsError(try decoder.decode(deltaMessage(bytes)))
            XCTAssertNoThrow(try decoder.decode(deltaMessage(good)), "Invalid delta must not advance its baseline")
        }
        var decoder = try reuseDecoder(delta: true)
        XCTAssertThrowsError(try decoder.decode(deltaMessage(good)), "Missing full baseline must reject delta")
    }

    private func scrollBaseline() throws -> HerdrShellSurface {
        guard case .surface(var surface) = try HerdrShellWire.decode(golden("surface_image")) else { throw CLIError("Missing baseline") }
        let cells = ["a", "b", "c", "d", "e", "f"].map {
            HerdrShellCell(symbol: $0, fg: 0, bg: 0, modifier: 0, skip: false, hyperlink: nil)
        }
        surface.frame = .init(cells: cells, width: 2, height: 3, cursor: nil, hyperlinks: [], graphics: Data())
        let rect = HerdrShellRect(x: 0, y: 0, width: 2, height: 3)
        surface.panes = [.init(pane_id: "w5:pA", content_revision: 1, rect: rect, inner_rect: rect, scrollbar_rect: nil,
            scroll: nil, focused: true, mouse_reporting: false, sgr_pixel_mouse: false, alternate_screen_active: false, pixel_width: 16, pixel_height: 48)]
        return surface
    }

    private func scrollBytes(_ regions: [(HerdrShellRect, Int16)], rows: [(UInt16, UInt16, [String])],
                             projection: UInt64 = 251, baseSurface: UInt64 = 65536) throws -> Data {
        var patch = HerdrShellWriter()
        patch.uint(19); try patch.string("boot"); patch.uint(projection); patch.uint(baseSurface); patch.uint(baseSurface + 1)
        patch.uint(UInt64(rows.count))
        for (x, y, cells) in rows {
            patch.uint(UInt64(x)); patch.uint(UInt64(y)); patch.uint(UInt64(cells.count))
            for text in cells {
                try patch.string(text); patch.uint(0); patch.uint(0); patch.uint(0); patch.bool(false); patch.bool(false)
            }
        }
        patch.uint(0); patch.bool(false)
        var result = Data([UInt8(regions.count)])
        for (rect, shift) in regions {
            for value in [rect.x, rect.y, rect.width, rect.height, UInt16(bitPattern: shift)] {
                result.append(UInt8(truncatingIfNeeded: value)); result.append(UInt8(truncatingIfNeeded: value >> 8))
            }
        }
        result.append(framed(patch.data))
        return result
    }
    private func scrollMessage(_ bytes: Data) -> HerdrShellServerMessage {
        .control("endpoint.surface-scroll.v1", bytes.base64EncodedString().replacingOccurrences(of: "=", with: ""))
    }

    func testScrollExpandsUpAndDownIntoFinalDisjointPatchRowsAndFeedsReuse() throws {
        let rect = HerdrShellRect(x: 0, y: 0, width: 2, height: 3)
        for (shift, y, expected) in [(Int16(1), UInt16(2), ["c", "d", "e", "f", "x", "y"]),
                                     (Int16(-1), UInt16(0), ["x", "y", "a", "b", "c", "d"])] {
            var decoder = try reuseDecoder(scroll: true)
            let base = try scrollBaseline()
            _ = try decoder.decode(.surface(base))
            let bytes = try scrollBytes([(rect, shift)], rows: [(0, y, ["x", "y"])])
            guard case .patch(let expanded) = try decoder.decode(scrollMessage(bytes)) else { return XCTFail("Scroll must normalize into a patch") }
            XCTAssertEqual(expanded.rows.count, 3)
            var cells = base.frame.cells
            for row in expanded.rows {
                let start = Int(row.y) * 2 + Int(row.x)
                cells.replaceSubrange(start..<(start + row.cells.count), with: row.cells)
            }
            XCTAssertEqual(cells.map(\.symbol), expected)
            var json = try surfaceReuseJSON()
            json["base_surface_revision"] = 65537
            var surface = try XCTUnwrap(json["surface"] as? [String: Any]); surface["surface_revision"] = 65538
            var frame = try XCTUnwrap(surface["frame"] as? [String: Any]); frame["height"] = 3
            surface["frame"] = frame; json["surface"] = surface
            guard case .surface(let reused) = try decoder.decode(reuseMessage(json)) else { return XCTFail("Expected reuse after scroll") }
            XCTAssertEqual(reused.frame.cells.map(\.symbol), expected)
        }
    }

    func testMixedFullPatchReuseDeltaScrollKeepsOneBaselineAndIndependentPopupGraphics() throws {
        var decoder = try reuseDecoder(scroll: true, delta: true)
        _ = try decoder.decode(.surface(scrollBaseline()))
        _ = try decoder.decode(HerdrShellWire.decode(golden("patch")))
        var json = try surfaceReuseJSON()
        json["base_surface_revision"] = 65537
        var metadata = try XCTUnwrap(json["surface"] as? [String: Any])
        metadata["surface_revision"] = 65538
        var frame = try XCTUnwrap(metadata["frame"] as? [String: Any]); frame["height"] = 3
        metadata["frame"] = frame; json["surface"] = metadata
        guard case .surface(let reused) = try decoder.decode(reuseMessage(json)) else { return XCTFail("Missing reuse") }
        XCTAssertEqual(reused.frame.cells.map(\.symbol), ["x", "b", "c", "d", "e", "f"])
        XCTAssertEqual(reused.popup?.frame.cells.first?.symbol, "P")
        XCTAssertEqual(reused.graphics.assets.count, 2)
        guard case .surface(let delta) = try decoder.decode(deltaMessage(deltaBytes(baseProjection: 252, baseSurface: 65538,
            rows: [(1, 0, ["Z"])], popup: .patch("popup-reuse", "Q")))) else { return XCTFail("Missing delta") }
        XCTAssertEqual(delta.frame.cells.map(\.symbol), ["x", "Z", "c", "d", "e", "f"])
        XCTAssertEqual(delta.popup?.frame.cells.first?.symbol, "Q")
        XCTAssertTrue(delta.graphics.assets.isEmpty, "Old reuse graphics cannot be copied into new delta metadata")
        let region = HerdrShellRect(x: 0, y: 0, width: 2, height: 3)
        guard case .patch(let patch) = try decoder.decode(scrollMessage(scrollBytes([(region, 1)],
            rows: [(0, 2, ["r", "s"])], projection: 253, baseSurface: 65539))) else { return XCTFail("Missing scroll patch") }
        XCTAssertEqual(patch.surface_revision, 65540)
        XCTAssertEqual(patch.rows.flatMap(\.cells).map(\.symbol), ["c", "d", "e", "f", "r", "s"])
        json["base_surface_revision"] = 65540
        metadata["surface_revision"] = 65541; metadata["projection_revision"] = 254
        json["surface"] = metadata
        guard case .surface(let final) = try decoder.decode(reuseMessage(json)) else { return XCTFail("Missing final reuse") }
        XCTAssertEqual(final.frame.cells.map(\.symbol), ["c", "d", "e", "f", "r", "s"])
        XCTAssertEqual(final.popup?.frame.cells.first?.symbol, "P", "A new popup scene is independent of the main grid baseline")
        XCTAssertEqual(final.graphics.assets.count, 2)
        XCTAssertEqual(reused.frame.cells.map(\.symbol), ["x", "b", "c", "d", "e", "f"], "Later updates cannot mutate previously delivered values")
    }

    func testInvalidScrollDoesNotAdvanceBaselineAndRequiresNegotiation() throws {
        let rect = HerdrShellRect(x: 0, y: 0, width: 2, height: 3)
        let good = try scrollBytes([(rect, 1)], rows: [(0, 2, ["x", "y"])])
        var disabled = try reuseDecoder()
        _ = try disabled.decode(.surface(scrollBaseline()))
        XCTAssertThrowsError(try disabled.decode(scrollMessage(good)))
        let bad = [try scrollBytes([(rect, 0)], rows: []), try scrollBytes([(rect, 3)], rows: []),
            try scrollBytes([(rect, Int16.min)], rows: []), try scrollBytes([(rect, 1), (rect, -1)], rows: []),
            try scrollBytes([(rect, 1)], rows: [(0, 3, ["x"])]), good + Data([0]), Data([1, 0])]
        for bytes in bad {
            var decoder = try reuseDecoder(scroll: true)
            _ = try decoder.decode(.surface(scrollBaseline()))
            XCTAssertThrowsError(try decoder.decode(scrollMessage(bytes)))
            XCTAssertNoThrow(try decoder.decode(scrollMessage(good)), "A rejected message must not consume its baseline")
        }
        var decoder = try reuseDecoder(scroll: true)
        XCTAssertThrowsError(try decoder.decode(scrollMessage(good)), "No baseline must reject scroll")
        _ = try decoder.decode(.surface(scrollBaseline()))
        XCTAssertThrowsError(try decoder.decode(.control("endpoint.surface-scroll.v1", "AA==")))
        XCTAssertThrowsError(try decoder.decode(.control("endpoint.surface-scroll.v1", "AB")), "Unused bits must be canonical")
    }

    func testReuseRestoresOnlyMainCellsAndPreservesNewPopupAndGraphics() throws {
        let full = try HerdrShellWire.decode(golden("surface_image"))
        guard case .surface(let base) = full else { return XCTFail("Expected a full surface") }
        var decoder = try reuseDecoder()
        _ = try decoder.decode(full)
        guard case .surface(let restored) = try decoder.decode(reuseMessage(surfaceReuseJSON())) else { return XCTFail("Reuse must normalize into a complete surface") }
        XCTAssertEqual(restored.frame.cells, base.frame.cells)
        XCTAssertEqual(restored.projection_revision, 252)
        XCTAssertEqual(restored.frame.cursor?.x, 1)
        XCTAssertEqual(restored.popup?.frame.cells.first?.symbol, "P")
        XCTAssertEqual(restored.popup?.width, 1)
        XCTAssertEqual(restored.popup?.height, 50)
        XCTAssertEqual(restored.popup?.heightIsPercent, true)
        XCTAssertEqual(restored.graphics.assets.count, 2)
        XCTAssertEqual(restored.graphics.assets.first?.data, Data([0, 0, 255, 255]))
        XCTAssertEqual(restored.graphics.assets.first?.key.data_fingerprint, UInt64.max)
        XCTAssertEqual(restored.graphics.placements.last?.asset.source, .popup("popup-reuse", 8))
        XCTAssertGreaterThan(HerdrShellServerMessage.surface(restored).estimatedDecodedBytes, base.frame.cells.count * MemoryLayout<HerdrShellCell>.stride)
    }

    func testReuseBaselineIncludesPatchesBeforePresentationFiltering() throws {
        var decoder = try reuseDecoder()
        _ = try decoder.decode(HerdrShellWire.decode(golden("surface_image")))
        _ = try decoder.decode(HerdrShellWire.decode(golden("patch")))
        var json = try surfaceReuseJSON()
        json["base_surface_revision"] = 65537
        var surface = try XCTUnwrap(json["surface"] as? [String: Any]); surface["surface_revision"] = 65538
        json["surface"] = surface
        guard case .surface(let restored) = try decoder.decode(reuseMessage(json)) else { return XCTFail("Expected normalized reuse") }
        XCTAssertEqual(restored.frame.cells.first?.symbol, "x")
        XCTAssertEqual(restored.surface_revision, 65538)
    }

    func testReuseRejectsMissingBaselineUnnegotiatedAndMalformedPayloads() throws {
        let original = try surfaceReuseJSON()
        var missing = try reuseDecoder()
        XCTAssertThrowsError(try missing.decode(reuseMessage(original)))
        var disabled = HerdrClientShellSurfaceDecoder()
        XCTAssertThrowsError(try disabled.decode(reuseMessage(original)))
        for mutation in 0..<5 {
            var decoder = try reuseDecoder()
            _ = try decoder.decode(HerdrShellWire.decode(golden("surface_image")))
            var json = original
            var surface = try XCTUnwrap(json["surface"] as? [String: Any])
            var frame = try XCTUnwrap(surface["frame"] as? [String: Any])
            switch mutation {
            case 0: json["base_surface_revision"] = 1
            case 1: surface["boot_id"] = "other"
            case 2: frame["width"] = 3
            case 3: frame["cells"] = [[:]]
            default: frame["hyperlinks"] = []
            }
            surface["frame"] = frame; json["surface"] = surface
            XCTAssertThrowsError(try decoder.decode(reuseMessage(json)))
        }
    }

    func testDecodedSurfaceBudgetChargesCellsAssetsAndMetadataBeyondWireBytes() throws {
        let payload = try golden("surface_image")
        let message = try HerdrShellWire.decode(payload)
        XCTAssertGreaterThan(message.estimatedDecodedBytes, payload.count)
        guard case .surface(var surface) = message else { return XCTFail("Expected a graphics surface") }
        let base = message.estimatedDecodedBytes
        let symbol = surface.frame.cells[0]
        surface.frame = .init(cells: Array(repeating: symbol, count: 1_000_000), width: 2000, height: 500,
            cursor: nil, hyperlinks: [], graphics: Data())
        let expanded = HerdrShellServerMessage.surface(surface).estimatedDecodedBytes
        XCTAssertGreaterThan(expanded, base)
        XCTAssertGreaterThanOrEqual(expanded, 1_000_000 * MemoryLayout<HerdrShellCell>.stride)
        XCTAssertLessThan(expanded, HerdrClientShellTransport.decodedQueueBudget,
            "One valid maximum-sized grid must fit the decoded budget")
        XCTAssertGreaterThan(HerdrShellServerMessage.clipboard(String(repeating: "界", count: 1000)).estimatedDecodedBytes, 3000)
    }

    func testHostColorBytesDoNotUseVarintsForRGBOrPaletteIndices() throws {
        let color = HerdrShellRGB(r: 255, g: 251, b: 254)
        XCTAssertEqual(try HerdrShellClientMessage.defaultColor(background: false, color: color).encoded(),
                       framed(Data([17, 0, 0, 255, 251, 254])))
        XCTAssertEqual(try HerdrShellClientMessage.defaultColor(background: true, color: color).encoded(),
                       framed(Data([17, 0, 1, 255, 251, 254])))
        XCTAssertEqual(try HerdrShellClientMessage.paletteColors([255: .init(r: 0, g: 1, b: 2), 0: color]).encoded(),
                       framed(Data([17, 1, 2, 0, 255, 251, 254, 255, 0, 1, 2])))
        let all = Dictionary(uniqueKeysWithValues: (0...255).map { (UInt8($0), color) })
        let encoded = try HerdrShellClientMessage.paletteColors(all).encoded()
        XCTAssertEqual(Array(encoded.dropFirst(4).prefix(5)), [17, 1, 251, 0, 1], "Only the vector length uses a varint")
        XCTAssertEqual(encoded.count, 4 + 5 + 256 * 4)
    }

    func testHostColorHexParsingRejectsNonRGBThemeValues() {
        XCTAssertEqual(HerdrShellRGB(hex: "#aBcDeF"), .init(r: 171, g: 205, b: 239))
        XCTAssertEqual(HerdrShellRGB(hex: "000000"), .init(r: 0, g: 0, b: 0))
        for value in ["", "fff", "#ffffffff", "+000ff", "0x00ff", " gg0000", "１２３４５６", "#abcdex"] {
            XCTAssertNil(HerdrShellRGB(hex: value), value)
        }
    }

    func testMouseCoordinatesUseInnerGridPixelsAndClampOnlyExistingGestures() throws {
        let grid = TerminalGridMetrics(columns: 10, rows: 5, widthPixels: 160, heightPixels: 160,
                                       cellWidthPixels: 16, cellHeightPixels: 32)
        let pixel = try XCTUnwrap(HerdrClientShellInput.mouse(kind: 0, button: 1, point: .init(x: 15.9, y: 35),
            grid: grid, scale: .init(width: 2, height: 2), pixel: true, flags: [.control, .option, .command]))
        XCTAssertEqual(pixel.column, 1); XCTAssertEqual(pixel.row, 2)
        XCTAssertEqual(pixel.pixels?.0, 31); XCTAssertEqual(pixel.pixels?.1, 70)
        XCTAssertEqual(pixel.geometry?.2, 160); XCTAssertEqual(pixel.geometry?.3, 160)
        XCTAssertEqual(pixel.modifiers, 14)
        XCTAssertNil(HerdrClientShellInput.mouse(kind: 0, button: 0, point: .init(x: -10, y: 100),
            grid: grid, scale: .init(width: 2, height: 2), pixel: false, flags: []))
        let dragged = try XCTUnwrap(HerdrClientShellInput.mouse(kind: 2, button: 0, point: .init(x: -10, y: 100),
            grid: grid, scale: .init(width: 2, height: 2), pixel: false, flags: [], clamp: true))
        XCTAssertEqual(dragged.column, 0); XCTAssertEqual(dragged.row, 4)
        XCTAssertNil(dragged.pixels); XCTAssertNil(dragged.geometry)
        XCTAssertNil(HerdrClientShellInput.mouse(kind: 4, point: .zero, grid: grid, scale: .zero, pixel: true, flags: []))
        XCTAssertNil(HerdrClientShellInput.mouse(kind: 3, point: .init(x: CGFloat.nan, y: 0), grid: grid,
            scale: .init(width: 1, height: 1), pixel: true, flags: []))
    }
    @MainActor
    func testAppKitSemanticKeysPreserveModifiersRepeatReleaseAndOptionText() throws {
        func event(_ code: UInt16, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown,
                   repeatKey: Bool = false, text: String = "a") throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 1,
                windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: repeatKey, keyCode: code))
        }
        let tab = try event(48, flags: [.shift, .control], text: "\t")
        let shiftedTab = try XCTUnwrap(HerdrClientShellInput.key(tab, translated: tab, text: "\t"))
        XCTAssertEqual(shiftedTab.code, 11); XCTAssertEqual(shiftedTab.modifiers, 3); XCTAssertNil(shiftedTab.text)
        let function = try event(111, repeatKey: true, text: "\u{f70f}")
        let f12 = try XCTUnwrap(HerdrClientShellInput.key(function, translated: function, text: function.characters))
        XCTAssertEqual(f12.code, 16); XCTAssertEqual(f12.function, 12); XCTAssertEqual(f12.kind, 1)
        let up = try event(36, type: .keyUp, text: "\r")
        let released = try XCTUnwrap(HerdrClientShellInput.key(up, translated: up, text: "ignored"))
        XCTAssertEqual(released.code, 1); XCTAssertEqual(released.kind, 2); XCTAssertNil(released.text)
        let option = try event(0, flags: .option)
        XCTAssertEqual(HerdrClientShellInput.key(option, translated: option, text: "å")?.modifiers, 0)
        let translated = try event(0)
        XCTAssertEqual(HerdrClientShellInput.key(option, translated: translated, text: "a")?.modifiers, 4,
                       "Option-as-Alt retains Alt while Option-generated text consumes it")
        XCTAssertEqual(HerdrClientShellInput.key(option, translated: option, text: "å")?.text, "å")
        let modifier = try event(56, text: "")
        XCTAssertNil(HerdrClientShellInput.key(modifier, translated: modifier, text: nil))
    }
    private func golden(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/herdr-clientshell-wire-v1.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let payloads = try XCTUnwrap(json["payloads"] as? [String: String])
        let hex = try XCTUnwrap(payloads[name])
        var data = Data(), index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            data.append(try XCTUnwrap(UInt8(hex[index..<end], radix: 16))); index = end
        }
        return data
    }

    private func framed(_ payload: Data) -> Data {
        let n = UInt32(payload.count)
        return Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) + payload
    }

    func testClientWireMatchesIndependentBincodeSerializer() throws {
        let messages: [(String, HerdrShellClientMessage)] = [
            ("control_empty", .control("", "")),
            ("resize", .resize(.init(cols: 289, rows: 77), 8, 16, true)),
            ("request", .request(boot: "boot", json: "{}")),
            ("focus", .focus(true)), ("appearance", .appearance(dark: true)), ("detach", .detach),
            ("text", .input(target: "w5:pA", popup: false, events: [.text("你好")])),
            ("paste", .input(target: "w5:pA", popup: false, events: [.paste("x\ny")])),
            ("key_char", .input(target: "w5:pA", popup: false, events: [.key(.init(code: 15, character: "é", modifiers: 4,
                shiftedCodepoint: 201, text: "é", tracksRelease: true, physicalKeyID: 12))])),
            ("key_enter", .input(target: "w5:pA", popup: false, events: [.key(.init(code: 1, kind: 2,
                tracksRelease: true, physicalKeyID: 36))])),
            ("mouse", .input(target: "w5:pA", popup: false, events: [.mouse(.init(kind: 0, button: 0, column: 2, row: 2,
                pixels: (16, 32), geometry: (80, 24, 640, 384), modifiers: 4))]))
        ]
        for (name, message) in messages { XCTAssertEqual(try message.encoded(), framed(try golden(name)), name) }
        XCTAssertThrowsError(try HerdrShellClientMessage.input(target: "x", popup: false, events: [.key(.init(code: 15))]).encoded())
        XCTAssertThrowsError(try HerdrShellClientMessage.resize(.init(cols: 0, rows: 24), 8, 16, false).encoded())
    }

    func testEverySemanticKeyMatchesUpstreamVariantOrder() throws {
        let events = (UInt32(0)...17).map { code in
            HerdrShellInput.key(.init(code: code, character: code == 15 ? "界" : nil,
                                     function: code == 16 ? 12 : nil))
        }
        XCTAssertEqual(try HerdrShellClientMessage.input(target: "w5:pA", popup: false, events: events).encoded(),
                       framed(try golden("all_keys")))
        for key in [HerdrShellInput.Key(code: 18), .init(code: 19), .init(code: 17, character: "x"),
                    .init(code: 16), .init(code: 15, function: 1)] {
            XCTAssertThrowsError(try HerdrShellClientMessage.input(target: "x", popup: false, events: [.key(key)]).encoded())
        }
    }

    func testImageSurfaceAndPatchDecodeIndependentWire() throws {
        guard case let .surface(surface) = try HerdrShellWire.decode(golden("surface_image")) else { return XCTFail("Missing surface") }
        XCTAssertEqual(surface.projection_revision, 251)
        XCTAssertEqual(surface.surface_revision, 65536)
        XCTAssertEqual(surface.frame.cells.map(\.symbol), ["界", ""])
        XCTAssertEqual(surface.frame.cells[0].fg, 0x02112233)
        XCTAssertEqual(surface.frame.hyperlinks, ["https://example.com"])
        XCTAssertEqual(surface.panes[0].scroll?.max_offset_from_bottom, 10)
        XCTAssertEqual(surface.graphics.assets[0].data, Data([255, 0, 0, 255]))
        XCTAssertEqual(surface.graphics.placements[0].z, -1)
        XCTAssertEqual(surface.graphics.placements[0].asset.source, .pane("w5:pA", 7))
        XCTAssertEqual(surface.graphics.retained_assets, [surface.graphics.assets[0].key])
        guard case let .patch(patch) = try HerdrShellWire.decode(golden("patch")) else { return XCTFail("Missing patch") }
        XCTAssertEqual(patch.base_surface_revision, 65536)
        XCTAssertEqual(patch.surface_revision, 65537)
        XCTAssertEqual(patch.rows[0].cells[0].symbol, "x")
        guard case let .notification(notice) = try HerdrShellWire.decode(golden("notification")) else { return XCTFail("Missing notification") }
        XCTAssertEqual(notice.pane_id, "w5:pA")
        XCTAssertEqual(notice.position, 3)
    }

    func testFragmentedAndBatchedFramesAndTruncation() throws {
        let bytes = framed(try golden("surface_image")) + framed(try golden("response")) + framed(try golden("shutdown"))
        var wire = HerdrShellWire(), messages: [HerdrShellServerMessage] = []
        for byte in bytes { messages += try wire.append(Data([byte])) }
        XCTAssertEqual(messages.count, 3)
        try wire.finish()
        var batched = HerdrShellWire()
        XCTAssertEqual(try batched.append(bytes), messages)
        XCTAssertEqual(messages[1], .response(boot: "boot", request: "r1", final: true, data: Data("{\"id\":\"r1\"}".utf8)))
        _ = try wire.append(Data([1]))
        XCTAssertThrowsError(try wire.finish())
    }

    func testMalformedLengthsCollectionsUTF8AndTrailingBytesAreRejected() throws {
        for bytes in [Data([20, 0, 0, 1]), Data([20, 1, 255, 0]), Data([20, 253] + Array(repeating: 255, count: 8)),
                      Data([99]), Data([8, 2, 0]), Data([13, 0])] {
            XCTAssertThrowsError(try HerdrShellWire.decode(bytes))
        }
        let image = try golden("surface_image")
        for end in 0..<image.count { XCTAssertThrowsError(try HerdrShellWire.decode(image.prefix(end))) }
        var wire = HerdrShellWire()
        XCTAssertThrowsError(try wire.append(Data([255, 255, 255, 255])))
        var empty = HerdrShellWire()
        XCTAssertThrowsError(try empty.append(Data([0, 0, 0, 0])))
        var reader = HerdrShellReader(data: Data([252, 0, 0, 1, 0]))
        XCTAssertThrowsError(try reader.u16())
    }

    func testHandshakeUsesCodecsAndCapabilitiesNotBuildVersion() throws {
        let welcome = """
        {"generation":1,"server_version":"future-build","snapshot_codec":"shell.snapshot.v1",\
        "surface_codec":"shell.surface.v1","input_codec":"shell.input.semantic.v1","blob_codec":"shell.blob.v1",\
        "capabilities":["surface_interest"],"methods":[],"future":true}
        """
        try JSONDecoder().decode(HerdrShellWelcome.self, from: Data(welcome.utf8)).validate()
        XCTAssertThrowsError(try JSONDecoder().decode(HerdrShellWelcome.self,
            from: Data(welcome.replacingOccurrences(of: "shell.surface.v1", with: "shell.surface.v2").utf8)).validate())
        XCTAssertThrowsError(try JSONDecoder().decode(HerdrShellWelcome.self,
            from: Data(welcome.replacingOccurrences(of: "surface_interest", with: "other").utf8)).validate())
        let hello = HerdrShellHello(cell_width_px: 8, cell_height_px: 16, surface_size: .init(cols: 80, rows: 24), pixel_mouse: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as? [String: Any])
        XCTAssertEqual(json["surface_active"] as? Bool, false)
        XCTAssertEqual(json["direct_graphics"] as? Bool, false)
        XCTAssertEqual(json["endpoint_keybindings"] as? Bool, false)
    }
}
