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

    let renderer: NativeTerminalInputView
    let source = SwiftTermFrameSource()
    let driver: GhosttyVTDriver
    private let virtualDocument = Document()
    let remainderFillView = NativeTerminalPaddingFillView(remainder: true)
    weak var outerPaddingFill: NativeTerminalPaddingFillView?
    private var geometry: NativeViewport?
    private var interaction: NativeTerminalInteraction!
    private(set) var scrollModeController: NativeScrollModeController!
    private(set) var hostActions: NativeTerminalHostActions!
    var isAtLiveBottom: Bool { geometry?.isAtBottom ?? true }
    var presentedViewport: NativeViewport? { geometry }
    var presentedCellSize: CGSize { lastCellSize }
    var canAutoscrollScrollMode: Bool { canPresentOutput }
    var permitsScrollModePointer: Bool {
        !displayAsleep && !isHiddenOrHasHiddenAncestor
            && (renderer.output == nil || (!applicationIsHidden() && canPresentOutput))
    }
    private(set) var presentedFrame: NativeTerminalFrame?
    var openLink: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    private var isUpdating = false
    private var linkHighlightDirty = false
    private var lastRenderedRow: Int?
    private var lastSurfaceSize = CGSize.zero
    private var lastCellSize = CGSize.zero
    private(set) var lastError: String?
    var onStatusChange: ((String) -> Void)?
    var onViewportChange: ((TerminalStreamViewport) -> Void)?
    var onAutomaticReplies: ((Data) -> Void)?
    private var lastViewport: TerminalStreamViewport?
    private var holdTask: Task<Void, Never>?
    private var imageAnimationTask: Task<Void, Never>?
    private var imageAnimationToken: UUID?
    private(set) var scheduledImageAnimationDeadline: UInt64?
    private var displayAsleep = false
    private let applicationIsHidden: @MainActor () -> Bool
    private(set) var hasPendingOutput = false
    private(set) var settings: NativeTerminalSettings?
    var onSettingsChange: (() -> Void)?

    init(driver: GhosttyVTDriver, frame: NSRect = .zero,
         applicationIsHidden: @escaping @MainActor () -> Bool = { NSApp.isHidden }) {
        self.driver = driver
        self.applicationIsHidden = applicationIsHidden
        renderer = NativeTerminalInputView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        super.init(frame: frame)
        interaction = NativeTerminalInteraction(view: self)
        scrollModeController = NativeScrollModeController(view: self)
        renderer.scrollModeController = scrollModeController
        hostActions = NativeTerminalHostActions(view:self)
        renderer.hostActions = hostActions
        drawsBackground = false
        automaticallyAdjustsContentInsets = false
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
        virtualDocument.addSubview(remainderFillView)
        remainderFillView.bind(to: self)
        renderer.frameSource = source
        // Ghostty owns cell ordering. Don't introduce a second bidi policy.
        renderer.bidiHostPolicy = .legacyLeftToRight
        renderer.onInputActivity = { [weak self] in self?.interaction.keyboardInput() }
        renderer.onPointerEvent = { [weak self] event in
            guard let self else { return true }
            if self.scrollModeController.isActive { return self.scrollModeController.pointer.mouse(event) }
            return self.interaction.mouse(event)
        }
        renderer.onPointerModifiersChanged = { [weak self] flags in
            guard let self, !self.scrollModeController.isActive else { return }
            self.interaction.modifiersChanged(flags)
        }
        renderer.onWheelEvent = { [weak self] in self?.scrollWheel(with: $0) }
        renderer.onInputReset = { [weak self] in self?.interaction.cancelGesture(); self?.scrollModeController.resetTransient() }
        renderer.onCopySelection = { [weak self] in self?.copySelection(to: .general) ?? false }
        renderer.onSelectAll = { [weak self] in
            guard let self, !self.scrollModeController.isActive else { return }
            self.interaction.selectAll()
        }
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        holdTask?.cancel()
        imageAnimationTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        interaction?.cancelGesture()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didMiniaturizeNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(presentPendingOutput),
                    name: name, object: window)
            }
        }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(cancelPresentationTimers),
                name: NSWindow.willCloseNotification, object: window)
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(presentPendingOutput), name: name, object: nil)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.removeObserver(self)
        workspace.addObserver(self, selector: #selector(displaysSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displaysWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        presentPendingOutput()
    }

    private var canPresentOutput: Bool {
        !displayAsleep && window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true && window?.isMiniaturized == false
            && !isHiddenOrHasHiddenAncestor && !applicationIsHidden()
    }

    func parsedOutput(reset: Bool) {
        if reset { resetPresentation() }
        hasPendingOutput = true
        presentPendingOutput()
    }

    @objc func presentPendingOutput() {
        guard !isUpdating else { return }
        guard canPresentOutput else { cancelPresentationTimers(); return }
        if hasPendingOutput || (scheduledImageAnimationDeadline == nil && presentedFrame?.imageSnapshot.placements.isEmpty == false) {
            refresh(resizeTerminal: true)
        }
        else if linkHighlightDirty { presentCachedFrame() }
    }

    @objc private func displaysSlept() { setDisplaysAsleep(true) }
    @objc private func displaysWoke() { setDisplaysAsleep(false) }

    func setDisplaysAsleep(_ asleep: Bool) {
        displayAsleep = asleep
        if asleep { cancelPresentationTimers() } else { presentPendingOutput() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        cancelPresentationTimers()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        presentPendingOutput()
    }

    /// Dispatch once; true gives the original event exclusively to AppKit.
    func routeWheel(_ event: NSEvent) -> Bool {
        if scrollModeController?.isActive == true { scrollModeController.pointer.scrollWheel(event); return false }
        return interaction.wheel(event)
    }

    override func scrollWheel(with event: NSEvent) {
        if routeWheel(event) { super.scrollWheel(with: event) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        source.invalidateSelectionColors()
        refresh()
    }

    func copySelection(to pasteboard: NSPasteboard) -> Bool {
        scrollModeController.isActive ? scrollModeController.copy(to: pasteboard) : interaction.copy(to: pasteboard)
    }
    func prepareScrollModeEntry() { interaction.cancelGesture() }
    func refreshScrollModeExit() {
        if driver.renderHoldRemaining != nil {
            if renderer.output == nil || canPresentOutput { presentCachedFrame() }
        } else { refresh() }
    }
    func autoscrollSelectionStep() { interaction.autoscrollStep() }

    override func tile() {
        // Let AppKit place the scrollers at the pane edges, then inset only
        // the clip view. Document coordinates still start at zero, preserving
        // fractional scrolling, hit testing and bounded renderer geometry.
        let wasUpdating = isUpdating
        isUpdating = true
        defer { isUpdating = wasUpdating }
        super.tile()
        let padding = settings?.padding ?? 0
        let frame = contentView.frame
        contentView.frame = frame.insetBy(dx: min(padding, frame.width / 2),
                                         dy: min(padding, frame.height / 2))
    }

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

    /// Relayout is batched with font/default updates to avoid intermediate
    /// wire resizes. Color-only updates respect an active presentation hold.
    func applySettings(_ next: NativeTerminalSettings, relayout: () -> Void = {}) throws {
        guard !isUpdating else { throw NativeSettingsError.reentrantUpdate }
        guard settings != next else { relayout(); return }
        try driver.applySettings(next)
        let font = next.font
        let fontChanged = renderer.font.fontName != font.fontName || renderer.font.pointSize != font.pointSize
        let paddingChanged = settings?.padding != next.padding
        settings = next
        isUpdating = true
        if fontChanged { renderer.font = font }
        relayout()
        if paddingChanged { tile() }
        isUpdating = false
        refresh(resizeTerminal: fontChanged || paddingChanged)
        invalidatePaddingFill()
        onSettingsChange?()
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
        resetPresentation()
        driver.reset()
        driver.feed(fixture)
        geometry = nil
        refresh()
    }

    func scrollToLiveScreen() {
        let bottom = max(0, virtualDocument.frame.height - contentSize.height)
        contentView.scroll(to: NSPoint(x: 0, y: bottom))
        reflectScrolledClipView(contentView)
    }

    func resetPresentation() {
        hostActions?.invalidateReview()
        scrollModeController?.exit(refresh: false)
        cancelPresentationTimers()
        geometry = nil
        presentedFrame = nil
        invalidatePaddingFill()
        lastRenderedRow = nil
        renderer.resetInputState()
        source.resetPresentation()
        renderer.clearAccessiblePresentation()
        linkHighlightDirty = false
        // showEmpty hides the Metal surface/caret without asking an occluded
        // drawable to render. Pending ticks then see the emptied source.
        renderer.frameSource = nil
        renderer.presentExternalFrame()
        renderer.frameSource = source
    }

    var viewport: TerminalStreamViewport {
        let scale = window?.backingScaleFactor ?? 1
        let cell = renderer.cellSize
        return .init(columns: UInt16(driver.columns), rows: UInt16(driver.rows),
            widthPixels: UInt32(max(0, contentSize.width * scale)),
            heightPixels: UInt32(max(0, contentSize.height * scale)),
            cellWidthPixels: UInt32(max(1, (cell.width * scale).rounded())),
            cellHeightPixels: UInt32(max(1, (cell.height * scale).rounded())))
    }

    @objc private func cancelPresentationTimers() {
        scrollModeController?.pointer.cancel()
        if holdTask != nil { hasPendingOutput = true }
        holdTask?.cancel(); holdTask = nil
        cancelImageAnimation()
    }

    private func cancelImageAnimation() {
        imageAnimationTask?.cancel(); imageAnimationTask = nil
        imageAnimationToken = nil; scheduledImageAnimationDeadline = nil
    }

    private func scheduleImageAnimation() {
        guard canPresentOutput, holdTask == nil,
              source.hasImages(intersecting: renderer.visibleRect, cell: renderer.cellSize,
                  scale: window?.backingScaleFactor ?? 1, height: renderer.bounds.height),
              let wake = driver.imageAnimationWake else { cancelImageAnimation(); return }
        if scheduledImageAnimationDeadline == wake.deadlineMilliseconds { return }
        cancelImageAnimation()
        let token = UUID()
        imageAnimationToken = token
        scheduledImageAnimationDeadline = wake.deadlineMilliseconds
        imageAnimationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(Double(wake.delayMilliseconds))) } catch { return }
            // Unwrap only after sleeping: a repeating animation must not own
            // the view/driver. Epoch tokens reject an already queued old wake.
            guard !Task.isCancelled, let self, self.imageAnimationToken == token else { return }
            self.imageAnimationTask = nil
            self.imageAnimationToken = nil; self.scheduledImageAnimationDeadline = nil
            guard self.canPresentOutput else { return }
            self.refresh() // one VT tick, not catch-up loops or a 60-Hz poll
        }
    }

    private func holdPresentationIfNeeded() -> Bool {
        guard let remaining = driver.renderHoldRemaining else {
            holdTask?.cancel(); holdTask = nil
            return false
        }
        cancelImageAnimation()
        scrollModeController?.pointer.cancel()
        if holdTask == nil {
            holdTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                self?.holdTask = nil
                self?.refresh()
            }
        }
        return true
    }

    enum GeometryError: Error { case unavailable }

    /// Layout facts only: usable before first exec/attach and while hidden.
    /// No frame capture, AX publication, animation tick, focus or paint.
    @discardableResult
    func synchronizeViewport() throws -> TerminalStreamViewport {
        guard !isUpdating else { throw NativeSettingsError.reentrantUpdate }
        isUpdating = true
        defer { isUpdating = false }
        try updateViewportGeometry()
        return viewport
    }

    private func updateViewportGeometry() throws {
        let cell = renderer.cellSize
        guard contentSize.width.isFinite, contentSize.height.isFinite,
              contentSize.width > 0, contentSize.height > 0,
              cell.width.isFinite, cell.height.isFinite, cell.width > 0, cell.height > 0 else { throw GeometryError.unavailable }
        let columns = max(1,Int(min(4096,contentSize.width / cell.width)))
        let rows = max(1,Int(min(1024,contentSize.height / cell.height)))
        let scale = window?.backingScaleFactor ?? 1
        let pixelValues = [contentSize.width*scale,contentSize.height*scale,(cell.width*scale).rounded(),(cell.height*scale).rounded()]
        guard scale.isFinite, scale > 0,
              pixelValues.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= CGFloat(UInt32.max) }) else { throw GeometryError.unavailable }
        let cellWidth = UInt32(max(1,pixelValues[2]))
        let cellHeight = UInt32(max(1,pixelValues[3]))
        if driver.columns != columns || driver.rows != rows
            || lastViewport?.cellWidthPixels != cellWidth || lastViewport?.cellHeightPixels != cellHeight {
            interaction?.cancelGesture(preservePointer:true)
            scrollModeController?.pointer.cancel()
            let replies = try driver.resize(columns:columns,rows:rows,cellWidth:cellWidth,cellHeight:cellHeight)
            onAutomaticReplies?(replies)
        }
        let next = viewport
        if lastViewport != next { lastViewport = next; onViewportChange?(next) }
    }

    /// Re-publish output; pure clip movement calls renderViewport instead.
    func refresh(resizeTerminal: Bool = false) {
        guard !isUpdating, contentSize.width > 0, contentSize.height > 0 else { return }
        if renderer.output != nil, !canPresentOutput {
            hasPendingOutput = true
            cancelPresentationTimers()
            return
        }
        isUpdating = true
        defer { isUpdating = false }
        do {
            if resizeTerminal { try updateViewportGeometry() }
            if holdPresentationIfNeeded() { return }
            try renderViewport()
            lastCellSize = renderer.cellSize
            lastError = nil
            hasPendingOutput = false
        } catch { cancelImageAnimation(); report(error) }
    }

    @objc private func clipBoundsChanged() {
        guard !isUpdating else { return }
        // Bounds-size/font changes are layout, not a user's scroll intent.
        // Keep the old geometry (and follow state) until resize resolves it.
        guard geometry?.viewportHeight == contentSize.height,
              lastSurfaceSize.width == contentSize.width, lastCellSize == renderer.cellSize else { return }
        isUpdating = true
        defer { isUpdating = false }
        if holdPresentationIfNeeded() {
            // Keep the published viewport intact until the short hold releases;
            // don't relocate an old snapshot to a newly requested row.
            if let geometry { contentView.scroll(to: NSPoint(x: 0, y: geometry.offset)) }
            return
        }
        do { try renderViewport(requestedOffset: contentView.bounds.minY) }
        catch { report(error) }
    }

    private func renderViewport(requestedOffset: CGFloat? = nil) throws {
        if scrollModeController?.isActive != true, let requestedOffset, let geometry {
            let movement = NativeViewport(rowHeight: geometry.rowHeight, viewportHeight: geometry.viewportHeight,
                totalRows: geometry.totalRows, offset: requestedOffset)
            if lastRenderedRow == movement.firstRow,
               lastSurfaceSize == CGSize(width: contentSize.width, height: movement.renderHeight) {
                // Keep the original cell/column through within-row travel,
                // including after reflow. No C frame or row conversion needed.
                self.geometry = movement
                interaction.presentationChanged()
                if linkHighlightDirty { presentCachedFrame() }
                reportViewport(movement)
                renderer.postAccessibility(.layoutChanged)
                scheduleImageAnimation()
                return
            }
        }
        let mode = scrollModeController.isActive ? try driver.scrollModePresentation(rowHeight: renderer.cellSize.height,
            viewportHeight: contentSize.height, advanceAnimations: canPresentOutput) : nil
        if scrollModeController.isActive, mode == nil, driver.renderHoldRemaining == nil { scrollModeController.coreEnded() }
        var nextPresentation = mode?.presentation
        if nextPresentation == nil {
            nextPresentation = try driver.presentation(rowHeight: renderer.cellSize.height,
                viewportHeight: contentSize.height, previous: geometry, requestedOffset: requestedOffset,
                advanceAnimations: canPresentOutput)
        }
        guard let presentation = nextPresentation else {
            _ = holdPresentationIfNeeded()
            return
        }
        let next = presentation.viewport
        let snapshot = presentation.frame
        let size = CGSize(width: contentSize.width, height: next.renderHeight)
        let documentSize = NSSize(width: contentSize.width, height: next.documentHeight)
        if virtualDocument.frame.size != documentSize { virtualDocument.setFrameSize(documentSize) }
        if contentView.bounds.minY != next.offset { contentView.scroll(to: NSPoint(x: 0, y: next.offset)) }
        reflectScrolledClipView(contentView)
        do {
            if let settings {
                renderer.caretTextColor = settings.theme.cursorText?.nsColor ?? snapshot.background.nsColor
            }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                if let fg = NSColor.selectedTextColor.usingColorSpace(.sRGB),
                   let bg = NSColor.selectedTextBackgroundColor.usingColorSpace(.sRGB) {
                    func byte(_ value: CGFloat) -> UInt8 { value.isFinite ? UInt8(min(255, max(0, (value * 255).rounded()))) : 0 }
                    source.selectionForeground = settings?.theme.selectionForeground ?? NativeRGB(red: byte(fg.redComponent), green: byte(fg.greenComponent), blue: byte(fg.blueComponent))
                    source.selectionBackground = settings?.theme.selectionBackground ?? NativeRGB(red: byte(bg.redComponent), green: byte(bg.greenComponent), blue: byte(bg.blueComponent))
                }
            }
            renderer.cursorCell = (snapshot.cursor.column, snapshot.cursor.line - next.firstRow)
            if renderer.nativeForegroundColor != snapshot.foreground.nsColor {
                renderer.nativeForegroundColor = snapshot.foreground.nsColor
            }
            let background = snapshot.background.nsColor.withAlphaComponent(settings?.backgroundOpacity ?? 1)
            if renderer.nativeBackgroundColor != background {
                renderer.nativeBackgroundColor = background
            }
            if renderer.caretColor != snapshot.cursorColor.nsColor {
                renderer.caretColor = snapshot.cursorColor.nsColor
            }
            // A flipped parent places this nonflipped renderer by its top edge.
            let frame = NSRect(x: 0, y: next.renderOrigin, width: size.width, height: size.height)
            if renderer.frame != frame { renderer.frame = frame }
            if remainderFillView.frame != frame { remainderFillView.frame = frame }
            geometry = next
            presentedFrame = snapshot
            interaction.presentationChanged()
            source.apply(snapshot, topLine: next.firstRow, renderRows: next.renderRows)
            renderer.publishAccessibility(snapshot, topRow: next.firstRow)
            renderer.presentExternalFrame()
            if let mode { scrollModeController.publish(mode.state, frame: snapshot, viewport: next) }
            linkHighlightDirty = false
            lastRenderedRow = next.firstRow
            lastSurfaceSize = size
        }
        geometry = next
        reportViewport(next)
        scheduleImageAnimation()
    }

    /// Host-only decoration: repaint the published bounded cells, never sample
    /// new VT output or move the reading anchor just to change hover state.
    func updateLinkHighlight(_ ranges: [Int: Range<Int>], fromUserEvent: Bool = false) {
        if let geometry {
            let cell = renderer.cellSize
            renderer.linkCursorRects = ranges.keys.sorted().compactMap { row in
                guard let range = ranges[row] else { return nil }
                let rect = NSRect(x: CGFloat(range.lowerBound) * cell.width,
                    y: renderer.bounds.height - CGFloat(row - geometry.firstRow + 1) * cell.height,
                    width: CGFloat(range.count) * cell.width, height: cell.height).intersection(renderer.visibleRect)
                return rect.isEmpty ? nil : rect
            }
        } else { renderer.linkCursorRects = [] }
        if source.highlightedLink != ranges {
            source.highlightedLink = ranges
            linkHighlightDirty = true
        }
        guard linkHighlightDirty else { return }
        if !isUpdating, fromUserEvent || renderer.output == nil || canPresentOutput { presentCachedFrame() }
    }

    private func presentCachedFrame() {
        guard let frame = presentedFrame, let geometry else { return }
        source.apply(frame, topLine: geometry.firstRow, renderRows: geometry.renderRows)
        renderer.presentExternalFrame()
        linkHighlightDirty = false
    }

    private func invalidatePaddingFill() {
        outerPaddingFill?.invalidate()
        remainderFillView.invalidate()
    }

    private func reportViewport(_ next: NativeViewport) {
        invalidatePaddingFill()
        let images = presentedFrame?.imageSnapshot
        let imageStatus = images?.limited == true ? " · images limited" : images?.placements.isEmpty == false ? " · images \(images?.placements.count ?? 0)" : ""
        onStatusChange?("\(driver.columns)×\(driver.rows) · row \(next.firstRow) + \(String(format: "%.2f", next.fraction)) pt · cached \(source.lines.count) rows · \(renderer.isUsingMetalRenderer ? "Metal" : "Core Graphics")\(imageStatus)")
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
