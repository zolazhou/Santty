import AppKit

@MainActor
final class AgentManagerView: NSView, NSPopoverDelegate {
    var onFocusPane: ((AgentSessionSnapshot) -> Void)?
    var onCancel: (() -> Void)?
    var onContentSizeChange: (() -> Void)?

    private var sessions: [AgentSessionSnapshot]
    private var messageSessions: [AgentSessionSnapshot] = []
    private let isMessageList: Bool
    private var messagePopover: NSPopover?
    private var messageListView: AgentManagerView?
    private var messageAgentID: String?
    private var pendingMessageSelection: AgentSessionSnapshot?
    private var selectedIndex = 0
    private let titleLabel = NSTextField(labelWithString: "Agents")
    private let scrollView = NSScrollView()
    private let stackView = AgentManagerListView()
    private let rowSpacing = ListPaneStyle.rowSpacing
    private let emptyLabel = NSTextField(labelWithString: "No agent status reported by herdr-core")
    private var rowViews: [AgentManagerRowView] = []

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(sessions: [AgentSessionSnapshot], messageListTitle: String? = nil) {
        self.sessions = sessions
        self.isMessageList = messageListTitle != nil
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        wantsLayer = true
        configureSubviews()
        titleLabel.stringValue = messageListTitle ?? "Agents"
        emptyLabel.stringValue = isMessageList ? "No messages for this agent" : "No agent status reported by herdr-core"
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
        let padding = ListPaneStyle.padding
        titleLabel.frame = NSRect(x: padding, y: 12, width: max(0, bounds.width - padding * 2), height: 22)
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
        if event.keyCode == 124, !isMessageList, rowViews.indices.contains(selectedIndex) {
            showMessages(rowViews[selectedIndex].messagesButton)
            return
        }
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { messagePopover?.close() }
        super.viewWillMove(toWindow: newWindow)
    }

    func updateSessions(_ sessions: [AgentSessionSnapshot], messages: [AgentSessionSnapshot]) {
        let selectedID = self.sessions.indices.contains(selectedIndex) ? self.sessions[selectedIndex].id : nil
        self.sessions = sessions
        messageSessions = messages
        selectedIndex = selectedID.flatMap { id in sessions.firstIndex { $0.id == id } } ?? 0
        reloadRows()
        if let id = messageAgentID, let row = rowViews.first(where: { $0.session.id == id }) {
            messageListView?.updateSessions(messagesForAgent(id), messages: [])
            messagePopover?.contentSize = NSSize(width: 420, height: messageListView?.preferredHeight ?? 180)
            row.messagesButton.state = .on
        } else { messagePopover?.close() }
        invalidateIntrinsicContentSize()
        needsLayout = true
        onContentSizeChange?()
    }

    func messagesForAgent(_ id: String) -> [AgentSessionSnapshot] {
        messageSessions.filter { $0.recordID == id }
    }

