import AppKit

/// Floating location bar shown at the bottom of a browser pane. Hosts the
/// address field and doubles as the page load progress indicator.
@MainActor
final class BrowserLocationBarView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 32
    static let bottomMargin: CGFloat = 10
    static let sideMargin: CGFloat = 12

    let textField = NSTextField(string: "")

    var onSubmitURL: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onHoverExit: (() -> Void)?

    private let vibrancyView = AppAppearanceDefaults.makeVibrancyView(tintViewAlpha: 0.35)
    private let progressView = NSView()
    private var progress: Double = 0
    private var hoverTrackingArea: NSTrackingArea?

    private(set) var isBarVisible = true

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        appearance = NSAppearance(named: .darkAqua)

        // The bar floats above web content, so blend within the window rather
        // than with the desktop behind it.
        vibrancyView.blendingMode = .withinWindow
        vibrancyView.material = AppAppearanceDefaults.floatingPaneVibrancyMaterial
        addSubview(vibrancyView)

        textField.placeholderString = "Enter URL"
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingMiddle
        textField.appearance = NSAppearance(named: .darkAqua)
        textField.target = self
        textField.action = #selector(submitAddress(_:))
        textField.delegate = self
        addSubview(textField)

        progressView.wantsLayer = true
        progressView.layer?.backgroundColor = AppAppearanceSettings.accentColor.cgColor
        progressView.isHidden = true
        addSubview(progressView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        vibrancyView.frame = bounds
        let fieldHeight = textField.intrinsicContentSize.height
        textField.frame = NSRect(
            x: 10,
            y: (bounds.height - fieldHeight) / 2,
            width: bounds.width - 20,
            height: fieldHeight
        )
        updateProgressFrame(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverTrackingArea {
            onHoverExit?()
        }
    }

    func updateProgress(_ estimatedProgress: Double) {
        progress = min(max(estimatedProgress, 0), 1)
        progressView.isHidden = progress <= 0 || progress >= 1
        updateProgressFrame(animated: true)
    }

    func resetProgress() {
        progress = 0
        progressView.isHidden = true
        updateProgressFrame(animated: false)
    }

    private func updateProgressFrame(animated: Bool) {
        let target = NSRect(
            x: 0,
            y: bounds.height - 2,
            width: bounds.width * progress,
            height: 2
        )
        guard animated else {
            progressView.frame = target
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            progressView.animator().frame = target
        }
    }

    func setVisible(_ visible: Bool, animated: Bool) {
        guard visible != isBarVisible else {
            return
        }
        isBarVisible = visible

        let targetAlpha: CGFloat = visible ? 1 : 0
        let targetOffset: CGFloat = visible ? 0 : -6
        guard animated, superview != nil else {
            alphaValue = targetAlpha
            layer?.transform = CATransform3DMakeTranslation(0, targetOffset, 0)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = targetAlpha
        }
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = layer?.presentation()?.value(forKeyPath: "transform.translation.y")
        animation.toValue = targetOffset
        animation.duration = 0.15
        layer?.transform = CATransform3DMakeTranslation(0, targetOffset, 0)
        layer?.add(animation, forKey: "locationBarSlide")
    }

    func focusTextField(selectingAll: Bool = true) {
        guard let window else {
            return
        }
        window.makeFirstResponder(textField)
        if selectingAll {
            textField.currentEditor()?.selectAll(nil)
        }
    }

    @objc private func submitAddress(_ sender: NSTextField) {
        // First-responder churn (tab switches, pane rebuilds) can detach the
        // field editor and make AppKit deliver the action spuriously. Only a
        // visible bar with non-empty text is a genuine user submission.
        guard isBarVisible,
            !sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        onSubmitURL?(sender.stringValue)
    }

    func control(
        _: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}
