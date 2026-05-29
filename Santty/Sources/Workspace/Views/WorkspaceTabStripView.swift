import AppKit

@MainActor
private final class WorkspaceTabCollectionView: NSCollectionView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard indexPathForItem(at: location) == nil else {
            super.mouseDown(with: event)
            return
        }

        window?.performDrag(with: event)
    }
}

struct WorkspaceTabStripItem: Equatable {
    let id: UUID
    let title: String
    let isSelected: Bool
}

@MainActor
final class WorkspaceTabStripView: NSView {
    var items: [WorkspaceTabStripItem] = [] {
        didSet {
            guard items != oldValue else {
                return
            }

            reloadTabs(previousItems: oldValue)
            needsLayout = true
        }
    }

    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onMoveTab: ((UUID, Int) -> Void)?

    private let collectionView = WorkspaceTabCollectionView()
    private let collectionLayout = NSCollectionViewFlowLayout()
    private var tabButtons: [UUID: WorkspaceTabButtonView] = [:]
    nonisolated private static let tabPasteboardType = NSPasteboard.PasteboardType(
        "dev.zola.Santty.workspace-tab"
    )

    private let tabSpacing: CGFloat = 6
    private let tabHeight: CGFloat = 32
    private let minimumTabWidth: CGFloat = 60
    private let maximumTabWidth: CGFloat = 220
    private let newTabButtonWidth: CGFloat = 28

    override var isFlipped: Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureCollectionView()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()

        let collectionY = max(0, (bounds.height - tabHeight) / 2)
        collectionView.frame = NSRect(
            x: bounds.minX,
            y: collectionY,
            width: bounds.width,
            height: tabHeight
        )
        collectionLayout.invalidateLayout()
    }

    private func configureCollectionView() {
        collectionLayout.scrollDirection = .horizontal
        collectionLayout.minimumInteritemSpacing = tabSpacing
        collectionLayout.minimumLineSpacing = tabSpacing
        collectionLayout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        collectionView.collectionViewLayout = collectionLayout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            WorkspaceTabCollectionViewItem.self,
            forItemWithIdentifier: WorkspaceTabCollectionViewItem.identifier
        )
        collectionView.registerForDraggedTypes([Self.tabPasteboardType])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)

        addSubview(collectionView)
    }

    private func reloadTabs(previousItems: [WorkspaceTabStripItem]) {
        tabButtons = tabButtons.filter { tabID, _ in items.contains { $0.id == tabID } }

        guard
            previousItems.count == items.count,
            let movedTabID = movedTabID(from: previousItems, to: items),
            let sourceIndex = previousItems.firstIndex(where: { $0.id == movedTabID }),
            let destinationIndex = items.firstIndex(where: { $0.id == movedTabID })
        else {
            collectionView.reloadData()
            collectionLayout.invalidateLayout()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            collectionView.animator().moveItem(
                at: IndexPath(item: sourceIndex, section: 0),
                to: IndexPath(item: destinationIndex, section: 0)
            )
            reconfigureVisibleTabButtons()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.reconfigureVisibleTabButtons()
            }
        }
    }

    private func movedTabID(
        from previousItems: [WorkspaceTabStripItem],
        to newItems: [WorkspaceTabStripItem]
    ) -> UUID? {
        let previousIDs = previousItems.map(\.id)
        let newIDs = newItems.map(\.id)
        guard Set(previousIDs) == Set(newIDs), previousIDs != newIDs else {
            return nil
        }

        for tabID in previousIDs {
            var previousWithoutCandidate = previousIDs
            previousWithoutCandidate.removeAll { $0 == tabID }

            var newWithoutCandidate = newIDs
            newWithoutCandidate.removeAll { $0 == tabID }

            if previousWithoutCandidate == newWithoutCandidate {
                return tabID
            }
        }

        return nil
    }

    private func configure(
        _ tabButton: WorkspaceTabButtonView,
        with item: WorkspaceTabStripItem,
        at index: Int
    ) {
        tabButton.title = item.title
        tabButton.index = index + 1
        tabButton.isSelected = item.isSelected
        tabButton.minimumWidth = minimumTabWidth
        tabButton.maximumWidth = maximumTabWidth
        tabButton.fixedWidth = nil
        tabButton.showsCloseButton = true
        tabButton.forwardsMouseDownToResponderChain = true
        tabButton.titleFont = .systemFont(ofSize: 12, weight: .medium)
        tabButton.titleAlignment = .left
        tabButton.contentInset = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        tabButton.target = self
        tabButton.action = #selector(handleTabButton(_:))
        tabButton.onClose = { [weak self] in
            self?.onCloseTab?(item.id)
        }
        tabButton.updateAppearance()
        tabButtons = tabButtons.filter { $0.value !== tabButton }
    }

    private func reconfigureVisibleTabButtons() {
        for case let collectionItem as WorkspaceTabCollectionViewItem in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: collectionItem) else {
                continue
            }

            if indexPath.item == items.count {
                configureNewTabButton(collectionItem.tabButton)
                continue
            }

            let item = items[indexPath.item]
            configure(collectionItem.tabButton, with: item, at: indexPath.item)
            tabButtons[item.id] = collectionItem.tabButton
        }
    }

    private func width(for item: WorkspaceTabStripItem) -> CGFloat {
        let titleWidth = item.title.size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        ).width
        let indexWidth: CGFloat = 18
        let width = 10 + titleWidth + 8 + indexWidth + 10
        return min(max(ceil(width), minimumTabWidth), maximumTabWidth)
    }

    private func configureNewTabButton(_ tabButton: WorkspaceTabButtonView) {
        tabButton.title = "+"
        tabButton.index = nil
        tabButton.isSelected = false
        tabButton.minimumWidth = newTabButtonWidth
        tabButton.maximumWidth = newTabButtonWidth
        tabButton.fixedWidth = newTabButtonWidth
        tabButton.forwardsMouseDownToResponderChain = false
        tabButton.titleFont = .systemFont(ofSize: 15, weight: .medium)
        tabButton.titleAlignment = .center
        tabButton.contentInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tabButton.showsCloseButton = false
        tabButton.target = self
        tabButton.action = #selector(handleNewTabButton)
        tabButton.onClose = nil
        tabButton.updateAppearance()
        tabButtons = tabButtons.filter { $0.value !== tabButton }
    }

    @objc private func handleTabButton(_ sender: WorkspaceTabButtonView) {
        guard let tabID = tabButtons.first(where: { $0.value === sender })?.key else {
            return
        }

        onSelectTab?(tabID)
    }

    @objc private func handleNewTabButton() {
        onNewTab?()
    }

    func debugSelectedTabBackgroundColor(for id: UUID) -> NSColor? {
        tabButtons[id]?.debugSelectedBackgroundColor
    }

    func debugSelectedTabBackground(for id: UUID) -> AppAppearanceSettings.ActiveTabBackground? {
        tabButtons[id]?.debugSelectedBackground
    }

    func debugTabUsesHiddenWindowPresentation(for id: UUID) -> Bool? {
        tabButtons[id]?.debugUsesHiddenWindowPresentation
    }

    func debugTabIndexText(for id: UUID) -> String? {
        if let index = items.firstIndex(where: { $0.id == id }) {
            return String(index + 1)
        }

        return tabButtons[id]?.debugIndexText
    }

    func debugTabCloseButtonIsHidden(for id: UUID) -> Bool? {
        tabButtons[id]?.debugCloseButtonIsHidden
    }

    func updateAppearance() {
        for button in tabButtons.values {
            button.updateAppearance()
        }
        collectionView.reloadData()
    }
}

