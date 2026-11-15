import Foundation
import GhosttyVt

/// All access, allocation and disposal happens under the driver's VT lock.
/// Only three VT-owned tracked locations survive a call; no borrowed GridRef,
/// numeric row identity, text snapshot or second selection engine is retained.
final class GhosttyVTScrollMode {
    private let terminal: GhosttyTerminal
    private var cursor: GhosttyTrackedGridRef?
    private var anchor: GhosttyTrackedGridRef?
    private var viewport: GhosttyTrackedGridRef?
    private var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
    private var epoch: UInt64 = 0
    private var linewise = false
    private(set) var pointerToken: UUID?
    private var columns = 0
    private var rows = 0
    static let maximumMotionCells = 16 * 1024
    static let maximumMotionBytes = 128 * 1024
    static let maximumCellScalars = 4096

    init(terminal: GhosttyTerminal) { self.terminal = terminal }
    deinit { dispose() }

    func dispose() {
        ghostty_tracked_grid_ref_free(cursor); cursor = nil
        ghostty_tracked_grid_ref_free(anchor); anchor = nil
        ghostty_tracked_grid_ref_free(viewport); viewport = nil
        linewise = false; pointerToken = nil
    }

    func end() throws {
        defer { dispose() }
        if anchor != nil { try clearSelection() }
    }

