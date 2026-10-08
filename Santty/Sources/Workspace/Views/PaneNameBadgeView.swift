import AppKit

@MainActor
final class PaneNameBadgeView: NSView {
    // Match the scroll-mode badge: 8pt inset, 8/4pt padding, 5pt corners.
    private let label = NSTextField(labelWithString: "")
    var name: String? {
        didSet {
            label.stringValue = name ?? ""
            setAccessibilityLabel(name)
            invalidateIntrinsicContentSize()
            updateVisibility()
        }
    }
    var isRevealed = false {
        didSet { updateVisibility() }
    }
    var isFocused = false {
        didSet { updateAppearance() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        isHidden = true
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func updateAppearance() {
        layer?.backgroundColor = AppAppearanceSettings.accentColor.cgColor
        label.textColor = .white.withAlphaComponent(isFocused ? 1 : 0.75)
    }

    override var intrinsicContentSize: NSSize {
        // The text cell includes drawing insets that the label's intrinsic size omits.
        let size = label.cell?.cellSize ?? label.intrinsicContentSize
        return NSSize(width: ceil(size.width) + 16, height: ceil(size.height) + 8)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 8, dy: 4)
    }

    func layout(in host: NSView) {
        let size = intrinsicContentSize
        frame = NSRect(
            x: 8, y: host.isFlipped ? 8 : host.bounds.height - size.height - 8,
            width: min(size.width, max(0, host.bounds.width / 2 - 16)), height: size.height
        )
    }

    private func updateVisibility() {
        isHidden = !isRevealed || name == nil
        superview?.needsLayout = true
    }
}
