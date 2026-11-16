import AppKit

enum TerminalPaddingFill: String, CaseIterable, Identifiable, Sendable {
    case off, automatic, always
    var id: Self { self }
    var title: String {
        switch self {
        case .off: "Off"
        case .automatic: "Automatic"
        case .always: "Always"
        }
    }
    func isEnabled(alternateScreen: Bool) -> Bool {
        self == .always || (self == .automatic && alternateScreen)
    }
}

/// Horizontal-only background extension over owned, already-published VT cells.
/// Top/bottom padding and incomplete-row space keep their original background.
/// The outer instance sits behind the scroll view; the remainder instance sits above the
/// renderer but BELOW AppKit's scroller. Neither changes layout, captures VT,
/// includes selection/caret colors, handles input, or schedules a wake.
@MainActor
final class NativeTerminalPaddingFillView: NSView {
    private weak var terminal: NativeTerminalScrollView?
    private let remainder: Bool
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(remainder: Bool = false) {
        self.remainder = remainder
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    func bind(to terminal: NativeTerminalScrollView) {
        self.terminal = terminal
        if !remainder { terminal.outerPaddingFill = self }
        invalidate()
    }

    func invalidate() {
        let enabled: Bool
        if let terminal, let snapshot = terminal.presentedFrame, let viewport = terminal.presentedViewport {
            enabled = terminal.settings?.paddingFill.isEnabled(alternateScreen: snapshot.isAlternateScreen) == true
                && viewport.offset >= 0 && viewport.offset <= viewport.maximumOffset
        } else { enabled = false }
        // Ordinary primary-screen output must not repaint two empty surfaces.
        isHidden = !enabled
        if enabled { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let terminal, let snapshot = terminal.presentedFrame,
              let viewport = terminal.presentedViewport, let settings = terminal.settings,
              settings.paddingFill.isEnabled(alternateScreen: snapshot.isAlternateScreen),
              viewport.offset >= 0, viewport.offset <= viewport.maximumOffset,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let cell = terminal.presentedCellSize
        guard cell.width > 0, cell.height > 0, snapshot.columns > 0, viewport.totalRows > 0 else { return }
        let clip = convert(terminal.contentView.bounds, from: terminal.contentView)
        guard clip.width > 0, clip.height > 0 else { return }
        let first = max(0, Int(floor(viewport.offset / cell.height)))
        let last = min(viewport.totalRows - 1, Int(ceil((viewport.offset + clip.height) / cell.height)) - 1)
        guard first <= last else { return }

        context.saveGState()
        defer { context.restoreGState() }
        if remainder {
            context.clip(to: clip)
        } else {
            // The renderer already paints its default background. Never put
            // another translucent coat underneath it inside the viewport.
            context.addRect(bounds)
            context.addRect(clip)
            context.clip(using: .evenOdd)
        }

        struct Color {
            let rgb: NativeRGB
            let alpha: CGFloat
            let isDefault: Bool
        }
        func color(_ cell: NativeTerminalCell) -> Color {
            let inverse = cell.style.contains(.inverse)
            let value = inverse ? cell.foreground : cell.background
            switch value {
            case .defaultColor:
                return Color(rgb: inverse ? snapshot.foreground : snapshot.background,
                             alpha: inverse ? 1 : settings.backgroundOpacity, isDefault: !inverse)
            case .palette(let index):
                return Color(rgb: snapshot.palette[Int(index)], alpha: 1, isDefault: false)
            case .rgb(let rgb):
                return Color(rgb: rgb, alpha: 1, isDefault: false)
            }
        }
        func fill(_ rect: NSRect, _ color: Color) {
            // Default-background remainder pixels are already correct, even
            // with opacity < 1. Explicit cell backgrounds remain opaque.
            guard rect.width > 0, rect.height > 0, rect.intersects(dirtyRect),
                  !(remainder && color.isDefault), color.alpha > 0 else { return }
            color.rgb.nsColor.withAlphaComponent(color.alpha).setFill()
            context.fill(rect)
        }
        let left = clip.minX
        let right = left + CGFloat(snapshot.columns) * cell.width
        let top = clip.minY
        let bottom = min(clip.maxY, clip.minY + CGFloat(last + 1) * cell.height - viewport.offset)
        for row in first...last {
            guard let cells = snapshot.rows[row]?.cells, let leading = cells.first, let trailing = cells.last else { continue }
            let y = max(top, clip.minY + CGFloat(row) * cell.height - viewport.offset)
            let end = min(bottom, clip.minY + CGFloat(row + 1) * cell.height - viewport.offset)
            fill(NSRect(x: bounds.minX, y: y, width: left - bounds.minX, height: end - y), color(leading))
            fill(NSRect(x: right, y: y, width: bounds.maxX - right, height: end - y), color(trailing))
        }
    }
}
