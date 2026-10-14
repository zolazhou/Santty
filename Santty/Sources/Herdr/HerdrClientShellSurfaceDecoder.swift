import Foundation

// Connection-owned generation-1 baseline; Herdr 2563803, protocol/surface_reuse.rs (Apache-2.0).
struct HerdrClientShellSurfaceDecoder {
    private struct Reuse: Decodable {
        let base_surface_revision: UInt64
        let surface: HerdrShellSurface
    }
    private struct PopupBaseline {
        let terminalID: String
        let width: UInt16
        let height: UInt16
        let frame: HerdrShellFrame
    }
    private struct Baseline {
        let boot: String
        let projection: UInt64
        var revision: UInt64
        let width: UInt16
        let height: UInt16
        var frame: HerdrShellFrame
        var damage: HerdrShellSurface.Damage?
        let panes: [HerdrShellPane]
        let popup: PopupBaseline?
        init(_ surface: HerdrShellSurface) {
            boot = surface.boot_id; projection = surface.projection_revision; revision = surface.surface_revision
            width = surface.frame.width; height = surface.frame.height; frame = surface.frame; damage = surface.damage; panes = surface.panes
            popup = surface.popup.map {
                .init(terminalID: $0.terminal_id, width: $0.frame.width, height: $0.frame.height, frame: $0.frame)
            }
        }
    }
    private var baseline: Baseline?
    private let requestedReuse: Bool
    private var negotiatedReuse = false
    private let requestedScroll: Bool
    private var negotiatedScroll = false
    private let requestedDelta: Bool
    private var negotiatedDelta = false

    init(requestedReuse: Bool = false, requestedScroll: Bool = false, requestedDelta: Bool = false) {
        self.requestedReuse = requestedReuse; self.requestedScroll = requestedScroll; self.requestedDelta = requestedDelta
    }

