import Foundation

// Endpoint generation 1; wire order is frozen independently of Herdr's private protocol version.
// Source: herdrdev/herdr 2563803, src/protocol/{wire,endpoint}.rs (Apache-2.0).
struct HerdrShellHello: Encodable, Sendable {
    static let requestSurfaceReuse = false
    static let requestSurfaceScroll = false
    static let requestSurfaceDelta = false
    let generation = 1
    let cell_width_px: UInt32
    let cell_height_px: UInt32
    let surface_size: HerdrShellSize
    let pixel_mouse: Bool
    let direct_graphics = false
    let endpoint_keybindings = false
    let mouse_capture = true
    let surface_active = false
    let surface_reuse = Self.requestSurfaceReuse
    let surface_delta = Self.requestSurfaceDelta
    let surface_scroll = Self.requestSurfaceScroll
    let snapshot_codecs = ["shell.snapshot.v1"]
    let surface_codecs = ["shell.surface.v1"]
    let input_codecs = ["shell.input.semantic.v1"]
    let blob_codecs = ["shell.blob.v1"]
}

struct HerdrShellSize: Codable, Sendable, Equatable {
    let cols: UInt16
    let rows: UInt16
}

struct HerdrShellWelcome: Decodable, Sendable {
    struct Failure: Decodable, Sendable { let code: String; let message: String }
    let generation: Int
    let server_version: String
    let snapshot_codec: String
    let surface_codec: String
    let input_codec: String
    let blob_codec: String
    let methods: [String]?
    let capabilities: [String]?
    let error: Failure?

    func validate() throws {
        if let error { throw CLIError("Herdr endpoint rejected connection: \(error.message)") }
        guard generation == 1, snapshot_codec == "shell.snapshot.v1", surface_codec == "shell.surface.v1",
              input_codec == "shell.input.semantic.v1", blob_codec == "shell.blob.v1",
              capabilities?.contains("surface_interest") == true
        else { throw CLIError("Herdr does not support the required ClientShell codecs and surface lifecycle") }
    }
}

struct HerdrShellRect: Codable, Sendable, Equatable {
    let x: UInt16; let y: UInt16; let width: UInt16; let height: UInt16
    func contains(_ other: Self) -> Bool {
        Int(other.x) >= Int(x) && Int(other.y) >= Int(y)
            && Int(other.x) + Int(other.width) <= Int(x) + Int(width)
            && Int(other.y) + Int(other.height) <= Int(y) + Int(height)
    }
}

struct HerdrShellCell: Codable, Sendable, Equatable {
    let symbol: String
    let fg: UInt32; let bg: UInt32
    let modifier: UInt16
    let skip: Bool
    let hyperlink: UInt32?
}

struct HerdrShellCursor: Codable, Sendable, Equatable {
    let x: UInt16; let y: UInt16
    let visible: Bool
    let shape: UInt8
}

struct HerdrShellFrame: Sendable, Equatable {
    var cells: [HerdrShellCell]
    let width: UInt16; let height: UInt16
    var cursor: HerdrShellCursor?
    let hyperlinks: [String]
    let graphics: Data
}

struct HerdrShellScroll: Codable, Sendable, Equatable {
    let offset_from_bottom: UInt64
    let max_offset_from_bottom: UInt64
    let viewport_rows: UInt64
}

struct HerdrShellPane: Decodable, Sendable, Equatable {
    let pane_id: String
    let content_revision: UInt64
    let rect: HerdrShellRect
    let inner_rect: HerdrShellRect
    let scrollbar_rect: HerdrShellRect?
    let scroll: HerdrShellScroll?
    let focused: Bool
    let mouse_reporting: Bool
    let sgr_pixel_mouse: Bool
    let alternate_screen_active: Bool
    let pixel_width: UInt32; let pixel_height: UInt32
}

struct HerdrShellSplit: Sendable, Equatable {
    let horizontal: Bool
    let pos: UInt16
    let area: HerdrShellRect
    let hit_rect: HerdrShellRect
    let path: [Bool]
}

