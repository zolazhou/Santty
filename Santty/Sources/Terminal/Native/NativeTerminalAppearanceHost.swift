import AppKit

/// Layout only, not a second terminal or pane/session controller. The scroll
/// view fills the host and owns its internal padding; decorations remain separate.
@MainActor
final class NativeTerminalAppearanceHost: NSView {
    let terminal: NativeTerminalScrollView
    let paddingFillView = NativeTerminalPaddingFillView()
    init(terminal: NativeTerminalScrollView) {
        self.terminal = terminal
        super.init(frame: .zero)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(paddingFillView)
        addSubview(terminal)
        paddingFillView.bind(to: terminal)
        let edges = [terminal.leadingAnchor.constraint(equalTo: leadingAnchor), terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
                 terminal.topAnchor.constraint(equalTo: topAnchor), terminal.bottomAnchor.constraint(equalTo: bottomAnchor)]
        NSLayoutConstraint.activate(edges)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        paddingFillView.frame = bounds
        paddingFillView.invalidate()
    }
    func apply(_ settings: NativeTerminalSettings) throws {
        try terminal.applySettings(settings) { [self] in layoutSubtreeIfNeeded() }
    }
}