    /// Does not read a render state, scroll a viewport, or advance a clock.
    func cell(_ cell: NativeScrollCell, columns: Int, total: Int) throws -> NativeScrollCellContent? {
        guard cell.column >= 0, cell.column < columns, cell.row >= 0, cell.row < total else { return nil }
        var ref = try reference(cell), raw: GhosttyCell = 0, row: GhosttyRow = 0
        try check(ghostty_grid_ref_cell(&ref, &raw), "cell")
        var wide = GHOSTTY_CELL_WIDE_NARROW
        try check(ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide), "wide")
        var count = 0
        let size = ghostty_grid_ref_graphemes(&ref, nil, 0, &count)
        guard size == GHOSTTY_SUCCESS || size == GHOSTTY_OUT_OF_SPACE else { try check(size, "grapheme_size"); return nil }
        guard count <= Self.maximumCellScalars else { throw NativeScrollModeError.readBudget }
        var values = [UInt32](repeating: 0, count: count)
        if count > 0 {
            try values.withUnsafeMutableBufferPointer { try check(ghostty_grid_ref_graphemes(&ref, $0.baseAddress, $0.count, &count), "graphemes") }
        }
        var scalars = String.UnicodeScalarView()
        for value in values.prefix(count) {
            guard let scalar = UnicodeScalar(value) else { throw NativeScrollModeError.invalidCell }
            if value != 0 { scalars.append(scalar) }
        }
        try check(ghostty_grid_ref_row(&ref, &row), "row")
        var imageRow = false
        try check(ghostty_row_get(row, GHOSTTY_ROW_DATA_KITTY_VIRTUAL_PLACEHOLDER, &imageRow), "image_row")
        let image = imageRow && scalars.first?.value == 0x10EEEE
        return .init(text: image ? "" : String(scalars),
                     width: wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL ? 0 : 1),
                     isWrapSpacer: wide == GHOSTTY_CELL_WIDE_SPACER_HEAD, isImagePlaceholder: image)
    }

    /// Synchronization never retargets an old numeric row after pruning.
    func synchronize(columns: Int, rows: Int, epoch: UInt64) throws {
        var current = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        try check(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &current), "screen")
        if epoch != self.epoch || screen != current { try end() }
        self.epoch = epoch; screen = current
        if columns != self.columns || rows != self.rows { try cancelSelection() }
        self.columns = columns; self.rows = rows
        guard cursor != nil else { return }
        let geometry = try geometry()
        if try position(cursor) == nil {
            try cancelSelection()
            try track(&cursor, at: .init(column: 0, row: 0))
            try track(&viewport, at: .init(column: 0, row: 0))
        } else if anchor != nil {
            var selection = GhosttySelection()
            if try position(anchor) == nil || ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_NO_VALUE {
                try cancelSelection()
            }
        }
        // Reflow can leave the cursor on a wide tail. VT, not Swift string
        // width, decides which column contains the actual glyph.
        if let point = try position(cursor) {
            let normalized = try canonical(point, total: geometry.total)
            if normalized != point { try track(&cursor, at: normalized) }
        }
    }

    func state() throws -> NativeScrollModeState? {
        guard let point = try position(cursor) else { return nil }
        let geometry = try geometry()
        let top = try position(viewport)?.row ?? max(0, point.row - rows + 1)
        var navigation = NativeScrollNavigation(cell: point, viewport: top, columns: columns, rows: rows, total: geometry.total)
        navigation.clampAndReveal()
        if top != navigation.viewport { try track(&viewport, at: .init(column: 0, row: navigation.viewport)) }
        return .init(cell: point, viewport: navigation.viewport, columns: columns, rows: rows, total: geometry.total,
                     selection: anchor == nil ? nil : (linewise ? .line : .character))
    }

    func begin(firstRow: Int? = nil, preferInputCursor: Bool = false) throws -> NativeScrollModeState? {
        try end()
        let geometry = try geometry()
        let top = min(max(0, firstRow ?? geometry.offset), max(0, geometry.total - rows))
        var initial = NativeScrollCell(column: 0, row: min(geometry.total - 1, top + rows - 1))
        if preferInputCursor || top == max(0, geometry.total - rows) {
            var x: UInt16 = 0, y: UInt16 = 0
            try check(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x), "cursor_x")
            try check(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y), "cursor_y")
            initial = .init(column: min(columns - 1, Int(x)), row: geometry.total - rows + Int(y))
        }
        try track(&cursor, at: canonical(initial, total: geometry.total))
        try track(&viewport, at: .init(column: 0, row: top))
        return try state()
    }

    func move(_ movement: NativeScrollMovement) throws -> NativeScrollModeState? {
        guard let old = try state() else { return nil }
        var next = NativeScrollNavigation(cell: old.cell, viewport: old.viewport, columns: columns, rows: rows, total: old.total)
        // Bounded per-motion cache only. A budget refusal commits NO cursor or
        // selection movement; it is not silently treated as a word boundary.
        var cache: [NativeScrollCell: NativeScrollCellContent] = [:]
        var bytes = 0, failure: (any Error)?
        func read(_ point: NativeScrollCell) throws -> NativeScrollCellContent {
            if let cached = cache[point] { return cached }
            guard cache.count < Self.maximumMotionCells else { throw NativeScrollModeError.readBudget }
            guard let value = try cell(point, columns: columns, total: old.total) else { throw NativeScrollModeError.invalidCell }
            guard value.text.utf8.count <= Self.maximumMotionBytes - bytes else { throw NativeScrollModeError.readBudget }
            cache[point] = value; bytes += value.text.utf8.count
            return value
        }
        next.move(movement) { point in
            do {
                let value = try read(point)
                if value.width == 0, point.column > 0 { return try read(.init(column: point.column - 1, row: point.row)).text }
                return value.text
            } catch { failure = error; return nil }
        }
        if let failure { throw failure }
        if movement == .right, try read(old.cell).width == 2 {
            next.move(.right)
        }
        let point = try canonical(next.cell, total: old.total)
        try track(&cursor, at: point)
        try track(&viewport, at: .init(column: 0, row: next.viewport))
        try updateSelection()
        return try state()
    }

    func toggleSelection(linewise: Bool) throws {
        guard let point = try position(cursor) else { return }
        if anchor != nil, self.linewise == linewise { try cancelSelection(); return }
        if anchor == nil { try track(&anchor, at: point) }
        self.linewise = linewise
        try updateSelection()
    }

    func cancelSelection() throws {
        pointerToken = nil
        if anchor != nil { try clearSelection() }
        ghostty_tracked_grid_ref_free(anchor); anchor = nil
        linewise = false
    }

    func beginPointer(at point: NativeScrollCell) throws -> UUID? {
        guard cursor != nil else { return nil }
        try cancelSelection()
        try track(&cursor, at: canonical(point, total: geometry().total))
        let token = UUID(); pointerToken = token
        return token
    }

    @discardableResult
    func cancelPointer(expected token: UUID? = nil) -> Bool {
        guard token == nil || token == pointerToken else { return false }
        pointerToken = nil
        return true
    }

    /// Adopt fresh endpoints from VT's EXISTING tracked gesture engine. It
    /// owns half-cell thresholds, multi-click words/lines and drag direction.
    func adoptPointerSelection(token: UUID, fallback: NativeScrollCell) throws -> Bool {
        guard pointerToken == token, cursor != nil else { return false }
        var selection = GhosttySelection()
        let result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection)
        if result == GHOSTTY_NO_VALUE {
            ghostty_tracked_grid_ref_free(anchor); anchor = nil; linewise = false
            try track(&cursor, at: canonical(fallback, total: geometry().total))
            return true
        }
        try check(result, "pointer_selection")
        var a = GhosttyPointCoordinate(), b = GhosttyPointCoordinate()
        try check(ghostty_terminal_point_from_grid_ref(terminal, &selection.start, GHOSTTY_POINT_TAG_SCREEN, &a), "pointer_anchor")
        try check(ghostty_terminal_point_from_grid_ref(terminal, &selection.end, GHOSTTY_POINT_TAG_SCREEN, &b), "pointer_end")
        try track(&anchor, at: .init(column: Int(a.x), row: Int(a.y)))
        try track(&cursor, at: canonical(.init(column: Int(b.x), row: Int(b.y)), total: geometry().total))
        linewise = false
        return true
    }

    func moveRows(_ delta: Int) throws -> NativeScrollModeState? {
        guard let old = try state() else { return nil }
        let row = min(old.total - 1, max(0, old.cell.row + min(40, max(-40, delta))))
        try track(&cursor, at: canonical(.init(column: old.cell.column, row: row), total: old.total))
        try updateSelection()
        return try state()
    }

    func proposeViewport(_ row: Int) throws {
        let total = try geometry().total
        try track(&viewport, at: .init(column: 0, row: min(max(0,row), max(0,total-rows))))
    }

    private func clearSelection() throws { try check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil), "clear_selection") }
    private func updateSelection() throws {
        guard let a = try position(anchor), let b = try position(cursor) else { return }
        var start = min(a, b), end = max(a, b)
        if linewise { start.column = 0; end.column = columns - 1 }
        var selection = GhosttySelection()
        selection.start = try reference(start); selection.end = try reference(end)
        try check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection), "set_selection")
    }

    private func canonical(_ point: NativeScrollCell, total: Int) throws -> NativeScrollCell {
        guard let value = try cell(point, columns: columns, total: total) else { throw NativeScrollModeError.invalidCell }
        return .init(column: max(0, point.column - (value.width == 0 ? 1 : 0)), row: point.row)
    }
    private func geometry() throws -> (total: Int, offset: Int) {
        var scrollbar = GhosttyTerminalScrollbar()
        try check(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar), "geometry")
        guard scrollbar.total > 0, scrollbar.total <= UInt64(UInt32.max) else { throw NativeScrollModeError.invalidCell }
        return (Int(scrollbar.total), Int(scrollbar.offset))
    }
    private func point(_ cell: NativeScrollCell) -> GhosttyPoint {
        var point = GhosttyPoint(); point.tag = GHOSTTY_POINT_TAG_SCREEN
        point.value.coordinate = .init(x: UInt16(cell.column), y: UInt32(cell.row)); return point
    }
    private func reference(_ cell: NativeScrollCell) throws -> GhosttyGridRef {
        var ref = GhosttyGridRef()
        try check(ghostty_terminal_grid_ref(terminal, point(cell), &ref), "reference"); return ref
    }
    private func track(_ ref: inout GhosttyTrackedGridRef?, at cell: NativeScrollCell) throws {
        if let ref { try check(ghostty_tracked_grid_ref_set(ref, terminal, point(cell)), "track_set") }
        else { try check(ghostty_terminal_grid_ref_track(terminal, point(cell), &ref), "track_new") }
    }
    private func position(_ ref: GhosttyTrackedGridRef?) throws -> NativeScrollCell? {
        guard let ref else { return nil }
        var point = GhosttyPointCoordinate()
        let result = ghostty_tracked_grid_ref_point(ref, GHOSTTY_POINT_TAG_SCREEN, &point)
        if result == GHOSTTY_NO_VALUE { return nil }
        try check(result, "position")
        return .init(column: Int(point.x), row: Int(point.y))
    }
    private func check(_ result: GhosttyResult, _ operation: String) throws {
        guard result == GHOSTTY_SUCCESS else { throw NativeTerminalError.api("scroll_mode_" + operation, result.rawValue) }
    }
}

