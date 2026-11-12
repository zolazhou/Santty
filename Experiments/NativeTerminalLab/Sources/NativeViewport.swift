import Foundation

/// Owned result of an atomic anchor resolution + bounded VT frame capture.
struct NativeTerminalPresentation {
    enum Anchor: Equatable {
        case following
        case preserved(column: Int)
        case oldestAvailable
    }
    let viewport: NativeViewport
    let frame: NativeTerminalFrame
    let anchor: Anchor
}

/// Pure geometry. The scroll view owns motion; this type never adds easing.
struct NativeViewport: Equatable {
    let rowHeight: CGFloat
    let viewportHeight: CGFloat
    let totalRows: Int
    let offset: CGFloat

    init(rowHeight: CGFloat, viewportHeight: CGFloat, totalRows: Int, offset: CGFloat) {
        self.rowHeight = rowHeight.isFinite ? max(1, rowHeight) : 1
        self.viewportHeight = viewportHeight.isFinite ? max(0, viewportHeight) : 0
        self.totalRows = max(0, totalRows)
        self.offset = offset.isFinite ? offset : 0
    }

    var documentHeight: CGFloat { max(viewportHeight, CGFloat(totalRows) * rowHeight) }
    var maximumOffset: CGFloat { max(0, documentHeight - viewportHeight) }
    var clampedOffset: CGFloat { min(max(0, offset), maximumOffset) }
    var firstRow: Int { Int(floor(clampedOffset / rowHeight)) }
    var fraction: CGFloat { clampedOffset - CGFloat(firstRow) * rowHeight }
    var renderRows: Int { max(1, Int(ceil(viewportHeight / rowHeight)) + 2) }
    var renderOrigin: CGFloat { CGFloat(firstRow) * rowHeight }
    var renderHeight: CGFloat { CGFloat(renderRows) * rowHeight }
    var isAtBottom: Bool { clampedOffset >= maximumOffset - 0.5 }

    /// Includes AppKit's elastic displacement, not just the clamped VT viewport.
    func row(atViewportY y: CGFloat) -> Int? {
        let documentY = offset + y
        guard y >= 0, y < viewportHeight, documentY >= 0,
              documentY < CGFloat(totalRows) * rowHeight else { return nil }
        return Int(floor(documentY / rowHeight))
    }

    /// Geometry-only fallback for callers with unchanged logical row indices.
    /// Live terminal presentation must resolve the driver's content reference.
    func offsetAfterUpdate(totalRows: Int, viewportHeight: CGFloat, rowHeight: CGFloat) -> CGFloat {
        let next = NativeViewport(rowHeight: rowHeight, viewportHeight: viewportHeight,
                                  totalRows: totalRows, offset: 0)
        if isAtBottom { return next.maximumOffset }
        // Keep the same logical row and sub-row position on a font-size change.
        return min(next.maximumOffset, max(0, (CGFloat(firstRow) + fraction / self.rowHeight) * next.rowHeight))
    }
}
