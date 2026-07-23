import AppKit

@MainActor
final class DetachedPaneStatusButtonView: NSControl {
    var numberText: String {
        get { numberLabel.stringValue }
        set {
            numberLabel.stringValue = newValue
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    var isActive: Bool = false {
        didSet {
            updateAppearance()
        }
    }

    override var isEnabled: Bool {
        didSet {
            updateAppearance()
        }
    }

    private let numberLabel = NSTextField(labelWithString: "")
    private let vibrancyView = AppAppearanceDefaults.makeVibrancyView(
        tintViewAlpha: AppAppearanceDefaults.vibrancyTintAlpha
    )
    private let sideLength: CGFloat = 32

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = false
        layer?.borderWidth = 1

        configureSubviews()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: sideLength, height: sideLength)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
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

    func updateAppearance() {
        vibrancyView.isHidden = !AppAppearanceSettings.isWindowHidden
        numberLabel.textColor = .white.withAlphaComponent(isEnabled ? (isActive ? 1 : 0.86) : 0.35)
        layer?.borderColor =
            isActive
            ? AppAppearanceSettings.accentColor.withAlphaComponent(0.95).cgColor
            : NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.backgroundColor =
            isActive
            ? AppAppearanceSettings.accentColor.withAlphaComponent(0.28).cgColor
            : NSColor.white.withAlphaComponent(0.04).cgColor
        alphaValue = isEnabled ? 1 : 0.55
    }

    private func configureSubviews() {
        vibrancyView.translatesAutoresizingMaskIntoConstraints = false
        vibrancyView.wantsLayer = true
        vibrancyView.layer?.cornerRadius = layer?.cornerRadius ?? 0
        vibrancyView.layer?.masksToBounds = true
        addSubview(vibrancyView)

        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        numberLabel.alignment = .center
        numberLabel.backgroundColor = .clear
        numberLabel.isBordered = false
        numberLabel.isEditable = false
        numberLabel.isSelectable = false
        addSubview(numberLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: sideLength),
            widthAnchor.constraint(equalToConstant: sideLength),

            vibrancyView.leadingAnchor.constraint(equalTo: leadingAnchor),
            vibrancyView.trailingAnchor.constraint(equalTo: trailingAnchor),
            vibrancyView.topAnchor.constraint(equalTo: topAnchor),
            vibrancyView.bottomAnchor.constraint(equalTo: bottomAnchor),

            numberLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func highlight(_ isHighlighted: Bool) {
        alphaValue = isHighlighted ? 0.82 : 1
    }
}