enum HerdrShellGraphicsSource: Sendable, Hashable {
    case pane(String, UInt32)
    case popup(String, UInt32)
    case layer(String, String)
}

struct HerdrShellAssetKey: Sendable, Hashable {
    let source: HerdrShellGraphicsSource
    let image_width: UInt32; let image_height: UInt32
    let format: UInt32
    let data_len: UInt64
    let data_fingerprint: UInt64
}

struct HerdrShellAsset: Sendable, Equatable {
    let key: HerdrShellAssetKey
    let data: Data
}

struct HerdrShellPlacement: Decodable, Sendable, Equatable {
    let asset: HerdrShellAssetKey
    let logical_placement_id: UInt32
    let x: UInt16; let y: UInt16
    let cols: UInt32; let rows: UInt32
    let source_x: UInt32; let source_y: UInt32
    let source_width: UInt32; let source_height: UInt32
    let x_offset: UInt32; let y_offset: UInt32
    let z: Int32
    let scrollback_offset: UInt32
}

struct HerdrShellGraphics: Decodable, Sendable, Equatable {
    let assets: [HerdrShellAsset]
    let placements: [HerdrShellPlacement]
    let retained_assets: [HerdrShellAssetKey]
}

struct HerdrShellPopup: Sendable, Equatable {
    let terminal_id: String
    let title: String
    let width: UInt16?; let height: UInt16?
    let widthIsPercent: Bool; let heightIsPercent: Bool
    var frame: HerdrShellFrame
    let mouse_reporting: Bool
    let sgr_pixel_mouse: Bool
    let pixel_width: UInt32; let pixel_height: UInt32
}

struct HerdrShellSurface: Decodable, Sendable, Equatable {
    let boot_id: String
    let projection_revision: UInt64
    var surface_revision: UInt64
    var frame: HerdrShellFrame
    var panes: [HerdrShellPane]
    let splits: [HerdrShellSplit]
    var popup: HerdrShellPopup?
    let graphics: HerdrShellGraphics

    func containsInputTarget(_ target: String, popup: Bool) -> Bool {
        if popup { return self.popup?.terminal_id == target }
        return self.popup == nil && panes.contains { $0.pane_id == target }
    }
}

struct HerdrShellPatch: Sendable, Equatable {
    struct Row: Sendable, Equatable { let x: UInt16; let y: UInt16; let cells: [HerdrShellCell] }
    let boot_id: String
    let projection_revision: UInt64
    let base_surface_revision: UInt64
    let surface_revision: UInt64
    let rows: [Row]
    let panes: [HerdrShellPane]
    let cursor: HerdrShellCursor?
}

struct HerdrShellNotification: Sendable, Equatable {
    let kind: UInt32
    let title: String
    let body: String?
    let sound: UInt32?
    let agent: String?
    let workspace_id: String?
    let tab_id: String?
    let pane_id: String?
    let position: UInt32?
}

enum HerdrShellServerMessage: Sendable, Equatable {
    case control(String, String)
    case surface(HerdrShellSurface)
    case patch(HerdrShellPatch)
    case response(boot: String, request: String, final: Bool, data: Data)
    case shutdown(String?)
    case failure(String)
    case clipboard(String)
    case title(String?)
    case bell(UInt16)
    case mouseCapture(Bool, Bool)
    case keyboardReportAll(Bool)
    case notification(HerdrShellNotification)
    case notify(UInt32, String, String?)
    case reloadSound

