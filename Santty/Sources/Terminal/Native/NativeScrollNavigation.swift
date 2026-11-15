// Reuses Santty's physical-grid Scroll Mode movement policy, not CLI/AX text.
import Foundation

struct NativeScrollCell: Equatable, Comparable, Hashable, Sendable {
    var column: Int
    var row: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }
}

/// Temporary movement coordinates only. Persistent identity belongs to VT refs.
struct NativeScrollNavigation {
    var cell: NativeScrollCell
    var viewport: Int
    var columns: Int
    var rows: Int
    var total: Int

    mutating func move(_ movement: NativeScrollMovement, readCell: ((NativeScrollCell) -> String?)? = nil) {
        switch movement {
        case .left: cell.column -= 1
        case .right: cell.column += 1
        case .up: cell.row -= 1
        case .down: cell.row += 1
        case .lineStart: cell.column = 0
        case .lineEnd: cell.column = columns - 1
        case .top: cell = NativeScrollCell(column: 0, row: 0)
        case .bottom: cell.row = total - 1
        case .halfUp: cell.row -= max(1, rows / 2)
        case .halfDown: cell.row += max(1, rows / 2)
        case .pageUp: cell.row -= rows
        case .pageDown: cell.row += rows
        case .firstNonblank, .wordForward, .wordBackward, .wordEnd:
            guard let readCell else { return }
            moveThroughText(movement, readCell: readCell)
        }
        clampAndReveal()
    }

    private mutating func moveThroughText(_ movement: NativeScrollMovement,
                                         readCell: (NativeScrollCell) -> String?) {
        // Displayed rows are separated by whitespace, including soft wraps.
        let stride = columns + 1
        let last = (total - 1) * stride + columns - 1
        var index = cell.row * stride + cell.column
        let bigWord: Bool
        switch movement {
        case let .wordForward(big), let .wordBackward(big), let .wordEnd(big): bigWord = big
        default: bigWord = false
        }
        // Per-motion classifications only; the VT adapter imposes a strict read budget.
        var cache: [Int: Int] = [:]
        func kind(_ index: Int) -> Int? {
            guard index >= 0, index <= last else { return nil }
            if index % stride == columns { return 0 }
            if let cached = cache[index] { return cached }
            guard let text = readCell(.init(column: index % stride, row: index / stride)) else { return nil }
            let value: Int
            if text.isEmpty || text.allSatisfy(\.isWhitespace) { value = 0 }
            else if bigWord || text.first.map({ $0.isLetter || $0.isNumber || $0 == "_" }) == true { value = 1 }
            else { value = 2 }
            cache[index] = value
            return value
        }
        guard let initial = kind(index) else { return }
        switch movement {
        case .firstNonblank:
            index = cell.row * stride
            while index % stride < columns - 1, kind(index) == 0 { index += 1 }
            if kind(index) == 0 { index = cell.row * stride }
        case .wordForward:
            if initial != 0 {
                while index < last, kind(index) == initial { index += 1 }
            }
            while index < last, kind(index) == 0 { index += 1 }
        case .wordBackward:
            index = max(0, index - 1)
            while index > 0, kind(index) == 0 { index -= 1 }
            if let current = kind(index), current != 0 {
                while index > 0, kind(index - 1) == current { index -= 1 }
            }
        case .wordEnd:
            index = min(last, index + 1)
            while index < last, kind(index) == 0 { index += 1 }
            if let current = kind(index), current != 0 {
                while index < last, kind(index + 1) == current { index += 1 }
            }
        default: break
        }
        guard kind(index) != nil else { return }
        cell = .init(column: min(columns - 1, index % stride), row: index / stride)
    }

    mutating func clampAndReveal() {
        cell.column = min(max(0, cell.column), max(0, columns - 1))
        cell.row = min(max(0, cell.row), max(0, total - 1))
        viewport = min(viewport, cell.row)
        viewport = max(viewport, cell.row - rows + 1)
        viewport = min(max(0, viewport), max(0, total - rows))
    }
}

enum NativeScrollMovement: Equatable, Sendable {
    case left, right, up, down, lineStart, lineEnd, top, bottom
    case halfUp, halfDown, pageUp, pageDown
    case firstNonblank
    case wordForward(big: Bool), wordBackward(big: Bool), wordEnd(big: Bool)
}


enum NativeScrollModeAction: Sendable {
    case begin, move(NativeScrollMovement), toggleSelection(linewise: Bool), cancelSelection, end
}

struct NativeScrollModeState: Equatable, Sendable {
    enum Selection: Equatable, Sendable { case character, line }
    let cell: NativeScrollCell
    let viewport: Int
    let columns: Int
    let rows: Int
    let total: Int
    let selection: Selection?
}

struct NativeScrollModePresentation: Sendable {
    let state: NativeScrollModeState
    let presentation: NativeTerminalPresentation
}

struct NativeScrollModePointerResult: Sendable {
    let state: NativeScrollModeState
    let token: UUID?
}

struct NativeScrollCellContent: Equatable, Sendable {
    let text: String
    let width: Int
    let isWrapSpacer: Bool
    let isImagePlaceholder: Bool
}

enum NativeScrollModeError: Error, Equatable {
    case readBudget, invalidCell
}
