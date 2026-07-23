import AppKit
import SwiftUI

@MainActor
final class CommandPaletteView: NSView {
    var onDismiss: (() -> Void)?
    var onPerformCommand: ((AppCommand) -> Void)?

    private var commands: [AppCommand]
    private var filteredCommands: [AppCommand] = []
    private var selectedIndex: Int?

    private let panelView = NSView()
    private let vibrancyView = AppAppearanceDefaults.makeVibrancyView()
    private let searchContainerView = CommandPaletteSearchContainerView()
    private let scrollView = NSScrollView()
    private let tableView = CommandPaletteTableView()
    private let tableColumn = NSTableColumn(identifier: .commandPaletteCommand)
    private let searchField = NSTextField()

    let preferredContentSize = NSSize(width: 620, height: 420)

    private let searchHeight: CGFloat = 56
    private let rowHeight: CGFloat = 44
    private let contentInset: CGFloat = 8

    override var acceptsFirstResponder: Bool {
        true
    }

    init(commands: [AppCommand] = [], searchQuery: String = "") {
        self.commands = commands
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        configurePanel()
        configureSearchContainer()
        configureSearchField()
        configureTableView()
        configureConstraints()
        searchField.stringValue = searchQuery
        applyFilter()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(searchField)
    }

    override func layout() {
        super.layout()
        tableColumn.width = scrollView.contentSize.width
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    func updateCommands(_ commands: [AppCommand], resetSearch: Bool) {
        self.commands = commands
        if resetSearch {
            searchField.stringValue = ""
        }
        applyFilter()
    }

    private func configureSearchField() {
        searchField.cell = CommandPaletteSearchFieldCell(textCell: "")
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search for commands...",
            attributes: [
                .foregroundColor: CommandPaletteColors.placeholderText,
                .font: NSFont.systemFont(ofSize: 26, weight: .regular),
            ]
        )
        searchField.font = .systemFont(ofSize: 26, weight: .regular)
        searchField.textColor = CommandPaletteColors.primaryText
        searchField.focusRingType = .none
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.drawsBackground = false
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureSearchContainer() {
        searchContainerView.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(searchContainerView)

        searchContainerView.contentView.addSubview(searchField)
    }

    private func configurePanel() {
        panelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panelView)

        vibrancyView.translatesAutoresizingMaskIntoConstraints = false
        vibrancyView.material = .popover
        vibrancyView.blendingMode = .behindWindow
        panelView.addSubview(vibrancyView)
    }

