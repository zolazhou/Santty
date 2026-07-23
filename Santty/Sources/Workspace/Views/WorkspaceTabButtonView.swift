import AppKit

@MainActor
final class WorkspaceTabButtonView: NSControl {
    var titleFont: NSFont {
        get {
            titleLabel.font ?? .systemFont(ofSize: 12, weight: .medium)
        }
        set {
            titleLabel.font = newValue
            needsLayout = true
        }
    }

    var titleAlignment: NSTextAlignment {
        get {
            titleLabel.alignment
        }
        set {
            titleLabel.alignment = newValue
        }
    }

    var contentInset = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10) {
        didSet {
            stackView.edgeInsets = contentInset
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
    }

    var title: String {
        get {
            titleLabel.stringValue
        }
        set {
            titleLabel.stringValue = newValue
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
    }

    var index: Int? {
        didSet {
            indexLabel.stringValue = index.map(String.init) ?? ""
            updateCloseButtonVisibility()
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
    }

    var showsCloseButton = true {
        didSet {
            updateCloseButtonVisibility()
            invalidateIntrinsicContentSize()
        }
    }

    var minimumWidth: CGFloat = 60 {
        didSet {
            updateWidthConstraints()
            invalidateIntrinsicContentSize()
        }
    }

    var maximumWidth: CGFloat = 220 {
        didSet {
            updateWidthConstraints()
            invalidateIntrinsicContentSize()
        }
    }

    var fixedWidth: CGFloat? {
        didSet {
            updateWidthConstraints()
            invalidateIntrinsicContentSize()
        }
    }

    var onClose: (() -> Void)?
    var forwardsMouseDownToResponderChain = false

    var isSelected = false {
        didSet {
            updateSelectionAppearance()
        }
    }

    private let vibrancyView = AppAppearanceDefaults.makeVibrancyView(
        tintViewAlpha: AppAppearanceDefaults.vibrancyTintAlpha
    )
    private let selectedBackgroundView = ActiveTabBackgroundView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let indexLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let closeButtonSize = NSSize(width: 18, height: 18)
    private let stackView = NSStackView()
    private var widthConstraints: [NSLayoutConstraint] = []
    private var isHoveringCloseTarget = false

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true

        configureTitleLabel()
        configureIndexLabel()
        configureCloseButton()
        addSubview(vibrancyView)
        addSubview(selectedBackgroundView)
        addSubview(stackView)
        addSubview(closeButton)
        configureStackView()
        updateAppearance()
        updateWidthConstraints()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        vibrancyView.frame = bounds
        selectedBackgroundView.frame = bounds
        selectedBackgroundView.cornerRadius = layer?.cornerRadius ?? 0

        closeButton.frame = NSRect(
            x: bounds.maxX - contentInset.right - closeButtonSize.width,
            y: bounds.midY - closeButtonSize.height / 2,
            width: closeButtonSize.width,
            height: closeButtonSize.height
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for trackingArea in trackingAreas {
            removeTrackingArea(trackingArea)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
    }

    override func mouseEntered(with _: NSEvent) {
        isHoveringCloseTarget = true
        updateCloseButtonVisibility()
    }

    override func mouseExited(with _: NSEvent) {
        isHoveringCloseTarget = false
        updateCloseButtonVisibility()
    }

    override var intrinsicContentSize: NSSize {
        if let fixedWidth {
            return NSSize(width: fixedWidth, height: 32)
        }

        let titleWidth = titleLabel.intrinsicContentSize.width
        let indexWidth =
            index == nil
            ? 0
            : max(indexLabel.intrinsicContentSize.width, closeButtonSize.width)
        let spacing = indexWidth > 0 ? stackView.spacing : 0
        let width = contentInset.left + titleWidth + spacing + indexWidth + contentInset.right
        return NSSize(width: min(max(width, minimumWidth), maximumWidth), height: 32)
    }

    override func mouseDown(with event: NSEvent) {
        if forwardsMouseDownToResponderChain {
            nextResponder?.mouseDown(with: event)
            return
        }

        highlight(true)
        window?.trackEvents(
            matching: [.leftMouseUp], timeout: .infinity, mode: .eventTracking
        ) { [weak self] event, stop in
            guard let self else {
                stop.pointee = true
                return
            }

            guard let event else {
                return
            }

            if event.type == .leftMouseUp {
                self.highlight(false)
                if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.sendAction(self.action, to: self.target)
                }
                stop.pointee = true
            }
        }
    }

    private func configureTitleLabel() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .left
        titleLabel.textColor = .white.withAlphaComponent(0.92)
        titleLabel.backgroundColor = .clear
        titleLabel.isBordered = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false

        selectedBackgroundView.background = AppAppearanceSettings.activeTabBackground
    }

    private func configureIndexLabel() {
        indexLabel.font = .systemFont(ofSize: 12, weight: .medium)
        indexLabel.alignment = .center
        indexLabel.textColor = .white.withAlphaComponent(0.56)
        indexLabel.backgroundColor = .clear
        indexLabel.isBordered = false
        indexLabel.isEditable = false
        indexLabel.isSelectable = false
        indexLabel.setContentHuggingPriority(.required, for: .horizontal)
        indexLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureCloseButton() {
        closeButton.target = self
        closeButton.action = #selector(handleCloseButton)
        closeButton.bezelStyle = .shadowlessSquare
        closeButton.isBordered = false
        closeButton.isHidden = true
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close Tab"
        )?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = closeButtonSize.height / 2
        closeButton.layer?.masksToBounds = true
        closeButton.contentTintColor = .white.withAlphaComponent(0.92)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateCloseButtonAppearance()
    }

    private func configureStackView() {
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fill
        stackView.spacing = 8
        stackView.edgeInsets = contentInset
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(indexLabel)

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            indexLabel.widthAnchor.constraint(
                greaterThanOrEqualToConstant: closeButtonSize.width
            ),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func updateWidthConstraints() {
        NSLayoutConstraint.deactivate(widthConstraints)
        if let fixedWidth {
            widthConstraints = [
                widthAnchor.constraint(equalToConstant: fixedWidth)
            ]
        } else {
            widthConstraints = [
                widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth),
                widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth),
            ]
        }
        NSLayoutConstraint.activate(widthConstraints)
    }

    private func highlight(_ isHighlighted: Bool) {
        alphaValue = isHighlighted ? 0.82 : 1
    }

    @objc private func handleCloseButton() {
        onClose?()
    }

    private func updateCloseButtonVisibility() {
        closeButton.isHidden = !showsCloseButton || !isHoveringCloseTarget
        indexLabel.isHidden = index == nil
        indexLabel.alphaValue = showsCloseButton && isHoveringCloseTarget ? 0 : 1
        updateCloseButtonAppearance()
    }

    private func updateCloseButtonAppearance() {
        closeButton.layer?.backgroundColor =
            NSColor.white.withAlphaComponent(
                isSelected ? 0.24 : 0.16
            ).cgColor
    }

    private func updateSelectionAppearance() {
        selectedBackgroundView.isHidden = !isSelected
        selectedBackgroundView.background = AppAppearanceSettings.activeTabBackground
        layer?.borderWidth = isSelected ? 0 : 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        titleLabel.textColor = isSelected ? .white : .white.withAlphaComponent(0.82)
        updateCloseButtonAppearance()
    }

    func updateAppearance() {
        vibrancyView.isHidden = !AppAppearanceSettings.isWindowHidden
        updateSelectionAppearance()
    }

    var debugSelectedBackgroundColor: NSColor? {
        selectedBackgroundView.debugSolidBackgroundColor
    }

    var debugSelectedBackground: AppAppearanceSettings.ActiveTabBackground {
        selectedBackgroundView.background
    }

    var debugUsesHiddenWindowPresentation: Bool {
        !vibrancyView.isHidden
    }

    var debugIndexText: String {
        indexLabel.stringValue
    }

    var debugCloseButtonIsHidden: Bool {
        closeButton.isHidden
    }
}

@MainActor
private final class ActiveTabBackgroundView: NSView {
    var background = AppAppearanceSettings.activeTabBackground {
        didSet {
            updateLayerContents()
        }
    }

    var cornerRadius: CGFloat = 0 {
        didSet {
            layer?.cornerRadius = cornerRadius
            gradientLayer.cornerRadius = cornerRadius
        }
    }

    private let gradientLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(gradientLayer)
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        updateLayerContents()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
    }

    private func updateLayerContents() {
        switch background {
        case .solid(let color):
            layer?.backgroundColor = color.cgColor
            gradientLayer.isHidden = true
            gradientLayer.colors = nil
        case .gradient(let startColor, let endColor):
            layer?.backgroundColor = nil
            gradientLayer.isHidden = false
            gradientLayer.colors = [startColor.cgColor, endColor.cgColor]
        }
    }

    var debugSolidBackgroundColor: NSColor? {
        guard case .solid(let color) = background else {
            return nil
        }

        return color
    }
}
