import AppKit
import GhosttyTerminal

struct PaneFocusRatios: Codable, Sendable, Equatable {
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

struct PaneAutoResizeConfiguration: Codable, Sendable, Equatable {
    enum Trigger: String, Codable, Sendable {
        case focus
        case unfocused

        var ratioRange: ClosedRange<Double> {
            self == .focus ? 0.25...0.95 : 0...1
        }
    }

    var isEnabled: Bool
    var ratios: PaneFocusRatios
    var trigger: Trigger = .focus
    var isHorizontalEnabled: Bool = true
    var isVerticalEnabled: Bool = true
}

extension PaneAutoResizeConfiguration {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        ratios = try container.decode(PaneFocusRatios.self, forKey: .ratios)
        trigger = try container.decodeIfPresent(Trigger.self, forKey: .trigger) ?? .focus
        isHorizontalEnabled = try container.decodeIfPresent(Bool.self, forKey: .isHorizontalEnabled) ?? true
        isVerticalEnabled = try container.decodeIfPresent(Bool.self, forKey: .isVerticalEnabled) ?? true
    }
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
final class WorkspaceViewController: NSViewController, NSMenuItemValidation, NSMenuDelegate, NSWindowDelegate {
    private var windowContentView: WindowContentView { view as! WindowContentView }
    private var rootView: WorkspaceRootView { windowContentView.mainView }
    private let sidebar = WindowSidebarState()
    private var sidebarIsFocused = false
    private var windowFocusHistory: [PaneID] = []
    private var sidebarMouseMonitor: Any?
    private var visibleTiledPaneCount: Int {
        (selectedTabState?.tiledPaneIDsInTraversalOrder.count ?? 0) + (sidebar.isVisible ? sidebar.tab.tiledPaneIDsInTraversalOrder.count : 0)
    }
    private var activePaneTab: WorkspaceTabState? { sidebarIsFocused ? sidebar.tab : selectedTabState }
    private var paneOwnerTabs: [WorkspaceTabState] { allWorkspaceTabs + [sidebar.tab] }

    private var workspaceStore: WorkspaceStore?
    private var initialSavedWorkspace: SavedWorkspace?
    private var workspacePersistenceActivated = false
    private var suppressWorkspaceSaving = false
    private var workspaceSaveTask: Task<Void, Never>?
    private(set) var workspacePersistenceError: String?
    private var workspaceEntries: [WorkspaceEntry] = []
    private var closingHerdrPaneIDs: Set<PaneID> = []
    var herdrCoreClient = HerdrCoreClient.shared
    private var agentObserver: NSObjectProtocol?
    private var agentPopover: AgentManagerPopoverController?
    private var agentNavigationTask: Task<Void, Never>?

    private struct LocalWorkspaceState {
        let id: UUID
        let name: String
        var kind: WorkspaceKind = .local
        var remote: HerdrRemote? = nil
        var tabs: [WorkspaceTabState]
        var selectedTabID: UUID?
        var pickerID: String { kind.rawValue + "." + id.uuidString }
    }
    private var localWorkspaceID = UUID()
    private var localWorkspaceName = "Default"
    private var workspaceKind: WorkspaceKind = .local
    private var workspaceRemote: HerdrRemote?
    private var otherLocalWorkspaces: [LocalWorkspaceState] = []
    private var localWorkspaceStates: [LocalWorkspaceState] {
        let current = LocalWorkspaceState(id: localWorkspaceID, name: localWorkspaceName, kind: workspaceKind, remote: workspaceRemote,
            tabs: tabs, selectedTabID: selectedTabID)
        return ([current] + otherLocalWorkspaces).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var allWorkspaceTabs: [WorkspaceTabState] {
        tabs + otherLocalWorkspaces.flatMap(\.tabs)
    }
    private var tabs: [WorkspaceTabState] = []
    private var selectedTabID: UUID?

    func handleCLIRequest(_ request: CLIRequest) throws -> CLIResponse {
        try request.validate()
        if request.command == "list" { return CLIResponse(tabs: cliTabSnapshots()) }
        guard request.command == "read" || request.command == "search" else {
            throw CLIError("Control commands must pass through the authorized CLI router.")
        }
        guard let id = request.paneID,
            let pane = paneOwnerTabs.lazy.compactMap({ $0.paneControllers[id] }).first
        else { throw CLIError("Pane not found. Run santty list --json to refresh pane IDs.", code: "pane_not_found") }
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
    private var animatingDetachedPaneIDs: Set<PaneID> = []
    private var lastPaneNameCommandPress: TimeInterval?
    private var paneNamesVisible = false
    private var isCommandHeld = false
    private var isClosingWindow = false
    private var cliWindowClosePending = false
    private var cliWindowCloseRequestID: String?
    private var cliPreservingResponder = false
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
        activePaneTab?.focusedPaneController
    }

    private var focusedTerminalPaneController: TerminalPaneController? {
        focusedPaneController as? TerminalPaneController
    }

    var inputSourceTarget: PaneInputSourceCoordinator.Target? {
        guard
              let pane = focusedTerminalPaneController, let target = pane.inputSourceTargetView,
              let window = target.window, window.isKeyWindow, window.attachedSheet == nil,
              window.firstResponder === target else { return nil }
        return .init(paneID: pane.id, view: target, foreground: { [weak pane] in
            guard let pane else { throw CLIError("The terminal pane was closed") }
            return try await pane.inputSourceForeground()
        })
    }

    private var focusedBrowserPaneController: BrowserPaneController? {
        focusedPaneController as? BrowserPaneController
    }

    private var canSplitFocusedPane: Bool {
        focusedPaneIsTiled && focusedPaneController != nil
            && focusedTerminalPaneController.map({ $0.isLive }) != false

    }

    private var focusedPaneIsTiled: Bool {
        guard let tabState = activePaneTab, let focusedPaneID = tabState.focusedPaneID else {
            return false
        }

        return tabState.isPaneTiled(focusedPaneID)
    }

    override func loadView() {
        view = WindowContentView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        windowContentView.onWidthChange = { [weak self] width in
            guard let self else { return }
            sidebar.preferredWidth = width
            scheduleWorkspaceSave()
        }
        windowContentView.onSidebarLayout = { [weak self] in self?.renderSidebar() }
        windowContentView.sidebarView.onFractionsChange = { [weak self] path, fractions, source in
            guard let self, source == .userDrag else { return }
            sidebar.tab.layoutNode = sidebar.tab.layoutNode?.replacingFractions(at: path, with: fractions)
            scheduleWorkspaceSave()
        }
        sidebarMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.view.window else { return }
                let point = self.view.convert(event.locationInWindow, from: nil)
                for pane in self.sidebar.tab.paneControllers.values where self.sidebar.isVisible {
                    let frame = pane.hostView.convert(pane.hostView.bounds, to: self.view)
                    if frame.contains(point) { self.focusSidebarPane(pane.id); return }
                }
                for case let pane as AgentsPaneController in self.selectedTabState?.paneControllers.values ?? [:].values {
                    guard pane.hostView.window === event.window else { continue }
                    let frame = pane.hostView.convert(pane.hostView.bounds, to: self.view)
                    if frame.contains(point) { self.handlePaneFocusRequest(withID: pane.id); return }
                }
            }
            return event
        }
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
        configureAgents()
        rootView.toolbarView.onSelectWorkspace = { [weak self] in self?.selectWorkspace($0) }
        if let initialSavedWorkspace {
            do { try restoreWorkspace(initialSavedWorkspace) }
            catch { workspacePersistenceError = error.localizedDescription; createInitialTab() }
        } else { createInitialTab() }
        refreshWorkspacePicker()
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
            if let agentObserver { NotificationCenter.default.removeObserver(agentObserver) }
            agentNavigationTask?.cancel()
            if let sidebarMouseMonitor { NSEvent.removeMonitor(sidebarMouseMonitor) }
            workspaceSaveTask?.cancel()
            for observer in paneNameFocusObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            if let appearanceSettingsObserver {
                NotificationCenter.default.removeObserver(appearanceSettingsObserver)
            }
            if let terminalSettingsObserver {
                NotificationCenter.default.removeObserver(terminalSettingsObserver)
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
            if sidebar.isVisible { startPaneControllersIfNeeded(in: sidebar.tab) }
        }

        applyFocusedPaneResponder()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateWindowMinimumSize()
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
        if event.type == .flagsChanged, modifiers.isEmpty { return }
        guard event.type == .flagsChanged, modifiers == [.command] else {
            cancelPaneNameReveal()
            return
        }
        // A shortcut or another modifier suppresses this press until Cmd is released.
        guard !wasCommandHeld else { return }
        if let lastPress = lastPaneNameCommandPress,
            (0...NSEvent.doubleClickInterval).contains(event.timestamp - lastPress)
        {
            lastPaneNameCommandPress = nil
            setPaneNamesVisible(!paneNamesVisible)
        } else {
            lastPaneNameCommandPress = event.timestamp
        }
    }

    private func cancelPaneNameReveal() {
        lastPaneNameCommandPress = nil
        setPaneNamesVisible(false)
    }

