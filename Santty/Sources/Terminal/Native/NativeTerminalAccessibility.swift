// AppKit counterpart of SwiftTerm's iOS page/line accessibility boundary,
// adapted to owned VT cells/formatter text, not SwiftTerm's terminal buffer.
// See Santty/Resources/TerminalLicenses/Accessibility-Adaptation-NOTICE.txt.
import AppKit

/// One immutable bounded presentation's UTF-16 index, not a history cache.
/// VT formats the string; cell data only locates its exact UTF-16 sequences.
struct NativeTerminalAccessibility {
    struct Span {
        let range: NSRange
        let row: Int, column: Int, width: Int
    }
    struct Line {
        let row: Int
        let range: NSRange
        let columns: [Int] // insertion offsets; wide tails point to the lead
    }
    let text: String
    let spans: [Span]
    let lines: [Line]
    let selectedRange: NSRange
    let cursor: (row: Int, column: Int, offset: Int)?
    let limited: Bool
    let length: Int
    private let units: [UInt16]
    static let missing = NSRange(location: NSNotFound, length: 0)
    static let empty = Self(text: "", spans: [], lines: [], selectedRange: missing, cursor: nil, limited: false)

    init(frame: NativeTerminalFrame) {
        guard !frame.accessibleText.limited,
              frame.accessibleText.text.utf8.count <= GhosttyVTAccessibleText.maximumBytes,
              frame.rows.count <= GhosttyVTAccessibleText.maximumCells / max(1, frame.columns) else { self = Self(text: "", spans: [], lines: [], selectedRange: Self.missing, cursor: nil, limited: true); return }
        let raw = Array(frame.accessibleText.text.utf16)
        var source = 0, output: [UInt16] = [], spans: [Span] = [], lines: [Line] = []
        var selected: [NSRange] = []
        let rows = frame.rows.keys.sorted()
        for (rowIndex, rowNumber) in rows.enumerated() {
            guard let row = frame.rows[rowNumber] else { continue }
            let start = output.count
            var columns = [Int](repeating: start, count: row.cells.count + 1)
            for (column, cell) in row.cells.enumerated() {
                columns[column] = output.count
                guard cell.width > 0, !cell.isWrapSpacer else {
                    if cell.width == 0, column > 0 { columns[column] = columns[column - 1] }
                    continue
                }
                let token = Array((cell.text ?? " ").utf16)
                guard token.count <= raw.count - source,
                      raw[source..<(source + token.count)].elementsEqual(token) else {
                    // VT trims physical-row padding and final blank rows. Only
                    // blank cells may be omitted; never normalize or guess a
                    // mismatching nonblank grapheme into a different range.
                    if cell.text == nil || token == [32] { continue }
                    self = Self(text: "", spans: [], lines: [], selectedRange: Self.missing, cursor: nil, limited: true)
                    return
                }
                source += token.count
                let position = output.count
                // Screen-only AX policy: do not speak concealed glyphs or
                // Kitty placeholder/ID payloads. Backgrounds stay in renderer.
                if !cell.style.contains(.invisible), !cell.isImagePlaceholder {
                    output.append(contentsOf: token)
                    let range = NSRange(location: position, length: token.count)
                    spans.append(.init(range: range, row: rowNumber, column: column, width: max(1, cell.width)))
                    if let selection = frame.selection[rowNumber],
                       selection.overlaps(column...(column + max(1, cell.width) - 1)) { selected.append(range) }
                }
            }
            columns[row.cells.count] = output.count
            if rowIndex < rows.count - 1, source < raw.count, raw[source] == 10 {
                source += 1
                spans.append(.init(range: NSRange(location: output.count, length: 1), row: rowNumber,
                    column: max(0, row.cells.count - 1), width: 1))
                output.append(10)
            }
            lines.append(.init(row: rowNumber, range: NSRange(location: start, length: output.count - start), columns: columns))
        }
        guard source == raw.count else { self = Self(text: "", spans: [], lines: [], selectedRange: Self.missing, cursor: nil, limited: true); return }
        let text = String(decoding: output, as: UTF16.self)
        let line = lines.first { $0.row == frame.cursor.line }
        let column = line.map { min(max(0, frame.cursor.column), $0.columns.count - 1) }
        let cursor = line.flatMap { l in column.map { (row: l.row, column: $0, offset: l.columns[$0]) } }
        let selection: NSRange
        if let first = selected.first, let last = selected.last {
            selection = NSRange(location: first.location, length: last.location + last.length - first.location)
        } else { selection = cursor.map { NSRange(location: $0.offset, length: 0) } ?? Self.missing }
        self.init(text: text, spans: spans, lines: lines, selectedRange: selection, cursor: cursor, limited: false)
    }

