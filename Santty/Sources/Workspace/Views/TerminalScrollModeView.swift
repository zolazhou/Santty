import AppKit
import GhosttyTerminal

struct ScrollModeCell: Equatable, Comparable {
    var column: Int
    var row: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }
}

/// Coordinates belong to Ghostty's retained grid, never to a text snapshot.
// ponytail: row indices can drift when history is evicted; stable anchors need a core API.
struct ScrollModeCursor {
    var cell: ScrollModeCell
    var viewport: Int
    var columns: Int
    var rows: Int
    var total: Int

    mutating func move(_ movement: TerminalScrollMovement, readCell: ((ScrollModeCell) -> String?)? = nil) {
        switch movement {
        case .left: cell.column -= 1
        case .right: cell.column += 1
        case .up: cell.row -= 1
        case .down: cell.row += 1
        case .lineStart: cell.column = 0
        case .lineEnd: cell.column = columns - 1
        case .top: cell = ScrollModeCell(column: 0, row: 0)
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

    private mutating func moveThroughText(_ movement: TerminalScrollMovement,
                                         readCell: (ScrollModeCell) -> String?) {
        // Displayed rows are separated by whitespace, including soft wraps.
        let stride = columns + 1
        let last = (total - 1) * stride + columns - 1
        var index = cell.row * stride + cell.column
        let bigWord: Bool
        switch movement {
        case let .wordForward(big), let .wordBackward(big), let .wordEnd(big): bigWord = big
        default: bigWord = false
        }
        // ponytail: read cells lazily per motion; batch native cell reads if key repeat becomes costly.
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

/// Transparent input/cursor layer; Ghostty still renders every cell and selection.
@MainActor
final class TerminalScrollModeView: NSView {
    private let terminalView: TerminalView
    private(set) var cursor: ScrollModeCursor
    private var anchor: ScrollModeCell?
    private var linewise = false
    private var mouseAnchor: ScrollModeCell?
    private let copyFlashLayer = CALayer()
    var onSelectionChange: ((String) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        let grid = terminalView.scrollModeGrid
        let viewport = terminalView.scrollModeViewport
        let rows = max(1, Int(grid?.rows ?? 1))
        let offset = viewport?.offset ?? 0
        cursor = ScrollModeCursor(
            cell: ScrollModeCell(column: 0, row: offset + rows - 1),
            viewport: offset, columns: max(1, Int(grid?.columns ?? 1)),
            rows: rows, total: max(rows, viewport?.total ?? rows)
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        copyFlashLayer.backgroundColor = NSColor.systemYellow.cgColor
        copyFlashLayer.opacity = 0
        layer?.addSublayer(copyFlashLayer)
        if offset == max(0, cursor.total - rows), let point = terminalView.scrollModeInputPoint {
            cursor.cell = cell(at: point)
        }
        setAccessibilityElement(true)
        setAccessibilityLabel("Scroll mode cursor")
        updateLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var cellSize: CGSize {
        let scale = terminalView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let grid = terminalView.scrollModeGrid
        return CGSize(width: max(1, CGFloat(grid?.cellWidthPixels ?? 1) / scale),
                      height: max(1, CGFloat(grid?.cellHeightPixels ?? 1) / scale))
    }

    override func layout() {
        super.layout()
        guard let grid = terminalView.scrollModeGrid else { return }
        if cursor.columns != Int(grid.columns) || cursor.rows != Int(grid.rows) {
            // Grid reflow invalidates application-owned row/column anchors.
            _ = cancelSelection()
            cursor.columns = max(1, Int(grid.columns))
            cursor.rows = max(1, Int(grid.rows))
            cursor.clampAndReveal()
            updateSelection()
        }
        needsDisplay = true
    }

    func updateViewport(_ viewport: TerminalScrollViewport) {
        if viewport.total < cursor.total { _ = cancelSelection() }
        cursor.total = max(cursor.rows, viewport.total)
        cursor.viewport = viewport.offset
        cursor.cell.row = min(cursor.cell.row, cursor.total - 1)
        needsDisplay = true
    }

    func move(_ movement: TerminalScrollMovement) {
        var next = cursor
        var readingViewport = cursor.viewport
        let maxViewport = max(0, cursor.total - cursor.rows)
        let rows = cursor.rows
        next.move(movement) { [terminalView] cell in
            if cell.row < readingViewport || cell.row >= readingViewport + rows {
                readingViewport = min(cell.row, maxViewport)
                terminalView.scrollToRow(UInt(readingViewport))
            }
            return terminalView.readScrollModeCell(column: cell.column, row: cell.row - readingViewport)
        }
        cursor = next
        updateSelection()
    }

    func toggleSelection(linewise: Bool) {
        if anchor != nil, self.linewise == linewise { _ = cancelSelection() }
        else {
            anchor = anchor ?? cursor.cell
            self.linewise = linewise
            updateSelection()
        }
    }

    @discardableResult
    func cancelSelection() -> Bool {
        guard anchor != nil else { return false }
        anchor = nil
        linewise = false
        terminalView.clearScrollModeSelection()
        updateLabel()
        return true
    }

    func copySelection(to pasteboard: NSPasteboard = .general) {
        guard anchor != nil, let text = terminalView.readScrollModeSelection(), !text.isEmpty else { return }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        copyFlashLayer.frame = cursorRect
        CATransaction.commit()
        let flash = CABasicAnimation(keyPath: "opacity")
        flash.fromValue = 0.85
        flash.toValue = 0
        flash.duration = 0.3
        flash.timingFunction = CAMediaTimingFunction(name: .easeOut)
        copyFlashLayer.add(flash, forKey: "copyFlash")
    }

    private func updateSelection() {
        if let anchor {
            var start = min(anchor, cursor.cell)
            var end = max(anchor, cursor.cell)
            if linewise {
                start.column = 0
                end.column = cursor.columns - 1
            }
            let startViewport = min(start.row, max(0, cursor.total - cursor.rows))
            let endViewport = min(end.row, max(0, cursor.total - cursor.rows))
            terminalView.selectScrollModeText(
                start: point(for: start, viewport: startViewport, fraction: 0.1), startViewport: startViewport,
                end: point(for: end, viewport: endViewport, fraction: 0.9), endViewport: endViewport,
                restoringViewport: cursor.viewport
            )
        } else {
            terminalView.scrollToRow(UInt(cursor.viewport))
        }
        updateLabel()
        needsDisplay = true
    }

    private func updateLabel() {
        let title = anchor == nil ? "SCROLL" : linewise ? "SELECT LINE" : "SELECT"
        onSelectionChange?(title)
        setAccessibilityValue("\(title), row \(cursor.cell.row + 1), column \(cursor.cell.column + 1)")
    }

    private func point(for cell: ScrollModeCell, viewport: Int, fraction: CGFloat) -> CGPoint {
        CGPoint(x: TerminalDefaults.innerPadding + (CGFloat(cell.column) + fraction) * cellSize.width,
                y: TerminalDefaults.innerPadding + (CGFloat(cell.row - viewport) + 0.5) * cellSize.height)
    }

    private func cell(at point: CGPoint) -> ScrollModeCell {
        ScrollModeCell(
            column: min(cursor.columns - 1, max(0, Int((point.x - TerminalDefaults.innerPadding) / cellSize.width))),
            row: cursor.viewport + min(cursor.rows - 1, max(0, Int((point.y - TerminalDefaults.innerPadding) / cellSize.height)))
        )
    }

    private var cursorRect: NSRect {
        let center = point(for: cursor.cell, viewport: cursor.viewport, fraction: 0.5)
        return NSRect(x: center.x - cellSize.width / 2, y: center.y - cellSize.height / 2,
                      width: cellSize.width, height: cellSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard cursor.cell.row >= cursor.viewport, cursor.cell.row < cursor.viewport + cursor.rows else { return }
        NSColor.systemYellow.setStroke()
        let path = NSBezierPath(rect: cursorRect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        _ = cancelSelection()
        cursor.cell = cell(at: convert(event.locationInWindow, from: nil))
        mouseAnchor = cursor.cell
        updateSelection()
    }

    override func mouseDragged(with event: NSEvent) {
        anchor = mouseAnchor
        cursor.cell = cell(at: convert(event.locationInWindow, from: nil))
        updateSelection()
    }

    override func mouseUp(with event: NSEvent) { mouseAnchor = nil }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? -event.scrollingDeltaY / cellSize.height : -event.scrollingDeltaY
        let lines = Int(delta.rounded(.awayFromZero))
        guard lines != 0 else { return }
        cursor.cell.row += lines
        cursor.clampAndReveal()
        updateSelection()
    }

    @objc func copy(_ sender: Any?) { copySelection() }
}

enum TerminalScrollMovement: Equatable {
    case left, right, up, down, lineStart, lineEnd, top, bottom
    case halfUp, halfDown, pageUp, pageDown
    case firstNonblank
    case wordForward(big: Bool), wordBackward(big: Bool), wordEnd(big: Bool)
}
