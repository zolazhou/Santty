import AppKit
import os

private let paneResizeWVCLog = Logger(subsystem: "com.zola.santty", category: "PaneResize")

private func formatFractionsWVC(_ fractions: [CGFloat]) -> String {
    "[" + fractions.map { String(format: "%.4f", Double($0)) }.joined(separator: ", ") + "]"
}

private func formatPath(_ path: [LayoutPathComponent]) -> String {
    path.map { component in
        switch component {
        case .child(let index): return "\(index)"
        }
    }.joined(separator: "/")
}

struct PaneFocusRatios: Equatable {
    var horizontal: CGFloat
    var vertical: CGFloat

    subscript(axis: SplitAxis) -> CGFloat {
        switch axis {
        case .horizontal:
            horizontal
        case .vertical:
            vertical
        }
    }
}

struct PaneAutoResizeConfiguration: Equatable {
    var isEnabled: Bool
    var ratios: PaneFocusRatios
}

enum WorkspaceFocusZoomConfiguration {
    static let defaultAutoResizeConfiguration = PaneAutoResizeConfiguration(
        isEnabled: false,
        ratios: PaneFocusRatios(horizontal: 0.7, vertical: 0.7)
    )
    static let animationDuration: TimeInterval = 0.15
}

enum WorkspaceFloatingPaneConfiguration {
    static let animationDuration: TimeInterval = 0.15
    static let resizeStep: CGFloat = 40
}

private enum PaneDividerMoveDirection {
    case up
    case down
    case left
    case right

    var axis: SplitAxis {
        switch self {
        case .left, .right:
            .horizontal
        case .up, .down:
            .vertical
        }
    }
}

struct ActiveAutoZoomSplitState: Equatable {
    let splitPath: [LayoutPathComponent]
    let originalFractions: [CGFloat]
}

struct ActiveAutoZoomState: Equatable {
    let focusedPaneID: PaneID
    let splitStates: [ActiveAutoZoomSplitState]

    var splitPath: [LayoutPathComponent] {
        splitStates.last?.splitPath ?? []
    }

    var originalFractions: [CGFloat] {
        splitStates.last?.originalFractions ?? []
    }
}

private struct DirectionalPaneCandidate {
    let paneID: PaneID
    let score: DirectionalFocusScore?
}

private struct DirectionalFocusScore: Comparable {
    let hasPerpendicularOverlap: Bool
    let primaryDistance: CGFloat
    let focusRecency: Int?
    let perpendicularDistance: CGFloat

    static func < (lhs: DirectionalFocusScore, rhs: DirectionalFocusScore) -> Bool {
        if lhs.hasPerpendicularOverlap != rhs.hasPerpendicularOverlap {
            return lhs.hasPerpendicularOverlap
        }
        if lhs.primaryDistance != rhs.primaryDistance {
            return lhs.primaryDistance < rhs.primaryDistance
        }
        if lhs.focusRecency != rhs.focusRecency {
            switch (lhs.focusRecency, rhs.focusRecency) {
            case (.some(let lhsRecency), .some(let rhsRecency)):
                return lhsRecency < rhsRecency
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
        }

        return lhs.perpendicularDistance < rhs.perpendicularDistance
    }
}

@MainActor
final class WorkspaceViewController: NSViewController, NSMenuItemValidation, NSWindowDelegate {
    private var rootView: WorkspaceRootView {
        view as! WorkspaceRootView
    }

    private var tabs: [WorkspaceTabState] = []
    private var selectedTabID: UUID?
    private var tilingView: WorkspaceTilingView?
    private var autoResizePanelController: PaneAutoResizePanelController?
    private var hasAppeared = false
    private var bypassNextWindowCloseConfirmation = false
    private var didRequestWindowCloseForTesting = false
    private var appearanceSettingsObserver: NSObjectProtocol?
    private var terminalSettingsObserver: NSObjectProtocol?
    private var agentSessionObserver: NSObjectProtocol?
    private var agentManagerPopoverController: AgentManagerPopoverController?

    private var selectedTabIndex: Int? {
        guard let selectedTabID else {
            return nil
        }

        return tabs.firstIndex { $0.id == selectedTabID }
    }

    private var selectedTabState: WorkspaceTabState? {
        guard let selectedTabIndex else {
            return nil
        }

        return tabs[selectedTabIndex]
    }

    private var focusedPaneController: TerminalPaneController? {
        selectedTabState?.focusedPaneController
    }

