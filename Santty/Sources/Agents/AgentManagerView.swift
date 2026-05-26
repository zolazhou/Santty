import AppKit

@MainActor
final class AgentManagerView: NSView {
    var onFocusPane: ((PaneID) -> Void)?
    var onClearEnded: (() -> Void)?
    var onCancel: (() -> Void)?

    private var sessions: [AgentSessionSnapshot]
    private var selectedIndex = 0
    private let titleLabel = NSTextField(labelWithString: "Agents")
    private let clearButton = NSButton(title: "Clear Ended", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No tracked agents")
    private var rowViews: [AgentManagerRowView] = []

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(sessions: [AgentSessionSnapshot]) {
        self.sessions = sessions
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        wantsLayer = true
        layer?.backgroundColor = AgentManagerTheme.backgroundColor.cgColor
        appearance = NSAppearance(named: .darkAqua)
        configureSubviews()
        reloadRows()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 480, height: preferredHeight)
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 14
        titleLabel.frame = NSRect(x: padding, y: 12, width: 240, height: 22)
        clearButton.sizeToFit()
        clearButton.frame.origin = NSPoint(
            x: bounds.maxX - padding - clearButton.frame.width,
            y: 10
        )
        let contentY = titleLabel.frame.maxY + 10
        let contentHeight = max(0, bounds.height - contentY - padding)
        scrollView.frame = NSRect(
            x: padding,
            y: contentY,
            width: max(0, bounds.width - padding * 2),
            height: contentHeight
        )
        emptyLabel.frame = scrollView.frame
        layoutStackDocument()
    }

    override func keyDown(with event: NSEvent) {
        switch keyAction(for: event) {
        case .previous:
            moveSelection(by: -1)
        case .next:
            moveSelection(by: 1)
        case .confirm:
            focusSelectedSession()
        case .cancel:
            onCancel?()
        case .none:
            super.keyDown(with: event)
        }
    }