    private init(text: String, spans: [Span], lines: [Line], selectedRange: NSRange,
                 cursor: (row: Int, column: Int, offset: Int)?, limited: Bool) {
        self.text = text; self.spans = spans; self.lines = lines
        self.units = Array(text.utf16); self.length = units.count
        self.selectedRange = selectedRange; self.cursor = cursor; self.limited = limited
    }

    func valid(_ range: NSRange) -> Bool {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= length, range.length <= length - range.location else { return false }
        func boundary(_ index: Int) -> Bool {
            !(index > 0 && index < units.count && (0xdc00...0xdfff).contains(units[index])
                && (0xd800...0xdbff).contains(units[index - 1]))
        }
        return boundary(range.location) && boundary(range.location + range.length)
    }
    func string(_ range: NSRange) -> String? {
        guard valid(range) else { return nil }
        return (text as NSString).substring(with: range)
    }
    func span(at index: Int) -> Span? {
        guard index >= 0, index < length else { return nil }
        var low = 0, high = spans.count
        while low < high {
            let mid = (low + high) / 2, span = spans[mid]
            if span.range.location + span.range.length <= index { low = mid + 1 } else { high = mid }
        }
        return low < spans.count && spans[low].range.location <= index ? spans[low] : nil
    }
    func range(at index: Int) -> NSRange {
        if index == length { return NSRange(location: length, length: 0) }
        guard span(at: index) != nil else { return Self.missing }
        // AX character navigation uses the platform's Unicode composed range.
        // In VT's legacy (non-2027) mode a ZWJ sequence can span several cells;
        // geometry still unions those original cells, never inventing widths.
        return (text as NSString).rangeOfComposedCharacterSequence(at: index)
    }
    func line(for index: Int) -> Int {
        guard index >= 0, index <= length else { return -1 }
        if index == cursor?.offset, let cursor { return lines.firstIndex { $0.row == cursor.row } ?? -1 }
        if let span = span(at: index) { return lines.firstIndex { $0.row == span.row } ?? -1 }
        return lines.isEmpty ? -1 : lines.count - 1
    }
    func rangeForLine(_ index: Int) -> NSRange { lines.indices.contains(index) ? lines[index].range : Self.missing }
    func range(row: Int, column: Int) -> NSRange {
        guard let line = lines.first(where: { $0.row == row }), column >= 0, column < line.columns.count - 1 else { return Self.missing }
        let offset = line.columns[column]
        if let span = span(at: offset), span.row == row,
           column >= span.column, column < span.column + span.width { return range(at: offset) }
        return NSRange(location: offset, length: 0)
    }
    func localRect(_ span: Span, topRow: Int, cell: CGSize, height: CGFloat) -> CGRect {
        CGRect(x: CGFloat(span.column) * cell.width,
            y: height - CGFloat(span.row - topRow + 1) * cell.height,
            width: CGFloat(span.width) * cell.width, height: cell.height)
    }
    func bounds(for range: NSRange, topRow: Int, cell: CGSize, height: CGFloat, clip: CGRect) -> CGRect {
        guard valid(range) else { return .zero }
        if range.length == 0 {
            let position: (row: Int, column: Int)?
            if let cursor, cursor.offset == range.location { position = (cursor.row, cursor.column) }
            else if let span = span(at: range.location) { position = (span.row, span.column) }
            else { position = lines.last.map { ($0.row, max(0, $0.columns.count - 1)) } }
            guard let position else { return .zero }
            let rect = CGRect(x: CGFloat(position.column) * cell.width,
                y: height - CGFloat(position.row - topRow + 1) * cell.height, width: 1, height: cell.height)
            let result = rect.intersection(clip)
            return result.isNull ? .zero : result
        }
        var rect = CGRect.null
        for span in spans where NSIntersectionRange(span.range, range).length > 0 {
            rect = rect.union(localRect(span, topRow: topRow, cell: cell, height: height))
        }
        rect = rect.intersection(clip)
        return rect.isNull ? .zero : rect
    }
    func visibleRange(topRow: Int, cell: CGSize, height: CGFloat, clip: CGRect) -> NSRange {
        let visible = spans.filter { localRect($0, topRow: topRow, cell: cell, height: height).intersects(clip) }
        guard let first = visible.first, let last = visible.last else { return NSRange(location: length, length: 0) }
        return NSRange(location: first.range.location, length: last.range.location + last.range.length - first.range.location)
    }
}
