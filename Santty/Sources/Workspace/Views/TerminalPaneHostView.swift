import AppKit
import GhosttyTerminal
import os

private let paneResizeLog = Logger(subsystem: "com.zola.santty", category: "PaneResize")

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
        layer?.cornerRadius = 8
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

    var onFocusRequest: ((PaneID) -> Void)?

    private let terminalView: TerminalView
    private let vibrancyView = AppAppearanceDefaults.makeVibrancyView(
        tintViewAlpha: AppAppearanceDefaults.vibrancyTintAlpha
    )
    private let statusBackgroundView = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var isFocused = false
    private var isFloating = false
    private var terminalPadding = TerminalSettings.padding
    private var terminalPaddingConstraints: [NSLayoutConstraint] = []
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
        layer?.cornerRadius = 8
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

        let clickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        clickRecognizer.buttonMask = 0x1
        addGestureRecognizer(clickRecognizer)

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

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        if oldSize != newSize {
            paneResizeLog.debug(
                "setFrameSize TerminalPaneHostView#\(ObjectIdentifier(self).hashValue, privacy: .public) old=\(NSStringFromSize(oldSize), privacy: .public) new=\(NSStringFromSize(newSize), privacy: .public)"
            )
        }
        super.setFrameSize(newSize)
    }

    override func layout() {
        super.layout()

        let labelSize = statusLabel.intrinsicContentSize
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 4
        let backgroundWidth = min(bounds.width - 16, labelSize.width + horizontalPadding * 2)
        let backgroundHeight = labelSize.height + verticalPadding * 2
        let origin = NSPoint(x: 8, y: max(8, bounds.height - backgroundHeight - 8))

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
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPaneBackgroundColor()
    }

    @objc func copy(_ sender: Any?) {
        terminalView.copy(sender)
    }

    @objc func paste(_ sender: Any?) {
        if pasteTerminalURLsFromGeneralPasteboard() {
            return
        }

        terminalView.paste(sender)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else {
            return []
        }

        return Set(types).isDisjoint(with: TerminalPasteboardText.dropTypes) ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = TerminalPasteboardText.dropInsertionText(from: sender.draggingPasteboard) else {
            return false
        }

        window?.makeFirstResponder(terminalView)
        terminalView.sendText(text)
        return true
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

    private func applyPaneBackgroundColor() {
        let alpha = AppAppearanceSettings.isWindowHidden ? 0 : 0.5
        layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
    }

    func updateAppearance() {
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
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: terminalPadding),
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
    }

    @objc private func handleClick() {
        guard !isFloating else {
            return
        }

        onFocusRequest?(paneID)
    }

    private func installPasteKeyMonitor() {
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else {
                return event
            }

            return self.handlePasteKeyEvent(event)
        }) else {
            return
        }

        pasteKeyMonitor = EventMonitorToken(monitor)
    }

    private func handlePasteKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard isTerminalResponderActive,
              Self.isPasteKeyEvent(event),
              pasteTerminalURLsFromGeneralPasteboard() else {
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
}
