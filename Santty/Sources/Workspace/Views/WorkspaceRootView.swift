import AppKit
import QuartzCore

@MainActor
private final class WorkspaceFloatingOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        for subview in subviews.reversed() {
            let convertedPoint = convert(point, to: subview)
            if let hitView = subview.hitTest(convertedPoint) {
                return hitView
            }
        }

        return nil
    }
}

@MainActor
private final class WorkspaceFloatingPaneContainerView: NSView {
    private let contentView: NSView

    init(contentView: NSView, frame: NSRect) {
        self.contentView = contentView
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(contentView)
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        contentView.frame = bounds
    }
}

@MainActor
final class WorkspaceRootView: NSView {
    let contentContainerView = NSView()
    let toolbarView = WorkspaceToolbarView()
    var tabStripView: WorkspaceTabStripView {
        toolbarView.tabStripView
    }

    private let floatingOverlayView = WorkspaceFloatingOverlayView()
    private var renderedContentView: NSView?
    private var floatingPaneView: WorkspaceFloatingPaneContainerView?
    private var floatingPaneContentView: NSView?
    private var lastFloatingPaneInitialFrame: NSRect?
    private var isFloatingPaneAnimating = false
    private var contentFrame = NSRect.zero
    private var toolbarFrame = NSRect.zero

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyWindowBackgroundColor()
        addSubview(contentContainerView)
        addSubview(floatingOverlayView)
        addSubview(toolbarView)