    private func setPaneNamesVisible(_ visible: Bool) {
        paneNamesVisible = visible
        for tab in paneOwnerTabs {
            for pane in tab.paneControllers.values {
                pane.setNameVisible(visible && (tab.id == selectedTabID || tab === sidebar.tab && sidebar.isVisible))
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if sidebarIsFocused, [#selector(detachPane(_:)),
            #selector(attachDetachedPane(_:)), #selector(showAutoResizeSettings(_:)),
            #selector(convertFocusedPaneToTerminal(_:)), #selector(convertFocusedPaneToBrowser(_:))].contains(menuItem.action) { return false }
        if let keyWindow = NSApp.keyWindow, keyWindow is NSPanel, !keyWindow.canBecomeMain {
            return false
        }
        return switch menuItem.action {
        case #selector(splitPaneHorizontally(_:)), #selector(splitPaneVertically(_:)), #selector(newTerminalPane(_:)):
            canSplitFocusedPane
        case #selector(newBrowserPane(_:)), #selector(newAgentsPane(_:)), #selector(newWorkspacesPane(_:)):
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
        case #selector(newWorkspace(_:)), #selector(newHerdrWorkspace(_:)), #selector(newRemoteHerdrWorkspace(_:)):
            canCreateLocalWorkspace
        case #selector(closeWorkspace(_:)), #selector(renameWorkspace(_:)):
            canCloseWorkspace
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
        case #selector(focusNextPane(_:)), #selector(focusPreviousPane(_:)):
            focusedPaneIsTiled && (activePaneTab?.tiledPaneIDsInTraversalOrder.count ?? 0) > 1
        case #selector(focusLeftPane(_:)), #selector(focusRightPane(_:)),
            #selector(focusAbovePane(_:)), #selector(focusBelowPane(_:)):
            focusedPaneIsTiled && visibleTiledPaneCount > 1
        case #selector(newTab(_:)):
            true
        case #selector(renameTab(_:)):
            selectedTabState != nil && canCloseWorkspace
        case #selector(closeTab(_:)):
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
        guard workspacePersistenceActivated else { return true }
        guard !isClosingWindow else { return false }
        isClosingWindow = true
        Task { [weak self] in
            guard let self else { return }
            defer { isClosingWindow = false }
            if await confirmWorkspaceSaveForClose() { requestWindowClose(workspaceSaveConfirmed: true) }
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
        splitFocusedPane(along: automaticSplitAxis(for: focusedPaneController)) {
            self.makeBrowserPaneController()
        }
    }

    @objc func newAgentsPane(_: Any?) {
        splitFocusedPane(along: automaticSplitAxis(for: focusedPaneController)) { self.makeAgentsPaneController() }
    }

    @objc func newWorkspacesPane(_: Any?) {
        splitFocusedPane(along: automaticSplitAxis(for: focusedPaneController)) { self.makeWorkspacesPaneController() }
    }

    @objc func newTerminalPane(_: Any?) {
        splitFocusedPane(along: automaticSplitAxis(for: focusedPaneController))
    }

    @objc func focusBrowserLocationBar(_: Any?) {
        guard let focusedBrowserPaneController else {
            NSSound.beep()
            return
        }

        focusedBrowserPaneController.focusLocationBar()
    }

    @objc func convertFocusedPaneToBrowser(_: Any?) {
        guard !sidebarIsFocused else { return }
        guard selectedTabState?.focusedPaneController is TerminalPaneController,
            let paneID = selectedTabState?.focusedPaneID
        else {
            NSSound.beep()
            return
        }

        replaceFocusedPane(with: makeBrowserPaneController(id: paneID))
    }

    @objc func convertFocusedPaneToTerminal(_: Any?) {
        guard !sidebarIsFocused else { return }
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
        guard !sidebarIsFocused else { return }
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
        guard let tabState = activePaneTab else {
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
        guard !sidebarIsFocused else { return }
        detachFocusedPane(animated: true)
    }

    @objc func attachDetachedPane(_: Any?) {
        guard !sidebarIsFocused else { return }
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

    @objc func focusNextPane(_: Any?) {
        guard let tabState = activePaneTab,
            let focusedPaneID = tabState.focusedPaneID
        else {
            return
        }

        let ids = tabState.tiledPaneIDsInTraversalOrder
        guard !ids.isEmpty else { return }
        let nextPaneID = ids[((ids.firstIndex(of: focusedPaneID) ?? -1) + 1) % ids.count]

        focusPane(withID: nextPaneID)
    }

    @objc func focusPreviousPane(_: Any?) {
        guard let tabState = activePaneTab,
            let focusedPaneID = tabState.focusedPaneID
        else {
            return
        }

        let ids = tabState.tiledPaneIDsInTraversalOrder
        guard !ids.isEmpty else { return }
        let previousPaneID = ids[((ids.firstIndex(of: focusedPaneID) ?? 0) + ids.count - 1) % ids.count]

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
        sidebarIsFocused = false
        updatePanePresentation(in: sidebar.tab)

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

    @objc func renameTab(_: Any?) {
        guard canCloseWorkspace, let tabState = selectedTabState else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave empty to use the automatic tab title."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        textField.usesSingleLineMode = true
        textField.stringValue = tabState.customTitle ?? tabState.displayTitle
        textField.placeholderString = tabState.focusedPaneController?.displayTitle ?? "Shell"
        textField.selectText(nil)
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, selectedTabID == tabState.id else {
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
        alert.informativeText = "Double-press Command to show pane names. Leave empty to remove the name."
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
        scheduleWorkspaceSave()
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

    private func createInitialTab(terminal: TerminalPaneController? = nil) {
        let initialTabState = makeTabState(startImmediately: false, terminal: terminal)
        tabs = [initialTabState]
        selectedTabID = initialTabState.id
        workspacePersistenceActivated = true
        rebuildWorkspaceLayout()
        scheduleWorkspaceSave()
    }

    private func makeTabState(startImmediately: Bool, terminal: TerminalPaneController? = nil) -> WorkspaceTabState {
        let paneController: any PaneControlling = terminal ?? makeTerminalPaneController()
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
        workingDirectory: String? = nil,
        kind: WorkspaceKind? = nil,
        binding: HerdrTerminalBinding? = nil,
        remote: HerdrRemote? = nil,
        runPending: Bool = false,
        viewerOnly: Bool = false
    ) -> TerminalPaneController {
        let herdr = (kind ?? workspaceKind) == .herdr ? HerdrTerminalSession(paneID: id, cwd: workingDirectory, binding: binding, remote: kind == nil ? workspaceRemote : remote, runPending: runPending, viewerOnly: viewerOnly, client: herdrCoreClient) : nil
        herdr?.beforeRun = { [weak self] in try await self?.flushWorkspaceState() }
        let paneController = TerminalPaneController(id: id, workingDirectory: workingDirectory, herdrSession: herdr)
        paneController.updateAppearance()

        paneController.onFocusRequest = { [weak self] paneID in
            self?.handlePaneFocusRequest(withID: paneID)
        }

        paneController.onTitleChange = { [weak self] paneID in
            self?.handleTitleChange(for: paneID)
            self?.scheduleWorkspaceSave()
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
            self?.scheduleWorkspaceSave()
        }

        return paneController
    }

    private func makeAgentsPaneController(id: PaneID = UUID()) -> AgentsPaneController {
        let pane = AgentsPaneController(id: id)
        let store = herdrCoreClient.agents
        pane.onFocusRequest = { [weak self] in self?.handlePaneFocusRequest(withID: $0) }
        pane.managerView.onFocusPane = { [weak self, weak store] session in
            store?.acknowledge(session)
            self?.navigateToAgent(session.binding)
        }
        pane.managerView.onCancel = { [weak self] in
            guard let self, self.sidebar.tab.containsPane(withID: id) else { return }
            self.focusMainRegion()
        }
        pane.update(sessions: store.snapshots, messages: store.messageSnapshots)
        return pane
    }

    private func applyTerminalSettingsToPanes() {

        for tabState in paneOwnerTabs {
            for case let paneController as TerminalPaneController in tabState.paneControllers.values
            {
                paneController.applyTerminalSettings()
            }
        }

    }

    private func automaticSplitAxis(for pane: (any PaneControlling)?) -> SplitAxis {
        view.layoutSubtreeIfNeeded()
        let size = pane?.hostView.bounds.size ?? .zero
        return size.width >= size.height ? .horizontal : .vertical
    }

    private func splitFocusedPane(along axis: SplitAxis) {
        guard canSplitFocusedPane else {
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
                    workingDirectory: focusedTerminalPaneController.workingDirectoryForNewPane,
                    kind: self.sidebarIsFocused ? .herdr : nil
                )
            }
        } else {
            splitFocusedPane(along: axis) {
                self.makeTerminalPaneController(kind: self.sidebarIsFocused ? .herdr : nil)
            }
        }
    }

    private func splitFocusedPane(
        along axis: SplitAxis,
        makeNewPaneController: () -> any PaneControlling
    ) {
        guard
            let tabState = activePaneTab,
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
        _ = insertPane(makeNewPaneController(), relativeTo: focusedPaneID, in: tabState,
                       layout: layoutNode, axis: axis, before: false, focus: true)
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

        if let previous = tabState.focusedPaneController, closeHerdrPanes([previous], then: { [weak self, weak tabState] in
            guard let self, let tabState else { return }
            if self.selectedTabState === tabState, tabState.focusedPaneID == focusedPaneID {
                self.replaceFocusedPane(with: newPaneController)
            } else { self.performClosePane(withID: focusedPaneID, in: tabState) }
        }) { return }

        leaveFloatingPane(in: tabState, animated: false, reapplyAutoZoom: false)
        clearActiveAutoZoomState(in: tabState, restoreLayout: false, animated: false)

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
            let tabState = activePaneTab,
            let layoutNode = tabState.layoutNode,
            canEqualizePaneSplits()
        else {
            NSSound.beep()
            return
        }

        leaveFloatingPane(in: tabState, animated: false, reapplyAutoZoom: false)
        clearActiveAutoZoomState(in: tabState, restoreLayout: false, animated: false)
        let equalizedLayout = layoutNode.equalizingSplitFractions()
        tabState.layoutNode = equalizedLayout
        let activeTilingView = tabState === sidebar.tab ? windowContentView.sidebarView : tilingView
        activeTilingView?.setLayoutNode(equalizedLayout, paneViews: buildPaneViewsDictionary(for: tabState))
        scheduleWorkspaceSave()
    }

    private func canEqualizePaneSplits() -> Bool {
        return (activePaneTab?.tiledPaneIDsInTraversalOrder.count ?? 0) > 1
    }

    private func movePaneDivider(_ direction: PaneDividerMoveDirection) {
        if let tabState = activePaneTab,
            tabState.activeFloatingPaneState != nil || tabState.activeDetachedPaneID != nil
        {
            resizeFloatingPane(in: tabState, direction: direction)
            return
        }

        let target = focusedResizeTarget(for: direction.axis)
        if target == nil, sidebarIsFocused, direction.axis == .horizontal {
            windowContentView.moveSidebarDivider(by: direction == .left ? -0.05 : 0.05)
            return
        }

        guard
            let tabState = activePaneTab,
            let target,
            case .split(_, _, let originalFractions) = tabState.layoutNode?.node(at: target.context.splitPath),
            let move = movedDividerFractions(
                in: target.context,
                direction: direction,
                restoringFrom: originalFractions
            )
        else {
            NSSound.beep()
            return
        }

        let clampedFractions = target.splitNode.clampedFractions(
            move.fractions,
            in: target.tilingView.currentLayout?.nodeFrames[target.context.splitPath]?.size
                ?? target.tilingView.bounds.size,
            dividerThickness: AppAppearanceSettings.workspaceDividerThickness,
            collapsedChildIndices: Set(target.context.fractions.indices.filter {
                target.context.fractions[$0] == 0
                    && $0 != target.context.focusedChildIndex && $0 != move.neighboringIndex
            })
        )
        guard clampedFractions != target.context.fractions else {
            NSSound.beep()
            return
        }

        guard let updatedNode = target.layoutNode.replacingFractions(
            at: target.context.splitPath, with: clampedFractions
        ) else { return }

        let preservesFoldedLayout = tabState.manualResizeLayout != nil
            || !target.tilingView.collapsedPaneIDs.isEmpty
        if preservesFoldedLayout, let focusedPaneID = tabState.focusedPaneID {
            tabState.manualResizeLayout = (focusedPaneID, updatedNode)
        }
        let paneViews = buildPaneViewsDictionary(for: tabState)
        target.tilingView.setLayoutNode(
            updatedNode, paneViews: paneViews, animated: true,
            isTransient: preservesFoldedLayout
        )

        if sidebarIsFocused {
            tabState.layoutNode = updatedNode
            scheduleWorkspaceSave()
            return
        }

        updateSplitFractions(
            at: target.context.splitPath,
            to: clampedFractions,
            changeSource: .userDrag
        )
    }

    private func canMovePaneDivider(_ direction: PaneDividerMoveDirection) -> Bool {
        if activePaneTab?.activeFloatingPaneState != nil
            || activePaneTab?.activeDetachedPaneID != nil
        {
            return true
        }
        return focusedResizeTarget(for: direction.axis) != nil
            || sidebarIsFocused && direction.axis == .horizontal
    }

    private func movePane(_ direction: PaneMoveDirection) {
        guard
            let tabState = activePaneTab,
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
        rebuildPaneContainer(tabState)
        scheduleWorkspaceSave()
    }

    private func canMovePane(_ direction: PaneMoveDirection) -> Bool {
        guard
            let tabState = activePaneTab,
            let focusedPaneID = tabState.focusedPaneID,
            tabState.focusedPaneController != nil,
            tabState.isPaneTiled(focusedPaneID),
            tabState.activeFloatingPaneState == nil,
            tabState.activeDetachedPaneID == nil
        else {
            return false
        }

        let target = directionalTiledPaneTarget(
            from: focusedPaneID,
            direction: direction.focusDirection,
            in: tabState
        )

        return target != nil
    }

    private func resizeFloatingPane(
        in tabState: WorkspaceTabState,
        direction: PaneDividerMoveDirection
    ) {
        let rootView = floatingRootView(for: tabState)
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
        layoutNode: LayoutNode,
        tilingView: WorkspaceTilingView
    )? {
        guard
            let tabState = activePaneTab,
            let focusedPaneID = tabState.focusedPaneID,
            let tilingView = sidebarIsFocused ? windowContentView.sidebarView : tilingView,
            let layoutNode = tabState.manualResizeLayout == nil && tilingView.collapsedPaneIDs.isEmpty
                ? tabState.layoutNode : tilingView.layoutNode,
            let context = layoutNode.ancestorSplitContexts(for: focusedPaneID).reversed()
                .first(where: { $0.axis == axis && $0.fractions.count > 1 }),
            let splitNode = layoutNode.node(at: context.splitPath)
        else {
            return nil
        }

        return (context, splitNode, layoutNode, tilingView)
    }

    private func movedDividerFractions(
        in context: ParentSplitContext,
        direction: PaneDividerMoveDirection,
        restoringFrom originalFractions: [CGFloat],
        step: CGFloat = 0.05
    ) -> (fractions: [CGFloat], neighboringIndex: Int)? {
        let focusedIndex = context.focusedChildIndex
        guard context.fractions.indices.contains(focusedIndex),
            originalFractions.count == context.fractions.count
        else {
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
        if fractions[focusedIndex] == 0 || fractions[neighboringIndex] == 0 {
            // Restore only the resized pair, leaving other folded siblings at zero.
            let budget = fractions[focusedIndex] + fractions[neighboringIndex]
            let originalBudget = originalFractions[focusedIndex] + originalFractions[neighboringIndex]
            guard originalBudget > 0 else { return nil }
            fractions[focusedIndex] = budget * originalFractions[focusedIndex] / originalBudget
            fractions[neighboringIndex] = budget * originalFractions[neighboringIndex] / originalBudget
        }
        fractions[focusedIndex] += focusedDelta
        fractions[neighboringIndex] -= focusedDelta
        return (fractions, neighboringIndex)
    }

    private func performClosePane(withID paneID: PaneID) {
        guard let tabState = tabState(containing: paneID) else {
            return
        }

        performClosePane(withID: paneID, in: tabState)
    }

    private func performClosePane(withID paneID: PaneID, in tabState: WorkspaceTabState, forCLI: Bool = false) {
        if let pane = tabState.paneControllers[paneID], closeHerdrPanes([pane], then: { [weak self, weak tabState] in
            guard let self, let tabState else { return }
            self.performClosePane(withID: paneID, in: tabState)
        }) { return }

        if tabState === sidebar.tab {
            guard let result = tabState.layoutNode?.closingPane(paneID) else { return }
            leaveFloatingPane(in: tabState, animated: false, reapplyAutoZoom: false)
            removePaneControllerState(for: paneID, in: tabState)
            tabState.layoutNode = result.root
            if tabState.focusedPaneID == paneID {
                tabState.focusedPaneID = result.promotedPaneID ?? result.root?.firstPaneID
            }
            if result.root == nil { sidebar.isVisible = false; sidebarIsFocused = false }
            rebuildSidebar()
            applyFocusedPaneResponder()
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
                if forCLI { cliRemoveEmptyTab(tabState) }
                else { closeTab(withID: tabState.id, bypassTabConfirmation: true) }
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
            if tabState.focusedPaneID == paneID {
                tabState.focusedPaneID = closePaneResult.promotedPaneID ?? root.firstPaneID
            }
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

        if forCLI { cliRemoveEmptyTab(tabState) }
        else { closeTab(withID: tabState.id, bypassTabConfirmation: true) }
    }

    private func closeHerdrPanes(_ panes: [any PaneControlling], then completion: @escaping @MainActor () -> Void) -> Bool {
        let terminals = panes.compactMap { $0 as? TerminalPaneController }.filter { $0.herdrSession != nil && $0.herdrSession?.state != .finished }
        guard !terminals.isEmpty else { return false }
        let ids = Set(terminals.map(\.id))
        guard closingHerdrPaneIDs.isDisjoint(with: ids) else { return true }
        closingHerdrPaneIDs.formUnion(ids)
        Task { [weak self] in
            guard let self else { return }
            defer { self.closingHerdrPaneIDs.subtract(ids) }
            do {
                for terminal in terminals { try await terminal.herdrSession?.closeTerminal() }
                completion()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could Not Close Herdr Terminal"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        return true
    }

    private func removePaneControllerState(for paneID: PaneID, in tabState: WorkspaceTabState) {
        tabState.paneControllers.removeValue(forKey: paneID)
        tabState.paneAutoResizeConfigurations.removeValue(forKey: paneID)
        tabState.floatingPaneSizes.removeValue(forKey: paneID)
        tabState.removePaneFromFocusHistory(paneID)
    }



    private func handlePaneFocusRequest(withID paneID: PaneID) {
        if sidebar.tab.containsPane(withID: paneID) { focusSidebarPane(paneID); return }
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
        if sidebar.tab.containsPane(withID: paneID) { focusSidebarPane(paneID); return }
        guard let tabState = selectedTabState, tabState.containsPane(withID: paneID) else { return }
        let changedRegion = sidebarIsFocused
        sidebarIsFocused = false
        recordWindowFocus(paneID)
        updatePanePresentation(in: sidebar.tab)
        if changedRegion, let selectedTabState {
            updatePanePresentation(in: selectedTabState)
            applyFocusedPaneResponder()
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

        tabState.focusedPaneID = paneID
        tabState.markPaneFocused(paneID)

        applyAutoZoomToFocusedPane(in: tabState, animated: true)
        updatePanePresentation(in: tabState)
        updateTabStrip()
        updateWindowTitle()
        applyFocusedPaneResponder()
    }

    private func focusPane(in direction: PaneFocusDirection) {
        guard view.window?.attachedSheet == nil else { return }
        guard
            let tabState = activePaneTab,
            let focusedPaneID = tabState.focusedPaneID,
            let targetPaneID = directionalTiledPaneTarget(
                from: focusedPaneID,
                direction: direction,
                in: tabState, acrossWindow: sidebar.isVisible
            )
        else {
            return
        }

        focusPane(withID: targetPaneID)
    }

    private func directionalTiledPaneTarget(
        from focusedPaneID: PaneID,
        direction: PaneFocusDirection,
        in tabState: WorkspaceTabState, acrossWindow: Bool = false
    ) -> PaneID? {
        var unfoldedFrames: [PaneID: NSRect] = [:]
        if let tilingView, !tilingView.collapsedPaneIDs.isEmpty,
            let layoutNode = selectedTabState?.layoutNode
        {
            let layout = TilingLayout.compute(
                node: layoutNode, rect: tilingView.bounds,
                dividerThickness: AppAppearanceSettings.workspaceDividerThickness)
            unfoldedFrames = Dictionary(uniqueKeysWithValues: layout.panePlacements.map {
                ($0.paneID, tilingView.convert($0.frame, to: view))
            })
        }
        guard let focusedFrame = unfoldedFrames[focusedPaneID]
            ?? renderedPaneFrame(for: focusedPaneID, in: tabState)
        else {
            return nil
        }

        let owners = acrossWindow ? ([selectedTabState].compactMap { $0 } + (sidebar.isVisible ? [sidebar.tab] : [])) : [tabState]
        return owners.flatMap { owner in owner.paneControllers.keys.map { ($0, owner) } }
            .compactMap { paneID, owner -> DirectionalPaneCandidate? in
                guard paneID != focusedPaneID,
                    owner.isPaneTiled(paneID),
                    let candidateFrame = unfoldedFrames[paneID]
                        ?? renderedPaneFrame(for: paneID, in: owner)
                else {
                    return nil
                }

                return DirectionalPaneCandidate(
                    paneID: paneID,
                    score: directionalFocusScore(
                        from: focusedFrame,
                        to: candidateFrame,
                        direction: direction,
                        focusRecency: acrossWindow ? (windowFocusHistory.firstIndex(of: paneID) ?? owner.focusRecency(for: paneID).map { windowFocusHistory.count + $0 }) : tabState.focusRecency(for: paneID)
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

                return lhsScore == rhsScore ? lhs.paneID.uuidString < rhs.paneID.uuidString : lhsScore < rhsScore
            }?
            .paneID
    }

    private func renderedPaneFrame(for paneID: PaneID, in tabState: WorkspaceTabState) -> NSRect? {
        guard let hostView = tabState.paneControllers[paneID]?.hostView,
            hostView.superview != nil, !hostView.isHidden
        else {
            return nil
        }

        view.layoutSubtreeIfNeeded()
        let frame = hostView.convert(hostView.bounds, to: view)
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

        return floatingRootView(for: tabState).floatingPaneFrame(for: hostView)
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
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        sidebarIsFocused = false
        updatePanePresentation(in: sidebar.tab)

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

    private func closeTab(withID tabID: UUID, bypassTabConfirmation: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }

        let tabState = tabs[index]

        if tabs.count == 1, !otherLocalWorkspaces.isEmpty {
            guard bypassTabConfirmation || confirmCloseTabIfNeeded(tabState) else { return }
            removeCurrentLocalWorkspace()
            return
        }
        if tabs.count == 1 {
            if !bypassTabConfirmation, tabState.paneControllers.values.contains(where: { ($0 as? TerminalPaneController)?.herdrSession != nil }),
               !confirmCloseTabIfNeeded(tabState) { return }
            if closeHerdrPanes(Array(tabState.paneControllers.values), then: { [weak self] in self?.closeTab(withID: tabID, bypassTabConfirmation: true) }) { return }
            guard confirmCloseWindowIfNeeded() else {
                return
            }

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

        if closeHerdrPanes(Array(tabState.paneControllers.values), then: { [weak self] in self?.closeTab(withID: tabID, bypassTabConfirmation: true) }) { return }

        let wasSelected = selectedTabID == tabID
        if wasSelected {
            leaveFloatingPane(in: tabState, animated: false, reapplyAutoZoom: false)
            hideActiveDetachedPane(in: tabState, animated: false, reapplyAutoZoom: false)
            clearActiveAutoZoomState(in: tabState, restoreLayout: true, animated: false)
        }

        tabs.remove(at: index)

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

    private func updateSelectedTabTitle(_ title: String) {
        guard let selectedTabState else {
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.utf8.count <= 1024 else { NSSound.beep(); return }

        selectedTabState.customTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        scheduleWorkspaceSave()
        updateTabStrip()
        updateWindowTitle()
    }

    private func handleTitleChange(for paneID: PaneID) {
        guard let tabState = tabState(containing: paneID) else {
            return
        }

        updatePanePresentation(in: tabState)

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
        if sidebarIsFocused { return false }
        guard let tabState = selectedTabState,
            let focusedPaneID = tabState.focusedPaneID,
            tabState.isPaneTiled(focusedPaneID)
        else {
            return false
        }

        return tabState.detachedPaneIDs.count < 9
    }

    private func canAttachFocusedDetachedPane() -> Bool {
        if sidebarIsFocused { return false }
        guard let tabState = selectedTabState,
            let focusedPaneID = tabState.focusedPaneID
        else {
            return false
        }

        return tabState.activeDetachedPaneID == focusedPaneID
            && tabState.isPaneDetached(focusedPaneID)
    }

    private func canToggleFloatingPane() -> Bool {
        guard let tabState = activePaneTab else {
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
        tabState.focusedPaneID = closePaneResult.promotedPaneID.flatMap { tabState.isPaneTiled($0) ? $0 : nil } ?? tabState.lastFocusedTiledPaneID
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
        let rootView = floatingRootView(for: tabState)

        guard
            tabState.id == selectedTabID || tabState === sidebar.tab && sidebar.isVisible,
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
        if tabState === sidebar.tab {
            rebuildSidebar(restoreFloatingPresentation: false)
        } else {
            rebuildWorkspaceLayout(applyAutoZoomAnimated: false, restoreFloatingPresentation: false)
        }

        let targetFrame = rootView.floatingPaneTargetFrame()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = WorkspaceFloatingPaneConfiguration.animationDuration
                rootView.animateFloatingPaneFrame(to: targetFrame)
            } completionHandler: { [weak self, weak rootView] in
                Task { @MainActor in
                    rootView?.finishFloatingPaneAnimation()
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
        let rootView = floatingRootView(for: tabState)

        guard
            tabState.id == selectedTabID || tabState === sidebar.tab && sidebar.isVisible,
            let floatingPaneState = tabState.activeFloatingPaneState,
            let paneController = tabState.paneControllers[floatingPaneState.paneID]
        else {
            tabState.activeFloatingPaneState = nil
            return
        }

        let destinationFrame: NSRect
        if tabState === sidebar.tab, let placeholder = windowContentView.sidebarView.paneViews[floatingPaneState.paneID] {
            destinationFrame = rootView.floatingPaneFrame(for: placeholder) ?? paneController.hostView.frame
        } else {
            destinationFrame = rootView.placeholderFrame(for: floatingPaneState.paneID) ?? paneController.hostView.frame
        }

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
        let rootView = floatingRootView(for: tabState)
        if let floatingState = tabState.activeFloatingPaneState,
            let size = floatingState.size
        {
            tabState.floatingPaneSizes[floatingState.paneID] = size
        }

        tabState.activeFloatingPaneState = nil
        if tabState === sidebar.tab { rebuildSidebar() }
        else { rebuildWorkspaceLayout(applyAutoZoomAnimated: reapplyAutoZoom) }
        rootView.removeFloatingPaneView()
        applyFocusedPaneResponder()
    }

    private func clearFloatingPaneImmediately(
        in tabState: WorkspaceTabState,
        reapplyAutoZoom: Bool
    ) {
        let rootView = floatingRootView(for: tabState)

        if let floatingState = tabState.activeFloatingPaneState,
            let paneController = tabState.paneControllers[floatingState.paneID],
            let size = rootView.floatingPaneFrame(for: paneController.hostView)?.size
        {
            tabState.floatingPaneSizes[floatingState.paneID] = size
        }

        tabState.activeFloatingPaneState = nil
        if tabState === sidebar.tab { rebuildSidebar() }
        else { rebuildWorkspaceLayout(applyAutoZoomAnimated: reapplyAutoZoom) }
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

        if tilingView == nil {
            let newTilingView = WorkspaceTilingView(
                dividerThickness: AppAppearanceSettings.workspaceDividerThickness
            )
            newTilingView.onFractionsChange = { [weak self] path, fractions, source in
                self?.updateSplitFractions(
                    at: path, to: fractions, changeSource: source
                )
            }
            tilingView = newTilingView
            rootView.installRenderedContentView(newTilingView)
        }

        view.layoutSubtreeIfNeeded()
        // Apply the final auto-resized layout without first resizing terminals to the model layout.
        if !applyPreservedActiveAutoZoom(in: tabState) {
            if tabState.activeFloatingPaneState == nil,
                let focusedPaneID = tabState.focusedPaneID,
                tabState.isPaneTiled(focusedPaneID)
            {
                applyAutoZoomToFocusedPane(in: tabState, animated: applyAutoZoomAnimated)
            } else {
                tilingView?.setLayoutNode(layoutNode, paneViews: buildPaneViewsDictionary(for: tabState))
            }
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
        let rootView = floatingRootView(for: tabState)
        captureFloatingPaneSizes(in: tabState)
        rootView.removeFloatingPaneView()
    }

    private func captureFloatingPaneSizes(in tabState: WorkspaceTabState) {
        let rootView = floatingRootView(for: tabState)
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
    }

    private func restoreActiveFloatingPresentation(in tabState: WorkspaceTabState) {
        let rootView = floatingRootView(for: tabState)
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
        let rootView = floatingRootView(for: tabState)
        guard tabState.id == selectedTabID || tabState === sidebar.tab && sidebar.isVisible,
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
            guard tabState.layoutNode?.path(to: paneID) != nil else {
                continue
            }

            if tabState.activeFloatingPaneState?.paneID == paneID || tabState.isPaneDetached(paneID) {
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
        guard let tabState = selectedTabState, let layoutNode = tabState.layoutNode else {
            return
        }

        if changeSource == .userDrag,
            tabState.manualResizeLayout != nil || tilingView?.collapsedPaneIDs.isEmpty == false,
            let focusedPaneID = tabState.focusedPaneID,
            let renderedNode = tilingView?.layoutNode
        {
            tabState.manualResizeLayout = (focusedPaneID, renderedNode)
            tabState.activeAutoZoomState = nil
        } else if tabState.activeAutoZoomState?.splitStates.contains(where: { $0.splitPath == path })
            == true
        {
            tabState.activeAutoZoomState = nil
        }

        var savedFractions = fractions
        if changeSource == .userDrag,
            case .split(_, _, let originalFractions) = layoutNode.node(at: path),
            fractions.contains(0)
        {
            let foldedBudget = fractions.indices.filter { fractions[$0] == 0 }
                .reduce(CGFloat.zero) { $0 + originalFractions[$1] }
            savedFractions = fractions.indices.map {
                fractions[$0] == 0 ? originalFractions[$0] : fractions[$0] * (1 - foldedBudget)
            }
        }
        tabState.layoutNode = layoutNode.replacingFractions(at: path, with: savedFractions)
        updateWindowMinimumSize()
        scheduleWorkspaceSave()
    }

    private func restoreActiveAutoZoom(in tabState: WorkspaceTabState, animated: Bool) {
        guard tabState.activeAutoZoomState != nil || tabState.manualResizeLayout != nil,
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
        tabState.manualResizeLayout = nil
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
        tabState.manualResizeLayout = nil
    }

    private func applyAutoZoomToFocusedPane(in tabState: WorkspaceTabState, animated: Bool) {
        guard tabState.activeFloatingPaneState == nil else {
            return
        }

        tabState.manualResizeLayout = nil
        guard
            let focusedPaneID = tabState.focusedPaneID,
            tabState.isPaneTiled(focusedPaneID)
        else {
            tabState.activeAutoZoomState = nil
            return
        }

        let targetStates = autoZoomTargetStates(for: focusedPaneID, in: tabState)
        guard !targetStates.isEmpty else {
            tabState.activeAutoZoomState = nil
            applyAutoZoomTargetStates([], animated: animated)
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
        if let manualLayout = tabState.manualResizeLayout,
            manualLayout.focusedPaneID == tabState.focusedPaneID,
            manualLayout.node.paneIDsInTraversalOrder == tabState.layoutNode?.paneIDsInTraversalOrder,
            let tilingView
        {
            tilingView.setLayoutNode(
                manualLayout.node, paneViews: buildPaneViewsDictionary(for: tabState),
                animated: false, isTransient: true)
            return true
        }
        tabState.manualResizeLayout = nil
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
            let tilingView
        else {
            return []
        }

        let paneIDs = layoutNode.paneIDsInTraversalOrder
        var seenPaths: Set<[LayoutPathComponent]> = []
        let contexts = paneIDs.flatMap { layoutNode.ancestorSplitContexts(for: $0) }
            .filter { seenPaths.insert($0.splitPath).inserted }
        var targetNode = layoutNode

        func applyRatios(for paneID: PaneID, configuration: PaneAutoResizeConfiguration) {
            for context in targetNode.ancestorSplitContexts(for: paneID) {
                let axisIsEnabled = context.axis == .horizontal
                    ? configuration.isHorizontalEnabled : configuration.isVerticalEnabled
                guard axisIsEnabled,
                    let splitNode = targetNode.node(at: context.splitPath)
                else { continue }
                if configuration.trigger == .unfocused,
                    case .split(_, let children, _) = splitNode,
                    children[context.focusedChildIndex].path(to: focusedPaneID) != nil
                { continue }
                let ratio = configuration.ratios[context.axis]
                let proposedFractions = context.replacingFocusedChildFraction(ratio)
                let targetFractions = splitNode.clampedFractions(
                    proposedFractions,
                    in: tilingView.bounds.size,
                    dividerThickness: AppAppearanceSettings.workspaceDividerThickness,
                    collapsedChildIndices: Set(context.fractions.indices.filter {
                        proposedFractions[$0] == 0
                            && (context.fractions[$0] == 0 || $0 == context.focusedChildIndex && ratio == 0)
                    }))
                if let updated = targetNode.replacingFractions(at: context.splitPath, with: targetFractions) {
                    targetNode = updated
                }
            }
        }

        for paneID in paneIDs where paneID != focusedPaneID {
            if let config = tabState.paneAutoResizeConfigurations[paneID],
                config.isEnabled, config.trigger == .unfocused
            {
                applyRatios(for: paneID, configuration: config)
            }
        }
        if let config = tabState.paneAutoResizeConfigurations[focusedPaneID],
            config.isEnabled, config.trigger == .focus
        {
            applyRatios(for: focusedPaneID, configuration: config)
        }

        return contexts.compactMap { context in
            guard case .split(_, _, let targetFractions) = targetNode.node(at: context.splitPath),
                targetFractions != context.fractions
            else { return nil }
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
        tilingView.setLayoutNode(
            autoZoomedNode, paneViews: paneViews, animated: animated,
            isTransient: !targetStates.isEmpty)
    }

    private func updatePanePresentation(in tabState: WorkspaceTabState) {
        for (paneID, paneController) in tabState.paneControllers {
            paneController.setNameVisible(paneNamesVisible && (tabState.id == selectedTabID || tabState === sidebar.tab && sidebar.isVisible))
            paneController.updatePresentation(
                isFocused: paneID == tabState.focusedPaneID && (tabState === sidebar.tab ? sidebarIsFocused : !sidebarIsFocused && tabState.id == selectedTabID),
                isFloating: tabState.activeFloatingPaneState?.paneID == paneID
                    || tabState.activeDetachedPaneID == paneID
            )
        }
    }

    private func updateTabStrip() {
        scheduleWorkspaceSave()
        updateAgentPresentation()
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
    }

    private var currentWindowPaneIDs: Set<PaneID> {
        Set(tabs.flatMap { $0.paneControllers.keys })
    }

    private func updateAppearance() {
        windowContentView.needsLayout = true
        rootView.updateAppearance()
        windowContentView.sidebarView.updateDividerThickness(AppAppearanceSettings.workspaceDividerThickness)
        updatePanePresentation(in: sidebar.tab)
        tilingView?.updateDividerThickness(AppAppearanceSettings.workspaceDividerThickness)
        if let window = view.window {
            AppAppearanceDefaults.applyWindowPresentation(
                to: window,
                isWindowHidden: AppAppearanceSettings.isWindowHidden,
                cornerRadius: AppAppearanceSettings.windowCornerRadius
            )
        }
        for tabState in paneOwnerTabs {
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
            AppCommand(id: "sidebar.toggle", title: KeybindingAction.toggleSidebar.title, shortcut: KeybindingSettings.displayShortcut(for: .toggleSidebar), isEnabled: true, perform: { [weak self] in self?.toggleSidebar(nil) }),
            AppCommand(id: "sidebar.left", title: "Move Sidebar Left", shortcut: nil, isEnabled: true, perform: { [weak self] in self?.moveSidebarLeft(nil) }),
            AppCommand(id: "sidebar.right", title: "Move Sidebar Right", shortcut: nil, isEnabled: true, perform: { [weak self] in self?.moveSidebarRight(nil) }),
            AppCommand(id: "sidebar.browser", title: "Add Browser to Sidebar", shortcut: nil, isEnabled: true, perform: { [weak self] in self?.addSidebarBrowser(nil) }),
            AppCommand(id: "sidebar.workspaces", title: "Add Workspaces to Sidebar", shortcut: nil, isEnabled: true, perform: { [weak self] in self?.addSidebarWorkspaces(nil) }),
            AppCommand(id: "sidebar.agents", title: "Add Agents to Sidebar", shortcut: nil, isEnabled: true, perform: { [weak self] in self?.addSidebarAgents(nil) }),
            AppCommand(id: "agents.show", title: KeybindingAction.showAgents.title, shortcut: KeybindingSettings.displayShortcut(for: .showAgents), isEnabled: !isClosingWindow, perform: { [weak self] in self?.showAgentManager(nil) }),
            AppCommand(id: "workspace.new", title: "New Local Workspace", shortcut: KeybindingSettings.displayShortcut(for: .newWorkspace), isEnabled: canCreateLocalWorkspace, perform: { [weak self] in self?.newWorkspace(nil) }),
            AppCommand(id: "workspace.rename", title: "Rename Workspace", shortcut: KeybindingSettings.displayShortcut(for: .renameWorkspace), isEnabled: canCloseWorkspace, perform: { [weak self] in self?.renameWorkspace(nil) }),
            AppCommand(id: "workspace.new.herdr.remote", title: "New Remote Herdr Workspace…", shortcut: nil, isEnabled: canCreateLocalWorkspace, perform: { [weak self] in self?.newRemoteHerdrWorkspace(nil) }),
            AppCommand(id: "workspace.new.herdr", title: "New Herdr Workspace", shortcut: nil, isEnabled: canCreateLocalWorkspace, perform: { [weak self] in self?.newHerdrWorkspace(nil) }),
            AppCommand(id: "workspace.close", title: "Close Workspace", shortcut: KeybindingSettings.displayShortcut(for: .closeWorkspace), isEnabled: canCloseWorkspace, perform: { [weak self] in self?.closeWorkspace(nil) }),

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
                isEnabled: canSplitFocusedPane,
                perform: { [weak self] in self?.splitPaneHorizontally(nil) }
            ),
            AppCommand(
                id: "pane.split.vertical",
                title: "Split Vertically",
                shortcut: KeybindingSettings.displayShortcut(for: .splitPaneVertically),
                isEnabled: canSplitFocusedPane,
                perform: { [weak self] in self?.splitPaneVertically(nil) }
            ),
            AppCommand(
                id: "pane.terminal.new",
                title: "New Terminal Pane",
                shortcut: nil,
                isEnabled: canSplitFocusedPane,
                perform: { [weak self] in self?.newTerminalPane(nil) }
            ),
            AppCommand(
                id: "pane.workspaces.new",
                title: "New Workspaces Pane",
                shortcut: nil,
                isEnabled: focusedPaneController != nil && focusedPaneIsTiled,
                perform: { [weak self] in self?.newWorkspacesPane(nil) }
            ),
            AppCommand(
                id: "pane.agents.new",
                title: "New Agents Pane",
                shortcut: nil,
                isEnabled: focusedPaneController != nil && focusedPaneIsTiled,
                perform: { [weak self] in self?.newAgentsPane(nil) }
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
                isEnabled: !sidebarIsFocused && focusedBrowserPaneController != nil && focusedPaneIsTiled,
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
                    && (activePaneTab?.tiledPaneIDsInTraversalOrder.count ?? 0) > 1,
                perform: { [weak self] in self?.focusPreviousPane(nil) }
            ),
            AppCommand(
                id: "pane.focus.next",
                title: "Focus Next Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusNextPane),
                isEnabled: focusedPaneIsTiled
                    && (activePaneTab?.tiledPaneIDsInTraversalOrder.count ?? 0) > 1,
                perform: { [weak self] in self?.focusNextPane(nil) }
            ),
            AppCommand(
                id: "pane.focus.left",
                title: "Focus Left Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusLeftPane),
                isEnabled: focusedPaneIsTiled && visibleTiledPaneCount > 1,
                perform: { [weak self] in self?.focusLeftPane(nil) }
            ),
            AppCommand(
                id: "pane.focus.right",
                title: "Focus Right Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusRightPane),
                isEnabled: focusedPaneIsTiled && visibleTiledPaneCount > 1,
                perform: { [weak self] in self?.focusRightPane(nil) }
            ),
            AppCommand(
                id: "pane.focus.above",
                title: "Focus Above Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusAbovePane),
                isEnabled: focusedPaneIsTiled && visibleTiledPaneCount > 1,
                perform: { [weak self] in self?.focusAbovePane(nil) }
            ),
            AppCommand(
                id: "pane.focus.below",
                title: "Focus Below Pane",
                shortcut: KeybindingSettings.displayShortcut(for: .focusBelowPane),
                isEnabled: focusedPaneIsTiled && visibleTiledPaneCount > 1,
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
                isEnabled: !sidebarIsFocused && focusedPaneController != nil && focusedPaneIsTiled,
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
                id: "tab.rename",
                title: "Rename Tab",
                shortcut: KeybindingSettings.displayShortcut(for: .renameTab),
                isEnabled: selectedTabState != nil && canCloseWorkspace,
                perform: { [weak self] in self?.renameTab(nil) }
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
            WorkspaceLayoutMetrics.workspaceSectionSpacing
            + WorkspaceLayoutMetrics.tabStripHeight

        var minimumSize = selectedTabState?.layoutNode?.minimumSize(
            dividerThickness: AppAppearanceSettings.workspaceDividerThickness
        ) ?? WorkspaceLayoutMetrics.minimumPaneSize
        let mainMinimumWidth = minimumSize.width
        let sidebarMinimum = sidebar.tab.layoutNode?.minimumSize(dividerThickness: AppAppearanceSettings.workspaceDividerThickness)
            ?? WorkspaceLayoutMetrics.minimumPaneSize
        windowContentView.updateMinimumWidths(main: mainMinimumWidth, sidebar: sidebarMinimum.width)
        if sidebar.isVisible {
            minimumSize.width += sidebarMinimum.width + AppAppearanceSettings.workspaceDividerThickness
            minimumSize.height = max(minimumSize.height, sidebarMinimum.height)
        }
        let paddedMinimumSize = NSSize(
            width: minimumSize.width + AppAppearanceSettings.workspaceEdgePadding * 2,
            height: minimumSize.height + tabChromeHeight + AppAppearanceSettings.workspaceEdgePadding * 2
        )
        view.window?.contentMinSize = NSSize(
            width: max(
                WorkspaceLayoutMetrics.minimumWindowContentSize.width, paddedMinimumSize.width),
            height: max(
                WorkspaceLayoutMetrics.minimumWindowContentSize.height, paddedMinimumSize.height)
        )
    }

    private func applyFocusedPaneResponder() {
        guard !cliPreservingResponder, hasAppeared, let window = view.window else {
            return
        }

        if let focusedPaneController = activePaneTab?.focusedPaneController {
            recordWindowFocus(focusedPaneController.id)
            window.makeFirstResponder(focusedPaneController.focusTargetView)
            focusedPaneController.fitToSize()
        } else {
            window.makeFirstResponder(rootView)
        }
        PaneInputSourceCoordinator.shared.refresh()
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

        tabState.paneAutoResizeConfigurations[paneID] = configuration
        applyAutoZoomToFocusedPane(in: tabState, animated: true)
        scheduleWorkspaceSave()
    }

    private func startPaneControllersIfNeeded(in tabState: WorkspaceTabState, allowFocus: Bool = true) {
        for pane in tabState.paneControllers.values {
            // Empty browsers start by focusing their address field. Background CLI
            // operations must leave that to an explicit later focus/presentation.
            if pane is BrowserPaneController, !allowFocus || cliPreservingResponder { continue }
            pane.startIfNeeded()
        }
    }

    private func tabState(containing paneID: PaneID) -> WorkspaceTabState? {
        ([sidebar.tab] + tabs).first { $0.containsPane(withID: paneID) }
    }

    private func confirmCloseWindowIfNeeded() -> Bool {
        guard paneOwnerTabs.flatMap({ Array($0.paneControllers.values) }).contains(where: { ($0 as? TerminalPaneController)?.herdrSession == nil && $0.isLive })
        else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close Window?"
        alert.informativeText = "Local terminal processes will close. Herdr terminals will keep running."
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
        alert.informativeText = "Terminal processes in this tab will end. External agent viewers only detach."
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func requestWindowClose(workspaceSaveConfirmed: Bool = false) {
        didRequestWindowCloseForTesting = true

        guard let window = view.window else {
            return
        }

        if !workspaceSaveConfirmed, workspaceStore != nil, workspacePersistenceActivated {
            Task { [weak self] in
                guard let self, await self.confirmWorkspaceSaveForClose() else { return }
                self.bypassNextWindowCloseConfirmation = true
                window.performClose(nil)
            }
        } else {
            bypassNextWindowCloseConfirmation = true
            window.performClose(nil)
        }
    }
}

extension WorkspaceViewController {
    private func configureAgents() {
        let store = herdrCoreClient.agents
        store.context = { [weak self] binding in self?.agentContext(binding) }
        store.isTargetVisible = { [weak self] binding in self?.agentIsVisible(binding) == true }
        rootView.toolbarView.agentStatusButton.target = self
        rootView.toolbarView.agentStatusButton.action = #selector(showAgentManager(_:))
        agentObserver = NotificationCenter.default.addObserver(forName: AgentSessionStore.didChangeNotification,
            object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAgentPresentation() }
            }
        for name in [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification] {
            paneNameFocusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAgentPresentation() }
            })
        }
    }

    private func agentLocation(_ binding: HerdrTerminalBinding) -> (UUID, WorkspaceTabState, TerminalPaneController)? {
        let locations = localWorkspaceStates.flatMap { workspace in workspace.tabs.map { (workspace.id, $0) } }
            + [(localWorkspaceID, sidebar.tab)]
        for (workspaceID, tab) in locations {
            for pane in tab.paneControllers.values {
                if let terminal = pane as? TerminalPaneController, let owned = terminal.herdrSession?.binding,
                   owned.coreID == binding.coreID, owned.address == binding.address,
                   (owned.remote == true) == (binding.remote == true) { return (workspaceID, tab, terminal) }
            }
        }
        return nil
    }

    private func agentContext(_ binding: HerdrTerminalBinding) -> AgentTerminalContext? {
        if let (workspaceID, tab, pane) = agentLocation(binding), let workspace = localWorkspaceStates.first(where: { $0.id == workspaceID }) {
            let paneName = pane.name ?? pane.displayTitle
            if tab === sidebar.tab { return AgentTerminalContext(paneName: paneName, location: "Sidebar") }
            return AgentTerminalContext(
                paneName: paneName,
                location: [workspace.name, tab.displayTitle].joined(separator: " › ")
            )
        }
        let machine = binding.remote == true ? herdrCoreClient.machines.first { $0.id == binding.coreID }?.name ?? "Remote" : "Local herdr-core"
        return AgentTerminalContext(paneName: nil, location: machine + " › " + binding.address)
    }

    private func agentIsVisible(_ binding: HerdrTerminalBinding) -> Bool {
        guard view.window?.isKeyWindow == true, NSApp.isActive,
              let (workspace, tab, pane) = agentLocation(binding), workspace == localWorkspaceID,
              tab === sidebar.tab ? sidebar.isVisible : tab.id == selectedTabID,
              pane.herdrSession?.state == .live else { return false }
        return tab.isPaneTiled(pane.id) || tab.activeDetachedPaneID == pane.id
    }

    private func updateAgentPresentation() {
        let store = herdrCoreClient.agents
        let sessions = store.snapshots
        rootView.toolbarView.updateAgents(count: sessions.count, unread: store.unreadCount)
        agentPopover?.updateSessions(sessions, messages: store.messageSnapshots)
        for tab in paneOwnerTabs {
            for case let pane as AgentsPaneController in tab.paneControllers.values {
                pane.update(sessions: sessions, messages: store.messageSnapshots)
            }
        }
        let visible = sessions.filter { $0.isUnread && agentIsVisible($0.binding) }
        guard !visible.isEmpty else { return }
        Task { @MainActor [weak self, weak store] in
            await Task.yield()
            guard let self, let store else { return }
            store.markViewed(visible.filter { self.agentIsVisible($0.binding) })
        }
    }

    @objc func showAgentManager(_: Any?) {
        guard !isClosingWindow, view.window != nil else { return }
        herdrCoreClient.startAgentMonitoring()
        if agentPopover?.isShown == true { agentPopover?.close(); return }
        let store = herdrCoreClient.agents
        let popover = AgentManagerPopoverController(sessions: store.snapshots,
            previousFirstResponder: view.window?.firstResponder,
            onFocusPane: { [weak self, weak store] session in
                store?.acknowledge(session)
                self?.navigateToAgent(session.binding)
            },
            onClose: { [weak self] in self?.agentPopover = nil })
        agentPopover = popover
        popover.updateSessions(store.snapshots, messages: store.messageSnapshots)
        let anchor = rootView.toolbarView.agentStatusButton.isHidden ? rootView.toolbarView : rootView.toolbarView.agentStatusButton
        popover.show(relativeTo: anchor)
    }

    func navigateToAgent(_ binding: HerdrTerminalBinding) {
        agentNavigationTask?.cancel()
        agentNavigationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let terminal = try await herdrCoreClient.terminal(binding)
                try Task.checkCancellation()
                guard !isClosingWindow, closingHerdrPaneIDs.isEmpty else { throw CLIError("Finish the current close operation before opening an agent") }
                if let (workspace, tab, pane) = agentLocation(binding) {
                    if tab === sidebar.tab {
                        if !sidebar.isVisible { toggleSidebar(nil) }
                        focusSidebarPane(pane.id)
                    } else {
                        navigateFromPalette(workspaceID: workspace, tabID: tab.id, paneID: pane.id)
                    }
                } else {
                    guard terminal.state == "live" else { throw CLIError("This agent terminal has ended") }
                    let remote: HerdrRemote?
                    if binding.remote == true {
                        guard let machine = herdrCoreClient.machines.first(where: { $0.id == binding.coreID }) else { throw CLIError("This agent's remote core is not configured") }
                        remote = machine.reference
                    } else { remote = nil }
                    if let workspace = localWorkspaceStates.first(where: { $0.kind == .herdr && $0.remote?.id == remote?.id }) {
                        guard allWorkspaceTabs.count < 64 else { throw CLIError("Workspace tab limit reached") }
                        selectLocalWorkspace(workspace.id)
                        let pane = makeTerminalPaneController(workingDirectory: terminal.cwd, binding: binding, viewerOnly: true)
                        let tab = makeTabState(startImmediately: false, terminal: pane)
                        tabs.append(tab); selectedTabID = tab.id
                        finishLocalWorkspaceSwitch()
                    } else {
                        guard canCreateLocalWorkspace else { throw CLIError("Workspace limit reached") }
                        createWorkspace(kind: .herdr, remote: remote, viewer: binding)
                    }
                }
                rootView.toolbarView.showNavigationStatus(nil)
                updateAgentPresentation()
            } catch is CancellationError { }
            catch { rootView.toolbarView.showNavigationStatus("Agent unavailable: " + error.localizedDescription) }
        }
    }

    var canSendAgentNotifications: Bool { workspaceStore?.canWrite != false }
    var debugAgentSnapshots: [AgentSessionSnapshot] { herdrCoreClient.agents.snapshots }
}

extension WorkspaceViewController {

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
    var debugIsFloatingPaneAnimating: Bool { rootView.debugIsFloatingPaneAnimating }
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
        guard let tabState = activePaneTab else {
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

extension WorkspaceViewController {

    private func refreshWorkspacePicker() {
        workspaceEntries = localWorkspaceStates.map { .init(reference: $0.id, name: $0.name, kind: $0.kind, remote: $0.remote) }
        rootView.toolbarView.updateWorkspaceEntries(workspaceEntries, selectedID: workspaceKind.rawValue + "." + localWorkspaceID.uuidString)
        updateWorkspaceLists()
    }

    @objc func renameWorkspace(_: Any?) {
        guard canCloseWorkspace else { return }
        let localID = localWorkspaceID
        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.usesSingleLineMode = true
        field.stringValue = localWorkspaceName
        field.placeholderString = "Workspace name"
        field.selectText(nil)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              localID == localWorkspaceID else { return }
        updateSelectedWorkspaceName(field.stringValue)
    }

    func updateSelectedWorkspaceName(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canCloseWorkspace, !name.isEmpty, name.utf8.count <= 1024 else { NSSound.beep(); return }

        localWorkspaceName = name
        refreshWorkspacePicker()
        scheduleWorkspaceSave()

    }

    @objc func newWorkspace(_: Any?) { createWorkspace(kind: .local) }

    @objc func newHerdrWorkspace(_: Any?) { createWorkspace(kind: .herdr) }

    @objc func newRemoteHerdrWorkspace(_: Any?) {
        guard canCreateLocalWorkspace else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let machines = try await self.herdrCoreClient.configuredMachines().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                guard self.canCreateLocalWorkspace else { return }
                let alert = NSAlert()
                alert.messageText = "New Remote Herdr Workspace"
                guard !machines.isEmpty else {
                    alert.informativeText = "No machines configured. Add one with hc machine add, then try again."
                    alert.runModal()
                    return
                }
                alert.informativeText = "Choose a machine configured in herdr-core. Manage connections with hc machine."
                alert.addButton(withTitle: "Create Workspace"); alert.addButton(withTitle: "Cancel")
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28), pullsDown: false)
                picker.setAccessibilityLabel("Remote Machine")
                for machine in machines { picker.addItem(withTitle: machine.name + " — " + machine.status) }
                alert.accessoryView = picker
                guard alert.runModal() == .alertFirstButtonReturn, machines.indices.contains(picker.indexOfSelectedItem) else { return }
                self.createRemoteHerdrWorkspace(machines[picker.indexOfSelectedItem].reference)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could Not Load Herdr Machines"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @discardableResult
    func createRemoteHerdrWorkspace(_ remote: HerdrRemote) -> Bool {
        guard canCreateLocalWorkspace else { return false }
        createWorkspace(kind: .herdr, remote: remote)
        return true
    }

    private func createWorkspace(kind: WorkspaceKind, remote: HerdrRemote? = nil, viewer: HerdrTerminalBinding? = nil) {
        guard canCreateLocalWorkspace else { return }
        sidebarIsFocused = false
        updatePanePresentation(in: sidebar.tab)
        suspendLocalWorkspacePresentation()
        otherLocalWorkspaces.append(.init(id: localWorkspaceID, name: localWorkspaceName, kind: workspaceKind, remote: workspaceRemote, tabs: tabs, selectedTabID: selectedTabID))
        let names = Set(otherLocalWorkspaces.map(\.name))
        var number = 1
        let prefix = remote.map { "Herdr · " + $0.name } ?? (kind == .herdr ? "Herdr" : "Workspace")
        while names.contains("\(prefix) \(number)") { number += 1 }
        localWorkspaceID = UUID()
        localWorkspaceName = "\(prefix) \(number)"
        workspaceKind = kind
        workspaceRemote = remote
        createInitialTab(terminal: viewer.map { makeTerminalPaneController(binding: $0, viewerOnly: true) })
        finishLocalWorkspaceSwitch()
    }

    private var canCreateLocalWorkspace: Bool {
        !isClosingWindow && closingHerdrPaneIDs.isEmpty
            && otherLocalWorkspaces.count < 63 && allWorkspaceTabs.count < 64
    }

    private var canCloseWorkspace: Bool {
        !isClosingWindow
            && !tabs.isEmpty
    }

    func closeWorkspaceAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close Workspace?"
        alert.informativeText = "This closes \(localWorkspaceName) and ends its terminal processes. External agent viewers only detach."
        alert.addButton(withTitle: "Close Workspace"); alert.addButton(withTitle: "Cancel")
        return alert
    }

    @objc func closeWorkspace(_: Any?) {
        guard canCloseWorkspace else { return }
        let localID = localWorkspaceID
        guard closeWorkspaceAlert().runModal() == .alertFirstButtonReturn,
              localID == localWorkspaceID else { return }
        closeLocalWorkspace(localID)
    }

    func closeLocalWorkspace(_ id: UUID) {
        guard id == localWorkspaceID, canCloseWorkspace else { return }
        removeCurrentLocalWorkspace()
    }

    private func removeCurrentLocalWorkspace() {
        let currentID = localWorkspaceID
        if closeHerdrPanes(tabs.flatMap { Array($0.paneControllers.values) }, then: { [weak self] in
            guard let self, self.localWorkspaceID == currentID else { return }
            self.removeCurrentLocalWorkspace()
        }) { return }
        suspendLocalWorkspacePresentation()
        if let next = otherLocalWorkspaces.first {
            otherLocalWorkspaces.removeFirst()
            localWorkspaceID = next.id; localWorkspaceName = next.name; workspaceKind = next.kind; workspaceRemote = next.remote
            tabs = next.tabs; selectedTabID = next.selectedTabID
        } else {
            localWorkspaceID = UUID(); localWorkspaceName = "Default"; workspaceKind = .local; workspaceRemote = nil
            createInitialTab()
        }
        finishLocalWorkspaceSwitch()
    }

    func selectLocalWorkspace(_ id: UUID) {
        guard closingHerdrPaneIDs.isEmpty else { return }
        guard id == localWorkspaceID || otherLocalWorkspaces.contains(where: { $0.id == id }) else { return }
        sidebarIsFocused = false
        updatePanePresentation(in: sidebar.tab)
        guard id != localWorkspaceID,
              let index = otherLocalWorkspaces.firstIndex(where: { $0.id == id }) else { return }
        suspendLocalWorkspacePresentation()
        let next = otherLocalWorkspaces.remove(at: index)
        otherLocalWorkspaces.append(.init(id: localWorkspaceID, name: localWorkspaceName, kind: workspaceKind, remote: workspaceRemote, tabs: tabs, selectedTabID: selectedTabID))
        localWorkspaceID = next.id; localWorkspaceName = next.name; workspaceKind = next.kind; workspaceRemote = next.remote
        tabs = next.tabs; selectedTabID = next.selectedTabID
        finishLocalWorkspaceSwitch()
    }

    private func suspendLocalWorkspacePresentation() {
        if let tab = selectedTabState {
            (tab.focusedPaneController as? TerminalPaneController)?.exitScrollMode()
            suspendActiveFloatingPresentation(in: tab)
            restoreActiveAutoZoom(in: tab, animated: false)
        }
        for tab in tabs {
            for pane in tab.paneControllers.values { pane.updatePresentation(isFocused: false, isFloating: false) }
        }
    }

    private func finishLocalWorkspaceSwitch() {
        cancelPaneNameReveal()
        refreshWorkspacePicker()
        rebuildWorkspaceLayout()
        if hasAppeared, let tab = selectedTabState { startPaneControllersIfNeeded(in: tab) }
        scheduleWorkspaceSave()
    }

}

extension WorkspaceViewController {
    func prepareWorkspacePersistence(url: URL = WorkspaceStore.defaultURL) async {
        do {
            let store = try await Task.detached { try WorkspaceStore(url: url) }.value
            workspaceStore = store
            let loaded = try await store.load()
            initialSavedWorkspace = loaded.workspace
            workspacePersistenceError = loaded.warning
        } catch { workspacePersistenceError = error.localizedDescription }
    }

    func savedWorkspace() -> SavedWorkspace {
        var document = savedWorkspaceTabs(tabs, selected: selectedTabID)
        document.localWorkspaceID = localWorkspaceID
        document.localWorkspaceName = localWorkspaceName
        document.workspaceKind = workspaceKind == .herdr ? .herdr : nil
        document.herdrRemote = workspaceRemote
        document.otherLocalWorkspaces = otherLocalWorkspaces.isEmpty ? nil : otherLocalWorkspaces.map {
            .init(id: $0.id, name: $0.name, kind: $0.kind == .herdr ? .herdr : nil, herdrRemote: $0.remote, selectedTabID: $0.selectedTabID,
                  tabs: savedWorkspaceTabs($0.tabs, selected: $0.selectedTabID).tabs)
        }
        document.sidebar = .init(side: sidebar.side, preferredWidth: sidebar.preferredWidth,
            isVisible: sidebar.isVisible, tab: savedWorkspaceTabs([sidebar.tab], selected: nil).tabs[0])
        document.sidebarIsFocused = sidebarIsFocused
        return document
    }

    private func savedWorkspaceTabs(_ sourceTabs: [WorkspaceTabState], selected: UUID?) -> SavedWorkspace {
        let savedTabs = sourceTabs.map { tab -> SavedWorkspace.Tab in
            var layout = tab.layoutNode
            if let zoom = tab.activeAutoZoomState {
                for state in zoom.splitStates.reversed() { layout = layout?.replacingFractions(at: state.splitPath, with: state.originalFractions) }
            }
            let panes = tab.paneControllers.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { pane -> SavedWorkspace.Pane in
                if let placeholder = pane as? RestoredPanePlaceholderController { return placeholder.savedPane }
                if let terminal = pane as? TerminalPaneController {
                    return .init(id: pane.id, kind: terminal.herdrSession == nil ? .localTerminal : .herdrTerminal,
                        name: pane.name, title: terminal.lastKnownTitle, cwd: terminal.currentWorkingDirectory,
                        herdr: terminal.herdrSession?.binding, herdrRunPending: terminal.herdrSession?.createResultUnknown == true ? true : nil,
                        herdrViewer: terminal.herdrSession?.viewerOnly == true ? true : nil)
                }
                if let browser = pane as? BrowserPaneController {
                    return .init(id: pane.id, kind: .browser, name: pane.name, title: pane.displayTitle, browserURL: browser.restorationURL)
                }
                if pane is AgentsPaneController {
                    return .init(id: pane.id, kind: .agents, name: pane.name, title: pane.displayTitle)
                }
                precondition(pane is SidebarListPaneController, "Unsupported pane type")
                return .init(id: pane.id, kind: .workspaces, name: pane.name, title: pane.displayTitle)
            }
            return .init(id: tab.id, layout: layout, panes: panes, focusedPaneID: tab.focusedPaneID,
                customTitle: tab.customTitle,
                autoResize: tab.paneAutoResizeConfigurations, detachedPaneIDs: tab.detachedPaneIDs,
                activeDetachedPaneID: tab.activeDetachedPaneID,
                floating: tab.activeFloatingPaneState.map { .init(paneID: $0.paneID, size: $0.size) },
                floatingSizes: tab.floatingPaneSizes)
        }
        return .init(selectedTabID: selected, tabs: savedTabs)
    }

    private func scheduleWorkspaceSave() {
        guard workspaceStore?.canWrite == true, workspacePersistenceActivated, !suppressWorkspaceSaving else { return }
        workspaceSaveTask?.cancel()
        workspaceSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard let self, let store = self.workspaceStore else { return }
            let document = self.savedWorkspace()
            do { try await store.save(document) }
            catch { self.workspacePersistenceError = error.localizedDescription }
        }
    }

    func flushWorkspaceState() async throws {
        workspaceSaveTask?.cancel()
        await workspaceSaveTask?.value
        guard let store = workspaceStore, store.canWrite, workspacePersistenceActivated else { return }
        try await store.save(savedWorkspace())
    }

    var hasWorkspacePersistence: Bool { workspaceStore != nil && workspacePersistenceActivated }

    func confirmWorkspaceSaveForClose() async -> Bool {
        do { try await flushWorkspaceState(); return true }
        catch {
            workspacePersistenceError = error.localizedDescription
            let alert = NSAlert()
            alert.messageText = "Workspace Could Not Be Saved"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Close Without Saving")
            let response: NSApplication.ModalResponse
            if let window = view.window {
                response = await withCheckedContinuation { continuation in
                    alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                }
            } else { response = alert.runModal() }
            return response == .alertSecondButtonReturn
        }
    }

    func restoreWorkspace(_ document: SavedWorkspace) throws {
        try document.validate()
        suppressWorkspaceSaving = true
        defer { suppressWorkspaceSaving = false }
        func restoreTabs(_ savedTabs: [SavedWorkspace.Tab], remote: HerdrRemote? = nil, isSidebar: Bool = false) -> [WorkspaceTabState] {
            var restoredTabs: [WorkspaceTabState] = []
            for saved in savedTabs {
                var controllers: [PaneID: any PaneControlling] = [:]
                for pane in saved.panes {
                    let controller: any PaneControlling
                    switch pane.kind {
                    case .localTerminal:
                        let placeholder = RestoredPanePlaceholderController(pane: pane,
                            message: "Previous local session ended. Start a new shell explicitly.")
                        placeholder.onFocusRequest = { [weak self] in self?.handlePaneFocusRequest(withID: $0) }
                        placeholder.onActivate = { [weak self] in
                            guard let self else { return }
                            self.replaceRestoredPane(pane.id, with: self.makeTerminalPaneController(id: pane.id, workingDirectory: pane.cwd, kind: isSidebar ? .herdr : .local))
                        }
                        controller = placeholder
                    case .herdrTerminal:
                        controller = makeTerminalPaneController(id: pane.id, workingDirectory: pane.cwd, kind: .herdr, binding: pane.herdr, remote: remote, runPending: pane.herdrRunPending == true, viewerOnly: pane.herdrViewer == true)
                    case .browser:
                        let browser = makeBrowserPaneController(id: pane.id)
                        if let url = pane.browserURL, let scheme = URL(string: url)?.scheme?.lowercased(), ["http", "https"].contains(scheme) { browser.loadURLString(url) }
                        controller = browser
                    case .workspaces:
                        controller = makeWorkspacesPaneController(id: pane.id)
                    case .agents:
                        controller = makeAgentsPaneController(id: pane.id)
                    }
                    controller.name = pane.name
                    controllers[pane.id] = controller
                }
                let tab = WorkspaceTabState(id: saved.id, layoutNode: saved.layout, paneControllers: controllers,
                    paneAutoResizeConfigurations: saved.autoResize, focusedPaneID: saved.focusedPaneID, customTitle: saved.customTitle,
                    activeFloatingPaneState: saved.floating.map { .init(paneID: $0.paneID, size: $0.size) })
                tab.detachedPaneIDs = saved.detachedPaneIDs
                tab.activeDetachedPaneID = saved.activeDetachedPaneID
                tab.floatingPaneSizes = saved.floatingSizes
                restoredTabs.append(tab)
            }
            return restoredTabs
        }
        if let savedSidebar = document.sidebar {
            sidebar.side = savedSidebar.side
            sidebar.preferredWidth = savedSidebar.preferredWidth
            sidebar.isVisible = savedSidebar.isVisible
            sidebar.tab = restoreTabs([savedSidebar.tab], isSidebar: true)[0]
        } else {
            sidebar.isVisible = false
            sidebar.tab = WorkspaceTabState(layoutNode: nil, paneControllers: [:], paneAutoResizeConfigurations: [:], focusedPaneID: nil)
        }
        sidebarIsFocused = document.sidebarIsFocused == true && sidebar.isVisible && sidebar.tab.focusedPaneController != nil
        rebuildSidebar()
        localWorkspaceID = document.localWorkspaceID ?? UUID()
        localWorkspaceName = document.localWorkspaceName ?? "Default"
        workspaceKind = document.workspaceKind ?? .local
        workspaceRemote = document.herdrRemote
        otherLocalWorkspaces = (document.otherLocalWorkspaces ?? []).map {
            .init(id: $0.id, name: $0.name, kind: $0.kind ?? .local, remote: $0.herdrRemote, tabs: restoreTabs($0.tabs, remote: $0.herdrRemote), selectedTabID: $0.selectedTabID ?? $0.tabs.first?.id)
        }
        tabs = restoreTabs(document.tabs, remote: document.herdrRemote)
        selectedTabID = document.selectedTabID ?? tabs.first?.id
        workspacePersistenceActivated = !tabs.isEmpty
        if tabs.isEmpty { createInitialTab() }
        else { rebuildWorkspaceLayout() }
        refreshWorkspacePicker()
    }

    private func replaceRestoredPane(_ id: PaneID, with controller: any PaneControlling) {
        guard let tab = tabState(containing: id), tab.paneControllers[id] is RestoredPanePlaceholderController else { return }
        controller.name = tab.paneControllers[id]?.name
        tab.paneControllers[id] = controller
        if tab === sidebar.tab { rebuildPaneContainer(tab) }
        else if tab.id == selectedTabID { rebuildWorkspaceLayout() }
        else { updateTabStrip() }
        if hasAppeared, tab.id == selectedTabID || tab === sidebar.tab && sidebar.isVisible { controller.startIfNeeded() }
    }

    var debugRestoredPlaceholderCount: Int { tabs.flatMap { $0.paneControllers.values }.filter { $0 is RestoredPanePlaceholderController }.count }
}

extension WorkspaceViewController {

    func selectWorkspace(_ id: String) {
        guard let entry = workspaceEntries.first(where: { $0.id == id }) else { return }
        selectWorkspace(entry.reference)
    }

    func selectWorkspace(_ reference: UUID) {
        guard !isClosingWindow else { return }
        selectLocalWorkspace(reference)
    }

    var debugWorkspaceEntries: [WorkspaceEntry] { workspaceEntries }

    var debugSelectedWorkspace: UUID { localWorkspaceID }

}

extension WorkspaceViewController {
    var paletteNavigationItems: [AppCommand] {
        var items: [AppCommand] = herdrCoreClient.agents.snapshots.map { session in
            AppCommand(id: "navigate.Agents." + session.id, title: session.agent.displayName,
                shortcut: nil, isEnabled: !isClosingWindow, kind: .agent,
                subtitle: [session.paneTitle, session.location, session.statusText, session.message].compactMap { $0 }.joined(separator: " · "),
                symbol: "sparkles", brandIcon: session.agent.brandIcon,
                perform: { [weak self] in self?.navigateToAgent(session.binding) })
        }
        func item(_ id: String, _ title: String, _ kind: PaletteItemKind, _ subtitle: String,
                  _ symbol: String, brandIcon: BrandIcon? = nil, current: Bool, inWorkspace: Bool, workspaceID: UUID, tabID: UUID? = nil, paneID: PaneID? = nil) {
            items.append(AppCommand(id: "navigate." + kind.rawValue + "." + id, title: title, shortcut: nil, isEnabled: !isClosingWindow,
                kind: kind, subtitle: subtitle, symbol: symbol, brandIcon: brandIcon, isCurrent: current, isInCurrentWorkspace: inWorkspace,
                perform: { [weak self] in self?.navigateFromPalette(workspaceID: workspaceID, tabID: tabID, paneID: paneID) }))
        }
        for workspace in localWorkspaceStates {
            let isSelected = workspace.id == localWorkspaceID
            item(workspace.pickerID, workspace.name, .workspace, workspace.remote.map { "Herdr · " + $0.name } ?? workspace.kind.title, workspace.remote == nil ? workspace.kind.symbol : "network",
                 brandIcon: workspace.kind.brandIcon, current: isSelected, inWorkspace: isSelected, workspaceID: workspace.id)
            for (index, tab) in workspace.tabs.enumerated() {
                item(tab.id.uuidString, tab.displayTitle, .tab, "\(workspace.name) › Tab \(index + 1)", "rectangle.on.rectangle",
                     current: isSelected && tab.id == selectedTabID, inWorkspace: isSelected,
                     workspaceID: workspace.id, tabID: tab.id)
                for pane in paletteOrderedPanes(tab) {
                    item(pane.id.uuidString, pane.name ?? pane.displayTitle, .pane, palettePaneSubtitle(pane, tab: tab, workspace: workspace.name),
                         palettePaneSymbol(pane), current: isSelected && tab.id == selectedTabID && tab.focusedPaneID == pane.id,
                         inWorkspace: isSelected, workspaceID: workspace.id, tabID: tab.id, paneID: pane.id)
                }
            }
        }
        return items
    }

    private func paletteOrderedPanes(_ tab: WorkspaceTabState) -> [any PaneControlling] {
        let order = tab.tiledPaneIDsInTraversalOrder + tab.detachedPaneIDs
        return order.compactMap { tab.paneControllers[$0] }
            + tab.paneControllers.keys.filter { !order.contains($0) }.sorted { $0.uuidString < $1.uuidString }.compactMap { tab.paneControllers[$0] }
    }

    private func palettePaneSymbol(_ pane: any PaneControlling) -> String {
        pane is AgentsPaneController ? "sparkles" : pane is BrowserPaneController ? "globe" : pane is SidebarListPaneController ? "list.bullet" : "terminal"
    }

    private func palettePaneSubtitle(_ pane: any PaneControlling, tab: WorkspaceTabState, workspace: String) -> String {
        let kind = pane is AgentsPaneController ? "Agents" : pane is BrowserPaneController ? "Browser" : pane is SidebarListPaneController ? "Workspaces" : "Terminal"
        let presentation = tab.activeFloatingPaneState?.paneID == pane.id ? " · Floating" : tab.isPaneDetached(pane.id) ? " · Hidden" : ""
        return "\(workspace) › \(tab.displayTitle) · \(kind)\(presentation)"
    }

    private func navigateFromPalette(workspaceID: UUID, tabID: UUID?, paneID: PaneID?) {
        guard !isClosingWindow else { return }
        guard let local = localWorkspaceStates.first(where: { $0.id == workspaceID }) else {
            rootView.toolbarView.showNavigationStatus("The selected workspace no longer exists")
            return
        }
        if let tabID, !local.tabs.contains(where: { $0.id == tabID && (paneID == nil || $0.containsPane(withID: paneID!)) }) {
            rootView.toolbarView.showNavigationStatus("The selected tab or pane no longer exists")
            return
        }
        selectLocalWorkspace(workspaceID)
        if let tabID { selectTab(withID: tabID) }
        if let paneID { handlePaneFocusRequest(withID: paneID) }
        rootView.toolbarView.showNavigationStatus(nil)
    }

    // MARK: Window sidebar

    private func recordWindowFocus(_ paneID: PaneID) {
        windowFocusHistory.removeAll { id in id == paneID || !paneOwnerTabs.contains(where: { $0.containsPane(withID: id) }) }
        windowFocusHistory.insert(paneID, at: 0)
    }

    private func focusSidebarPane(_ paneID: PaneID) {
        guard sidebar.isVisible, sidebar.tab.containsPane(withID: paneID), view.window?.attachedSheet == nil else { return }
        if let floating = sidebar.tab.activeFloatingPaneState, floating.paneID != paneID {
            clearFloatingPaneImmediately(in: sidebar.tab, reapplyAutoZoom: false)
        }
        let changed = !sidebarIsFocused || sidebar.tab.focusedPaneID != paneID
        sidebarIsFocused = true
        sidebar.tab.focusedPaneID = paneID
        sidebar.tab.markPaneFocused(paneID)
        recordWindowFocus(paneID)
        if let selectedTabState { updatePanePresentation(in: selectedTabState) }
        updatePanePresentation(in: sidebar.tab)
        if changed { applyFocusedPaneResponder() }
        scheduleWorkspaceSave()
    }

    private func focusMainRegion() {
        sidebarIsFocused = false
        updatePanePresentation(in: sidebar.tab)
        if let selectedTabState { updatePanePresentation(in: selectedTabState) }
        applyFocusedPaneResponder()
    }

    @objc func toggleSidebar(_: Any?) {
        sidebar.isVisible.toggle()
        if sidebar.isVisible && sidebar.tab.layoutNode == nil { createDefaultSidebar() }
        if !sidebar.isVisible {
            clearFloatingPaneImmediately(in: sidebar.tab, reapplyAutoZoom: false)
            focusMainRegion()
        }
        rebuildSidebar()
    }

    @objc func moveSidebarLeft(_: Any?) { setSidebarSide(.left) }
    @objc func moveSidebarRight(_: Any?) { setSidebarSide(.right) }
    private func setSidebarSide(_ side: SidebarSide) {
        sidebar.side = side
        sidebar.isVisible = true
        if sidebar.tab.layoutNode == nil { createDefaultSidebar() }
        rebuildSidebar()
    }

    @objc func addSidebarBrowser(_: Any?) { addSidebarPane(makeBrowserPaneController()) }

    @objc func addSidebarWorkspaces(_: Any?) { addSidebarPane(makeWorkspacesPaneController()) }

    @objc func addSidebarAgents(_: Any?) { addSidebarPane(makeAgentsPaneController()) }

    private func makeWorkspacesPaneController(id: PaneID = UUID()) -> SidebarListPaneController {
        let pane = SidebarListPaneController(id: id)
        pane.onFocusRequest = { [weak self] in self?.handlePaneFocusRequest(withID: $0) }
        pane.onSelectWorkspace = { [weak self] reference in self?.navigateFromSidebar(to: reference) }
        pane.onCancel = { [weak self] in self?.focusMainRegion() }
        pane.update(entries: workspaceEntries, selected: localWorkspaceID)
        return pane
    }

    private func navigateFromSidebar(to reference: UUID) {
        guard !isClosingWindow else { return }
        selectWorkspace(reference)
        if localWorkspaceID == reference { focusMainRegion() }
    }

    private func createDefaultSidebar() {
        let terminal = makeTerminalPaneController(kind: .herdr)
        sidebar.tab.paneControllers = [terminal.id: terminal]
        sidebar.tab.layoutNode = .panel(terminal.id)
        sidebar.tab.focusedPaneID = terminal.id
    }

    private func addSidebarPane(_ pane: any PaneControlling) {
        sidebar.isVisible = true
        windowContentView.updateSidebar(sidebar)
        let tab = sidebar.tab
        leaveFloatingPane(in: tab, animated: false, reapplyAutoZoom: false)
        if let layout = tab.layoutNode, let anchor = tab.focusedPaneID ?? layout.firstPaneID {
            tab.layoutNode = layout.insertingSplit(for: anchor, axis: automaticSplitAxis(for: tab.paneControllers[anchor]), newPaneID: pane.id)
        } else { tab.layoutNode = .panel(pane.id) }
        tab.paneControllers[pane.id] = pane
        tab.focusedPaneID = pane.id
        rebuildSidebar()
        focusSidebarPane(pane.id)
    }

    private func rebuildPaneContainer(_ tab: WorkspaceTabState) {
        if tab === sidebar.tab { rebuildSidebar(); applyFocusedPaneResponder() }
        else { rebuildWorkspaceLayout(applyAutoZoomAnimated: true) }
    }

    private func renderSidebar() {
        let tiling = windowContentView.sidebarView
        guard sidebar.isVisible, tiling.bounds.width > 0, tiling.bounds.height > 0,
              let layout = sidebar.tab.layoutNode else { return }
        tiling.setLayoutNode(layout, paneViews: buildPaneViewsDictionary(for: sidebar.tab))
    }

    private func floatingRootView(for tab: WorkspaceTabState) -> WorkspaceRootView {
        tab === sidebar.tab ? windowContentView.sidebarFloatingView : rootView
    }

    private func rebuildSidebar(restoreFloatingPresentation: Bool = true, allowFocus: Bool = true) {
        windowContentView.updateSidebar(sidebar)
        renderSidebar()
        if restoreFloatingPresentation { restoreActiveFloatingPresentation(in: sidebar.tab) }
        updateWorkspaceLists()
        updatePanePresentation(in: sidebar.tab)
        updateWindowMinimumSize()
        scheduleWorkspaceSave()
        if hasAppeared, sidebar.isVisible { startPaneControllersIfNeeded(in: sidebar.tab, allowFocus: allowFocus) }
    }

    private func updateWorkspaceLists() {
        for case let pane as SidebarListPaneController in paneOwnerTabs.flatMap({ Array($0.paneControllers.values) }) {
            pane.update(entries: workspaceEntries, selected: localWorkspaceID)
        }
    }

    var debugSidebarPaneIDs: [PaneID] { sidebar.tab.layoutNode?.paneIDsInTraversalOrder ?? [] }
    var debugSidebarVisible: Bool { sidebar.isVisible }
    var debugSidebarFocused: Bool { sidebarIsFocused }
    var debugSidebarSide: SidebarSide { sidebar.side }
    var debugSidebarFocusedPaneID: PaneID? { sidebar.tab.focusedPaneID }
    func debugFocusSidebarPane(_ id: PaneID) { focusSidebarPane(id) }
    func debugSidebarPane(_ id: PaneID) -> (any PaneControlling)? { sidebar.tab.paneControllers[id] }

}

// Explicit-target operations shared by GUI actions and the authorized CLI router.
// Kept in this file so the controller's presentation and ownership stay private.
extension WorkspaceViewController {
    private func cliTabSnapshots() -> [CLITab] {
        func snapshot(_ tab: WorkspaceTabState, owner: LocalWorkspaceState?) -> CLITab {
            CLITab(id: tab.id, title: tab.displayTitle,
                isSelected: owner?.id == localWorkspaceID && tab.id == selectedTabID,
                panes: tab.paneControllers.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { pane in
                    let terminal = pane as? TerminalPaneController
                    return CLIPane(id: pane.id, title: pane.displayTitle, name: pane.name,
                        kind: terminal != nil ? "terminal" : pane is AgentsPaneController ? "agents" : pane is SidebarListPaneController ? "workspaces" : pane is RestoredPanePlaceholderController ? "unavailable" : "browser",
                        cwd: terminal?.workingDirectoryForNewPane,
                        foregroundProcessGroupID: terminal?.herdrSession?.remote == nil ? terminal?.foregroundProcessID : nil,
                        isFocused: tab.focusedPaneID == pane.id, isLive: pane.isLive,
                        isDetached: tab.isPaneDetached(pane.id))
                }, workspaceID: owner?.id, workspaceName: owner?.name,
                region: owner == nil ? "sidebar" : "main")
        }
        // Current workspace stays first for old consumers of list.
        let current = LocalWorkspaceState(id: localWorkspaceID, name: localWorkspaceName, kind: workspaceKind,
                                         remote: workspaceRemote, tabs: tabs, selectedTabID: selectedTabID)
        return ([current] + otherLocalWorkspaces).flatMap { owner in owner.tabs.map { snapshot($0, owner: owner) } }
            + [snapshot(sidebar.tab, owner: nil)]
    }

    private func cliOwner(of tab: WorkspaceTabState) -> LocalWorkspaceState? {
        localWorkspaceStates.first { owner in owner.tabs.contains { $0 === tab } }
    }

    private func cliMakePane(type: String?, owner: LocalWorkspaceState?, cwd: String? = nil) -> any PaneControlling {
        switch type ?? "terminal" {
        case "browser": return makeBrowserPaneController()
        case "agents": return makeAgentsPaneController()
        case "workspaces": return makeWorkspacesPaneController()
        default: return makeTerminalPaneController(workingDirectory: cwd, kind: owner?.kind ?? .herdr, remote: owner?.remote)
        }
    }

    @discardableResult
    private func insertPane(_ pane: any PaneControlling, relativeTo anchor: PaneID, in tab: WorkspaceTabState,
                            layout: LayoutNode, axis: SplitAxis, before: Bool, focus: Bool) -> Bool {
        guard var updated = layout.insertingSplit(for: anchor, axis: axis, newPaneID: pane.id) else { return false }
        if before, let swapped = updated.swappingPane(anchor, with: pane.id) { updated = swapped }
        tab.paneControllers[pane.id] = pane
        if tab !== sidebar.tab {
            tab.paneAutoResizeConfigurations[pane.id] = WorkspaceFocusZoomConfiguration.defaultAutoResizeConfiguration
        }
        tab.layoutNode = updated
        if focus {
            tab.focusedPaneID = pane.id
            tab.markPaneFocused(pane.id)
            recordWindowFocus(pane.id)
            rebuildPaneContainer(tab)
            if hasAppeared { pane.startIfNeeded(); applyFocusedPaneResponder() }
        } else { cliRefresh(tab) }
        scheduleWorkspaceSave()
        return true
    }

    /// Updates only the target container; never changes first responder, selected
    /// workspace/tab, or a different container's transient layout.
    private func cliRefresh(_ tab: WorkspaceTabState) {
        if tab === sidebar.tab {
            rebuildSidebar(allowFocus: false)
        } else if tab.id == selectedTabID, let layout = tab.layoutNode {
            tilingView?.setLayoutNode(layout, paneViews: buildPaneViewsDictionary(for: tab))
            updatePanePresentation(in: tab)
            updateWindowMinimumSize()
            if hasAppeared { startPaneControllersIfNeeded(in: tab, allowFocus: false) }
        }
        updateTabStrip()
        updateWindowTitle()
        scheduleWorkspaceSave()
    }

    private func cliLayout(in tab: WorkspaceTabState, paneID: PaneID) throws -> LayoutNode {
        let rendered = tab === sidebar.tab ? windowContentView.sidebarView : tab.id == selectedTabID ? tilingView : nil
        guard tab.isPaneTiled(paneID), tab.activeFloatingPaneState == nil, tab.activeDetachedPaneID == nil,
              tab.manualResizeLayout == nil, rendered?.collapsedPaneIDs.isEmpty != false,
              let layout = tab.layoutNode else {
            throw CLIError("Layout operations require tiled panes without floating, detached overlays or folded layouts. Restore the layout first.", code: "unsupported_layout")
        }
        return layout
    }

    func performCLIPaneRequest(_ request: CLIRequest) async throws -> CLIResponse {
        guard !isClosingWindow, !cliWindowClosePending, closingHerdrPaneIDs.isEmpty,
              view.window?.attachedSheet == nil, NSApp.modalWindow == nil else {
            throw CLIError("Finish the current close operation first.", code: "busy")
        }
        if request.command == "pane.new" || request.command == "pane.split" {
            guard paneOwnerTabs.reduce(0, { $0 + $1.paneControllers.count }) < 512 else {
                throw CLIError("Workspace pane limit reached.", code: "limit_reached")
            }
        }
        if request.command == "pane.new" {
            guard let owner = localWorkspaceStates.first(where: { $0.id == request.workspaceID }) else {
                throw CLIError("Workspace not found. Run santty list --json.", code: "workspace_not_found")
            }
            guard allWorkspaceTabs.count < 64 else { throw CLIError("Tab limit reached.", code: "limit_reached") }
            let pane = cliMakePane(type: request.paneType, owner: owner)
            let tab = WorkspaceTabState(layoutNode: .panel(pane.id), paneControllers: [pane.id: pane],
                paneAutoResizeConfigurations: [pane.id: WorkspaceFocusZoomConfiguration.defaultAutoResizeConfiguration], focusedPaneID: pane.id)
            if owner.id == localWorkspaceID { tabs.append(tab) }
            else if let index = otherLocalWorkspaces.firstIndex(where: { $0.id == owner.id }) {
                otherLocalWorkspaces[index].tabs.append(tab)
            }
            if request.focus == true { cliFocus(pane.id, tab: tab, owner: owner, activate: false) }
            else { cliRefresh(tab) }
            return CLIResponse(paneID: pane.id, tabID: tab.id, workspaceID: owner.id, status: "created")
        }
        guard let id = request.paneID, let tab = paneOwnerTabs.first(where: { $0.containsPane(withID: id) }),
              let pane = tab.paneControllers[id] else {
            throw CLIError("Pane not found. Run santty list --json to refresh pane IDs.", code: "pane_not_found")
        }
        let owner = cliOwner(of: tab)
        var response = CLIResponse(paneID: id, tabID: tab.id, workspaceID: owner?.id, status: "ok")
        switch request.command {
        case "pane.rename": updatePaneName(request.name ?? "", for: pane)
        case "pane.focus":
            cliFocus(id, tab: tab, owner: owner, activate: request.activate == true)
        case "pane.close":
            guard !pane.isLive || request.force == true else {
                throw CLIError("Pane is live. Use --force to close its session (external viewers only detach).", code: "confirmation_required")
            }
            let window = view.window
            let responder = window?.firstResponder
            let preserveResponder = focusedPaneController?.id != id
            closingHerdrPaneIDs.insert(id)
            defer { closingHerdrPaneIDs.remove(id) }
            if let terminal = pane as? TerminalPaneController { try await terminal.herdrSession?.closeTerminal() }
            // GUI actions may have run during the await. Never remove a replacement.
            guard tab.paneControllers[id] === pane else { throw CLIError("Pane changed while closing.", code: "pane_changed") }
            cliPreservingResponder = preserveResponder
            performClosePane(withID: id, in: tab, forCLI: true)
            cliPreservingResponder = false
            if cliWindowClosePending { cliWindowCloseRequestID = request.requestID }
            if preserveResponder, let responder, let responderView = responder as? NSView, responderView.window === window {
                window?.makeFirstResponder(responder)
            }
            scheduleWorkspaceSave()
            do { try await flushWorkspaceState() }
            catch {
                cliWindowClosePending = false
                throw CLIError("Pane closed, but saving workspace state failed: \(error.localizedDescription)", code: "persistence_failed")
            }
            response.status = "closed"
        case "pane.split":
            let layout = try cliLayout(in: tab, paneID: id)
            guard (layout.path(to: id)?.count ?? 64) < 62 else { throw CLIError("Layout depth limit reached.", code: "limit_reached") }
            let newPane = cliMakePane(type: request.paneType, owner: owner, cwd: (pane as? TerminalPaneController)?.workingDirectoryForNewPane)
            let horizontal = request.direction == "left" || request.direction == "right"
            tab.activeAutoZoomState = nil
            guard insertPane(newPane, relativeTo: id, in: tab, layout: layout,
                             axis: horizontal ? .horizontal : .vertical,
                             before: request.direction == "left" || request.direction == "up", focus: false) else {
                throw CLIError("Could not split pane.", code: "unsupported_layout")
            }
            if request.focus == true { cliFocus(newPane.id, tab: tab, owner: owner, activate: false) }
            response.paneID = newPane.id; response.status = "created"
        case "pane.move", "pane.resize", "pane.equalize":
            let layout = try cliLayout(in: tab, paneID: id)
            view.layoutSubtreeIfNeeded()
            let size = tab === sidebar.tab ? windowContentView.sidebarView.bounds.size : rootView.contentContainerView.bounds.size
            let updated = try CLIPaneLayout.apply(request, to: layout, size: size)
            tab.activeAutoZoomState = nil
            tab.layoutNode = updated
            cliRefresh(tab)
        case "pane.send-text", "pane.send-key":
            guard let terminal = pane as? TerminalPaneController else { throw CLIError("Only terminal panes accept input.", code: "not_terminal") }
            try terminal.sendForCLI(request)
            response.status = "accepted"
        default: throw CLIError("Unsupported pane command.", code: "unsupported_command")
        }
        return response
    }

    private func cliFocus(_ id: PaneID, tab: WorkspaceTabState, owner: LocalWorkspaceState?, activate: Bool) {
        if let owner {
            if owner.id != localWorkspaceID { selectLocalWorkspace(owner.id) }
            if tab.id != selectedTabID { selectTab(withID: tab.id) }
        }
        if tab === sidebar.tab, !sidebar.isVisible {
            sidebar.isVisible = true
            rebuildSidebar()
        }
        handlePaneFocusRequest(withID: id)
        // An already-focused pane in an inactive app still needs its responder.
        applyFocusedPaneResponder()
        if activate { view.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        scheduleWorkspaceSave()
    }

    private func cliRemoveEmptyTab(_ tab: WorkspaceTabState) {
        if let index = otherLocalWorkspaces.firstIndex(where: { $0.tabs.contains { $0 === tab } }) {
            otherLocalWorkspaces[index].tabs.removeAll { $0 === tab }
            if otherLocalWorkspaces[index].tabs.isEmpty { otherLocalWorkspaces.remove(at: index) }
            else if otherLocalWorkspaces[index].selectedTabID == tab.id {
                otherLocalWorkspaces[index].selectedTabID = otherLocalWorkspaces[index].tabs.first?.id
            }
            refreshWorkspacePicker()
        } else {
            tabs.removeAll { $0 === tab }
            if tabs.isEmpty, let next = otherLocalWorkspaces.first {
                otherLocalWorkspaces.removeFirst()
                localWorkspaceID = next.id; localWorkspaceName = next.name; workspaceKind = next.kind; workspaceRemote = next.remote
                tabs = next.tabs; selectedTabID = next.selectedTabID
                finishLocalWorkspaceSwitch()
            } else if tabs.isEmpty {
                selectedTabID = nil
                cliWindowClosePending = true
            } else if selectedTabID == tab.id {
                selectedTabID = tabs.first?.id
                rebuildWorkspaceLayout()
            }
        }
        scheduleWorkspaceSave()
    }

    /// Called only after the socket reply has been written, so closing the last
    /// pane cannot terminate the app before the caller receives its result.
    func finishCLIReply(requestID: String?) {
        guard cliWindowClosePending, cliWindowCloseRequestID == requestID else { return }
        cliWindowClosePending = false
        cliWindowCloseRequestID = nil
        requestWindowClose(workspaceSaveConfirmed: true)
    }
}
