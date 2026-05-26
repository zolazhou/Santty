import AppKit

@MainActor
final class CommandPaletteWindowController: NSWindowController, NSWindowDelegate {
    var onCommand: ((AppCommand) -> Void)?
    var onDismiss: (() -> Void)?

    private let commandPaletteView = CommandPaletteView()
    private var isOrderingOut = false

    init() {
        let panel = CommandPalettePanel(contentView: commandPaletteView)
        super.init(window: panel)
        panel.delegate = self
        panel.onKeyDown = { [weak commandPaletteView] event in
            commandPaletteView?.handleKeyDown(event) ?? false
        }

        commandPaletteView.onDismiss = { [weak self] in
            self?.dismiss()
        }
        commandPaletteView.onPerformCommand = { [weak self] command in
            self?.dismiss(notify: false)
            self?.onCommand?(command)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    func show(commands: [AppCommand], relativeTo parentWindow: NSWindow) {
        guard let panel = window as? NSPanel else {
            return
        }

        commandPaletteView.updateCommands(commands, resetSearch: true)
        positionPanel(panel, over: parentWindow)
        panel.makeKeyAndOrderFront(nil)
        commandPaletteView.focusSearchField()
    }

    func dismiss() {
        dismiss(notify: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as AnyObject? === window else {
            return
        }

        guard !isOrderingOut else {
            return
        }

        dismiss()
    }

    private func dismiss(notify: Bool) {
        isOrderingOut = true
        window?.orderOut(nil)
        DispatchQueue.main.async { [weak self] in
            self?.isOrderingOut = false
        }

        if notify {
            onDismiss?()
        }
    }

    private func positionPanel(_ panel: NSPanel, over parentWindow: NSWindow) {
        let panelSize = panel.frame.size
        let parentFrame = parentWindow.frame
        let origin = NSPoint(
            x: parentFrame.midX - panelSize.width / 2,
            y: parentFrame.maxY - panelSize.height - 86
        )
        panel.setFrameOrigin(origin)
    }
}
