import AppKit

@MainActor
private final class WorkspaceToolbarStackView: NSStackView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct DetachedPaneStatusItem: Equatable {
    let paneID: PaneID
    let number: Int
    let isActive: Bool
    let isEnabled: Bool
}

@MainActor
final class WorkspaceToolbarView: NSView {
    let tabStripView = WorkspaceTabStripView()
    let agentStatusButton = WorkspaceStatusButtonView()

    private let statusStackView = WorkspaceToolbarStackView()
    private var detachedPaneButtons: [PaneID: DetachedPaneStatusButtonView] = [:]
    private var detachedPaneOrder: [PaneID] = []
    private let spacing: CGFloat = 6
    private let toolbarHeight = WorkspaceLayoutMetrics.tabStripHeight

    override var isFlipped: Bool { true }

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let statusSize = statusStackView.fittingSize
        let hasVisibleStatusItem = statusStackView.arrangedSubviews.contains { !$0.isHidden }
        let statusWidth = hasVisibleStatusItem ? statusSize.width : 0
        let centeredY = max(0, (bounds.height - toolbarHeight) / 2)
        let statusX = max(bounds.minX, bounds.maxX - statusWidth)
        statusStackView.frame = NSRect(
            x: statusX,
            y: centeredY,
            width: statusWidth,
            height: toolbarHeight
        )

        let tabWidth = max(0, bounds.width - statusWidth - (statusWidth > 0 ? spacing : 0))
        tabStripView.frame = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: tabWidth,
            height: bounds.height
        )
    }

    func updateAgentStatus(sessionCount: Int, unreadCount: Int) {
        agentStatusButton.isHidden = sessionCount == 0
        agentStatusButton.title = "Agents"
        agentStatusButton.badgeText = unreadCount > 0 ? badgeText(for: unreadCount) : nil
        needsLayout = true
    }

    func updateDetachedPanes(
        _ items: [DetachedPaneStatusItem],
        target: AnyObject?,
        action: Selector
    ) {
        let itemIDs = items.map(\.paneID)
        for paneID in detachedPaneOrder where !itemIDs.contains(paneID) {
            if let button = detachedPaneButtons.removeValue(forKey: paneID) {
                statusStackView.removeArrangedSubview(button)
                button.removeFromSuperview()
            }
        }

        detachedPaneOrder = itemIDs
        for (index, item) in items.enumerated() {
            let button = detachedPaneButtons[item.paneID] ?? DetachedPaneStatusButtonView()
            if detachedPaneButtons[item.paneID] == nil {
                detachedPaneButtons[item.paneID] = button
            }

            button.numberText = "\(item.number)"
            button.tag = index
            button.target = target
            button.action = action
            button.isEnabled = item.isEnabled
            button.isActive = item.isActive

            if button.superview !== statusStackView {
                statusStackView.insertArrangedSubview(button, at: index)
            } else if statusStackView.arrangedSubviews.firstIndex(of: button) != index {
                statusStackView.removeArrangedSubview(button)
                statusStackView.insertArrangedSubview(button, at: index)
            }
        }

        if agentStatusButton.superview !== statusStackView {
            statusStackView.addArrangedSubview(agentStatusButton)
        } else {
            statusStackView.removeArrangedSubview(agentStatusButton)
            statusStackView.addArrangedSubview(agentStatusButton)
        }

        needsLayout = true
    }

    func updateAppearance() {
        tabStripView.updateAppearance()
        for button in detachedPaneButtons.values {
            button.updateAppearance()
        }
        agentStatusButton.updateAppearance()
    }

    func detachedPaneCellFrame(for paneID: PaneID) -> NSRect? {
        guard let button = detachedPaneButtons[paneID], button.superview != nil else {
            return nil
        }

        layoutSubtreeIfNeeded()
        return button.convert(button.bounds, to: nil)
    }

    func debugDetachedPaneCellIsActive(for paneID: PaneID) -> Bool? {
        detachedPaneButtons[paneID]?.isActive
    }

    private func configureSubviews() {
        addSubview(tabStripView)
        addSubview(statusStackView)

        statusStackView.orientation = .horizontal
        statusStackView.alignment = .centerY
        statusStackView.distribution = .fill
        statusStackView.spacing = spacing
        statusStackView.addArrangedSubview(agentStatusButton)

        agentStatusButton.symbolName = "sparkles"
        agentStatusButton.title = "Agents"
        agentStatusButton.isHidden = true
    }

    private func badgeText(for count: Int) -> String {
        count > 99 ? "99+" : String(count)
    }
}
