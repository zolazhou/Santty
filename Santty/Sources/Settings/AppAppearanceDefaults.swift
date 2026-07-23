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
    static func applyWindowPresentation(
        to window: NSWindow,
        isWindowHidden: Bool,
        cornerRadius: CGFloat = 0
    ) {
        window.isOpaque = !isWindowHidden
        window.hasShadow = !isWindowHidden
        window.backgroundColor = isWindowHidden ? .clear : .windowBackgroundColor
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // Keep the window titled even in hidden mode: AppKit does not deliver
        // drop events (performDragOperation) to borderless windows, which
        // breaks tab reordering. A transparent, button-less titlebar looks
        // identical to a borderless window but keeps drag-and-drop working.
        window.styleMask.insert(.titled)

        // A titled window's corners are always clipped by the WindowServer
        // corner mask (~16pt on macOS 26), which no CALayer change can
        // override; these private AppKit setters adjust the mask itself.
        // `_setCornerRadius:` treats 0 as "reset to the system default", so a
        // true zero radius requires `_setEffectiveCornerRadius:` afterwards.
        applyCornerRadius(cornerRadius, to: window, isWindowHidden: isWindowHidden)

        guard let rootView = window.contentView else {
            return
        }

        syncRootVibrancyView(in: rootView, isVisible: !isWindowHidden)
    }

    @MainActor
    private static func applyCornerRadius(
        _ cornerRadius: CGFloat,
        to window: NSWindow,
        isWindowHidden: Bool
    ) {
        let setRadius = NSSelectorFromString("_setCornerRadius:")
        let setEffectiveRadius = NSSelectorFromString("_setEffectiveCornerRadius:")
        guard window.responds(to: setRadius) else {
            return
        }

        guard isWindowHidden else {
            // Reset to the system default radius.
            setWindowCornerValue(0, selector: setRadius, on: window)
            return
        }

        setWindowCornerValue(cornerRadius, selector: setRadius, on: window)
        if cornerRadius == 0, window.responds(to: setEffectiveRadius) {
            setWindowCornerValue(0, selector: setEffectiveRadius, on: window)
        }
    }

    @MainActor
    private static func setWindowCornerValue(
        _ value: CGFloat,
        selector: Selector,
        on window: NSWindow
    ) {
        typealias Setter = @convention(c) (NSWindow, Selector, CGFloat) -> Void
        guard let implementation = window.method(for: selector) else {
            return
        }

        unsafeBitCast(implementation, to: Setter.self)(window, selector, value)
    }

    @MainActor
    static func debugEffectiveCornerRadius(of window: NSWindow) -> CGFloat? {
        let getEffectiveRadius = NSSelectorFromString("_effectiveCornerRadius")
        typealias Getter = @convention(c) (NSWindow, Selector) -> CGFloat
        guard window.responds(to: getEffectiveRadius),
            let implementation = window.method(for: getEffectiveRadius)
        else {
            return nil
        }

        return unsafeBitCast(implementation, to: Getter.self)(window, getEffectiveRadius)
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
