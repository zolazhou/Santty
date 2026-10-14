import Foundation
import GhosttyTerminal

enum HerdrShellRenderTarget: Sendable, Hashable {
    case pane(String)
    case popup(String)

    func accepts(_ source: HerdrShellGraphicsSource) -> Bool {
        switch (self, source) {
        case let (.pane(id), .pane(other, _)), let (.pane(id), .layer(other, _)): id == other
        case let (.popup(id), .popup(other, _)): id == other
        default: false
        }
    }
}

struct HerdrShellViewportFrame: Sendable, Equatable {
    struct Revision: Sendable, Equatable {
        let boot: String
        let projection: UInt64
        let surface: UInt64
        let target: HerdrShellRenderTarget
    }
    let frame: HerdrShellFrame
    let originX: UInt16
    let originY: UInt16
    let placements: [HerdrShellPlacement]
    let retained: Set<HerdrShellAssetKey>
    var cellRect: HerdrShellRect? = nil
    var hidesCursor = false
    var revision: Revision? = nil
    var rowRevisions: [UInt64] = []
    var contentRevision: UInt64? = nil
    var damageOrigin: HerdrShellSurface.Damage.Origin? = nil

    var width: UInt16 { cellRect?.width ?? frame.width }
    var height: UInt16 { cellRect?.height ?? frame.height }
    var cursor: HerdrShellCursor? {
        guard !hidesCursor, let cursor = frame.cursor else { return nil }
        guard let rect = cellRect else { return cursor }
        guard cursor.x >= rect.x, cursor.y >= rect.y,
              Int(cursor.x) < Int(rect.x) + Int(rect.width), Int(cursor.y) < Int(rect.y) + Int(rect.height) else { return nil }
        return .init(x: cursor.x - rect.x, y: cursor.y - rect.y, visible: cursor.visible, shape: cursor.shape)
    }

    func cells(in row: Int) -> ArraySlice<HerdrShellCell> {
        let cells = frame.cells(in: row + Int(cellRect?.y ?? 0))
        let start = cells.startIndex + Int(cellRect?.x ?? 0)
        return cells[start..<(start + Int(width))]
    }

    static func extract(_ target: HerdrShellRenderTarget, from surface: HerdrShellSurface) throws -> Self {
        let frame: HerdrShellFrame, x: UInt16, y: UInt16
        var cellRect: HerdrShellRect?, hidesCursor = false, contentRevision: UInt64?
        switch target {
        case .pane(let id):
            guard let pane = surface.panes.first(where: { $0.pane_id == id }), pane.inner_rect.width > 0,
                  pane.inner_rect.height > 0 else { throw CLIError("Herdr pane is absent from the visible surface") }
            let rect = pane.inner_rect
            guard Int(rect.x) + Int(rect.width) <= Int(surface.frame.width),
                  Int(rect.y) + Int(rect.height) <= Int(surface.frame.height),
                  surface.frame.cellCount == Int(surface.frame.width) * Int(surface.frame.height)
            else { throw CLIError("Herdr pane content lies outside its surface") }
            var paneFrame = surface.frame
            paneFrame.graphics = Data()
            frame = paneFrame
            cellRect = rect; hidesCursor = !pane.focused
            contentRevision = surface.damage?.panes[id]
            x = rect.x; y = rect.y
        case .popup(let id):
            guard let popup = surface.popup, popup.terminal_id == id else { throw CLIError("Herdr popup is absent from the visible surface") }
            frame = popup.frame; x = 0; y = 0
        }
        return .init(frame: frame, originX: x, originY: y,
                     placements: surface.graphics.placements.filter { target.accepts($0.asset.source) },
                     retained: Set(surface.graphics.retained_assets.filter { target.accepts($0.source) }),
                     cellRect: cellRect, hidesCursor: hidesCursor,
                     revision: .init(boot: surface.boot_id, projection: surface.projection_revision,
                        surface: surface.surface_revision, target: target),
                     rowRevisions: cellRect == nil ? [] : surface.damage?.rows ?? [], contentRevision: contentRevision,
                     damageOrigin: cellRect == nil ? nil : surface.damage?.origin)
    }
}

@MainActor
struct HerdrShellPreparedRender {
    let byteCount: Int
    let isCurrent: @MainActor () -> Bool
    let commit: @MainActor () -> InMemoryTerminalSession?
}