    override func loadView() {
        view = WorkspaceRootView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateAppearance()
        rootView.tabStripView.onSelectTab = { [weak self] tabID in
            self?.selectTab(withID: tabID)
        }
        rootView.tabStripView.onCloseTab = { [weak self] tabID in
            self?.closeTab(withID: tabID)
        }
        rootView.tabStripView.onNewTab = { [weak self] in
            self?.newTab(nil)
        }
        rootView.tabStripView.onMoveTab = { [weak self] tabID, destinationIndex in
            self?.moveTab(withID: tabID, to: destinationIndex)
        }
        rootView.toolbarView.agentStatusButton.target = self
        rootView.toolbarView.agentStatusButton.action = #selector(showAgentManager(_:))
        createInitialTab()
        appearanceSettingsObserver = NotificationCenter.default.addObserver(
            forName: AppAppearanceSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateAppearance()
            }
        }
        terminalSettingsObserver = NotificationCenter.default.addObserver(
            forName: TerminalSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyTerminalSettingsToPanes()
                self?.updateAppearance()
            }
        }
        agentSessionObserver = NotificationCenter.default.addObserver(
            forName: AgentSessionStore.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateAgentStatus()
                self?.updateAgentManagerPopover()
            }
        }
        updateAgentStatus()
    }

    deinit {
        MainActor.assumeIsolated {
            if let appearanceSettingsObserver {
                NotificationCenter.default.removeObserver(appearanceSettingsObserver)
            }
            if let terminalSettingsObserver {
                NotificationCenter.default.removeObserver(terminalSettingsObserver)
            }
            if let agentSessionObserver {
                NotificationCenter.default.removeObserver(agentSessionObserver)
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        if !hasAppeared {
            hasAppeared = true
            if let selectedTabState {
                startPaneControllersIfNeeded(in: selectedTabState)
            }
        }

        applyFocusedPaneResponder()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(splitPaneHorizontally(_:)), #selector(splitPaneVertically(_:)):
            focusedPaneController?.isLive == true
        case #selector(equalizePaneSplits(_:)):
            canEqualizePaneSplits()
        case #selector(movePaneDividerUp(_:)):
            canMovePaneDivider(.up)
        case #selector(movePaneDividerDown(_:)):
            canMovePaneDivider(.down)
        case #selector(movePaneDividerLeft(_:)):
            canMovePaneDivider(.left)
        case #selector(movePaneDividerRight(_:)):
            canMovePaneDivider(.right)
        case #selector(closePane(_:)):
            focusedPaneController != nil
        case #selector(showAutoResizeSettings(_:)):
            focusedPaneController != nil
        case #selector(toggleFloatingPane(_:)):
            focusedPaneController != nil
        case #selector(openPromptEditor(_:)):
            focusedPaneController?.isLive == true
        case #selector(focusNextPane(_:)), #selector(focusPreviousPane(_:)),
            #selector(focusLeftPane(_:)), #selector(focusRightPane(_:)),
            #selector(focusAbovePane(_:)), #selector(focusBelowPane(_:)):
            (selectedTabState?.paneControllers.count ?? 0) > 1
        case #selector(newTab(_:)):
            true
        case #selector(closeTab(_:)), #selector(changeTabTitle(_:)):
            selectedTabState != nil
        case #selector(focusNextTab(_:)), #selector(focusPreviousTab(_:)):
            tabs.count > 1
        case #selector(focusTabAtIndex(_:)):
            tabs.indices.contains(menuItem.tag)
        default:
            true
        }
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        if bypassNextWindowCloseConfirmation {
            bypassNextWindowCloseConfirmation = false
            return true
        }

        return confirmCloseWindowIfNeeded()
    }

    @objc func splitPaneHorizontally(_: Any?) {
        splitFocusedPane(along: .horizontal)
    }

    @objc func splitPaneVertically(_: Any?) {
        splitFocusedPane(along: .vertical)
    }

    @objc func equalizePaneSplits(_: Any?) {
        equalizePaneSplits()
    }

    @objc func movePaneDividerUp(_: Any?) {
        movePaneDivider(.up)
    }

    @objc func movePaneDividerDown(_: Any?) {
        movePaneDivider(.down)
    }

    @objc func movePaneDividerLeft(_: Any?) {
        movePaneDivider(.left)
    }

    @objc func movePaneDividerRight(_: Any?) {
        movePaneDivider(.right)
    }

    @objc func closePane(_: Any?) {
        guard let paneController = focusedPaneController else {
            return
        }

        if paneController.isLive {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Close Pane?"
            alert.informativeText = "The focused pane still has a running shell session."
            alert.addButton(withTitle: "Close Pane")
            alert.addButton(withTitle: "Cancel")

            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }

        performClosePane(withID: paneController.id)
    }

    @objc func showAutoResizeSettings(_: Any?) {
        guard
            let window = view.window,
            let tabState = selectedTabState,
            let paneID = tabState.focusedPaneID,
            let configuration = tabState.paneAutoResizeConfigurations[paneID]
        else {
            NSSound.beep()
            return
        }

        let panelController = autoResizePanelController ?? PaneAutoResizePanelController()
        autoResizePanelController = panelController
        panelController.onChange = { [weak self] updatedConfiguration in
            self?.updateAutoResizeConfiguration(updatedConfiguration, for: paneID)
        }
        panelController.show(configuration: configuration, relativeTo: window)
    }

    @objc func toggleFloatingPane(_: Any?) {
        guard let tabState = selectedTabState, tabState.focusedPaneController != nil else {
            NSSound.beep()
            return
        }

        if tabState.activeFloatingPaneState != nil {
            leaveFloatingPane(in: tabState, animated: true, reapplyAutoZoom: true)
        } else {
            enterFloatingPane(in: tabState, animated: true)
        }
    }

    @objc func openPromptEditor(_: Any?) {
        guard
            let window = view.window,
            let paneController = focusedPaneController,
            paneController.isLive
        else {
            NSSound.beep()
            return
        }

        paneController.showPromptEditor(relativeTo: window)
    }

    @objc func showAgentManager(_: Any?) {
        let paneIDs = currentWindowPaneIDs
        let sessions = AgentSessionStore.shared.snapshots(forPaneIDs: paneIDs)
        guard !sessions.isEmpty else {
            return
        }

        AgentSessionStore.shared.markRead(forPaneIDs: paneIDs)
        let updatedSessions = AgentSessionStore.shared.snapshots(forPaneIDs: paneIDs)
        let popoverController = AgentManagerPopoverController(
            sessions: updatedSessions,
            previousFirstResponder: view.window?.firstResponder,
            onFocusPane: { [weak self] paneID in
                self?.focusPaneLocatingTab(withID: paneID)
            },
            onClearEnded: { [weak self] in
                self?.clearEndedAgentSessions()
            },
            onClose: { [weak self] in
                self?.agentManagerPopoverController = nil
            }
        )
        agentManagerPopoverController = popoverController
        popoverController.show(relativeTo: rootView.toolbarView.agentStatusButton)
        updateAgentStatus()
    }

    @objc func focusNextPane(_: Any?) {
        guard let tabState = selectedTabState, let layoutNode = tabState.layoutNode,
            let focusedPaneID = tabState.focusedPaneID
        else {
            return
        }

        guard let nextPaneID = layoutNode.nextPaneID(after: focusedPaneID) else {
            return
        }

        focusPane(withID: nextPaneID)
    }

    @objc func focusPreviousPane(_: Any?) {
        guard let tabState = selectedTabState, let layoutNode = tabState.layoutNode,
            let focusedPaneID = tabState.focusedPaneID
        else {
            return
        }

        guard let previousPaneID = layoutNode.previousPaneID(before: focusedPaneID) else {
            return
        }

        focusPane(withID: previousPaneID)
    }

    @objc func focusLeftPane(_: Any?) {
        focusPane(in: .left)
    }

    @objc func focusRightPane(_: Any?) {
        focusPane(in: .right)
    }

    @objc func focusAbovePane(_: Any?) {
        focusPane(in: .above)
    }

    @objc func focusBelowPane(_: Any?) {
        focusPane(in: .below)
    }

    @objc func newTab(_: Any?) {
        let newTabState = makeTabState(startImmediately: hasAppeared)
        tabs.append(newTabState)
        selectTab(withID: newTabState.id, restorePreviousAutoZoom: true)
    }

    @objc func closeTab(_: Any?) {
        guard let selectedTabID else {
            return
        }

        closeTab(withID: selectedTabID)
    }

    @objc func changeTabTitle(_: Any?) {
        guard let tabState = selectedTabState else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Change Tab Title"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        textField.stringValue = tabState.customTitle ?? tabState.displayTitle
        textField.placeholderString = tabState.focusedPaneController?.displayTitle ?? "Shell"
        textField.selectText(nil)
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return
        }

        updateSelectedTabTitle(textField.stringValue)
    }

    @objc func focusNextTab(_: Any?) {
        guard let selectedTabIndex, !tabs.isEmpty else {
            return
        }

        let nextIndex = (selectedTabIndex + 1) % tabs.count
        selectTab(withID: tabs[nextIndex].id)
    }

    @objc func focusPreviousTab(_: Any?) {
        guard let selectedTabIndex, !tabs.isEmpty else {
            return
        }

        let previousIndex = (selectedTabIndex - 1 + tabs.count) % tabs.count
        selectTab(withID: tabs[previousIndex].id)
    }

    @objc func focusTabAtIndex(_ sender: Any?) {
        let index: Int
        if let menuItem = sender as? NSMenuItem {
            index = menuItem.tag
        } else if let control = sender as? NSControl {
            index = control.tag
        } else {
            return
        }

        focusTab(at: index)
    }

    private func createInitialTab() {
        let initialTabState = makeTabState(startImmediately: false)
        tabs = [initialTabState]
        selectedTabID = initialTabState.id
        rebuildWorkspaceLayout()
    }

    private func makeTabState(startImmediately: Bool) -> WorkspaceTabState {
        let paneController = makePaneController()
        let tabState = WorkspaceTabState(
            layoutNode: .panel(paneController.id),
            paneControllers: [paneController.id: paneController],
            paneAutoResizeConfigurations: [
                paneController.id: WorkspaceFocusZoomConfiguration.defaultAutoResizeConfiguration
            ],
            focusedPaneID: paneController.id
        )

        if startImmediately {
            paneController.startIfNeeded()
        }

        return tabState
    }

    private func makePaneController(workingDirectory: String? = nil) -> TerminalPaneController {
        let paneController = TerminalPaneController(workingDirectory: workingDirectory)
        paneController.updateAppearance()

        paneController.onFocusRequest = { [weak self] paneID in
            self?.focusPaneLocatingTab(withID: paneID)
        }

        paneController.onTitleChange = { [weak self] paneID in
            self?.handleTitleChange(for: paneID)
        }

        paneController.onExit = { [weak self] paneID in
            self?.handlePaneExit(withID: paneID)
        }

        return paneController
    }

    private func applyTerminalSettingsToPanes() {
        for paneController in tabs.flatMap({ $0.paneControllers.values }) {
            paneController.applyTerminalSettings()
        }
    }

    private func splitFocusedPane(along axis: SplitAxis) {
        guard
            let tabState = selectedTabState,
            let focusedPaneController = tabState.focusedPaneController,
            focusedPaneController.isLive,
            let layoutNode = tabState.layoutNode,
            let focusedPaneID = tabState.focusedPaneID
        else {
            NSSound.beep()
            return
        }

        leaveFloatingPane(in: tabState, animated: false, reapplyAutoZoom: false)
        clearActiveAutoZoomState(in: tabState, restoreLayout: false, animated: false)

        let newPaneController = makePaneController(
            workingDirectory: focusedPaneController.currentWorkingDirectory
        )
        guard
            let updatedLayoutNode = layoutNode.insertingSplit(
                for: focusedPaneID,
                axis: axis,
                newPaneID: newPaneController.id
            )
        else {
            return
        }

        tabState.paneControllers[newPaneController.id] = newPaneController
        tabState.paneAutoResizeConfigurations[newPaneController.id] =
            WorkspaceFocusZoomConfiguration.defaultAutoResizeConfiguration
        tabState.layoutNode = updatedLayoutNode
        tabState.focusedPaneID = newPaneController.id
        tabState.markPaneFocused(newPaneController.id)
        rebuildWorkspaceLayout(applyAutoZoomAnimated: true)

        if hasAppeared {
            newPaneController.startIfNeeded()
            applyFocusedPaneResponder()
        }
    }

    private func equalizePaneSplits() {
        guard
            let tabState = selectedTabState,
            let layoutNode = tabState.layoutNode,
            canEqualizePaneSplits()
        else {
            NSSound.beep()
            return
        }

        leaveFloatingPane(in: tabState, animated: false, reapplyAutoZoom: false)
        clearActiveAutoZoomState(in: tabState, restoreLayout: false, animated: false)
        tabState.layoutNode = layoutNode.equalizingSplitFractions()
        for paneID in tabState.paneControllers.keys {
            tabState.paneAutoResizeConfigurations[paneID]?.isEnabled = false
        }
        rebuildWorkspaceLayout()
    }

    private func canEqualizePaneSplits() -> Bool {
        (selectedTabState?.paneControllers.count ?? 0) > 1
    }

    private func movePaneDivider(_ direction: PaneDividerMoveDirection) {
        if let tabState = selectedTabState,
            tabState.activeFloatingPaneState != nil
        {
            resizeFloatingPane(in: tabState, direction: direction)
            return
        }

        paneResizeWVCLog.debug(
            "movePaneDivider direction=\(String(describing: direction), privacy: .public)"
        )
        guard
            let target = focusedResizeTarget(for: direction.axis),
            let targetFractions = movedDividerFractions(
                in: target.context,
                direction: direction
            )
        else {
            paneResizeWVCLog.debug("movePaneDivider no target -> beep")
            NSSound.beep()
            return
        }

        let clampedFractions = target.splitNode.clampedFractions(
            targetFractions,
            in: target.tilingView.bounds.size
        )
        paneResizeWVCLog.debug(
            "movePaneDivider path=\(formatPath(target.context.splitPath), privacy: .public) context=\(formatFractionsWVC(target.context.fractions), privacy: .public) proposed=\(formatFractionsWVC(targetFractions), privacy: .public) clamped=\(formatFractionsWVC(clampedFractions), privacy: .public) bounds=\(NSStringFromSize(target.tilingView.bounds.size), privacy: .public)"
        )
        guard clampedFractions != target.context.fractions else {
            paneResizeWVCLog.debug("movePaneDivider clamped==context -> beep")
            NSSound.beep()
            return
        }

        // Update the model
        if let layoutNode = selectedTabState?.layoutNode,
            let updatedNode = layoutNode.replacingFractions(
                at: target.context.splitPath, with: clampedFractions
            )
        {
            selectedTabState?.layoutNode = updatedNode
            let paneViews = buildPaneViewsDictionary(for: selectedTabState!)
            target.tilingView.setLayoutNode(
                updatedNode, paneViews: paneViews, animated: true
            )
        }

        updateSplitFractions(
            at: target.context.splitPath,
            to: clampedFractions,
            changeSource: .userDrag
        )
    }

    private func canMovePaneDivider(_ direction: PaneDividerMoveDirection) -> Bool {
        if selectedTabState?.activeFloatingPaneState != nil {
            return true
        }
        return focusedResizeTarget(for: direction.axis) != nil
    }

    private func resizeFloatingPane(
        in tabState: WorkspaceTabState,
        direction: PaneDividerMoveDirection
    ) {
        guard var floatingState = tabState.activeFloatingPaneState else { return }

        let step = WorkspaceFloatingPaneConfiguration.resizeStep

        let currentSize: NSSize = {
            if let existing = floatingState.size {
                return existing
            }
            return rootView.floatingPaneTargetFrame().size
        }()

        var newSize = currentSize
        switch direction {
        case .up:
            newSize.height += step
        case .down:
            newSize.height -= step
        case .left:
            newSize.width -= step
        case .right:
            newSize.width += step
        }

        newSize.width = max(newSize.width, WorkspaceLayoutMetrics.minimumPaneSize.width)
        newSize.height = max(newSize.height, WorkspaceLayoutMetrics.minimumPaneSize.height)

        guard newSize != currentSize else {
            NSSound.beep()
            return
        }

        floatingState.size = newSize
        tabState.activeFloatingPaneState = floatingState
        rootView.setCustomFloatingPaneSize(newSize)
    }

    private func focusedResizeTarget(
        for axis: SplitAxis
    ) -> (
        context: ParentSplitContext,
        splitNode: LayoutNode,
        tilingView: WorkspaceTilingView
    )? {
        guard
            let tabState = selectedTabState,
            let layoutNode = tabState.layoutNode,
            let focusedPaneID = tabState.focusedPaneID,
            let tilingView,
            let context = layoutNode.ancestorSplitContexts(for: focusedPaneID).reversed()
                .first(where: { $0.axis == axis && $0.fractions.count > 1 }),
            let splitNode = layoutNode.node(at: context.splitPath)
        else {
            return nil
        }

        return (context, splitNode, tilingView)
    }

    private func movedDividerFractions(
        in context: ParentSplitContext,
        direction: PaneDividerMoveDirection,
        step: CGFloat = 0.05
    ) -> [CGFloat]? {
        let focusedIndex = context.focusedChildIndex
        guard context.fractions.indices.contains(focusedIndex) else {
            return nil
        }

        let neighboringIndex: Int
        let focusedDelta: CGFloat

        switch direction {
        case .left, .up:
            if focusedIndex > 0 {
                neighboringIndex = focusedIndex - 1
                focusedDelta = step
            } else if focusedIndex + 1 < context.fractions.count {
                neighboringIndex = focusedIndex + 1
                focusedDelta = -step
            } else {
                return nil
            }
        case .right, .down:
            if focusedIndex + 1 < context.fractions.count {
                neighboringIndex = focusedIndex + 1
                focusedDelta = step
            } else if focusedIndex > 0 {
                neighboringIndex = focusedIndex - 1
                focusedDelta = -step
            } else {
                return nil
            }
        }

        var fractions = context.fractions
        fractions[focusedIndex] += focusedDelta
        fractions[neighboringIndex] -= focusedDelta
        return fractions
    }

    private func performClosePane(withID paneID: PaneID) {
        guard let tabState = tabState(containing: paneID) else {
            return
        }

        performClosePane(withID: paneID, in: tabState)
    }

    private func performClosePane(withID paneID: PaneID, in tabState: WorkspaceTabState) {
        guard let layoutNode = tabState.layoutNode,
            let closePaneResult = layoutNode.closingPane(paneID)
        else {
            return
        }

        leaveFloatingPane(in: tabState, animated: false, reapplyAutoZoom: false)
        clearActiveAutoZoomState(in: tabState, restoreLayout: false, animated: false)

        tabState.paneControllers.removeValue(forKey: paneID)
        tabState.paneAutoResizeConfigurations.removeValue(forKey: paneID)
        tabState.floatingPaneSizes.removeValue(forKey: paneID)
        tabState.removePaneFromFocusHistory(paneID)
        AgentSessionStore.shared.removeSessions(forPaneID: paneID)

        if let root = closePaneResult.root {
            tabState.layoutNode = root
            tabState.focusedPaneID = closePaneResult.promotedPaneID ?? root.firstPaneID
            if let focusedPaneID = tabState.focusedPaneID {
                tabState.markPaneFocused(focusedPaneID)
            }
            if tabState.id == selectedTabID {
                rebuildWorkspaceLayout(applyAutoZoomAnimated: true)
            } else {
                updateTabStrip()
            }
            return
        }

        closeTab(withID: tabState.id, bypassTabConfirmation: true)
    }

    private func focusPaneLocatingTab(withID paneID: PaneID) {
        guard let tabState = tabState(containing: paneID) else {
            return
        }

        if tabState.id != selectedTabID {
            selectTab(withID: tabState.id)
        }

        focusPane(withID: paneID)
    }

    private func focusPane(withID paneID: PaneID) {
        guard let tabState = selectedTabState, tabState.containsPane(withID: paneID) else {
            return
        }

        guard paneID != tabState.focusedPaneID else {
            return
        }

        leaveFloatingPane(in: tabState, animated: false, reapplyAutoZoom: false)
        restoreActiveAutoZoom(in: tabState, animated: true)

        tabState.focusedPaneID = paneID
        tabState.markPaneFocused(paneID)
        applyAutoZoomToFocusedPane(in: tabState, animated: true)
        updatePanePresentation(in: tabState)
        updateTabStrip()
        updateWindowTitle()
        applyFocusedPaneResponder()
    }

    private func focusPane(in direction: PaneFocusDirection) {
        guard
            let tabState = selectedTabState,
            let focusedPaneID = tabState.focusedPaneID,
            let focusedFrame = renderedPaneFrame(for: focusedPaneID, in: tabState)
        else {
            return
        }

        let targetPaneID = tabState.paneControllers
            .compactMap { paneID, _ -> DirectionalPaneCandidate? in
                guard paneID != focusedPaneID,
                    let candidateFrame = renderedPaneFrame(for: paneID, in: tabState)
                else {
                    return nil
                }

                return DirectionalPaneCandidate(
                    paneID: paneID,
                    score: directionalFocusScore(
                        from: focusedFrame,
                        to: candidateFrame,
                        direction: direction,
                        focusRecency: tabState.focusRecency(for: paneID)
                    )
                )
            }
            .compactMap { candidate -> DirectionalPaneCandidate? in
                candidate.score == nil ? nil : candidate
            }
            .min { lhs, rhs in
                guard let lhsScore = lhs.score, let rhsScore = rhs.score else {
                    return false
                }

                return lhsScore < rhsScore
            }?
            .paneID

        guard let targetPaneID else {
            return
        }

        focusPane(withID: targetPaneID)
    }

    private func renderedPaneFrame(for paneID: PaneID, in tabState: WorkspaceTabState) -> NSRect? {
        guard let hostView = tabState.paneControllers[paneID]?.hostView,
            hostView.superview != nil
        else {
            return nil
        }

        view.layoutSubtreeIfNeeded()
        let frame = hostView.convert(hostView.bounds, to: rootView)
        return frame.isEmpty ? nil : frame
    }

    private func renderedPaneFrameInFloatingOverlay(
        for paneID: PaneID,
        in tabState: WorkspaceTabState
    ) -> NSRect? {
        guard let hostView = tabState.paneControllers[paneID]?.hostView,
            hostView.superview != nil
        else {
            return nil
        }

        return rootView.floatingPaneFrame(for: hostView)
    }

    private func directionalFocusScore(
        from focusedFrame: NSRect,
        to candidateFrame: NSRect,
        direction: PaneFocusDirection,
        focusRecency: Int?
    ) -> DirectionalFocusScore? {
        let primaryDistance: CGFloat
        let perpendicularOverlap: CGFloat
        let perpendicularDistance: CGFloat

        switch direction {
        case .left:
            primaryDistance = focusedFrame.minX - candidateFrame.maxX
            perpendicularOverlap = intervalOverlap(
                focusedFrame.minY...focusedFrame.maxY,
                candidateFrame.minY...candidateFrame.maxY
            )
            perpendicularDistance = intervalMidpointDistance(
                focusedFrame.minY...focusedFrame.maxY,
                candidateFrame.minY...candidateFrame.maxY
            )
        case .right:
            primaryDistance = candidateFrame.minX - focusedFrame.maxX
            perpendicularOverlap = intervalOverlap(
                focusedFrame.minY...focusedFrame.maxY,
                candidateFrame.minY...candidateFrame.maxY
            )
            perpendicularDistance = intervalMidpointDistance(
                focusedFrame.minY...focusedFrame.maxY,
                candidateFrame.minY...candidateFrame.maxY
            )
        case .above:
            primaryDistance = candidateFrame.minY - focusedFrame.maxY
            perpendicularOverlap = intervalOverlap(
                focusedFrame.minX...focusedFrame.maxX,
                candidateFrame.minX...candidateFrame.maxX
            )
            perpendicularDistance = intervalMidpointDistance(
                focusedFrame.minX...focusedFrame.maxX,
                candidateFrame.minX...candidateFrame.maxX
            )
        case .below:
            primaryDistance = focusedFrame.minY - candidateFrame.maxY
            perpendicularOverlap = intervalOverlap(
                focusedFrame.minX...focusedFrame.maxX,
                candidateFrame.minX...candidateFrame.maxX
            )
            perpendicularDistance = intervalMidpointDistance(
                focusedFrame.minX...focusedFrame.maxX,
                candidateFrame.minX...candidateFrame.maxX
            )
        }

        guard primaryDistance >= 0 else {
            return nil
        }

        return DirectionalFocusScore(
            hasPerpendicularOverlap: perpendicularOverlap > 0,
            primaryDistance: primaryDistance,
            focusRecency: focusRecency,
            perpendicularDistance: perpendicularDistance
        )
    }

    private func intervalOverlap(_ lhs: ClosedRange<CGFloat>, _ rhs: ClosedRange<CGFloat>)
        -> CGFloat
    {
        max(0, min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound))
    }

    private func intervalMidpointDistance(
        _ lhs: ClosedRange<CGFloat>,
        _ rhs: ClosedRange<CGFloat>
    ) -> CGFloat {
        abs((lhs.lowerBound + lhs.upperBound) / 2 - (rhs.lowerBound + rhs.upperBound) / 2)
    }

    private func selectTab(withID tabID: UUID, restorePreviousAutoZoom: Bool = true) {
        guard tabs.contains(where: { $0.id == tabID }) else {
            return
        }

        if tabID == selectedTabID {
            if let selectedTabState {
                startPaneControllersIfNeeded(in: selectedTabState)
            }
            rebuildWorkspaceLayout()
            return
        }

        if let currentTabState = selectedTabState {
            leaveFloatingPane(in: currentTabState, animated: false, reapplyAutoZoom: false)
        }

        if restorePreviousAutoZoom, let currentTabState = selectedTabState {
            restoreActiveAutoZoom(in: currentTabState, animated: false)
        }

        selectedTabID = tabID
        rebuildWorkspaceLayout()

        if let selectedTabState {
            startPaneControllersIfNeeded(in: selectedTabState)
        }
    }

    private func focusTab(at index: Int) {
        guard tabs.indices.contains(index) else {
            NSSound.beep()
            return
        }

        selectTab(withID: tabs[index].id)
    }

    private func moveTab(withID tabID: UUID, to destinationIndex: Int) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }

        let tabState = tabs.remove(at: sourceIndex)
        let clampedDestinationIndex = min(max(destinationIndex, 0), tabs.count)
        guard clampedDestinationIndex != sourceIndex else {
            tabs.insert(tabState, at: sourceIndex)
            return
        }

        tabs.insert(tabState, at: clampedDestinationIndex)
        updateTabStrip()
    }

    private func closeTab(withID tabID: UUID, bypassTabConfirmation: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }

        let tabState = tabs[index]

        if tabs.count == 1 {
            guard confirmCloseWindowIfNeeded() else {
                return
            }

            removeAgentSessions(in: tabState)
            tabs.remove(at: index)
            selectedTabID = nil
            tilingView = nil
            rebuildWorkspaceLayout()
            requestWindowClose()
            return
        }

        if !bypassTabConfirmation, !confirmCloseTabIfNeeded(tabState) {
            return
        }

        let wasSelected = selectedTabID == tabID
        if wasSelected {
            leaveFloatingPane(in: tabState, animated: false, reapplyAutoZoom: false)
            clearActiveAutoZoomState(in: tabState, restoreLayout: true, animated: false)
        }

        tabs.remove(at: index)
        removeAgentSessions(in: tabState)

        if wasSelected {
            let nextIndex = min(index, tabs.count - 1)
            selectedTabID = tabs[nextIndex].id
            rebuildWorkspaceLayout()
            if let selectedTabState {
                startPaneControllersIfNeeded(in: selectedTabState)
            }
        } else {
            updateTabStrip()
            updateWindowTitle()
            updateWindowMinimumSize()
        }
    }

    private func removeAgentSessions(in tabState: WorkspaceTabState) {
        for paneID in tabState.paneControllers.keys {
            AgentSessionStore.shared.removeSessions(forPaneID: paneID)
        }
    }

    private func updateSelectedTabTitle(_ title: String) {
        guard let selectedTabState else {
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedTabState.customTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        updateTabStrip()
        updateWindowTitle()
    }

    private func handleTitleChange(for paneID: PaneID) {
        guard let tabState = tabState(containing: paneID) else {
            return
        }

        tabState.paneControllers[paneID]?.updatePresentation(
            isFocused: paneID == tabState.focusedPaneID,
            isFloating: tabState.activeFloatingPaneState?.paneID == paneID
        )
        updateTabStrip()

        if tabState.id == selectedTabID, paneID == tabState.focusedPaneID {
            updateWindowTitle()
        }
    }

    private func handlePaneExit(withID paneID: PaneID) {
        guard let tabState = tabState(containing: paneID) else {
            return
        }

        performClosePane(withID: paneID, in: tabState)
    }

    private func enterFloatingPane(in tabState: WorkspaceTabState, animated: Bool) {
        guard
            tabState.id == selectedTabID,
            tabState.activeFloatingPaneState == nil,
            let paneID = tabState.focusedPaneID,
            let paneController = tabState.paneControllers[paneID]
        else {
            NSSound.beep()
            return
        }

        guard let sourceFrame = renderedPaneFrameInFloatingOverlay(for: paneID, in: tabState) else {
            NSSound.beep()
            return
        }

        let savedSize = tabState.floatingPaneSizes[paneID]
        rootView.setCustomFloatingPaneSize(savedSize)

        tabState.activeFloatingPaneState = ActiveFloatingPaneState(
            paneID: paneID, size: savedSize)
        rootView.installFloatingPaneView(
            paneController.hostView,
            initialFrame: sourceFrame,
            animated: animated
        )
        rebuildWorkspaceLayout(applyAutoZoomAnimated: false)

        let targetFrame = rootView.floatingPaneTargetFrame()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = WorkspaceFloatingPaneConfiguration.animationDuration
                rootView.animateFloatingPaneFrame(to: targetFrame)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.rootView.finishFloatingPaneAnimation()
                    self?.applyFocusedPaneResponder()
                }
            }
        } else {
            rootView.setFloatingPaneFrame(targetFrame)
            rootView.finishFloatingPaneAnimation()
            applyFocusedPaneResponder()
        }
    }

    private func leaveFloatingPane(
        in tabState: WorkspaceTabState,
        animated: Bool,
        reapplyAutoZoom: Bool
    ) {
        guard
            tabState.id == selectedTabID,
            let floatingPaneState = tabState.activeFloatingPaneState,
            let paneController = tabState.paneControllers[floatingPaneState.paneID]
        else {
            tabState.activeFloatingPaneState = nil
            return
        }

        let destinationFrame =
            rootView.placeholderFrame(for: floatingPaneState.paneID)
            ?? paneController.hostView.frame

        if animated {
            rootView.beginFloatingPaneAnimation()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = WorkspaceFloatingPaneConfiguration.animationDuration
                rootView.animateFloatingPaneFrame(to: destinationFrame)
            } completionHandler: { [weak self, weak tabState] in
                Task { @MainActor in
                    guard let self, let tabState else {
                        return
                    }

                    self.finishLeavingFloatingPane(in: tabState, reapplyAutoZoom: reapplyAutoZoom)
                }
            }
        } else {
            rootView.setFloatingPaneFrame(destinationFrame)
            finishLeavingFloatingPane(in: tabState, reapplyAutoZoom: reapplyAutoZoom)
        }
    }

    private func finishLeavingFloatingPane(
        in tabState: WorkspaceTabState,
        reapplyAutoZoom: Bool
    ) {
        if let floatingState = tabState.activeFloatingPaneState,
            let size = floatingState.size
        {
            tabState.floatingPaneSizes[floatingState.paneID] = size
        }

        tabState.activeFloatingPaneState = nil
        rebuildWorkspaceLayout(applyAutoZoomAnimated: reapplyAutoZoom)
        rootView.removeFloatingPaneView()
        applyFocusedPaneResponder()
    }

    private func rebuildWorkspaceLayout(applyAutoZoomAnimated: Bool = false) {
        updateTabStrip()

        guard let tabState = selectedTabState, let layoutNode = tabState.layoutNode else {
            tilingView = nil
            rootView.installRenderedContentView(NSView())
            view.layoutSubtreeIfNeeded()
            updateWindowTitle()
            updateWindowMinimumSize()
            applyFocusedPaneResponder()
            return
        }

        let paneViews = buildPaneViewsDictionary(for: tabState)

        if let tilingView {
            tilingView.setLayoutNode(layoutNode, paneViews: paneViews)
        } else {
            let newTilingView = WorkspaceTilingView()
            newTilingView.onFractionsChange = { [weak self] path, fractions, source in
                self?.updateSplitFractions(
                    at: path, to: fractions, changeSource: source
                )
            }
            tilingView = newTilingView
            newTilingView.setLayoutNode(layoutNode, paneViews: paneViews)
            rootView.installRenderedContentView(newTilingView)
        }

        view.layoutSubtreeIfNeeded()
        if !applyPreservedActiveAutoZoom(in: tabState) {
            applyAutoZoomToFocusedPane(in: tabState, animated: applyAutoZoomAnimated)
        }
        updatePanePresentation(in: tabState)
        updateWindowTitle()
        updateWindowMinimumSize()
        applyFocusedPaneResponder()
    }

    private func buildPaneViewsDictionary(
        for tabState: WorkspaceTabState
    ) -> [PaneID: NSView] {
        var result: [PaneID: NSView] = [:]
        for (paneID, paneController) in tabState.paneControllers {
            if tabState.activeFloatingPaneState?.paneID == paneID {
                result[paneID] = TerminalPanePlaceholderView(paneID: paneID)
            } else {
                result[paneID] = paneController.hostView
            }
        }
        return result
    }

    private func updateSplitFractions(
        at path: [LayoutPathComponent],
        to fractions: [CGFloat],
        changeSource: TilingFractionChangeSource
    ) {
        paneResizeWVCLog.debug(
            "updateSplitFractions path=\(formatPath(path), privacy: .public) fractions=\(formatFractionsWVC(fractions), privacy: .public) source=\(String(describing: changeSource), privacy: .public)"
        )
        guard let tabState = selectedTabState, let layoutNode = tabState.layoutNode else {
            return
        }

        if tabState.activeAutoZoomState?.splitStates.contains(where: { $0.splitPath == path })
            == true
        {
            tabState.activeAutoZoomState = nil
        }

        if changeSource == .userDrag {
            disableAutoResizeForPanesAffectedBySplit(at: path, in: tabState)
        }

        tabState.layoutNode = layoutNode.replacingFractions(at: path, with: fractions)
        updateWindowMinimumSize()
    }

    private func disableAutoResizeForPanesAffectedBySplit(
        at path: [LayoutPathComponent],
        in tabState: WorkspaceTabState
    ) {
        guard let affectedPaneIDs = tabState.layoutNode?.node(at: path)?.paneIDsInTraversalOrder
        else {
            return
        }

        for paneID in affectedPaneIDs {
            tabState.paneAutoResizeConfigurations[paneID]?.isEnabled = false
        }
    }

    private func restoreActiveAutoZoom(in tabState: WorkspaceTabState, animated: Bool) {
        guard tabState.activeAutoZoomState != nil,
            let modelLayoutNode = tabState.layoutNode,
            let tilingView
        else {
            return
        }

        // The model was never modified by auto-zoom, so restoring just means
        // re-applying the model's layout to the tiling view.
        let paneViews = buildPaneViewsDictionary(for: tabState)
        tilingView.setLayoutNode(modelLayoutNode, paneViews: paneViews, animated: animated)
        tabState.activeAutoZoomState = nil
    }

    private func clearActiveAutoZoomState(
        in tabState: WorkspaceTabState,
        restoreLayout: Bool,
        animated: Bool
    ) {
        if restoreLayout {
            restoreActiveAutoZoom(in: tabState, animated: animated)
            return
        }

        tabState.activeAutoZoomState = nil
    }

    private func applyAutoZoomToFocusedPane(in tabState: WorkspaceTabState, animated: Bool) {
        guard tabState.activeFloatingPaneState == nil else {
            return
        }

        guard
            let focusedPaneID = tabState.focusedPaneID,
            let autoResizeConfiguration = tabState.paneAutoResizeConfigurations[focusedPaneID],
            autoResizeConfiguration.isEnabled
        else {
            tabState.activeAutoZoomState = nil
            return
        }

        let targetStates = autoZoomTargetStates(for: focusedPaneID, in: tabState)
        guard !targetStates.isEmpty else {
            tabState.activeAutoZoomState = nil
            return
        }

        tabState.activeAutoZoomState = ActiveAutoZoomState(
            focusedPaneID: focusedPaneID,
            splitStates: targetStates.map { context, _ in
                ActiveAutoZoomSplitState(
                    splitPath: context.splitPath,
                    originalFractions: context.fractions
                )
            }
        )

        applyAutoZoomTargetStates(targetStates, animated: animated)
    }

    private func applyPreservedActiveAutoZoom(in tabState: WorkspaceTabState) -> Bool {
        guard let activeAutoZoomState = tabState.activeAutoZoomState else {
            return false
        }

        let targetStates = autoZoomTargetStates(
            for: activeAutoZoomState.focusedPaneID,
            in: tabState
        )
        guard !targetStates.isEmpty else {
            return false
        }

        applyAutoZoomTargetStates(targetStates, animated: false)
        return true
    }

    private func autoZoomTargetStates(
        for focusedPaneID: PaneID,
        in tabState: WorkspaceTabState
    ) -> [(ParentSplitContext, [CGFloat])] {
        guard
            let layoutNode = tabState.layoutNode,
            let autoResizeConfiguration = tabState.paneAutoResizeConfigurations[focusedPaneID],
            autoResizeConfiguration.isEnabled,
            let tilingView
        else {
            return []
        }

        return layoutNode.ancestorSplitContexts(for: focusedPaneID).compactMap {
            context -> (ParentSplitContext, [CGFloat])? in
            guard let splitNode = layoutNode.node(at: context.splitPath) else {
                return nil
            }

            let focusedRatio = autoResizeConfiguration.ratios[context.axis]
            let proposedFractions = context.replacingFocusedChildFraction(focusedRatio)
            let targetFractions = splitNode.clampedFractions(
                proposedFractions, in: tilingView.bounds.size
            )

            guard targetFractions != context.fractions else {
                return nil
            }

            return (context, targetFractions)
        }
    }

    private func applyAutoZoomTargetStates(
        _ targetStates: [(ParentSplitContext, [CGFloat])],
        animated: Bool
    ) {
        guard let tabState = selectedTabState,
            let modelLayoutNode = tabState.layoutNode,
            let tilingView
        else {
            return
        }

        // Build auto-zoomed layout node for rendering only — the model is NOT updated.
        // This matches the old behavior where splitView.setFractions() only affected visuals.
        var autoZoomedNode = modelLayoutNode
        for (context, targetFractions) in targetStates {
            if let updated = autoZoomedNode.replacingFractions(
                at: context.splitPath, with: targetFractions
            ) {
                autoZoomedNode = updated
            }
        }

        let paneViews = buildPaneViewsDictionary(for: tabState)
        tilingView.setLayoutNode(autoZoomedNode, paneViews: paneViews, animated: animated)
    }

    private func updatePanePresentation(in tabState: WorkspaceTabState) {
        for (paneID, paneController) in tabState.paneControllers {
            paneController.updatePresentation(
                isFocused: paneID == tabState.focusedPaneID,
                isFloating: tabState.activeFloatingPaneState?.paneID == paneID
            )
        }
    }

    private func updateTabStrip() {
        rootView.updateTabItems(
            tabs.map { tabState in
                WorkspaceTabStripItem(
                    id: tabState.id,
                    title: tabState.displayTitle,
                    isSelected: tabState.id == selectedTabID
                )
            }
        )
        updateAgentStatus()
    }

    private var currentWindowPaneIDs: Set<PaneID> {
        Set(tabs.flatMap { $0.paneControllers.keys })
    }

    private func updateAgentStatus() {
        let paneIDs = currentWindowPaneIDs
        let sessions = AgentSessionStore.shared.snapshots(forPaneIDs: paneIDs)
        rootView.updateAgentStatus(
            sessionCount: sessions.count,
            unreadCount: AgentSessionStore.shared.unreadSessionCount(forPaneIDs: paneIDs)
        )
    }

    private func updateAgentManagerPopover() {
        guard agentManagerPopoverController?.isShown == true else {
            return
        }

        agentManagerPopoverController?.updateSessions(
            AgentSessionStore.shared.snapshots(forPaneIDs: currentWindowPaneIDs)
        )
    }

    private func clearEndedAgentSessions() {
        AgentSessionStore.shared.clearEnded(forPaneIDs: currentWindowPaneIDs)
        updateAgentStatus()
        updateAgentManagerPopover()
    }

    private func updateAppearance() {
        rootView.updateAppearance()
        if let window = view.window {
            AppAppearanceDefaults.applyWindowPresentation(
                to: window,
                isWindowHidden: AppAppearanceSettings.isWindowHidden
            )
        }
        for tabState in tabs {
            for paneController in tabState.paneControllers.values {
                paneController.updateAppearance()
            }
        }

        if let selectedTabState {
            updatePanePresentation(in: selectedTabState)
        }
    }

    private func updateWindowTitle() {
        view.window?.title = selectedTabState?.displayTitle ?? "Santty"
    }

    var commandPaletteCommands: [AppCommand] {
        [
            AppCommand(
                id: "pane.split.horizontal",
                title: "Split Horizontally",
                shortcut: KeybindingSettings.displayShortcut(for: .splitPaneHorizontally),
                isEnabled: focusedPaneController?.isLive == true,
                perform: { [weak self] in self?.splitPaneHorizontally(nil) }
            ),
            AppCommand(
                id: "pane.split.vertical",
                title: "Split Vertically",
                shortcut: KeybindingSettings.displayShortcut(for: .splitPaneVertically),
                isEnabled: focusedPaneController?.isLive == true,
                perform: { [weak self] in self?.splitPaneVertically(nil) }
            ),
            AppCommand(
                id: "pane.resize.equalize",
                title: "Equalize Splits",
                shortcut: KeybindingSettings.displayShortcut(for: .equalizePaneSplits),
                isEnabled: canEqualizePaneSplits(),
                perform: { [weak self] in self?.equalizePaneSplits(nil) }
            ),
            AppCommand(
                id: "pane.resize.up",
                title: "Move Divider Up",
                shortcut: KeybindingSettings.displayShortcut(for: .movePaneDividerUp),
                isEnabled: canMovePaneDivider(.up),
                perform: { [weak self] in self?.movePaneDividerUp(nil) }
            ),
            AppCommand(
                id: "pane.resize.down",
                title: "Move Divider Down",
                shortcut: KeybindingSettings.displayShortcut(for: .movePaneDividerDown),
                isEnabled: canMovePaneDivider(.down),
                perform: { [weak self] in self?.movePaneDividerDown(nil) }
            ),
            AppCommand(
                id: "pane.resize.left",
                title: "Move Divider Left",
                shortcut: KeybindingSettings.displayShortcut(for: .movePaneDividerLeft),
                isEnabled: canMovePaneDivider(.left),
                perform: { [weak self] in self?.movePaneDividerLeft(nil) }
            ),
            AppCommand(
                id: "pane.resize.right",
                title: "Move Divider Right",
                shortcut: KeybindingSettings.displayShortcut(for: .movePaneDividerRight),
                isEnabled: canMovePaneDivider(.right),
                perform: { [weak self] in self?.movePaneDividerRight(nil) }
            ),
            AppCommand(
                id: "pane.focus.previous",
                title: "Focus Previous Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusPreviousPane),
                isEnabled: (selectedTabState?.paneControllers.count ?? 0) > 1,
                perform: { [weak self] in self?.focusPreviousPane(nil) }
            ),
            AppCommand(
                id: "pane.focus.next",
                title: "Focus Next Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusNextPane),
                isEnabled: (selectedTabState?.paneControllers.count ?? 0) > 1,
                perform: { [weak self] in self?.focusNextPane(nil) }
            ),
            AppCommand(
                id: "pane.focus.left",
                title: "Focus Left Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusLeftPane),
                isEnabled: (selectedTabState?.paneControllers.count ?? 0) > 1,
                perform: { [weak self] in self?.focusLeftPane(nil) }
            ),
            AppCommand(
                id: "pane.focus.right",
                title: "Focus Right Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusRightPane),
                isEnabled: (selectedTabState?.paneControllers.count ?? 0) > 1,
                perform: { [weak self] in self?.focusRightPane(nil) }
            ),
            AppCommand(
                id: "pane.focus.above",
                title: "Focus Above Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusAbovePane),
                isEnabled: (selectedTabState?.paneControllers.count ?? 0) > 1,
                perform: { [weak self] in self?.focusAbovePane(nil) }
            ),
            AppCommand(
                id: "pane.focus.below",
                title: "Focus Below Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusBelowPane),
                isEnabled: (selectedTabState?.paneControllers.count ?? 0) > 1,
                perform: { [weak self] in self?.focusBelowPane(nil) }
            ),
            AppCommand(
                id: "pane.autoResize",
                title: "Auto Resize",
                shortcut: KeybindingSettings.displayShortcut(for: .autoResizePane),
                isEnabled: focusedPaneController != nil,
                perform: { [weak self] in self?.showAutoResizeSettings(nil) }
            ),
            AppCommand(
                id: "pane.floating.toggle",
                title: "Toggle Floating Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .toggleFloatingPane),
                isEnabled: focusedPaneController != nil,
                perform: { [weak self] in self?.toggleFloatingPane(nil) }
            ),
            AppCommand(
                id: "pane.promptEditor",
                title: "Open Prompt Editor",
                shortcut: KeybindingSettings.displayShortcut(for: .openPromptEditor),
                isEnabled: focusedPaneController?.isLive == true,
                perform: { [weak self] in self?.openPromptEditor(nil) }
            ),
            AppCommand(
                id: "pane.close",
                title: "Close Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .closePane),
                isEnabled: focusedPaneController != nil,
                perform: { [weak self] in self?.closePane(nil) }
            ),
            AppCommand(
                id: "tab.new",
                title: "New Tab",
                shortcut: KeybindingSettings.displayShortcut(for: .newTab),
                isEnabled: true,
                perform: { [weak self] in self?.newTab(nil) }
            ),
            AppCommand(
                id: "tab.close",
                title: "Close Tab",
                shortcut: KeybindingSettings.displayShortcut(for: .closeTab),
                isEnabled: selectedTabState != nil,
                perform: { [weak self] in self?.closeTab(nil) }
            ),
            AppCommand(
                id: "tab.title.change",
                title: "Change Tab Title",
                shortcut: nil,
                isEnabled: selectedTabState != nil,
                perform: { [weak self] in self?.changeTabTitle(nil) }
            ),
            AppCommand(
                id: "tab.focus.previous",
                title: "Previous Tab",
                shortcut: KeybindingSettings.displayShortcut(for: .focusPreviousTab),
                isEnabled: tabs.count > 1,
                perform: { [weak self] in self?.focusPreviousTab(nil) }
            ),
            AppCommand(
                id: "tab.focus.next",
                title: "Next Tab",
                shortcut: KeybindingSettings.displayShortcut(for: .focusNextTab),
                isEnabled: tabs.count > 1,
                perform: { [weak self] in self?.focusNextTab(nil) }
            ),
        ]
    }

    private func updateWindowMinimumSize() {
        let tabChromeHeight =
            WorkspaceLayoutMetrics.workspaceEdgePadding * 2
            + WorkspaceLayoutMetrics.workspaceSectionSpacing
            + WorkspaceLayoutMetrics.tabStripHeight

        guard let layoutNode = selectedTabState?.layoutNode else {
            view.window?.contentMinSize = WorkspaceLayoutMetrics.minimumWindowContentSize
            return
        }

        let minimumSize = layoutNode.minimumSize()
        let paddedMinimumSize = NSSize(
            width: minimumSize.width + WorkspaceLayoutMetrics.workspaceEdgePadding * 2,
            height: minimumSize.height + tabChromeHeight
        )
        view.window?.contentMinSize = NSSize(
            width: max(
                WorkspaceLayoutMetrics.minimumWindowContentSize.width, paddedMinimumSize.width),
            height: max(
                WorkspaceLayoutMetrics.minimumWindowContentSize.height, paddedMinimumSize.height)
        )
    }

    private func applyFocusedPaneResponder() {
        guard hasAppeared, let window = view.window else {
            return
        }

        if let focusedPaneController = selectedTabState?.focusedPaneController {
            window.makeFirstResponder(focusedPaneController.focusTargetView)
            focusedPaneController.fitToSize()
        } else {
            window.makeFirstResponder(rootView)
        }
    }

    func restoreFocusAfterCommandPalette() {
        applyFocusedPaneResponder()
    }

    private func updateAutoResizeConfiguration(
        _ configuration: PaneAutoResizeConfiguration,
        for paneID: PaneID
    ) {
        guard let tabState = selectedTabState, tabState.containsPane(withID: paneID) else {
            return
        }

        restoreActiveAutoZoom(in: tabState, animated: true)
        tabState.paneAutoResizeConfigurations[paneID] = configuration

        if paneID == tabState.focusedPaneID {
            applyAutoZoomToFocusedPane(in: tabState, animated: true)
        }
    }

    private func startPaneControllersIfNeeded(in tabState: WorkspaceTabState) {
        tabState.paneControllers.values.forEach { $0.startIfNeeded() }
    }

    private func tabState(containing paneID: PaneID) -> WorkspaceTabState? {
        tabs.first { $0.containsPane(withID: paneID) }
    }

    private func confirmCloseWindowIfNeeded() -> Bool {
        guard tabs.flatMap({ Array($0.paneControllers.values) }).contains(where: { $0.isLive })
        else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close Window?"
        alert.informativeText = "This will close all running panes in the current window."
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmCloseTabIfNeeded(_ tabState: WorkspaceTabState) -> Bool {
        guard tabState.paneControllers.values.contains(where: { $0.isLive }) else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close Tab?"
        alert.informativeText = "This will close all running panes in the selected tab."
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func requestWindowClose() {
        didRequestWindowCloseForTesting = true

        guard let window = view.window else {
            return
        }

        bypassNextWindowCloseConfirmation = true
        window.performClose(nil)
    }
}

extension WorkspaceViewController {
    func debugLoadForTesting(frame: NSRect = NSRect(x: 0, y: 0, width: 1200, height: 800)) {
        loadViewIfNeeded()
        view.frame = frame
        view.layoutSubtreeIfNeeded()
    }

    var debugLayoutNode: LayoutNode? { selectedTabState?.layoutNode }
    var debugPaneIDsInTraversalOrder: [PaneID] {
        selectedTabState?.layoutNode?.paneIDsInTraversalOrder ?? []
    }
    var debugFocusedPaneID: PaneID? { selectedTabState?.focusedPaneID }
    var debugActiveAutoZoomState: ActiveAutoZoomState? { selectedTabState?.activeAutoZoomState }
    var debugActiveFloatingPaneState: ActiveFloatingPaneState? {
        selectedTabState?.activeFloatingPaneState
    }
    var debugTabIDs: [UUID] { tabs.map(\.id) }
    var debugSelectedTabID: UUID? { selectedTabID }
    var debugDidRequestWindowClose: Bool { didRequestWindowCloseForTesting }
    var debugContentFrame: NSRect { rootView.debugContentFrame }
    var debugTabStripFrame: NSRect { rootView.debugTabStripFrame }
    var debugRenderedContentFrame: NSRect { rootView.debugRenderedContentFrame }
    var debugFloatingPaneFrame: NSRect? { rootView.debugFloatingPaneFrame }
    var debugLastFloatingPaneInitialFrame: NSRect? { rootView.debugLastFloatingPaneInitialFrame }
    var debugCommandSnapshots: [AppCommandSnapshot] {
        commandPaletteCommands.map {
            AppCommandSnapshot(
                id: $0.id,
                title: $0.title,
                shortcut: $0.shortcut,
                isEnabled: $0.isEnabled
            )
        }
    }

    func debugPaneAutoResizeConfiguration(for paneID: PaneID) -> PaneAutoResizeConfiguration? {
        selectedTabState?.paneAutoResizeConfigurations[paneID]
    }

    func debugPaneBorderColor(for paneID: PaneID) -> NSColor? {
        selectedTabState?.paneControllers[paneID]?.debugBorderColor
    }

    func debugPaneBorderWidth(for paneID: PaneID) -> CGFloat? {
        selectedTabState?.paneControllers[paneID]?.debugBorderWidth
    }

    func debugPaneUsesHiddenWindowPresentation(for paneID: PaneID) -> Bool? {
        selectedTabState?.paneControllers[paneID]?.debugUsesHiddenWindowPresentation
    }

    func debugPaneVibrancyBlendingMode(for paneID: PaneID) -> NSVisualEffectView.BlendingMode? {
        selectedTabState?.paneControllers[paneID]?.debugVibrancyBlendingMode
    }

    func debugPaneVibrancyTintAlpha(for paneID: PaneID) -> CGFloat? {
        selectedTabState?.paneControllers[paneID]?.debugVibrancyTintAlpha
    }

    func debugTerminalFrame(for paneID: PaneID) -> NSRect? {
        selectedTabState?.paneControllers[paneID]?.debugTerminalFrame
    }

    func debugTerminalPadding(for paneID: PaneID) -> CGFloat? {
        selectedTabState?.paneControllers[paneID]?.debugTerminalPadding
    }

    func debugPaneBounds(for paneID: PaneID) -> NSRect? {
        selectedTabState?.paneControllers[paneID]?.debugPaneBounds
    }

    func debugRenderedTerminalConfig(for paneID: PaneID) -> String? {
        selectedTabState?.paneControllers[paneID]?.debugRenderedTerminalConfig
    }

    func debugPlaceholderFrame(for paneID: PaneID) -> NSRect? {
        rootView.debugPlaceholderFrame(for: paneID)
    }

    func debugPlaceholderUsesHiddenWindowPresentation(for paneID: PaneID) -> Bool? {
        rootView.debugPlaceholderUsesHiddenWindowPresentation(for: paneID)
    }

    func debugPlaceholderVibrancyBlendingMode(
        for paneID: PaneID
    ) -> NSVisualEffectView.BlendingMode? {
        rootView.debugPlaceholderVibrancyBlendingMode(for: paneID)
    }

    func debugPlaceholderVibrancyTintAlpha(for paneID: PaneID) -> CGFloat? {
        rootView.debugPlaceholderVibrancyTintAlpha(for: paneID)
    }

    func debugSelectedTabBackgroundColor(for tabID: UUID) -> NSColor? {
        rootView.debugSelectedTabBackgroundColor(for: tabID)
    }

    func debugSelectedTabBackground(for tabID: UUID) -> AppAppearanceSettings.ActiveTabBackground? {
        rootView.debugSelectedTabBackground(for: tabID)
    }

    func debugTabUsesHiddenWindowPresentation(for tabID: UUID) -> Bool? {
        rootView.debugTabUsesHiddenWindowPresentation(for: tabID)
    }

    func debugTabIndexText(for tabID: UUID) -> String? {
        rootView.debugTabIndexText(for: tabID)
    }

    func debugTabCloseButtonIsHidden(for tabID: UUID) -> Bool? {
        rootView.debugTabCloseButtonIsHidden(for: tabID)
    }

    func debugSetPaneAutoResizeConfiguration(
        _ configuration: PaneAutoResizeConfiguration,
        for paneID: PaneID
    ) {
        selectedTabState?.paneAutoResizeConfigurations[paneID] = configuration
    }

    func debugFocusPane(withID paneID: PaneID) {
        focusPane(withID: paneID)
    }

    func debugFocusPane(in direction: PaneFocusDirection) {
        switch direction {
        case .left:
            focusLeftPane(nil)
        case .right:
            focusRightPane(nil)
        case .above:
            focusAbovePane(nil)
        case .below:
            focusBelowPane(nil)
        }
    }

    func debugSplitFocusedPane(along axis: SplitAxis) {
        splitFocusedPane(along: axis)
    }

    func debugPerformClosePane(withID paneID: PaneID) {
        performClosePane(withID: paneID)
    }

    func debugSimulatePaneExit(withID paneID: PaneID) {
        tabState(containing: paneID)?
            .paneControllers[paneID]?
            .terminalDidClose(processAlive: false)
    }

    func debugUpdateSplitFractions(at path: [LayoutPathComponent], to fractions: [CGFloat]) {
        guard let tabState = selectedTabState,
            var layoutNode = tabState.layoutNode,
            let tilingView
        else {
            return
        }

        if let updated = layoutNode.replacingFractions(at: path, with: fractions) {
            layoutNode = updated
        }

        tabState.layoutNode = layoutNode
        let paneViews = buildPaneViewsDictionary(for: tabState)
        tilingView.setLayoutNode(layoutNode, paneViews: paneViews)
        updateSplitFractions(at: path, to: fractions, changeSource: .userDrag)
    }

    func debugRenderedSplitFractions(at path: [LayoutPathComponent]) -> [CGFloat]? {
        tilingView?.debugCurrentFractions(at: path)
    }

    func debugRenderedSplitChildFrame(
        at path: [LayoutPathComponent],
        childIndex: Int
    ) -> NSRect? {
        tilingView?.debugNodeFrame(at: path + [.child(childIndex)])
    }

    func debugNewTab() {
        newTab(nil)
    }

    func debugSelectTab(withID tabID: UUID) {
        selectTab(withID: tabID)
    }

    func debugFocusTab(at index: Int) {
        focusTab(at: index)
    }

    func debugMoveTab(withID tabID: UUID, to destinationIndex: Int) {
        moveTab(withID: tabID, to: destinationIndex)
    }

    func debugCloseTab(withID tabID: UUID) {
        closeTab(withID: tabID, bypassTabConfirmation: true)
    }

    func debugSetSelectedTabTitle(_ title: String) {
        updateSelectedTabTitle(title)
    }

    func debugSetPaneTitle(_ title: String, for paneID: PaneID) {
        guard
            let tabState = tabState(containing: paneID),
            let paneController = tabState.paneControllers[paneID]
        else {
            return
        }

        paneController.terminalDidChangeTitle(title)
    }

    func debugSetPaneWorkingDirectory(_ workingDirectory: String, for paneID: PaneID) {
        guard
            let tabState = tabState(containing: paneID),
            let paneController = tabState.paneControllers[paneID]
        else {
            return
        }

        paneController.terminalDidChangeWorkingDirectory(workingDirectory)
    }

    func debugPerformCommand(withID commandID: String) {
        guard
            let command = commandPaletteCommands.first(where: { $0.id == commandID && $0.isEnabled }
            )
        else {
            return
        }

        command.perform()
    }

    func debugToggleFloatingPane(animated: Bool = false) {
        guard let tabState = selectedTabState, tabState.focusedPaneController != nil else {
            return
        }

        if tabState.activeFloatingPaneState != nil {
            leaveFloatingPane(in: tabState, animated: animated, reapplyAutoZoom: true)
        } else {
            enterFloatingPane(in: tabState, animated: animated)
        }
    }

    func debugLayoutNode(forTabID tabID: UUID) -> LayoutNode? {
        tabs.first(where: { $0.id == tabID })?.layoutNode
    }

    func debugPaneIDsInTraversalOrder(forTabID tabID: UUID) -> [PaneID] {
        tabs.first(where: { $0.id == tabID })?.layoutNode?.paneIDsInTraversalOrder ?? []
    }

    func debugFocusedPaneID(forTabID tabID: UUID) -> PaneID? {
        tabs.first(where: { $0.id == tabID })?.focusedPaneID
    }

    func debugDisplayTitle(forTabID tabID: UUID) -> String? {
        tabs.first(where: { $0.id == tabID })?.displayTitle
    }
}