extension WorkspaceTabStripView: NSCollectionViewDataSource {
    func collectionView(
        _: NSCollectionView,
        numberOfItemsInSection _: Int
    ) -> Int {
        items.count + 1
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let collectionItem = collectionView.makeItem(
            withIdentifier: WorkspaceTabCollectionViewItem.identifier,
            for: indexPath
        ) as! WorkspaceTabCollectionViewItem

        guard indexPath.item < items.count else {
            configureNewTabButton(collectionItem.tabButton)
            return collectionItem
        }

        let item = items[indexPath.item]
        configure(collectionItem.tabButton, with: item, at: indexPath.item)
        tabButtons[item.id] = collectionItem.tabButton
        return collectionItem
    }
}

extension WorkspaceTabStripView: NSCollectionViewDelegateFlowLayout {
    func collectionView(
        _: NSCollectionView,
        layout _: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        guard indexPath.item < items.count else {
            return NSSize(width: newTabButtonWidth, height: tabHeight)
        }

        return NSSize(width: width(for: items[indexPath.item]), height: tabHeight)
    }
}

extension WorkspaceTabStripView: NSCollectionViewDelegate {
    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard let indexPath = indexPaths.first else {
            return
        }

        if indexPath.item == items.count {
            onNewTab?()
        } else if items.indices.contains(indexPath.item) {
            onSelectTab?(items[indexPath.item].id)
        }
        collectionView.deselectItems(at: indexPaths)
    }

    func collectionView(
        _: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> NSPasteboardWriting? {
        guard indexPath.item < items.count else {
            return nil
        }

        let tabIDString = items[indexPath.item].id.uuidString
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(tabIDString, forType: Self.tabPasteboardType)
        return pasteboardItem
    }

    func collectionView(
        _: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard
            draggingInfo.draggingPasteboard.string(forType: Self.tabPasteboardType)
                .flatMap(UUID.init(uuidString:)) != nil
        else {
            return []
        }

        let proposedIndex = min(max(proposedDropIndexPath.pointee.item, 0), items.count)
        proposedDropIndexPath.pointee = NSIndexPath(forItem: proposedIndex, inSection: 0)
        proposedDropOperation.pointee = .before
        return .move
    }

    func collectionView(
        _: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation _: NSCollectionView.DropOperation
    ) -> Bool {
        guard
            let tabID = draggingInfo.draggingPasteboard.string(forType: Self.tabPasteboardType)
                .flatMap(UUID.init(uuidString:))
        else {
            return false
        }

        let proposedIndex = min(max(indexPath.item, 0), items.count)
        let sourceIndex = items.firstIndex { $0.id == tabID } ?? proposedIndex
        let destinationIndex = sourceIndex < proposedIndex ? proposedIndex - 1 : proposedIndex
        onMoveTab?(tabID, destinationIndex)
        return true
    }
}

private final class WorkspaceTabCollectionViewItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("WorkspaceTabCollectionViewItem")

    let tabButton = WorkspaceTabButtonView()

    override func loadView() {
        view = tabButton
    }
}