@MainActor
struct HerdrShellRenderRequest {
    let input: HerdrClientShellRenderer.Input
    let isCurrent: @MainActor () -> Bool
    let commit: @MainActor (HerdrClientShellRenderer, Data) -> InMemoryTerminalSession?

    func output(_ encoded: HerdrClientShellRenderer.Output) -> HerdrShellPreparedRender {
        .init(byteCount: encoded.bytes.count, isCurrent: isCurrent, commit: {
            guard isCurrent() else { return nil }
            return commit(encoded.renderer, encoded.bytes)
        })
    }
}

struct HerdrShellRenderTiming: Sendable {
    let queue: TimeInterval
    let encode: TimeInterval
    var resume: TimeInterval = 0
}

// One encoder per Ghostty surface; its image namespace never reaches the backend PTY.
struct HerdrClientShellRenderer: Sendable {
    struct Input: Sendable { let renderer: HerdrClientShellRenderer; let target: HerdrShellRenderTarget }
    struct Output: Sendable { let renderer: HerdrClientShellRenderer; let bytes: Data }

    static let maximumBatchOutputBytes = 256 * 1024 * 1024
    static func clipboardOutput(_ text: String) throws -> Data {
        let bytes = Data(text.utf8)
        guard bytes.count <= 2 * 1024 * 1024 else { throw CLIError("Herdr clipboard output exceeds budget") }
        return Data(("\u{1b}]52;c;" + bytes.base64EncodedString() + "\u{1b}\\").utf8)
    }
    private struct Slot: Hashable {
        let source: HerdrShellGraphicsSource
        let logical: UInt32
        let x: UInt16; let y: UInt16
    }
    private struct Placed: Equatable {
        let placement: HerdrShellPlacement
        let imageID: UInt32
        let placementID: UInt32
        let localX: UInt16; let localY: UInt16
    }
    private struct Baseline: Sendable {
        let width: UInt16; let height: UInt16
        let cellRect: HerdrShellRect?
        let cursor: HerdrShellCursor?
        let hyperlinks: [String]
        let placements: [HerdrShellPlacement]
        let retained: Set<HerdrShellAssetKey>
        let revision: HerdrShellViewportFrame.Revision?
        let rows: [[HerdrShellCell]]
        let damageOrigin: HerdrShellSurface.Damage.Origin?
    }
    private var previous: Baseline?
    private var uploaded: [HerdrShellAssetKey: UInt32] = [:]
    private var placed: [Slot: Placed] = [:]
    private var nextImageID: UInt32 = 1
    private var nextPlacementID: UInt32 = 1

    mutating func reset() {
        // Monotonic IDs keep late Ghostty replies from matching a rebuilt scene.
        previous = nil; uploaded.removeAll(); placed.removeAll()
    }

    func prepare(_ target: HerdrShellRenderTarget, from surface: HerdrShellSurface,
                 assets: [HerdrShellAssetKey: Data]) async throws
        -> (renderer: Self, bytes: Data, timing: HerdrShellRenderTiming?) {
        let scene = try await Self.prepareScene([.init(renderer: self, target: target)], from: surface, assets: assets)
        return (scene.outputs[0].renderer, scene.outputs[0].bytes, scene.timing)
    }

