import Foundation
import GhosttyVt

enum NativeTerminalError: Error, CustomStringConvertible {
    case invalidSize
    case api(String, Int32)

    var description: String {
        switch self {
        case .invalidSize: return "Terminal size is outside the lab limits."
        case let .api(operation, code): return "\(operation) failed (Ghostty VT \(code))."
        }
    }
}

private func checkVT(_ result: GhosttyResult, _ operation: String) throws {
    guard result == GHOSTTY_SUCCESS else {
        throw NativeTerminalError.api(operation, result.rawValue)
    }
}

/// Single-threaded fixture driver, deliberately separate from the production
/// surface library. No PTY, network, shell or protocol-reply sink is installed.
@MainActor
final class GhosttyVTDriver {
    private let terminal: GhosttyTerminal
    private let state: GhosttyRenderState
    private let iterator: GhosttyRenderStateRowIterator
    private let cellIterator: GhosttyRenderStateRowCells
    private var previousRows: [NativeRowID: NativeTerminalRow] = [:]
    private(set) var columns: Int
    private(set) var rows: Int

    init(columns: Int = 80, rows: Int = 24) throws {
        guard (1...4096).contains(columns), (1...1024).contains(rows) else {
            throw NativeTerminalError.invalidSize
        }
        var terminal: GhosttyTerminal?
        var state: GhosttyRenderState?
        var iterator: GhosttyRenderStateRowIterator?
        var cells: GhosttyRenderStateRowCells?
        do {
            try checkVT(ghostty_terminal_new(nil, &terminal, UInt16(columns), UInt16(rows)), "terminal_new")
            try checkVT(ghostty_render_state_new(nil, &state), "render_state_new")
            try checkVT(ghostty_render_state_row_iterator_new(nil, &iterator), "row_iterator_new")
            try checkVT(ghostty_render_state_row_cells_new(nil, &cells), "row_cells_new")
            var limit = UInt(8 * 1024 * 1024)
            try checkVT(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &limit), "scrollback_limit")
            var overscan = GhosttyRenderStateOverscan(above: 1, below: 3)
            try checkVT(ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPT_OVERSCAN, &overscan), "overscan")
        } catch {
            ghostty_render_state_row_cells_free(cells)
            ghostty_render_state_row_iterator_free(iterator)
            ghostty_render_state_free(state)
            ghostty_terminal_free(terminal)
            throw error
        }
        self.terminal = terminal!
        self.state = state!
        self.iterator = iterator!
        self.cellIterator = cells!
        self.columns = columns
        self.rows = rows
    }

    isolated deinit {
        ghostty_render_state_row_cells_free(cellIterator)
        ghostty_render_state_row_iterator_free(iterator)
        ghostty_render_state_free(state)
        ghostty_terminal_free(terminal)
    }

    func feed(_ data: Data) {
        data.withUnsafeBytes { bytes in
            ghostty_terminal_vt_write(terminal, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
    }

    func feed(_ text: String) { feed(Data(text.utf8)) }

    func resize(columns: Int, rows: Int, cellWidth: UInt32 = 8, cellHeight: UInt32 = 16) throws {
        guard (1...4096).contains(columns), (1...1024).contains(rows) else {
            throw NativeTerminalError.invalidSize
        }
        try checkVT(ghostty_terminal_resize(terminal, UInt16(columns), UInt16(rows), cellWidth, cellHeight), "resize")
        self.columns = columns
        self.rows = rows
    }

    func reset() {
        ghostty_terminal_reset(terminal)
        previousRows = [:]
    }

    var totalRows: Int {
        get throws {
            var scrollbar = GhosttyTerminalScrollbar()
            try checkVT(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar), "scrollbar")
            return Int(clamping: scrollbar.total)
        }
    }

    func snapshot(topRow: Int) throws -> NativeTerminalFrame {
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW
        scroll.value.row = max(0, topRow)
        try checkVT(ghostty_terminal_scroll_viewport(terminal, scroll), "scroll_viewport")
        try checkVT(ghostty_render_state_update(state, terminal), "render_state_update")

        var scrollbar = GhosttyTerminalScrollbar()
        try checkVT(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar), "scrollbar")
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        try checkVT(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors), "colors")
        let palette = withUnsafePointer(to: &colors.palette) {
            $0.withMemoryRebound(to: GhosttyColorRgb.self, capacity: 256) {
                UnsafeBufferPointer(start: $0, count: 256).map(NativeRGB.init)
            }
        }

        var rowIterator: GhosttyRenderStateRowIterator? = iterator
        try checkVT(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator), "rows")
        var captured: [Int: NativeTerminalRow] = [:]
        var nextRows: [NativeRowID: NativeTerminalRow] = [:]
        while ghostty_render_state_row_iterator_next(iterator) {
            var position: Int32 = 0
            var identity = GhosttyRenderStateRowId()
            var raw: GhosttyRow = 0
            try checkVT(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y, &position), "row_position")
            try checkVT(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_ID, &identity), "row_identity")
            try checkVT(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &raw), "row_raw")
            var wrapped = false
            try checkVT(ghostty_row_get(raw, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &wrapped), "row_wrap")
            let id = NativeRowID(first: identity.bits.0, second: identity.bits.1)
            var dirty = true
            try checkVT(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &dirty), "row_dirty")
            if !dirty, let old = previousRows[id], old.cells.count == columns, old.isWrapped == wrapped {
                captured[Int(clamping: scrollbar.offset) + Int(position)] = old
                nextRows[id] = old
                continue
            }
            var cells: GhosttyRenderStateRowCells? = cellIterator
            try checkVT(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells), "row_cells")
            var values: [NativeTerminalCell] = []
            values.reserveCapacity(columns)
            while ghostty_render_state_row_cells_next(cellIterator) {
                values.append(try readCell())
            }
            // Dirty can mean a row moved, not that its content changed.
            let row: NativeTerminalRow
            if let old = previousRows[id], old.cells == values, old.isWrapped == wrapped {
                row = old
            } else {
                row = NativeTerminalRow(id: id, cells: values, isWrapped: wrapped)
            }
            captured[Int(clamping: scrollbar.offset) + Int(position)] = row
            nextRows[id] = row
        }
        previousRows = nextRows  // Bounded to the viewport + overscan, never all history.
        ghostty_render_state_clean(state)

        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        try checkVT(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor), "cursor")
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        try checkVT(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen), "active_screen")
        let shape: NativeTerminalFrame.CursorShape
        switch cursor.visual_style {
        case GHOSTTY_CURSOR_STYLE_BAR: shape = .bar
        case GHOSTTY_CURSOR_STYLE_UNDERLINE: shape = .underline
        case GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW: shape = .hollow
        default: shape = .block
        }
        return NativeTerminalFrame(
            columns: columns, terminalRows: rows, totalRows: Int(clamping: scrollbar.total),
            topRow: Int(clamping: scrollbar.offset), rows: captured,
            cursor: .init(line: cursor.viewport_has_value ? Int(clamping: scrollbar.offset) + Int(cursor.viewport_y) : -1,
                          column: cursor.viewport_has_value ? max(0, Int(cursor.viewport_x) - (cursor.wide_tail ? 1 : 0)) : 0,
                          visible: cursor.visible && cursor.viewport_has_value,
                          blinking: cursor.blinking, shape: shape),
            foreground: NativeRGB(colors.foreground), background: NativeRGB(colors.background),
            cursorColor: NativeRGB(colors.cursor_has_value ? colors.cursor : colors.foreground),
            palette: palette, isAlternateScreen: screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE)
    }

    private func readCell() throws -> NativeTerminalCell {
        var raw: GhosttyCell = 0
        var style = GhosttyStyle()
        try checkVT(ghostty_render_state_row_cells_get(cellIterator, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw), "cell_raw")
        try checkVT(ghostty_render_state_row_cells_get(cellIterator, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style), "cell_style")
        var wide = GHOSTTY_CELL_WIDE_NARROW
        try checkVT(ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide), "cell_width")
        var buffer = GhosttyBuffer()
        let result = ghostty_render_state_row_cells_get(cellIterator, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer)
        var text: String?
        if result == GHOSTTY_OUT_OF_SPACE {
            var bytes = [UInt8](repeating: 0, count: buffer.len)
            try bytes.withUnsafeMutableBufferPointer { pointer in
                buffer.ptr = pointer.baseAddress
                buffer.cap = pointer.count
                try checkVT(ghostty_render_state_row_cells_get(cellIterator, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer), "cell_text")
            }
            text = String(decoding: bytes.prefix(buffer.len), as: UTF8.self)
        } else {
            try checkVT(result, "cell_text")
        }
        // A spacer head is an empty narrow cell before a wrap; a tail must
        // remain width zero so the renderer never draws a second glyph.
        let width = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL ? 0 : 1)
        var background = color(style.bg_color)
        if background == .defaultColor {
            // Erased cells can carry color in packed content, not style.
            // Preserve palette identity so OSC 4 recolors even cached rows.
            var tag = GHOSTTY_CELL_CONTENT_CODEPOINT
            try checkVT(ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag), "cell_content")
            if tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE {
                var index: UInt8 = 0
                try checkVT(ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_PALETTE, &index), "cell_background_palette")
                background = .palette(index)
            } else if tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB {
                var rgb = GhosttyColorRgb()
                try checkVT(ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_RGB, &rgb), "cell_background_rgb")
                background = .rgb(NativeRGB(rgb))
            }
        }
        return .init(text: text, width: width, foreground: color(style.fg_color),
                     background: background, underlineColor: color(style.underline_color),
                     style: NativeCellStyle(rawValue: style.flags),
                     underline: UInt8((style.flags >> 8) & 7))
    }

    private func color(_ value: GhosttyStyleColor) -> NativeCellColor {
        switch UInt32(value.tag) {
        case GHOSTTY_STYLE_COLOR_PALETTE.rawValue: return .palette(value.value.palette)
        case GHOSTTY_STYLE_COLOR_RGB.rawValue: return .rgb(NativeRGB(value.value.rgb))
        default: return .defaultColor
        }
    }
}

private extension NativeRGB {
    init(_ color: GhosttyColorRgb) {
        self.init(red: color.r, green: color.g, blue: color.b)
    }
}
