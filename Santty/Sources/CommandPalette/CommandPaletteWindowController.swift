import AppKit

@MainActor
final class CommandPaletteWindowController: NSWindowController, NSWindowDelegate {
    var onCommand: ((AppCommand) -> Void)?
    var onDismiss: (() -> Void)?
    var commandsProvider: (() -> [AppCommand])?

    private let commandPaletteView = CommandPaletteView()
    private var isOrderingOut = false
    private var refreshTimer: Timer?
    private var displayedItems: [AppCommandSnapshot] = []

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
        displayedItems = commands.map(\.paletteSnapshot)
        refreshTimer?.invalidate()
        if commandsProvider != nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.window?.isVisible == true, let items = self.commandsProvider?() else { return }
                    let snapshot = items.map(\.paletteSnapshot)
                    guard snapshot != self.displayedItems else { return }
                    self.displayedItems = snapshot
                    self.commandPaletteView.updateCommands(items, resetSearch: false)
                }
            }
        }
        panel.contentMinSize = commandPaletteView.preferredContentSize
        panel.contentMaxSize = commandPaletteView.preferredContentSize
        panel.setContentSize(commandPaletteView.preferredContentSize)
        positionPanel(panel, over: parentWindow)
        PaneInputSourceCoordinator.shared.paletteWillOpen()
        panel.makeKeyAndOrderFront(nil)
        commandPaletteView.focusSearchField()
        if let editor = panel.firstResponder as? NSView {
            PaneInputSourceCoordinator.shared.paletteDidFocus(editor)
        }
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
        guard window?.isVisible == true else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
        isOrderingOut = true
        window?.orderOut(nil)
        PaneInputSourceCoordinator.shared.paletteDidClose()
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
