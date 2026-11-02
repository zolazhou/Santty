import AppKit

@MainActor
final class SidebarListPaneController: PaneControlling {
    let id: PaneID
    private let container = ListPaneHostView()
    private let workspaceView = WorkspaceListView(frame: .zero)
    var hostView: NSView { container }
    var focusTargetView: NSView { workspaceView }
    var displayTitle: String { "Workspaces" }
    var isLive: Bool { false }
    var name: String? { didSet { container.nameBadge.name = name } }
    var onFocusRequest: ((PaneID) -> Void)?
    var onTitleChange: ((PaneID) -> Void)?
    var onSelectWorkspace: ((UUID) -> Void)?
    var onCancel: (() -> Void)?

    init(id: PaneID = UUID()) {
        self.id = id
        let content = focusTargetView
        container.content = content
        container.addSubview(content, positioned: .below, relativeTo: container.nameBadge)
        container.onFocus = { [weak self] in
            guard let self else { return }
            onFocusRequest?(self.id)
        }
        workspaceView.onSelect = { [weak self] in self?.onSelectWorkspace?($0) }
        workspaceView.onCancel = { [weak self] in self?.onCancel?() }
        updateAppearance()
    }

    func update(entries: [WorkspaceEntry], selected: UUID?) {
        workspaceView.update(entries: entries, selected: selected)
    }
    func startIfNeeded() {}
    func fitToSize() { container.layoutSubtreeIfNeeded() }
    func setNameVisible(_ visible: Bool) { container.nameBadge.isRevealed = visible }
    func updatePresentation(isFocused: Bool, isFloating: Bool) {
        container.isFocused = isFocused
        container.isFloating = isFloating
        container.nameBadge.isFocused = isFocused
        updateAppearance()
    }
    func updateAppearance() {
        container.updateAppearance()
        workspaceView.updateAppearance()
    }
}

@MainActor
final class ListPaneHostView: NSView {
    private let vibrancyView = AppAppearanceDefaults.makeVibrancyView(tintViewAlpha: AppAppearanceDefaults.vibrancyTintAlpha)
    let nameBadge = PaneNameBadgeView()
    var content: NSView?
    var onFocus: (() -> Void)?
    var isFocused = false
    var isFloating = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(vibrancyView)
        addSubview(nameBadge)
    }
    convenience init() { self.init(frame: .zero) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        vibrancyView.frame = bounds
        content?.frame = bounds.insetBy(dx: 2, dy: 2)
        nameBadge.layout(in: self)
    }
    override func mouseDown(with event: NSEvent) { onFocus?() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }
    func updateAppearance() {
        vibrancyView.isHidden = !(AppAppearanceSettings.isWindowHidden || isFloating)
        vibrancyView.blendingMode = isFloating ? AppAppearanceDefaults.floatingPaneVibrancyBlendingMode : AppAppearanceDefaults.vibrancyBlendingMode
        vibrancyView.material = isFloating ? AppAppearanceDefaults.floatingPaneVibrancyMaterial : AppAppearanceDefaults.vibrancyMaterial
        let tintAlpha = isFloating ? AppAppearanceDefaults.floatingPaneVibrancyTintAlpha : AppAppearanceDefaults.vibrancyTintAlpha
        vibrancyView.subviews.first { $0.identifier == AppAppearanceDefaults.vibrancyTintIdentifier }?.layer?.backgroundColor = NSColor.black.withAlphaComponent(tintAlpha).cgColor
        layer?.cornerRadius = AppAppearanceSettings.paneCornerRadius
        layer?.borderWidth = isFocused ? AppAppearanceSettings.activePaneBorderWidth : 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = (isFocused ? AppAppearanceSettings.accentColor : NSColor.separatorColor).cgColor
            layer?.backgroundColor = NSColor.black.withAlphaComponent(AppAppearanceSettings.isWindowHidden ? 0 : 0.5).cgColor
        }
    }
}

enum ListPaneStyle {
    static let padding: CGFloat = 14
    static let rowSpacing: CGFloat = 6
    static let rowCornerRadius: CGFloat = 8
    @MainActor
    static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let rowBackgroundColor = NSColor.white.withAlphaComponent(0.06)
    @MainActor
    static var selectedRowBackgroundColor: NSColor {
        AppAppearanceSettings.accentColor.withAlphaComponent(0.30)
    }
    static let primaryTextColor = NSColor.white.withAlphaComponent(0.94)
    static let secondaryTextColor = NSColor.white.withAlphaComponent(0.62)
    static let tertiaryTextColor = NSColor.white.withAlphaComponent(0.42)
}

