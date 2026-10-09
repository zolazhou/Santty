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

private enum PaneMoveDirection {
    case up
    case down
    case left
    case right

    var focusDirection: PaneFocusDirection {
        switch self {
        case .left:
            .left
        case .right:
            .right
        case .up:
            .above
        case .down:
            .below
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

    func handleCLIRequest(_ request: CLIRequest) throws -> CLIResponse {
        try request.validate()
        if request.command == "list" {
            return CLIResponse(tabs: tabs.map { tab in
                CLITab(id: tab.id, title: tab.displayTitle, isSelected: tab.id == selectedTabID,
                    panes: tab.paneControllers.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { pane in
                        let terminal = pane as? TerminalPaneController
                        return CLIPane(id: pane.id, title: pane.displayTitle, name: pane.name,
                            kind: terminal != nil ? "terminal" : pane is NotesPaneController ? "notes" : "browser",
                            cwd: terminal?.workingDirectoryForNewPane,
                            foregroundProcessGroupID: terminal?.foregroundProcessID,
                            isFocused: tab.focusedPaneID == pane.id, isLive: pane.isLive,
                            isDetached: tab.isPaneDetached(pane.id))
                    })
            })
        }
        guard let id = request.paneID,
            let pane = tabs.lazy.compactMap({ $0.paneControllers[id] }).first
        else { throw CLIError("Pane not found. Run santty list --json to refresh pane IDs.") }
        guard let terminal = pane as? TerminalPaneController else {
            throw CLIError("Only terminal panes support reading text.")
        }
        return try terminal.readForCLI(request)
    }
    private var tilingView: WorkspaceTilingView?
    private var autoResizePanelController: PaneAutoResizePanelController?
    private var hasAppeared = false
    private var bypassNextWindowCloseConfirmation = false
    private var didRequestWindowCloseForTesting = false
    private var appearanceSettingsObserver: NSObjectProtocol?
    private var terminalSettingsObserver: NSObjectProtocol?
    private var agentSessionObserver: NSObjectProtocol?
    private var agentManagerPopoverController: AgentManagerPopoverController?
    private var animatingDetachedPaneIDs: Set<PaneID> = []
    private var paneNameRevealTask: Task<Void, Never>?
    private var paneNamesVisible = false
    private var isCommandHeld = false
    private var isClosingNotes = false
    private var paneNameFocusObservers: [NSObjectProtocol] = []

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

    private var focusedPaneController: (any PaneControlling)? {
        selectedTabState?.focusedPaneController
    }

    private var focusedTerminalPaneController: TerminalPaneController? {
        focusedPaneController as? TerminalPaneController
    }

    private var focusedBrowserPaneController: BrowserPaneController? {
        focusedPaneController as? BrowserPaneController
    }

    private var focusedPaneIsTiled: Bool {
        guard let tabState = selectedTabState, let focusedPaneID = tabState.focusedPaneID else {
            return false
        }

        return tabState.isPaneTiled(focusedPaneID)
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
        for notification in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            paneNameFocusObservers.append(NotificationCenter.default.addObserver(
                forName: notification, object: nil, queue: .main
            ) { [weak self] note in
                let isAppDeactivation = note.name == NSApplication.didResignActiveNotification
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if isAppDeactivation || window === self.view.window
                    {
                        self.cancelPaneNameReveal()
                        self.isCommandHeld = false
                    }
                }
            })
        }
    }

