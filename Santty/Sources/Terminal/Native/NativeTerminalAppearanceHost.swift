import AppKit

/// Layout only, not a second terminal or pane/session controller. Keeping all
/// padding OUTSIDE the NSScrollView leaves its virtual history coordinates and
/// AppKit elasticity unchanged. Production host decorations remain separate.
@MainActor
final class NativeTerminalAppearanceHost: NSView {
    let terminal: NativeTerminalScrollView
    let paddingFillView = NativeTerminalPaddingFillView()
    private var edges: [NSLayoutConstraint] = []
    init(terminal: NativeTerminalScrollView) {
        self.terminal = terminal
        super.init(frame: .zero)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(paddingFillView)
        addSubview(terminal)
        paddingFillView.bind(to: terminal)
        edges = [terminal.leadingAnchor.constraint(equalTo: leadingAnchor), terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
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
        try terminal.applySettings(settings) { [self] in
            let padding = settings.padding
            edges[0].constant = padding; edges[1].constant = -padding
            edges[2].constant = padding; edges[3].constant = -padding
            layoutSubtreeIfNeeded()
        }
    }
}