    private func configureTableView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: searchHeight,
            left: 0,
            bottom: 0,
            right: 0
        )
        scrollView.documentView = tableView
        panelView.addSubview(scrollView, positioned: .below, relativeTo: searchContainerView)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.enclosingScrollView?.drawsBackground = false
        tableView.headerView = nil
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.dataSource = self
        tableView.delegate = self
        tableColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(tableColumn)
        tableView.onPressRow = { [weak self] row in
            self?.performCommand(at: row)
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: preferredContentSize.width),
            heightAnchor.constraint(equalToConstant: preferredContentSize.height),

            panelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            panelView.trailingAnchor.constraint(equalTo: trailingAnchor),
            panelView.topAnchor.constraint(equalTo: topAnchor),
            panelView.bottomAnchor.constraint(equalTo: bottomAnchor),

            vibrancyView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            vibrancyView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            vibrancyView.topAnchor.constraint(equalTo: panelView.topAnchor),
            vibrancyView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),

            searchContainerView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            searchContainerView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            searchContainerView.topAnchor.constraint(equalTo: panelView.topAnchor),
            searchContainerView.heightAnchor.constraint(equalToConstant: searchHeight),

            searchField.leadingAnchor.constraint(
                equalTo: searchContainerView.contentView.leadingAnchor,
                constant: 18
            ),
            searchField.trailingAnchor.constraint(
                equalTo: searchContainerView.contentView.trailingAnchor,
                constant: -18
            ),
            searchField.centerYAnchor.constraint(
                equalTo: searchContainerView.contentView.centerYAnchor
            ),
            searchField.heightAnchor.constraint(equalToConstant: 44),

            scrollView.leadingAnchor.constraint(
                equalTo: panelView.leadingAnchor,
                constant: contentInset
            ),
            scrollView.trailingAnchor.constraint(
                equalTo: panelView.trailingAnchor,
                constant: -contentInset
            ),
            scrollView.topAnchor.constraint(
                equalTo: panelView.topAnchor,
                constant: contentInset
            ),
            scrollView.bottomAnchor.constraint(
                equalTo: panelView.bottomAnchor,
                constant: -contentInset
            ),

            tableView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])
    }

    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch CommandPaletteKeyAction(event: event) {
        case .confirm:
            performSelectedCommand()
        case .cancel:
            onDismiss?()
        case .moveSelection(let direction):
            moveSelection(by: direction)
        case nil:
            return false
        }

        return true
    }

    private func applyFilter() {
        filteredCommands = commands.filter {
            $0.isEnabled
                && CommandPaletteFilter.matches(query: searchField.stringValue, title: $0.title)
        }
        selectedIndex = filteredCommands.firstIndex(where: \.isEnabled)
        tableView.reloadData()
        updateTableSelection()
    }

    private func moveSelection(by direction: Int) {
        let enabledIndices = filteredCommands.indices.filter { filteredCommands[$0].isEnabled }
        guard !enabledIndices.isEmpty else {
            selectedIndex = nil
            updateTableSelection()
            return
        }

        guard let selectedIndex,
            let currentEnabledPosition = enabledIndices.firstIndex(of: selectedIndex)
        else {
            self.selectedIndex = enabledIndices.first
            updateTableSelection()
            return
        }

        let nextPosition =
            (currentEnabledPosition + direction + enabledIndices.count) % enabledIndices.count
        self.selectedIndex = enabledIndices[nextPosition]
        updateTableSelection()
        tableView.scrollRowToVisible(enabledIndices[nextPosition])
    }

    private func updateTableSelection() {
        guard let selectedIndex else {
            tableView.deselectAll(nil)
            return
        }

        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
    }

    private func performSelectedCommand() {
        guard let selectedIndex else {
            return
        }

        performCommand(at: selectedIndex)
    }

    private func performCommand(at row: Int) {
        guard filteredCommands.indices.contains(row) else {
            return
        }

        performCommand(filteredCommands[row])
    }

    private func performCommand(_ command: AppCommand) {
        guard command.isEnabled else {
            NSSound.beep()
            return
        }

        onPerformCommand?(command)
    }

}

extension CommandPaletteView: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === searchField else {
            return
        }

        applyFilter()
    }
}

extension CommandPaletteView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        guard tableView === self.tableView else {
            return 0
        }

        return filteredCommands.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard tableView === self.tableView,
            tableColumn?.identifier == .commandPaletteCommand,
            filteredCommands.indices.contains(row)
        else {
            return nil
        }

        let cellView =
            tableView.makeView(
                withIdentifier: .commandPaletteCommandCell,
                owner: self
            ) as? CommandPaletteCellView
            ?? CommandPaletteCellView()
        cellView.identifier = .commandPaletteCommandCell
        cellView.command = filteredCommands[row]
        return cellView
    }

    func tableView(
        _ tableView: NSTableView,
        rowViewForRow row: Int
    ) -> NSTableRowView? {
        guard tableView === self.tableView,
            filteredCommands.indices.contains(row)
        else {
            return nil
        }

        return CommandPaletteRowView()
    }

    func tableView(
        _ tableView: NSTableView,
        shouldSelectRow row: Int
    ) -> Bool {
        guard tableView === self.tableView,
            filteredCommands.indices.contains(row)
        else {
            return false
        }

        return filteredCommands[row].isEnabled
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === tableView else {
            return
        }

        let selectedRow = tableView.selectedRow
        selectedIndex = selectedRow >= 0 ? selectedRow : nil
    }
}

private enum CommandPaletteColors {
    static let rowSelected = NSColor.white.withAlphaComponent(0.18)
    static let rowSelectedBorder = NSColor.white.withAlphaComponent(0.12)
    static let iconBackground = NSColor(calibratedRed: 0.13, green: 0.18, blue: 0.18, alpha: 1)
    static let iconBorder = NSColor.white.withAlphaComponent(0.12)
    static let primaryText = NSColor.white.withAlphaComponent(0.94)
    static let secondaryText = NSColor.white.withAlphaComponent(0.56)
    static let placeholderText = NSColor.white.withAlphaComponent(0.42)
}