    // Charge each queued value conservatively, including shared cell/asset buffers.
    var estimatedDecodedBytes: Int {
        func keyBytes(_ key: HerdrShellAssetKey) -> Int {
            let strings: Int
            switch key.source {
            case .pane(let id, _), .popup(let id, _): strings = id.utf8.count
            case .layer(let pane, let layer): strings = pane.utf8.count + layer.utf8.count
            }
            return MemoryLayout<HerdrShellAssetKey>.stride + strings
        }
        func cellsBytes(_ cells: [HerdrShellCell]) -> Int {
            cells.count * MemoryLayout<HerdrShellCell>.stride + cells.reduce(0) { $0 + $1.symbol.utf8.count }
        }
        func frameBytes(_ frame: HerdrShellFrame) -> Int {
            MemoryLayout<HerdrShellFrame>.stride + cellsBytes(frame.cells) + frame.graphics.count
                + frame.hyperlinks.count * MemoryLayout<String>.stride
                + frame.hyperlinks.reduce(0) { $0 + $1.utf8.count }
        }
        func panesBytes(_ panes: [HerdrShellPane]) -> Int {
            panes.count * MemoryLayout<HerdrShellPane>.stride + panes.reduce(0) { $0 + $1.pane_id.utf8.count }
        }
        let content: Int
        switch self {
        case .control(let kind, let value): content = kind.utf8.count + value.utf8.count
        case .surface(let surface):
            let graphics = surface.graphics
            let assets = graphics.assets.reduce(0) { $0 + MemoryLayout<HerdrShellAsset>.stride + keyBytes($1.key) + $1.data.count }
            let placements = graphics.placements.reduce(0) { $0 + MemoryLayout<HerdrShellPlacement>.stride + keyBytes($1.asset) }
            let retained = graphics.retained_assets.reduce(0) { $0 + keyBytes($1) }
            let splits = surface.splits.reduce(0) { $0 + MemoryLayout<HerdrShellSplit>.stride + $1.path.count }
            let popup = surface.popup.map { MemoryLayout<HerdrShellPopup>.stride + $0.terminal_id.utf8.count
                + $0.title.utf8.count + frameBytes($0.frame) } ?? 0
            content = surface.boot_id.utf8.count + frameBytes(surface.frame) + panesBytes(surface.panes)
                + assets + placements + retained + splits + popup
        case .patch(let patch):
            content = patch.boot_id.utf8.count + panesBytes(patch.panes)
                + patch.rows.reduce(0) { $0 + MemoryLayout<HerdrShellPatch.Row>.stride + cellsBytes($1.cells) }
        case .response(let boot, let request, _, let bytes): content = boot.utf8.count + request.utf8.count + bytes.count
        case .shutdown(let value), .title(let value): content = value?.utf8.count ?? 0
        case .failure(let value), .clipboard(let value): content = value.utf8.count
        case .notify(_, let title, let body): content = title.utf8.count + (body?.utf8.count ?? 0)
        case .notification(let value):
            content = [value.title, value.body, value.agent, value.workspace_id, value.tab_id, value.pane_id]
                .reduce(0) { $0 + ($1?.utf8.count ?? 0) }
        case .bell, .mouseCapture, .keyboardReportAll, .reloadSound: content = 0
        }
        return MemoryLayout<Self>.stride + content
    }

    var presentationEffectBytes: Int? {
        switch self {
        case .clipboard(let text): text.utf8.count
        case .title(let text): text?.utf8.count ?? 0
        case .bell, .reloadSound: 0
        case .notify(_, let title, let body): title.utf8.count + (body?.utf8.count ?? 0)
        case .notification(let value):
            [value.title, value.body, value.agent, value.workspace_id, value.tab_id, value.pane_id]
                .compactMap { $0 }.reduce(0) { $0 + $1.utf8.count }
        default: nil
        }
    }
}

enum HerdrShellInput: Sendable, Equatable {
    struct Key: Sendable, Equatable {
        let code: UInt32
        var character: Unicode.Scalar? = nil
        var function: UInt8? = nil
        var modifiers: UInt8 = 0
        var kind: UInt32 = 0
        var repeatCount: UInt16 = 1
        var shiftedCodepoint: UInt32? = nil
        var text: String? = nil
        var tracksRelease: Bool = false
        var physicalKeyID: UInt32? = nil
    }
    struct Mouse: Sendable, Equatable {
        let kind: UInt32
        var button: UInt32? = nil
        let column: UInt16; let row: UInt16
        var pixels: (UInt32, UInt32)? = nil
        var geometry: (UInt16, UInt16, UInt32, UInt32)? = nil
        var modifiers: UInt8 = 0
        var lines: UInt16 = 1
        static func == (a: Self, b: Self) -> Bool {
            a.kind == b.kind && a.button == b.button && a.column == b.column && a.row == b.row
                && a.pixels?.0 == b.pixels?.0 && a.pixels?.1 == b.pixels?.1
                && a.geometry?.0 == b.geometry?.0 && a.geometry?.1 == b.geometry?.1
                && a.geometry?.2 == b.geometry?.2 && a.geometry?.3 == b.geometry?.3
                && a.modifiers == b.modifiers && a.lines == b.lines
        }
    }
    case key(Key)
    case text(String)
    case paste(String)
    case mouse(Mouse)
}

