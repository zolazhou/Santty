import Foundation
import GhosttyVt

/// Immutable formatter output for one bounded render window, not all history.
final class NativeAXFormattedText: Sendable {
    let text: String
    let limited: Bool
    init(_ text: String, limited: Bool = false) { self.text = text; self.limited = limited }
    static let unavailable = NativeAXFormattedText("", limited: true)
}

/// Only used under the driver lock. The formatter's selection is local to the
/// formatter; no active selection, cursor, viewport or terminal mode is set.
final class GhosttyVTAccessibleText {
    static let maximumBytes = 1024 * 1024
    static let maximumCells = 256 * 1024
    private var formatter: GhosttyFormatter?
    private var previousRows: [Int: NativeTerminalRow] = [:]
    private var previous = NativeAXFormattedText("")

    init(terminal: GhosttyTerminal) throws {
        var result: GhosttyFormatter?
        try Self.check(ghostty_formatter_terminal_new(nil, &result, terminal), "ax_formatter_new")
        do {
            var unwrap = false, trim = true
            // AX line numbers address visual physical rows. Clipboard copy
            // independently retains its existing unwrap=true policy.
            try Self.check(ghostty_formatter_set(result, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap), "ax_unwrap")
            try Self.check(ghostty_formatter_set(result, GHOSTTY_FORMATTER_OPT_TRIM, &trim), "ax_trim")
        } catch { ghostty_formatter_free(result); throw error }
        formatter = result
    }

    func dispose() { ghostty_formatter_free(formatter); formatter = nil; previousRows = [:] }

    func capture(terminal: GhosttyTerminal, rows: [Int: NativeTerminalRow], columns: Int) throws -> NativeAXFormattedText {
        if previousRows.count == rows.count, rows.allSatisfy({ previousRows[$0.key] === $0.value }) { return previous }
        previousRows = rows
        guard let first = rows.keys.min(), let last = rows.keys.max(), first >= 0,
              rows.count <= Self.maximumCells / max(1, columns) else {
            previous = rows.isEmpty ? NativeAXFormattedText("") : .unavailable
            return previous
        }
        var selection = GhosttySelection()
        func reference(_ column: Int, _ row: Int, _ target: UnsafeMutablePointer<GhosttyGridRef>) throws {
            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_SCREEN
            point.value.coordinate = .init(x: UInt16(column), y: UInt32(clamping: row))
            try Self.check(ghostty_terminal_grid_ref(terminal, point, target), "ax_reference")
        }
        try reference(0, first, &selection.start)
        try reference(columns - 1, last, &selection.end)
        try Self.check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection), "ax_format_range")
        var count = 0
        let result = ghostty_formatter_format_buf(formatter, nil, 0, &count)
        if result == GHOSTTY_SUCCESS { previous = NativeAXFormattedText(""); return previous }
        try Self.check(result == GHOSTTY_OUT_OF_SPACE ? GHOSTTY_SUCCESS : result, "ax_format_size")
        guard count <= Self.maximumBytes else { previous = .unavailable; return previous }
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBufferPointer {
            try Self.check(ghostty_formatter_format_buf(formatter, $0.baseAddress, $0.count, &count), "ax_format")
        }
        guard let text = String(bytes: bytes.prefix(count), encoding: .utf8) else { previous = .unavailable; return previous }
        previous = NativeAXFormattedText(text)
        return previous
    }

    private static func check(_ result: GhosttyResult, _ operation: String) throws {
        if result != GHOSTTY_SUCCESS { throw NativeTerminalError.api(operation, result.rawValue) }
    }
}
