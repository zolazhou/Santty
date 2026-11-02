import AppKit

@MainActor
final class AgentManagerPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let managerView: AgentManagerView
    private weak var previousFirstResponder: NSResponder?
    private weak var parentWindow: NSWindow?
    private var onClose: (() -> Void)?
    private var shouldRestoreFocus = true

    init(
        sessions: [AgentSessionSnapshot],
        previousFirstResponder: NSResponder?,
        onFocusPane: @escaping (AgentSessionSnapshot) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.managerView = AgentManagerView(sessions: sessions)
        self.previousFirstResponder = previousFirstResponder
        self.onClose = onClose
        super.init()

        managerView.onFocusPane = { [weak self] paneID in
            self?.shouldRestoreFocus = false
            self?.popover.close()
            onFocusPane(paneID)
        }
        managerView.onContentSizeChange = { [weak self] in self?.updateContentSize() }
        managerView.onCancel = { [weak self] in
            self?.popover.close()
        }

        let viewController = NSViewController()
        viewController.view = managerView
        popover.contentViewController = viewController
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        updateContentSize()
    }

    var isShown: Bool {
        popover.isShown
    }

    func show(relativeTo anchorView: NSView) {
        parentWindow = anchorView.window
        popover.show(
            relativeTo: anchorView.bounds,
            of: anchorView,
            preferredEdge: .maxY
        )
        managerView.window?.makeKey()
        managerView.window?.makeFirstResponder(managerView)
    }

    func close() {
        popover.close()
    }

    func updateSessions(_ sessions: [AgentSessionSnapshot], messages: [AgentSessionSnapshot]) {
        managerView.updateSessions(sessions, messages: messages)
        updateContentSize()
    }

    func popoverDidClose(_: Notification) {
        if shouldRestoreFocus,
            let parentWindow,
            let previousFirstResponder,
            previousFirstResponder !== managerView
        {
            parentWindow.makeFirstResponder(previousFirstResponder)
        }
        onClose?()
    }

    private func updateContentSize() {
        popover.contentSize = NSSize(width: 480, height: managerView.preferredHeight)
    }
}