struct HerdrShellRGB: Sendable, Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
}

extension HerdrShellRGB {
    init?(hex: String) {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.utf8.count == 6,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let packed = UInt32(value, radix: 16) else { return nil }
        self.init(r: UInt8(truncatingIfNeeded: packed >> 16), g: UInt8(truncatingIfNeeded: packed >> 8), b: UInt8(truncatingIfNeeded: packed))
    }
}

struct HerdrShellHostColors: Sendable, Equatable {
    let foreground: HerdrShellRGB
    let background: HerdrShellRGB
    let palette: [UInt8: HerdrShellRGB]
}

enum HerdrShellClientMessage: Sendable {
    case control(String, String)
    case resize(HerdrShellSize, UInt32, UInt32, Bool)
    case input(target: String, popup: Bool, events: [HerdrShellInput])
    case request(boot: String, json: String)
    case focus(Bool)
    case appearance(dark: Bool)
    case defaultColor(background: Bool, color: HerdrShellRGB)
    case paletteColors([UInt8: HerdrShellRGB])
    case detach

    func encoded() throws -> Data {
        var w = HerdrShellWriter()
        switch self {
        case let .control(kind, data): w.uint(20); try w.string(kind); try w.string(data)
        case let .resize(size, width, height, pixels):
            guard size.cols > 0, size.rows > 0 else { throw CLIError("Invalid Herdr shell dimensions") }
            w.uint(12); w.uint(UInt64(width)); w.uint(UInt64(height)); w.uint(UInt64(size.cols)); w.uint(UInt64(size.rows)); w.bool(pixels)
        case let .input(target, popup, events):
            guard !target.isEmpty, !events.isEmpty, events.count <= 4096 else { throw CLIError("Invalid Herdr semantic input batch") }
            w.uint(popup ? 14 : 13); try w.string(target); w.uint(UInt64(events.count))
            for event in events { try w.input(event) }
        case let .request(boot, json): w.uint(15); try w.string(boot); try w.string(json)
        case let .focus(focused): w.uint(18); w.bool(focused)
        case let .appearance(dark): w.uint(17); w.uint(2); w.uint(dark ? 0 : 1)
        case let .defaultColor(background, color):
            w.uint(17); w.uint(0); w.uint(background ? 1 : 0)
            w.bytes([color.r, color.g, color.b])
        case let .paletteColors(colors):
            w.uint(17); w.uint(1); w.uint(UInt64(colors.count))
            for (index, color) in colors.sorted(by: { $0.key < $1.key }) {
                w.bytes([index, color.r, color.g, color.b])
            }
        case .detach: w.uint(4)
        }
        guard w.data.count <= HerdrShellWire.maximumFrameBytes else { throw CLIError("Herdr shell command exceeds frame budget") }
        var framed = Data()
        for shift in stride(from: 0, to: 32, by: 8) { framed.append(UInt8(truncatingIfNeeded: UInt32(w.data.count) >> shift)) }
        framed.append(w.data)
        return framed
    }
}

