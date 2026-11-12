import Foundation

/// Unsafe-scalar policy adapted from SwiftTerm/Mac/UntrustedTerminalLink.swift
/// (28c6d1d), originally Ghostty 77537c8. See Link-Adaptation-NOTICE.txt.
/// More conservative than the production pane: no local file inspection,
/// relative paths or custom Launch Services handlers in this experiment.
enum NativeTerminalLink {
    static let maximumBytes = 8 * 1024
    static let frameByteBudget = 128 * 1024

    static func url(_ text: String) -> URL? {
        // Reject paths/file/custom schemes before invoking even the shared
        // parser's local file-URL constructor. Remote paths never touch the FS.
        guard let colon = text.firstIndex(of: ":"),
              ["http", "https", "mailto"].contains(text[..<colon].lowercased()),
              text.utf8.count <= maximumBytes,
              !unsafe(text), let decoded = text.removingPercentEncoding, !unsafe(decoded),
              let url = TerminalLinkValidation.url(encodeNonASCII(text)),
              let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme),
              url.user == nil, url.password == nil else { return nil }
        if scheme == "mailto", url.path.isEmpty { return nil }
        return url
    }

    /// Foundation's strict parser rejects unescaped Unicode too. Encode only
    /// non-ASCII scalars, never ASCII whitespace/control/invalid '%' escapes.
    private static func encodeNonASCII(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            scalar.value < 128 ? String(scalar) : String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
    }

    private static func unsafe(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            switch $0.value {
            case 0...0x1F, 0x7F...0x9F, 0x061C, 0x200B...0x200F, 0x202A...0x202E,
                 0x2066...0x2069, 0x2028...0x2029, 0x2060, 0xFEFF: return true
            default: return false
            }
        }
    }
}

struct NativeTerminalLinkMatch: Sendable {
    let uri: String
    let isExplicit: Bool
    let ranges: [Int: Range<Int>]

    func matches(_ other: Self, rowOffset: Int = 0) -> Bool {
        isExplicit == other.isExplicit && uri.utf8.elementsEqual(other.uri.utf8)
            && ranges.count == other.ranges.count
            && other.ranges.allSatisfy { ranges[$0.key + rowOffset] == $0.value }
    }
}

/// SwiftTerm Terminal.swift's scheme-URL tokens and cell-range mapping, adapted
/// to owned VT frames (not SwiftTerm's emulator). See Link-Adaptation-NOTICE.txt.
/// Only a bounded captured soft-wrap group is inspected; no history text cache,
/// hard-line guessing, local path resolution or filesystem access is involved.
enum NativeTerminalLinkMatcher {
    private struct Cell {
        let row: Int
        let column: Int
        let value: NativeTerminalCell
        let textRange: NSRange
    }
    private static let maximumScanUnits = 64 * 1024
    private static let pattern: NSRegularExpression? = {
        // Preserve SwiftTerm's linear tokens, not the upstream nested `+`
        // expressions which catastrophically backtrack on malformed IPv6/dots.
        let ipv6 = #"(?:\[[:0-9a-fA-F]+\](?::[0-9]+)?)"#
        let character = #"[\w\-.~:/?#@!$&*+,;=%]"#
        let suffix = #"(?:[\(\[]\w*[\)\]])"#
        // Do not recognize a nested scheme inside another URL/path token.
        let boundary = #"(?<![\w\-.~:/?#@!$&*+,;=%])"#
        return try? NSRegularExpression(pattern: boundary + #"(?:https?://|mailto:)"#
            + "(?:" + ipv6 + "|" + character + "(?:" + suffix + ")?)+" + #"(?<![,.])"#,
            options: [.caseInsensitive])
    }()

    static func match(in frame: NativeTerminalFrame, column: Int, row: Int) -> NativeTerminalLinkMatch? {
        guard let target = frame.rows[row], target.cells.indices.contains(column) else { return nil }
        var column = column
        if target.cells[column].width == 0, column > 0, target.cells[column - 1].width == 2 { column -= 1 }
        var first = row, last = row
        while frame.rows[first]?.isWrapped == true, frame.rows[first - 1] != nil { first -= 1 }
        while frame.rows[last + 1]?.isWrapped == true { last += 1 }

        var text = "", cells: [Cell] = [], units = 0
        for line in first...last {
            guard let data = frame.rows[line] else { return nil }
            for (index, cell) in data.cells.enumerated() where cell.width > 0 && !cell.isWrapSpacer {
                let value = cell.text ?? " "
                let length = value.utf16.count
                guard units + length <= maximumScanUnits else { return nil }
                cells.append(.init(row: line, column: index, value: cell,
                    textRange: NSRange(location: units, length: length)))
                text += value; units += length
            }
        }
        guard let hit = cells.firstIndex(where: { $0.row == row && $0.column == column }) else { return nil }
        if let uri = cells[hit].value.hyperlink {
            var lower = hit, upper = hit + 1
            func same(_ cell: Cell) -> Bool { cell.value.hyperlink?.utf8.elementsEqual(uri.utf8) == true }
            while lower > 0, same(cells[lower - 1]) { lower -= 1 }
            while upper < cells.count, same(cells[upper]) { upper += 1 }
            return .init(uri: uri, isExplicit: true, ranges: ranges(cells[lower..<upper]))
        }
        // A dropped/over-budget OSC 8 target must not turn its label into an
        // implicit link. Explicit metadata always takes precedence, even unsafe.
        guard !cells[hit].value.hasExplicitHyperlink, let pattern else { return nil }
        for result in pattern.matches(in: text, range: NSRange(location: 0, length: units)) {
            guard NSIntersectionRange(result.range, cells[hit].textRange).length > 0,
                  let stringRange = Range(result.range, in: text) else { continue }
            let selected = cells.filter { NSIntersectionRange(result.range, $0.textRange).length > 0 }
            guard !selected.contains(where: { $0.value.hasExplicitHyperlink || $0.value.hyperlink != nil }),
                  let start = selected.first, let end = selected.last,
                  start.textRange.location == result.range.location,
                  NSMaxRange(end.textRange) == NSMaxRange(result.range) else { return nil }
            // Never activate a prefix clipped by the bounded frame boundary.
            if result.range.location == 0, frame.rows[first]?.isWrapped == true { return nil }
            if NSMaxRange(result.range) == units, last + 1 < frame.totalRows,
               frame.rows[last + 1] == nil { return nil }
            // An unsupported/invisible character inside a word is not a
            // license to open its otherwise valid prefix instead.
            if let next = text[stringRange.upperBound...].first,
               !" \t\r\n<>\"'`)]}.,".contains(next) { return nil }
            let uri = String(text[stringRange])
            guard NativeTerminalLink.url(uri) != nil else { return nil }
            return .init(uri: uri, isExplicit: false, ranges: ranges(selected[...]))
        }
        return nil
    }

    private static func ranges(_ cells: ArraySlice<Cell>) -> [Int: Range<Int>] {
        var result: [Int: Range<Int>] = [:]
        for cell in cells {
            let old = result[cell.row]
            result[cell.row] = min(old?.lowerBound ?? cell.column, cell.column)..<max(
                old?.upperBound ?? cell.column, cell.column + cell.value.width)
        }
        return result
    }
}
