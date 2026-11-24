import AppKit

/// Decoration only, above both CG content and SwiftTerm's Metal child. Never
/// a first responder, hit-test destination, AX text source or terminal surface.
@MainActor
final class NativeScrollModeOverlay: NSView {
    private(set) var cursorRect = CGRect.zero
    private(set) var badgeRect = CGRect.zero
    private(set) var title = "SCROLL"
    private(set) var flashRect: CGRect?
    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame:.zero)
        setAccessibilityElement(false)
        wantsLayer = true // its own backing must sit above the Metal child layer
        layer?.masksToBounds = true
        isHidden = true
    }
    required init?(coder: NSCoder) { nil }

    func update(state: NativeScrollModeState, frame: NativeTerminalFrame, topRow: Int,
                cell: CGSize, bounds: CGRect, clip: CGRect, awaitingG: Bool, limited: Bool) {
        self.frame = bounds
        let width = frame.rows[state.cell.row]?.cells.indices.contains(state.cell.column) == true
            ? max(1, frame.rows[state.cell.row]!.cells[state.cell.column].width) : 1
        cursorRect = CGRect(x: CGFloat(state.cell.column) * cell.width,
            y: bounds.height - CGFloat(state.cell.row - topRow + 1) * cell.height,
            width: CGFloat(width) * cell.width, height: cell.height).intersection(clip)
        title = state.selection == .line ? "SELECT LINE" : state.selection == .character ? "SELECT" : "SCROLL"
        if awaitingG { title += " · g" }
        if limited { title += " · limit" }
        badgeRect = CGRect(x: clip.minX + 8, y: clip.minY + 8, width: min(max(0, clip.width - 16), 150), height: 24).intersection(clip)
        isHidden = false; needsDisplay = true
    }

    func clear() {
        isHidden = true; cursorRect = .zero; badgeRect = .zero; flashRect = nil
        needsDisplay = true
    }
    func clearPendingPrefix() {
        if title.contains(" · g") { title = title.replacingOccurrences(of:" · g",with:""); needsDisplay = true }
    }
    func flash() { flashRect = cursorRect; needsDisplay = true }
    func clearFlash() { flashRect = nil; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard !isHidden else { return }
        if let flashRect, !flashRect.isEmpty {
            NSColor.systemYellow.withAlphaComponent(0.35).setFill(); flashRect.fill()
        }
        if !cursorRect.isEmpty {
            NSColor.systemYellow.setStroke()
            let path = NSBezierPath(rect: cursorRect.insetBy(dx:0.5,dy:0.5))
            path.lineWidth = 1; path.stroke()
        }
        if !badgeRect.isEmpty {
            NSColor.black.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect:badgeRect,xRadius:5,yRadius:5).fill()
            title.draw(at:CGPoint(x:badgeRect.minX+7,y:badgeRect.minY+5), withAttributes:[
                .font:NSFont.monospacedSystemFont(ofSize:11,weight:.semibold), .foregroundColor:NSColor.systemYellow])
        }
    }
}
