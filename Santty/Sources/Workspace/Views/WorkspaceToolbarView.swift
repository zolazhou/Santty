import AppKit

@MainActor
private final class WorkspacePickerCell: NSPopUpButtonCell {
    private let arrow = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)
            .applying(.init(paletteColors: [.white])))

    override func drawBezel(withFrame frameRect: NSRect, in controlView: NSView) {
        let path = NSBezierPath(roundedRect: controlView.bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: WorkspaceTabButtonView.cornerRadius,
                                yRadius: WorkspaceTabButtonView.cornerRadius)
        NSColor.white.withAlphaComponent(isHighlighted ? 0.12 : 0.06).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1
        path.stroke()
        // AppKit normally paints the popup arrow as part of its bezel.
        guard let arrow else { return }
        let size = arrow.size
        arrow.draw(in: NSRect(x: controlView.bounds.maxX - 14 - size.width / 2,
                             y: controlView.bounds.midY - size.height / 2,
                             width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: isEnabled ? 0.82 : 0.4,
                    respectFlipped: true, hints: nil)
    }
}

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
    let workspaceSwitcher = NSPopUpButton(frame: .zero, pullsDown: false)
    private let workspaceSwitcherBackground = AppAppearanceDefaults.makeVibrancyView(
        tintViewAlpha: AppAppearanceDefaults.vibrancyTintAlpha
    )
    var onSelectWorkspace: ((String) -> Void)?
    private var selectedWorkspaceID: String?

    func updateWorkspaceEntries(_ entries: [WorkspaceEntry], selectedID: String?) {
        let changed = workspaceSwitcher.itemArray.count != entries.count || !zip(entries, workspaceSwitcher.itemArray).allSatisfy {
            $0.id == $1.representedObject as? String && $0.name == $1.title && $0.detail == $1.toolTip
        }
        // Re-selecting during popup tracking can replace the user's choice before its action arrives.
        guard changed || selectedWorkspaceID != selectedID else { return }
        if changed {
            workspaceSwitcher.removeAllItems()
            for entry in entries {
                workspaceSwitcher.addItem(withTitle: entry.name)
                workspaceSwitcher.lastItem?.representedObject = entry.id
                workspaceSwitcher.lastItem?.image = entry.brandIcon?.image(size: 16)
                    ?? NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.detail)
                workspaceSwitcher.lastItem?.toolTip = entry.detail
            }
        }
        selectedWorkspaceID = selectedID
        workspaceSwitcher.select(workspaceSwitcher.itemArray.first { $0.representedObject as? String == selectedID })
        workspaceSwitcher.isHidden = false
        workspaceSwitcher.toolTip = workspaceSwitcher.selectedItem.map { $0.title + " · " + ($0.toolTip ?? "") }
        needsLayout = true
    }

    @objc private func selectWorkspace(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        // Keep the confirmed label while the request waits or is rejected by the operation gate.
        sender.select(selectedWorkspaceID.flatMap { selected in sender.itemArray.first { $0.representedObject as? String == selected } })
        onSelectWorkspace?(id)
    }

    let agentStatusButton = WorkspaceStatusButtonView()
    private var agentCounts: (Int, Int)?

    func updateAgents(count: Int, unread: Int) {
        if let previous = agentCounts, previous.0 == count, previous.1 == unread { return }
        agentCounts = (count, unread)
        agentStatusButton.isHidden = count == 0 && unread == 0
        agentStatusButton.badgeText = unread > 0 ? (unread > 99 ? "99+" : String(unread)) : nil
        agentStatusButton.setAccessibilityLabel("Agents, \(count) sessions, \(unread) unread messages")
        agentStatusButton.toolTip = "Show Agents"
        needsLayout = true
    }

    private let statusStackView = WorkspaceToolbarStackView()
    private let navigationStatus = NSTextField(labelWithString: "")

    func showNavigationStatus(_ text: String?) {
        if navigationStatus.superview == nil {
            navigationStatus.font = .systemFont(ofSize: 12)
            navigationStatus.textColor = .secondaryLabelColor
            navigationStatus.lineBreakMode = .byTruncatingTail
            navigationStatus.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
            navigationStatus.setAccessibilityLabel("Navigation status")
            statusStackView.addArrangedSubview(navigationStatus)
        }
        navigationStatus.stringValue = text ?? ""
        navigationStatus.toolTip = text
        navigationStatus.isHidden = text == nil
        needsLayout = true
    }
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

        let switcherWidth = workspaceSwitcher.isHidden ? 0 : min(200, workspaceSwitcher.fittingSize.width)
        workspaceSwitcher.frame = NSRect(
            x: bounds.minX,
            y: centeredY,
            width: switcherWidth,
            height: toolbarHeight
        )
        workspaceSwitcherBackground.frame = workspaceSwitcher.frame
        let tabX = bounds.minX + switcherWidth + (switcherWidth > 0 ? spacing : 0)
        let tabWidth = max(0, statusX - tabX - (statusWidth > 0 ? spacing : 0))
        tabStripView.frame = NSRect(
            x: tabX,
            y: bounds.minY,
            width: tabWidth,
            height: bounds.height
        )
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

        needsLayout = true
    }

    func updateAppearance() {
        workspaceSwitcherBackground.isHidden = !AppAppearanceSettings.isWindowHidden
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
        agentStatusButton.title = "Agents"
        agentStatusButton.symbolName = "sparkles"
        agentStatusButton.isHidden = true
        statusStackView.addArrangedSubview(agentStatusButton)

        workspaceSwitcher.cell = WorkspacePickerCell(textCell: "", pullsDown: false)
        addSubview(workspaceSwitcher)
        workspaceSwitcherBackground.wantsLayer = true
        workspaceSwitcherBackground.layer?.cornerRadius = WorkspaceTabButtonView.cornerRadius
        workspaceSwitcherBackground.layer?.masksToBounds = true
        addSubview(workspaceSwitcherBackground, positioned: .below, relativeTo: workspaceSwitcher)
        workspaceSwitcherBackground.isHidden = !AppAppearanceSettings.isWindowHidden
        workspaceSwitcher.controlSize = .regular
        workspaceSwitcher.bezelStyle = .roundRect
        workspaceSwitcher.heightAnchor.constraint(equalToConstant: toolbarHeight).isActive = true
        workspaceSwitcher.cell?.lineBreakMode = .byTruncatingTail
        workspaceSwitcher.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        workspaceSwitcher.font = .systemFont(ofSize: 12, weight: .medium)
        workspaceSwitcher.setAccessibilityLabel("Workspace")
        workspaceSwitcher.target = self
        workspaceSwitcher.action = #selector(selectWorkspace(_:))

    }

}
