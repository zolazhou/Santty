import AppKit
import SwiftTerm

/// The sole conversion boundary. No SwiftTerm.Terminal is instantiated.
@MainActor
final class SwiftTermFrameSource: TerminalExternalFrameSource {
    private(set) var store = TerminalRowStore()
    private(set) var lines: [Int: BufferLine] = [:]
    private typealias CachedRow = (row: NativeTerminalRow, line: BufferLine, selection: ClosedRange<Int>?, link: Range<Int>?)
    private var cached: [NativeRowID: CachedRow] = [:]
    var highlightedLink: [Int: Range<Int>] = [:]
    var suppressProgramCursor = false
    var selectionForeground = NativeRGB(red: 255, green: 255, blue: 255) {
        didSet { if oldValue != selectionForeground { invalidateSelectionColors() } }
    }
    var selectionBackground = NativeRGB(red: 60, green: 90, blue: 145) {
        didSet { if oldValue != selectionBackground { invalidateSelectionColors() } }
    }
    private var frame = TerminalExternalFrame(
        columns: 1, rows: 0, topLine: 0, cursorLine: 0, cursorColumn: 0,
        cursorVisible: false, cursorStyle: .steadyBlock, isAlternateBuffer: false,
        palette: TerminalExternalFrame.makePalette())
    private(set) var convertedRows = 0

    func apply(_ snapshot: NativeTerminalFrame, topLine: Int, renderRows: Int) {
        if store.isNearCapacity {
            store = TerminalRowStore()
            cached = [:]
        }
        var next: [NativeRowID: CachedRow] = [:]
        var lines: [Int: BufferLine] = [:]
        for (index, row) in snapshot.rows {
            let line: BufferLine
            let selected = snapshot.selection[index], link = highlightedLink[index]
            if let old = cached[row.id], old.row === row, old.selection == selected, old.link == link {
                line = old.line
            } else {
                line = store.makeLine(columns: snapshot.columns)
                for (column, cell) in row.cells.enumerated() {
                    // The VT row marks this reserved placeholder. Suppress
                    // its text/ID colors/decorations, not its cell background;
                    // resolved image placements come from VT, never SwiftTerm's
                    // separate placeholder decoder.
                    var value = cell.isImagePlaceholder
                        ? Attribute(foreground: .defaultColor, background: color(cell.background), style: []) : attribute(cell)
                    if !cell.isImagePlaceholder, link?.contains(column) == true {
                        value = Attribute(foreground: value.fg, background: value.bg,
                            style: value.style.union(.underline),
                            underlineStyle: value.underlineStyle == .none ? .single : value.underlineStyle,
                            underlineColor: value.underlineColor, hasOverline: value.hasOverline)
                    }
                    if selected?.contains(column) == true {
                        value = Attribute(foreground: color(.rgb(selectionForeground)), background: color(.rgb(selectionBackground)),
                            style: value.style.subtracting(.inverse), underlineStyle: value.underlineStyle,
                            underlineColor: value.underlineColor, hasOverline: value.hasOverline)
                    }
                    store.setCell(line, column: column, text: cell.isImagePlaceholder ? nil : cell.text, width: cell.width, attribute: value)
                }
                store.setLineState(line, isWrapped: row.isWrapped)
                convertedRows += 1
            }
            lines[index] = line
            next[row.id] = (row, line, selected, link)
        }
        self.lines = lines
        cached = next
        let cursor = snapshot.cursor
        let style: CursorStyle
        switch cursor.shape {
        case .bar: style = cursor.blinking ? .blinkBar : .steadyBar
        case .underline: style = cursor.blinking ? .blinkUnderline : .steadyUnderline
        case .block, .hollow: style = cursor.blinking ? .blinkBlock : .steadyBlock
        }
        frame = TerminalExternalFrame(
            columns: snapshot.columns, rows: renderRows, topLine: topLine,
            cursorLine: cursor.line, cursorColumn: cursor.column,
            cursorVisible: cursor.visible && !suppressProgramCursor, cursorStyle: style,
            isAlternateBuffer: snapshot.isAlternateScreen,
            palette: snapshot.palette.map { SwiftTerm.Color(red8: UInt16($0.red), green8: UInt16($0.green), blue8: UInt16($0.blue)) })
        if case .hollow = cursor.shape { frame.cursorHollow = true }
        let pictures = snapshot.imageSnapshot
        if !pictures.placements.isEmpty {
            let live = Set(pictures.placements.map(\.imageID))
            let images = pictures.images.filter { live.contains($0.key) }.mapValues {
                KittyGraphicsRenderImage(imageId: $0.id, imageNumber: nil, width: $0.width, height: $0.height,
                    rgba: $0.rgba, contentGeneration: $0.generation)
            }
            let placements = pictures.placements.enumerated().map { index, p in
                KittyGraphicsRenderPlacement(token: UInt64(index + 1), placementId: p.placementID, imageId: p.imageID,
                    visibleSource: .init(x: p.sourceX, y: p.sourceY, width: p.sourceWidth, height: p.sourceHeight),
                    geometry: .init(column: p.column, row: p.row - topLine, columns: p.columns, rows: p.rows),
                    pixelOffsetX: p.offsetX, pixelOffsetY: p.offsetY, zIndex: p.z,
                    isVirtual: false, insertionOrder: UInt64(index),
                    resolvedSize: .init(width: p.pixelWidth, height: p.pixelHeight))
            }
            frame.kitty = .init(storageGeneration: pictures.revision, imagesById: images, placements: placements)
        }
    }

