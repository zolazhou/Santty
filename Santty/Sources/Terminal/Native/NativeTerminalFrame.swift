import Foundation

struct NativeRGB: Equatable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
}

enum NativeCellColor: Equatable, Sendable {
    case defaultColor
    case palette(UInt8)
    case rgb(NativeRGB)
}

struct NativeCellStyle: OptionSet, Sendable {
    let rawValue: UInt16
    static let bold = Self(rawValue: 1 << 0)
    static let italic = Self(rawValue: 1 << 1)
    static let faint = Self(rawValue: 1 << 2)
    static let blink = Self(rawValue: 1 << 3)
    static let inverse = Self(rawValue: 1 << 4)
    static let invisible = Self(rawValue: 1 << 5)
    static let strike = Self(rawValue: 1 << 6)
    static let overline = Self(rawValue: 1 << 7)
}

struct NativeTerminalCell: Equatable, Sendable {
    var text: String?
    var width: Int
    var foreground: NativeCellColor
    var background: NativeCellColor
    var underlineColor: NativeCellColor
    var style: NativeCellStyle
    var underline: UInt8
    var hyperlink: String? = nil
    var hasExplicitHyperlink = false
    var isWrapSpacer = false
    var isImagePlaceholder = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        // URL paths can distinguish canonically equivalent Unicode bytes.
        // String's normalized equality must not hide a target-only change.
        sameBytes(lhs.text, rhs.text) && sameBytes(lhs.hyperlink, rhs.hyperlink)
            && lhs.width == rhs.width && lhs.foreground == rhs.foreground
            && lhs.background == rhs.background && lhs.underlineColor == rhs.underlineColor
            && lhs.style == rhs.style && lhs.underline == rhs.underline
            && lhs.hasExplicitHyperlink == rhs.hasExplicitHyperlink && lhs.isWrapSpacer == rhs.isWrapSpacer
            && lhs.isImagePlaceholder == rhs.isImagePlaceholder
    }

    private static func sameBytes(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.utf8.elementsEqual(rhs.utf8)
        default: return false
        }
    }
}

struct NativeRowID: Hashable, Sendable {
    let first: UInt64
    let second: UInt64
}

/// Owned data only: no borrowed C pointers survive a render-state update.
final class NativeTerminalRow: Sendable {
    let id: NativeRowID
    let cells: [NativeTerminalCell]
    let isWrapped: Bool
    let hyperlinkBytes: Int

    init(id: NativeRowID, cells: [NativeTerminalCell], isWrapped: Bool) {
        self.id = id
        self.cells = cells
        self.isWrapped = isWrapped
        self.hyperlinkBytes = cells.reduce(0) { $0 + ($1.hyperlink?.utf8.count ?? 0) }
    }
}

struct NativeTerminalFrame: Sendable {
    enum CursorShape: Sendable, Equatable { case block, bar, underline, hollow }
    struct Cursor: Sendable {
        var line: Int
        var column: Int
        var visible: Bool
        var blinking: Bool
        var shape: CursorShape
    }

    let columns: Int
    let terminalRows: Int
    let totalRows: Int
    let topRow: Int
    let rows: [Int: NativeTerminalRow]
    let cursor: Cursor
    let foreground: NativeRGB
    let background: NativeRGB
    let cursorColor: NativeRGB
    let palette: [NativeRGB]
    let isAlternateScreen: Bool
    var selection: [Int: ClosedRange<Int>] = [:]
    var imageSnapshot: NativeImageSnapshot = .empty
    var accessibleText: NativeAXFormattedText = .unavailable
}