    mutating func decode(_ message: HerdrShellServerMessage) throws -> HerdrShellServerMessage {
        switch message {
        case .control("endpoint.welcome.v1", let data):
            let welcome = try JSONDecoder().decode(HerdrShellWelcome.self, from: Data(data.utf8))
            try welcome.validate()
            negotiatedReuse = requestedReuse && welcome.capabilities?.contains("surface_reuse") == true
            negotiatedScroll = requestedScroll && welcome.capabilities?.contains("surface_scroll") == true
            negotiatedDelta = requestedDelta && welcome.capabilities?.contains("surface_delta") == true
            return message
        case .control("endpoint.surface-reuse.v1", let data):
            guard negotiatedReuse else { throw CLIError("Herdr surface reuse was not negotiated") }
            guard data.utf8.count <= HerdrShellWire.maximumStringBytes else { throw CLIError("Herdr surface reuse exceeds budget") }
            let reuse = try JSONDecoder().decode(Reuse.self, from: Data(data.utf8))
            guard let base = baseline, base.revision < UInt64.max,
                  base.boot == reuse.surface.boot_id, base.revision == reuse.base_surface_revision,
                  reuse.surface.surface_revision == base.revision + 1,
                  base.width == reuse.surface.frame.width, base.height == reuse.surface.frame.height,
                  reuse.surface.frame.cellCount == 0 else { throw CLIError("Herdr surface reuse does not match its baseline") }
            var restored = reuse.surface
            restored.frame.reuseCells(from: base.frame)
            restored.damage = base.damage
            restored.hasRetainedCells = true
            try restored.validateWireSurface(extendedMetadata: negotiatedDelta, sharedMainCells: true)
            restored.recordCellDamage([], previousPanes: base.panes)
            baseline = Baseline(restored)
            return .surface(restored)
        case .control("endpoint.surface-scroll.v1", let data):
            guard negotiatedScroll else { throw CLIError("Herdr surface scroll was not negotiated") }
            return try .patch(decodeScroll(data))
        case .control("endpoint.surface-delta.v1", let data):
            guard negotiatedDelta else { throw CLIError("Herdr surface delta was not negotiated") }
            return try .surface(decodeDelta(data))
        case .surface(var surface):
            guard negotiatedReuse || negotiatedScroll || negotiatedDelta else { return message }
            try surface.validateWireSurface()
            surface.damage = nil; surface.hasRetainedCells = false
            surface.recordCellDamage([])
            baseline = Baseline(surface)
            return .surface(surface)
        case .patch(let patch):
            guard negotiatedReuse || negotiatedScroll || negotiatedDelta, var base = baseline else { return message }
            guard base.revision < UInt64.max, patch.boot_id == base.boot,
                  patch.projection_revision == base.projection,
                  patch.base_surface_revision == base.revision, patch.surface_revision == base.revision + 1 else {
                baseline = nil
                return message
            }
            for row in patch.rows {
                guard row.y < base.height, Int(row.x) + row.cells.count <= Int(base.width) else {
                    throw CLIError("Herdr patch exceeds the cell baseline")
                }
            }
            for row in patch.rows {
                base.frame.replaceCells(row.cells, x: Int(row.x), y: Int(row.y))
                base.damage?.mark(.init(x: row.x, y: row.y, width: UInt16(row.cells.count), height: 1),
                                  panes: base.panes, revision: patch.surface_revision)
            }
            base.revision = patch.surface_revision
            baseline = base
            return message
        default: return message
        }
    }
    private mutating func decodeDelta(_ text: String) throws -> HerdrShellSurface {
        guard let base = baseline else { throw CLIError("Herdr surface delta without a baseline") }
        let bytes = try Self.unpaddedBase64(text, maximumEncodedBytes: HerdrShellWire.maximumFrameBytes)
        var reader = HerdrShellReader(data: bytes)
        let projection = try reader.uint(), revision = try reader.uint()
        var surface = try reader.surface(omittingCells: true)
        let hasGraphics = !surface.graphics.assets.isEmpty || !surface.graphics.placements.isEmpty || !surface.graphics.retained_assets.isEmpty
        guard hasGraphics || text.utf8.count <= 2 * 1024 * 1024 else { throw CLIError("Ordinary Herdr surface delta exceeds budget") }
        guard base.revision < UInt64.max, surface.boot_id == base.boot, projection == base.projection, revision == base.revision,
              surface.surface_revision == base.revision + 1, surface.projection_revision >= base.projection,
              surface.frame.width == base.width, surface.frame.height == base.height else {
            throw CLIError("Herdr surface delta does not match its baseline")
        }
        let rows = try Self.deltaRows(&reader, width: base.width, height: base.height)
        surface.frame.reuseCells(from: base.frame)
        Self.applyDeltaRows(rows, to: &surface.frame)
        surface.damage = base.damage
        surface.hasRetainedCells = true
        let popupUpdate = try reader.bool()
        if popupUpdate {
            guard var popup = surface.popup else { throw CLIError("Herdr popup delta has no metadata") }
            switch try reader.uint(maximum: 1) {
            case 0:
                let rows = try Self.deltaRows(&reader, width: popup.frame.width, height: popup.frame.height)
                guard let previous = base.popup, previous.terminalID == popup.terminal_id,
                      previous.width == popup.frame.width, previous.height == popup.frame.height else {
                    throw CLIError("Herdr popup delta does not match its baseline")
                }
                popup.frame.reuseCells(from: previous.frame)
                Self.applyDeltaRows(rows, to: &popup.frame)
            default:
                let count = Int(popup.frame.width) * Int(popup.frame.height)
                guard try reader.uint(maximum: UInt64(count)) == UInt64(count), count <= reader.remaining / 6 else {
                    throw CLIError("Herdr popup replacement does not match its grid")
                }
                var cells: [HerdrShellCell] = []; cells.reserveCapacity(count)
                for _ in 0..<count { cells.append(try reader.cell()) }
                popup.frame.cells = cells
            }
            surface.popup = popup
        } else if surface.popup != nil { throw CLIError("Herdr popup delta update is missing") }
        guard reader.remaining == 0 else { throw CLIError("Trailing Herdr surface delta bytes") }
        try surface.validateWireSurface(extendedMetadata: true, sharedMainCells: true)
        surface.recordCellDamage(rows, previousPanes: base.panes)
        baseline = Baseline(surface)
        return surface
    }