    @objc private func showMessages(_ sender: NSButton) {
        guard let row = rowViews.first(where: { $0.messagesButton === sender }), window != nil else { return }
        if messageAgentID == row.session.id, messagePopover?.isShown == true {
            messagePopover?.close()
            return
        }
        pendingMessageSelection = nil
        messagePopover?.close()
        for row in rowViews { row.messagesButton.state = .off }
        let popover = NSPopover()
        let list = AgentManagerView(sessions: messagesForAgent(row.session.id),
                                    messageListTitle: row.session.agent.displayName + " Messages")
        list.onFocusPane = { [weak self, weak popover] message in
            self?.pendingMessageSelection = message
            popover?.close()
        }
        list.onCancel = { [weak popover] in popover?.close() }
        let controller = NSViewController()
        controller.view = list
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: 420, height: list.preferredHeight)
        messagePopover = popover
        messageListView = list
        messageAgentID = row.session.id
        row.messagesButton.state = .on
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
        list.window?.makeKey()
        list.window?.makeFirstResponder(list)
    }

    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === messagePopover else { return }
        let selection = pendingMessageSelection
        pendingMessageSelection = nil
        for row in rowViews { row.messagesButton.state = .off }
        messagePopover = nil
        messageListView = nil
        messageAgentID = nil
        // The outer popover can close only after AppKit's child-close callback returns.
        if let selection {
            DispatchQueue.main.async { [weak self] in self?.onFocusPane?(selection) }
        }
    }

    var preferredHeight: CGFloat {
        let rowHeight = CGFloat(max(sessions.count, 1)) * AgentManagerRowView.rowHeight
        return min(520, max(180, 44 + rowHeight + CGFloat(max(0, sessions.count - 1)) * rowSpacing + 14))
    }

    private func configureSubviews() {
        addSubview(titleLabel)
        addSubview(scrollView)
        addSubview(emptyLabel)

        titleLabel.font = ListPaneStyle.titleFont
        titleLabel.textColor = ListPaneStyle.primaryTextColor

        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = stackView

        emptyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyLabel.textColor = ListPaneStyle.secondaryTextColor
        emptyLabel.alignment = .center
        emptyLabel.isBordered = false
        emptyLabel.isEditable = false
        emptyLabel.isSelectable = false
        emptyLabel.backgroundColor = .clear
    }

    private func reloadRows() {
        let previous = Dictionary(uniqueKeysWithValues: rowViews.map { ($0.session.id, $0) })
        let ids = Set(sessions.map(\.id))
        for row in rowViews where !ids.contains(row.session.id) { row.removeFromSuperview() }
        rowViews = sessions.enumerated().map { index, session in
            let row = previous[session.id] ?? AgentManagerRowView(session: session)
            let messages = messagesForAgent(session.id)
            row.update(session: session, messageCount: messages.count, unreadCount: messages.filter(\.isUnread).count,
                       showsMessagesButton: !isMessageList)
            row.isSelected = index == selectedIndex
            row.target = self
            row.action = #selector(handleRowClick(_:))
            row.messagesButton.target = self
            row.messagesButton.action = #selector(showMessages(_:))
            if row.superview == nil { stackView.addSubview(row) }
            return row
        }
        emptyLabel.isHidden = !sessions.isEmpty
        scrollView.isHidden = sessions.isEmpty
        layoutStackDocument()
    }

    private func layoutStackDocument() {
        guard scrollView.bounds.width > 0 else {
            return
        }

        let height =
            CGFloat(rowViews.count) * AgentManagerRowView.rowHeight
            + CGFloat(max(0, rowViews.count - 1)) * rowSpacing
        stackView.frame = NSRect(
            x: 0,
            y: 0,
            width: scrollView.bounds.width,
            height: max(scrollView.bounds.height, height)
        )
        for (index, rowView) in rowViews.enumerated() {
            rowView.frame = NSRect(x: 0, y: CGFloat(index) * (AgentManagerRowView.rowHeight + rowSpacing),
                                  width: stackView.bounds.width, height: AgentManagerRowView.rowHeight)
        }
        // Keep accessibility traversal in visual order without replacing popover anchors.
        stackView.sortSubviews({ left, right, _ in
            MainActor.assumeIsolated {
                left.frame.minY < right.frame.minY ? .orderedAscending : left.frame.minY > right.frame.minY ? .orderedDescending : .orderedSame
            }
        }, context: nil)
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

        onFocusPane?(sessions[selectedIndex])
    }

    @objc private func handleRowClick(_ sender: AgentManagerRowView) {
        guard let index = rowViews.firstIndex(where: { $0 === sender }),
            sessions.indices.contains(index)
        else {
            return
        }

        selectedIndex = index
        onFocusPane?(sessions[index])
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

@MainActor
private final class AgentManagerListView: NSView {
    override var isFlipped: Bool { true }
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

    private(set) var session: AgentSessionSnapshot
    private let openButton = NSButton()
    let messagesButton = NSButton()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
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
        NSSize(width: NSView.noIntrinsicMetric, height: Self.rowHeight)
    }

    override func layout() {
        super.layout()
        openButton.frame = bounds
        iconView.frame = NSRect(x: 10, y: 8, width: 18, height: 18)
        dotView.layer?.cornerRadius = 4

        let textX: CGFloat = 36
        let rightPadding: CGFloat = 10
        let statusWidth = min(150, max(0, bounds.width - textX - rightPadding) * 0.55, statusLabel.intrinsicContentSize.width + 4)
        titleLabel.frame = NSRect(
            x: textX,
            y: 8,
            width: max(0, bounds.width - textX - statusWidth - rightPadding - 20),
            height: 18
        )
        statusLabel.frame = NSRect(
            x: bounds.maxX - rightPadding - statusWidth,
            y: 8,
            width: statusWidth,
            height: 18
        )
        dotView.frame = NSRect(x: statusLabel.frame.minX - 12, y: 14, width: 8, height: 8)
        let metaWidth = min(190, max(0, bounds.width - textX - rightPadding) * 0.45, metaLabel.intrinsicContentSize.width + 12)
        metaLabel.frame = NSRect(
            x: bounds.maxX - rightPadding - metaWidth,
            y: 29,
            width: metaWidth,
            height: 16
        )
        detailLabel.frame = NSRect(
            x: textX,
            y: 29,
            width: max(0, bounds.maxX - rightPadding - metaWidth - 10 - textX),
            height: 16
        )
        messagesButton.frame = NSRect(x: max(0, bounds.maxX - 54), y: 44, width: 44, height: 24)
        messageLabel.frame = NSRect(
            x: textX,
            y: 49,
            width: max(0, bounds.width - textX - rightPadding - (messagesButton.isHidden ? 0 : 50)),
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
        layer?.cornerRadius = ListPaneStyle.rowCornerRadius
        layer?.masksToBounds = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        addSubview(iconView)
        addSubview(dotView)
        addSubview(titleLabel)
        addSubview(statusLabel)
        addSubview(detailLabel)
        addSubview(metaLabel)
        addSubview(messageLabel)
        addSubview(messagesButton)
        openButton.isBordered = false
        openButton.title = ""
        openButton.setAccessibilityElement(true)
        openButton.setAccessibilityRole(.button)
        openButton.target = self
        openButton.action = #selector(openSession)
        addSubview(openButton, positioned: .below, relativeTo: dotView)
        messagesButton.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        messagesButton.imagePosition = .imageLeading
        messagesButton.bezelStyle = .rounded
        messagesButton.controlSize = .small
        messagesButton.setButtonType(.momentaryPushIn)

        for label in [titleLabel, statusLabel, detailLabel, metaLabel, messageLabel] {
            label.backgroundColor = .clear
            label.isBordered = false
            label.isEditable = false
            label.isSelectable = false
            label.lineBreakMode = .byTruncatingTail
        }
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.alignment = .right
        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        metaLabel.font = .systemFont(ofSize: 11, weight: .regular)
        metaLabel.alignment = .right
        messageLabel.font = .systemFont(ofSize: 11, weight: .regular)
        dotView.wantsLayer = true
    }

    func update(session: AgentSessionSnapshot, messageCount: Int, unreadCount: Int, showsMessagesButton: Bool) {
        self.session = session
        messagesButton.isHidden = !showsMessagesButton
        messagesButton.title = messageCount > 99 ? "99+" : String(messageCount)
        messagesButton.contentTintColor = unreadCount > 0 ? .systemOrange : ListPaneStyle.secondaryTextColor
        messagesButton.toolTip = "Messages (\(messageCount), \(unreadCount) unread)"
        messagesButton.setAccessibilityLabel("Messages for \(session.agent.displayName), \(messageCount) messages, \(unreadCount) unread")
        messagesButton.setAccessibilityTitle("Messages for \(session.agent.displayName), \(messageCount) messages, \(unreadCount) unread")
        messagesButton.setAccessibilityIdentifier("agent.messages." + session.id)
        updateContent()
        updateAppearance()
        needsLayout = true
    }

    private func updateContent() {
        iconView.image = session.agent.brandIcon?.image() ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        iconView.contentTintColor = iconView.image?.isTemplate == true ? ListPaneStyle.primaryTextColor : nil
        iconView.toolTip = session.agent.displayName
        titleLabel.stringValue = session.paneTitle
        titleLabel.toolTip = session.paneTitle
        statusLabel.stringValue = session.statusText
        detailLabel.stringValue = session.location
        detailLabel.isHidden = session.location.isEmpty
        metaLabel.stringValue = session.metaText
        let accessibleText = [session.agent.displayName, session.statusText, session.paneTitle, session.location]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        setAccessibilityLabel(accessibleText)
        openButton.setAccessibilityLabel(accessibleText)
        openButton.setAccessibilityTitle(accessibleText)
        setAccessibilityRole(.group)
        setAccessibilityElement(true)
        setAccessibilityChildren([openButton, messagesButton])
        messageLabel.toolTip = session.message
        messageLabel.stringValue = session.message ?? ""
        messageLabel.isHidden = session.message == nil
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        return sendAction(action, to: target)
    }

    @objc private func openSession() {
        _ = accessibilityPerformPress()
    }

    private func updateAppearance() {
        layer?.backgroundColor =
            isSelected
            ? ListPaneStyle.selectedRowBackgroundColor.cgColor
            : ListPaneStyle.rowBackgroundColor.cgColor
        titleLabel.textColor = ListPaneStyle.primaryTextColor
        detailLabel.textColor = ListPaneStyle.secondaryTextColor
        metaLabel.textColor = ListPaneStyle.tertiaryTextColor
        messageLabel.textColor = ListPaneStyle.tertiaryTextColor
        statusLabel.textColor = session.statusColor
        dotView.layer?.backgroundColor = session.statusColor.cgColor
    }
}

extension AgentSessionSnapshot {
    var statusText: String {
        if displayState == .sessionEnded { return "Session Ended" }
        guard backendStatusAvailable else { return "Status Unavailable" }
        let baseText =
            switch displayState {
            case .running:
                "Running"
            case .turnCompleted:
                "Turn Completed"
            case .waitingForUser:
                "Waiting for You"
            case .idle:
                "Idle"
            case .unknown:
                "Unknown"
            case .failed:
                "Error"
            case .sessionEnded:
                "Session Ended"
            }

        return isUnread && displayState == .running ? "\(baseText) · unread" : baseText
    }

    fileprivate var metaText: String {
        [
            workingDirectory.map(lastPathComponent),
            relativeTimeString(from: lastEventAt),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    fileprivate var statusColor: NSColor {
        guard backendStatusAvailable else { return ListPaneStyle.secondaryTextColor }
        return switch displayState {
        case .running:
            .systemRed
        case .waitingForUser:
            .systemOrange
        case .failed:
            .systemRed
        case .turnCompleted where isUnread:
            .systemGreen
        case .sessionEnded:
            ListPaneStyle.secondaryTextColor
        default:
            ListPaneStyle.tertiaryTextColor
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