    static func prepareScene(_ inputs: [Input], from surface: HerdrShellSurface,
                             assets: [HerdrShellAssetKey: Data]) async throws
        -> (outputs: [Output], timing: HerdrShellRenderTiming?) {
        try Task.checkCancellation()
        let reused = try inputs.map { try $0.renderer.canReuse($0.target, from: surface, assets: assets) }
        if reused.allSatisfy({ $0 }) { return (inputs.map { .init(renderer: $0.renderer, bytes: Data()) }, nil) }
        let enqueuedAt = ProcessInfo.processInfo.systemUptime
        let worker = Task.detached(priority: .userInitiated) {
            let startedAt = ProcessInfo.processInfo.systemUptime
            var outputs: [Output] = []; outputs.reserveCapacity(inputs.count)
            var totalBytes = 0
            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                var candidate = input.renderer
                let bytes = reused[index] ? Data() : try candidate.render(.extract(input.target, from: surface), assets: assets)
                guard bytes.count <= maximumBatchOutputBytes - totalBytes else {
                    throw CLIError("Herdr native render batch exceeds output budget")
                }
                totalBytes += bytes.count
                outputs.append(.init(renderer: candidate, bytes: bytes))
            }
            try Task.checkCancellation()
            let finishedAt = ProcessInfo.processInfo.systemUptime
            return (outputs: outputs, timing: HerdrShellRenderTiming(
                queue: startedAt - enqueuedAt, encode: finishedAt - startedAt), finishedAt: finishedAt)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            var timing = result.timing
            timing.resume = ProcessInfo.processInfo.systemUptime - result.finishedAt
            return (result.outputs, timing)
        } onCancel: { worker.cancel() }
    }

    func ownsImage(_ id: UInt32) -> Bool { uploaded.values.contains(id) }

    private func patchBaseline(for viewport: HerdrShellViewportFrame) -> UInt64? {
        guard let previous, let old = previous.revision, let next = viewport.revision,
              old.boot == next.boot, old.target == next.target,
              previous.damageOrigin != nil, previous.damageOrigin == viewport.damageOrigin,
              old.surface <= next.surface, previous.cellRect == viewport.cellRect,
              previous.width == viewport.width, previous.height == viewport.height,
              previous.hyperlinks == viewport.frame.hyperlinks,
              viewport.rowRevisions.count == Int(viewport.frame.height) else { return nil }
        return old.surface
    }

    func canReuse(_ target: HerdrShellRenderTarget, from surface: HerdrShellSurface,
                  assets: [HerdrShellAssetKey: Data]) throws -> Bool {
        let viewport = try HerdrShellViewportFrame.extract(target, from: surface)
        guard let baseline = patchBaseline(for: viewport), let content = viewport.contentRevision,
              content <= baseline, let previous, previous.cursor == viewport.cursor,
              previous.placements == viewport.placements, previous.retained == viewport.retained else { return false }
        return !viewport.placements.contains { uploaded[$0.asset] == nil && assets[$0.asset] != nil }
    }

    // Build on a copy so a rejected scene cannot advance the display's baseline.
    mutating func render(_ viewport: HerdrShellViewportFrame, assets: [HerdrShellAssetKey: Data]) throws -> Data {
        var next = self
        let bytes = try next.encode(viewport, assets: assets)
        self = next
        return bytes
    }

    private mutating func encode(_ viewport: HerdrShellViewportFrame, assets: [HerdrShellAssetKey: Data]) throws -> Data {
        let frame = viewport.frame
        let width = Int(viewport.width), height = Int(viewport.height)
        guard width > 0, height > 0, frame.cellCount == Int(frame.width) * Int(frame.height), frame.graphics.isEmpty else {
            throw CLIError("Invalid Herdr pane render frame")
        }
        // Herdr owns history; resizing a projected normal buffer would create local scrollback.
        var output = previous == nil ? Data("\u{1b}[?1049h".utf8) : Data()
        output.append(contentsOf: "\u{1b}[?2026h\u{1b}[?25l\u{1b}[?7l".utf8)
        if previous == nil {
            output.append(contentsOf: "\u{1b}[0m\u{1b}[2J\u{1b}_Ga=d,d=A,q=2;\u{1b}\\".utf8)
        }
        let changedSize = previous?.width != viewport.width || previous?.height != viewport.height
        let changedLinks = previous?.hyperlinks != frame.hyperlinks
        let baseline = patchBaseline(for: viewport)
        // Retain only this pane's rows, so idle panes cannot pin whole historical surfaces.
        var retainedRows = changedSize ? Array(repeating: [HerdrShellCell](), count: height) : previous!.rows
        for row in 0..<height {
            try Task.checkCancellation()
            if let baseline, viewport.rowRevisions[row + Int(viewport.cellRect?.y ?? 0)] <= baseline { continue }
            let cells = viewport.cells(in: row)
            let oldCells = changedSize || changedLinks ? nil : previous?.rows[row]
            if !changedSize, !changedLinks, let previous,
               previous.rows[row].elementsEqual(cells) { continue }
            retainedRows[row] = Array(cells)
            var coveredThrough = 0
            var invalidatedThrough = 0
            var lastStyle: (fg: UInt32, bg: UInt32, modifier: UInt16)?
            var nextColumn: Int?
            var currentLink: String?
            for column in 0..<width {
                let cell = cells[cells.startIndex + column]
                guard column >= coveredThrough, !cell.skip else { continue }
                let ascii = cell.symbol.utf8.count == 1 && cell.symbol.utf8.first.map { (32...126).contains($0) } == true
                let clean = ascii ? cell.symbol : Self.printable(cell.symbol)
                let columns = ascii ? 1 : Self.columnWidth(clean)
                let symbol = columns > width - column || clean.isEmpty ? " " : clean
                coveredThrough = column + max(1, columns > width - column ? 1 : columns)
                let previousCell = oldCells.map { $0[$0.startIndex + column] }
                guard previousCell != cell || column < invalidatedThrough else { continue }
                if let previousCell {
                    let oldWidth = previousCell.symbol.utf8.count == 1 ? 1 : Self.columnWidth(Self.printable(previousCell.symbol))
                    // A narrower replacement must repaint cells previously covered by a wide glyph.
                    invalidatedThrough = max(invalidatedThrough, column + (oldWidth <= width - column ? oldWidth : 1))
                }
                // Only ASCII runs rely on cursor advance; Unicode keeps explicit placement across width differences.
                if nextColumn != column || !ascii { output.append(contentsOf: "\u{1b}[\(row + 1);\(column + 1)H".utf8) }
                nextColumn = ascii ? column + 1 : nil
                if lastStyle?.fg != cell.fg || lastStyle?.bg != cell.bg || lastStyle?.modifier != cell.modifier {
                    output.append(contentsOf: Self.style(cell).utf8)
                    lastStyle = (cell.fg, cell.bg, cell.modifier)
                }
                let link = cell.hyperlink.flatMap { index in
                    Int(index) < frame.hyperlinks.count ? Self.sanitizedLink(frame.hyperlinks[Int(index)]) : nil
                }
                if link != currentLink {
                    if currentLink != nil { output.append(contentsOf: "\u{1b}]8;;\u{1b}\\".utf8) }
                    if let link { output.append(contentsOf: "\u{1b}]8;;\(link)\u{1b}\\".utf8) }
                    currentLink = link
                }
                output.append(contentsOf: symbol.utf8)
            }
            if currentLink != nil { output.append(contentsOf: "\u{1b}]8;;\u{1b}\\".utf8) }
        }
        try encodeGraphics(viewport, assets: assets, output: &output)
        output.append(contentsOf: "\u{1b}[0m".utf8)
        if let cursor = viewport.cursor, cursor.visible, cursor.x < viewport.width, cursor.y < viewport.height {
            output.append(contentsOf: "\u{1b}[\(cursor.y + 1);\(cursor.x + 1)H\u{1b}[\(cursor.shape) q\u{1b}[?25h".utf8)
        }
        output.append(contentsOf: "\u{1b}[?2026l".utf8)
        guard output.count <= HerdrClientShellTransport.queueBudget else { throw CLIError("Herdr render output exceeds budget") }
        previous = .init(width: viewport.width, height: viewport.height, cellRect: viewport.cellRect,
            cursor: viewport.cursor, hyperlinks: frame.hyperlinks, placements: viewport.placements,
            retained: viewport.retained, revision: viewport.revision, rows: retainedRows, damageOrigin: viewport.damageOrigin)
        return output
    }

    private mutating func encodeGraphics(_ viewport: HerdrShellViewportFrame, assets: [HerdrShellAssetKey: Data], output: inout Data) throws {
        var desired: [Slot: Placed] = [:]
        for placement in viewport.placements {
            try Task.checkCancellation()
            guard placement.cols > 0, placement.rows > 0, placement.x >= viewport.originX, placement.y >= viewport.originY else { throw CLIError("Herdr image has an invalid pane origin") }
            let x = placement.x - viewport.originX, y = placement.y - viewport.originY
            guard UInt64(x) + UInt64(placement.cols) <= UInt64(viewport.width),
                  UInt64(y) + UInt64(placement.rows) <= UInt64(viewport.height) else { throw CLIError("Herdr image lies outside its pane") }
            let slot = Slot(source: placement.asset.source, logical: placement.logical_placement_id, x: placement.x, y: placement.y)
            guard desired[slot] == nil else { throw CLIError("Duplicate Herdr image placement") }
            var imageID = uploaded[placement.asset]
            if imageID == nil, let data = assets[placement.asset] {
                guard UInt64(data.count) == placement.asset.data_len, nextImageID < UInt32.max else { throw CLIError("Invalid Herdr image upload") }
                imageID = nextImageID; nextImageID += 1
                try Self.upload(data, key: placement.asset, id: imageID!, output: &output)
                uploaded[placement.asset] = imageID!
            }
            guard let imageID else {
                // A bounded server frame may defer new pixels; keep the old placement until they arrive.
                if let old = placed[slot] { desired[slot] = old }
                continue
            }
            let placementID: UInt32
            if let old = placed[slot] { placementID = old.placementID }
            else {
                guard nextPlacementID < UInt32.max else { throw CLIError("Herdr placement ID exhausted") }
                placementID = nextPlacementID; nextPlacementID += 1
            }
            let value = Placed(placement: placement, imageID: imageID, placementID: placementID, localX: x, localY: y)
            desired[slot] = value
            if placed[slot] != value {
                if let old = placed[slot] { Self.deletePlacement(old, output: &output) }
                Self.display(value, output: &output)
            }
        }
        for (slot, old) in placed where desired[slot] == nil { Self.deletePlacement(old, output: &output) }
        let kept = Set(desired.values.map { $0.placement.asset }).union(viewport.retained)
        for (key, id) in uploaded where !kept.contains(key) {
            output.append(contentsOf: "\u{1b}_Ga=d,d=I,i=\(id),q=2;\u{1b}\\".utf8)
            uploaded.removeValue(forKey: key)
        }
        placed = desired
    }

    private static func upload(_ bytes: Data, key: HerdrShellAssetKey, id: UInt32, output: inout Data) throws {
        guard !bytes.isEmpty else { throw CLIError("Empty Herdr image upload") }
        let format = [24, 32, 100]
        let pixels = UInt64(key.image_width) * UInt64(key.image_height)
        guard key.format < 3, pixels > 0, pixels <= 64 * 1024 * 1024 else { throw CLIError("Unsupported Herdr image format or dimensions") }
        if key.format < 2 {
            guard UInt64(bytes.count) == pixels * (key.format == 0 ? 3 : 4) else { throw CLIError("Invalid Herdr raw image byte count") }
        } else {
            guard bytes.count >= 24, bytes.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
                  bytes.subdata(in: 12..<16) == Data("IHDR".utf8),
                  bytes[16..<20].reduce(UInt32(0), { ($0 << 8) | UInt32($1) }) == key.image_width,
                  bytes[20..<24].reduce(UInt32(0), { ($0 << 8) | UInt32($1) }) == key.image_height
            else { throw CLIError("Herdr PNG dimensions do not match its asset metadata") }
        }
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let end = min(offset + 3072, bytes.count)
            let base64 = bytes.subdata(in: offset..<end).base64EncodedString()
            let control = offset == 0 ? "a=t,t=d,f=\(format[Int(key.format)]),s=\(key.image_width),v=\(key.image_height),i=\(id),q=1," : ""
            guard output.count + base64.utf8.count + control.utf8.count + 32 <= HerdrClientShellTransport.queueBudget else {
                throw CLIError("Herdr render output exceeds budget")
            }
            output.append(contentsOf: "\u{1b}_G\(control)m=\(end == bytes.count ? 0 : 1);\(base64)\u{1b}\\".utf8)
            offset = end
        }
    }

    private static func deletePlacement(_ value: Placed, output: inout Data) {
        output.append(contentsOf: "\u{1b}_Ga=d,d=i,i=\(value.imageID),p=\(value.placementID),q=2;\u{1b}\\".utf8)
    }

    private static func display(_ value: Placed, output: inout Data) {
        let p = value.placement
        output.append(contentsOf: "\u{1b}[\(value.localY + 1);\(value.localX + 1)H".utf8)
        output.append(contentsOf: "\u{1b}_Ga=p,i=\(value.imageID),p=\(value.placementID),c=\(p.cols),r=\(p.rows),z=\(p.z),C=1,q=1,x=\(p.source_x),y=\(p.source_y),w=\(p.source_width),h=\(p.source_height),X=\(p.x_offset),Y=\(p.y_offset);\u{1b}\\".utf8)
    }

    private static func printable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .control }))
    }

    private static func sanitizedLink(_ text: String) -> String? {
        let clean = printable(text)
        return clean.isEmpty ? nil : clean
    }

    private static func style(_ cell: HerdrShellCell) -> String {
        var parts = ["0"]
        for (bit, code) in [(0, "1"), (1, "2"), (2, "3"), (4, "5"), (5, "6"), (6, "7"), (7, "8"), (8, "9")] {
            if cell.modifier & (1 << bit) != 0 { parts.append(code) }
        }
        if cell.modifier & 8 != 0 {
            let underline = (cell.modifier >> 12) & 15
            parts.append((2...5).contains(underline) ? "4:\(underline)" : "4")
        }
        parts.append(color(cell.fg, foreground: true)); parts.append(color(cell.bg, foreground: false))
        return "\u{1b}[\(parts.joined(separator: ";"))m"
    }

    private static func color(_ color: UInt32, foreground: Bool) -> String {
        let base = foreground ? 30 : 40
        switch color >> 24 {
        case 0:
            let named = Int(color & 255)
            if (1...8).contains(named) { return String(base + named - 1) }
            if (9...16).contains(named) { return String(base + 60 + named - 9) }
            return String(foreground ? 39 : 49)
        case 1: return "\(base + 8);5;\(color & 255)"
        case 2: return "\(base + 8);2;\((color >> 16) & 255);\((color >> 8) & 255);\(color & 255)"
        default: return String(foreground ? 39 : 49)
        }
    }

    private static func columnWidth(_ text: String) -> Int {
        text.reduce(0) { sum, character in
            let scalars = character.unicodeScalars
            let emoji = !scalars.contains("\u{fe0e}") && ((scalars.contains("\u{fe0f}") || scalars.contains("\u{20e3}"))
                && scalars.contains(where: { $0.properties.isEmoji })
                || scalars.contains(where: { $0.properties.isEmojiPresentation || (0x1f1e6...0x1f1ff).contains($0.value) }))
            let wide = scalars.contains { scalar in
                switch scalar.value {
                case 0x1100...0x115f, 0x2329...0x232a, 0x2e80...0x303e, 0x3041...0xa4c6,
                     0xa960...0xa97c, 0xac00...0xd7a3, 0xf900...0xfaff, 0xfe10...0xfe19,
                     0xfe30...0xfe6b, 0xff01...0xff60, 0xffe0...0xffe6, 0x20000...0x3fffd: true
                default: false
                }
            }
            let voicedKana = scalars.contains(where: { (0xff66...0xff9d).contains($0.value) })
                && scalars.contains(where: { $0.value == 0xff9e || $0.value == 0xff9f })
            return sum + (emoji || wide || voicedKana ? 2 : 1)
        }
    }
}

