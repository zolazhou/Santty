import AppKit
import QuartzCore

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

struct WorkspaceTabReorderPreviewMove: Equatable {
    let sourceIndex: Int
    let destinationIndex: Int
}

struct WorkspaceTabReorderPreviewPlan: Equatable {
    let previewIDs: [UUID]
    let modelDestinationIndex: Int
    let previewMove: WorkspaceTabReorderPreviewMove?

    static func make(
        draggedTabID: UUID,
        modelIDs: [UUID],
        currentPreviewIDs: [UUID]?,
        proposedDisplayIndex: Int
    ) -> WorkspaceTabReorderPreviewPlan? {
        guard
            let modelSourceIndex = modelIDs.firstIndex(of: draggedTabID)
        else {
            return nil
        }

        let displayIDs = currentPreviewIDs ?? modelIDs
        guard
            displayIDs.count == modelIDs.count,
            Set(displayIDs) == Set(modelIDs),
            let displaySourceIndex = displayIDs.firstIndex(of: draggedTabID)
        else {
            return nil
        }

        let clampedProposedIndex = min(max(proposedDisplayIndex, 0), displayIDs.count)
        var previewIDs = displayIDs
        previewIDs.remove(at: displaySourceIndex)

        let displayDestinationIndex =
            displaySourceIndex < clampedProposedIndex
            ? clampedProposedIndex - 1
            : clampedProposedIndex
        let clampedDisplayDestinationIndex = min(
            max(displayDestinationIndex, 0),
            previewIDs.count
        )
        previewIDs.insert(draggedTabID, at: clampedDisplayDestinationIndex)

        let nonDraggedModelIDs = modelIDs.filter { $0 != draggedTabID }
        let previewTabIndex = previewIDs.firstIndex(of: draggedTabID) ?? modelSourceIndex
        let followingID = previewIDs.dropFirst(previewTabIndex + 1).first
        let modelDestinationIndex =
            followingID.flatMap { nonDraggedModelIDs.firstIndex(of: $0) }
            ?? nonDraggedModelIDs.count
        let previewMove =
            displaySourceIndex == clampedDisplayDestinationIndex
            ? nil
            : WorkspaceTabReorderPreviewMove(
                sourceIndex: displaySourceIndex,
                destinationIndex: clampedDisplayDestinationIndex
            )

        return WorkspaceTabReorderPreviewPlan(
            previewIDs: previewIDs,
            modelDestinationIndex: modelDestinationIndex,
            previewMove: previewMove
        )
    }
}

