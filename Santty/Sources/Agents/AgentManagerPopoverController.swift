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
        onFocusPane: @escaping (PaneID) -> Void,
        onClearEnded: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.managerView = AgentManagerView(sessions: sessions)
        self.previousFirstResponder = previousFirstResponder
        self.onClose = onClose
        super.init()

        managerView.onFocusPane = { [weak self] paneID in
            self?.shouldRestoreFocus = false
            self?.popover.performClose(nil)
            onFocusPane(paneID)
        }
        managerView.onClearEnded = onClearEnded
        managerView.onCancel = { [weak self] in
            self?.popover.performClose(nil)
        }

        let viewController = NSViewController()
        viewController.view = managerView
        viewController.view.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = viewController
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
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
        anchorView.window?.makeFirstResponder(managerView)
    }

    func close() {
        popover.performClose(nil)
    }

    func updateSessions(_ sessions: [AgentSessionSnapshot]) {
        managerView.updateSessions(sessions)
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
