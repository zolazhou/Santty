import AppKit

@MainActor
final class WorkspaceStatusButtonView: NSControl {
    var title: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    var symbolName: String? {
        didSet {
            symbolImageView.image = symbolName.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: title)
            }?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            needsLayout = true
        }
    }

    var badgeText: String? {
        didSet {
            badgeView.text = badgeText
            badgeView.isHidden = badgeText == nil
            needsLayout = true
        }
    }

    private let vibrancyView = AppAppearanceDefaults.makeVibrancyView(
        tintViewAlpha: AppAppearanceDefaults.vibrancyTintAlpha
    )
    private let titleLabel = NSTextField(labelWithString: "")
    private let symbolImageView = NSImageView()
    private let badgeView = BadgeView()
    private let contentStackView = NSStackView()
    private let contentInset = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
    private let iconSize = NSSize(width: 14, height: 14)
    private let badgeHeight: CGFloat = 16
    private let minimumWidth: CGFloat = 98

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = false
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        configureSubviews()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil(titleLabel.intrinsicContentSize.width)
        let contentWidth = iconSize.width + contentStackView.spacing + titleWidth
        return NSSize(
            width: max(minimumWidth, contentInset.left + contentWidth + contentInset.right),
            height: 32
        )
    }

    override func mouseDown(with event: NSEvent) {
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
        titleLabel.textColor = .white.withAlphaComponent(0.88)
        symbolImageView.contentTintColor = .white.withAlphaComponent(0.86)
    }

    private func configureSubviews() {
        vibrancyView.translatesAutoresizingMaskIntoConstraints = false
        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        symbolImageView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(vibrancyView)
        addSubview(contentStackView)
        addSubview(badgeView)

        contentStackView.orientation = .horizontal
        contentStackView.alignment = .centerY
        contentStackView.distribution = .fill
        contentStackView.spacing = 6
        contentStackView.addArrangedSubview(symbolImageView)
        contentStackView.addArrangedSubview(titleLabel)

        symbolImageView.imageScaling = .scaleProportionallyDown
        symbolImageView.setContentHuggingPriority(.required, for: .horizontal)
        symbolImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byClipping
        titleLabel.backgroundColor = .clear
        titleLabel.isBordered = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        badgeView.isHidden = true

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth),

            vibrancyView.leadingAnchor.constraint(equalTo: leadingAnchor),
            vibrancyView.trailingAnchor.constraint(equalTo: trailingAnchor),
            vibrancyView.topAnchor.constraint(equalTo: topAnchor),
            vibrancyView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStackView.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: contentInset.left),
            contentStackView.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -contentInset.right),

            symbolImageView.widthAnchor.constraint(equalToConstant: iconSize.width),
            symbolImageView.heightAnchor.constraint(equalToConstant: iconSize.height),

            badgeView.topAnchor.constraint(equalTo: topAnchor, constant: -5),
            badgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 5),
            badgeView.heightAnchor.constraint(equalToConstant: badgeHeight),
            badgeView.widthAnchor.constraint(greaterThanOrEqualToConstant: badgeHeight),
        ])
    }

    private func highlight(_ isHighlighted: Bool) {
        alphaValue = isHighlighted ? 0.82 : 1
    }
}

@MainActor
private final class BadgeView: NSView {
    var text: String? {
        didSet {
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }

    private let font = NSFont.systemFont(ofSize: 10, weight: .bold)
    private let horizontalPadding: CGFloat = 8

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        guard let text, !text.isEmpty else {
            return NSSize(width: 16, height: 16)
        }

        let width = ceil(text.size(withAttributes: [.font: font]).width) + horizontalPadding
        return NSSize(width: max(16, width), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.systemRed.setFill()
        bounds.insetBy(dx: 0, dy: 0).roundedPath(radius: bounds.height / 2).fill()

        guard let text, !text.isEmpty else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attributes)
    }
}

private extension NSRect {
    func roundedPath(radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: self, xRadius: radius, yRadius: radius)
    }
}
