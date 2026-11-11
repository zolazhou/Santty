import AppKit
import SwiftTerm

/// Its large document is geometry only; just one viewport-sized renderer is
/// retained. Moving the clip view supplies fractional scrolling and elasticity
/// without translating the VT's logical state by fractions.
@MainActor
final class NativeTerminalScrollView: NSScrollView {
    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    let renderer: TerminalRenderView
    let source = SwiftTermFrameSource()
    let driver: GhosttyVTDriver
    private let virtualDocument = Document()
    private var geometry: NativeViewport?
    private var isUpdating = false
    private var lastRenderedRow: Int?
    private var lastSurfaceSize = CGSize.zero
    private var lastCellSize = CGSize.zero
    private(set) var lastError: String?
    var onStatusChange: ((String) -> Void)?

    init(driver: GhosttyVTDriver, frame: NSRect = .zero) {
        self.driver = driver
        renderer = TerminalRenderView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .automatic
        horizontalScrollElasticity = .none
        // Only the bounded renderer is layer-backed, not the tall document.
        virtualDocument.wantsLayer = false
        documentView = virtualDocument
        virtualDocument.addSubview(renderer)
        renderer.frameSource = source
        // Ghostty owns cell ordering. Don't introduce a second bidi policy.
        renderer.bidiHostPolicy = .legacyLeftToRight
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        // Scrolling may cause AppKit layout without a viewport-size change.
        // Fractional movement must not trigger parsing or frame production.
        if geometry?.viewportHeight != contentSize.height || lastSurfaceSize.width != contentSize.width
            || lastCellSize != renderer.cellSize {
            refresh(resizeTerminal: true)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh(resizeTerminal: true)
    }

    func setMetal(_ enabled: Bool) throws {
        try renderer.setUseMetal(enabled)
        refresh()
    }

    func feed(_ text: String) {
        driver.feed(text)
        refresh()
    }

    func reset(with fixture: String) {
        driver.reset()
        driver.feed(fixture)
        geometry = nil
        refresh()
    }

    /// Re-publish output; pure clip movement calls renderViewport instead.
    func refresh(resizeTerminal: Bool = false) {
        guard !isUpdating, contentSize.width > 0, contentSize.height > 0 else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            if resizeTerminal {
                let cell = renderer.cellSize
                let columns = max(1, min(4096, Int(contentSize.width / cell.width)))
                let rows = max(1, min(1024, Int(contentSize.height / cell.height)))
                if driver.columns != columns || driver.rows != rows {
                    let scale = window?.backingScaleFactor ?? 1
                    try driver.resize(columns: columns, rows: rows,
                        cellWidth: UInt32(max(1, (cell.width * scale).rounded())),
                        cellHeight: UInt32(max(1, (cell.height * scale).rounded())))
                }
            }
            let total = try driver.totalRows
            let offset = geometry?.offsetAfterUpdate(totalRows: total, viewportHeight: contentSize.height,
                rowHeight: renderer.cellSize.height)
            let next = NativeViewport(rowHeight: renderer.cellSize.height, viewportHeight: contentSize.height,
                                      totalRows: total, offset: offset ?? .greatestFiniteMagnitude)
            virtualDocument.setFrameSize(NSSize(width: contentSize.width, height: next.documentHeight))
            contentView.scroll(to: NSPoint(x: 0, y: offset ?? next.maximumOffset))
            reflectScrolledClipView(contentView)
            try renderViewport(force: true)
            lastCellSize = renderer.cellSize
            lastError = nil
        } catch { report(error) }
    }

    @objc private func clipBoundsChanged() {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        do { try renderViewport(force: false) }
        catch { report(error) }
    }

    private func renderViewport(force: Bool) throws {
        let next = NativeViewport(rowHeight: renderer.cellSize.height, viewportHeight: contentSize.height,
                                  totalRows: try driver.totalRows, offset: contentView.bounds.minY)
        let size = CGSize(width: contentSize.width, height: next.renderHeight)
        if force || lastRenderedRow != next.firstRow || lastSurfaceSize != size {
            let snapshot = try driver.snapshot(topRow: next.firstRow)
            source.apply(snapshot, topLine: next.firstRow, renderRows: next.renderRows)
            if renderer.nativeForegroundColor != snapshot.foreground.nsColor {
                renderer.nativeForegroundColor = snapshot.foreground.nsColor
            }
            if renderer.nativeBackgroundColor != snapshot.background.nsColor {
                renderer.nativeBackgroundColor = snapshot.background.nsColor
            }
            if renderer.caretColor != snapshot.cursorColor.nsColor {
                renderer.caretColor = snapshot.cursorColor.nsColor
            }
            // A flipped parent places this nonflipped renderer by its top edge.
            let frame = NSRect(x: 0, y: next.renderOrigin, width: size.width, height: size.height)
            if renderer.frame != frame { renderer.frame = frame }
            renderer.presentExternalFrame()
            lastRenderedRow = next.firstRow
            lastSurfaceSize = size
        }
        geometry = next
        onStatusChange?("\(driver.columns)×\(driver.rows) · row \(next.firstRow) + \(String(format: "%.2f", next.fraction)) pt · cached \(source.lines.count) rows · \(renderer.isUsingMetalRenderer ? "Metal" : "Core Graphics")")
    }

    private func report(_ error: Error) {
        lastError = String(describing: error)
        onStatusChange?("Error: \(error)")
    }

    /// Viewport-local coordinates are also the basis for future IME and mouse
    /// routing. Elastic empty space has no terminal cell.
    func cell(atViewportPoint point: NSPoint) -> (column: Int, row: Int)? {
        guard let geometry, point.x >= 0, point.x < contentSize.width,
              let row = geometry.row(atViewportY: point.y) else { return nil }
        let column = Int(floor(point.x / renderer.cellSize.width))
        guard column < driver.columns else { return nil }
        return (column, row)
    }
}