// Ghostty's host-protocol replies are display feedback, never pane-domain input.
final class HerdrShellDisplayFeedback: @unchecked Sendable {
    struct Failure: Sendable, Equatable { let imageID: UInt32; let message: String }
    private let lock = NSLock()
    private var partial = Data()
    private var handler: (@Sendable (Failure) -> Void)?
    private struct ColorQuery {
        let id: UInt64
        var started = false
        var finished = false
        var cancelled = false
        var foreground: HerdrShellRGB?
        var background: HerdrShellRGB?
        var palette: [UInt8: HerdrShellRGB] = [:]
    }
    private var colorQuery: ColorQuery?
    private var colorQueryID: UInt64 = 0
    private var reportedViewport: HerdrShellSize?
    private var confirmedViewport: (HerdrShellSize, ObjectIdentifier)?
    private var viewportGeneration: UInt64 = 0
    private static let end = Data([27, 92])
    private static let limit = 8192

    private func takeViewport() -> HerdrShellSize? {
        lock.lock(); defer { lock.unlock() }
        defer { reportedViewport = nil }
        return reportedViewport
    }

    func invalidateViewport() {
        lock.withLock {
            viewportGeneration &+= 1
            confirmedViewport = nil
            reportedViewport = nil
        }
    }

    func hasConfirmedViewport(_ size: HerdrShellSize, in memory: InMemoryTerminalSession) -> Bool {
        lock.withLock { confirmedViewport?.0 == size && confirmedViewport?.1 == ObjectIdentifier(memory) }
    }

