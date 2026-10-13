import AppKit

@MainActor
final class RestoredPanePlaceholderController: NSObject, PaneControlling {
    var savedPane: SavedWorkspace.Pane
    var id: PaneID { savedPane.id }
    private let placeholderView = RestoredPanePlaceholderView()
    var hostView: NSView { placeholderView }
    var displayTitle: String { savedPane.title }
    var name: String? { get { savedPane.name } set { savedPane.name = newValue } }
    let isLive = false
    var focusTargetView: NSView { hostView }
    var onFocusRequest: ((PaneID) -> Void)?
    var onTitleChange: ((PaneID) -> Void)?
    var onActivate: (() -> Void)?
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)

    init(pane: SavedWorkspace.Pane, message: String) {
        savedPane = pane
        super.init()
        placeholderView.onFocus = { [weak self] in
            guard let self else { return }
            self.onFocusRequest?(self.id)
        }
        label.stringValue = message
        label.alignment = .center
        button.title = pane.kind == .localTerminal ? "Start New Local Terminal" : "Choose Existing Terminal"
        button.target = self; button.action = #selector(activate)
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(stack)
        let maximumWidth = stack.widthAnchor.constraint(lessThanOrEqualTo: hostView.widthAnchor, constant: -24)
        maximumWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: hostView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: hostView.centerYAnchor),
            maximumWidth,
        ])
        updateAppearance()
    }

    func setMessage(_ message: String) { label.stringValue = message }
    @objc private func activate() { onFocusRequest?(id); onActivate?() }
    func updatePresentation(isFocused: Bool, isFloating: Bool) {
        hostView.layer?.borderWidth = isFocused ? AppAppearanceSettings.activePaneBorderWidth : 1
        hostView.effectiveAppearance.performAsCurrentDrawingAppearance {
            hostView.layer?.borderColor = (isFocused ? AppAppearanceSettings.accentColor : .separatorColor).cgColor
        }
    }
    func updateAppearance() {
        hostView.appearance = NSAppearance(named: .darkAqua)
        hostView.wantsLayer = true
        hostView.layer?.cornerRadius = AppAppearanceSettings.paneCornerRadius
        hostView.effectiveAppearance.performAsCurrentDrawingAppearance {
            hostView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
    func setNameVisible(_ visible: Bool) {}
    func startIfNeeded() {}
    func fitToSize() { hostView.layoutSubtreeIfNeeded() }
}

@MainActor
private final class RestoredPanePlaceholderView: NSView {
    var onFocus: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        onFocus?()
        window?.makeFirstResponder(self)
    }
}