enum CommandPaletteKeyAction: Equatable {
    case cancel
    case confirm
    case moveSelection(Int)

    init?(event: NSEvent) {
        switch event.keyCode {
        case 36:
            self = .confirm
            return
        case 53:
            self = .cancel
            return
        case 125:
            self = .moveSelection(1)
            return
        case 126:
            self = .moveSelection(-1)
            return
        default:
            break
        }

        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifierFlags.contains(.control),
            modifierFlags.intersection([.command, .option]).isEmpty
        else {
            return nil
        }

        switch event.keyCode {
        case 45:
            self = .moveSelection(1)
        case 35:
            self = .moveSelection(-1)
        default:
            return nil
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let commandPaletteCommand = NSUserInterfaceItemIdentifier("command")
    fileprivate static let commandPaletteCommandCell = NSUserInterfaceItemIdentifier(
        "commandPaletteCommandCell")
}

@MainActor
private final class CommandPaletteSearchContainerView: NSView {
    let contentView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureEffectView()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    private func configureEffectView() {
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let vibrancyView = NSVisualEffectView()
        vibrancyView.translatesAutoresizingMaskIntoConstraints = false
        vibrancyView.material = .popover
        vibrancyView.blendingMode = .behindWindow
        vibrancyView.state = .active
        vibrancyView.appearance = NSAppearance(named: .darkAqua)

        addSubview(vibrancyView)
        pin(vibrancyView, to: self)

        addSubview(contentView)
        pin(contentView, to: self)
    }

    private func pin(_ childView: NSView, to parentView: NSView) {
        NSLayoutConstraint.activate([
            childView.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
            childView.topAnchor.constraint(equalTo: parentView.topAnchor),
            childView.bottomAnchor.constraint(equalTo: parentView.bottomAnchor),
        ])
    }
}

private final class CommandPaletteSearchFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredTextRect(forBounds: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: centeredTextRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: centeredTextRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }

    private func centeredTextRect(forBounds rect: NSRect) -> NSRect {
        var textRect = super.drawingRect(forBounds: rect)
        let textHeight = cellSize(forBounds: rect).height
        textRect.origin.y = rect.origin.y + max(0, (rect.height - textHeight) / 2)
        textRect.size.height = min(textHeight, rect.height)
        return textRect
    }
}

@MainActor
private final class CommandPaletteTableView: NSTableView {
    var onPressRow: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0 else {
            super.mouseDown(with: event)
            return
        }

        selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        onPressRow?(clickedRow)
    }
}

@MainActor
private final class CommandPaletteRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            needsDisplay = true
        }
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else {
            return
        }

        let selectionRect = bounds.insetBy(dx: 0, dy: 2)
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: 12, yRadius: 12)
        CommandPaletteColors.rowSelected.setFill()
        path.fill()
        CommandPaletteColors.rowSelectedBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