@MainActor
final class WorkspaceTabStripView: NSView {
    var items: [WorkspaceTabStripItem] = [] {
        didSet {
            guard items != oldValue else {
                return
            }

            let previousDisplayedItems = dragPreviewState?.items ?? oldValue
            if let dragPreviewState {
                self.dragPreviewState = nil

                if dragPreviewState.didCommit,
                    dragPreviewState.items.map(\.id) == items.map(\.id)
                {
                    reloadTabsWithoutAnimation()
                } else {
                    reloadTabs(previousItems: previousDisplayedItems)
                }
            } else {
                reloadTabs(previousItems: oldValue)
            }
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
    private var dragPreviewState: DragPreviewState?
    nonisolated private static let tabPasteboardType = NSPasteboard.PasteboardType(
        "dev.zola.Santty.workspace-tab"
    )

    private let tabSpacing: CGFloat = 6
    private let tabHeight: CGFloat = 32
    private let minimumTabWidth: CGFloat = 60
    private let maximumTabWidth: CGFloat = 220
    private let newTabButtonWidth: CGFloat = 28
    private let reorderAnimationDuration: TimeInterval = 0.16

    private struct DragPreviewState {
        let draggedTabID: UUID
        var items: [WorkspaceTabStripItem]
        var destinationIndex: Int
        var didCommit = false
    }

    private var displayedItems: [WorkspaceTabStripItem] {
        dragPreviewState?.items ?? items
    }

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

        if previousItems.map(\.id) == items.map(\.id) {
            reloadTabsWithoutAnimation()
            return
        }

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
            context.duration = reorderAnimationDuration
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

    private func reloadTabsWithoutAnimation() {
        performWithoutImplicitTabAnimations {
            collectionView.reloadData()
            collectionLayout.invalidateLayout()
            collectionView.layoutSubtreeIfNeeded()
            reconfigureVisibleTabButtons()
        }
    }

    private func performWithoutImplicitTabAnimations(_ updates: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updates()
            CATransaction.commit()
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

    private func items(reorderedBy previewIDs: [UUID]) -> [WorkspaceTabStripItem]? {
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let reorderedItems = previewIDs.compactMap { itemsByID[$0] }
        guard reorderedItems.count == items.count else {
            return nil
        }

        return reorderedItems
    }

    private func updateDragPreview(
        for draggedTabID: UUID,
        proposedDisplayIndex: Int
    ) -> WorkspaceTabReorderPreviewPlan? {
        let currentPreviewIDs =
            dragPreviewState?.draggedTabID == draggedTabID
            ? dragPreviewState?.items.map(\.id)
            : nil
        guard
            let plan = WorkspaceTabReorderPreviewPlan.make(
                draggedTabID: draggedTabID,
                modelIDs: items.map(\.id),
                currentPreviewIDs: currentPreviewIDs,
                proposedDisplayIndex: proposedDisplayIndex
            ),
            let previewItems = items(reorderedBy: plan.previewIDs)
        else {
            return nil
        }

        let previousDisplayedIDs = displayedItems.map(\.id)
        let previousStateDidCommit = dragPreviewState?.didCommit ?? false
        dragPreviewState = DragPreviewState(
            draggedTabID: draggedTabID,
            items: previewItems,
            destinationIndex: plan.modelDestinationIndex,
            didCommit: previousStateDidCommit
        )

        guard previousDisplayedIDs != plan.previewIDs else {
            reconfigureVisibleTabButtons()
            return plan
        }

        guard let previewMove = plan.previewMove else {
            reloadTabsWithoutAnimation()
            return plan
        }

        animateTabMove(
            from: previewMove.sourceIndex,
            to: previewMove.destinationIndex
        )
        return plan
    }

    private func cancelDragPreview(animated: Bool) {
        guard let dragPreviewState else {
            return
        }

        let previewIDs = dragPreviewState.items.map(\.id)
        let modelIDs = items.map(\.id)
        self.dragPreviewState = nil

        guard previewIDs != modelIDs else {
            reloadTabsWithoutAnimation()
            return
        }

        guard
            animated,
            previewIDs.count == modelIDs.count,
            Set(previewIDs) == Set(modelIDs),
            let sourceIndex = previewIDs.firstIndex(of: dragPreviewState.draggedTabID),
            let destinationIndex = modelIDs.firstIndex(of: dragPreviewState.draggedTabID)
        else {
            reloadTabsWithoutAnimation()
            return
        }

        animateTabMove(from: sourceIndex, to: destinationIndex)
    }

    private func animateTabMove(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex else {
            reconfigureVisibleTabButtons()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reorderAnimationDuration
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
        let currentItems = displayedItems
        for case let collectionItem as WorkspaceTabCollectionViewItem in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: collectionItem) else {
                continue
            }

            if indexPath.item == currentItems.count {
                configureNewTabButton(collectionItem.tabButton)
                continue
            }

            let item = currentItems[indexPath.item]
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
        if let index = displayedItems.firstIndex(where: { $0.id == id }) {
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
        displayedItems.count + 1
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let collectionItem = collectionView.makeItem(
            withIdentifier: WorkspaceTabCollectionViewItem.identifier,
            for: indexPath
        ) as! WorkspaceTabCollectionViewItem

        let currentItems = displayedItems
        guard indexPath.item < currentItems.count else {
            configureNewTabButton(collectionItem.tabButton)
            return collectionItem
        }

        let item = currentItems[indexPath.item]
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
        let currentItems = displayedItems
        guard indexPath.item < currentItems.count else {
            return NSSize(width: newTabButtonWidth, height: tabHeight)
        }

        return NSSize(width: width(for: currentItems[indexPath.item]), height: tabHeight)
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

        let currentItems = displayedItems
        if indexPath.item == currentItems.count {
            onNewTab?()
        } else if currentItems.indices.contains(indexPath.item) {
            onSelectTab?(currentItems[indexPath.item].id)
        }
        collectionView.deselectItems(at: indexPaths)
    }

    func collectionView(
        _: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> NSPasteboardWriting? {
        let currentItems = displayedItems
        guard indexPath.item < currentItems.count else {
            return nil
        }

        let tabIDString = currentItems[indexPath.item].id.uuidString
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
            let tabID = draggingInfo.draggingPasteboard.string(forType: Self.tabPasteboardType)
                .flatMap(UUID.init(uuidString:))
        else {
            return []
        }

        var proposedIndex = min(max(proposedDropIndexPath.pointee.item, 0), displayedItems.count)

        // AppKit cancels a drop whose proposed index matches the dragged
        // item's current index (it treats it as a no-op) and never calls
        // acceptDrop. Proposing the next slot instead yields the same model
        // destination but keeps the drop deliverable.
        if displayedItems.indices.contains(proposedIndex),
            displayedItems[proposedIndex].id == tabID
        {
            proposedIndex = min(proposedIndex + 1, displayedItems.count)
        }

        proposedDropIndexPath.pointee = NSIndexPath(forItem: proposedIndex, inSection: 0)
        proposedDropOperation.pointee = .before
        return updateDragPreview(for: tabID, proposedDisplayIndex: proposedIndex) == nil
            ? []
            : .move
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

        let proposedIndex = min(max(indexPath.item, 0), displayedItems.count)
        guard
            let plan = updateDragPreview(for: tabID, proposedDisplayIndex: proposedIndex),
            let sourceIndex = items.firstIndex(where: { $0.id == tabID })
        else {
            cancelDragPreview(animated: true)
            return false
        }

        guard plan.modelDestinationIndex != sourceIndex else {
            cancelDragPreview(animated: true)
            return true
        }

        dragPreviewState?.didCommit = true
        dragPreviewState?.destinationIndex = plan.modelDestinationIndex
        onMoveTab?(tabID, plan.modelDestinationIndex)
        return true
    }

    func collectionView(
        _: NSCollectionView,
        draggingSession session: NSDraggingSession,
        willBeginAt _: NSPoint
    ) {
        // When a drop is not delivered and the preview is committed via the
        // fallback in draggingSessionEnded, sliding the drag image back to
        // its starting position would look like the tab jumped back before
        // landing at its new position.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        draggingSession _: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        dragOperation operation: NSDragOperation
    ) {
        // Fallback for drops AppKit never delivers (e.g. windows without the
        // titled style): commit the pending preview when the drag ended over
        // the strip with the mouse released.
        if operation.isEmpty,
            let dragPreviewState,
            !dragPreviewState.didCommit,
            NSApp.currentEvent?.type == .leftMouseUp
        {
            let windowPoint = collectionView.window?.convertFromScreen(
                NSRect(origin: screenPoint, size: .zero)
            ).origin ?? screenPoint
            let pointInCollection = collectionView.convert(windowPoint, from: nil)

            if collectionView.bounds.contains(pointInCollection),
                let sourceIndex = items.firstIndex(where: {
                    $0.id == dragPreviewState.draggedTabID
                }),
                dragPreviewState.destinationIndex != sourceIndex
            {
                self.dragPreviewState?.didCommit = true
                onMoveTab?(dragPreviewState.draggedTabID, dragPreviewState.destinationIndex)
                return
            }
        }

        cancelDragPreview(animated: true)
    }
}

private final class WorkspaceTabCollectionViewItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("WorkspaceTabCollectionViewItem")

    let tabButton = WorkspaceTabButtonView()

    override func loadView() {
        view = tabButton
    }
}