struct HerdrShellWriter {
    private(set) var data = Data()
    mutating func bytes(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
    mutating func uint(_ value: UInt64) {
        let count: Int
        if value < 251 { data.append(UInt8(value)); return }
        if value <= UInt16.max { data.append(251); count = 2 }
        else if value <= UInt32.max { data.append(252); count = 4 }
        else { data.append(253); count = 8 }
        for shift in stride(from: 0, to: count * 8, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    mutating func bool(_ value: Bool) { data.append(value ? 1 : 0) }
    mutating func string(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= HerdrShellWire.maximumStringBytes else { throw CLIError("Herdr string exceeds budget") }
        uint(UInt64(bytes.count)); data.append(bytes)
    }
    mutating func optionalUInt(_ value: UInt64?) { bool(value != nil); if let value { uint(value) } }
    mutating func input(_ event: HerdrShellInput) throws {
        switch event {
        case let .text(text): uint(1); try string(text)
        case let .paste(text): uint(3); try string(text)
        case let .key(key):
            guard key.code <= 17, key.kind <= 2, key.repeatCount > 0,
                  (key.code == 15) == (key.character != nil), (key.code == 16) == (key.function != nil)
            else { throw CLIError("Invalid Herdr semantic key") }
            uint(0); uint(UInt64(key.code))
            if let character = key.character { data.append(contentsOf: String(character).utf8) }
            if let function = key.function { data.append(function) }
            data.append(key.modifiers); uint(UInt64(key.kind)); uint(UInt64(key.repeatCount))
            optionalUInt(key.shiftedCodepoint.map(UInt64.init))
            bool(key.text != nil); if let text = key.text { try string(text) }
            bool(key.tracksRelease); optionalUInt(key.physicalKeyID.map(UInt64.init)); bool(false)
        case let .mouse(mouse):
            guard mouse.kind <= 7, (mouse.kind <= 2) == (mouse.button != nil),
                  mouse.button.map({ $0 <= 2 }) ?? true, mouse.lines > 0 else { throw CLIError("Invalid Herdr semantic mouse event") }
            uint(2); uint(UInt64(mouse.kind)); if let button = mouse.button { uint(UInt64(button)) }
            if let pixels = mouse.pixels { uint(1); uint(UInt64(pixels.0)); uint(UInt64(pixels.1)) } else { uint(0) }
            uint(UInt64(mouse.column)); uint(UInt64(mouse.row)); bool(mouse.geometry != nil)
            if let g = mouse.geometry { uint(UInt64(g.0)); uint(UInt64(g.1)); uint(UInt64(g.2)); uint(UInt64(g.3)) }
            data.append(mouse.modifiers); uint(UInt64(mouse.lines))
        }
    }
}

struct HerdrShellReader {
    let data: Data
    private(set) var offset = 0
    var remaining: Int { data.count - offset }
    mutating func byte() throws -> UInt8 {
        guard remaining > 0 else { throw CLIError("Truncated Herdr shell payload") }
        defer { offset += 1 }; return data[data.startIndex + offset]
    }
    mutating func uint(maximum: UInt64 = UInt64.max) throws -> UInt64 {
        let prefix = try byte()
        let count: Int
        switch prefix { case 0...250: guard UInt64(prefix) <= maximum else { throw CLIError("Herdr integer overflow") }; return UInt64(prefix)
        case 251: count = 2; case 252: count = 4; case 253: count = 8
        default: throw CLIError("Unsupported Herdr integer width") }
        var result: UInt64 = 0
        for shift in stride(from: 0, to: count * 8, by: 8) { result |= UInt64(try byte()) << shift }
        guard result <= maximum else { throw CLIError("Herdr integer overflow") }
        return result
    }
    mutating func u16() throws -> UInt16 { UInt16(try uint(maximum: UInt64(UInt16.max))) }
    mutating func u32() throws -> UInt32 { UInt32(try uint(maximum: UInt64(UInt32.max))) }
    mutating func i32() throws -> Int32 {
        let value = try u32()
        return Int32(bitPattern: (value >> 1) ^ (0 &- (value & 1)))
    }
    mutating func bool() throws -> Bool {
        let value = try byte(); guard value <= 1 else { throw CLIError("Invalid Herdr boolean") }; return value == 1
    }
    mutating func bytes(maximum: Int = HerdrShellWire.maximumFrameBytes) throws -> Data {
        let length = Int(try uint(maximum: UInt64(maximum)))
        guard length <= remaining else { throw CLIError("Truncated Herdr byte vector") }
        defer { offset += length }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + length))
    }
    mutating func string(maximum: Int = HerdrShellWire.maximumStringBytes) throws -> String {
        guard let text = String(data: try bytes(maximum: maximum), encoding: .utf8)
        else { throw CLIError("Invalid Herdr UTF-8") }; return text
    }
    mutating func optional<T>(_ decode: (inout Self) throws -> T) throws -> T? { try bool() ? decode(&self) : nil }
    mutating func array<T>(maximum: Int = 4096, minimumBytes: Int = 1, _ decode: (inout Self) throws -> T) throws -> [T] {
        let count = Int(try uint(maximum: UInt64(maximum)))
        guard count <= remaining / minimumBytes else { throw CLIError("Truncated Herdr collection") }
        var result: [T] = []; result.reserveCapacity(count)
        for _ in 0..<count { result.append(try decode(&self)) }
        return result
    }
    mutating func rect() throws -> HerdrShellRect { try .init(x: u16(), y: u16(), width: u16(), height: u16()) }
    mutating func cursor() throws -> HerdrShellCursor {
        let x = try u16(), y = try u16(), visible = try bool(), shape = try byte()
        guard shape <= 6 else { throw CLIError("Invalid Herdr cursor shape") }
        return .init(x: x, y: y, visible: visible, shape: shape)
    }
    mutating func cell() throws -> HerdrShellCell {
        try .init(symbol: string(), fg: u32(), bg: u32(), modifier: u16(), skip: bool(), hyperlink: optional { try $0.u32() })
    }
    mutating func frame(omittingCells: Bool = false) throws -> HerdrShellFrame {
        let cells = try array(maximum: omittingCells ? 0 : 1_048_576, minimumBytes: 6) { try $0.cell() }
        let width = try u16(), height = try u16(), cursor = try optional { try $0.cursor() }
        if omittingCells {
            guard width > 0, height > 0, width <= 4096, height <= 4096, Int(width) * Int(height) <= 1_000_000 else {
                throw CLIError("Herdr delta grid exceeds budget")
            }
        }
        let links = try array(maximum: omittingCells ? 65536 : 4096) { try $0.string() }, graphics = try bytes()
        guard width > 0, height > 0, omittingCells || cells.count == Int(width) * Int(height),
              cells.allSatisfy({ $0.hyperlink.map { Int($0) < links.count } ?? true }),
              cursor.map({ !$0.visible || ($0.x < width && $0.y < height) }) ?? true
        else { throw CLIError("Invalid Herdr surface grid") }
        return .init(cells: cells, width: width, height: height, cursor: cursor, hyperlinks: links, graphics: graphics)
    }
    mutating func pane() throws -> HerdrShellPane {
        try .init(pane_id: string(), content_revision: uint(), rect: rect(), inner_rect: rect(),
                  scrollbar_rect: optional { try $0.rect() }, scroll: optional {
                      try .init(offset_from_bottom: $0.uint(), max_offset_from_bottom: $0.uint(), viewport_rows: $0.uint())
                  }, focused: bool(), mouse_reporting: bool(), sgr_pixel_mouse: bool(), alternate_screen_active: bool(),
                  pixel_width: u32(), pixel_height: u32())
    }
    mutating func assetKey() throws -> HerdrShellAssetKey {
        let source: HerdrShellGraphicsSource
        switch try uint(maximum: 1) {
        case 0:
            let target = try uint(maximum: 1), id = try string(), imageID = try u32()
            source = target == 0 ? .pane(id, imageID) : .popup(id, imageID)
        default: source = try .layer(string(), string())
        }
        let width = try u32(), height = try u32(), format = try uint(maximum: 2), length = try uint(), fingerprint = try uint()
        guard width > 0, height > 0, length <= UInt64(HerdrShellWire.maximumFrameBytes),
              UInt64(width) * UInt64(height) <= 64 * 1024 * 1024
        else { throw CLIError("Herdr image exceeds dimensions or byte budget") }
        if format < 2 {
            guard UInt64(width) * UInt64(height) * (format == 0 ? 3 : 4) == length else { throw CLIError("Invalid Herdr raw image length") }
        }
        return .init(source: source, image_width: width, image_height: height, format: UInt32(format), data_len: length, data_fingerprint: fingerprint)
    }
    mutating func graphicsScene(extendedMetadata: Bool = false) throws -> HerdrShellGraphics {
        let assets = try array { r -> HerdrShellAsset in
            let key = try r.assetKey(), data = try r.bytes()
            guard UInt64(data.count) == key.data_len else { throw CLIError("Herdr image asset length mismatch") }
            return .init(key: key, data: data)
        }
        let placements = try array(maximum: extendedMetadata ? 65536 : 4096) { r -> HerdrShellPlacement in
            let key = try r.assetKey(), id = try r.u32(), x = try r.u16(), y = try r.u16()
            let cols = try r.u32(), rows = try r.u32(), sx = try r.u32(), sy = try r.u32(), sw = try r.u32(), sh = try r.u32()
            let ox = try r.u32(), oy = try r.u32(), z = try r.i32(), scroll = try r.u32()
            guard cols > 0, rows > 0, sw > 0, sh > 0,
                  UInt64(sx) + UInt64(sw) <= UInt64(key.image_width), UInt64(sy) + UInt64(sh) <= UInt64(key.image_height)
            else { throw CLIError("Invalid Herdr image placement") }
            return .init(asset: key, logical_placement_id: id, x: x, y: y, cols: cols, rows: rows,
                         source_x: sx, source_y: sy, source_width: sw, source_height: sh,
                         x_offset: ox, y_offset: oy, z: z, scrollback_offset: scroll)
        }
        let retained = try array(maximum: extendedMetadata ? 65536 : 4096) { try $0.assetKey() }
        guard Set(assets.map(\.key)).count == assets.count else { throw CLIError("Duplicate Herdr image asset") }
        return .init(assets: assets, placements: placements, retained_assets: retained)
    }
    mutating func popup(omittingCells: Bool = false) throws -> HerdrShellPopup {
        let terminal = try string(), title = try string()
        func size(_ r: inout Self) throws -> (UInt16, Bool) {
            let tag = try r.uint(maximum: 1)
            return tag == 0 ? (try r.u16(), false) : (UInt16(try r.byte()), true)
        }
        let width = try optional(size), height = try optional(size), frame = try frame(omittingCells: omittingCells)
        return try .init(terminal_id: terminal, title: title, width: width?.0, height: height?.0,
                         widthIsPercent: width?.1 ?? false, heightIsPercent: height?.1 ?? false, frame: frame,
                         mouse_reporting: bool(), sgr_pixel_mouse: bool(), pixel_width: u32(), pixel_height: u32())
    }
    mutating func surface(omittingCells: Bool = false) throws -> HerdrShellSurface {
        let boot = try string(), revision = try uint(), surfaceRevision = try uint(), frame = try frame(omittingCells: omittingCells)
        let panes = try array { try $0.pane() }
        let splits = try array { r in
            let direction = try r.uint(maximum: 1)
            return try HerdrShellSplit(horizontal: direction == 0, pos: r.u16(), area: r.rect(), hit_rect: r.rect(), path: r.array(maximum: omittingCells ? 4096 : 64) { try $0.bool() })
        }
        let popup = try optional { try $0.popup(omittingCells: omittingCells) }, graphics = try graphicsScene(extendedMetadata: omittingCells)
        let area = HerdrShellRect(x: 0, y: 0, width: frame.width, height: frame.height)
        guard !boot.isEmpty, Set(panes.map(\.pane_id)).count == panes.count,
              panes.allSatisfy({ !$0.pane_id.isEmpty && area.contains($0.rect) && $0.rect.contains($0.inner_rect) }),
              splits.allSatisfy({ area.contains($0.area) && area.contains($0.hit_rect) })
        else { throw CLIError("Invalid Herdr surface topology") }
        return .init(boot_id: boot, projection_revision: revision, surface_revision: surfaceRevision,
                     frame: frame, panes: panes, splits: splits, popup: popup, graphics: graphics)
    }
    mutating func patch() throws -> HerdrShellPatch {
        try .init(boot_id: string(), projection_revision: uint(), base_surface_revision: uint(), surface_revision: uint(),
                  rows: array { r in try .init(x: r.u16(), y: r.u16(), cells: r.array(maximum: 65535, minimumBytes: 6) { try $0.cell() }) },
                  panes: array { try $0.pane() }, cursor: optional { try $0.cursor() })
    }
}

struct HerdrShellWire {
    static let maximumFrameBytes = 32 * 1024 * 1024
    static let maximumStringBytes = 2 * 1024 * 1024
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [HerdrShellServerMessage] {
        let queueLimit = 2 * Self.maximumFrameBytes + 8
        guard data.count <= queueLimit, buffer.count <= queueLimit - data.count
        else { throw CLIError("Herdr shell receive queue exceeds budget") }
        buffer.append(data)
        var messages: [HerdrShellServerMessage] = []
        var consumed = 0
        while buffer.count - consumed >= 4 {
            var length: UInt32 = 0
            for i in 0..<4 { length |= UInt32(buffer[buffer.startIndex + consumed + i]) << (i * 8) }
            guard length > 0, length <= Self.maximumFrameBytes else { throw CLIError("Invalid Herdr shell frame length") }
            let end = consumed + 4 + Int(length)
            guard end <= buffer.count else { break }
            guard messages.count < 4096 else { throw CLIError("Too many Herdr messages in one receive batch") }
            messages.append(try Self.decode(buffer.subdata(in: (buffer.startIndex + consumed + 4)..<(buffer.startIndex + end))))
            consumed = end
        }
        if consumed > 0 { buffer.removeFirst(consumed) }
        return messages
    }