    private static func deltaRows(_ reader: inout HerdrShellReader, width: UInt16, height: UInt16) throws -> [HerdrShellPatch.Row] {
        let budget = Int(width) * Int(height)
        let count = Int(try reader.uint(maximum: UInt64(min(4096, budget))))
        guard count <= reader.remaining / 9 else { throw CLIError("Truncated Herdr surface delta spans") }
        var result: [HerdrShellPatch.Row] = []; result.reserveCapacity(count)
        var previousEnd = 0, total = 0
        for _ in 0..<count {
            let x = try reader.u16(), y = try reader.u16()
            guard x < width, y < height else { throw CLIError("Herdr delta span is outside its row") }
            let length = Int(try reader.uint(maximum: UInt64(width - x)))
            let start = Int(y) * Int(width) + Int(x)
            guard length > 0, start >= previousEnd, length <= reader.remaining / 6, length <= budget - total else {
                throw CLIError("Herdr delta spans overlap, are unsorted or exceed budget")
            }
            var cells: [HerdrShellCell] = []; cells.reserveCapacity(length)
            for _ in 0..<length { cells.append(try reader.cell()) }
            result.append(.init(x: x, y: y, cells: cells))
            total += length; previousEnd = start + length
        }
        return result
    }

    private static func applyDeltaRows(_ rows: [HerdrShellPatch.Row], to frame: inout HerdrShellFrame) {
        for row in rows { frame.replaceCells(row.cells, x: Int(row.x), y: Int(row.y)) }
    }

    private mutating func decodeScroll(_ text: String) throws -> HerdrShellPatch {
        guard var base = baseline else { throw CLIError("Herdr surface scroll without a baseline") }
        let ordinaryLimit = 2 * 1024 * 1024
        let bytes = try Self.unpaddedBase64(text, maximumEncodedBytes: (ordinaryLimit * 4 + 2) / 3)
        guard bytes.count <= ordinaryLimit, let countByte = bytes.first, countByte > 0, countByte <= 64 else {
            throw CLIError("Invalid Herdr surface scroll count or budget")
        }
        let count = Int(countByte), header = 1 + Int(countByte) * 10
        guard bytes.count >= header + 4 else { throw CLIError("Truncated Herdr surface scroll") }
        func word(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        let scrolls = (0..<count).map { index -> HerdrShellPatch.Scroll in
            let at = 1 + index * 10
            return .init(rect: .init(x: word(at), y: word(at + 2), width: word(at + 4), height: word(at + 6)),
                         shift: Int(Int16(bitPattern: word(at + 8))))
        }
        var length: UInt32 = 0
        for index in 0..<4 { length |= UInt32(bytes[header + index]) << (index * 8) }
        guard length > 0, Int(length) <= ordinaryLimit, Int(length) == bytes.count - header - 4,
              case .patch(let patch) = try HerdrShellWire.decode(bytes.subdata(in: (header + 4)..<bytes.count)) else {
            throw CLIError("Herdr surface scroll must contain exactly one pane patch")
        }
        guard base.revision < UInt64.max, patch.boot_id == base.boot, patch.projection_revision == base.projection,
              patch.base_surface_revision == base.revision, patch.surface_revision == base.revision + 1,
              base.frame.cellCount == Int(base.width) * Int(base.height) else {
            throw CLIError("Herdr surface scroll does not match its baseline")
        }
        let area = HerdrShellRect(x: 0, y: 0, width: base.width, height: base.height)
        for (index, scroll) in scrolls.enumerated() {
            let rect = scroll.rect
            guard rect.width > 0, rect.height >= 2, scroll.shift != 0, abs(scroll.shift) < Int(rect.height), area.contains(rect) else {
                throw CLIError("Herdr surface scroll exceeds its grid")
            }
            for other in scrolls.dropFirst(index + 1) {
                let b = other.rect
                guard !(Int(rect.x) < Int(b.x) + Int(b.width) && Int(b.x) < Int(rect.x) + Int(rect.width)
                    && Int(rect.y) < Int(b.y) + Int(b.height) && Int(b.y) < Int(rect.y) + Int(rect.height)) else {
                    throw CLIError("Herdr surface scroll regions overlap")
                }
            }
        }
        for row in patch.rows {
            guard row.y < base.height, Int(row.x) + row.cells.count <= Int(base.width) else {
                throw CLIError("Herdr surface scroll patch exceeds its grid")
            }
        }
        // Keep the operation compact through projection instead of expanding moved cells.
        for scroll in scrolls { base.frame.scroll(scroll.rect, by: scroll.shift) }
        Self.applyDeltaRows(patch.rows, to: &base.frame)
        for row in patch.rows {
            base.damage?.mark(.init(x: row.x, y: row.y, width: UInt16(row.cells.count), height: 1),
                              panes: base.panes, revision: patch.surface_revision)
        }
        for scroll in scrolls { base.damage?.mark(scroll.rect, panes: base.panes, revision: patch.surface_revision) }
        var compact = patch
        compact.scrolls = scrolls
        base.revision = patch.surface_revision
        baseline = base
        return compact
    }

    private static func unpaddedBase64(_ text: String, maximumEncodedBytes: Int) throws -> Data {
        guard !text.isEmpty, text.utf8.count <= maximumEncodedBytes, text.utf8.count % 4 != 1,
              text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47 }) else {
            throw CLIError("Invalid or oversized Herdr surface codec base64")
        }
        let padding = (4 - text.utf8.count % 4) % 4
        guard let bytes = Data(base64Encoded: text + String(repeating: "=", count: padding)),
              bytes.base64EncodedString().replacingOccurrences(of: "=", with: "") == text else {
            throw CLIError("Noncanonical Herdr surface codec base64")
        }
        return bytes
    }
}