        floatingOverlayView.wantsLayer = true
        floatingOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyWindowBackgroundColor()
    }

    private let edgePadding = WorkspaceLayoutMetrics.workspaceEdgePadding
    private let sectionSpacing = WorkspaceLayoutMetrics.workspaceSectionSpacing
    private let toolbarHeight = WorkspaceLayoutMetrics.tabStripHeight

    override func layout() {
        super.layout()
        let paddedBounds = NSRect(
            x: edgePadding,
            y: edgePadding,
            width: max(0, bounds.width - edgePadding * 2),
            height: max(0, bounds.height - edgePadding * 2)
        )
        let showToolbar = !tabItems.isEmpty
        if showToolbar {
            toolbarView.isHidden = false
            toolbarFrame = NSRect(
                x: paddedBounds.minX,
                y: paddedBounds.minY,
                width: paddedBounds.width,
                height: min(toolbarHeight, paddedBounds.height)
            )
            toolbarView.frame = toolbarFrame
        } else {
            toolbarView.isHidden = true
            toolbarFrame = .zero
        }

        let contentHeight: CGFloat
        if showToolbar {
            contentHeight = max(0, paddedBounds.height - toolbarFrame.height - sectionSpacing)
        } else {
            contentHeight = max(0, paddedBounds.height)
        }
        contentFrame = NSRect(
            x: paddedBounds.minX,
            y: showToolbar ? toolbarFrame.maxY + sectionSpacing : paddedBounds.minY,
            width: paddedBounds.width,
            height: contentHeight
        )
        contentContainerView.frame = contentFrame
        floatingOverlayView.frame = contentFrame
        renderedContentView?.frame = contentContainerView.bounds
        if let floatingPaneView, !isFloatingPaneAnimating {
            floatingPaneView.frame = floatingPaneTargetFrame()
        }
    }

    func installRenderedContentView(_ view: NSView) {
        if renderedContentView?.superview === contentContainerView {
            renderedContentView?.removeFromSuperview()
        }

        renderedContentView = view
        view.frame = contentContainerView.bounds
        contentContainerView.addSubview(view)
        needsLayout = true
    }

    func installFloatingPaneView(_ contentView: NSView, initialFrame: NSRect, animated: Bool) {
        if floatingPaneContentView !== contentView {
            floatingPaneView?.removeFromSuperview()
        }

        var installedContainer: WorkspaceFloatingPaneContainerView?
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentView.layer?.removeAllAnimations()
            contentView.removeFromSuperview()
            let container = WorkspaceFloatingPaneContainerView(
                contentView: contentView,
                frame: initialFrame
            )
            installedContainer = container
            container.layer?.removeAllAnimations()
            container.frame = initialFrame
            contentView.frame = container.bounds
            floatingOverlayView.addSubview(container)
            if let layer = container.layer {
                layer.frame = initialFrame
                layer.removeAllAnimations()
            }
            container.layoutSubtreeIfNeeded()
            CATransaction.commit()
        }
        floatingPaneView = installedContainer
        floatingPaneContentView = contentView
        lastFloatingPaneInitialFrame = initialFrame
        isFloatingPaneAnimating = animated
        needsLayout = true
    }

    func removeFloatingPaneView() {
        if floatingPaneView?.superview === floatingOverlayView {
            floatingPaneView?.removeFromSuperview()
        }
        floatingPaneView = nil
        floatingPaneContentView = nil
        lastFloatingPaneInitialFrame = nil
        isFloatingPaneAnimating = false
    }

    func beginFloatingPaneAnimation() {
        isFloatingPaneAnimating = true
    }

    func finishFloatingPaneAnimation() {
        isFloatingPaneAnimating = false
        floatingPaneView?.frame = floatingPaneTargetFrame()
    }

    func setFloatingPaneFrame(_ frame: NSRect) {
        floatingPaneView?.frame = frame
        floatingPaneView?.layoutSubtreeIfNeeded()
    }

    func animateFloatingPaneFrame(to frame: NSRect) {
        floatingPaneView?.animator().frame = frame
    }

    func floatingPaneTargetFrame() -> NSRect {
        let bounds = floatingOverlayView.bounds
        let targetSize = NSSize(
            width: min(
                bounds.width,
                max(bounds.width * 0.8, WorkspaceLayoutMetrics.minimumPaneSize.width)
            ),
            height: min(
                bounds.height,
                max(bounds.height * 0.9, WorkspaceLayoutMetrics.minimumPaneSize.height)
            )
        )

        return NSRect(
            x: (bounds.width - targetSize.width) / 2,
            y: (bounds.height - targetSize.height) / 2,
            width: targetSize.width,
            height: targetSize.height
        )
    }

    func floatingPaneFrame(for view: NSView) -> NSRect? {
        guard view.superview != nil else {
            return nil
        }

        layoutSubtreeIfNeeded()
        let windowFrame = view.convert(view.bounds, to: nil)
        let frame = floatingOverlayView.convert(windowFrame, from: nil)
        return frame.isEmpty ? nil : frame
    }

    func placeholderFrame(for paneID: PaneID) -> NSRect? {
        guard let placeholder = findPlaceholder(for: paneID, in: contentContainerView) else {
            return nil
        }

        layoutSubtreeIfNeeded()
        let windowFrame = placeholder.convert(placeholder.bounds, to: nil)
        return floatingOverlayView.convert(windowFrame, from: nil)
    }

    private func findPlaceholder(for paneID: PaneID, in view: NSView) -> TerminalPanePlaceholderView? {
        for subview in view.subviews {
            if let placeholder = subview as? TerminalPanePlaceholderView,
                placeholder.paneID == paneID
            {
                return placeholder
            }

            if let placeholder = findPlaceholder(for: paneID, in: subview) {
                return placeholder
            }
        }

        return nil
    }

    private var tabItems: [WorkspaceTabStripItem] = []

    func updateTabItems(_ items: [WorkspaceTabStripItem]) {
        tabItems = items
        tabStripView.items = items
        needsLayout = true
    }

    func updateAgentStatus(sessionCount: Int, unreadCount: Int) {
        toolbarView.updateAgentStatus(sessionCount: sessionCount, unreadCount: unreadCount)
    }

    func updateAppearance() {
        toolbarView.updateAppearance()
        updatePlaceholderAppearances(in: contentContainerView)
    }

    private func updatePlaceholderAppearances(in view: NSView) {
        for subview in view.subviews {
            if let placeholder = subview as? TerminalPanePlaceholderView {
                placeholder.updateAppearance()
            }

            updatePlaceholderAppearances(in: subview)
        }
    }

    var debugContentFrame: NSRect { contentFrame }
    var debugTabStripFrame: NSRect { toolbarFrame }
    var debugRenderedContentFrame: NSRect {
        guard let renderedContentView else {
            return .zero
        }

        return contentContainerView.convert(renderedContentView.frame, to: self)
    }
    var debugFloatingPaneFrame: NSRect? {
        guard let floatingPaneView else {
            return nil
        }

        return floatingOverlayView.convert(floatingPaneView.frame, to: self)
    }
    var debugLastFloatingPaneInitialFrame: NSRect? {
        guard let lastFloatingPaneInitialFrame else {
            return nil
        }

        return floatingOverlayView.convert(lastFloatingPaneInitialFrame, to: self)
    }

    func debugPlaceholderFrame(for paneID: PaneID) -> NSRect? {
        guard let frame = placeholderFrame(for: paneID) else {
            return nil
        }

        return floatingOverlayView.convert(frame, to: self)
    }

    func debugPlaceholderUsesHiddenWindowPresentation(for paneID: PaneID) -> Bool? {
        findPlaceholder(for: paneID, in: contentContainerView)?.debugUsesHiddenWindowPresentation
    }

    func debugPlaceholderVibrancyBlendingMode(
        for paneID: PaneID
    ) -> NSVisualEffectView.BlendingMode? {
        findPlaceholder(for: paneID, in: contentContainerView)?.debugVibrancyBlendingMode
    }

    func debugPlaceholderVibrancyTintAlpha(for paneID: PaneID) -> CGFloat? {
        findPlaceholder(for: paneID, in: contentContainerView)?.debugVibrancyTintAlpha
    }

    func debugSelectedTabBackgroundColor(for id: UUID) -> NSColor? {
        tabStripView.debugSelectedTabBackgroundColor(for: id)
    }

    func debugSelectedTabBackground(for id: UUID) -> AppAppearanceSettings.ActiveTabBackground? {
        tabStripView.debugSelectedTabBackground(for: id)
    }

    func debugTabUsesHiddenWindowPresentation(for id: UUID) -> Bool? {
        tabStripView.debugTabUsesHiddenWindowPresentation(for: id)
    }

    func debugTabIndexText(for id: UUID) -> String? {
        tabStripView.debugTabIndexText(for: id)
    }

    func debugTabCloseButtonIsHidden(for id: UUID) -> Bool? {
        tabStripView.debugTabCloseButtonIsHidden(for: id)
    }

    private func applyWindowBackgroundColor() {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}
