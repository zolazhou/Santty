import AppKit

@MainActor
final class SidebarListPaneController: PaneControlling {
    let id: PaneID
    private let container = SidebarListHostView()
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
        container.nameBadge.isFocused = isFocused
        updateAppearance()
    }
    func updateAppearance() { container.updateAppearance() }
}

@MainActor
private final class SidebarListHostView: NSView {
    let nameBadge = PaneNameBadgeView()
    var content: NSView?
    var onFocus: (() -> Void)?
    var isFocused = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(nameBadge)
    }
    convenience init() { self.init(frame: .zero) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        content?.frame = bounds.insetBy(dx: 2, dy: 2)
        nameBadge.layout(in: self)
    }
    override func mouseDown(with event: NSEvent) { onFocus?() }
    func updateAppearance() {
        layer?.cornerRadius = AppAppearanceSettings.paneCornerRadius
        layer?.borderWidth = isFocused ? AppAppearanceSettings.activePaneBorderWidth : 1
        layer?.borderColor = (isFocused ? AppAppearanceSettings.accentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("workspace"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 32
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(activateSelection)
        table.onConfirm = { [weak self] in self?.activateSelection() }
        table.onCancel = { [weak self] in self?.onCancel?() }
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
        title.frame = NSRect(x: 14, y: max(0, bounds.height - 36), width: max(0, bounds.width - 28), height: 22)
        scroll.frame = NSRect(x: 8, y: 8, width: max(0, bounds.width - 16), height: max(0, bounds.height - 48))
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
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let label = NSTextField(labelWithString: (entry.reference == selected ? "● " : "") + entry.name)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = entry.name
        label.textColor = .labelColor
        label.setAccessibilityLabel(entry.name)
        return label
    }
    @objc private func activateSelection() {
        guard entries.indices.contains(table.selectedRow) else { return }
        onSelect?(entries[table.selectedRow].reference)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        if event.keyCode == 36 { activateSelection(); return }
        if event.keyCode == 125 || event.keyCode == 126 {
            guard !entries.isEmpty else { return }
            let index = min(entries.count - 1, max(0, table.selectedRow + (event.keyCode == 125 ? 1 : -1)))
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class WorkspaceListTableView: NSTableView {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { onConfirm?(); return }
        if event.keyCode == 53 { onCancel?(); return }
        super.keyDown(with: event)
    }
}