private struct HerdrShellJSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension HerdrShellFrame: Decodable {
    private enum CodingKeys: String, CodingKey { case cells, width, height, cursor, hyperlinks, graphics }
    private struct JSONCursor: Decodable {
        let x: UInt16; let y: UInt16; let visible: Bool; let shape: UInt8?
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let width = try values.decode(UInt16.self, forKey: .width), height = try values.decode(UInt16.self, forKey: .height)
        guard width > 0, height > 0, Int(width) * Int(height) <= 1_048_576 else { throw CLIError("Herdr JSON grid exceeds budget") }
        var items = try values.nestedUnkeyedContainer(forKey: .cells)
        guard let count = items.count, count == 0 || count == Int(width) * Int(height) else { throw CLIError("Invalid Herdr JSON cell count") }
        var cells: [HerdrShellCell] = []; cells.reserveCapacity(count)
        while !items.isAtEnd { cells.append(try items.decode(HerdrShellCell.self)) }
        let rawCursor = try values.decodeIfPresent(JSONCursor.self, forKey: .cursor)
        self.init(cells: cells, width: width, height: height,
            cursor: rawCursor.map { .init(x: $0.x, y: $0.y, visible: $0.visible, shape: $0.shape ?? 0) },
            hyperlinks: try values.decode([String].self, forKey: .hyperlinks),
            graphics: Data(try values.decode([UInt8].self, forKey: .graphics)))
    }

    func validateWireFrame(extendedMetadata: Bool = false, sharedCells: Bool = false) throws {
        guard width > 0, height > 0, cellCount == Int(width) * Int(height), cellCount <= 1_048_576,
              hyperlinks.count <= (extendedMetadata ? 65536 : 4096), hyperlinks.allSatisfy({ $0.utf8.count <= HerdrShellWire.maximumStringBytes }),
              maximumHyperlink.map({ Int($0) < hyperlinks.count }) ?? true,
              sharedCells || (0..<Int(height)).allSatisfy({ cells(in: $0).allSatisfy { $0.symbol.utf8.count <= HerdrShellWire.maximumStringBytes } }),
              graphics.count <= HerdrShellWire.maximumFrameBytes,
              cursor.map({ $0.shape <= 6 && (!$0.visible || ($0.x < width && $0.y < height)) }) ?? true
        else { throw CLIError("Invalid Herdr surface grid") }
    }
}