@MainActor
private final class WorkspaceListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = WorkspaceListTableView()
    private let scroll = NSScrollView()
    private let title = NSTextField(labelWithString: "Workspaces")
    private var entries: [WorkspaceEntry] = []
    private var selected: UUID?
    var onSelect: ((UUID) -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = ListPaneStyle.titleFont
        title.textColor = ListPaneStyle.primaryTextColor
        let column = NSTableColumn(identifier: .init("workspace"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = WorkspaceListRowView.rowHeight + ListPaneStyle.rowSpacing
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(activateSelection)
        table.onConfirm = { [weak self] in self?.activateSelection() }
        table.onCancel = { [weak self] in self?.onCancel?() }
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        addSubview(title)
        addSubview(scroll)
        setAccessibilityLabel("Workspace list")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let padding = ListPaneStyle.padding
        title.frame = NSRect(x: padding, y: 12, width: max(0, bounds.width - padding * 2), height: 22)
        let contentY = title.frame.maxY + 10
        scroll.frame = NSRect(x: padding, y: contentY, width: max(0, bounds.width - padding * 2), height: max(0, bounds.height - contentY - padding))
        table.tableColumns.first?.width = scroll.contentSize.width
    }
    func update(entries: [WorkspaceEntry], selected: UUID?) {
        let previous = self.entries.indices.contains(table.selectedRow) ? self.entries[table.selectedRow].reference : nil
        self.entries = entries
        self.selected = selected
        table.reloadData()
        let index = previous.flatMap { identity in entries.firstIndex { $0.reference == identity } }
            ?? selected.flatMap { identity in entries.firstIndex { $0.reference == identity } }
        if let index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
    }
    func updateAppearance() {
        table.enumerateAvailableRowViews { row, index in
            row.needsDisplay = true
            (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? WorkspaceListCellView)?.updateAppearance()
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        WorkspaceListCellView(entry: entries[row], isCurrent: entries[row].reference == selected)
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        WorkspaceListRowView()
    }
    @objc private func activateSelection() {
        guard entries.indices.contains(table.selectedRow) else { return }
        onSelect?(entries[table.selectedRow].reference)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        if event.keyCode == 36 { activateSelection(); return }
        let controlKey = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control ? event.charactersIgnoringModifiers : nil
        if event.keyCode == 125 || event.keyCode == 126 || controlKey == "n" || controlKey == "p" {
            guard !entries.isEmpty else { return }
            let index = min(entries.count - 1, max(0, table.selectedRow + (event.keyCode == 125 || controlKey == "n" ? 1 : -1)))
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class WorkspaceListTableView: NSTableView {
    override var isOpaque: Bool { false }
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { onConfirm?(); return }
        if event.keyCode == 53 { onCancel?(); return }
        super.keyDown(with: event)
    }
}

@MainActor
private final class WorkspaceListRowView: NSTableRowView {
    static let rowHeight: CGFloat = 52
    override var isSelected: Bool { didSet { needsDisplay = true } }

    override func drawBackground(in dirtyRect: NSRect) {
        (isSelected ? ListPaneStyle.selectedRowBackgroundColor : ListPaneStyle.rowBackgroundColor).setFill()
        let cardFrame = NSRect(x: bounds.minX, y: isFlipped ? bounds.minY : bounds.maxY - Self.rowHeight,
                               width: bounds.width, height: Self.rowHeight)
        NSBezierPath(roundedRect: cardFrame, xRadius: ListPaneStyle.rowCornerRadius, yRadius: ListPaneStyle.rowCornerRadius).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

@MainActor
private final class WorkspaceListCellView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let currentLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    override var isFlipped: Bool { true }

    init(entry: WorkspaceEntry, isCurrent: Bool) {
        super.init(frame: .zero)
        nameLabel.stringValue = entry.name
        detailLabel.stringValue = entry.detail
        currentLabel.stringValue = isCurrent ? "Current" : ""
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = ListPaneStyle.primaryTextColor
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = ListPaneStyle.secondaryTextColor
        currentLabel.font = .systemFont(ofSize: 11, weight: .medium)
        currentLabel.textColor = ListPaneStyle.secondaryTextColor
        currentLabel.alignment = .right
        for label in [nameLabel, detailLabel, currentLabel] {
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        iconView.image = entry.brandIcon?.image() ?? NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        updateAppearance()
        addSubview(iconView)
        toolTip = entry.detail + " · " + entry.name
        setAccessibilityLabel(entry.name + ", " + entry.detail + (isCurrent ? ", Current" : ""))
    }

    func updateAppearance() {
        iconView.contentTintColor = iconView.image?.isTemplate == true ? ListPaneStyle.primaryTextColor : nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 10, y: 8, width: 18, height: 18)
        let textX: CGFloat = 36
        let rightPadding: CGFloat = 10
        let currentWidth = min(150, max(0, bounds.width - textX - rightPadding) * 0.55, currentLabel.intrinsicContentSize.width + 4)
        nameLabel.frame = NSRect(x: textX, y: 8, width: max(0, bounds.width - textX - currentWidth - rightPadding - 8), height: 18)
        currentLabel.frame = NSRect(x: bounds.maxX - rightPadding - currentWidth, y: 8, width: currentWidth, height: 18)
        detailLabel.frame = NSRect(x: textX, y: 29, width: max(0, bounds.width - textX - rightPadding), height: 16)
    }
}