    func finish() throws { guard buffer.isEmpty else { throw CLIError("Truncated Herdr shell frame") } }

    static func decode(_ payload: Data) throws -> HerdrShellServerMessage {
        guard !payload.isEmpty, payload.count <= maximumFrameBytes else { throw CLIError("Invalid Herdr shell payload length") }
        var r = HerdrShellReader(data: payload)
        let tag = try r.uint(), message: HerdrShellServerMessage
        switch tag {
        case 3: message = try .shutdown(r.optional { try $0.string() })
        case 4: message = try .notify(UInt32(r.uint(maximum: 2)), r.string(), r.optional { try $0.string() })
        case 5: message = try .clipboard(r.string())
        case 6: message = try .title(r.optional { try $0.string() })
        case 7: message = .reloadSound
        case 8: message = try .mouseCapture(r.bool(), r.bool())
        case 9: message = try .bell(r.u16())
        case 13: message = try .surface(r.surface())
        case 14:
            message = try .notification(.init(kind: UInt32(r.uint(maximum: 3)), title: r.string(), body: r.optional { try $0.string() },
                sound: r.optional { UInt32(try $0.uint(maximum: 1)) }, agent: r.optional { try $0.string() },
                workspace_id: r.optional { try $0.string() }, tab_id: r.optional { try $0.string() },
                pane_id: r.optional { try $0.string() }, position: r.optional { UInt32(try $0.uint(maximum: 3)) }))
        case 15: message = try .failure(r.string())
        case 17: message = try .keyboardReportAll(r.bool())
        case 18: message = try .response(boot: r.string(), request: r.string(), final: r.bool(), data: r.bytes())
        case 19: message = try .patch(r.patch())
        case 20:
            let kind = try r.string()
            let graphicsCodec = kind == "endpoint.surface-delta.v1" || kind == "endpoint.surface-scroll.v1"
            message = try .control(kind, r.string(maximum: graphicsCodec ? Self.maximumFrameBytes : Self.maximumStringBytes))
        default: throw CLIError("Unsupported Herdr ClientShell message tag \(tag)")
        }
        guard r.remaining == 0 else { throw CLIError("Trailing bytes in Herdr shell message") }
        return message
    }
}