    @MainActor
    func waitForViewport(_ size: HerdrShellSize, in memory: InMemoryTerminalSession) async throws {
        // View metrics change before Ghostty's IO thread applies the terminal resize.
        var queryGeneration: UInt64?
        for _ in 0..<100 {
            try Task.checkCancellation()
            let identity = ObjectIdentifier(memory)
            let (confirmed, generation) = lock.withLock {
                (confirmedViewport?.0 == size && confirmedViewport?.1 == identity, viewportGeneration)
            }
            if confirmed { return }
            await Task.detached { memory.waitForPendingOutput() }.value
            let pending = takeViewport()
            // Output drains before the asynchronous reply callback necessarily arrives.
            if queryGeneration == generation, pending == size, lock.withLock({
                guard viewportGeneration == generation else { return false }
                confirmedViewport = (size, identity)
                return true
            }) { return }
            guard memory.receiveIfAttached(Data("\u{1b}[18t".utf8)) else {
                throw CLIError("Ghostty viewport is detached")
            }
            queryGeneration = generation
            await Task.detached { memory.waitForPendingOutput() }.value
            if takeViewport() == size, lock.withLock({
                guard viewportGeneration == generation else { return false }
                confirmedViewport = (size, identity)
                return true
            }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CLIError("Ghostty terminal viewport did not synchronize")
    }

    func setHandler(_ handler: (@Sendable (Failure) -> Void)?) {
        lock.lock(); self.handler = handler; partial.removeAll(); colorQuery = nil; lock.unlock()
    }

    func resetHostColorQueries() {
        lock.lock(); colorQuery = nil; partial.removeAll(); lock.unlock()
    }

    func beginHostColorQuery() -> (id: UInt64, output: Data)? {
        lock.lock(); defer { lock.unlock() }
        guard colorQuery == nil || colorQuery?.finished == true else { return nil }
        colorQueryID &+= 1
        colorQuery = ColorQuery(id: colorQueryID)
        var query = "\u{1b}[5n\u{1b}]10;?\u{1b}\\\u{1b}]11;?\u{1b}\\"
        for index in 0...255 { query += "\u{1b}]4;\(index);?\u{1b}\\" }
        query += "\u{1b}[5n"
        return (colorQueryID, Data(query.utf8))
    }

    func cancelHostColorQuery(_ id: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if colorQuery?.id == id { colorQuery?.cancelled = true }
    }

    func hostColorQueryResult(_ id: UInt64) -> (finished: Bool, colors: HerdrShellHostColors?) {
        lock.lock(); defer { lock.unlock() }
        guard let query = colorQuery, query.id == id, !query.cancelled else { return (true, nil) }
        guard query.finished else { return (false, nil) }
        guard let foreground = query.foreground, let background = query.background, query.palette.count == 256 else {
            return (true, nil)
        }
        return (true, .init(foreground: foreground, background: background, palette: query.palette))
    }

    @MainActor
    func queryHostColors(in memory: InMemoryTerminalSession) async throws -> HerdrShellHostColors {
        await Task.detached { memory.waitForPendingOutput() }.value
        try Task.checkCancellation()
        var request: (id: UInt64, output: Data)?
        for _ in 0..<100 {
            try Task.checkCancellation()
            if let next = beginHostColorQuery() { request = next; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let request else { throw CLIError("Ghostty host color query is still pending") }
        defer { cancelHostColorQuery(request.id) }
        memory.receive(request.output)
        for _ in 0..<100 {
            try Task.checkCancellation()
            let result = hostColorQueryResult(request.id)
            if result.finished {
                guard let colors = result.colors else { throw CLIError("Ghostty host color query is incomplete or retired") }
                return colors
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CLIError("Ghostty host color query timed out")
    }

    func receive(_ bytes: Data) {
        lock.lock()
        var failures: [Failure] = []
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = min(offset + 1024, bytes.endIndex)
            partial.append(contentsOf: bytes[offset..<end]); offset = end
            while !partial.isEmpty {
                guard let escape = partial.firstIndex(of: 27) else { partial.removeAll(); break }
                if escape > partial.startIndex { partial = Data(partial[escape...]) }
                guard partial.count >= 2 else { break }
                let second = partial[partial.startIndex + 1]
                if second == 91 {
                    guard let final = partial[(partial.startIndex + 2)...].firstIndex(where: { (64...126).contains($0) }) else { break }
                    let response = partial[(partial.startIndex + 2)...final]
                    if response.elementsEqual([48, 110]), colorQuery != nil, colorQuery?.finished == false {
                        if colorQuery?.started == true { colorQuery?.finished = true }
                        else { colorQuery?.started = true }
                    }
                    if response.last == 116, let text = String(data: response.dropLast(), encoding: .utf8) {
                        let fields = text.split(separator: ";", omittingEmptySubsequences: false)
                        if fields.count == 3, fields[0] == "8",
                           fields.dropFirst().allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
                           let rows = UInt16(fields[1]), let cols = UInt16(fields[2]), rows > 0, cols > 0 {
                            reportedViewport = .init(cols: cols, rows: rows)
                        }
                    }
                    partial = Data(partial[(final + 1)...])
                } else if second == 93 || second == 95 {
                    guard partial.count >= 3 else { break }
                    let contentStart = partial.startIndex + (second == 95 ? 3 : 2)
                    let st = partial.range(of: Self.end, in: contentStart..<partial.endIndex)
                    let bell = second == 93 ? partial[contentStart...].firstIndex(of: 7) : nil
                    let stop: Int
                    let after: Int
                    if let bell, bell < (st?.lowerBound ?? partial.endIndex) { stop = bell; after = bell + 1 }
                    else if let st { stop = st.lowerBound; after = st.upperBound }
                    else { break }
                    let reply = partial[contentStart..<stop]
                    if reply.count <= Self.limit {
                        if second == 95, partial[partial.startIndex + 2] == 71,
                           failures.count < 64, let failure = Self.parse(reply) { failures.append(failure) }
                        else if second == 93 { acceptHostColor(reply) }
                    }
                    partial = Data(partial[after...])
                } else { partial = Data(partial.dropFirst()) }
            }
            if partial.count > Self.limit { partial = Data(partial.suffix(2)) }
        }
        let callback = handler
        lock.unlock()
        for failure in failures { callback?(failure) }
    }

    private func acceptHostColor(_ bytes: Data.SubSequence) {
        guard colorQuery?.started == true, colorQuery?.finished == false, colorQuery?.cancelled == false,
              let text = String(data: bytes, encoding: .utf8) else { return }
        let fields = text.split(separator: ";", omittingEmptySubsequences: false)
        if fields.count == 2, let color = Self.parseHostRGB(fields[1]) {
            if fields[0] == "10" { colorQuery?.foreground = color }
            else if fields[0] == "11" { colorQuery?.background = color }
        } else if fields.count == 3, fields[0] == "4", !fields[1].isEmpty,
                  fields[1].utf8.allSatisfy({ (48...57).contains($0) }),
                  let index = UInt8(fields[1]), let color = Self.parseHostRGB(fields[2]) {
            colorQuery?.palette[index] = color
        }
    }

    private static func parseHostRGB(_ text: Substring) -> HerdrShellRGB? {
        let components: [Substring]
        if text.hasPrefix("rgb:") { components = text.dropFirst(4).split(separator: "/", omittingEmptySubsequences: false) }
        else if text.hasPrefix("#") {
            let hex = text.dropFirst()
            guard hex.count >= 3, hex.count <= 12, hex.count % 3 == 0 else { return nil }
            let width = hex.count / 3
            components = stride(from: 0, to: hex.count, by: width).map { start in
                let lower = hex.index(hex.startIndex, offsetBy: start)
                return hex[lower..<hex.index(lower, offsetBy: width)]
            }
        } else { return nil }
        guard components.count == 3 else { return nil }
        let values = components.compactMap { component -> UInt8? in
            guard (1...4).contains(component.utf8.count),
                  component.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let value = UInt32(component, radix: 16) else { return nil }
            let maximum = (UInt32(1) << (component.utf8.count * 4)) - 1
            return UInt8((value * 255 + maximum / 2) / maximum)
        }
        guard values.count == 3 else { return nil }
        return .init(r: values[0], g: values[1], b: values[2])
    }

    private static func parse(_ bytes: Data.SubSequence) -> Failure? {
        guard let text = String(data: bytes, encoding: .utf8), let separator = text.firstIndex(of: ";") else { return nil }
        let fields = text[..<separator].split(separator: ",")
        let ids = fields.filter { $0.hasPrefix("i=") }
        guard ids.count == 1, let id = UInt32(ids[0].dropFirst(2)), id > 0 else { return nil }
        let result = text[text.index(after: separator)...]
        guard result != "OK", !result.isEmpty else { return nil }
        let clean = result.unicodeScalars.filter { $0.properties.generalCategory != .control }
        let message = String(String.UnicodeScalarView(clean)).prefix(512)
        return .init(imageID: id, message: String(message))
    }
}