    /// Drop old pixels/text before reconnect/reset can begin a held restore.
    /// A frame-driver tick during that hold must see empty host presentation.
    func resetPresentation() {
        store = TerminalRowStore(); lines = [:]; cached = [:]; highlightedLink = [:]
        frame = TerminalExternalFrame(columns: 1, rows: 0, topLine: 0, cursorLine: 0, cursorColumn: 0,
            cursorVisible: false, cursorStyle: .steadyBlock, isAlternateBuffer: false,
            palette: TerminalExternalFrame.makePalette())
    }

    func invalidateSelectionColors() { cached = [:] }

    /// Reuse the same resolved CG/Metal rectangle conversion, not another
    /// image placement/animation resolver. Overscan alone must not keep a
    /// deadline alive when no image intersects the actual native clip.
    func hasImages(intersecting clip: CGRect, cell: CGSize, scale: CGFloat, height: CGFloat) -> Bool {
        guard !clip.isEmpty else { return false }
        return frame.kitty?.placements.contains { placement in
            let rect = placement.destinationRect(cellWidth: cell.width, cellHeight: cell.height,
                imageScale: scale, screenRow: 0, lineOrigin: CGPoint(x: 0, y: height - cell.height))
            return rect.intersects(clip)
        } ?? false
    }

    func withFrame(_ body: (TerminalExternalFrame, TerminalRowStore, (Int) -> BufferLine?) -> Void) {
        // Source, store and driver are main-actor isolated. No parse/network
        // work or cross-thread lock is performed inside this callback.
        body(frame, store) { lines[$0] }
    }

    private func attribute(_ cell: NativeTerminalCell) -> Attribute {
        var style: CharacterStyle = []
        for (native, swift) in [
            (NativeCellStyle.bold, CharacterStyle.bold), (.italic, .italic),
            (.faint, .dim), (.blink, .blink), (.inverse, .inverse),
            (.invisible, .invisible), (.strike, .crossedOut),
        ] where cell.style.contains(native) {
            style.insert(swift)
        }
        let underline = UnderlineStyle(rawValue: cell.underline) ?? .none
        if underline != .none { style.insert(.underline) }
        return Attribute(foreground: color(cell.foreground),
                         background: color(cell.background),
                         style: style, underlineStyle: underline,
                         underlineColor: cell.underlineColor == .defaultColor ? nil : color(cell.underlineColor),
                         hasOverline: cell.style.contains(.overline))
    }

    private func color(_ value: NativeCellColor) -> Attribute.Color {
        switch value {
        // SwiftTerm resolves defaultColor according to the foreground/background
        // slot; defaultInvertedColor explicitly swaps that pair.
        case .defaultColor: return .defaultColor
        case let .palette(index): return .ansi256(code: index)
        case let .rgb(rgb): return .trueColor(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
    }
}

extension NativeRGB {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255, alpha: 1)
    }
}