extension HerdrShellSplit: Decodable {
    private enum CodingKeys: String, CodingKey { case direction, pos, area, hit_rect, path }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let direction = try values.decode(String.self, forKey: .direction)
        guard direction == "Horizontal" || direction == "Vertical" else { throw CLIError("Unknown Herdr split direction") }
        self.init(horizontal: direction == "Horizontal", pos: try values.decode(UInt16.self, forKey: .pos),
            area: try values.decode(HerdrShellRect.self, forKey: .area), hit_rect: try values.decode(HerdrShellRect.self, forKey: .hit_rect),
            path: try values.decode([Bool].self, forKey: .path))
    }
}

extension HerdrShellGraphicsSource: Decodable {
    private enum CodingKeys: String, CodingKey { case Terminal, PaneLayer, Pane, Popup, target, image_id, pane_id, terminal_id, layer_id }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try decoder.container(keyedBy: HerdrShellJSONKey.self).allKeys.count == 1 else { throw CLIError("Invalid Herdr graphics source") }
        if values.contains(.Terminal) {
            let terminal = try values.nestedContainer(keyedBy: CodingKeys.self, forKey: .Terminal)
            let target = try terminal.nestedContainer(keyedBy: CodingKeys.self, forKey: .target)
            guard try terminal.nestedContainer(keyedBy: HerdrShellJSONKey.self, forKey: .target).allKeys.count == 1 else {
                throw CLIError("Invalid Herdr graphics target")
            }
            let image = try terminal.decode(UInt32.self, forKey: .image_id)
            guard target.allKeys.count == 1 else { throw CLIError("Invalid Herdr graphics target") }
            if target.contains(.Pane) {
                self = .pane(try target.nestedContainer(keyedBy: CodingKeys.self, forKey: .Pane).decode(String.self, forKey: .pane_id), image)
            } else if target.contains(.Popup) {
                self = .popup(try target.nestedContainer(keyedBy: CodingKeys.self, forKey: .Popup).decode(String.self, forKey: .terminal_id), image)
            } else { throw CLIError("Unknown Herdr graphics target") }
        } else if values.contains(.PaneLayer) {
            let layer = try values.nestedContainer(keyedBy: CodingKeys.self, forKey: .PaneLayer)
            self = .layer(try layer.decode(String.self, forKey: .pane_id), try layer.decode(String.self, forKey: .layer_id))
        } else { throw CLIError("Unknown Herdr graphics source") }
    }
}

extension HerdrShellAssetKey: Decodable {
    private enum CodingKeys: String, CodingKey { case source, image_width, image_height, format, data_len, data_fingerprint }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = try values.decode(String.self, forKey: .format)
        let format: UInt32
        switch name { case "Rgb": format = 0; case "Rgba": format = 1; case "Png": format = 2
        default: throw CLIError("Unknown Herdr image format") }
        self.init(source: try values.decode(HerdrShellGraphicsSource.self, forKey: .source),
            image_width: try values.decode(UInt32.self, forKey: .image_width), image_height: try values.decode(UInt32.self, forKey: .image_height),
            format: format, data_len: try values.decode(UInt64.self, forKey: .data_len), data_fingerprint: try values.decode(UInt64.self, forKey: .data_fingerprint))
    }
    func validateWireAsset() throws {
        guard image_width > 0, image_height > 0, format <= 2, data_len <= UInt64(HerdrShellWire.maximumFrameBytes),
              UInt64(image_width) * UInt64(image_height) <= 64 * 1024 * 1024 else { throw CLIError("Herdr image exceeds dimensions or byte budget") }
        if format < 2 {
            guard UInt64(image_width) * UInt64(image_height) * (format == 0 ? 3 : 4) == data_len else { throw CLIError("Invalid Herdr raw image length") }
        }
    }
}

extension HerdrShellAsset: Decodable {
    private enum CodingKeys: String, CodingKey { case key, data }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try values.decode(HerdrShellAssetKey.self, forKey: .key), data: Data(try values.decode([UInt8].self, forKey: .data)))
    }
}

