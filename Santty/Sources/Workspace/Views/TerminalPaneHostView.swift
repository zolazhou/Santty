import AppKit

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
    weak var paneController: TerminalPaneController?
    let nameBadge = PaneNameBadgeView()
    let terminalView: NativeTerminalScrollView?
    var onFocusRequest: ((PaneID) -> Void)?
    var onGeometryChange: (() -> Void)?
    private let content: NSView
    let paddingFillView = NativeTerminalPaddingFillView()
    private let vibrancyView = AppAppearanceDefaults.makeVibrancyView(tintViewAlpha:AppAppearanceDefaults.vibrancyTintAlpha)
    private let statusBackgroundView = NSView()
    private let statusLabel = NSTextField(labelWithString:"")
    private let retryButton = NSButton(title:"Retry Connection",target:nil,action:nil)
    private var retryAction: (() -> Void)?
    private var isFocused = false
    private var isFloating = false
    private var terminalPadding = TerminalSettings.padding
    private var edges: [NSLayoutConstraint] = []
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(paneID: PaneID, terminalView: NativeTerminalScrollView?) {
        self.paneID = paneID; self.terminalView = terminalView; content = NSView()
        super.init(frame:.zero)
        wantsLayer = true; layer?.masksToBounds = true
        layer?.actions = ["position":NSNull(),"bounds":NSNull(),"frame":NSNull()]
        for view in [vibrancyView,content] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        addSubview(paddingFillView, positioned: .above, relativeTo: vibrancyView)
        NSLayoutConstraint.activate([vibrancyView.leadingAnchor.constraint(equalTo:leadingAnchor),
            vibrancyView.trailingAnchor.constraint(equalTo:trailingAnchor),vibrancyView.topAnchor.constraint(equalTo:topAnchor),
            vibrancyView.bottomAnchor.constraint(equalTo:bottomAnchor)])
        edges = [content.leadingAnchor.constraint(equalTo:leadingAnchor),content.trailingAnchor.constraint(equalTo:trailingAnchor),
                 content.topAnchor.constraint(equalTo:topAnchor),content.bottomAnchor.constraint(equalTo:bottomAnchor)]
        NSLayoutConstraint.activate(edges)
        if let terminalView {
            terminalView.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(terminalView)
            paddingFillView.bind(to: terminalView)
            NSLayoutConstraint.activate([terminalView.leadingAnchor.constraint(equalTo:content.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo:content.trailingAnchor),
                terminalView.topAnchor.constraint(equalTo:content.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo:content.bottomAnchor)])
        }
        statusBackgroundView.wantsLayer = true; statusBackgroundView.layer?.cornerRadius = 6
        statusLabel.font = .systemFont(ofSize:11,weight:.semibold); statusLabel.textColor = .white
        statusLabel.lineBreakMode = .byTruncatingTail
        retryButton.target = self; retryButton.action = #selector(retryConnection); retryButton.isHidden = true
        for view in [statusBackgroundView,statusLabel,retryButton,nameBadge] { addSubview(view) }
        updateAppearance()
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout(); nameBadge.layout(in:self)
        paddingFillView.frame = bounds
        paddingFillView.invalidate()
        onGeometryChange?()
        let height: CGFloat = retryButton.isHidden ? 28 : 60
        statusBackgroundView.frame = .init(x:8,y:max(8,bounds.height-height-32),width:max(0,min(bounds.width-16,300)),height:height)
        statusLabel.frame = statusBackgroundView.frame.insetBy(dx:8,dy:4)
        if !retryButton.isHidden { statusLabel.frame.origin.y+=30; statusLabel.frame.size.height-=30 }
        retryButton.frame = .init(x:16,y:statusBackgroundView.frame.minY+2,width:140,height:28)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    override func mouseDown(with event: NSEvent) { if !isFloating { onFocusRequest?(paneID) }; super.mouseDown(with:event) }
    @objc func copy(_ sender: Any?) { terminalView?.renderer.copy(sender) }
    @objc func paste(_ sender: Any?) { terminalView?.renderer.paste(sender) }
    func updatePresentation(isFocused: Bool,isFloating: Bool,isLive: Bool,displayTitle: String,renderingWarning: String? = nil) {
        self.isFocused = isFocused; self.isFloating = isFloating
        let hideStatus = isLive && renderingWarning == nil
        statusBackgroundView.isHidden = hideStatus; statusLabel.isHidden = hideStatus
        statusLabel.stringValue = isLive ? renderingWarning ?? displayTitle : displayTitle
        statusLabel.toolTip = statusLabel.stringValue
        updateAppearance()
    }
    func setRetryAction(_ action: (() -> Void)?) { retryAction = action; retryButton.isHidden = action == nil; needsLayout = true }
    @objc private func retryConnection() { retryAction?() }
    func updateAppearance() {
        terminalPadding = TerminalSettings.padding
        let inset = terminalPadding
        if edges.count == 4 { edges[0].constant = inset; edges[1].constant = -inset; edges[2].constant = inset; edges[3].constant = -inset }
        nameBadge.isFocused = isFocused
        vibrancyView.isHidden = !(AppAppearanceSettings.isWindowHidden || isFloating)
        vibrancyView.blendingMode = isFloating ? AppAppearanceDefaults.floatingPaneVibrancyBlendingMode : AppAppearanceDefaults.vibrancyBlendingMode
        vibrancyView.material = isFloating ? AppAppearanceDefaults.floatingPaneVibrancyMaterial : AppAppearanceDefaults.vibrancyMaterial
        let alpha = isFloating ? AppAppearanceDefaults.floatingPaneVibrancyTintAlpha : AppAppearanceDefaults.vibrancyTintAlpha
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = AppAppearanceSettings.paneCornerRadius
            layer?.borderWidth = isFocused ? AppAppearanceSettings.activePaneBorderWidth : 1
            layer?.borderColor = debugBorderColor.cgColor
            layer?.backgroundColor = NSColor.black.withAlphaComponent(AppAppearanceSettings.isWindowHidden ? 0 : 0.5).cgColor
            statusBackgroundView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
            vibrancyView.subviews.first { $0.identifier == AppAppearanceDefaults.vibrancyTintIdentifier }?.layer?.backgroundColor =
                NSColor.black.withAlphaComponent(alpha).cgColor
        }
        needsLayout = true
    }
    var debugBorderColor: NSColor { isFocused ? AppAppearanceSettings.accentColor : NSColor.separatorColor.withAlphaComponent(0.45) }
    var debugBorderWidth: CGFloat { layer?.borderWidth ?? 0 }
    var debugUsesHiddenWindowPresentation: Bool { !vibrancyView.isHidden }
    var debugVibrancyBlendingMode: NSVisualEffectView.BlendingMode { vibrancyView.blendingMode }
    var debugVibrancyTintAlpha: CGFloat? {
        vibrancyView.subviews.first { $0.identifier == AppAppearanceDefaults.vibrancyTintIdentifier }?.layer?.backgroundColor
            .flatMap { NSColor(cgColor:$0)?.alphaComponent }
    }
    var debugTerminalFrame: NSRect { content.frame }
    var debugVibrancyFrame: NSRect { vibrancyView.frame }
    var debugTerminalPadding: CGFloat { terminalPadding }
    var debugPaneBounds: NSRect { bounds }
    var debugScrollModeIndicatorIsVisible: Bool { terminalView?.scrollModeController.isActive == true }
    var debugScrollModeIndicatorFrames: (background:NSRect,label:NSRect) {
        guard let overlay = terminalView?.scrollModeController.overlay else { return (.zero,.zero) }
        let rect = overlay.convert(overlay.badgeRect,to:self)
        return (rect,rect.insetBy(dx:7,dy:5))
    }
}
