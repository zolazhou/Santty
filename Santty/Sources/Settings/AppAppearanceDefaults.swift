import AppKit

enum AppAppearanceDefaults {
    static let terminalBackgroundOpacity = 0.0
    static let vibrancyTintAlpha: CGFloat = 0.75
    static let vibrancyMaterial: NSVisualEffectView.Material = .hudWindow
    static let vibrancyBlendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    static let floatingPaneVibrancyTintAlpha: CGFloat = 0.0
    static let floatingPaneVibrancyMaterial: NSVisualEffectView.Material = .popover
    static let floatingPaneVibrancyBlendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    static let vibrancyState: NSVisualEffectView.State = .active
    static let vibrancyAppearanceName = NSAppearance.Name.darkAqua
    static let vibrancyTintIdentifier = NSUserInterfaceItemIdentifier("Santty.VibrancyTintView")
    private static let rootVibrancyIdentifier = NSUserInterfaceItemIdentifier(
        "Santty.RootVibrancyView")

    @MainActor
    private static func makeVibrancyTintView(alpha: CGFloat) -> NSView {
        let view = NSView()
        view.identifier = vibrancyTintIdentifier
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
        return view
    }

    @MainActor
    static func makeVibrancyView(tintViewAlpha: CGFloat? = nil) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = vibrancyMaterial
        view.blendingMode = vibrancyBlendingMode
        view.state = vibrancyState
        view.appearance = NSAppearance(named: vibrancyAppearanceName)

        if let tintViewAlpha, tintViewAlpha > 0 {
            let tintView = makeVibrancyTintView(alpha: tintViewAlpha)
            tintView.frame = view.bounds
            tintView.autoresizingMask = [.width, .height]
            view.addSubview(tintView)
        }

        return view
    }

    @MainActor
    static func applyWindowPresentation(to window: NSWindow, isWindowHidden: Bool) {
        window.isOpaque = !isWindowHidden
        window.hasShadow = !isWindowHidden
        window.backgroundColor = isWindowHidden ? .clear : .windowBackgroundColor
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        guard let rootView = window.contentView else {
            return
        }

        syncRootVibrancyView(in: rootView, isVisible: !isWindowHidden)
    }

    @MainActor
    private static func syncRootVibrancyView(in rootView: NSView, isVisible: Bool) {
        if !isVisible {
            rootVibrancyView(in: rootView)?.removeFromSuperview()
            return
        }

        if let vibrancyView = rootVibrancyView(in: rootView) {
            vibrancyView.frame = rootView.bounds
            return
        }

        let vibrancyView = makeVibrancyView(tintViewAlpha: 0.5)
        vibrancyView.identifier = rootVibrancyIdentifier
        vibrancyView.frame = rootView.bounds
        vibrancyView.autoresizingMask = [.width, .height]

        if let frontmostView = rootView.subviews.first {
            rootView.addSubview(vibrancyView, positioned: .below, relativeTo: frontmostView)
        } else {
            rootView.addSubview(vibrancyView)
        }
    }

    @MainActor
    private static func rootVibrancyView(in rootView: NSView) -> NSVisualEffectView? {
        rootView.subviews.first {
            $0.identifier == rootVibrancyIdentifier
        } as? NSVisualEffectView
    }
}