@MainActor
private final class CommandPaletteCellView: NSTableCellView {
    var command: AppCommand? {
        didSet {
            updateContent()
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let categoryLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let iconContainerView = NSView()
    private let iconView = NSImageView()
    private var shortcutWidthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        iconContainerView.translatesAutoresizingMaskIntoConstraints = false
        iconContainerView.wantsLayer = true
        iconContainerView.layer?.cornerRadius = 8
        iconContainerView.layer?.backgroundColor = CommandPaletteColors.iconBackground.cgColor
        iconContainerView.layer?.borderWidth = 1
        iconContainerView.layer?.borderColor = CommandPaletteColors.iconBorder.cgColor
        addSubview(iconContainerView)

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        iconView.contentTintColor = CommandPaletteColors.primaryText
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainerView.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.backgroundColor = .clear
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        categoryLabel.font = .systemFont(ofSize: 12, weight: .regular)
        categoryLabel.lineBreakMode = .byTruncatingTail
        categoryLabel.backgroundColor = .clear
        categoryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(categoryLabel)

        shortcutLabel.font = .systemFont(ofSize: 13, weight: .medium)
        shortcutLabel.alignment = .right
        shortcutLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.backgroundColor = .clear
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutLabel)

        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    private func updateContent() {
        titleLabel.stringValue = command?.title ?? ""
        categoryLabel.stringValue = command.map(Self.categoryTitle(for:)) ?? ""
        shortcutLabel.stringValue = command?.shortcut ?? Self.kindTitle(for: command)
        iconView.image =
            command.map(Self.icon(for:))
            ?? NSImage(systemSymbolName: "command", accessibilityDescription: nil)
        shortcutWidthConstraint?.constant = command?.shortcut == nil ? 138 : 176
        alphaValue = command?.isEnabled == false ? 0.45 : 1
        titleLabel.textColor = CommandPaletteColors.primaryText
        categoryLabel.textColor = CommandPaletteColors.secondaryText
        shortcutLabel.textColor = CommandPaletteColors.secondaryText
    }

    private static func categoryTitle(for command: AppCommand) -> String {
        switch command.id.split(separator: ".").first {
        case "pane":
            return "Pane Management"
        case "tab":
            return "Tabs"
        case "window":
            return "Window Management"
        default:
            return "Command"
        }
    }

    private static func kindTitle(for command: AppCommand?) -> String {
        guard command != nil else {
            return ""
        }

        return "Command"
    }

    private static func icon(for command: AppCommand) -> NSImage? {
        let symbolName: String
        switch command.id.split(separator: ".").first {
        case "pane":
            symbolName = "rectangle.split.2x1"
        case "tab":
            symbolName = "rectangle.on.rectangle"
        case "window":
            symbolName = "macwindow"
        default:
            symbolName = "command"
        }

        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    private func configureConstraints() {
        let shortcutWidthConstraint = shortcutLabel.widthAnchor.constraint(equalToConstant: 138)
        self.shortcutWidthConstraint = shortcutWidthConstraint

        NSLayoutConstraint.activate([
            iconContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconContainerView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconContainerView.widthAnchor.constraint(equalToConstant: 28),
            iconContainerView.heightAnchor.constraint(equalToConstant: 28),

            iconView.centerXAnchor.constraint(equalTo: iconContainerView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainerView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.heightAnchor.constraint(equalToConstant: 24),
            shortcutWidthConstraint,

            titleLabel.leadingAnchor.constraint(
                equalTo: iconContainerView.trailingAnchor,
                constant: 12
            ),
            titleLabel.trailingAnchor.constraint(
                equalTo: shortcutLabel.leadingAnchor,
                constant: -16
            ),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.heightAnchor.constraint(equalToConstant: 18),

            categoryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            categoryLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            categoryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor),
            categoryLabel.heightAnchor.constraint(equalToConstant: 14),
        ])
    }
}

#Preview("Command Palette") {
    CommandPaletteViewPreview()
        .frame(width: 860, height: 540)
}

@MainActor
private struct CommandPaletteViewPreview: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = CommandPaletteView(
            commands: Self.commands,
            searchQuery: "split"
        )
        view.translatesAutoresizingMaskIntoConstraints = false

        let containerView = CommandPalettePreviewContainerView()
        containerView.addSubview(view)

        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
        ])

        return containerView
    }

    func updateNSView(_: NSView, context _: Context) {}

    private static let commands: [AppCommand] = [
        AppCommand(
            id: "pane.splitHorizontal",
            title: "Split Horizontally",
            shortcut: "⇧⌘\\",
            isEnabled: true
        ) {},
        AppCommand(
            id: "pane.splitVertical",
            title: "Split Vertically",
            shortcut: "⇧⌘-",
            isEnabled: true
        ) {},
        AppCommand(
            id: "pane.equalizeSplits",
            title: "Equalize Splits",
            shortcut: "⇧⌘=",
            isEnabled: false
        ) {},
        AppCommand(
            id: "pane.focusNext",
            title: "Focus Next Pane",
            shortcut: "⌘]",
            isEnabled: true
        ) {},
        AppCommand(
            id: "tab.new",
            title: "New Tab",
            shortcut: "⌘T",
            isEnabled: true
        ) {},
        AppCommand(
            id: "window.close",
            title: "Close Window",
            shortcut: "⌘W",
            isEnabled: true
        ) {},
    ]
}

@MainActor
private final class CommandPalettePreviewContainerView: NSView {
    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.28, alpha: 1),
            NSColor(calibratedRed: 0.52, green: 0.17, blue: 0.34, alpha: 1),
            NSColor(calibratedRed: 0.10, green: 0.34, blue: 0.30, alpha: 1),
        ])
        gradient?.draw(in: bounds, angle: 32)
    }
}
