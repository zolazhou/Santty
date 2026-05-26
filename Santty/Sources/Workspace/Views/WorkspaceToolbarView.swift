import AppKit

@MainActor
final class WorkspaceToolbarView: NSView {
    let tabStripView = WorkspaceTabStripView()
    let agentStatusButton = WorkspaceStatusButtonView()

    private let statusStackView = NSStackView()
    private let spacing: CGFloat = 6
    private let toolbarHeight = WorkspaceLayoutMetrics.tabStripHeight

    override var isFlipped: Bool { true }

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
        let statusWidth = agentStatusButton.isHidden ? 0 : statusSize.width
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

    func updateAppearance() {
        tabStripView.updateAppearance()
        agentStatusButton.updateAppearance()
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