    deinit {
        MainActor.assumeIsolated {
            paneNameRevealTask?.cancel()
            for observer in paneNameFocusObservers {
                NotificationCenter.default.removeObserver(observer)
            }
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

    override func viewWillDisappear() {
        super.viewWillDisappear()
        cancelPaneNameReveal()
        isCommandHeld = false
    }

    func handlePaneNameEvent(_ event: NSEvent) {
        let wasCommandHeld = isCommandHeld
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option, .function])
        isCommandHeld = modifiers.contains(.command)
        guard event.type == .flagsChanged, modifiers == [.command] else {
            cancelPaneNameReveal()
            return
        }
        // A shortcut or another modifier suppresses this hold until Cmd is released.
        guard !wasCommandHeld else { return }
        paneNameRevealTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            self?.setPaneNamesVisible(true)
        }
    }

    private func cancelPaneNameReveal() {
        paneNameRevealTask?.cancel()
        paneNameRevealTask = nil
        setPaneNamesVisible(false)
    }

    private func setPaneNamesVisible(_ visible: Bool) {
        paneNamesVisible = visible
        for tab in tabs {
            for pane in tab.paneControllers.values {
                pane.setNameVisible(visible && tab.id == selectedTabID)
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let keyWindow = NSApp.keyWindow, keyWindow is NSPanel, !keyWindow.canBecomeMain {
            return false
        }
        return switch menuItem.action {
        case #selector(splitPaneHorizontally(_:)), #selector(splitPaneVertically(_:)):
            if focusedTerminalPaneController != nil {
                focusedTerminalPaneController?.isLive == true && focusedPaneIsTiled
            } else {
                focusedPaneController != nil && focusedPaneIsTiled
            }
        case #selector(newBrowserPane(_:)), #selector(newNotesPane(_:)):
            focusedPaneController != nil && focusedPaneIsTiled
        case #selector(focusBrowserLocationBar(_:)):
            focusedBrowserPaneController != nil
        case #selector(convertFocusedPaneToBrowser(_:)):
            focusedTerminalPaneController != nil && focusedPaneIsTiled
        case #selector(convertFocusedPaneToTerminal(_:)):
            focusedBrowserPaneController != nil && focusedPaneIsTiled
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
        case #selector(movePaneUp(_:)):
            canMovePane(.up)
        case #selector(movePaneDown(_:)):
            canMovePane(.down)
        case #selector(movePaneLeft(_:)):
            canMovePane(.left)
        case #selector(movePaneRight(_:)):
            canMovePane(.right)
        case #selector(closePane(_:)), #selector(renamePane(_:)):
            focusedPaneController != nil
        case #selector(showAutoResizeSettings(_:)):
            focusedPaneController != nil && focusedPaneIsTiled
        case #selector(toggleFloatingPane(_:)):
            canToggleFloatingPane()
        case #selector(detachPane(_:)):
            canDetachFocusedPane()
        case #selector(attachDetachedPane(_:)):
            canAttachFocusedDetachedPane()
        case #selector(toggleDetachedPaneAtIndex(_:)):
            if let detachedPaneIDs = selectedTabState?.detachedPaneIDs,
                detachedPaneIDs.indices.contains(menuItem.tag)
            {
                !animatingDetachedPaneIDs.contains(detachedPaneIDs[menuItem.tag])
            } else {
                false
            }
        case #selector(openPromptEditor(_:)):
            focusedTerminalPaneController?.isLive == true
        case #selector(enterScrollMode(_:)):
            focusedTerminalPaneController?.isLive == true
                && focusedTerminalPaneController?.isScrollModeActive == false
        case #selector(focusNextPane(_:)), #selector(focusPreviousPane(_:)),
            #selector(focusLeftPane(_:)), #selector(focusRightPane(_:)),
            #selector(focusAbovePane(_:)), #selector(focusBelowPane(_:)):
            focusedPaneIsTiled && (selectedTabState?.tiledPaneIDsInTraversalOrder.count ?? 0) > 1
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

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        guard window is MainWindow else { return defaultFrame }
        return window.screen?.visibleFrame ?? defaultFrame
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        if bypassNextWindowCloseConfirmation {
            bypassNextWindowCloseConfirmation = false
            return true
        }

        guard confirmCloseWindowIfNeeded() else { return false }
        guard hasNotesPanes else { return true }
        guard !isClosingNotes else { return false }
        isClosingNotes = true
        Task { [weak self] in
            guard let self else { return }
            defer { isClosingNotes = false }
            if await prepareNotesToClose() { requestWindowClose() }
        }
        return false
    }

    @objc func splitPaneHorizontally(_: Any?) {
        splitFocusedPane(along: .horizontal)
    }

    @objc func splitPaneVertically(_: Any?) {
        splitFocusedPane(along: .vertical)
    }

    @objc func newBrowserPane(_: Any?) {
        splitFocusedPane(along: .horizontal) {
            self.makeBrowserPaneController()
        }
    }

    @objc func newNotesPane(_: Any?) {
        splitFocusedPane(along: .horizontal) { self.makeNotesPaneController() }
    }

    func handleNotesKeyEvent(_ event: NSEvent) -> Bool {
        guard let pane = focusedPaneController as? NotesPaneController,
            let responder = view.window?.firstResponder as? NSView,
            responder.isDescendant(of: pane.hostView)
        else { return false }
        return pane.content.handleCommand(event)
    }

    @objc func focusBrowserLocationBar(_: Any?) {
        guard let focusedBrowserPaneController else {
            NSSound.beep()
            return
        }

        focusedBrowserPaneController.focusLocationBar()
    }

    @objc func convertFocusedPaneToBrowser(_: Any?) {
        guard selectedTabState?.focusedPaneController is TerminalPaneController,
            let paneID = selectedTabState?.focusedPaneID
        else {
            NSSound.beep()
            return
        }

        replaceFocusedPane(with: makeBrowserPaneController(id: paneID))
    }

    @objc func convertFocusedPaneToTerminal(_: Any?) {
        guard selectedTabState?.focusedPaneController is BrowserPaneController,
            let paneID = selectedTabState?.focusedPaneID
        else {
            NSSound.beep()
            return
        }

        replaceFocusedPane(with: makeTerminalPaneController(id: paneID))
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

    @objc func movePaneUp(_: Any?) {
        movePane(.up)
    }

    @objc func movePaneDown(_: Any?) {
        movePane(.down)
    }

    @objc func movePaneLeft(_: Any?) {
        movePane(.left)
    }

    @objc func movePaneRight(_: Any?) {
        movePane(.right)
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
        guard let tabState = selectedTabState else {
            NSSound.beep()
            return
        }

        if tabState.activeDetachedPaneID != nil {
            hideActiveDetachedPane(in: tabState, animated: true, reapplyAutoZoom: true)
            return
        }

        guard
            let focusedPaneID = tabState.focusedPaneID,
            tabState.focusedPaneController != nil,
            tabState.isPaneTiled(focusedPaneID)
        else {
            NSSound.beep()
            return
        }

        if tabState.activeFloatingPaneState != nil {
            leaveFloatingPane(in: tabState, animated: true, reapplyAutoZoom: true)
        } else {
            enterFloatingPane(in: tabState, animated: true)
        }
    }

    @objc func detachPane(_: Any?) {
        detachFocusedPane(animated: true)
    }

    @objc func attachDetachedPane(_: Any?) {
        attachFocusedDetachedPane(animated: true)
    }

    @objc func toggleDetachedPaneAtIndex(_ sender: Any?) {
        let index: Int
        if let menuItem = sender as? NSMenuItem {
            index = menuItem.tag
        } else if let control = sender as? NSControl {
            index = control.tag
        } else {
            return
        }

        toggleDetachedPane(at: index, animated: true)
    }

    @objc func openPromptEditor(_: Any?) {
        guard
            let window = view.window,
            let paneController = focusedTerminalPaneController,
            paneController.isLive
        else {
            NSSound.beep()
            return
        }

        paneController.showPromptEditor(relativeTo: window)
    }

    @objc func enterScrollMode(_: Any?) {
        guard let paneController = focusedTerminalPaneController, paneController.isLive else {
            NSSound.beep()
            return
        }

        paneController.enterScrollMode()
    }

    func handleScrollModeKeyEvent(_ event: NSEvent) -> Bool {
        focusedTerminalPaneController?.handleScrollModeKeyEvent(event) ?? false
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

    @objc func renamePane(_: Any?) {
        guard let pane = focusedPaneController else {
            NSSound.beep()
            return
        }
        cancelPaneNameReveal()
        let alert = NSAlert()
        alert.messageText = "Rename Pane"
        alert.informativeText = "Hold Command to show pane names. Leave empty to remove the name."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.usesSingleLineMode = true
        field.stringValue = pane.name ?? ""
        field.placeholderString = "Pane name"
        field.selectText(nil)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updatePaneName(field.stringValue, for: pane)
    }

    private func updatePaneName(_ name: String, for pane: any PaneControlling) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        pane.name = trimmed.isEmpty ? nil : trimmed
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
        let paneController: any PaneControlling = makeTerminalPaneController()
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

    private func makeTerminalPaneController(
        id: PaneID = UUID(),
        workingDirectory: String? = nil
    ) -> TerminalPaneController {
        let paneController = TerminalPaneController(id: id, workingDirectory: workingDirectory)
        paneController.updateAppearance()

        paneController.onFocusRequest = { [weak self] paneID in
            self?.handlePaneFocusRequest(withID: paneID)
        }

        paneController.onTitleChange = { [weak self] paneID in
            self?.handleTitleChange(for: paneID)
        }

        paneController.onExit = { [weak self] paneID in
            self?.handlePaneExit(withID: paneID)
        }

        return paneController
    }

    private func makeBrowserPaneController(id: PaneID = UUID()) -> BrowserPaneController {
        let paneController = BrowserPaneController(id: id)
        paneController.updateAppearance()

        paneController.onFocusRequest = { [weak self] paneID in
            self?.handlePaneFocusRequest(withID: paneID)
        }

        paneController.onTitleChange = { [weak self] paneID in
            self?.handleTitleChange(for: paneID)
        }

        return paneController
    }

    private func makeNotesPaneController() -> NotesPaneController {
        let pane = NotesPaneController()
        pane.onFocusRequest = { [weak self] in self?.handlePaneFocusRequest(withID: $0) }
        pane.onTitleChange = { [weak self] in self?.handleTitleChange(for: $0) }
        return pane
    }

    private var notesPanes: [NotesPaneController] {
        tabs.flatMap { $0.paneControllers.values.compactMap { $0 as? NotesPaneController } }
    }

    var hasNotesPanes: Bool { !notesPanes.isEmpty }

    func prepareNotesToClose(_ panes: [NotesPaneController]? = nil) async -> Bool {
        for pane in panes ?? notesPanes {
            guard await pane.content.prepareToClose() else {
                focusPaneLocatingTab(withID: pane.id)
                NSSound.beep()
                return false
            }
        }
        return true
    }

    private func applyTerminalSettingsToPanes() {
        for tabState in tabs {
            for case let paneController as TerminalPaneController in tabState.paneControllers.values
            {
                paneController.applyTerminalSettings()
            }
        }
    }

    private func splitFocusedPane(along axis: SplitAxis) {
        guard let focusedPaneController, focusedPaneIsTiled else {
            NSSound.beep()
            return
        }

        if let focusedTerminalPaneController {
            guard focusedTerminalPaneController.isLive else {
                NSSound.beep()
                return
            }

            splitFocusedPane(along: axis) {
                self.makeTerminalPaneController(
                    workingDirectory: focusedTerminalPaneController.workingDirectoryForNewPane
                )
            }
        } else {
            splitFocusedPane(along: axis) {
                self.makeTerminalPaneController()
            }
        }
    }

    private func splitFocusedPane(
        along axis: SplitAxis,
        makeNewPaneController: () -> any PaneControlling
    ) {
        guard
            let tabState = selectedTabState,
            tabState.focusedPaneController != nil,
            let layoutNode = tabState.layoutNode,
            let focusedPaneID = tabState.focusedPaneID,
            tabState.isPaneTiled(focusedPaneID)
        else {
            NSSound.beep()
            return
        }

        leaveFloatingPane(in: tabState, animated: false, reapplyAutoZoom: false)
        clearActiveAutoZoomState(in: tabState, restoreLayout: false, animated: false)

        let newPaneController = makeNewPaneController()
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

    private func replaceFocusedPane(with newPaneController: any PaneControlling) {
        guard
            let tabState = selectedTabState,
            let focusedPaneID = tabState.focusedPaneID,
            tabState.focusedPaneController != nil,
            tabState.isPaneTiled(focusedPaneID)
        else {
            NSSound.beep()
            return
        }

        leaveFloatingPane(in: tabState, animated: false, reapplyAutoZoom: false)
        clearActiveAutoZoomState(in: tabState, restoreLayout: false, animated: false)

        if tabState.paneControllers[focusedPaneID] is TerminalPaneController {
            AgentSessionStore.shared.removeSessions(forPaneID: focusedPaneID)
        }

        newPaneController.name = tabState.paneControllers[focusedPaneID]?.name
        tabState.paneControllers[focusedPaneID] = newPaneController
        tabState.paneAutoResizeConfigurations[focusedPaneID] =
            WorkspaceFocusZoomConfiguration.defaultAutoResizeConfiguration
        tabState.focusedPaneID = focusedPaneID
        tabState.markPaneFocused(focusedPaneID)

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
        (selectedTabState?.tiledPaneIDsInTraversalOrder.count ?? 0) > 1
    }

    private func movePaneDivider(_ direction: PaneDividerMoveDirection) {
        if let tabState = selectedTabState,
            tabState.activeFloatingPaneState != nil || tabState.activeDetachedPaneID != nil
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
            in: target.tilingView.bounds.size,
            dividerThickness: AppAppearanceSettings.workspaceDividerThickness
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
        if selectedTabState?.activeFloatingPaneState != nil
            || selectedTabState?.activeDetachedPaneID != nil
        {
            return true
        }
        return focusedResizeTarget(for: direction.axis) != nil
    }

    private func movePane(_ direction: PaneMoveDirection) {
        guard
            let tabState = selectedTabState,
            let layoutNode = tabState.layoutNode,
            let focusedPaneID = tabState.focusedPaneID,
            tabState.focusedPaneController != nil,
            tabState.isPaneTiled(focusedPaneID),
            tabState.activeFloatingPaneState == nil,
            tabState.activeDetachedPaneID == nil
        else {
            NSSound.beep()
            return
        }

        guard
            let targetPaneID = directionalTiledPaneTarget(
                from: focusedPaneID,
                direction: direction.focusDirection,
                in: tabState
            ),
            let updatedLayoutNode = layoutNode.swappingPane(focusedPaneID, with: targetPaneID)
        else {
            NSSound.beep()
            return
        }

        restoreActiveAutoZoom(in: tabState, animated: false)
        tabState.layoutNode = updatedLayoutNode
        rebuildWorkspaceLayout(applyAutoZoomAnimated: true)
    }

    private func canMovePane(_ direction: PaneMoveDirection) -> Bool {
        guard
            let tabState = selectedTabState,
            let focusedPaneID = tabState.focusedPaneID,
            tabState.focusedPaneController != nil,
            tabState.isPaneTiled(focusedPaneID),
            tabState.activeFloatingPaneState == nil,
            tabState.activeDetachedPaneID == nil
        else {
            return false
        }

        return directionalTiledPaneTarget(
            from: focusedPaneID,
            direction: direction.focusDirection,
            in: tabState
        ) != nil
    }

    private func resizeFloatingPane(
        in tabState: WorkspaceTabState,
        direction: PaneDividerMoveDirection
    ) {
        let activePaneID: PaneID
        let floatingState = tabState.activeFloatingPaneState
        if let state = floatingState {
            activePaneID = state.paneID
        } else if let detachedPaneID = tabState.activeDetachedPaneID {
            activePaneID = detachedPaneID
        } else {
            return
        }

        let step = WorkspaceFloatingPaneConfiguration.resizeStep

        let currentSize: NSSize = {
            if let existing = floatingState?.size {
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

        if var floatingState {
            floatingState.size = newSize
            tabState.activeFloatingPaneState = floatingState
        }
        tabState.floatingPaneSizes[activePaneID] = newSize
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

    private func performClosePane(withID paneID: PaneID, in tabState: WorkspaceTabState, notesPrepared: Bool = false) {
        if !notesPrepared, let pane = tabState.paneControllers[paneID] as? NotesPaneController {
            guard !isClosingNotes else { return }
            isClosingNotes = true
            Task { [weak self] in
                guard let self else { return }
                defer { isClosingNotes = false }
                if await prepareNotesToClose([pane]) {
                    performClosePane(withID: paneID, in: tabState, notesPrepared: true)
                }
            }
            return
        }
        if tabState.isPaneDetached(paneID) {
            if tabState.activeDetachedPaneID == paneID {
                hideActiveDetachedPane(in: tabState, animated: false, reapplyAutoZoom: false)
            }
            removePaneControllerState(for: paneID, in: tabState)
            tabState.detachedPaneIDs.removeAll { $0 == paneID }
            if tabState.focusedPaneID == paneID {
                tabState.focusedPaneID = tabState.lastFocusedTiledPaneID
            }

            if tabState.paneControllers.isEmpty {
                closeTab(withID: tabState.id, bypassTabConfirmation: true)
                return
            }

            if tabState.id == selectedTabID {
                rebuildWorkspaceLayout(applyAutoZoomAnimated: true)
            } else {
                updateTabStrip()
            }
            return
        }

        guard let layoutNode = tabState.layoutNode,
            let closePaneResult = layoutNode.closingPane(paneID)
        else {
            return
        }

        leaveFloatingPane(in: tabState, animated: false, reapplyAutoZoom: false)
        clearActiveAutoZoomState(in: tabState, restoreLayout: false, animated: false)

        removePaneControllerState(for: paneID, in: tabState)

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

    private func removePaneControllerState(for paneID: PaneID, in tabState: WorkspaceTabState) {
        tabState.paneControllers.removeValue(forKey: paneID)
        tabState.paneAutoResizeConfigurations.removeValue(forKey: paneID)
        tabState.floatingPaneSizes.removeValue(forKey: paneID)
        tabState.removePaneFromFocusHistory(paneID)
        AgentSessionStore.shared.removeSessions(forPaneID: paneID)
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

    private func handlePaneFocusRequest(withID paneID: PaneID) {
        guard let tabState = tabState(containing: paneID) else {
            return
        }

        if tabState.id != selectedTabID {
            selectTab(withID: tabState.id)
        }

        if tabState.id == selectedTabID,
            tabState.activeFloatingPaneState != nil,
            tabState.activeFloatingPaneState?.paneID != paneID
        {
            clearFloatingPaneImmediately(in: tabState, reapplyAutoZoom: false)
        }

        focusPane(withID: paneID)
    }

    private func focusPane(withID paneID: PaneID) {
        guard let tabState = selectedTabState, tabState.containsPane(withID: paneID) else {
            return
        }

        if let activeFloatingPaneID = tabState.activeFloatingPaneState?.paneID,
            paneID != activeFloatingPaneID
        {
            clearFloatingPaneImmediately(in: tabState, reapplyAutoZoom: false)
        }

        guard paneID != tabState.focusedPaneID else {
            return
        }

        (tabState.focusedPaneController as? TerminalPaneController)?.exitScrollMode()

        if tabState.isPaneDetached(paneID) {
            if let index = tabState.detachedPaneIDs.firstIndex(of: paneID) {
                showDetachedPane(at: index, animated: true)
            }
            return
        }

        if tabState.activeFloatingPaneState != nil {
            leaveFloatingPane(in: tabState, animated: false, reapplyAutoZoom: false)
        }
        hideActiveDetachedPane(in: tabState, animated: false, reapplyAutoZoom: false)
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
            let targetPaneID = directionalTiledPaneTarget(
                from: focusedPaneID,
                direction: direction,
                in: tabState
            )
        else {
            return
        }

        focusPane(withID: targetPaneID)
    }

    private func directionalTiledPaneTarget(
        from focusedPaneID: PaneID,
        direction: PaneFocusDirection,
        in tabState: WorkspaceTabState
    ) -> PaneID? {
        guard let focusedFrame = renderedPaneFrame(for: focusedPaneID, in: tabState) else {
            return nil
        }

        return tabState.paneControllers
            .compactMap { paneID, _ -> DirectionalPaneCandidate? in
                guard paneID != focusedPaneID,
                    tabState.isPaneTiled(paneID),
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

        cancelPaneNameReveal()

        if tabID == selectedTabID {
            if let selectedTabState {
                startPaneControllersIfNeeded(in: selectedTabState)
            }
            rebuildWorkspaceLayout()
            return
        }


        (selectedTabState?.focusedPaneController as? TerminalPaneController)?.exitScrollMode()

        if let currentTabState = selectedTabState {
            suspendActiveFloatingPresentation(in: currentTabState)
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

    private func closeTab(withID tabID: UUID, bypassTabConfirmation: Bool = false, notesPrepared: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }

        let tabState = tabs[index]
        let notes = tabState.paneControllers.values.compactMap { $0 as? NotesPaneController }
        if !notesPrepared, !notes.isEmpty {
            guard !isClosingNotes else { return }
            isClosingNotes = true
            Task { [weak self] in
                guard let self else { return }
                defer { isClosingNotes = false }
                if await prepareNotesToClose(notes) {
                    closeTab(withID: tabID, bypassTabConfirmation: bypassTabConfirmation, notesPrepared: true)
                }
            }
            return
        }

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
            hideActiveDetachedPane(in: tabState, animated: false, reapplyAutoZoom: false)
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
                || tabState.activeDetachedPaneID == paneID
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

    private func canDetachFocusedPane() -> Bool {
        guard let tabState = selectedTabState,
            let focusedPaneID = tabState.focusedPaneID,
            tabState.isPaneTiled(focusedPaneID)
        else {
            return false
        }

        return tabState.detachedPaneIDs.count < 9
    }

    private func canAttachFocusedDetachedPane() -> Bool {
        guard let tabState = selectedTabState,
            let focusedPaneID = tabState.focusedPaneID
        else {
            return false
        }

        return tabState.activeDetachedPaneID == focusedPaneID
            && tabState.isPaneDetached(focusedPaneID)
    }

    private func canToggleFloatingPane() -> Bool {
        guard let tabState = selectedTabState else {
            return false
        }

        if let activeDetachedPaneID = tabState.activeDetachedPaneID {
            return !animatingDetachedPaneIDs.contains(activeDetachedPaneID)
        }

        guard let focusedPaneID = tabState.focusedPaneID else {
            return false
        }

        return tabState.focusedPaneController != nil
            && tabState.isPaneTiled(focusedPaneID)
    }

    private func detachFocusedPane(animated: Bool) {
        guard
            let tabState = selectedTabState,
            let paneID = tabState.focusedPaneID,
            tabState.isPaneTiled(paneID),
            let layoutNode = tabState.layoutNode,
            let paneController = tabState.paneControllers[paneID],
            tabState.detachedPaneIDs.count < 9
        else {
            NSSound.beep()
            return
        }

        if tabState.activeFloatingPaneState?.paneID == paneID {
            leaveFloatingPane(in: tabState, animated: false, reapplyAutoZoom: false)
        }

        guard let sourceFrame = renderedPaneFrameInFloatingOverlay(for: paneID, in: tabState),
            let closePaneResult = layoutNode.closingPane(paneID)
        else {
            NSSound.beep()
            return
        }

        clearActiveAutoZoomState(in: tabState, restoreLayout: false, animated: false)
        tabState.layoutNode = closePaneResult.root
        tabState.detachedPaneIDs.append(paneID)
        tabState.focusedPaneID = closePaneResult.promotedPaneID ?? tabState.lastFocusedTiledPaneID
        tabState.removePaneFromFocusHistory(paneID)
        if animated {
            animatingDetachedPaneIDs.insert(paneID)
        }

        rebuildWorkspaceLayout(applyAutoZoomAnimated: true)
        rootView.layoutSubtreeIfNeeded()

        let destinationFrame = rootView.detachedPaneStatusCellFrame(for: paneID) ?? sourceFrame
        rootView.installFloatingPaneView(
            paneController.hostView,
            initialFrame: sourceFrame,
            animated: animated
        )

        if animated {
            rootView.beginFloatingPaneAnimation()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = WorkspaceFloatingPaneConfiguration.animationDuration
                rootView.animateFloatingPaneFrame(to: destinationFrame)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.animatingDetachedPaneIDs.remove(paneID)
                    self?.rootView.removeFloatingPaneView()
                    self?.rebuildWorkspaceLayout(applyAutoZoomAnimated: true)
                }
            }
        } else {
            rootView.setFloatingPaneFrame(destinationFrame)
            rootView.removeFloatingPaneView()
            rebuildWorkspaceLayout(applyAutoZoomAnimated: true)
        }
    }

    private func attachFocusedDetachedPane(animated: Bool) {
        guard
            let tabState = selectedTabState,
            let paneID = tabState.focusedPaneID,
            tabState.isPaneDetached(paneID)
        else {
            NSSound.beep()
            return
        }

        if tabState.activeDetachedPaneID == paneID, animated {
            hideActiveDetachedPane(in: tabState, animated: true, reapplyAutoZoom: false) {
                self.finishAttachingDetachedPane(withID: paneID, in: tabState)
            }
        } else {
            hideActiveDetachedPane(in: tabState, animated: false, reapplyAutoZoom: false)
            finishAttachingDetachedPane(withID: paneID, in: tabState)
        }
    }

    private func finishAttachingDetachedPane(withID paneID: PaneID, in tabState: WorkspaceTabState)
    {
        guard tabState.isPaneDetached(paneID) else {
            return
        }

        tabState.detachedPaneIDs.removeAll { $0 == paneID }
        if let layoutNode = tabState.layoutNode,
            let targetPaneID = tabState.lastFocusedTiledPaneID ?? layoutNode.firstPaneID,
            let updatedLayoutNode = layoutNode.insertingSplit(
                for: targetPaneID,
                axis: .horizontal,
                newPaneID: paneID
            )
        {
            tabState.layoutNode = updatedLayoutNode
        } else {
            tabState.layoutNode = .panel(paneID)
        }

        tabState.focusedPaneID = paneID
        tabState.markPaneFocused(paneID)
        rebuildWorkspaceLayout(applyAutoZoomAnimated: true)
    }

    private func toggleDetachedPane(at index: Int, animated: Bool) {
        guard let tabState = selectedTabState,
            tabState.detachedPaneIDs.indices.contains(index)
        else {
            NSSound.beep()
            return
        }

        let paneID = tabState.detachedPaneIDs[index]
        guard !animatingDetachedPaneIDs.contains(paneID) else {
            return
        }

        if tabState.activeDetachedPaneID == paneID {
            hideActiveDetachedPane(in: tabState, animated: animated, reapplyAutoZoom: true)
        } else {
            showDetachedPane(at: index, animated: animated)
        }
    }

    private func showDetachedPane(at index: Int, animated: Bool) {
        guard
            let tabState = selectedTabState,
            tabState.detachedPaneIDs.indices.contains(index),
            let paneController = tabState.paneControllers[tabState.detachedPaneIDs[index]]
        else {
            NSSound.beep()
            return
        }

        let paneID = paneController.id
        guard !animatingDetachedPaneIDs.contains(paneID) else {
            return
        }

        if let activeDetachedPaneID = tabState.activeDetachedPaneID,
            activeDetachedPaneID != paneID
        {
            hideActiveDetachedPane(in: tabState, animated: animated, reapplyAutoZoom: false) {
                self.showDetachedPane(at: index, animated: animated)
            }
            return
        }

        restoreActiveAutoZoom(in: tabState, animated: animated)
        tabState.activeDetachedPaneID = paneID
        tabState.focusedPaneID = paneID
        if animated {
            animatingDetachedPaneIDs.insert(paneID)
        }
        rootView.setCustomFloatingPaneSize(tabState.floatingPaneSizes[paneID])
        updatePanePresentation(in: tabState)
        updateTabStrip()
        updateWindowTitle()
        rootView.layoutSubtreeIfNeeded()

        let sourceFrame =
            rootView.detachedPaneStatusCellFrame(for: paneID)
            ?? rootView.floatingPaneTargetFrame()
        rootView.installFloatingPaneView(
            paneController.hostView,
            initialFrame: sourceFrame,
            animated: animated
        )

        let targetFrame = rootView.floatingPaneTargetFrame()
        if animated {
            rootView.beginFloatingPaneAnimation()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = WorkspaceFloatingPaneConfiguration.animationDuration
                rootView.animateFloatingPaneFrame(to: targetFrame)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.animatingDetachedPaneIDs.remove(paneID)
                    self?.updateTabStrip()
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

    private func hideActiveDetachedPane(
        in tabState: WorkspaceTabState,
        animated: Bool,
        reapplyAutoZoom: Bool,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard
            tabState.id == selectedTabID,
            let paneID = tabState.activeDetachedPaneID,
            let paneController = tabState.paneControllers[paneID]
        else {
            tabState.activeDetachedPaneID = nil
            completion?()
            return
        }

        let destinationFrame =
            rootView.detachedPaneStatusCellFrame(for: paneID)
            ?? paneController.hostView.frame
        let currentFloatingSize =
            rootView.floatingPaneFrame(for: paneController.hostView)?.size
            ?? paneController.hostView.frame.size

        if animated {
            animatingDetachedPaneIDs.insert(paneID)
            updateTabStrip()
            rootView.beginFloatingPaneAnimation()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = WorkspaceFloatingPaneConfiguration.animationDuration
                rootView.animateFloatingPaneFrame(to: destinationFrame)
            } completionHandler: { [weak self, weak tabState] in
                Task { @MainActor in
                    guard let self, let tabState else {
                        completion?()
                        return
                    }

                    self.finishHidingDetachedPane(
                        in: tabState,
                        reapplyAutoZoom: reapplyAutoZoom,
                        savedFloatingSize: currentFloatingSize
                    )
                    completion?()
                }
            }
        } else {
            rootView.setFloatingPaneFrame(destinationFrame)
            finishHidingDetachedPane(
                in: tabState,
                reapplyAutoZoom: reapplyAutoZoom,
                savedFloatingSize: currentFloatingSize
            )
            completion?()
        }
    }

    private func finishHidingDetachedPane(
        in tabState: WorkspaceTabState,
        reapplyAutoZoom: Bool,
        savedFloatingSize: NSSize
    ) {
        if let paneID = tabState.activeDetachedPaneID {
            tabState.floatingPaneSizes[paneID] = savedFloatingSize
            animatingDetachedPaneIDs.remove(paneID)
        }

        tabState.activeDetachedPaneID = nil
        tabState.focusedPaneID = tabState.lastFocusedTiledPaneID
        rootView.removeFloatingPaneView()
        rootView.setCustomFloatingPaneSize(nil)
        if reapplyAutoZoom {
            applyAutoZoomToFocusedPane(in: tabState, animated: true)
        }
        updatePanePresentation(in: tabState)
        updateTabStrip()
        updateWindowTitle()
        applyFocusedPaneResponder()
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
        rebuildWorkspaceLayout(applyAutoZoomAnimated: false, restoreFloatingPresentation: false)

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

    private func clearFloatingPaneImmediately(
        in tabState: WorkspaceTabState,
        reapplyAutoZoom: Bool
    ) {
        if let floatingState = tabState.activeFloatingPaneState,
            let paneController = tabState.paneControllers[floatingState.paneID],
            let size = rootView.floatingPaneFrame(for: paneController.hostView)?.size
        {
            tabState.floatingPaneSizes[floatingState.paneID] = size
        }

        tabState.activeFloatingPaneState = nil
        rebuildWorkspaceLayout(applyAutoZoomAnimated: reapplyAutoZoom)
        rootView.removeFloatingPaneView()
        applyFocusedPaneResponder()
    }

    private func rebuildWorkspaceLayout(
        applyAutoZoomAnimated: Bool = false,
        restoreFloatingPresentation: Bool = true
    ) {
        updateTabStrip()

        guard let tabState = selectedTabState, let layoutNode = tabState.layoutNode else {
            tilingView = nil
            rootView.installRenderedContentView(NSView())
            view.layoutSubtreeIfNeeded()
            if let selectedTabState, restoreFloatingPresentation {
                restoreActiveFloatingPresentation(in: selectedTabState)
            }
            updateWindowTitle()
            updateWindowMinimumSize()
            applyFocusedPaneResponder()
            return
        }

        let paneViews = buildPaneViewsDictionary(for: tabState)

        if let tilingView {
            tilingView.setLayoutNode(layoutNode, paneViews: paneViews)
        } else {
            let newTilingView = WorkspaceTilingView(
                dividerThickness: AppAppearanceSettings.workspaceDividerThickness
            )
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
        if restoreFloatingPresentation {
            restoreActiveFloatingPresentation(in: tabState)
        }
        updatePanePresentation(in: tabState)
        updateWindowTitle()
        updateWindowMinimumSize()
        applyFocusedPaneResponder()
    }

    private func suspendActiveFloatingPresentation(in tabState: WorkspaceTabState) {
        if var floatingState = tabState.activeFloatingPaneState,
            let paneController = tabState.paneControllers[floatingState.paneID],
            let size = rootView.floatingPaneFrame(for: paneController.hostView)?.size
        {
            floatingState.size = size
            tabState.activeFloatingPaneState = floatingState
            tabState.floatingPaneSizes[floatingState.paneID] = size
        }

        if let detachedPaneID = tabState.activeDetachedPaneID,
            let paneController = tabState.paneControllers[detachedPaneID],
            let size = rootView.floatingPaneFrame(for: paneController.hostView)?.size
        {
            tabState.floatingPaneSizes[detachedPaneID] = size
        }

        rootView.removeFloatingPaneView()
    }

    private func restoreActiveFloatingPresentation(in tabState: WorkspaceTabState) {
        if let floatingState = tabState.activeFloatingPaneState {
            restoreFloatingPane(
                withID: floatingState.paneID,
                in: tabState,
                size: floatingState.size
            )
        } else if let detachedPaneID = tabState.activeDetachedPaneID {
            restoreFloatingPane(
                withID: detachedPaneID,
                in: tabState,
                size: tabState.floatingPaneSizes[detachedPaneID]
            )
        } else {
            rootView.removeFloatingPaneView()
            rootView.setCustomFloatingPaneSize(nil)
        }
    }

    private func restoreFloatingPane(
        withID paneID: PaneID,
        in tabState: WorkspaceTabState,
        size: NSSize?
    ) {
        guard tabState.id == selectedTabID,
            let paneController = tabState.paneControllers[paneID]
        else {
            rootView.removeFloatingPaneView()
            return
        }

        rootView.removeFloatingPaneView()
        rootView.setCustomFloatingPaneSize(size)
        view.layoutSubtreeIfNeeded()
        let targetFrame = rootView.floatingPaneTargetFrame()
        rootView.installFloatingPaneView(
            paneController.hostView,
            initialFrame: targetFrame,
            animated: false
        )
        rootView.setFloatingPaneFrame(targetFrame)
        rootView.finishFloatingPaneAnimation()
    }

    private func buildPaneViewsDictionary(
        for tabState: WorkspaceTabState
    ) -> [PaneID: NSView] {
        var result: [PaneID: NSView] = [:]
        for (paneID, paneController) in tabState.paneControllers {
            guard tabState.isPaneTiled(paneID) else {
                continue
            }

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
                proposedFractions,
                in: tilingView.bounds.size,
                dividerThickness: AppAppearanceSettings.workspaceDividerThickness
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
            paneController.setNameVisible(paneNamesVisible && tabState.id == selectedTabID)
            paneController.updatePresentation(
                isFocused: paneID == tabState.focusedPaneID,
                isFloating: tabState.activeFloatingPaneState?.paneID == paneID
                    || tabState.activeDetachedPaneID == paneID
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
        let detachedItems =
            selectedTabState?.detachedPaneIDs.enumerated().map { index, paneID in
                DetachedPaneStatusItem(
                    paneID: paneID,
                    number: index + 1,
                    isActive: selectedTabState?.activeDetachedPaneID == paneID,
                    isEnabled: !animatingDetachedPaneIDs.contains(paneID)
                )
            } ?? []
        rootView.updateDetachedPaneStatusItems(
            detachedItems,
            target: self,
            action: #selector(toggleDetachedPaneAtIndex(_:))
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
        tilingView?.updateDividerThickness(AppAppearanceSettings.workspaceDividerThickness)
        if let window = view.window {
            AppAppearanceDefaults.applyWindowPresentation(
                to: window,
                isWindowHidden: AppAppearanceSettings.isWindowHidden,
                cornerRadius: AppAppearanceSettings.windowCornerRadius
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
        updateWindowMinimumSize()
    }

    private func updateWindowTitle() {
        view.window?.title = selectedTabState?.displayTitle ?? "Santty"
    }

    var commandPaletteCommands: [AppCommand] {
        [
            AppCommand(
                id: "pane.rename",
                title: "Rename Pane",
                shortcut: nil,
                isEnabled: focusedPaneController != nil,
                perform: { [weak self] in self?.renamePane(nil) }
            ),
            AppCommand(
                id: "pane.split.horizontal",
                title: "Split Horizontally",
                shortcut: KeybindingSettings.displayShortcut(for: .splitPaneHorizontally),
                isEnabled: focusedTerminalPaneController != nil
                    ? focusedTerminalPaneController?.isLive == true && focusedPaneIsTiled
                    : focusedPaneController != nil && focusedPaneIsTiled,
                perform: { [weak self] in self?.splitPaneHorizontally(nil) }
            ),
            AppCommand(
                id: "pane.split.vertical",
                title: "Split Vertically",
                shortcut: KeybindingSettings.displayShortcut(for: .splitPaneVertically),
                isEnabled: focusedTerminalPaneController != nil
                    ? focusedTerminalPaneController?.isLive == true && focusedPaneIsTiled
                    : focusedPaneController != nil && focusedPaneIsTiled,
                perform: { [weak self] in self?.splitPaneVertically(nil) }
            ),
            AppCommand(
                id: "pane.notes.new",
                title: "Open Notes in Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .newNotesPane),
                isEnabled: focusedPaneController != nil && focusedPaneIsTiled,
                perform: { [weak self] in self?.newNotesPane(nil) }
            ),
            AppCommand(
                id: "pane.browser.new",
                title: "New Browser Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .newBrowserPane),
                isEnabled: focusedPaneController != nil && focusedPaneIsTiled,
                perform: { [weak self] in self?.newBrowserPane(nil) }
            ),
            AppCommand(
                id: "pane.browser.location",
                title: "Focus Location Bar",
                shortcut: KeybindingSettings.displayShortcut(for: .focusBrowserLocation),
                isEnabled: focusedBrowserPaneController != nil,
                perform: { [weak self] in self?.focusBrowserLocationBar(nil) }
            ),
            AppCommand(
                id: "pane.browser.convert",
                title: "Switch Pane to Browser",
                shortcut: KeybindingSettings.displayShortcut(for: .convertPaneToBrowser),
                isEnabled: focusedTerminalPaneController != nil && focusedPaneIsTiled,
                perform: { [weak self] in self?.convertFocusedPaneToBrowser(nil) }
            ),
            AppCommand(
                id: "pane.terminal.convert",
                title: "Switch Pane to Terminal",
                shortcut: KeybindingSettings.displayShortcut(for: .convertPaneToTerminal),
                isEnabled: focusedBrowserPaneController != nil && focusedPaneIsTiled,
                perform: { [weak self] in self?.convertFocusedPaneToTerminal(nil) }
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
                isEnabled: focusedPaneIsTiled
                    && (selectedTabState?.tiledPaneIDsInTraversalOrder.count ?? 0) > 1,
                perform: { [weak self] in self?.focusPreviousPane(nil) }
            ),
            AppCommand(
                id: "pane.focus.next",
                title: "Focus Next Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusNextPane),
                isEnabled: focusedPaneIsTiled
                    && (selectedTabState?.tiledPaneIDsInTraversalOrder.count ?? 0) > 1,
                perform: { [weak self] in self?.focusNextPane(nil) }
            ),
            AppCommand(
                id: "pane.focus.left",
                title: "Focus Left Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusLeftPane),
                isEnabled: focusedPaneIsTiled
                    && (selectedTabState?.tiledPaneIDsInTraversalOrder.count ?? 0) > 1,
                perform: { [weak self] in self?.focusLeftPane(nil) }
            ),
            AppCommand(
                id: "pane.focus.right",
                title: "Focus Right Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusRightPane),
                isEnabled: focusedPaneIsTiled
                    && (selectedTabState?.tiledPaneIDsInTraversalOrder.count ?? 0) > 1,
                perform: { [weak self] in self?.focusRightPane(nil) }
            ),
            AppCommand(
                id: "pane.focus.above",
                title: "Focus Above Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusAbovePane),
                isEnabled: focusedPaneIsTiled
                    && (selectedTabState?.tiledPaneIDsInTraversalOrder.count ?? 0) > 1,
                perform: { [weak self] in self?.focusAbovePane(nil) }
            ),
            AppCommand(
                id: "pane.focus.below",
                title: "Focus Below Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusBelowPane),
                isEnabled: focusedPaneIsTiled
                    && (selectedTabState?.tiledPaneIDsInTraversalOrder.count ?? 0) > 1,
                perform: { [weak self] in self?.focusBelowPane(nil) }
            ),
            AppCommand(
                id: "pane.move.left",
                title: "Move Pane Left",
                shortcut: KeybindingSettings.displayShortcut(for: .movePaneLeft),
                isEnabled: canMovePane(.left),
                perform: { [weak self] in self?.movePaneLeft(nil) }
            ),
            AppCommand(
                id: "pane.move.right",
                title: "Move Pane Right",
                shortcut: KeybindingSettings.displayShortcut(for: .movePaneRight),
                isEnabled: canMovePane(.right),
                perform: { [weak self] in self?.movePaneRight(nil) }
            ),
            AppCommand(
                id: "pane.move.up",
                title: "Move Pane Up",
                shortcut: KeybindingSettings.displayShortcut(for: .movePaneUp),
                isEnabled: canMovePane(.up),
                perform: { [weak self] in self?.movePaneUp(nil) }
            ),
            AppCommand(
                id: "pane.move.down",
                title: "Move Pane Down",
                shortcut: KeybindingSettings.displayShortcut(for: .movePaneDown),
                isEnabled: canMovePane(.down),
                perform: { [weak self] in self?.movePaneDown(nil) }
            ),
            AppCommand(
                id: "pane.autoResize",
                title: "Auto Resize",
                shortcut: KeybindingSettings.displayShortcut(for: .autoResizePane),
                isEnabled: focusedPaneController != nil && focusedPaneIsTiled,
                perform: { [weak self] in self?.showAutoResizeSettings(nil) }
            ),
            AppCommand(
                id: "pane.floating.toggle",
                title: "Toggle Floating Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .toggleFloatingPane),
                isEnabled: canToggleFloatingPane(),
                perform: { [weak self] in self?.toggleFloatingPane(nil) }
            ),
            AppCommand(
                id: "pane.detach",
                title: "Detach Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .detachPane),
                isEnabled: canDetachFocusedPane(),
                perform: { [weak self] in self?.detachPane(nil) }
            ),
            AppCommand(
                id: "pane.detached.attach",
                title: "Attach Detached Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .attachDetachedPane),
                isEnabled: canAttachFocusedDetachedPane(),
                perform: { [weak self] in self?.attachDetachedPane(nil) }
            ),
            AppCommand(
                id: "pane.promptEditor",
                title: "Open Prompt Editor",
                shortcut: KeybindingSettings.displayShortcut(for: .openPromptEditor),
                isEnabled: focusedTerminalPaneController?.isLive == true,
                perform: { [weak self] in self?.openPromptEditor(nil) }
            ),
            AppCommand(
                id: "pane.scrollMode.enter",
                title: "Enter Scroll Mode",
                shortcut: KeybindingSettings.displayShortcut(for: .enterScrollMode),
                isEnabled: focusedTerminalPaneController?.isLive == true
                    && focusedTerminalPaneController?.isScrollModeActive == false,
                perform: { [weak self] in self?.enterScrollMode(nil) }
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
            AppAppearanceSettings.workspaceEdgePadding * 2
            + WorkspaceLayoutMetrics.workspaceSectionSpacing
            + WorkspaceLayoutMetrics.tabStripHeight

        guard let layoutNode = selectedTabState?.layoutNode else {
            view.window?.contentMinSize = WorkspaceLayoutMetrics.minimumWindowContentSize
            return
        }

        let minimumSize = layoutNode.minimumSize(
            dividerThickness: AppAppearanceSettings.workspaceDividerThickness
        )
        let paddedMinimumSize = NSSize(
            width: minimumSize.width + AppAppearanceSettings.workspaceEdgePadding * 2,
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

    @discardableResult
    func performKeybindingAction(_ action: KeybindingAction) -> Bool {
        guard action != .focusBrowserLocation || focusedBrowserPaneController != nil else {
            return false
        }

        guard let command = commandPaletteCommands.first(where: { $0.id == action.commandID })
        else {
            return false
        }

        guard command.isEnabled else {
            NSSound.beep()
            return true
        }

        command.perform()
        return true
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
    var debugFocusedNotesPane: NotesPaneController? { focusedPaneController as? NotesPaneController }

    func debugSetFocusedPaneName(_ name: String) {
        if let pane = focusedPaneController { updatePaneName(name, for: pane) }
    }

    func debugPaneNameBadge(for paneID: PaneID) -> PaneNameBadgeView? {
        let host = tabState(containing: paneID)?.paneControllers[paneID]?.hostView
        return host?.subviews.compactMap { $0 as? PaneNameBadgeView }.first
    }

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
    var debugFocusedPaneIsTerminal: Bool {
        focusedPaneController is TerminalPaneController
    }
    var debugFocusedPaneIsBrowser: Bool {
        focusedPaneController is BrowserPaneController
    }
    var debugFocusedPaneIsInScrollMode: Bool {
        focusedTerminalPaneController?.isScrollModeActive == true
    }
    var debugActiveAutoZoomState: ActiveAutoZoomState? { selectedTabState?.activeAutoZoomState }
    var debugActiveFloatingPaneState: ActiveFloatingPaneState? {
        selectedTabState?.activeFloatingPaneState
    }
    var debugDetachedPaneIDs: [PaneID] { selectedTabState?.detachedPaneIDs ?? [] }
    var debugActiveDetachedPaneID: PaneID? { selectedTabState?.activeDetachedPaneID }
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
        selectedTabState?.terminalPaneController(for: paneID)?.debugBorderColor
    }

    func debugPaneBorderWidth(for paneID: PaneID) -> CGFloat? {
        selectedTabState?.terminalPaneController(for: paneID)?.debugBorderWidth
    }

    func debugPaneUsesHiddenWindowPresentation(for paneID: PaneID) -> Bool? {
        selectedTabState?.terminalPaneController(for: paneID)?.debugUsesHiddenWindowPresentation
    }

    func debugPaneVibrancyBlendingMode(for paneID: PaneID) -> NSVisualEffectView.BlendingMode? {
        selectedTabState?.terminalPaneController(for: paneID)?.debugVibrancyBlendingMode
    }

    func debugPaneVibrancyTintAlpha(for paneID: PaneID) -> CGFloat? {
        selectedTabState?.terminalPaneController(for: paneID)?.debugVibrancyTintAlpha
    }

    func debugTerminalFrame(for paneID: PaneID) -> NSRect? {
        selectedTabState?.terminalPaneController(for: paneID)?.debugTerminalFrame
    }

    func debugTerminalPadding(for paneID: PaneID) -> CGFloat? {
        selectedTabState?.terminalPaneController(for: paneID)?.debugTerminalPadding
    }

    func debugPaneBounds(for paneID: PaneID) -> NSRect? {
        selectedTabState?.terminalPaneController(for: paneID)?.debugPaneBounds
    }

    func debugScrollModeIndicatorIsVisible(for paneID: PaneID) -> Bool? {
        selectedTabState?.terminalPaneController(for: paneID)?.debugScrollModeIndicatorIsVisible
    }

    func debugScrollModeIndicatorFrames(
        for paneID: PaneID
    ) -> (background: NSRect, label: NSRect)? {
        selectedTabState?.terminalPaneController(for: paneID)?.debugScrollModeIndicatorFrames
    }

    func debugRenderedTerminalConfig(for paneID: PaneID) -> String? {
        selectedTabState?.terminalPaneController(for: paneID)?.debugRenderedTerminalConfig
    }

    func debugPlaceholderFrame(for paneID: PaneID) -> NSRect? {
        rootView.debugPlaceholderFrame(for: paneID)
    }

    func debugDetachedPaneStatusCellFrame(for paneID: PaneID) -> NSRect? {
        rootView.debugDetachedPaneStatusCellFrame(for: paneID)
    }

    func debugDetachedPaneStatusCellIsActive(for paneID: PaneID) -> Bool? {
        rootView.debugDetachedPaneStatusCellIsActive(for: paneID)
    }

    @discardableResult
    func debugClickWorkspace(at point: NSPoint) -> PaneID? {
        guard let hit = rootView.debugHitTerminalPane(at: point) else {
            return nil
        }

        if hit.isInsideFloatingPane {
            return hit.paneID
        }

        handlePaneFocusRequest(withID: hit.paneID)
        return hit.paneID
    }

    func debugHitWorkspacePaneID(at point: NSPoint) -> PaneID? {
        rootView.debugHitTerminalPaneID(at: point)
    }

    func debugHitIsInsideFloatingPane(at point: NSPoint) -> Bool {
        rootView.debugHitIsInsideFloatingPane(at: point)
    }

    func debugSelectedTabContainsPane(withID paneID: PaneID) -> Bool {
        selectedTabState?.containsPane(withID: paneID) == true
    }

    func debugSelectedTabPaneIsTiled(_ paneID: PaneID) -> Bool {
        selectedTabState?.isPaneTiled(paneID) == true
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

    func debugHandlePaneFocusRequest(withID paneID: PaneID) {
        handlePaneFocusRequest(withID: paneID)
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
            .terminalPaneController(for: paneID)?
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
            let paneController = tabState.terminalPaneController(for: paneID)
        else {
            return
        }

        paneController.terminalDidChangeTitle(title)
    }

    func debugSetPaneWorkingDirectory(_ workingDirectory: String, for paneID: PaneID) {
        guard
            let tabState = tabState(containing: paneID),
            let paneController = tabState.terminalPaneController(for: paneID)
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

    func debugHandleScrollModeKeyEvent(_ event: NSEvent) -> Bool {
        handleScrollModeKeyEvent(event)
    }

    func debugToggleFloatingPane(animated: Bool = false) {
        guard let tabState = selectedTabState else {
            return
        }

        if tabState.activeDetachedPaneID != nil {
            hideActiveDetachedPane(in: tabState, animated: animated, reapplyAutoZoom: true)
            return
        }

        guard
            let focusedPaneID = tabState.focusedPaneID,
            tabState.focusedPaneController != nil,
            tabState.isPaneTiled(focusedPaneID)
        else {
            return
        }

        if tabState.activeFloatingPaneState != nil {
            leaveFloatingPane(in: tabState, animated: animated, reapplyAutoZoom: true)
        } else {
            enterFloatingPane(in: tabState, animated: animated)
        }
    }

    func debugDetachFocusedPane(animated: Bool = false) {
        detachFocusedPane(animated: animated)
    }

    func debugAttachFocusedDetachedPane(animated: Bool = false) {
        attachFocusedDetachedPane(animated: animated)
    }

    func debugToggleDetachedPane(at index: Int, animated: Bool = false) {
        toggleDetachedPane(at: index, animated: animated)
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
