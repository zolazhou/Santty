import AppKit
import GhosttyTerminal

private final class EventMonitorToken: @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }
}

@MainActor
final class TerminalPanePlaceholderView: NSView {
    let paneID: PaneID

    private let vibrancyView = AppAppearanceDefaults.makeVibrancyView(
        tintViewAlpha: AppAppearanceDefaults.vibrancyTintAlpha
    )

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    init(paneID: PaneID) {
        self.paneID = paneID
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(vibrancyView)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func layout() {
        super.layout()
        vibrancyView.frame = bounds
    }

    func updateAppearance() {
        isHidden = !AppAppearanceSettings.isWindowHidden
        vibrancyView.isHidden = !AppAppearanceSettings.isWindowHidden
        layer?.cornerRadius = AppAppearanceSettings.paneCornerRadius
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = AppAppearanceSettings.isWindowHidden ? 1 : 0
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        needsLayout = true
    }

    var debugUsesHiddenWindowPresentation: Bool {
        !isHidden && !vibrancyView.isHidden
    }

    var debugVibrancyBlendingMode: NSVisualEffectView.BlendingMode {
        vibrancyView.blendingMode
    }

    var debugVibrancyTintAlpha: CGFloat? {
        guard
            let tintView = vibrancyView.subviews.first(where: {
                $0.identifier == AppAppearanceDefaults.vibrancyTintIdentifier
            }),
            let backgroundColor = tintView.layer?.backgroundColor
        else {
            return nil
        }

        return NSColor(cgColor: backgroundColor)?.alphaComponent
    }
}

@MainActor
final class TerminalPaneHostView: NSView {
    let paneID: PaneID
    let nameBadge = PaneNameBadgeView()

    var onFocusRequest: ((PaneID) -> Void)?

    private let terminalView: TerminalView
    var onPasteText: ((String) -> Bool)?
    private let vibrancyView = AppAppearanceDefaults.makeVibrancyView(
        tintViewAlpha: AppAppearanceDefaults.vibrancyTintAlpha
    )
    private let statusBackgroundView = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let scrollModeBackgroundView = NSView()
    private let scrollModeLabel = NSTextField(labelWithString: "SCROLL")
    private(set) var scrollModeView: TerminalScrollModeView?
    private var isPersistentHistoryActive = false
    private var isFocused = false
    private var isFloating = false
    private var terminalPadding = TerminalSettings.padding
    private var terminalPaddingConstraints: [NSLayoutConstraint] = []
    private var fixedTerminalSizeConstraints: [NSLayoutConstraint] = []
    private var fixedTerminalCursorRect: NSRect?
    private var pasteKeyMonitor: EventMonitorToken?

    override var acceptsFirstResponder: Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    init(paneID: PaneID, terminalView: TerminalView) {
        self.paneID = paneID
        self.terminalView = terminalView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        // Suppress implicit position/bounds animations so they don't fight an
        // in-flight pane-resize FLIP transform animation on this layer.
        layer?.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
        ]
        updateAppearance()

        addSubview(vibrancyView)
        vibrancyView.translatesAutoresizingMaskIntoConstraints = false

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)

        statusBackgroundView.wantsLayer = true
        statusBackgroundView.layer?.cornerRadius = 6
        statusBackgroundView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        statusBackgroundView.isHidden = true
        addSubview(statusBackgroundView)

        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = true
        addSubview(statusLabel)

        scrollModeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        scrollModeLabel.textColor = .black
        scrollModeLabel.alignment = .center
        scrollModeLabel.isHidden = true
        scrollModeLabel.setAccessibilityLabel("Scroll mode active")

        scrollModeBackgroundView.wantsLayer = true
        scrollModeBackgroundView.layer?.cornerRadius = 5
        scrollModeBackgroundView.layer?.backgroundColor = NSColor.systemYellow.cgColor
        scrollModeBackgroundView.isHidden = true
        addSubview(scrollModeBackgroundView)
        addSubview(scrollModeLabel)

        addSubview(nameBadge)

        registerForDraggedTypes(Array(TerminalPasteboardText.dropTypes))
        installPasteKeyMonitor()
        installContentConstraints()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    deinit {
        if let pasteKeyMonitor {
            NSEvent.removeMonitor(pasteKeyMonitor.value)
        }
    }