extension HerdrShellPopup: Decodable {
    private enum CodingKeys: String, CodingKey { case terminal_id, title, width, height, frame, mouse_reporting, sgr_pixel_mouse, pixel_width, pixel_height, Cells, Percent }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func size(_ key: CodingKeys) throws -> (UInt16?, Bool) {
            if !values.contains(key) { return (nil, false) }
            if try values.decodeNil(forKey: key) { return (nil, false) }
            let value = try values.nestedContainer(keyedBy: CodingKeys.self, forKey: key)
            guard try values.nestedContainer(keyedBy: HerdrShellJSONKey.self, forKey: key).allKeys.count == 1 else { throw CLIError("Invalid Herdr popup size") }
            if value.contains(.Cells) { return (try value.decode(UInt16.self, forKey: .Cells), false) }
            if value.contains(.Percent) { return (UInt16(try value.decode(UInt8.self, forKey: .Percent)), true) }
            throw CLIError("Unknown Herdr popup size")
        }
        let width = try size(.width), height = try size(.height)
        self.init(terminal_id: try values.decode(String.self, forKey: .terminal_id), title: try values.decode(String.self, forKey: .title),
            width: width.0, height: height.0, widthIsPercent: width.1, heightIsPercent: height.1,
            frame: try values.decode(HerdrShellFrame.self, forKey: .frame), mouse_reporting: try values.decode(Bool.self, forKey: .mouse_reporting),
            sgr_pixel_mouse: try values.decode(Bool.self, forKey: .sgr_pixel_mouse), pixel_width: try values.decode(UInt32.self, forKey: .pixel_width),
            pixel_height: try values.decode(UInt32.self, forKey: .pixel_height))
    }
}

extension HerdrShellSurface {
    func validateWireSurface(extendedMetadata: Bool = false, sharedMainCells: Bool = false) throws {
        try frame.validateWireFrame(extendedMetadata: extendedMetadata, sharedCells: sharedMainCells)
        let area = HerdrShellRect(x: 0, y: 0, width: frame.width, height: frame.height)
        guard !boot_id.isEmpty, boot_id.utf8.count <= HerdrShellWire.maximumStringBytes,
              panes.count <= 4096, splits.count <= 4096, Set(panes.map(\.pane_id)).count == panes.count,
              panes.allSatisfy({ !$0.pane_id.isEmpty && $0.pane_id.utf8.count <= HerdrShellWire.maximumStringBytes
                  && area.contains($0.rect) && $0.rect.contains($0.inner_rect) }),
              splits.allSatisfy({ $0.path.count <= (extendedMetadata ? 4096 : 64) && area.contains($0.area) && area.contains($0.hit_rect) }),
              graphics.assets.count <= 4096, graphics.placements.count <= (extendedMetadata ? 65536 : 4096), graphics.retained_assets.count <= (extendedMetadata ? 65536 : 4096),
              Set(graphics.assets.map(\.key)).count == graphics.assets.count else { throw CLIError("Invalid Herdr surface topology") }
        if let popup {
            try popup.frame.validateWireFrame(extendedMetadata: extendedMetadata)
            guard !popup.terminal_id.isEmpty, popup.terminal_id.utf8.count <= HerdrShellWire.maximumStringBytes, popup.title.utf8.count <= HerdrShellWire.maximumStringBytes else {
                throw CLIError("Herdr popup exceeds string budget")
            }
        }
        for asset in graphics.assets {
            try asset.key.validateWireAsset()
            guard UInt64(asset.data.count) == asset.key.data_len else { throw CLIError("Herdr image asset length mismatch") }
        }
        for key in graphics.retained_assets { try key.validateWireAsset() }
        for placement in graphics.placements {
            try placement.asset.validateWireAsset()
            guard placement.cols > 0, placement.rows > 0, placement.source_width > 0, placement.source_height > 0,
                  UInt64(placement.source_x) + UInt64(placement.source_width) <= UInt64(placement.asset.image_width),
                  UInt64(placement.source_y) + UInt64(placement.source_height) <= UInt64(placement.asset.image_height) else {
                throw CLIError("Invalid Herdr image placement")
            }
        }
    }
}