    func updateSessions(_ sessions: [AgentSessionSnapshot]) {
        self.sessions = sessions
        if selectedIndex >= sessions.count {
            selectedIndex = max(0, sessions.count - 1)
        }
        reloadRows()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    var preferredHeight: CGFloat {
        let rowHeight = CGFloat(max(sessions.count, 1)) * AgentManagerRowView.rowHeight
        return min(520, max(180, 58 + rowHeight + 18))
    }

    private func configureSubviews() {
        addSubview(titleLabel)
        addSubview(clearButton)
        addSubview(scrollView)
        addSubview(emptyLabel)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = AgentManagerTheme.primaryTextColor

        clearButton.target = self
        clearButton.action = #selector(handleClearEnded)
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.font = .systemFont(ofSize: 11, weight: .medium)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = stackView

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.spacing = 6

        emptyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyLabel.textColor = AgentManagerTheme.secondaryTextColor
        emptyLabel.alignment = .center
        emptyLabel.isBordered = false
        emptyLabel.isEditable = false
        emptyLabel.isSelectable = false
        emptyLabel.backgroundColor = .clear
    }

    private func reloadRows() {
        for rowView in rowViews {
            rowView.removeFromSuperview()
        }
        rowViews.removeAll()

        emptyLabel.isHidden = !sessions.isEmpty
        scrollView.isHidden = sessions.isEmpty
        clearButton.isEnabled = sessions.contains { !$0.isUnread && $0.isClearableWhenRead }

        for (index, session) in sessions.enumerated() {
            let rowView = AgentManagerRowView(session: session)
            rowView.isSelected = index == selectedIndex
            rowView.target = self
            rowView.action = #selector(handleRowClick(_:))
            stackView.addArrangedSubview(rowView)
            rowViews.append(rowView)
        }
        layoutStackDocument()
    }

    private func layoutStackDocument() {
        guard scrollView.bounds.width > 0 else {
            return
        }

        let height =
            CGFloat(rowViews.count) * AgentManagerRowView.rowHeight
            + CGFloat(max(0, rowViews.count - 1)) * stackView.spacing
        stackView.frame = NSRect(
            x: 0,
            y: 0,
            width: scrollView.bounds.width,
            height: max(scrollView.bounds.height, height)
        )
        for rowView in rowViews {
            rowView.frame.size.width = stackView.bounds.width
        }
    }

    private func moveSelection(by delta: Int) {
        guard !sessions.isEmpty else {
            return
        }

        selectedIndex = min(max(selectedIndex + delta, 0), sessions.count - 1)
        updateRowSelection()
        rowViews[selectedIndex].scrollToVisible(rowViews[selectedIndex].bounds)
    }

    private func updateRowSelection() {
        for (index, rowView) in rowViews.enumerated() {
            rowView.isSelected = index == selectedIndex
        }
    }

    private func focusSelectedSession() {
        guard sessions.indices.contains(selectedIndex) else {
            return
        }

        onFocusPane?(sessions[selectedIndex].paneID)
    }

    @objc private func handleRowClick(_ sender: AgentManagerRowView) {
        guard let index = rowViews.firstIndex(where: { $0 === sender }),
            sessions.indices.contains(index)
        else {
            return
        }

        selectedIndex = index
        onFocusPane?(sessions[index].paneID)
    }

    @objc private func handleClearEnded() {
        onClearEnded?()
    }

    private func keyAction(for event: NSEvent) -> AgentManagerKeyAction? {
        if event.keyCode == 53 {
            return .cancel
        }
        if event.keyCode == 36 {
            return .confirm
        }
        if event.keyCode == 126 {
            return .previous
        }
        if event.keyCode == 125 {
            return .next
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control {
            switch event.charactersIgnoringModifiers {
            case "p":
                return .previous
            case "n":
                return .next
            default:
                break
            }
        }

        return nil
    }
}

private enum AgentManagerTheme {
    static let backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
    static let rowBackgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
    @MainActor
    static var selectedRowBackgroundColor: NSColor {
        AppAppearanceSettings.accentColor.withAlphaComponent(0.30)
    }
    static let primaryTextColor = NSColor.white.withAlphaComponent(0.94)
    static let secondaryTextColor = NSColor.white.withAlphaComponent(0.62)
    static let tertiaryTextColor = NSColor.white.withAlphaComponent(0.42)
}

private enum AgentManagerKeyAction {
    case previous
    case next
    case confirm
    case cancel
}

@MainActor
private final class AgentManagerRowView: NSControl {
    static let rowHeight: CGFloat = 72

    var isSelected = false {
        didSet {
            updateAppearance()
        }
    }

    private let session: AgentSessionSnapshot
    private let agentLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let dotView = NSView()

    override var isFlipped: Bool { true }

    init(session: AgentSessionSnapshot) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 452, height: Self.rowHeight))
        configureSubviews()
        updateContent()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 452, height: Self.rowHeight)
    }

    override func layout() {
        super.layout()
        dotView.frame = NSRect(x: 10, y: 14, width: 8, height: 8)
        dotView.layer?.cornerRadius = 4

        let textX: CGFloat = 28
        let rightPadding: CGFloat = 10
        let statusWidth = min(150, statusLabel.intrinsicContentSize.width + 4)
        agentLabel.frame = NSRect(
            x: textX,
            y: 8,
            width: max(0, bounds.width - textX - statusWidth - rightPadding - 8),
            height: 18
        )
        statusLabel.frame = NSRect(
            x: bounds.maxX - rightPadding - statusWidth,
            y: 8,
            width: statusWidth,
            height: 18
        )
        detailLabel.frame = NSRect(
            x: textX,
            y: 29,
            width: max(0, bounds.width - textX - rightPadding),
            height: 16
        )
        messageLabel.frame = NSRect(
            x: textX,
            y: 49,
            width: max(0, bounds.width - textX - rightPadding),
            height: 16
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.trackEvents(
            matching: [.leftMouseUp], timeout: .infinity, mode: .eventTracking
        ) { [weak self] event, stop in
            guard let self else {
                stop.pointee = true
                return
            }
            guard let event else {
                return
            }

            if event.type == .leftMouseUp {
                if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.sendAction(self.action, to: self.target)
                }
                stop.pointee = true
            }
        }
    }

    private func configureSubviews() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        addSubview(dotView)
        addSubview(agentLabel)
        addSubview(statusLabel)
        addSubview(detailLabel)
        addSubview(messageLabel)

        for label in [agentLabel, statusLabel, detailLabel, messageLabel] {
            label.backgroundColor = .clear
            label.isBordered = false
            label.isEditable = false
            label.isSelectable = false
            label.lineBreakMode = .byTruncatingTail
        }
        agentLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.alignment = .right
        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        messageLabel.font = .systemFont(ofSize: 11, weight: .regular)
        dotView.wantsLayer = true
    }

    private func updateContent() {
        agentLabel.stringValue = session.agent.displayName
        statusLabel.stringValue = session.statusText
        detailLabel.stringValue = session.detailText
        messageLabel.stringValue = session.message ?? ""
        messageLabel.isHidden = session.message == nil
    }

    private func updateAppearance() {
        layer?.backgroundColor =
            isSelected
            ? AgentManagerTheme.selectedRowBackgroundColor.cgColor
            : AgentManagerTheme.rowBackgroundColor.cgColor
        agentLabel.textColor = AgentManagerTheme.primaryTextColor
        detailLabel.textColor = AgentManagerTheme.secondaryTextColor
        messageLabel.textColor = AgentManagerTheme.tertiaryTextColor
        statusLabel.textColor = session.statusColor
        dotView.layer?.backgroundColor = session.statusColor.cgColor
    }
}

extension AgentSessionSnapshot {
    fileprivate var isClearableWhenRead: Bool {
        displayState == .sessionEnded
    }

    fileprivate var statusText: String {
        let baseText =
            switch displayState {
            case .running:
                "Running"
            case .turnCompleted:
                "Turn Completed"
            case .waitingForUser:
                "Waiting for You"
            case .sessionEnded:
                "Session Ended"
            }

        return isUnread && displayState == .running ? "\(baseText) · unread" : baseText
    }

    fileprivate var detailText: String {
        [
            paneTitle,
            workingDirectory.map(lastPathComponent),
            relativeTimeString(from: lastEventAt),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    fileprivate var statusColor: NSColor {
        switch displayState {
        case .waitingForUser:
            return .systemOrange
        case .turnCompleted where isUnread:
            return .systemGreen
        case .sessionEnded:
            return AgentManagerTheme.secondaryTextColor
        default:
            return AgentManagerTheme.tertiaryTextColor
        }
    }

    private func lastPathComponent(_ path: String) -> String {
        let component = URL(fileURLWithPath: path).lastPathComponent
        return component.isEmpty ? path : component
    }

    private func relativeTimeString(from date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        if elapsed < 60 {
            return "now"
        }
        if elapsed < 3600 {
            return "\(Int(elapsed / 60))m ago"
        }
        if elapsed < 86400 {
            return "\(Int(elapsed / 3600))h ago"
        }
        return "\(Int(elapsed / 86400))d ago"
    }
}