    override func layout() {
        updateFixedTerminalViewport()
        super.layout()

        nameBadge.layout(in: self)
        let labelSize = statusLabel.intrinsicContentSize
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 4
        let backgroundWidth = min(bounds.width - 16, labelSize.width + horizontalPadding * 2)
        let backgroundHeight = labelSize.height + verticalPadding * 2
        let topInset: CGFloat = nameBadge.isHidden ? 8 : nameBadge.intrinsicContentSize.height + 12
        let origin = NSPoint(x: 8, y: max(8, bounds.height - backgroundHeight - topInset))

        statusBackgroundView.frame = NSRect(
            origin: origin,
            size: NSSize(width: max(0, backgroundWidth), height: backgroundHeight)
        )

        statusLabel.frame = NSRect(
            x: origin.x + horizontalPadding,
            y: origin.y + verticalPadding,
            width: max(0, backgroundWidth - horizontalPadding * 2),
            height: labelSize.height
        )

        let scrollModeSize = scrollModeLabel.intrinsicContentSize
        scrollModeBackgroundView.frame = NSRect(
            x: max(8, bounds.width - scrollModeSize.width - 24),
            y: max(8, bounds.height - scrollModeSize.height - 16),
            width: scrollModeSize.width + 16,
            height: scrollModeSize.height + 8
        )
        scrollModeLabel.frame = NSRect(
            x: scrollModeBackgroundView.frame.minX + 8,
            y: scrollModeBackgroundView.frame.midY - scrollModeSize.height / 2,
            width: scrollModeSize.width,
            height: scrollModeSize.height
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPaneBackgroundColor()
    }

    override func mouseDown(with event: NSEvent) {
        if !isFloating {
            onFocusRequest?(paneID)
        }

        super.mouseDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        if let scrollModeView {
            scrollModeView.copySelection()
            return
        }
        terminalView.copy(sender)
    }

    @objc func paste(_ sender: Any?) {
        guard scrollModeView == nil, !isPersistentHistoryActive else { return }
        if pasteTerminalURLsFromGeneralPasteboard() {
            return
        }

        if let onPasteText {
            if let text = NSPasteboard.general.string(forType: .string) { _ = onPasteText(text) }
            return
        }

        terminalView.performBindingAction("paste_from_clipboard")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard scrollModeView == nil, !isPersistentHistoryActive else { return [] }
        guard let types = sender.draggingPasteboard.types else {
            return []
        }

        return Set(types).isDisjoint(with: TerminalPasteboardText.dropTypes) ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard scrollModeView == nil, !isPersistentHistoryActive else { return false }
        guard let text = TerminalPasteboardText.dropInsertionText(from: sender.draggingPasteboard)
        else {
            return false
        }

        window?.makeFirstResponder(terminalView)
        return insertPasteText(text)
    }

    func updatePresentation(isFocused: Bool, isFloating: Bool, isLive: Bool, displayTitle: String) {
        self.isFocused = isFocused
        self.isFloating = isFloating
        updateAppearance()

        statusBackgroundView.isHidden = isLive
        statusLabel.isHidden = isLive
        statusLabel.stringValue = displayTitle
        needsLayout = true
    }

    func setScrollModeActive(_ active: Bool) {
        scrollModeBackgroundView.isHidden = !active
        scrollModeLabel.isHidden = !active
        needsLayout = true
    }

    func showScrollMode() {
        let view = TerminalScrollModeView(terminalView: terminalView)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .above, relativeTo: terminalView)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor),
            view.topAnchor.constraint(equalTo: terminalView.topAnchor),
            view.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor),
        ])
        scrollModeView = view
        view.onSelectionChange = { [weak self] title in
            self?.scrollModeLabel.stringValue = title
            self?.scrollModeLabel.setAccessibilityLabel("\(title.lowercased()) mode active")
            self?.needsLayout = true
        }
        scrollModeLabel.stringValue = "SCROLL"
        setScrollModeActive(true)
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(view)
    }

    func showPersistentHistory(_ view: HerdrHistoryView) {
        isPersistentHistoryActive = true
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .above, relativeTo: terminalView)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor), view.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor),
            view.topAnchor.constraint(equalTo: terminalView.topAnchor), view.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor),
        ])
        scrollModeLabel.stringValue = "RECENT HISTORY · FROZEN"
        setScrollModeActive(true)
        window?.makeFirstResponder(view.textView)
    }

    func hidePersistentHistory() {
        isPersistentHistoryActive = false
        setScrollModeActive(false)
        window?.makeFirstResponder(terminalView)
    }

    func hideScrollMode() {
        let hadFocus = window?.firstResponder === scrollModeView
        scrollModeView?.cancelSelection()
        scrollModeView?.removeFromSuperview()
        scrollModeView = nil
        setScrollModeActive(false)
        if hadFocus { window?.makeFirstResponder(terminalView) }
    }

    private func applyPaneBackgroundColor() {
        let alpha = AppAppearanceSettings.isWindowHidden ? 0 : 0.5
        layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
    }

    func updateAppearance() {
        nameBadge.isFocused = isFocused
        terminalPadding = TerminalSettings.padding
        vibrancyView.isHidden = !(AppAppearanceSettings.isWindowHidden || isFloating)
        vibrancyView.blendingMode =
            isFloating
            ? AppAppearanceDefaults.floatingPaneVibrancyBlendingMode
            : AppAppearanceDefaults.vibrancyBlendingMode
        vibrancyView.material =
            isFloating
            ? AppAppearanceDefaults.floatingPaneVibrancyMaterial
            : AppAppearanceDefaults.vibrancyMaterial
        applyVibrancyTintAlpha(
            isFloating
                ? AppAppearanceDefaults.floatingPaneVibrancyTintAlpha
                : AppAppearanceDefaults.vibrancyTintAlpha
        )
        layer?.cornerRadius = AppAppearanceSettings.paneCornerRadius
        layer?.borderWidth = isFocused ? AppAppearanceSettings.activePaneBorderWidth : 1
        layer?.borderColor = borderColor(isFocused: isFocused).cgColor
        applyPaneBackgroundColor()
        needsLayout = true
        updateTerminalPaddingConstraints()
    }

    private func applyVibrancyTintAlpha(_ alpha: CGFloat) {
        guard
            let tintView = vibrancyView.subviews.first(where: {
                $0.identifier == AppAppearanceDefaults.vibrancyTintIdentifier
            })
        else {
            return
        }

        tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
    }

    private func borderColor(isFocused: Bool) -> NSColor {
        isFocused
            ? AppAppearanceSettings.accentColor
            : NSColor.separatorColor.withAlphaComponent(0.45)
    }

    private func installContentConstraints() {
        terminalPaddingConstraints = [
            terminalView.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: terminalPadding),
            terminalView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -terminalPadding
            ),
            terminalView.topAnchor.constraint(equalTo: topAnchor, constant: terminalPadding),
            terminalView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -terminalPadding
            ),
        ]

        NSLayoutConstraint.activate(
            [
                vibrancyView.leadingAnchor.constraint(equalTo: leadingAnchor),
                vibrancyView.trailingAnchor.constraint(equalTo: trailingAnchor),
                vibrancyView.topAnchor.constraint(equalTo: topAnchor),
                vibrancyView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ] + terminalPaddingConstraints
        )
    }

    private func updateTerminalPaddingConstraints() {
        guard terminalPaddingConstraints.count == 4 else {
            return
        }

        terminalPaddingConstraints[0].constant = terminalPadding
        terminalPaddingConstraints[1].constant = -terminalPadding
        terminalPaddingConstraints[2].constant = terminalPadding
        terminalPaddingConstraints[3].constant = -terminalPadding
        updateFixedTerminalViewport()
    }

    func setFixedTerminalCursorRect(_ rect: NSRect?) {
        fixedTerminalCursorRect = rect
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func updateFixedTerminalViewport() {
        guard fixedTerminalSizeConstraints.count == 2 else { return }
        func offset(length: CGFloat, visible: CGFloat, previous: CGFloat, start: CGFloat?, end: CGFloat?) -> CGFloat {
            var value = previous
            if let start, let end {
                value = min(value, start)
                value = max(value, end - visible)
            }
            return min(max(0, value), max(0, length - visible))
        }
        let x = offset(length: fixedTerminalSizeConstraints[0].constant,
                       visible: max(0, bounds.width - terminalPadding * 2),
                       previous: terminalPadding - terminalPaddingConstraints[0].constant,
                       start: fixedTerminalCursorRect?.minX, end: fixedTerminalCursorRect?.maxX)
        let y = offset(length: fixedTerminalSizeConstraints[1].constant,
                       visible: max(0, bounds.height - terminalPadding * 2),
                       previous: terminalPadding - terminalPaddingConstraints[2].constant,
                       start: fixedTerminalCursorRect?.minY, end: fixedTerminalCursorRect?.maxY)
        terminalPaddingConstraints[0].constant = terminalPadding - x
        terminalPaddingConstraints[2].constant = terminalPadding - y
    }

    // Keep the backend grid intact; pan the clipped viewport to keep its cursor visible.
    func setFixedTerminalSize(_ size: NSSize) {
        precondition(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0)
        if fixedTerminalSizeConstraints.isEmpty {
            NSLayoutConstraint.deactivate([terminalPaddingConstraints[1], terminalPaddingConstraints[3]])
            fixedTerminalSizeConstraints = [terminalView.widthAnchor.constraint(equalToConstant: size.width),
                                            terminalView.heightAnchor.constraint(equalToConstant: size.height)]
            NSLayoutConstraint.activate(fixedTerminalSizeConstraints)
        } else {
            fixedTerminalSizeConstraints[0].constant = size.width
            fixedTerminalSizeConstraints[1].constant = size.height
        }
        layoutSubtreeIfNeeded()
    }

    private func installPasteKeyMonitor() {
        guard
            let monitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown,
                handler: { [weak self] event in
                    guard let self else {
                        return event
                    }

                    return self.handlePasteKeyEvent(event)
                })
        else {
            return
        }

        pasteKeyMonitor = EventMonitorToken(monitor)
    }

    private func handlePasteKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard isTerminalResponderActive,
            Self.isPasteKeyEvent(event),
            pasteTerminalURLsFromGeneralPasteboard()
        else {
            return event
        }

        return nil
    }

    private var isTerminalResponderActive: Bool {
        guard let responder = window?.firstResponder else {
            return false
        }

        if responder === terminalView {
            return true
        }

        if let view = responder as? NSView, view.isDescendant(of: terminalView) {
            return true
        }

        var nextResponder = responder.nextResponder
        while let current = nextResponder {
            if current === terminalView {
                return true
            }
            nextResponder = current.nextResponder
        }
        return false
    }

    private func pasteTerminalURLsFromGeneralPasteboard() -> Bool {
        guard let text = TerminalPasteboardText.urlInsertionText(from: .general) else {
            return false
        }

        return insertPasteText(text)
    }

    private func insertPasteText(_ text: String) -> Bool {
        if let onPasteText { return onPasteText(text) }
        terminalView.sendText(text)
        return true
    }

    private static func isPasteKeyEvent(_ event: NSEvent) -> Bool {
        let relevantModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return relevantModifiers == .command && event.charactersIgnoringModifiers == "v"
    }

    var debugBorderColor: NSColor {
        borderColor(isFocused: isFocused)
    }

    var debugBorderWidth: CGFloat {
        layer?.borderWidth ?? 0
    }

    var debugUsesHiddenWindowPresentation: Bool {
        !vibrancyView.isHidden
    }

    var debugVibrancyBlendingMode: NSVisualEffectView.BlendingMode {
        vibrancyView.blendingMode
    }

    var debugVibrancyTintAlpha: CGFloat? {
        guard
            let tintView = vibrancyView.subviews.first(where: {
                $0.identifier == AppAppearanceDefaults.vibrancyTintIdentifier
            }),
            let backgroundColor = tintView.layer?.backgroundColor
        else {
            return nil
        }

        return NSColor(cgColor: backgroundColor)?.alphaComponent
    }

    var debugTerminalFrame: NSRect {
        terminalView.frame
    }

    var debugVibrancyFrame: NSRect {
        vibrancyView.frame
    }

    var debugTerminalPadding: CGFloat {
        terminalPadding
    }

    var debugPaneBounds: NSRect {
        bounds
    }

    var debugScrollModeIndicatorIsVisible: Bool {
        !scrollModeLabel.isHidden
    }

    var debugScrollModeIndicatorFrames: (background: NSRect, label: NSRect) {
        layoutSubtreeIfNeeded()
        return (scrollModeBackgroundView.frame, scrollModeLabel.frame)
    }
}
