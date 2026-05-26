import AppKit

@MainActor
final class CommandPaletteView: NSView {
    var onDismiss: (() -> Void)?
    var onPerformCommand: ((AppCommand) -> Void)?

    private var commands: [AppCommand]
    private var filteredCommands: [AppCommand] = []
    private var selectedIndex: Int?

    private let panelView = NSView()
    private let vibrancyView = AppAppearanceDefaults.makeVibrancyView(
        tintViewAlpha: AppAppearanceDefaults.vibrancyTintAlpha
    )
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let rowsContainerView = NSView()
    private var rowViews: [CommandPaletteRowView] = []

    let preferredContentSize = NSSize(width: 560, height: 420)

    private let searchHeight: CGFloat = 42
    private let rowHeight: CGFloat = 38
    private let contentInset: CGFloat = 10

    override var acceptsFirstResponder: Bool {
        true
    }

    init(commands: [AppCommand] = []) {
        self.commands = commands
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        configurePanel()
        configureSearchField()
        configureScrollView()
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

        panelView.frame = bounds

        vibrancyView.frame = panelView.bounds

        searchField.frame = NSRect(
            x: contentInset,
            y: panelView.bounds.height - contentInset - searchHeight,
            width: max(0, panelView.bounds.width - contentInset * 2),
            height: searchHeight
        )

        scrollView.frame = NSRect(
            x: contentInset,
            y: contentInset,
            width: max(0, panelView.bounds.width - contentInset * 2),
            height: max(0, searchField.frame.minY - contentInset * 2)
        )
        layoutRows()
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

    private func configurePanel() {
        panelView.wantsLayer = true
        panelView.layer?.cornerRadius = 8
        panelView.layer?.masksToBounds = true
        panelView.layer?.borderWidth = 1
        panelView.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        addSubview(panelView)

        panelView.addSubview(vibrancyView)
    }

    private func configureSearchField() {
        searchField.placeholderString = "Search commands"
        searchField.font = .systemFont(ofSize: 16, weight: .regular)
        searchField.focusRingType = .none
        searchField.bezelStyle = .roundedBezel
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchFieldChanged)
        panelView.addSubview(searchField)
    }

    private func configureScrollView() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = rowsContainerView
        panelView.addSubview(scrollView)
    }

    @objc private func searchFieldChanged() {
        applyFilter()
    }

    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch CommandPaletteKeyAction(event: event) {
        case .confirm:
            performSelectedCommand()
        case .cancel:
            onDismiss?()
        case let .moveSelection(direction):
            moveSelection(by: direction)
        case nil:
            return false
        }

        return true
    }

    private func applyFilter() {
        filteredCommands = commands.filter {
            CommandPaletteFilter.matches(query: searchField.stringValue, title: $0.title)
        }
        selectedIndex = filteredCommands.firstIndex(where: \.isEnabled)
        rebuildRows()
        needsLayout = true
    }

    private func rebuildRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = filteredCommands.enumerated().map { index, command in
            let rowView = CommandPaletteRowView()
            rowView.command = command
            rowView.isSelected = index == selectedIndex
            rowView.onPress = { [weak self] row in
                self?.performCommand(row.command)
            }
            rowsContainerView.addSubview(rowView)
            return rowView
        }
        layoutRows()
    }

    private func layoutRows() {
        let contentHeight = CGFloat(filteredCommands.count) * rowHeight
        rowsContainerView.frame = NSRect(
            x: 0,
            y: 0,
            width: scrollView.contentSize.width,
            height: max(scrollView.contentSize.height, contentHeight)
        )

        for (index, rowView) in rowViews.enumerated() {
            rowView.frame = NSRect(
                x: 0,
                y: rowsContainerView.bounds.height - CGFloat(index + 1) * rowHeight,
                width: rowsContainerView.bounds.width,
                height: rowHeight
            )
        }
    }

    private func moveSelection(by direction: Int) {
        let enabledIndices = filteredCommands.indices.filter { filteredCommands[$0].isEnabled }
        guard !enabledIndices.isEmpty else {
            selectedIndex = nil
            updateRowSelection()
            return
        }

        guard let selectedIndex, let currentEnabledPosition = enabledIndices.firstIndex(of: selectedIndex) else {
            self.selectedIndex = enabledIndices.first
            updateRowSelection()
            return
        }

        let nextPosition = (currentEnabledPosition + direction + enabledIndices.count) % enabledIndices.count
        self.selectedIndex = enabledIndices[nextPosition]
        updateRowSelection()
        scrollSelectedRowToVisible()
    }

    private func updateRowSelection() {
        for (index, rowView) in rowViews.enumerated() {
            rowView.isSelected = index == selectedIndex
        }
    }

    private func scrollSelectedRowToVisible() {
        guard let selectedIndex, rowViews.indices.contains(selectedIndex) else {
            return
        }

        rowViews[selectedIndex].scrollToVisible(rowViews[selectedIndex].bounds)
    }

    private func performSelectedCommand() {
        guard let selectedIndex, filteredCommands.indices.contains(selectedIndex) else {
            return
        }

        performCommand(filteredCommands[selectedIndex])
    }

    private func performCommand(_ command: AppCommand?) {
        guard let command, command.isEnabled else {
            NSSound.beep()
            return
        }

        onPerformCommand?(command)
    }
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

@MainActor
private final class CommandPaletteRowView: NSControl {
    var command: AppCommand? {
        didSet {
            updateContent()
        }
    }

    var isSelected = false {
        didSet {
            updateSelection()
        }
    }

    var onPress: ((CommandPaletteRowView) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.backgroundColor = .clear
        addSubview(titleLabel)

        shortcutLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        shortcutLabel.alignment = .right
        shortcutLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.backgroundColor = .clear
        addSubview(shortcutLabel)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()

        let shortcutWidth: CGFloat = command?.shortcut == nil ? 0 : 128
        shortcutLabel.frame = NSRect(
            x: bounds.maxX - shortcutWidth - 12,
            y: 0,
            width: shortcutWidth,
            height: bounds.height
        )
        titleLabel.frame = NSRect(
            x: 12,
            y: 0,
            width: max(0, bounds.width - shortcutWidth - 28),
            height: bounds.height
        )
    }

    override func mouseDown(with _: NSEvent) {
        onPress?(self)
    }

    private func updateContent() {
        titleLabel.stringValue = command?.title ?? ""
        shortcutLabel.stringValue = command?.shortcut ?? ""
        alphaValue = command?.isEnabled == false ? 0.45 : 1
        updateSelection()
        needsLayout = true
    }

    private func updateSelection() {
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            : NSColor.clear.cgColor
        titleLabel.textColor = isSelected ? .white : .white.withAlphaComponent(0.9)
        shortcutLabel.textColor = isSelected ? .white.withAlphaComponent(0.88) : .white.withAlphaComponent(0.48)
    }
}
