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
final class WorkspaceViewController: NSViewController, NSMenuItemValidation, NSMenuDelegate, NSWindowDelegate {
    private var rootView: WorkspaceRootView {
        view as! WorkspaceRootView
    }

    private var workspaceStore: WorkspaceStore?
    private var initialSavedWorkspace: SavedWorkspace?
    private var workspacePersistenceActivated = false
    private var suppressWorkspaceSaving = false
    private var workspaceSaveTask: Task<Void, Never>?
    private(set) var workspacePersistenceError: String?
    private var herdrClient: HerdrWorkspaceClient?
    private var herdrManagementState: HerdrConnectionState = .disconnected
    private var herdrManagement: HerdrConnection?
    private let herdrCatalog = HerdrWorkspaceCatalog()
    private var workspaceEntries: [WorkspaceEntry] = []
    private var workspaceSelectionTask: Task<Void, Never>?
    private var workspaceSelectionGeneration = 0
    private var restoredWorkspaceSelection: WorkspaceReference?
    private var herdrManagementGeneration = 0
    private var herdrOperationPending = false
    private var herdrWorkspaceClosed = false
    private var herdrWindowWorkspaceID: String?
    private let herdrWindowMode: HerdrTerminalMode = .control
    private let herdrWindowTransport: HerdrPaneTransport = .clientShell
    private var herdrShellSession: HerdrClientShellSession?
    private var borrowedHerdrCallbacks: (state: ((HerdrConnectionState) -> Void)?, failure: ((any Error, Bool) -> Void)?)?
    private var herdrShellPopup: HerdrClientShellPopupController?
    private var herdrShellGeneration = 0
    private var herdrShellProjectionTask: Task<Void, Never>?
    private var herdrShellResizeTask: Task<Void, Never>?
    private var herdrShellHostColorTask: Task<Void, Never>?
    private var herdrShellHostColorRequest = 0
    private var herdrShellHostColorSource: (PaneID, Int)?
    private var herdrShellReconnectTask: Task<Void, Never>?
    private var herdrShellRecoveryTask: Task<Void, Never>?
    private var herdrShellRecoveryAttempts = 0
    private var herdrShellConnectedAt: TimeInterval?
    private var lastHerdrBellAt: TimeInterval = 0
    private var herdrShellPendingProjection: (HerdrShellSnapshot, HerdrShellSurface, [HerdrShellAssetKey: Data])?
    private var herdrShellPresentedSnapshot: HerdrShellSnapshot?
    private var herdrFloatingRecords: [HerdrFloatingPaneRecord] = []
    private var herdrShellViewportCalibration: (tab: UUID, layout: LayoutNode, available: CGSize, cell: CGSize,
        padding: CGFloat, divider: CGFloat, size: HerdrShellSize)?
    private var herdrFloatingDisplays: [PaneID: HerdrFloatingPaneDisplay] = [:]
    private var herdrFloatingTransition = false
    private var herdrFloatingTask: Task<Void, Never>?
    private var herdrFloatingShutdownTask: Task<Void, Never>?
    private var herdrShellLayouts: [String: HerdrLayout.Node] = [:]
    private var herdrDiscoveredWorkspaces: [HerdrSnapshot.Workspace] = []
    private var herdrDiscoveryTask: Task<Void, Never>?
    private var herdrSettingsObserver: NSObjectProtocol?
    private var paletteNavigationTask: Task<Void, Never>?
    private var paletteNavigationGeneration = 0
    private var paletteNavigationInProgress = false
    private var herdrLatestQuerySnapshot: HerdrSnapshot?
    private struct LocalWorkspaceState {
        let id: UUID
        let name: String
        var tabs: [WorkspaceTabState]
        var selectedTabID: UUID?
        var pickerID: String { "local." + id.uuidString }
    }
    private var localWorkspaceID = UUID()
    private var localWorkspaceName = "Default"
    // The selected local workspace remains in tabs (or parkedLocalTabs while showing Herdr).
    private var otherLocalWorkspaces: [LocalWorkspaceState] = []
    private var localWorkspaceStates: [LocalWorkspaceState] {
        let current = LocalWorkspaceState(id: localWorkspaceID, name: localWorkspaceName,
            tabs: parkedLocalTabs ?? tabs, selectedTabID: parkedLocalTabs == nil ? selectedTabID : parkedSelectedTabID)
        return ([current] + otherLocalWorkspaces).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var allWorkspaceTabs: [WorkspaceTabState] {
        tabs + herdrAuxiliaryTabs + (parkedLocalTabs ?? []) + otherLocalWorkspaces.flatMap(\.tabs)
    }
    private var parkedLocalTabs: [WorkspaceTabState]?
    private var herdrAuxiliaryTabs: [WorkspaceTabState] = []
    private var parkedSelectedTabID: UUID?
    private var herdrLayoutRevision = 0
    private var applyingHerdrLayout = false
    private var herdrShellStagingTab: WorkspaceTabState?
    private var herdrShellRetainedPresentation: [any PaneControlling] = []
    private var herdrShellNativeLayoutPending = false
    private var pendingHerdrFocus: HerdrPaneBinding?
    private var optimisticHerdrFocus: HerdrPaneBinding?
    private var pendingHerdrSplits: [(binding: HerdrPaneBinding, path: [LayoutPathComponent], edit: WorkspaceTabState.SplitEdit)] = []
    private var herdrWindowRestoreFailed = false
    private var herdrWindowIdentity: HerdrServiceIdentity?
    private(set) var herdrLastError: String?
    var herdrErrorHandler: ((String) -> Void)?
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
                            isDetached: tab.isPaneDetached(pane.id), backend: terminal.map { $0.herdrBinding == nil ? "local" : "herdr" },
                            herdrPaneID: terminal?.herdrBinding?.paneID, herdrTerminalID: terminal?.herdrQueryBinding?.terminalID,
                            herdrSocketPath: terminal?.herdrBinding?.endpoint.socketPath)
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

    func handleCLIRequestAsync(_ request: CLIRequest) async throws -> CLIResponse {
        try request.validate()
        if request.command != "list" {
            guard let id = request.paneID,
                  let terminal = tabs.lazy.compactMap({ $0.paneControllers[id] as? TerminalPaneController }).first else {
                return try handleCLIRequest(request)
            }
            guard terminal.herdrBinding != nil else { return try handleCLIRequest(request) }
            let binding = try await terminal.resolveHerdrQueryBinding()
            guard tabs.contains(where: { $0.paneControllers[terminal.id] === terminal }) else {
                throw CLIError("Herdr query target changed while resolving identity")
            }
            let read = try await HerdrWorkspaceClient(endpoint: binding.endpoint, identity: binding.serviceIdentity).read(binding)
            guard terminal.isLive, terminal.herdrQueryBinding == binding,
                  tabs.contains(where: { $0.paneControllers[terminal.id] === terminal }) else {
                throw CLIError("Herdr query target changed while reading history")
            }
            var response = try CLITextSnapshot.response(read.text, request: request)
            response.textSource = "herdr_recent_1000"
            response.historyTruncated = read.truncated
            response.backendRevision = read.revision
            response.truncated = response.truncated == true || read.truncated
            return response
        }
        if request.includeProcesses == false { return try handleCLIRequest(request) }
        let deadline = Date().addingTimeInterval(2)
        var errors: [PaneID: String] = [:]
        for case let terminal as TerminalPaneController in tabs.flatMap({ Array($0.paneControllers.values) }) {
            if terminal.herdrBinding != nil {
                if Date() >= deadline { errors[terminal.id] = "Process refresh exceeded the request budget"; continue }
                do { try await terminal.refreshHerdrProcessInfo() }
                catch { errors[terminal.id] = error.localizedDescription }
            }
        }
        var response = try handleCLIRequest(request)
        if var listed = response.tabs {
            for t in listed.indices {
                for p in listed[t].panes.indices where listed[t].panes[p].backend == "herdr" {
                    let id = listed[t].panes[p].id
                    listed[t].panes[p].backendError = errors[id]
                    if errors[id] != nil {
                        listed[t].panes[p].foregroundProcessGroupID = nil
                        listed[t].panes[p].processes = []
                        continue
                    }
                    listed[t].panes[p].processes = (tabs.lazy.compactMap({ $0.paneControllers[id] as? TerminalPaneController }).first?.herdrProcessInfo?.foreground_processes ?? []).map {
                        CLIProcess(pid: $0.pid, command: $0.cmdline ?? $0.name)
                    }
                }
            }
            response.tabs = listed
        }
        return response
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

    private var canSplitFocusedPane: Bool {
        focusedPaneIsTiled && focusedPaneController != nil
            && focusedTerminalPaneController.map({ $0.isLive }) != false
            && selectedTabState?.focusedPaneID.flatMap({ floatingRecord(for: $0) }) == nil
            && herdrFloatingTask == nil
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
        rootView.toolbarView.onSelectWorkspace = { [weak self] in self?.selectWorkspace($0) }
        rootView.onEffectiveAppearanceChange = { [weak self] in self?.syncHerdrShellAppearance() }
        rootView.toolbarView.agentStatusButton.target = self
        rootView.toolbarView.agentStatusButton.action = #selector(showAgentManager(_:))
        if let initialSavedWorkspace {
            do { try restoreWorkspace(initialSavedWorkspace) }
            catch { workspacePersistenceError = error.localizedDescription; createInitialTab() }
        } else { createInitialTab() }
        refreshWorkspacePicker()
        herdrSettingsObserver = NotificationCenter.default.addObserver(
            forName: HerdrSettings.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.discoverHerdrWorkspaces() }
        }
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
            herdrDiscoveryTask?.cancel(); workspaceSelectionTask?.cancel()
            if let herdrSettingsObserver { NotificationCenter.default.removeObserver(herdrSettingsObserver) }
            workspaceSaveTask?.cancel()
            herdrShellReconnectTask?.cancel()
            herdrShellRecoveryTask?.cancel()
            herdrShellHostColorTask?.cancel()
            herdrShellSession?.disconnect()
            herdrCatalog.stop()
            herdrManagement?.disconnect()
            for tab in allWorkspaceTabs {
                for case let pane as TerminalPaneController in tab.paneControllers.values { pane.disconnectHerdr() }
            }
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
            if herdrClient == nil { discoverHerdrWorkspaces() }
            if let selectedTabState {
                startPaneControllersIfNeeded(in: selectedTabState)
            }
        }

        applyFocusedPaneResponder()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleHerdrShellResize()
        resizeHerdrFloatingPane()
    }

    func windowDidResize(_ notification: Notification) { scheduleHerdrShellResize() }
    func windowDidChangeBackingProperties(_ notification: Notification) { scheduleHerdrShellResize() }
    func windowDidBecomeKey(_ notification: Notification) { setHerdrShellHostFocus(true) }
    func windowDidResignKey(_ notification: Notification) { setHerdrShellHostFocus(false) }

    private func setHerdrShellHostFocus(_ focused: Bool) {
        do { try herdrShellSession?.setFocused(focused) }
        catch { herdrLastError = error.localizedDescription }
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let reconnectItem = menu.items.first(where: { $0.action == #selector(reconnectPersistentTerminal(_:)) }) else { return }
        let disconnected = switch herdrShellSession?.state {
        case nil, .disconnected?, .failed(_)?: true
        default: false
        }
        reconnectItem.isHidden = herdrWindowWorkspaceID == nil || herdrWorkspaceClosed || !disconnected
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let keyWindow = NSApp.keyWindow, keyWindow is NSPanel, !keyWindow.canBecomeMain {
            return false
        }
        if herdrWindowWorkspaceID != nil {
            if menuItem.action == #selector(convertFocusedPaneToBrowser(_:)), focusedHerdrBinding != nil { return false }
        }
        if menuItem.action == #selector(closeTab(_:)) {
            menuItem.title = herdrWindowWorkspaceID != nil ? "Close Herdr Tab" : selectedTabState?.herdrTabBinding == nil ? "Close Tab" : "Remove Tab Views"
        }
        if menuItem.action == #selector(closePane(_:)) {
            menuItem.title = focusedHerdrBinding == nil ? "Close Pane" : herdrWindowWorkspaceID != nil ? "End Herdr Pane" : "Remove Persistent Terminal View"
        }
        if menuItem.action == #selector(enterScrollMode(_:)) {
            menuItem.title = focusedHerdrBinding == nil ? "Enter Scroll Mode" : "Open Recent History Snapshot"
        }
        return switch menuItem.action {
        case #selector(splitPaneHorizontally(_:)), #selector(splitPaneVertically(_:)):
            canSplitFocusedPane
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
        case #selector(disconnectPersistentTerminal(_:)):
            (herdrWindowWorkspaceID != nil && herdrWindowWorkspaceID != nil || focusedHerdrBinding != nil)
                && (!herdrOperationPending || herdrShellRecoveryTask != nil)
        case #selector(reconnectPersistentTerminal(_:)), #selector(takeOverPersistentTerminal(_:)):
            (herdrWindowWorkspaceID != nil || focusedHerdrBinding != nil) && !herdrOperationPending
        case #selector(newWorkspace(_:)):
            canCreateLocalWorkspace
        case #selector(closeWorkspace(_:)), #selector(renameWorkspace(_:)):
            canCloseWorkspace
        case #selector(endPersistentTerminal(_:)):
            focusedHerdrBinding != nil && !herdrOperationPending
        case #selector(showPersistentDiagnostics(_:)), #selector(newHerdrWorkspace(_:)), #selector(addRemoteHerdrMachine(_:)):
            !herdrOperationPending
        case #selector(authenticateRemoteHerdrMachine(_:)):
            !herdrOperationPending && herdrCatalog.states.values.contains { $0.endpoint.machine != nil }
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
            focusedTerminalPaneController?.canAcceptInput == true
        case #selector(enterScrollMode(_:)):
            focusedTerminalPaneController?.isLive == true
                && focusedTerminalPaneController?.isScrollModeActive == false
        case #selector(focusNextPane(_:)), #selector(focusPreviousPane(_:)),
            #selector(focusLeftPane(_:)), #selector(focusRightPane(_:)),
            #selector(focusAbovePane(_:)), #selector(focusBelowPane(_:)):
            focusedPaneIsTiled && (selectedTabState?.tiledPaneIDsInTraversalOrder.count ?? 0) > 1
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
        guard hasNotesPanes || workspacePersistenceActivated else { return true }
        guard !isClosingNotes else { return false }
        isClosingNotes = true
        Task { [weak self] in
            guard let self else { return }
            defer { isClosingNotes = false }
            if await prepareNotesToClose(), await confirmWorkspaceSaveForClose() { requestWindowClose(workspaceSaveConfirmed: true) }
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
        guard focusedHerdrBinding == nil else { NSSound.beep(); return }
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
        if herdrWindowWorkspaceID != nil, focusedHerdrBinding != nil { endPersistentTerminal(nil); return }
        guard let paneController = focusedPaneController else {
            return
        }

        if paneController.isLive && (paneController as? TerminalPaneController)?.herdrBinding == nil {
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

        if let id = tabState.activeFloatingPaneState?.paneID, herdrFloatingDisplays[id] != nil {
            toggleHerdrFloatingPane(in: tabState)
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
        let sessions = AgentSessionStore.shared.snapshots
        guard !sessions.isEmpty else {
            return
        }

        let popoverController = AgentManagerPopoverController(
            sessions: sessions,
            previousFirstResponder: view.window?.firstResponder,
            onFocusPane: { [weak self] paneID in
                self?.focusHerdrAgent(paneID)
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
        guard let tabState = selectedTabState,
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
        guard let tabState = selectedTabState,
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
        if let binding = focusedHerdrBinding ?? selectedTabState?.herdrTabBinding {
            createHerdrPane(workspaceID: binding.workspaceID)
            return
        }
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
        guard response == .alertFirstButtonReturn, selectedTabID == tabState.id,
              selectedTabState?.herdrTabBinding == tabState.herdrTabBinding else {
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
        if let binding = (pane as? TerminalPaneController)?.herdrBinding {
            runHerdrOperation { client in
                try await client.verify(binding)
                _ = try await client.request("pane.rename", params: .init(pane_id: binding.paneID, label: name.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return
        }
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
        workingDirectory: String? = nil,
        herdr: HerdrPaneBinding? = nil,
        launchCommand: String? = nil
    ) -> TerminalPaneController {
        let paneController = TerminalPaneController(id: id, workingDirectory: workingDirectory, herdr: herdr, launchCommand: launchCommand)
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

    private func makeNotesPaneController(id: PaneID = UUID(), preferredFileName: String? = nil, fileURL: URL? = nil) -> NotesPaneController {
        let pane = NotesPaneController(id: id, store: fileURL.map { NotesStore(fileURL: $0) } ?? NotesStore(), preferredFileName: preferredFileName)
        pane.onFocusRequest = { [weak self] in self?.handlePaneFocusRequest(withID: $0) }
        pane.onTitleChange = { [weak self] in self?.handleTitleChange(for: $0) }
        return pane
    }

    private var notesPanes: [NotesPaneController] {
        allWorkspaceTabs.flatMap { $0.paneControllers.values.compactMap { $0 as? NotesPaneController } }
    }

    var hasNotesPanes: Bool { !notesPanes.isEmpty }

    func prepareNotesToClose(_ panes: [NotesPaneController]? = nil) async -> Bool {
        for pane in panes ?? notesPanes {
            guard await pane.content.prepareToClose() else {
                if parkedLocalTabs?.contains(where: { $0.containsPane(withID: pane.id) }) == true { selectLocalWorkspace() }
                if let local = otherLocalWorkspaces.first(where: { $0.tabs.contains(where: { $0.containsPane(withID: pane.id) }) }) {
                    selectLocalWorkspace(local.id)
                }
                if let owner = herdrAuxiliaryTabs.first(where: { $0.containsPane(withID: pane.id) })?.herdrTabBinding {
                    do {
                        if herdrClient?.endpoint != owner.endpoint {
                            selectLocalWorkspace()
                            try configureHerdrWorkspace(owner.endpoint)
                        }
                        try await enterHerdrWorkspace(owner.workspaceID)
                    } catch { presentHerdrError(error) }
                }
                focusPaneLocatingTab(withID: pane.id)
                NSSound.beep()
                return false
            }
        }
        return true
    }

    private func applyTerminalSettingsToPanes() {
        retireHerdrShellHostColorQuery()
        if let session = herdrShellSession {
            do { try session.invalidatePresentation() }
            catch { herdrLastError = error.localizedDescription; stopHerdrClientShell() }
        }
        for tabState in allWorkspaceTabs {
            for case let paneController as TerminalPaneController in tabState.paneControllers.values
            {
                paneController.applyTerminalSettings()
            }
        }
        herdrShellPopup?.applySettings()
        if herdrWindowWorkspaceID != nil {
            view.layoutSubtreeIfNeeded()
            scheduleHerdrShellResize()
            requestHerdrLayoutRefresh()
        }
    }

    private func splitFocusedPane(along axis: SplitAxis) {
        guard canSplitFocusedPane else {
            NSSound.beep()
            return
        }

        let fallbackBinding = herdrWindowWorkspaceID == nil ? selectedTabState?.paneControllers.values.compactMap({ pane -> HerdrPaneBinding? in
            guard let terminal = pane as? TerminalPaneController, terminal.isLive else { return nil }
            return terminal.herdrBinding
        }).first ?? selectedTabState?.herdrTabBinding : nil
        if let binding = focusedHerdrBinding ?? fallbackBinding {
            createHerdrPane(split: binding, axis: axis, anchor: selectedTabState?.focusedPaneID)
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
        if tabState.herdrBackendLayout != nil {
            let local = tabState.herdrLocalLayout
            tabState.herdrLocalLayout = local.flatMap { node in
                node.insertingSplit(for: node.path(to: focusedPaneID) != nil ? focusedPaneID : node.firstPaneID!, axis: axis, newPaneID: newPaneController.id)
            } ?? .panel(newPaneController.id)
            tabState.paneControllers[newPaneController.id] = newPaneController
            tabState.paneAutoResizeConfigurations[newPaneController.id] = WorkspaceFocusZoomConfiguration.defaultAutoResizeConfiguration
            tabState.composeHerdrLayout()
            tabState.focusedPaneID = newPaneController.id
            tabState.markPaneFocused(newPaneController.id)
            rebuildWorkspaceLayout(applyAutoZoomAnimated: true)
            if hasAppeared { newPaneController.startIfNeeded(); applyFocusedPaneResponder() }
            scheduleWorkspaceSave()
            return
        }
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

        if let terminal = tabState.paneControllers[focusedPaneID] as? TerminalPaneController {
            retireHerdrPane(terminal)
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
        if tabState.herdrBackendLayout != nil {
            if let backend = tabState.herdrBackendLayout {
                func equalize(_ node: LayoutNode, path: [LayoutPathComponent]) {
                    guard case let .split(_, children, _) = node else { return }
                    let composedPath = tabState.herdrLocalLayout == nil ? path : [.child(0)] + path
                    updateSplitFractions(at: composedPath, to: Array(repeating: 1 / CGFloat(children.count), count: children.count), changeSource: .userDrag)
                    for (index, child) in children.enumerated() { equalize(child, path: path + [.child(index)]) }
                }
                equalize(backend, path: [])
            }
            tabState.herdrLocalLayout = tabState.herdrLocalLayout?.equalizingSplitFractions()
            if tabState.herdrLocalLayout != nil {
                tabState.herdrLocalFraction = 0.5
                scheduleHerdrShellResize()
            }
            tabState.composeHerdrLayout()
        } else { tabState.layoutNode = layoutNode.equalizingSplitFractions() }
        for paneID in tabState.paneControllers.keys {
            tabState.paneAutoResizeConfigurations[paneID]?.isEnabled = false
        }
        rebuildWorkspaceLayout()
        scheduleWorkspaceSave()
    }

    private func canEqualizePaneSplits() -> Bool {
        return (selectedTabState?.tiledPaneIDsInTraversalOrder.count ?? 0) > 1
    }

    private func movePaneDivider(_ direction: PaneDividerMoveDirection) {
        if let tabState = selectedTabState,
            tabState.activeFloatingPaneState != nil || tabState.activeDetachedPaneID != nil
        {
            resizeFloatingPane(in: tabState, direction: direction)
            return
        }

        guard
            let target = focusedResizeTarget(for: direction.axis),
            let targetFractions = movedDividerFractions(
                in: target.context,
                direction: direction
            )
        else {
            NSSound.beep()
            return
        }

        let clampedFractions = target.splitNode.clampedFractions(
            targetFractions,
            in: target.tilingView.bounds.size,
            dividerThickness: AppAppearanceSettings.workspaceDividerThickness
        )
        guard clampedFractions != target.context.fractions else {
            NSSound.beep()
            return
        }

        if selectedTabState?.herdrBackendLayout != nil {
            updateSplitFractions(at: target.context.splitPath, to: clampedFractions, changeSource: .userDrag)
            if let tab = selectedTabState, let node = tab.renderedLayout {
                target.tilingView.setLayoutNode(node, paneViews: buildPaneViewsDictionary(for: tab), animated: true)
            }
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
        guard let target = focusedResizeTarget(for: direction.axis) else { return false }
        return true
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
        if tabState.herdrBackendLayout != nil {
            guard tabState.herdrLocalLayout?.path(to: focusedPaneID) != nil,
                  tabState.herdrLocalLayout?.path(to: targetPaneID) != nil else { NSSound.beep(); return }
            tabState.herdrLocalLayout = tabState.herdrLocalLayout?.swappingPane(focusedPaneID, with: targetPaneID)
            tabState.composeHerdrLayout()
        } else { tabState.layoutNode = updatedLayoutNode }
        rebuildWorkspaceLayout(applyAutoZoomAnimated: true)
        scheduleWorkspaceSave()
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

        let target = directionalTiledPaneTarget(
            from: focusedPaneID,
            direction: direction.focusDirection,
            in: tabState
        )
        if tabState.herdrBackendLayout != nil {
            return tabState.herdrLocalLayout?.path(to: focusedPaneID) != nil && target.flatMap { tabState.herdrLocalLayout?.path(to: $0) } != nil
        }
        return target != nil
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
        if let index = herdrFloatingRecords.firstIndex(where: { $0.paneID == activePaneID }) {
            herdrFloatingRecords[index].size = newSize
            scheduleWorkspaceSave()
        }
        rootView.setCustomFloatingPaneSize(newSize)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            self?.resizeHerdrFloatingPane()
        }
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
        if herdrWindowWorkspaceID != nil, let binding = tabState(containing: paneID)?.terminalPaneController(for: paneID)?.herdrBinding { endHerdrTerminal(binding); return }
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
        if tabState.herdrBackendLayout != nil {
            leaveFloatingPane(in: tabState, animated: false, reapplyAutoZoom: false)
            if tabState.activeDetachedPaneID == paneID { hideActiveDetachedPane(in: tabState, animated: false, reapplyAutoZoom: false) }
            if let removal = tabState.herdrLocalLayout?.closingPane(paneID) { tabState.herdrLocalLayout = removal.root }
            tabState.detachedPaneIDs.removeAll { $0 == paneID }
            removePaneControllerState(for: paneID, in: tabState)
            tabState.composeHerdrLayout()
            tabState.focusedPaneID = tabState.herdrLocalLayout?.firstPaneID ?? tabState.herdrFocusedPaneID
            if tabState.id == selectedTabID { rebuildWorkspaceLayout() }
            scheduleWorkspaceSave()
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
        if let terminal = tabState.paneControllers[paneID] as? TerminalPaneController { retireHerdrPane(terminal) }
        tabState.paneControllers.removeValue(forKey: paneID)
        tabState.paneAutoResizeConfigurations.removeValue(forKey: paneID)
        tabState.floatingPaneSizes.removeValue(forKey: paneID)
        tabState.removePaneFromFocusHistory(paneID)
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

        if herdrWindowWorkspaceID != nil, !applyingHerdrLayout, let binding = tabState.terminalPaneController(for: paneID)?.herdrBinding {
            if paneID != tabState.focusedPaneID { queueHerdrFocus(binding) }
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
        if tabState.herdrBackendLayout?.path(to: paneID) != nil { tabState.herdrFocusedPaneID = paneID }
        tabState.markPaneFocused(paneID)
        if herdrWindowWorkspaceID != nil, tabState.herdrZoomed {
            rebuildWorkspaceLayout()
            return
        }
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

        if herdrWindowWorkspaceID != nil, !applyingHerdrLayout,
           let tab = tabs.first(where: { $0.id == tabID }),
           let binding = (tab.herdrFocusedPaneID ?? tab.focusedPaneID).flatMap({
               floatingRecord(for: $0)?.placeholder ?? tab.terminalPaneController(for: $0)?.herdrBinding
           }) ?? tab.herdrTabBinding {
            cancelPaneNameReveal()
            if tabID != selectedTabID {
                (selectedTabState?.focusedPaneController as? TerminalPaneController)?.exitScrollMode()
                for case let pane as TerminalPaneController in tabs.flatMap({ $0.paneControllers.values }) {
                    if pane.herdrBinding != nil { pane.setClientShellPresented(false) }
                }
                herdrShellPopup?.setPresented(false)
                queueHerdrFocus(binding)
                selectedTabID = tabID
                updateTabStrip()
            }
            // Keep the presented surfaces attached until the matching scene has parsed.
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

    private func moveTab(withID tabID: UUID, to destinationIndex: Int, backendCommitted: Bool = false) {
        if !backendCommitted, let tab = tabs.first(where: { $0.id == tabID }),
           let binding = tab.herdrTabBinding {
            guard herdrClient != nil, !herdrOperationPending, !herdrWorkspaceClosed,
                  herdrWindowWorkspaceID == nil || herdrShellSession?.isPresentationReady == true else {
                rootView.tabStripView.cancelPendingTabReorder()
                NSSound.beep()
                return
            }
            runHerdrOperation { [weak self] client in
                guard let self, !self.tabs.isEmpty, self.tabs.contains(where: { $0.id == tabID }) else { return }
                do {
                    let backendTabIDs = try await client.orderedTabIDs(for: binding)
                    guard let sourceIndex = backendTabIDs.firstIndex(of: binding.tabID) else { throw CLIError("Herdr tab disappeared before reordering") }
                    let localTarget = self.tabs[min(max(destinationIndex, 0), self.tabs.count - 1)]
                    let targetID = localTarget.herdrTabBinding?.tabID
                    let index = backendTabIDs.firstIndex { $0 == targetID } ?? max(0, backendTabIDs.count - 1)
                    // Herdr counts insertion positions before removal; dragging supplies the final index.
                    let insertIndex = sourceIndex < index ? index + 1 : index
                    _ = try await client.request("tab.move", params: .init(tab_id: binding.tabID, insert_index: insertIndex))
                    if self.herdrWindowWorkspaceID == nil { self.moveTab(withID: tabID, to: destinationIndex, backendCommitted: true) }
                } catch {
                    self.rootView.tabStripView.cancelPendingTabReorder()
                    throw error
                }
            }
            return
        }
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
        if herdrWindowWorkspaceID != nil, let binding = tabState.herdrTabBinding {
            if !bypassTabConfirmation {
                let alert = NSAlert()
                alert.messageText = "Close Herdr Tab?"
                alert.informativeText = "This ends every terminal and running process in this tab in Herdr."
                alert.addButton(withTitle: "Close Tab"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            mutateHerdrLayout("tab.close", binding: binding, params: .init(tab_id: binding.tabID))
            return
        }
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

        if tabs.count == 1, !otherLocalWorkspaces.isEmpty {
            guard bypassTabConfirmation || confirmCloseTabIfNeeded(tabState) else { return }
            removeCurrentLocalWorkspace()
            return
        }
        if tabs.count == 1 {
            guard confirmCloseWindowIfNeeded() else {
                return
            }

            retireHerdrPanes(in: tabState)
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
        retireHerdrPanes(in: tabState)

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

    private func retireHerdrPanes(in tabState: WorkspaceTabState) {
        for case let pane as TerminalPaneController in tabState.paneControllers.values { retireHerdrPane(pane) }
    }

    private func updateSelectedTabTitle(_ title: String) {
        guard let selectedTabState else {
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.utf8.count <= 1024 else { NSSound.beep(); return }
        if let binding = selectedTabState.herdrTabBinding {
            runHerdrOperation { client in
                if self.herdrWindowWorkspaceID != nil {
                    try await self.waitForPaletteNavigation { self.herdrShellSession?.isPresentationReady == true }
                }
                try await client.verify(binding)
                _ = try await client.request("tab.rename", params: .init(tab_id: binding.tabID, label: trimmedTitle))

            }
            return
        }
        selectedTabState.customTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        scheduleWorkspaceSave()
        updateTabStrip()
        updateWindowTitle()
    }

    private func handleTitleChange(for paneID: PaneID) {
        guard let tabState = tabState(containing: paneID) else {
            return
        }

        scheduleWorkspaceSave()
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

        if tabState.terminalPaneController(for: paneID)?.herdrBinding != nil { handleTitleChange(for: paneID) }
        else { performClosePane(withID: paneID, in: tabState) }
    }

    private func canDetachFocusedPane() -> Bool {
        if let id = selectedTabState?.focusedPaneID, floatingRecord(for: id) != nil { return false }
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
        if herdrFloatingTask != nil || herdrOperationPending { return false }
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
        if let id = selectedTabState?.focusedPaneID, floatingRecord(for: id) != nil { NSSound.beep(); return }
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
        if tabState.herdrBackendLayout != nil {
            if tabState.herdrLocalLayout?.path(to: paneID) != nil {
                tabState.herdrLocalLayout = tabState.herdrLocalLayout?.closingPane(paneID)?.root
            }
            tabState.composeHerdrLayout()
        } else { tabState.layoutNode = closePaneResult.root }
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
        if tabState.herdrBackendLayout != nil {
            if tabState.herdrBackendLayout?.path(to: paneID) == nil {
                if let local = tabState.herdrLocalLayout, let target = local.firstPaneID {
                    tabState.herdrLocalLayout = local.insertingSplit(for: target, axis: .horizontal, newPaneID: paneID)
                } else { tabState.herdrLocalLayout = .panel(paneID) }
            }
            tabState.composeHerdrLayout()
            tabState.focusedPaneID = paneID
            tabState.markPaneFocused(paneID)
            rebuildWorkspaceLayout(applyAutoZoomAnimated: true)
            scheduleWorkspaceSave()
            return
        }
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
        if let binding = tabState.terminalPaneController(for: paneID)?.herdrBinding, herdrWindowWorkspaceID != nil {
            tabState.herdrFocusedPaneID = paneID
            queueHerdrFocus(binding)
        }
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
        if tabState.focusedPaneController is TerminalPaneController,
           (tabState.focusedPaneController as? TerminalPaneController)?.herdrBinding != nil,
           herdrWindowWorkspaceID != nil {
            toggleHerdrFloatingPane(in: tabState, animated: animated)
            return
        }
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
        guard herdrFloatingTask == nil else { return }
        if let id = tabState.activeFloatingPaneState?.paneID, herdrFloatingDisplays[id] != nil {
            toggleHerdrFloatingPane(in: tabState, animated: animated)
            return
        }
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
        guard herdrFloatingTask == nil else { return }
        if let id = tabState.activeFloatingPaneState?.paneID, herdrFloatingDisplays[id] != nil {
            toggleHerdrFloatingPane(in: tabState, animated: false)
            return
        }
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

        guard let tabState = selectedTabState, let backendLayout = tabState.layoutNode else {
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

        let layoutNode = tabState.renderedLayout ?? backendLayout
        let paneViews = buildPaneViewsDictionary(for: tabState)

        if let tilingView {
            tilingView.commitsDividerChangesOnMouseUp = tabState.herdrBackendLayout != nil
            tilingView.setLayoutNode(layoutNode, paneViews: paneViews)
        } else {
            let newTilingView = WorkspaceTilingView(
                dividerThickness: AppAppearanceSettings.workspaceDividerThickness
            )
            newTilingView.commitsDividerChangesOnMouseUp = tabState.herdrBackendLayout != nil
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
        captureFloatingPaneSizes(in: tabState)
        if let id = tabState.activeFloatingPaneState?.paneID { herdrFloatingDisplays[id]?.stop() }
        rootView.removeFloatingPaneView()
    }

    private func captureFloatingPaneSizes(in tabState: WorkspaceTabState) {
        if var floatingState = tabState.activeFloatingPaneState,
            let paneController = tabState.paneControllers[floatingState.paneID],
            let size = rootView.floatingPaneFrame(for: paneController.hostView)?.size
        {
            floatingState.size = size
            tabState.activeFloatingPaneState = floatingState
            tabState.floatingPaneSizes[floatingState.paneID] = size
            if let index = herdrFloatingRecords.firstIndex(where: { $0.paneID == floatingState.paneID }) {
                herdrFloatingRecords[index].size = size
            }
        }

        if let detachedPaneID = tabState.activeDetachedPaneID,
            let paneController = tabState.paneControllers[detachedPaneID],
            let size = rootView.floatingPaneFrame(for: paneController.hostView)?.size
        {
            tabState.floatingPaneSizes[detachedPaneID] = size
        }
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
        if herdrShellSession?.isPresentationReady == true { herdrFloatingDisplays[paneID]?.resume() }
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

        if tabState.herdrBackendLayout != nil {
            guard changeSource == .userDrag, fractions.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 }) else { return }
            if tabState.activeAutoZoomState?.splitStates.contains(where: { $0.splitPath == path }) == true {
                tabState.activeAutoZoomState = nil
            }
            disableAutoResizeForPanesAffectedBySplit(at: path, in: tabState)
            if tabState.herdrLocalLayout != nil, path.isEmpty {
                guard fractions.count == 2 else { return }
                tabState.herdrLocalFraction = fractions[0]
                tabState.composeHerdrLayout()
                scheduleHerdrShellResize()
                scheduleWorkspaceSave()
                return
            }
            if tabState.herdrLocalLayout != nil, path.first == .child(1) {
                tabState.herdrLocalLayout = tabState.herdrLocalLayout?.replacingFractions(at: Array(path.dropFirst()), with: fractions)
                tabState.composeHerdrLayout()
                scheduleWorkspaceSave()
                return
            }
            guard changeSource == .userDrag, !tabState.herdrZoomed, fractions.count == 2, let binding = tabState.herdrTabBinding else { return }
            let corePath = tabState.herdrLocalLayout == nil ? path : Array(path.dropFirst())
            guard let split = tabState.herdrBackendLayout?.node(at: corePath) else { return }
            let edit = WorkspaceTabState.SplitEdit(fractions: fractions, paneIDs: split.paneIDsInTraversalOrder)
            tabState.herdrSplitEdits[corePath] = edit
            tabState.composeHerdrLayout()
            pendingHerdrSplits.removeAll { $0.binding.tabID == binding.tabID && $0.path == corePath }
            pendingHerdrSplits.append((binding, corePath, edit))
            flushHerdrSplit()
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
        scheduleWorkspaceSave()
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
            let modelLayoutNode = tabState.renderedLayout,
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
            let layoutNode = tabState.renderedLayout,
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
            let modelLayoutNode = tabState.renderedLayout,
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
        scheduleWorkspaceSave()
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
        let sessions = AgentSessionStore.shared.snapshots
        rootView.updateAgentStatus(
            sessionCount: sessions.count,
            unreadCount: AgentSessionStore.shared.unreadCount
        )
    }

    private func updateAgentManagerPopover() {
        guard agentManagerPopoverController?.isShown == true else {
            return
        }

        agentManagerPopoverController?.updateSessions(
            AgentSessionStore.shared.snapshots
        )
    }

    private func clearEndedAgentSessions() {
        AgentSessionStore.shared.clearEnded()
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
        for tabState in allWorkspaceTabs {
            for paneController in tabState.paneControllers.values {
                paneController.updateAppearance()
            }
        }

        if let selectedTabState {
            updatePanePresentation(in: selectedTabState)
        }
        updateWindowMinimumSize()
        syncHerdrShellAppearance()
    }

    private func syncHerdrShellAppearance() {
        retireHerdrShellHostColorQuery()
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        do {
            guard let session = herdrShellSession else { return }
            try syncHerdrShellTheme(session, dark: dark)
            refreshHerdrShellHostColors()
        }
        catch { herdrLastError = error.localizedDescription }
    }

    private func syncHerdrShellTheme(_ session: HerdrClientShellSession, dark: Bool) throws {
        if let theme = TerminalDefaults.themeDefinition {
            guard let foreground = HerdrShellRGB(hex: theme.foreground),
                  let background = HerdrShellRGB(hex: theme.background) else {
                throw CLIError("Terminal theme contains an invalid host color")
            }
            var palette: [UInt8: HerdrShellRGB] = [:]
            for (index, hex) in theme.palette {
                guard let index = UInt8(exactly: index), let color = HerdrShellRGB(hex: hex) else {
                    throw CLIError("Terminal theme contains an invalid host palette color")
                }
                palette[index] = color
            }
            try session.setHostColors(.init(foreground: foreground, background: background, palette: palette))
        }
        try session.setAppearance(dark: dark)
    }

    private func retireHerdrShellHostColorQuery() {
        herdrShellHostColorRequest += 1
        herdrShellHostColorTask?.cancel(); herdrShellHostColorTask = nil
        herdrShellHostColorSource = nil
    }

    private func refreshHerdrShellHostColors() {
        guard herdrShellHostColorTask == nil, let session = herdrShellSession, session.isPresentationReady,
              let tabID = session.projection.snapshot?.focused_tab_id,
              let tab = tabs.first(where: { $0.herdrTabBinding?.tabID == tabID }),
              let pane = (tab.herdrBackendLayout?.paneIDsInTraversalOrder ?? []).compactMap({ tab.terminalPaneController(for: $0) }).first(where: {
                  $0.herdrBinding != nil && $0.hostView.window != nil
              }) else { return }
        let source = (pane.id, pane.clientShellHostColorEpoch)
        guard herdrShellHostColorSource?.0 != source.0 || herdrShellHostColorSource?.1 != source.1 else { return }
        herdrShellHostColorSource = source
        herdrShellHostColorRequest += 1
        let request = herdrShellHostColorRequest, epoch = herdrShellGeneration
        herdrShellHostColorTask = Task { [weak self, weak session, weak pane] in
            guard let self else { return }
            defer {
                if self.herdrShellHostColorRequest == request {
                    self.herdrShellHostColorTask = nil
                    self.refreshHerdrShellHostColors()
                }
            }
            guard let session, let pane else { return }
            do {
                let colors = try await pane.queryClientShellHostColors()
                guard self.herdrShellGeneration == epoch, self.herdrShellHostColorRequest == request,
                      self.herdrShellSession === session else { return }
                try session.setHostColors(colors)
            } catch is CancellationError { }
            catch {
                guard self.herdrShellGeneration == epoch, self.herdrShellHostColorRequest == request else { return }
                self.herdrLastError = error.localizedDescription
            }
        }
    }

    private func updateWindowTitle() {
        view.window?.title = selectedTabState?.displayTitle ?? "Santty"
    }

    var commandPaletteCommands: [AppCommand] {
        [
            AppCommand(id: "terminal.herdr.diagnostics", title: "Herdr Diagnostics", shortcut: nil, isEnabled: !herdrOperationPending, perform: { [weak self] in self?.showPersistentDiagnostics(nil) }),
            AppCommand(id: "workspace.new", title: "New Workspace", shortcut: KeybindingSettings.displayShortcut(for: .newWorkspace), isEnabled: canCreateLocalWorkspace, perform: { [weak self] in self?.newWorkspace(nil) }),
            AppCommand(id: "workspace.herdr.new", title: "New Herdr Workspace", shortcut: KeybindingSettings.displayShortcut(for: .newHerdrWorkspace), isEnabled: !herdrOperationPending, perform: { [weak self] in self?.newHerdrWorkspace(nil) }),
            AppCommand(id: "workspace.remote.add", title: "Add Remote Herdr Machine", shortcut: nil, isEnabled: !herdrOperationPending, perform: { [weak self] in self?.addRemoteHerdrMachine(nil) }),
            AppCommand(id: "workspace.remote.authenticate", title: "Authenticate Remote Herdr Machine", shortcut: nil,
                isEnabled: !herdrOperationPending && herdrCatalog.states.values.contains { $0.endpoint.machine != nil }, perform: { [weak self] in self?.authenticateRemoteHerdrMachine(nil) }),
            AppCommand(id: "workspace.rename", title: "Rename Workspace", shortcut: KeybindingSettings.displayShortcut(for: .renameWorkspace), isEnabled: canCloseWorkspace, perform: { [weak self] in self?.renameWorkspace(nil) }),
            AppCommand(id: "workspace.close", title: "Close Workspace", shortcut: KeybindingSettings.displayShortcut(for: .closeWorkspace), isEnabled: canCloseWorkspace, perform: { [weak self] in self?.closeWorkspace(nil) }),
            AppCommand(id: "terminal.herdr.disconnect", title: KeybindingAction.disconnectPersistentTerminal.title, shortcut: KeybindingSettings.displayShortcut(for: .disconnectPersistentTerminal), isEnabled: (herdrWindowWorkspaceID != nil && herdrWindowWorkspaceID != nil || focusedHerdrBinding != nil) && (!herdrOperationPending || herdrShellRecoveryTask != nil), perform: { [weak self] in self?.disconnectPersistentTerminal(nil) }),
            AppCommand(id: "terminal.herdr.reconnect", title: KeybindingAction.reconnectPersistentTerminal.title, shortcut: KeybindingSettings.displayShortcut(for: .reconnectPersistentTerminal), isEnabled: (herdrWindowWorkspaceID != nil || focusedHerdrBinding != nil) && !herdrOperationPending, perform: { [weak self] in self?.reconnectPersistentTerminal(nil) }),
            AppCommand(id: "terminal.herdr.takeover", title: herdrWindowWorkspaceID != nil ? "Take Control of Herdr Window" : "Take Control of Herdr Window", shortcut: KeybindingSettings.displayShortcut(for: .takeOverPersistentTerminal), isEnabled: (herdrWindowWorkspaceID != nil || focusedHerdrBinding != nil) && !herdrOperationPending, perform: { [weak self] in self?.takeOverPersistentTerminal(nil) }),
            AppCommand(id: "terminal.herdr.end", title: "End Persistent Terminal", shortcut: KeybindingSettings.displayShortcut(for: .endPersistentTerminal), isEnabled: focusedHerdrBinding != nil && !herdrOperationPending, perform: { [weak self] in self?.endPersistentTerminal(nil) }),

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
                isEnabled: focusedTerminalPaneController != nil && focusedHerdrBinding == nil && focusedPaneIsTiled,
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
                isEnabled: focusedTerminalPaneController?.canAcceptInput == true,
                perform: { [weak self] in self?.openPromptEditor(nil) }
            ),
            AppCommand(
                id: "pane.scrollMode.enter",
                title: focusedHerdrBinding == nil ? "Enter Scroll Mode" : "Open Recent History Snapshot",
                shortcut: KeybindingSettings.displayShortcut(for: .enterScrollMode),
                isEnabled: focusedTerminalPaneController?.isLive == true
                    && focusedTerminalPaneController?.isScrollModeActive == false,
                perform: { [weak self] in self?.enterScrollMode(nil) }
            ),
            AppCommand(
                id: "pane.close",
                title: focusedHerdrBinding == nil ? "Close Pane" : herdrWindowWorkspaceID != nil ? "End Herdr Pane" : "Remove Persistent Terminal View",
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
                title: herdrWindowWorkspaceID != nil ? "Close Herdr Tab" : selectedTabState?.herdrTabBinding == nil ? "Close Tab" : "Remove Tab Views",
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
        guard allWorkspaceTabs.flatMap({ Array($0.paneControllers.values) }).contains(where: { $0.isLive && ($0 as? TerminalPaneController)?.herdrBinding == nil })
        else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close Window?"
        alert.informativeText = "Local terminal processes will close. Persistent terminals disconnect and continue running in Herdr."
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmCloseTabIfNeeded(_ tabState: WorkspaceTabState) -> Bool {
        guard tabState.paneControllers.values.contains(where: { $0.isLive && ($0 as? TerminalPaneController)?.herdrBinding == nil }) else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close Tab?"
        alert.informativeText = "Local terminal processes will close. Persistent terminals disconnect and continue running in Herdr."
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

extension WorkspaceViewController {
    private var focusedHerdrBinding: HerdrPaneBinding? { focusedTerminalPaneController?.herdrBinding }

    func configureHerdrWorkspace(_ endpoint: HerdrEndpoint) throws {
        try endpoint.validate()
        if let client = herdrClient, client.endpoint != endpoint,
           tabs.contains(where: { $0.paneControllers.values.contains { ($0 as? TerminalPaneController)?.herdrBinding != nil } }) {
            throw CLIError("Remove existing persistent terminal views before changing the Herdr connection")
        }
        herdrWorkspaceClosed = false
        herdrClient = HerdrWorkspaceClient(endpoint: endpoint)
        herdrLatestQuerySnapshot = nil
        herdrManagement?.disconnect()
        herdrManagementGeneration += 1
        let generation = herdrManagementGeneration
        herdrManagement = HerdrConnection(socketPath: endpoint.socketPath, endpoint: endpoint, snapshot: { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.herdrManagementGeneration == generation, !self.herdrWorkspaceClosed else { return }
                self.reconcileHerdrSnapshot(snapshot)
            }
        }, state: { [weak self] state in
            Task { @MainActor in
                guard let self, self.herdrManagementGeneration == generation, !self.herdrWorkspaceClosed else { return }
                self.herdrManagementState = state
                if case .failed(let message) = state {
                    self.herdrLastError = message
                    self.herdrLatestQuerySnapshot = nil
                    if self.herdrWindowWorkspaceID == nil {
                        self.herdrDiscoveredWorkspaces = []
                        self.refreshWorkspacePicker()
                    }
                }
            }
        })
        herdrManagement?.connect()
    }

    func discoverHerdrWorkspaces() {
        herdrDiscoveryTask?.cancel()
        herdrDiscoveryTask = Task { [weak self] in
            guard let self, !self.herdrWorkspaceClosed else { return }
            let local = HerdrSettings.endpoint
            self.startHerdrAgentMonitoring(local)
            do {
                if self.herdrClient == nil { try self.configureHerdrWorkspace(local) }
                if self.herdrClient?.endpoint.machine == nil, self.herdrClient?.endpoint != local {
                    self.selectLocalWorkspace()
                    self.herdrDiscoveredWorkspaces = []
                    try self.configureHerdrWorkspace(local)
                }
                guard let client = self.herdrClient else { return }
                let generation = self.herdrManagementGeneration
                let snapshot = try await client.snapshot()
                guard !Task.isCancelled, generation == self.herdrManagementGeneration else { return }
                self.reconcileHerdrSnapshot(snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                self.herdrLastError = error.localizedDescription
                self.refreshWorkspacePicker()
            }
        }
    }

    func waitForHerdrWorkspaceDiscovery() async { await herdrDiscoveryTask?.value }

    private func refreshWorkspacePicker(_ workspaces: [HerdrSnapshot.Workspace]? = nil) {
        if let workspaces {
            guard workspaces.count <= 64,
                  Set(workspaces.map(\.workspace_id)).count == workspaces.count,
                  workspaces.allSatisfy({ !$0.workspace_id.isEmpty && $0.workspace_id.utf8.count <= 1024 && $0.label.utf8.count <= 4096 }) else {
                herdrLastError = "Invalid Herdr workspace snapshot"
                return
            }
            herdrDiscoveredWorkspaces = workspaces
        }
        var entries = localWorkspaceStates.map {
            WorkspaceEntry(reference: .init(source: .local($0.id)), name: $0.name)
        }
        let live = herdrCatalog.workspaces
        var backend = Dictionary(uniqueKeysWithValues: workspaceEntries.filter { $0.kind != .local }.map { ($0.id, $0) })
        for state in herdrCatalog.states.values {
            guard let snapshot = state.snapshot else { continue }
            let ids = Set(snapshot.workspaces.map(\.workspace_id))
            backend = backend.filter { _, entry in
                if case .herdr(let endpoint, let id) = entry.reference.source, endpoint.id == state.endpoint.id { return ids.contains(id) }
                return true
            }
        }
        for entry in live { backend[entry.id] = entry }
        if let active = herdrClient?.endpoint {
            let endpoint = herdrCatalog.states[active.id]?.endpoint ?? active
            for workspace in herdrDiscoveredWorkspaces {
                let reference = WorkspaceReference(source: .herdr(endpoint: endpoint, workspaceID: workspace.workspace_id))
                if backend[reference.id] == nil || endpoint.id == herdrClient?.endpoint.id {
                    let available = herdrCatalog.states[endpoint.id].map {
                        $0.identity != nil || ($0.snapshot == nil && $0.status == .connecting && herdrLatestQuerySnapshot != nil)
                    }
                        ?? (herdrWindowWorkspaceID != nil ? herdrShellSession?.failure == nil : herdrLatestQuerySnapshot != nil)
                    backend[reference.id] = .init(reference: reference, name: workspace.label,
                        isAvailable: available)
                }
            }
        }
        let catalogIDs = Set(herdrCatalog.states.keys)
        if !catalogIDs.isEmpty {
            backend = backend.filter { _, entry in
                if case .herdr(let endpoint, _) = entry.reference.source { return catalogIDs.contains(endpoint.id) || endpoint == herdrClient?.endpoint }
                return false
            }
        }
        entries += backend.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        workspaceEntries = entries
        let selected = herdrWindowWorkspaceID.flatMap { id in herdrClient.map { WorkspaceReference(source: .herdr(endpoint: $0.endpoint, workspaceID: id)) } }
            ?? WorkspaceReference(source: .local(localWorkspaceID))
        rootView.toolbarView.updateWorkspaceEntries(entries, selectedID: selected.id)
    }

    func collectHerdrDiagnostics() async -> HerdrDiagnostics {
        let controllers = tabs.flatMap { $0.paneControllers.values }
        let endpoint = herdrClient?.endpoint ?? tabs.compactMap { $0.herdrTabBinding?.endpoint }.first
            ?? controllers.compactMap { ($0 as? RestoredPanePlaceholderController)?.savedPane.binding?.endpoint }.first
        let panes = controllers.compactMap { controller -> HerdrDiagnostics.Pane? in
            if let placeholder = controller as? RestoredPanePlaceholderController, let binding = placeholder.savedPane.binding {
                return .init(id: placeholder.id, backendPaneID: binding.paneID, terminalID: binding.terminalID,
                             mode: placeholder.savedPane.mode, state: "restore-required", lastError: "Automatic restore unavailable; choose an existing terminal")
            }
            guard let pane = controller as? TerminalPaneController, let binding = pane.herdrBinding else { return nil }
            let error: String?
            switch pane.herdrState {
            case .failed(let message), .terminalEnded(let message): error = HerdrDiagnosticError.summary(message)
            default: error = HerdrDiagnosticError.summary(pane.clientShellDisplayError)
            }
            return .init(id: pane.id, backendPaneID: binding.paneID, terminalID: pane.herdrQueryBinding?.terminalID,
                         mode: pane.herdrRestorationMode, state: pane.herdrState.diagnosticName, lastError: error, transport: pane.herdrTransport)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let bundle = Bundle.main
        var report = HerdrDiagnostics(santtyVersion: "\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") (\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"))",
            session: endpoint?.session, executable: endpoint?.binary.path, socket: endpoint?.socketPath,
            managementState: herdrManagementState.diagnosticName, panes: panes,
            lastError: HerdrDiagnosticError.summary(herdrLastError))
        report.windowTransport = herdrWindowWorkspaceID == nil ? nil : herdrWindowTransport
        report.clientShell = herdrShellSession?.diagnostics
        report.clientShell?.recoveryAttempts = herdrShellRecoveryAttempts
        report.clientShell?.popupLastError = HerdrDiagnosticError.summary(herdrShellPopup?.displayError)
        if let endpoint { await report.inspect(endpoint) }
        return report
    }

    @objc func showPersistentDiagnostics(_: Any?) {
        Task { [weak self] in
            guard let self else { return }
            let report = await self.collectHerdrDiagnostics()
            guard !self.herdrWorkspaceClosed else { return }
            do {
                let json = try report.json()
                let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
                text.isEditable = false; text.isSelectable = true
                text.setAccessibilityLabel("Herdr diagnostic report")
                text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                text.string = json
                text.isVerticallyResizable = true
                text.textContainer?.widthTracksTextView = true
                let scroll = NSScrollView(frame: text.frame)
                scroll.hasVerticalScroller = true; scroll.documentView = text
                let alert = NSAlert()
                alert.messageText = "Herdr Diagnostics"
                alert.informativeText = herdrLastError ?? "Includes local connection paths and object IDs. Excludes terminal text, pane titles, cwd and raw errors."
                alert.accessoryView = scroll
                alert.addButton(withTitle: "Close"); alert.addButton(withTitle: "Copy JSON")
                if alert.runModal() == .alertSecondButtonReturn {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(json, forType: .string)
                }
            } catch { self.presentHerdrError(error) }
        }
    }

    @objc func newHerdrWorkspace(_: Any?) {
        guard !isClosingNotes else { return }
        if herdrClient == nil {
            do { try configureHerdrWorkspace(HerdrSettings.endpoint) }
            catch { presentHerdrError(error); return }
        }
        createHerdrPane()
    }

    @objc func addRemoteHerdrMachine(_: Any?) {
        guard !herdrOperationPending, !isClosingNotes, !herdrWorkspaceClosed else { return }
        let alert = NSAlert()
        alert.messageText = "Add Remote Herdr Machine"
        alert.informativeText = "Setup opens in a local terminal. Herdr handles SSH authentication, session discovery, and any installation or replacement confirmation."
        alert.addButton(withTitle: "Open Setup"); alert.addButton(withTitle: "Cancel")
        let target = NSTextField(), session = NSTextField(), label = NSTextField()
        target.placeholderString = "SSH host or ssh://user@host:port"
        session.placeholderString = "Session (blank to discover)"
        label.placeholderString = "Machine label (optional)"
        target.setAccessibilityLabel("SSH target"); session.setAccessibilityLabel("Herdr session"); label.setAccessibilityLabel("Machine label")
        for field in [target, session, label] { field.usesSingleLineMode = true; field.widthAnchor.constraint(equalToConstant: 360).isActive = true }
        let stack = NSStackView(views: [target, session, label]); stack.orientation = .vertical; stack.alignment = .leading
        stack.setFrameSize(stack.fittingSize)
        alert.accessoryView = stack; alert.window.initialFirstResponder = target
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let command = try HerdrMachineProfile.setupCommand(binary: HerdrSettings.endpoint.binary,
                target: target.stringValue, session: session.stringValue, label: label.stringValue)
            openHerdrSetupTerminal(command)
        } catch { presentHerdrError(error) }
    }

    @objc func authenticateRemoteHerdrMachine(_: Any?) {
        let machines = herdrCatalog.states.values.compactMap { $0.endpoint.machine }.sorted { $0.label < $1.label }
        guard !machines.isEmpty else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Authenticate Remote Herdr Machine"
        alert.informativeText = "Herdr verifies the saved machine in a local terminal. This does not install or update Herdr."
        alert.addButton(withTitle: "Open Terminal"); alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        picker.addItems(withTitles: machines.map { $0.label + " · " + $0.target })
        if let active = herdrClient?.endpoint.machine, let index = machines.firstIndex(where: { $0.id == active.id }) { picker.selectItem(at: index) }
        alert.accessoryView = picker
        guard alert.runModal() == .alertFirstButtonReturn, machines.indices.contains(picker.indexOfSelectedItem) else { return }
        let machine = machines[picker.indexOfSelectedItem]
        openHerdrSetupTerminal(HerdrSSHBridge.quote(HerdrSettings.endpoint.binary.path) + " machine reconnect " + HerdrSSHBridge.quote(machine.id))
    }

    private func openHerdrSetupTerminal(_ command: String) {
        guard !herdrOperationPending, !isClosingNotes, !herdrWorkspaceClosed else { return }
        selectLocalWorkspace()
        let script = command + "; printf '\\nHerdr setup finished. Remote workspaces refresh automatically.\\n'; exec \"${SHELL:-/bin/zsh}\" -l"
        let pane = makeTerminalPaneController(launchCommand: "/bin/sh -c " + HerdrSSHBridge.quote(script))
        pane.name = "Herdr Setup"
        let tab = WorkspaceTabState(layoutNode: .panel(pane.id), paneControllers: [pane.id: pane],
            paneAutoResizeConfigurations: [:], focusedPaneID: pane.id)
        tabs.append(tab); selectedTabID = tab.id
        rebuildWorkspaceLayout(); pane.startIfNeeded(); scheduleWorkspaceSave()
        startHerdrAgentMonitoring(HerdrSettings.endpoint)
    }

    @objc func renameWorkspace(_: Any?) {
        guard canCloseWorkspace else { return }
        let localID = localWorkspaceID
        let workspaceID = herdrWindowWorkspaceID
        let identity = herdrWindowIdentity
        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.usesSingleLineMode = true
        field.stringValue = workspaceID.flatMap { id in herdrDiscoveredWorkspaces.first { $0.workspace_id == id }?.label } ?? localWorkspaceName
        field.placeholderString = "Workspace name"
        field.selectText(nil)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              localID == localWorkspaceID, workspaceID == herdrWindowWorkspaceID,
              identity == herdrWindowIdentity else { return }
        updateSelectedWorkspaceName(field.stringValue)
    }

    func updateSelectedWorkspaceName(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canCloseWorkspace, !name.isEmpty, name.utf8.count <= 1024 else { NSSound.beep(); return }
        if let workspaceID = herdrWindowWorkspaceID {
            guard let binding = tabs.first?.herdrTabBinding else { return }
            runHerdrOperation { client in
                try await self.waitForPaletteNavigation { self.herdrShellSession?.isPresentationReady == true }
                try await client.verify(binding)
                _ = try await client.request("workspace.rename", params: .init(workspace_id: workspaceID, label: name))
            }
        } else {
            localWorkspaceName = name
            refreshWorkspacePicker()
            scheduleWorkspaceSave()
        }
    }

    @objc func newWorkspace(_: Any?) {
        guard canCreateLocalWorkspace else { return }
        selectLocalWorkspace()
        suspendLocalWorkspacePresentation()
        otherLocalWorkspaces.append(.init(id: localWorkspaceID, name: localWorkspaceName, tabs: tabs, selectedTabID: selectedTabID))
        let names = Set(otherLocalWorkspaces.map(\.name))
        var number = 1
        while names.contains("Workspace \(number)") { number += 1 }
        localWorkspaceID = UUID()
        localWorkspaceName = "Workspace \(number)"
        createInitialTab()
        finishLocalWorkspaceSwitch()
    }

    private var canCreateLocalWorkspace: Bool {
        !herdrOperationPending && !isClosingNotes && !herdrWorkspaceClosed
            && otherLocalWorkspaces.count < 63 && allWorkspaceTabs.count < 64
    }

    private var canCloseWorkspace: Bool {
        !herdrOperationPending && !isClosingNotes && !herdrWorkspaceClosed
            && (herdrWindowWorkspaceID == nil ? !tabs.isEmpty : herdrShellSession?.isPresentationReady == true)
    }

    func closeWorkspaceAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close Workspace?"
        alert.informativeText = herdrWindowWorkspaceID == nil
            ? "This closes \(localWorkspaceName) and ends all its local terminal processes."
            : "This ends every terminal and running process in this Herdr workspace. Local browser and notes panes will be kept in your local workspace."
        alert.addButton(withTitle: "Close Workspace"); alert.addButton(withTitle: "Cancel")
        return alert
    }

    @objc func closeWorkspace(_: Any?) {
        guard canCloseWorkspace else { return }
        let localID = localWorkspaceID
        let workspaceID = herdrWindowWorkspaceID
        let binding = tabs.first?.herdrTabBinding
        guard closeWorkspaceAlert().runModal() == .alertFirstButtonReturn,
              localID == localWorkspaceID, workspaceID == herdrWindowWorkspaceID else { return }
        if workspaceID != nil {
            if let binding { closeHerdrWorkspace(binding: binding) }
        } else {
            Task { [weak self] in await self?.closeLocalWorkspace(localID) }
        }
    }

    func closeLocalWorkspace(_ id: UUID) async {
        guard id == localWorkspaceID, herdrWindowWorkspaceID == nil, canCloseWorkspace else { return }
        isClosingNotes = true
        defer { isClosingNotes = false }
        let notes = tabs.flatMap { $0.paneControllers.values.compactMap { $0 as? NotesPaneController } }
        guard await prepareNotesToClose(notes), id == localWorkspaceID, herdrWindowWorkspaceID == nil else { return }
        removeCurrentLocalWorkspace()
    }

    private func removeCurrentLocalWorkspace() {
        suspendLocalWorkspacePresentation()
        for tab in tabs { retireHerdrPanes(in: tab) }
        if let next = otherLocalWorkspaces.first {
            otherLocalWorkspaces.removeFirst()
            localWorkspaceID = next.id; localWorkspaceName = next.name
            tabs = next.tabs; selectedTabID = next.selectedTabID
        } else {
            localWorkspaceID = UUID(); localWorkspaceName = "Default"
            createInitialTab()
        }
        finishLocalWorkspaceSwitch()
    }

    func selectLocalWorkspace(_ id: UUID) {
        if id == localWorkspaceID { selectLocalWorkspace(); return }
        guard let index = otherLocalWorkspaces.firstIndex(where: { $0.id == id }) else { return }
        selectLocalWorkspace()
        suspendLocalWorkspacePresentation()
        let next = otherLocalWorkspaces.remove(at: index)
        otherLocalWorkspaces.append(.init(id: localWorkspaceID, name: localWorkspaceName, tabs: tabs, selectedTabID: selectedTabID))
        localWorkspaceID = next.id; localWorkspaceName = next.name
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

    func closeHerdrWorkspace(binding: HerdrPaneBinding) {
        guard binding.workspaceID == herdrWindowWorkspaceID else { return }
        runHerdrOperation { [weak self] client in
            guard let self else { return }
            try await self.waitForPaletteNavigation { self.herdrShellSession?.isPresentationReady == true }
            try await client.verify(binding)
            _ = try await client.request("workspace.close", params: .init(workspace_id: binding.workspaceID))
            self.selectLocalWorkspace()
            for tab in self.herdrAuxiliaryTabs where tab.herdrTabBinding?.workspaceID == binding.workspaceID {
                self.recoverAuxiliaries(tab)
            }
            self.herdrAuxiliaryTabs.removeAll { $0.herdrTabBinding == nil }
            self.rebuildWorkspaceLayout()
            self.scheduleWorkspaceSave()
        }
    }

    private func runHerdrOperation(requiresPresentation: Bool = true,
                                   _ body: @escaping @MainActor (HerdrWorkspaceClient) async throws -> Void) {
        guard let client = herdrClient, !herdrOperationPending, !herdrWorkspaceClosed else { NSSound.beep(); return }
        if requiresPresentation, herdrWindowWorkspaceID != nil, herdrShellSession?.isPresentationReady != true { NSSound.beep(); return }
        herdrOperationPending = true
        herdrLastError = nil
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.herdrOperationPending = false
                self.flushHerdrFocus()
                self.flushHerdrSplit()
            }
            do {
                try await body(client)
                self.requestHerdrLayoutRefresh()
            }
            catch { self.presentHerdrError(error) }
        }
    }

    private func presentHerdrError(_ error: Error) {
        herdrLastError = error.localizedDescription
        if paletteNavigationInProgress {
            rootView.toolbarView.showNavigationStatus("Navigation failed: \(error.localizedDescription)")
            herdrErrorHandler?(error.localizedDescription)
            return
        }
        if let herdrErrorHandler { herdrErrorHandler(error.localizedDescription); return }
        guard !herdrWorkspaceClosed, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Herdr Operation Failed"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    func createHerdrPane(workspaceID: String? = nil, split: HerdrPaneBinding? = nil,
                         axis: SplitAxis = .horizontal, anchor: PaneID? = nil) {
        let workspaceBinding = workspaceID.flatMap { id in tabs.compactMap(\.herdrTabBinding).first { $0.workspaceID == id } }
        let initialCwd = focusedTerminalPaneController?.workingDirectoryForNewPane
        runHerdrOperation { [weak self] client in
            var cwd = initialCwd
            if let workspaceBinding {
                let source = try await client.verify(workspaceBinding)
                cwd = source.foreground_cwd ?? source.cwd
            }
            let pane = try await client.create(workspaceID: workspaceID, split: split, axis: axis, cwd: split == nil ? cwd : nil)
            guard let self, !self.herdrWorkspaceClosed else { return }
            if self.herdrWindowWorkspaceID != nil { return }
            guard let workspace = pane.workspace_id else { throw CLIError("Herdr created a pane without a workspace") }
            try await self.enterHerdrWorkspace(workspace)
        }
    }

    private func reconcileHerdrSnapshot(_ snapshot: HerdrSnapshot) {
        herdrLatestQuerySnapshot = snapshot
        if herdrWindowWorkspaceID == nil { refreshWorkspacePicker(snapshot.workspaces) }
        for tab in tabs {
            for case let pane as TerminalPaneController in tab.paneControllers.values {
                guard let binding = pane.herdrBinding else { continue }
                // Remote subscription reads have no verified boot; ClientShell owns invalidation.
                guard binding.endpoint.machine == nil || snapshot.panes.contains(where: { $0.serviceIdentity == binding.serviceIdentity }) else { continue }
                pane.applyHerdrSnapshot(snapshot.panes.first { binding.matches($0, requireRuntime: false) })
            }
        }
    }

    @objc func disconnectPersistentTerminal(_: Any?) {
        guard !herdrOperationPending || herdrShellRecoveryTask != nil else { return }
        herdrShellRecoveryTask?.cancel(); stopHerdrClientShell()
    }

    @objc func reconnectPersistentTerminal(_: Any?) {
        guard !herdrOperationPending, !herdrWorkspaceClosed else { return }
        guard herdrWindowWorkspaceID != nil else { return }
        reconnectHerdrWindow()
    }


    private func reconnectHerdrWindow(claimControl: Bool = false) {
        guard !herdrOperationPending, !herdrWorkspaceClosed, let workspaceID = herdrWindowWorkspaceID else { return }
        herdrShellRecoveryTask?.cancel()
        herdrShellRecoveryAttempts = 0
        // Reconnection cannot use the mutation gate: a disconnected shell has no presentation.
        herdrOperationPending = true
        rootView.toolbarView.workspaceSwitcher.isEnabled = herdrClient?.endpoint.machine != nil
        herdrLastError = nil
        let selection = workspaceSelectionGeneration
        herdrShellReconnectTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.workspaceSelectionGeneration == selection {
                    self.herdrShellReconnectTask = nil
                    self.herdrOperationPending = false
                    self.rootView.toolbarView.workspaceSwitcher.isEnabled = true
                    self.flushHerdrFocus(); self.flushHerdrSplit()
                }
            }
            do {
                try await self.enterHerdrWorkspace(workspaceID)
                if claimControl {
                    guard let session = self.herdrShellSession, let client = self.herdrClient,
                          let paneID = session.projection.snapshot?.focused_pane_id else { throw CLIError("Herdr has no active pane to control") }
                    _ = try await client.request("pane.focus", params: .init(pane_id: paneID))
                    try await self.waitForHerdrShellPresentation(session, epoch: self.herdrShellGeneration)
                }
            }
            catch is CancellationError { }
            catch { self.presentHerdrError(error) }
        }
    }
    @objc func takeOverPersistentTerminal(_: Any?) {
        guard !herdrOperationPending, !herdrWorkspaceClosed else { return }
        if herdrWindowWorkspaceID != nil { reconnectHerdrWindow(claimControl: true) }

    }

    @objc func endPersistentTerminal(_: Any?) {
        guard let binding = focusedHerdrBinding else { return }
        let alert = NSAlert()
        alert.messageText = "End Persistent Terminal?"
        alert.informativeText = "This ends \(binding.paneID) and its running processes in Herdr. To keep them running, disconnect the view or select a local workspace."
        alert.addButton(withTitle: "End Terminal"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        endHerdrTerminal(binding)
    }

    func endHerdrTerminal(_ binding: HerdrPaneBinding) {
        runHerdrOperation { client in
            try await client.verify(binding)
            _ = try await client.request("pane.close", params: .init(pane_id: binding.paneID))
        }
    }

    func windowWillClose(_ notification: Notification) { releaseHerdrConnections() }

    private func retireHerdrPane(_ pane: TerminalPaneController) {
        pane.disconnectHerdr()
    }

    var hasHerdrConnectionsToRelease: Bool {
        tabs.contains { $0.herdrTabBinding != nil }
    }

    func finishHerdrShutdown() async {
        releaseHerdrConnections()
        await herdrFloatingShutdownTask?.value
    }

    func releaseHerdrConnections() {
        herdrWorkspaceClosed = true
        workspaceSelectionGeneration += 1; workspaceSelectionTask?.cancel(); workspaceSelectionTask = nil
        paletteNavigationTask?.cancel()
        herdrDiscoveryTask?.cancel()
        selectLocalWorkspace()
        if let shutdown = herdrFloatingShutdownTask {
            let catalog = herdrCatalog
            Task { await shutdown.value; catalog.stop() }
        } else { herdrCatalog.stop() }
        herdrManagementState = .disconnected
        herdrManagementGeneration += 1
        herdrManagement?.disconnect()
        for tab in allWorkspaceTabs {
            for case let pane as TerminalPaneController in tab.paneControllers.values { retireHerdrPane(pane) }
        }
    }

    var debugFocusedHerdrPane: TerminalPaneController? { focusedTerminalPaneController?.herdrBinding == nil ? nil : focusedTerminalPaneController }
    var debugHerdrOperationPending: Bool { herdrOperationPending }
    var debugHerdrShellSession: HerdrClientShellSession? { herdrShellSession }
    var debugHerdrWorkspaceClient: HerdrWorkspaceClient? { herdrClient }
}

extension WorkspaceViewController {
    func prepareWorkspacePersistence(url: URL = WorkspaceStore.defaultURL) async {
        do {
            let store = try await Task.detached { try WorkspaceStore(url: url) }.value
            workspaceStore = store
            let loaded = try await store.load()
            initialSavedWorkspace = loaded.workspace?.tabs.isEmpty == false ? loaded.workspace : nil
            workspacePersistenceError = loaded.warning
        } catch { workspacePersistenceError = error.localizedDescription }
    }

    func savedWorkspace() -> SavedWorkspace {
        var document = savedWorkspaceTabs(tabs, selected: selectedTabID)
        if herdrWindowWorkspaceID != nil || parkedLocalTabs != nil {
            document.herdrWindowBinding = tabs.first?.herdrTabBinding
            document.herdrWindowMode = herdrWindowMode
            document.herdrWindowTransport = herdrWindowTransport
            document.parkedTabs = parkedLocalTabs.map { savedWorkspaceTabs($0, selected: parkedSelectedTabID).tabs }
            document.parkedSelectedTabID = parkedSelectedTabID
        }
        document.herdrAuxiliaryTabs = herdrAuxiliaryTabs.isEmpty ? nil : savedWorkspaceTabs(herdrAuxiliaryTabs, selected: nil).tabs
        document.workspaces = workspaceEntries
        document.selectedWorkspace = herdrWindowWorkspaceID.flatMap { id in herdrClient.map { .init(source: .herdr(endpoint: $0.endpoint, workspaceID: id)) } }
            ?? .init(source: .local(localWorkspaceID))
        document.herdrFloatingPanes = herdrFloatingRecords.isEmpty ? nil : herdrFloatingRecords
        document.localWorkspaceID = localWorkspaceID
        document.localWorkspaceName = localWorkspaceName
        document.otherLocalWorkspaces = otherLocalWorkspaces.isEmpty ? nil : otherLocalWorkspaces.map {
            .init(id: $0.id, name: $0.name, selectedTabID: $0.selectedTabID,
                  tabs: savedWorkspaceTabs($0.tabs, selected: $0.selectedTabID).tabs)
        }
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
                    return .init(id: pane.id, kind: terminal.herdrBinding == nil ? .localTerminal : .persistentTerminal,
                        name: pane.name, title: terminal.lastKnownTitle, cwd: terminal.currentWorkingDirectory,
                        binding: floatingRecord(for: terminal.id)?.placeholder ?? terminal.herdrBinding, mode: terminal.herdrRestorationMode)
                }
                if let browser = pane as? BrowserPaneController {
                    return .init(id: pane.id, kind: .browser, name: pane.name, title: pane.displayTitle, browserURL: browser.restorationURL)
                }
                return .init(id: pane.id, kind: .notes, name: pane.name, title: pane.displayTitle,
                             noteFileName: (pane as? NotesPaneController)?.content.library.activeID,
                             noteFileURL: (pane as? NotesPaneController)?.content.store.fileURL)
            }
            return .init(id: tab.id, layout: layout, panes: panes, focusedPaneID: tab.focusedPaneID,
                customTitle: tab.customTitle, backendBinding: tab.herdrTabBinding,
                autoResize: tab.paneAutoResizeConfigurations, detachedPaneIDs: tab.detachedPaneIDs,
                activeDetachedPaneID: tab.activeDetachedPaneID,
                floating: tab.activeFloatingPaneState.map { .init(paneID: $0.paneID, size: $0.size) },
                floatingSizes: tab.floatingPaneSizes, herdrBackendLayout: tab.herdrBackendLayout,
                herdrLocalLayout: tab.herdrLocalLayout, herdrLocalFraction: tab.herdrLocalFraction, herdrFocusedPaneID: tab.herdrFocusedPaneID)
        }
        return .init(selectedTabID: selected, tabs: savedTabs)
    }

    private func scheduleWorkspaceSave() {
        guard workspaceStore?.canWrite == true, workspacePersistenceActivated, !suppressWorkspaceSaving, !herdrWorkspaceClosed else { return }
        workspaceSaveTask?.cancel()
        workspaceSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard let self, let store = self.workspaceStore, !self.herdrWorkspaceClosed else { return }
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
        if herdrWorkspaceClosed { return true }
        do { try await flushWorkspaceState(); return true }
        catch {
            workspacePersistenceError = error.localizedDescription
            guard herdrErrorHandler == nil else { return false }
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
        herdrFloatingRecords = document.herdrFloatingPanes ?? []
        workspaceEntries = (document.workspaces ?? []).map {
            var entry = $0
            if entry.kind != .local { entry.isAvailable = false; entry.status = "Reconnecting" }
            return entry
        }
        restoredWorkspaceSelection = document.selectedWorkspace
        herdrShellReconnectTask?.cancel()
        herdrShellRecoveryTask?.cancel()
        herdrShellRecoveryAttempts = 0
        stopHerdrClientShell()
        // Subscription refreshes must not activate a saved window before its identity is verified.
        herdrWindowWorkspaceID = nil
        herdrWindowIdentity = nil
        suppressWorkspaceSaving = true
        defer { suppressWorkspaceSaving = false }
        func restoreTabs(_ savedTabs: [SavedWorkspace.Tab]) -> [WorkspaceTabState] {
            var restoredTabs: [WorkspaceTabState] = []
            for saved in savedTabs {
                var controllers: [PaneID: any PaneControlling] = [:]
                for pane in saved.panes {
                    let controller: any PaneControlling
                    switch pane.kind {
                    case .localTerminal, .persistentTerminal:
                        let placeholder = RestoredPanePlaceholderController(pane: pane, message: pane.kind == .localTerminal
                            ? "Previous local session ended. Start a new shell explicitly."
                            : "Select this terminal’s Herdr workspace to reconnect.")
                        placeholder.onFocusRequest = { [weak self] in self?.handlePaneFocusRequest(withID: $0) }
                        placeholder.onActivate = { [weak self] in
                            guard let self else { return }
                            if pane.kind == .localTerminal { self.replaceRestoredPane(pane.id, with: self.makeTerminalPaneController(id: pane.id, workingDirectory: pane.cwd)) }
                            else {
                                do {
                                    if let binding = pane.binding {
                                        if self.herdrClient?.endpoint != binding.endpoint { try self.configureHerdrWorkspace(binding.endpoint) }
                                        self.selectWorkspace(binding.workspaceID)
                                    }
                                } catch { self.presentHerdrError(error) }
                            }
                        }
                        controller = placeholder
                    case .browser:
                        let browser = makeBrowserPaneController(id: pane.id)
                        if let url = pane.browserURL, let scheme = URL(string: url)?.scheme?.lowercased(), ["http", "https"].contains(scheme) { browser.loadURLString(url) }
                        controller = browser
                    case .notes:
                        controller = makeNotesPaneController(id: pane.id, preferredFileName: pane.noteFileName, fileURL: pane.noteFileURL)
                    }
                    controller.name = pane.name
                    controllers[pane.id] = controller
                }
                let tab = WorkspaceTabState(id: saved.id, layoutNode: saved.layout, paneControllers: controllers,
                    paneAutoResizeConfigurations: saved.autoResize, focusedPaneID: saved.focusedPaneID, customTitle: saved.customTitle,
                    activeFloatingPaneState: saved.floating.map { .init(paneID: $0.paneID, size: $0.size) })
                tab.herdrTabBinding = saved.backendBinding
                tab.herdrBackendLayout = saved.herdrBackendLayout
                tab.herdrLocalLayout = saved.herdrLocalLayout
                tab.herdrLocalFraction = saved.herdrLocalFraction ?? 0.7
                tab.herdrFocusedPaneID = saved.herdrFocusedPaneID
                tab.detachedPaneIDs = saved.detachedPaneIDs
                tab.activeDetachedPaneID = saved.activeDetachedPaneID
                tab.floatingPaneSizes = saved.floatingSizes
                restoredTabs.append(tab)
            }
            return restoredTabs
        }
        localWorkspaceID = document.localWorkspaceID ?? UUID()
        localWorkspaceName = document.localWorkspaceName ?? "Default"
        otherLocalWorkspaces = (document.otherLocalWorkspaces ?? []).map {
            .init(id: $0.id, name: $0.name, tabs: restoreTabs($0.tabs), selectedTabID: $0.selectedTabID ?? $0.tabs.first?.id)
        }
        let restoredTabs = restoreTabs(document.tabs + (document.parkedTabs ?? []) + (document.herdrAuxiliaryTabs ?? []))
        tabs = Array(restoredTabs.prefix(document.tabs.count))
        parkedLocalTabs = document.parkedTabs == nil ? nil : Array(restoredTabs.dropFirst(document.tabs.count).prefix(document.parkedTabs?.count ?? 0))
        herdrAuxiliaryTabs = Array(restoredTabs.dropFirst(document.tabs.count + (document.parkedTabs?.count ?? 0)))
        parkedSelectedTabID = document.parkedSelectedTabID
        selectedTabID = document.selectedTabID ?? tabs.first?.id
        workspacePersistenceActivated = !tabs.isEmpty
        if tabs.isEmpty { createInitialTab() }
        else { rebuildWorkspaceLayout() }
        // Saved backend tabs contribute local additions; startup opens the last selected local workspace.
        if document.herdrWindowBinding != nil {
            for tab in tabs {
                if let local = localAuxiliaries(from: tab) { herdrAuxiliaryTabs.append(local) }
            }
            tabs = parkedLocalTabs ?? []
            selectedTabID = parkedSelectedTabID ?? tabs.first?.id
            parkedLocalTabs = nil; parkedSelectedTabID = nil
            if tabs.isEmpty { createInitialTab() }
            else { rebuildWorkspaceLayout() }
        }
        refreshWorkspacePicker()
    }

    private func replaceRestoredPane(_ id: PaneID, with controller: any PaneControlling) {
        guard let tab = tabState(containing: id), tab.paneControllers[id] is RestoredPanePlaceholderController else { return }
        tab.paneControllers[id] = controller
        if tab.id == selectedTabID { rebuildWorkspaceLayout() }
        else { updateTabStrip() }
        if hasAppeared, tab.id == selectedTabID { controller.startIfNeeded() }
    }

    var debugRestoredPlaceholderCount: Int { tabs.flatMap { $0.paneControllers.values }.filter { $0 is RestoredPanePlaceholderController }.count }
}


extension WorkspaceViewController {
    private func localAuxiliaries(from tab: WorkspaceTabState) -> WorkspaceTabState? {
        let controllers = tab.paneControllers.filter { entry in
            if let terminal = entry.value as? TerminalPaneController { return terminal.herdrBinding == nil }
            if let placeholder = entry.value as? RestoredPanePlaceholderController { return placeholder.savedPane.binding == nil }
            return true
        }
        guard !controllers.isEmpty else { return nil }
        let ids = Set(controllers.keys)
        let local = WorkspaceTabState(id: tab.id, layoutNode: tab.herdrLocalLayout, paneControllers: controllers,
            paneAutoResizeConfigurations: tab.paneAutoResizeConfigurations.filter { ids.contains($0.key) },
            focusedPaneID: tab.focusedPaneID.flatMap { ids.contains($0) ? $0 : nil },
            customTitle: tab.herdrBackendTitle ?? tab.customTitle,
            activeFloatingPaneState: tab.activeFloatingPaneState.flatMap { ids.contains($0.paneID) ? $0 : nil })
        local.herdrTabBinding = tab.herdrTabBinding
        local.herdrBackendTitle = tab.herdrBackendTitle
        local.herdrLocalLayout = tab.herdrLocalLayout
        local.herdrLocalFraction = tab.herdrLocalFraction
        local.detachedPaneIDs = tab.detachedPaneIDs.filter { ids.contains($0) }
        local.activeDetachedPaneID = tab.activeDetachedPaneID.flatMap { ids.contains($0) ? $0 : nil }
        local.floatingPaneSizes = tab.floatingPaneSizes.filter { ids.contains($0.key) }
        return local
    }

    private func recoverAuxiliaries(_ tab: WorkspaceTabState) {
        tab.customTitle = "Local · \((tab.herdrBackendTitle ?? tab.customTitle ?? tab.herdrTabBinding?.tabID ?? "Herdr").prefix(128))"
        tab.herdrTabBinding = nil
        tab.herdrBackendTitle = nil
        tab.herdrLocalLayout = nil
        tab.focusedPaneID = tab.focusedPaneID ?? tab.layoutNode?.firstPaneID ?? tab.detachedPaneIDs.first
        if parkedLocalTabs != nil { parkedLocalTabs?.append(tab) }
        else { tabs.append(tab) }
    }

    func enterHerdrWorkspace(_ workspaceID: String) async throws {
        guard workspaceStore?.canWrite != false else { throw CLIError("Another Santty instance owns workspace saving; ClientShell was not activated") }
        stopHerdrClientShell()
        let generation = herdrShellGeneration
        if let endpoint = herdrClient?.endpoint { herdrClient = HerdrWorkspaceClient(endpoint: endpoint) }
        if herdrWindowWorkspaceID != nil { herdrWindowWorkspaceID = workspaceID }
        do {
            herdrWindowRestoreFailed = false
            try await startHerdrClientShell(workspaceID: workspaceID)
            try Task.checkCancellation()
            guard herdrShellGeneration == generation else { throw CancellationError() }
        } catch {
            guard herdrShellGeneration == generation else { throw CancellationError() }
            stopHerdrClientShell()
            herdrWindowRestoreFailed = true
            herdrLastError = error.localizedDescription
            throw error
        }
    }

    private func requestHerdrLayoutRefresh() {
        if let session = herdrShellSession, let snapshot = session.projection.snapshot,
           let surface = session.projection.coherentSurface {
            queueHerdrShellProjection(snapshot, surface, session.projection.assets)
        }
    }

    @discardableResult
    private func refreshHerdrLayout(workspaceID: String,
                                   shellProjection: (HerdrShellSnapshot, HerdrShellSurface)? = nil,
                                   shellMetadata: HerdrShellSnapshot? = nil) async throws -> Bool {
        guard let client = herdrClient, !herdrWorkspaceClosed else { throw CLIError("Herdr connection closed") }
        let stagesNativePresentation = shellProjection != nil
        let generation = herdrManagementGeneration
        herdrLayoutRevision += 1
        let revision = herdrLayoutRevision
        let workspaces: [HerdrSnapshot.Workspace]?
        let backendTabs: [HerdrSnapshot.Tab]?
        let panes: [HerdrSnapshot.Pane]
        let shell = shellProjection?.0 ?? shellMetadata
        if let shell {
            guard let identity = herdrShellSession?.serviceIdentity,
                  herdrWindowIdentity == nil || identity == herdrWindowIdentity else { return false }
            workspaces = shell.workspaces.map {
                .init(workspace_id: $0.workspace_id, label: $0.label, active_tab_id: $0.active_tab_id)
            }
            backendTabs = shell.tabs.map { .init(tab_id: $0.tab_id, workspace_id: $0.workspace_id, label: $0.label) }
            panes = shell.panes.map {
                .init(pane_id: $0.pane_id, terminal_id: nil, workspace_id: $0.workspace_id, tab_id: $0.tab_id,
                      label: $0.label, cwd: $0.cwd, foreground_cwd: $0.foreground_cwd, serviceIdentity: identity)
            }
        } else {
            let snapshot = try await client.snapshot()
            workspaces = snapshot.workspaces; backendTabs = snapshot.tabs
            panes = snapshot.panes
        }
        if workspaces?.isEmpty == true, parkedLocalTabs != nil, !Task.isCancelled, generation == herdrManagementGeneration {
            if shell != nil { return false }
            selectLocalWorkspace(); return false
        }
        guard let workspaces, workspaces.count <= 64,
              Set(workspaces.map(\.workspace_id)).count == workspaces.count,
              workspaces.allSatisfy({ !$0.workspace_id.isEmpty && $0.workspace_id.utf8.count <= 1024 && $0.label.utf8.count <= 4096 }),
              let workspace = workspaces.first(where: { $0.workspace_id == workspaceID }) ?? workspaces.first,
              let backendTabs, backendTabs.count <= 256 else { throw CLIError("Invalid Herdr workspace snapshot") }
        let targetID = workspace.workspace_id
        let allBackendTabs = backendTabs.filter { $0.workspace_id == targetID }
        let orderedTabs = allBackendTabs.filter { !hiddenHerdrFloatingTabs.contains($0.tab_id) }
        guard Set(orderedTabs.map(\.tab_id)).count == orderedTabs.count, panes.count <= 512,
              Set(panes.map(\.pane_id)).count == panes.count,
              orderedTabs.allSatisfy({ !$0.tab_id.isEmpty && $0.tab_id.utf8.count <= 1024 && $0.label.utf8.count <= 4096 }) else { throw CLIError("Invalid Herdr tabs") }
        var layouts: [String: HerdrLayout] = [:]
        for tab in allBackendTabs {
            let tabPanes = panes.filter { $0.workspace_id == targetID && $0.tab_id == tab.tab_id }
            let layout: HerdrLayout
            if let shell, tabPanes.count == 1, let pane = tabPanes.first {
                layout = .init(workspace_id: targetID, tab_id: tab.tab_id,
                    zoomed: shell.tabs.first(where: { $0.tab_id == tab.tab_id })?.zoomed == true,
                    focused_pane_id: pane.pane_id, root: .pane(pane.pane_id), serviceIdentity: pane.serviceIdentity)
            } else {
                guard let exported = try await client.request("layout.export", params: .init(tab_id: tab.tab_id)).layout else { throw CLIError("Missing Herdr tab layout") }
                layout = exported
            }
            guard layout.workspace_id == targetID, layout.tab_id == tab.tab_id,
                  layout.serviceIdentity == panes.first?.serviceIdentity else { throw CLIError("Missing Herdr tab layout") }
            let ids = layout.root.paneIDs
            guard !ids.isEmpty, ids.count == Set(ids).count, ids.contains(layout.focused_pane_id),
                  tabPanes.allSatisfy({ pane in
                      return pane.serviceIdentity != nil
                          && (herdrWindowIdentity == nil || pane.serviceIdentity == herdrWindowIdentity)
                  })
            else { throw CLIError("Herdr layout or service changed during refresh; reconnect to resync") }
            guard ids.count == tabPanes.count, Set(ids) == Set(tabPanes.map(\.pane_id)) else {
                if shell != nil { return false }
                throw CLIError("Herdr layout changed during refresh; reconnect to resync")
            }
            layouts[tab.tab_id] = layout
        }
        guard !Task.isCancelled, revision == herdrLayoutRevision, generation == herdrManagementGeneration, !herdrWorkspaceClosed,
              shell != nil || herdrWindowWorkspaceID == nil || herdrWindowWorkspaceID == workspaceID else { return false }
        if let shell {
            guard let session = herdrShellSession,
                  session.projection.snapshot?.boot_id == shell.boot_id,
                  session.projection.snapshot?.revision == shell.revision else { return false }
        }
        if let (shell, surface) = shellProjection {
            guard let session = herdrShellSession,
                  shell.boot_id == session.projection.snapshot?.boot_id,
                  shell.revision == session.projection.snapshot?.revision,
                  session.canPresent(surface),
                  targetID == shell.focused_workspace_id,
                  HerdrLayout.matchesShellProjection(layouts: layouts, shell: shell, surface: surface)
            else { return false }
        }
        // Existing controllers are shared; their metadata changes only after preparation succeeds.
        let oldControllers = tabs.flatMap { $0.paneControllers.values.compactMap { $0 as? TerminalPaneController } }
        var projection: [WorkspaceTabState] = []
        var existingTabs: [UUID: WorkspaceTabState] = [:]
        var metadataUpdates: [(TerminalPaneController, HerdrSnapshot.Pane)] = []
        var reused = Set<UUID>()
        for backendTab in orderedTabs {
            let layout = layouts[backendTab.tab_id]!
            let existing = (herdrWindowWorkspaceID == nil ? herdrAuxiliaryTabs : tabs + herdrAuxiliaryTabs).first {
                $0.herdrTabBinding?.endpoint == client.endpoint && $0.herdrTabBinding?.serviceIdentity == (herdrWindowIdentity ?? panes.first?.serviceIdentity)
                    && $0.herdrTabBinding?.workspaceID == targetID && $0.herdrTabBinding?.tabID == backendTab.tab_id
            }
            var controllers: [PaneID: any PaneControlling] = [:]
            var nativeIDs: [String: UUID] = [:]
            var replacementIDs: [PaneID: PaneID] = [:]
            var binding: HerdrPaneBinding?
            for metadata in panes.filter({ $0.tab_id == backendTab.tab_id && $0.workspace_id == targetID }) {
                let identity = try HerdrPaneBinding(endpoint: client.endpoint, pane: metadata)
                let floating = floatingRecord(placeholderID: metadata.pane_id)
                let previous = floating.flatMap { herdrFloatingDisplays[$0.paneID]?.pane } ?? (herdrWindowWorkspaceID == nil ? nil : oldControllers.first { pane in
                    guard let old = pane.herdrBinding, old.endpoint == client.endpoint,
                          old.serviceIdentity == metadata.serviceIdentity else { return false }
                    return old.matches(metadata, requireRuntime: false)
                })
                let controller = previous
                let remembered = herdrFloatingRecords.first {
                    $0.source.endpoint == client.endpoint && $0.placeholder == nil && $0.floating == nil
                        && $0.source.matches(metadata, requireRuntime: false)
                }
                let pane = controller ?? makeTerminalPaneController(id: remembered?.paneID ?? UUID(), workingDirectory: metadata.cwd, herdr: identity)
                if controller == nil, let previous {
                    replacementIDs[previous.id] = pane.id
                    pane.name = previous.name
                }
                if shell == nil { metadataUpdates.append((pane, metadata)) }
                controllers[pane.id] = pane
                nativeIDs[metadata.pane_id] = pane.id
                if controller != nil { reused.insert(pane.id) }
                binding = identity
            }
            let native = try layout.root.nativeLayout(panes: nativeIDs)
            let focusedBackendID: String?
            let zoomed: Bool
            if let shell {
                focusedBackendID = shell.focused_tab_id == backendTab.tab_id ? shell.focused_pane_id
                    : shell.panes.first(where: { $0.tab_id == backendTab.tab_id && $0.focused })?.pane_id
                        ?? layout.root.paneIDs.first
                zoomed = shell.tabs.first(where: { $0.tab_id == backendTab.tab_id })?.zoomed == true
            } else {
                focusedBackendID = layout.focused_pane_id; zoomed = layout.zoomed
            }
            let focusedNativeID = focusedBackendID.flatMap { nativeIDs[$0] }
            let tab = existing?.makeProjectionCandidate() ?? WorkspaceTabState(layoutNode: native, paneControllers: controllers,
                paneAutoResizeConfigurations: [:], focusedPaneID: focusedNativeID)
            if let existing {
                existingTabs[tab.id] = existing
                if existing.id == selectedTabID, herdrFloatingTask == nil { captureFloatingPaneSizes(in: tab) }
            }
            if let auxiliaries = existing.flatMap({ localAuxiliaries(from: $0) }) {
                controllers.merge(auxiliaries.paneControllers) { current, _ in current }
            }
            tab.remapPresentationPaneIDs(replacementIDs)
            tab.herdrBackendLayout = native
            tab.composeHerdrLayout()
            tab.paneControllers = controllers
            for record in herdrFloatingRecords where controllers[record.paneID] != nil && tab.floatingPaneSizes[record.paneID] == nil {
                tab.floatingPaneSizes[record.paneID] = record.size
            }
            if let record = herdrFloatingRecords.first(where: { $0.source.tabID == backendTab.tab_id && floatingRecord(for: $0.paneID) != nil }) {
                tab.activeFloatingPaneState = .init(paneID: record.paneID, size: record.size)
                if let size = record.size { tab.floatingPaneSizes[record.paneID] = size }
            }
            let retainedFocus = tab.focusedPaneID.flatMap { controllers[$0] == nil ? nil : $0 }
            let localFocus = retainedFocus.map { native.path(to: $0) == nil || tab.isPaneDetached($0) || tab.activeFloatingPaneState?.paneID == $0 } == true
            tab.focusedPaneID = localFocus || optimisticHerdrFocus != nil
                ? retainedFocus : focusedNativeID
            if optimisticHerdrFocus == nil { tab.herdrFocusedPaneID = focusedNativeID }
            tab.detachedPaneIDs.removeAll { controllers[$0] == nil }
            if let floating = tab.activeFloatingPaneState, controllers[floating.paneID] == nil { tab.activeFloatingPaneState = nil }
            if let detached = tab.activeDetachedPaneID, controllers[detached] == nil { tab.activeDetachedPaneID = nil }
            tab.paneAutoResizeConfigurations = tab.paneAutoResizeConfigurations.filter { controllers[$0.key] != nil }
            tab.floatingPaneSizes = tab.floatingPaneSizes.filter { controllers[$0.key] != nil }
            tab.customTitle = nil
            tab.herdrBackendTitle = backendTab.label
            tab.herdrTabBinding = binding
            tab.herdrZoomed = zoomed
            projection.append(tab)
        }
        if !stagesNativePresentation, let current = selectedTabState { suspendActiveFloatingPresentation(in: current) }
        projection = projection.map { candidate in
            guard let existing = existingTabs[candidate.id] else { return candidate }
            existing.applyProjectionCandidate(candidate)
            return existing
        }
        herdrShellLayouts = layouts.mapValues(\.root)
        herdrAuxiliaryTabs.removeAll { auxiliary in projection.contains { $0.id == auxiliary.id } }
        if parkedLocalTabs == nil {
            parkedLocalTabs = tabs
            parkedSelectedTabID = selectedTabID
            for pane in oldControllers where pane.herdrBinding != nil { retireHerdrPane(pane) }
        } else {
            let projected = Set(projection.map(\.id))
            for tab in tabs where !projected.contains(tab.id) {
                if let local = localAuxiliaries(from: tab) { herdrAuxiliaryTabs.append(local) }
            }
            herdrAuxiliaryTabs.removeAll { projected.contains($0.id) }
            for pane in oldControllers where !reused.contains(pane.id) { retireHerdrPane(pane) }
        }
        for tab in herdrAuxiliaryTabs where tab.herdrTabBinding?.endpoint == client.endpoint
            && (tab.herdrTabBinding?.serviceIdentity != (herdrWindowIdentity ?? panes.first?.serviceIdentity)
                || !backendTabs.contains(where: { $0.workspace_id == tab.herdrTabBinding?.workspaceID && $0.tab_id == tab.herdrTabBinding?.tabID })) {
            recoverAuxiliaries(tab)
        }
        herdrAuxiliaryTabs.removeAll { $0.herdrTabBinding == nil }
        let previousSelection = selectedTabID
        tabs = projection
        herdrWindowWorkspaceID = targetID
        herdrWindowIdentity = herdrWindowIdentity ?? panes.first?.serviceIdentity
        let editingAuxiliary = optimisticHerdrFocus != nil || projection.contains { tab in
            tab.id == previousSelection && tab.focusedPaneID.map { tab.herdrBackendLayout?.path(to: $0) == nil } == true
        }
        let authoritativeTabID = shell?.tabs.first(where: { $0.workspace_id == targetID && $0.focused })?.tab_id ?? workspace.active_tab_id
        let auxiliaryInActiveTab = optimisticHerdrFocus != nil || editingAuxiliary && (herdrWindowWorkspaceID == nil
            || projection.first(where: { $0.id == previousSelection })?.herdrTabBinding?.tabID == authoritativeTabID)
        selectedTabID = auxiliaryInActiveTab && projection.contains(where: { $0.id == previousSelection })
            ? previousSelection : projection.first(where: { $0.herdrTabBinding?.tabID == authoritativeTabID })?.id ?? projection.first?.id
        for (pane, metadata) in metadataUpdates { pane.applyHerdrSnapshot(metadata) }
        if shell != nil, let cached = herdrLatestQuerySnapshot {
            for candidate in projection {
                for case let pane as TerminalPaneController in candidate.paneControllers.values {
                    guard pane.herdrQueryBinding == nil, let binding = pane.herdrBinding,
                          let metadata = cached.panes.first(where: { binding.matches($0, requireRuntime: false) }) else { continue }
                    pane.applyHerdrSnapshot(metadata)
                }
            }
        }
        workspacePersistenceActivated = true
        if !stagesNativePresentation {
            refreshWorkspacePicker(workspaces)
            rootView.removeFloatingPaneView()
            applyingHerdrLayout = true
            rebuildWorkspaceLayout()
            applyingHerdrLayout = false
        }
        if hasAppeared, let selectedTabState { startPaneControllersIfNeeded(in: selectedTabState) }
        scheduleWorkspaceSave()
        return true
    }

    func selectWorkspace(_ id: String) {
        if id.isEmpty { selectWorkspace(WorkspaceReference(source: .local(localWorkspaceID))); return }
        if let entry = workspaceEntries.first(where: { $0.id == id }) {
            guard entry.isAvailable || entry.reference.id == selectedWorkspaceReference.id else { NSSound.beep(); return }
            selectWorkspace(entry.reference)
        } else if let local = localWorkspaceStates.first(where: { $0.pickerID == id }) {
            selectWorkspace(.init(source: .local(local.id)))
        } else if let endpoint = herdrClient?.endpoint {
            selectWorkspace(.init(source: .herdr(endpoint: endpoint, workspaceID: id)))
        }
    }

    private var selectedWorkspaceReference: WorkspaceReference {
        if let id = herdrWindowWorkspaceID, let endpoint = herdrClient?.endpoint {
            return .init(source: .herdr(endpoint: endpoint, workspaceID: id))
        }
        return .init(source: .local(localWorkspaceID))
    }

    func selectWorkspace(_ reference: WorkspaceReference) {
        guard !herdrWorkspaceClosed, !isClosingNotes else { return }
        if case .local(let id) = reference.source {
            guard !herdrOperationPending || workspaceSelectionTask != nil || herdrShellRecoveryTask != nil || herdrShellReconnectTask != nil else { NSSound.beep(); return }
            workspaceSelectionGeneration += 1; workspaceSelectionTask?.cancel(); workspaceSelectionTask = nil
            restoredWorkspaceSelection = nil
            herdrOperationPending = false
            rootView.toolbarView.workspaceSwitcher.isEnabled = true
            selectLocalWorkspace(id)
            return
        }
        guard !herdrOperationPending else { NSSound.beep(); return }
        guard case .herdr(let endpoint, let workspaceID) = reference.source else { return }
        if reference.id == selectedWorkspaceReference.id, herdrShellSession?.isPresentationReady == true { return }
        restoredWorkspaceSelection = nil
        workspaceSelectionGeneration += 1
        let epoch = workspaceSelectionGeneration
        workspaceSelectionTask?.cancel()
        herdrOperationPending = true
        workspaceSelectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.workspaceSelectionGeneration == epoch {
                    self.workspaceSelectionTask = nil; self.herdrOperationPending = false
                    self.refreshWorkspacePicker(); self.flushHerdrFocus(); self.flushHerdrSplit()
                }
            }
            do {
                if self.herdrClient?.endpoint != endpoint {
                    self.selectLocalWorkspace()
                    self.herdrDiscoveredWorkspaces = []
                    try self.configureHerdrWorkspace(endpoint)
                }
                try Task.checkCancellation()
                guard self.workspaceSelectionGeneration == epoch, let client = self.herdrClient else { throw CancellationError() }
                if self.herdrWindowWorkspaceID == nil || self.herdrShellSession?.isPresentationReady != true {
                    self.herdrWindowIdentity = nil; self.herdrShellRecoveryAttempts = 0
                    try await self.enterHerdrWorkspace(workspaceID)
                } else {
                    guard self.herdrShellSession?.projection.snapshot?.workspaces.contains(where: { $0.workspace_id == workspaceID }) == true else {
                        throw CLIError("The selected Herdr workspace no longer exists")
                    }
                    _ = try await client.request("workspace.focus", params: .init(workspace_id: workspaceID))
                }
            } catch is CancellationError { }
            catch {
                guard self.workspaceSelectionGeneration == epoch else { return }
                self.presentHerdrError(error)
            }
        }
    }

    var debugWorkspaceEntries: [WorkspaceEntry] { workspaceEntries }
    var debugHerdrEndpointStatus: [String: String] {
        herdrCatalog.states.mapValues { "identity=\($0.identity != nil), state=\($0.status.diagnosticName), error=\($0.monitor.session?.failure?.localizedDescription ?? "nil")" }
    }
    var debugSelectedWorkspace: WorkspaceReference { selectedWorkspaceReference }
    func waitForWorkspaceSelection() async { await workspaceSelectionTask?.value }

    private func queueHerdrFocus(_ binding: HerdrPaneBinding) {
        if herdrFloatingTransition, let tab = selectedTabState,
           let id = tab.activeFloatingPaneState?.paneID, let pane = tab.terminalPaneController(for: id),
           pane.herdrBinding?.paneID == binding.paneID, pane.herdrBinding?.endpoint == binding.endpoint {
            return
        }
        if let record = herdrFloatingRecords.first(where: { $0.floating?.paneID == binding.paneID && $0.floating?.tabID == binding.tabID && $0.source.endpoint == binding.endpoint }),
           let display = herdrFloatingDisplays[record.paneID] {
            try? display.session.setFocused(view.window?.isKeyWindow == true)
            return
        }
        optimisticHerdrFocus = binding
        pendingHerdrFocus = binding
        flushHerdrFocus()
    }

    private var hiddenHerdrFloatingTabs: Set<String> {
        Set(herdrFloatingRecords.compactMap { record in
            guard record.source.endpoint == herdrClient?.endpoint,
                  record.source.serviceIdentity == herdrShellSession?.serviceIdentity,
                  record.placeholder != nil, let floating = record.floating,
                  floating.tabID != record.source.tabID, herdrFloatingDisplays[record.paneID] != nil else { return nil }
            return floating.tabID
        })
    }

    private func floatingRecord(for id: PaneID) -> HerdrFloatingPaneRecord? {
        herdrFloatingRecords.first { $0.paneID == id && $0.source.endpoint == herdrClient?.endpoint
            && $0.source.serviceIdentity == herdrShellSession?.serviceIdentity
            && $0.placeholder != nil && $0.floating?.tabID != $0.source.tabID && herdrFloatingDisplays[id] != nil }
    }

    private func floatingRecord(placeholderID: String) -> HerdrFloatingPaneRecord? {
        herdrFloatingRecords.first { $0.placeholder?.paneID == placeholderID && floatingRecord(for: $0.paneID) != nil }
    }

    private func updateHerdrFloatingRecord(_ record: HerdrFloatingPaneRecord) {
        herdrFloatingRecords.removeAll { $0.paneID == record.paneID }
        // Keep the size after returning the pane; workspace switches rebuild its local controller.
        if record.size != nil || record.placeholder != nil || record.floating != nil { herdrFloatingRecords.append(record) }
        scheduleWorkspaceSave()
    }

    private func makeHerdrFloatingDisplay(_ record: HerdrFloatingPaneRecord, session: HerdrClientShellSession? = nil) throws -> HerdrFloatingPaneDisplay {
        let display = try HerdrFloatingPaneDisplay(record: record, session: session, initialViewport: { [weak self] in
            guard let self, let (_, width, height) = self.herdrClientShellViewport(), let surface = self.herdrShellSession?.projection.coherentSurface else { return nil }
            return (.init(cols: surface.frame.width, rows: surface.frame.height), width, height)
        })
        try syncHerdrShellTheme(display.session, dark: view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        display.pane.onFocusRequest = { [weak self] in self?.handlePaneFocusRequest(withID: $0) }
        display.pane.onTitleChange = { [weak self] in self?.handleTitleChange(for: $0) }
        display.pane.onExit = { [weak self] in self?.handlePaneExit(withID: $0) }
        display.session.onEffect = { [weak self, weak display] message in
            guard let self, let display, display.session.isPresentationReady else { return }
            self.handleHerdrShellEffect(message, session: display.session)
        }
        display.onFailure = { [weak self] error in
            guard let self, !self.herdrWorkspaceClosed else { return }
            self.herdrLastError = error.localizedDescription
            self.herdrErrorHandler?(error.localizedDescription)
        }
        herdrFloatingDisplays[record.paneID] = display
        return display
    }

    private func prepareHerdrFloatingDisplays(client: HerdrWorkspaceClient, session: HerdrClientShellSession) async throws {
        let records = herdrFloatingRecords.filter { $0.source.endpoint == client.endpoint && $0.placeholder != nil && $0.floating != nil }
        guard records.contains(where: { herdrFloatingDisplays[$0.paneID] == nil }) else { return }
        let current = try await client.snapshot()
        for record in records where herdrFloatingDisplays[record.paneID] == nil {
            guard record.source.serviceIdentity == session.serviceIdentity,
                  let floating = record.floating, let placeholder = record.placeholder,
                  current.panes.contains(where: { floating.matches($0) }),
                  current.panes.contains(where: { placeholder.matches($0) }), floating.tabID != record.source.tabID else {
                // A changed server exposes its real tabs; it never authorizes deleting a runtime.
                herdrFloatingRecords.removeAll { $0.paneID == record.paneID }
                herdrLastError = "Floating placement changed on Herdr; the terminal remains available in its tab"
                continue
            }
            _ = try makeHerdrFloatingDisplay(record)
        }
    }

    private func resizeHerdrFloatingPane() {
        guard !herdrFloatingTransition, let id = selectedTabState?.activeFloatingPaneState?.paneID else { return }
        herdrFloatingDisplays[id]?.resize()
    }

    private func toggleHerdrFloatingPane(in tab: WorkspaceTabState, animated: Bool = true) {
        guard herdrFloatingTask == nil, !herdrOperationPending, let client = herdrClient,
              let session = herdrShellSession, session.isPresentationReady,
              let id = tab.activeFloatingPaneState?.paneID ?? tab.focusedPaneID,
              let original = tab.terminalPaneController(for: id) else { NSSound.beep(); return }
        let epoch = herdrShellGeneration
        let returning = floatingRecord(for: id) != nil
        let previousFocus = tab.focusedPaneID
        let destination: NSRect
        if returning {
            guard let frame = rootView.placeholderFrame(for: id) else { NSSound.beep(); return }
            destination = frame
            herdrOperationPending = true
            herdrFloatingTransition = true
            herdrFloatingDisplays[id]?.freeze()
            rootView.beginFloatingPaneAnimation()
        } else {
            guard let frame = renderedPaneFrameInFloatingOverlay(for: id, in: tab) else { NSSound.beep(); return }
            herdrOperationPending = true
            herdrFloatingTransition = true
            pendingHerdrFocus = nil; optimisticHerdrFocus = nil
            original.setClientShellPresented(false)
            rootView.setCustomFloatingPaneSize(tab.floatingPaneSizes[id])
            tab.activeFloatingPaneState = .init(paneID: id, size: tab.floatingPaneSizes[id])
            rootView.installFloatingPaneView(original.hostView, initialFrame: frame, animated: animated)
            rebuildWorkspaceLayout(applyAutoZoomAnimated: false, restoreFloatingPresentation: false)
            destination = rootView.floatingPaneTargetFrame()
        }
        herdrFloatingTransition = true
        herdrOperationPending = true
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = WorkspaceFloatingPaneConfiguration.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                rootView.animateFloatingPaneFrame(to: destination)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.herdrShellGeneration == epoch, self.selectedTabID == tab.id else { return }
                    if !returning { self.rootView.finishFloatingPaneAnimation() }
                }
            }
        } else {
            rootView.setFloatingPaneFrame(destination)
            if !returning { rootView.finishFloatingPaneAnimation() }
        }
        herdrFloatingTask = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            defer {
                self.herdrFloatingTransition = false; self.herdrOperationPending = false
                self.herdrFloatingTask = nil; self.requestHerdrLayoutRefresh()
                self.flushHerdrFocus(); self.flushHerdrSplit(); self.scheduleWorkspaceSave()
            }
            var transfer: HerdrFloatingPaneTransfer?
            do {
                if let record = self.floatingRecord(for: id), let display = self.herdrFloatingDisplays[id] {
                    let operation = HerdrFloatingPaneTransfer(record: record, client: client, session: session)
                    transfer = operation
                    operation.onChange = { [weak self] in self?.updateHerdrFloatingRecord($0) }
                    self.herdrFloatingTransition = true
                    display.freeze()
                    try await display.session.deactivateAndWait()
                    try await operation.leave()
                    let focus = tab.focusedPaneID != previousFocus ? tab.focusedPaneID ?? id : id
                    try display.pane.applyHerdrMove(record.source)
                    display.stop(); self.herdrFloatingDisplays.removeValue(forKey: id)
                    tab.activeFloatingPaneState = nil
                    tab.focusedPaneID = focus
                    if focus == id {
                        self.optimisticHerdrFocus = record.source
                        self.pendingHerdrFocus = record.source
                    }
                    self.herdrFloatingTransition = false
                    try session.invalidatePresentation()
                    self.requestHerdrLayoutRefresh()
                    try await self.waitForHerdrShellPresentation(session, epoch: epoch)
                    self.focusPane(withID: focus)
                    self.applyFocusedPaneResponder()
                } else {
                    let child = HerdrClientShellSession(endpoint: client.endpoint)
                    let connecting = Task {
                        try await child.start(size: .init(cols: 1, rows: 1), cellWidth: 0, cellHeight: 0, focused: false, activateWhenMetadataReady: false)
                    }
                    var installed = false
                    defer { connecting.cancel(); if !installed { child.disconnect() } }
                    let source = try await original.resolveHerdrQueryBinding(using: client)
                    guard self.herdrShellGeneration == epoch, self.selectedTabID == tab.id else { throw CancellationError() }
                    let surface = session.projection.coherentSurface
                    let record = HerdrFloatingPaneRecord(paneID: id, source: source, size: tab.floatingPaneSizes[id],
                        sourceViewport: surface.map { .init(cols: $0.frame.width, rows: $0.frame.height) })
                    let operation = HerdrFloatingPaneTransfer(record: record, client: client, session: session)
                    transfer = operation
                    operation.onChange = { [weak self] in self?.updateHerdrFloatingRecord($0) }
                    self.updateHerdrFloatingRecord(record)
                    try await self.flushWorkspaceState()
                    self.herdrFloatingTransition = true
                    for case let pane as TerminalPaneController in tab.paneControllers.values { pane.setClientShellPresented(false) }
                    try await operation.enter()
                    guard self.herdrShellGeneration == epoch, self.selectedTabID == tab.id else { throw CancellationError() }
                    try await connecting.value
                    let display = try self.makeHerdrFloatingDisplay(operation.record, session: child)
                    installed = true
                    display.pane.name = original.name
                    tab.activeFloatingPaneState = .init(paneID: id, size: tab.floatingPaneSizes[id])
                    self.herdrFloatingTransition = false
                    try session.invalidatePresentation()
                    self.requestHerdrLayoutRefresh()
                    try await self.waitForHerdrShellPresentation(session, epoch: epoch)
                    original.disconnectHerdr()
                    self.focusPane(withID: id)
                    self.applyFocusedPaneResponder()
                }
            } catch {
                if let transfer, self.herdrShellGeneration == epoch, session.failure == nil {
                    do { try await transfer.leave() }
                    catch { self.herdrLastError = "Floating transfer needs recovery: \(error.localizedDescription)" }
                }
                if let transfer, transfer.record.placeholder == nil && transfer.record.floating == nil { self.updateHerdrFloatingRecord(transfer.record) }
                self.herdrFloatingDisplays.removeValue(forKey: id)?.stop()
                tab.activeFloatingPaneState = nil
                if self.herdrShellGeneration == epoch, session.failure == nil {
                    self.herdrFloatingTransition = false
                    try? session.invalidatePresentation()
                    self.requestHerdrLayoutRefresh()
                    try? await self.waitForHerdrShellPresentation(session, epoch: epoch)
                }
                if !(error is CancellationError), self.herdrShellGeneration == epoch { self.presentHerdrError(error) }
            }
        }
    }

    func waitForHerdrFloatingTransitionForTesting() async { await herdrFloatingTask?.value }

    private func flushHerdrFocus() {
        if herdrWindowWorkspaceID != nil, herdrShellSession?.isPresentationReady != true { return }
        guard !herdrOperationPending, herdrWindowWorkspaceID != nil, let binding = pendingHerdrFocus else { return }
        pendingHerdrFocus = nil
        runHerdrOperation { client in
            do {
                if self.herdrWindowWorkspaceID != nil, self.herdrShellSession?.isPresentationReady != true {
                    if self.pendingHerdrFocus == nil { self.pendingHerdrFocus = binding }
                    return
                }
                try await client.verify(binding)
                // Focusing a pane also selects its backend tab, including the last locally chosen pane.
                _ = try await client.request("pane.focus", params: .init(pane_id: binding.paneID))
            } catch {
                guard self.pendingHerdrFocus == nil else { return }
                if self.optimisticHerdrFocus == binding { self.optimisticHerdrFocus = nil }
                self.requestHerdrLayoutRefresh()
                throw error
            }
        }
    }

    private func flushHerdrSplit() {
        if herdrWindowWorkspaceID != nil, herdrShellSession?.isPresentationReady != true { return }
        guard !herdrOperationPending, herdrWindowWorkspaceID != nil, !pendingHerdrSplits.isEmpty else { return }
        let pending = pendingHerdrSplits.removeFirst()
        let backendPath = pending.path.map { $0 == .child(1) }
        runHerdrOperation { client in
            do {
                guard self.herdrClient === client else { return }
                if self.herdrWindowWorkspaceID != nil, self.herdrShellSession?.isPresentationReady != true {
                    if !self.pendingHerdrSplits.contains(where: { $0.binding.tabID == pending.binding.tabID && $0.path == pending.path }) {
                        self.pendingHerdrSplits.insert(pending, at: 0)
                    }
                    return
                }
                try await client.verify(pending.binding)
                guard let tab = self.tabs.first(where: { $0.herdrTabBinding?.tabID == pending.binding.tabID }),
                      tab.herdrBackendLayout?.node(at: pending.path)?.paneIDsInTraversalOrder == pending.edit.paneIDs else {
                    throw CLIError("Herdr split changed before resizing")
                }
                _ = try await client.request("layout.set_split_ratio", params: .init(tab_id: pending.binding.tabID,
                    path: backendPath, ratio: Double(pending.edit.fractions[0])))
                if tab.herdrSplitEdits[pending.path]?.id == pending.edit.id {
                    tab.herdrSplitEdits[pending.path]?.acknowledged = true
                }
            } catch {
                if let tab = self.tabs.first(where: { $0.herdrTabBinding?.tabID == pending.binding.tabID }),
                   tab.herdrSplitEdits[pending.path]?.id == pending.edit.id {
                    tab.herdrSplitEdits.removeValue(forKey: pending.path)
                    tab.composeHerdrLayout()
                    if tab.id == self.selectedTabID { self.rebuildWorkspaceLayout() }
                }
                throw error
            }
        }
    }

    private func mutateHerdrLayout(_ method: String, binding: HerdrPaneBinding, params: HerdrConnection.Request.Params) {
        runHerdrOperation { client in
            try await client.verify(binding)
            _ = try await client.request(method, params: params)
        }
    }

    func selectLocalWorkspace() {
        herdrShellReconnectTask?.cancel(); herdrShellReconnectTask = nil
        herdrShellRecoveryTask?.cancel()
        herdrShellRecoveryAttempts = 0; herdrShellConnectedAt = nil
        stopHerdrClientShell()
        guard let localTabs = parkedLocalTabs else { return }
        herdrLayoutRevision += 1
        for tab in tabs { for case let pane as TerminalPaneController in tab.paneControllers.values { retireHerdrPane(pane) } }
        herdrAuxiliaryTabs += tabs.compactMap { localAuxiliaries(from: $0) }
        tabs = parkedLocalTabs ?? localTabs
        selectedTabID = parkedSelectedTabID
        parkedLocalTabs = nil
        parkedSelectedTabID = nil
        herdrWindowWorkspaceID = nil
        pendingHerdrSplits.removeAll()
        pendingHerdrFocus = nil
        herdrWindowIdentity = nil
        herdrWindowRestoreFailed = false
        if !herdrWorkspaceClosed {
            for tab in tabs {
                let replacements = tab.paneControllers.compactMap { id, pane -> (PaneID, String?, String?)? in
                    let cwd: String?
                    if let placeholder = pane as? RestoredPanePlaceholderController {
                        cwd = placeholder.savedPane.cwd
                    } else if let terminal = pane as? TerminalPaneController, terminal.herdrBinding != nil {
                        cwd = terminal.currentWorkingDirectory
                        terminal.disconnectHerdr()
                    } else { return nil }
                    return (id, cwd, pane.name)
                }
                for (id, _, _) in replacements { tab.paneControllers.removeValue(forKey: id) }
                for (id, cwd, name) in replacements {
                    var isDirectory: ObjCBool = false
                    let localCwd = cwd.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue ? $0 : nil }
                    let local = makeTerminalPaneController(id: id, workingDirectory: localCwd)
                    local.name = name
                    tab.paneControllers[id] = local
                }
                tab.herdrTabBinding = nil
                tab.herdrBackendLayout = nil; tab.herdrLocalLayout = nil
                tab.herdrBackendTitle = nil; tab.herdrFocusedPaneID = nil; tab.herdrZoomed = false
            }
            if tabs.isEmpty { createInitialTab() }
            if !tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = tabs.first?.id }
        }
        refreshWorkspacePicker()
        rebuildWorkspaceLayout()
        if !herdrWorkspaceClosed, hasAppeared, let selectedTabState { startPaneControllersIfNeeded(in: selectedTabState) }
        scheduleWorkspaceSave()
    }

    private func stopHerdrClientShell() {
        let floating = herdrFloatingDisplays.values.filter { $0.session.state != .disconnected }
        for display in floating { display.freeze() }
        let wasShell = herdrShellSession != nil || herdrWindowWorkspaceID != nil
        herdrShellGeneration += 1
        herdrShellProjectionTask?.cancel(); herdrShellProjectionTask = nil
        herdrShellResizeTask?.cancel(); herdrShellResizeTask = nil
        retireHerdrShellHostColorQuery()
        herdrShellPendingProjection = nil; herdrShellPresentedSnapshot = nil; herdrShellLayouts.removeAll()
        herdrShellViewportCalibration = nil
        herdrShellStagingTab = nil
        rootView.cancelStagedContentView()
        rootView.cancelStagedFloatingPaneView(); herdrShellRetainedPresentation.removeAll()
        herdrShellNativeLayoutPending = false
        pendingHerdrFocus = nil; optimisticHerdrFocus = nil; pendingHerdrSplits.removeAll()
        for tab in tabs + herdrAuxiliaryTabs {
            tab.herdrSplitEdits.removeAll()
            tab.composeHerdrLayout()
        }
        herdrClient?.retireCommands()
        let session = herdrShellSession
        let callbacks = borrowedHerdrCallbacks
        if let session, let callbacks {
            session.onProjection = nil; session.onEffect = nil
            session.onState = callbacks.state; session.onFailure = callbacks.failure
        } else { session?.onProjection = nil; session?.onFailure = nil; session?.onEffect = nil; session?.onState = nil }
        if floating.isEmpty {
            if callbacks != nil { do { try session?.deactivate() } catch { session?.disconnect() } }
            else { session?.disconnect() }
        } else {
            let previous = herdrFloatingShutdownTask
            // Keep the source client active until floating clients release geometry ownership.
            herdrFloatingShutdownTask = Task {
                await previous?.value
                for display in floating { try? await display.session.deactivateAndWait(); display.stop() }
                if callbacks != nil { do { try session?.deactivate() } catch { session?.disconnect() } }
                else { session?.disconnect() }
            }
        }
        borrowedHerdrCallbacks = nil; herdrShellSession = nil
        herdrShellPopup?.setPresented(false)
        rootView.removeHerdrPopupView(); herdrShellPopup = nil
        if wasShell {
            for tab in tabs + herdrAuxiliaryTabs {
                for case let pane as TerminalPaneController in tab.paneControllers.values where pane.herdrBinding != nil {
                    pane.disconnectHerdr()
                }
            }
        }
        // An old mutation must retain its disconnected route rather than fall back to the API.
        if wasShell, let endpoint = herdrClient?.endpoint { herdrClient = HerdrWorkspaceClient(endpoint: endpoint) }
    }


    private func startHerdrClientShell(workspaceID: String) async throws {
        await herdrFloatingShutdownTask?.value
        herdrFloatingShutdownTask = nil
        try Task.checkCancellation()
        guard let client = herdrClient else { throw CLIError("Herdr endpoint is unavailable") }
        let epoch = herdrShellGeneration
        guard herdrShellGeneration == epoch, herdrClient === client, !herdrWorkspaceClosed else { throw CancellationError() }
        let borrowed = herdrCatalog.states[client.endpoint.id]?.monitor.session
        let session = borrowed ?? HerdrClientShellSession(endpoint: client.endpoint)
        let callbacks = borrowed.map { ($0.onState, $0.onFailure) }
        borrowedHerdrCallbacks = callbacks.map { (state: $0.0, failure: $0.1) }
        herdrShellSession = session
        session.onState = { [weak self] state in
            callbacks?.0?(state)
            guard let self, self.herdrShellGeneration == epoch else { return }
            self.herdrShellPopup?.applyState(state)
            for tab in self.tabs {
                for case let pane as TerminalPaneController in tab.paneControllers.values where pane.herdrBinding != nil {
                    if self.floatingRecord(for: pane.id) != nil { continue }
                    pane.applyClientShellState(state)
                }
            }
            if case .failed(let message) = state { self.herdrLastError = message }
            if state == .interactive { self.flushHerdrFocus(); self.flushHerdrSplit() }
        }
        session.onProjection = { [weak self] snapshot, surface, assets in
            guard let self, self.herdrShellGeneration == epoch else { return }
            self.queueHerdrShellProjection(snapshot, surface, assets)
        }
        session.onFailure = { [weak self] error, recoverable in
            callbacks?.1?(error, recoverable)
            guard let self, self.herdrShellGeneration == epoch else { return }
            if recoverable { self.scheduleHerdrShellRecovery(epoch: epoch) }
            else { self.presentHerdrError(error) }
        }
        session.onEffect = { [weak self, weak session] message in
            guard let self, let session, self.herdrShellGeneration == epoch, self.herdrShellSession === session else { return }
            if case let .failure(detail) = message { self.presentHerdrError(CLIError(detail)); return }
            guard session.isPresentationReady else { return }
            self.handleHerdrShellEffect(message, session: session)
        }
        try syncHerdrShellTheme(session, dark: view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        // The inactive hello uses unknown cell pixels; only the measured viewport is activated.
        if borrowed == nil {
            try await session.start(size: .init(cols: 80, rows: 24), cellWidth: 0, cellHeight: 0,
                focused: view.window?.isKeyWindow == true, activateWhenMetadataReady: false)
        }
        try session.setFocused(view.window?.isKeyWindow == true)
        for _ in 0..<(client.endpoint.machine == nil ? 500 : 2000) {
            try Task.checkCancellation()
            guard herdrShellGeneration == epoch, herdrShellSession === session, !herdrWorkspaceClosed else { throw CancellationError() }
            if let failure = session.failure { throw failure }
            if session.projection.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard herdrWindowIdentity == nil || session.serviceIdentity == herdrWindowIdentity else {
            throw CLIError("Herdr service changed before native window preparation")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var viewport: (HerdrShellSize, UInt32, UInt32)?
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard herdrShellGeneration == epoch, herdrShellSession === session, !herdrWorkspaceClosed else { throw CancellationError() }
            if let failure = session.failure { throw failure }
            guard let metadata = session.projection.snapshot else { throw CLIError("Herdr shell initial metadata timed out") }
            try client.establishQueryIdentity(session)
            try await prepareHerdrFloatingDisplays(client: client, session: session)
            if try await refreshHerdrLayout(workspaceID: workspaceID, shellMetadata: metadata) {
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try Task.checkCancellation()
                    guard herdrShellGeneration == epoch, herdrShellSession === session, !herdrWorkspaceClosed else { throw CancellationError() }
                    if let failure = session.failure { throw failure }
                    guard session.projection.snapshot == metadata else { break }
                    view.layoutSubtreeIfNeeded()
                    if let value = herdrClientShellViewport() { viewport = value; break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                if viewport != nil { break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let (size, width, height) = viewport else { throw CLIError("Herdr metadata and native viewport did not become ready") }
        try Task.checkCancellation()
        guard herdrShellGeneration == epoch, herdrShellSession === session else { throw CancellationError() }
        let sourceSize = herdrFloatingRecords.first { $0.source.endpoint == client.endpoint
            && $0.source.serviceIdentity == session.serviceIdentity && $0.source.tabID == selectedTabState?.herdrTabBinding?.tabID
            && $0.placeholder != nil && $0.floating != nil }?.sourceViewport ?? size
        try session.activate(size: sourceSize, cellWidth: width, cellHeight: height)
        if let tabID = session.projection.snapshot?.focused_tab_id, hiddenHerdrFloatingTabs.contains(tabID),
           let record = herdrFloatingRecords.first(where: { $0.floating?.tabID == tabID }) {
            try await session.selectInitialTab(record.source.tabID)
        }
        try await waitForHerdrShellPresentation(session, epoch: epoch)
        if session.projection.snapshot?.focused_workspace_id != workspaceID {
            _ = try await client.request("workspace.focus", params: .init(workspace_id: workspaceID))
            try await waitForHerdrShellPresentation(session, epoch: epoch)
        }
        herdrShellConnectedAt = ProcessInfo.processInfo.systemUptime
    }

    private func waitForHerdrShellPresentation(_ session: HerdrClientShellSession, epoch: Int) async throws {
        for _ in 0..<600 {
            try Task.checkCancellation()
            guard herdrShellGeneration == epoch, herdrShellSession === session, !herdrWorkspaceClosed else { throw CancellationError() }
            if case .failed(let message) = session.state { throw session.failure ?? CLIError(message) }
            if session.state == .disconnected { throw CLIError(herdrLastError ?? "Herdr shell disconnected") }
            if session.state == .interactive, session.isPresentationReady { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CLIError("Herdr native window did not become ready")
    }

    private func scheduleHerdrShellRecovery(epoch: Int) {
        if herdrClient?.endpoint.machine != nil { scheduleRemoteHerdrRecovery(epoch: epoch); return }
        guard herdrShellRecoveryTask == nil, let workspaceID = herdrWindowWorkspaceID,
              let identity = herdrWindowIdentity, herdrWindowWorkspaceID != nil, !herdrWorkspaceClosed else { return }
        if let connected = herdrShellConnectedAt, ProcessInfo.processInfo.systemUptime - connected >= 30 { herdrShellRecoveryAttempts = 0 }
        guard herdrShellRecoveryAttempts < 3 else { return }
        herdrShellRecoveryTask = Task { [weak self] in
            guard let self else { return }
            var ownsOperation = false
            defer {
                self.herdrShellRecoveryTask = nil
                if ownsOperation {
                    self.herdrOperationPending = false
                    self.rootView.toolbarView.workspaceSwitcher.isEnabled = true
                    self.flushHerdrFocus(); self.flushHerdrSplit()
                }
            }
            do {
                for _ in 0..<500 where self.herdrOperationPending {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard !self.herdrOperationPending, self.herdrShellGeneration == epoch else { return }
                self.herdrOperationPending = true; ownsOperation = true
                self.rootView.toolbarView.workspaceSwitcher.isEnabled = false
                for delay in [1, 2, 4].dropFirst(self.herdrShellRecoveryAttempts) {
                    self.herdrShellRecoveryAttempts += 1
                    try await Task.sleep(for: .seconds(delay))
                    guard !self.herdrWorkspaceClosed, self.herdrWindowWorkspaceID == workspaceID,
                          self.herdrWindowIdentity == identity, self.herdrWindowWorkspaceID != nil else { return }
                    for tab in self.tabs {
                        for case let pane as TerminalPaneController in tab.paneControllers.values where pane.herdrBinding != nil {
                            pane.applyClientShellState(.reconnecting)
                        }
                    }
                    do {
                        try await self.enterHerdrWorkspace(workspaceID)
                        return
                    } catch is CancellationError { return }
                    catch {
                        self.herdrLastError = error.localizedDescription
                        if !(error is HerdrShellConnectionLost), (error as? CLIConnectionError)?.isRecoverable != true { return }
                    }
                }
            } catch { }
        }
    }

    private func scheduleRemoteHerdrRecovery(epoch: Int) {
        guard herdrShellRecoveryTask == nil, let endpoint = herdrClient?.endpoint,
              let workspaceID = herdrWindowWorkspaceID, !herdrWorkspaceClosed else { return }
        if let since = herdrShellConnectedAt, ProcessInfo.processInfo.systemUptime - since >= 60 { herdrShellRecoveryAttempts = 0 }
        let selection = workspaceSelectionGeneration
        herdrShellRecoveryTask = Task { [weak self] in
            guard let self else { return }
            var ownsOperation = false
            defer {
                self.herdrShellRecoveryTask = nil
                if ownsOperation, self.workspaceSelectionGeneration == selection {
                    self.herdrOperationPending = false
                    self.refreshWorkspacePicker(); self.flushHerdrFocus(); self.flushHerdrSplit()
                }
            }
            do {
                while self.herdrOperationPending { try await Task.sleep(for: .milliseconds(20)) }
                guard self.herdrShellGeneration == epoch else { return }
                self.herdrOperationPending = true; ownsOperation = true
                while !Task.isCancelled {
                    let delay = min(120.0, pow(2, Double(min(self.herdrShellRecoveryAttempts, 7))))
                    self.herdrShellRecoveryAttempts += 1
                    try await Task.sleep(for: .seconds(delay))
                    guard !self.herdrWorkspaceClosed, self.workspaceSelectionGeneration == selection,
                          self.herdrClient?.endpoint == endpoint, self.herdrWindowWorkspaceID == workspaceID else { return }
                    self.herdrWindowIdentity = nil
                    do { try await self.enterHerdrWorkspace(workspaceID); return }
                    catch is CancellationError { return }
                    catch {
                        self.herdrLastError = error.localizedDescription
                        if (error as? HerdrSSHFailure)?.needsAttention == true { self.presentHerdrError(error); return }
                    }
                }
            } catch { }
        }
    }

    private func handleHerdrShellEffect(_ message: HerdrShellServerMessage, session: HerdrClientShellSession) {
        func remoteHasKeyboardFocus() -> Bool {
            let owner = herdrShellPopup == nil
                ? focusedTerminalPaneController.flatMap { herdrFloatingDisplays[$0.id]?.session } ?? herdrShellSession
                : herdrShellSession
            guard owner === session else { return false }
            let target: NSView?
            if let popup = herdrShellPopup { target = popup.canAcceptInput ? popup.terminalView : nil }
            else { target = focusedTerminalPaneController?.herdrBinding != nil && focusedTerminalPaneController?.canAcceptInput == true ? focusedTerminalPaneController?.focusTargetView : nil }
            guard let target, let window = target.window else { return false }
            return window.isKeyWindow && window.firstResponder === target
        }
        func bell() {
            let now = ProcessInfo.processInfo.systemUptime
            guard remoteHasKeyboardFocus(), now - lastHerdrBellAt >= 0.2 else { return }
            lastHerdrBellAt = now; NSSound.beep()
        }
        func notification(title: String, body: String?, sound: Bool, target: String?) {
            guard workspaceStore?.canWrite != false, let boot = session.projection.snapshot?.boot_id else { return }
            let identity = "\(session.serviceIdentity?.pid ?? 0):\(boot):\(target ?? "workspace")"
            AgentNotifier.shared.notifyTerminal(title: title, body: body, sound: sound, identity: identity)
        }
        switch message {
        case .clipboard(let text):
            guard remoteHasKeyboardFocus() else { return }
            // Use the resolved Ghostty policy with the host event's bridge generation.
            do {
                if let popup = herdrShellPopup { try popup.receiveClipboard(text) }
                else { try focusedTerminalPaneController?.receiveClientShellClipboard(text) }
            } catch { herdrLastError = error.localizedDescription }
        case .bell(let count): if count > 0 { bell() }
        case .notify(let kind, let title, let body):
            if kind == 0 { bell() }
            else { notification(title: title, body: body, sound: false, target: nil) }
        default: break
        }
    }

    private func sameHerdrViewportTopology(_ a: LayoutNode, _ b: LayoutNode) -> Bool {
        switch (a, b) {
        case let (.panel(a), .panel(b)): return a == b
        case let (.split(axisA, childrenA, _), .split(axisB, childrenB, _)):
            return axisA == axisB && childrenA.count == childrenB.count
                && zip(childrenA, childrenB).allSatisfy { sameHerdrViewportTopology($0.0, $0.1) }
        default: return false
        }
    }

    private func herdrClientShellViewport(surface: HerdrShellSurface? = nil) -> (HerdrShellSize, UInt32, UInt32)? {
        guard let tab = herdrShellStagingTab ?? selectedTabState, let layout = tab.herdrBackendLayout,
              let pane = layout.paneIDsInTraversalOrder.compactMap({ tab.terminalPaneController(for: $0) }).first,
              let grid = pane.clientShellGridMetrics, grid.cellWidthPixels > 0, grid.cellHeightPixels > 0 else { return nil }
        let scale = pane.clientShellBackingScale
        guard scale.width > 0, scale.height > 0 else { return nil }
        var frame = NSRect.null
        for id in layout.paneIDsInTraversalOrder {
            if let pane = tab.terminalPaneController(for: id),
               let rect = rootView.backendPaneFrame(id, host: pane.clientShellRenderHostView) { frame = frame.union(rect) }
        }
        guard !frame.isNull, frame.width > 0, frame.height > 0 else { return nil }
        let cellSize = CGSize(width: CGFloat(grid.cellWidthPixels) / scale.width,
                              height: CGFloat(grid.cellHeightPixels) / scale.height)
        if let tabID = tab.herdrTabBinding?.tabID,
           herdrShellSession?.projection.snapshot?.focused_tab_id == tabID,
           let surface = surface ?? herdrShellSession?.projection.coherentSurface,
           let tree = try? herdrShellLayouts[tabID]?.projected(on: surface) {
            let paneIDs = Dictionary(uniqueKeysWithValues: tab.paneControllers.values.compactMap { controller -> (String, UUID)? in
                guard let pane = controller as? TerminalPaneController, let binding = pane.herdrBinding else { return nil }
                return (floatingRecord(for: pane.id)?.placeholder?.paneID ?? binding.paneID, pane.id)
            })
            guard let geometry = try? tree.nativeShellLayout(panes: paneIDs, surface: surface, cellSize: cellSize,
                padding: TerminalSettings.padding, divider: WorkspaceLayoutMetrics.dividerThickness) else { return nil }
            if let cached = herdrShellViewportCalibration, cached.tab == tab.id, sameHerdrViewportTopology(cached.layout, layout),
               cached.available == frame.size, cached.cell == cellSize, cached.padding == TerminalSettings.padding,
               cached.divider == AppAppearanceSettings.workspaceDividerThickness {
                return (cached.size, grid.cellWidthPixels, grid.cellHeightPixels)
            }
            guard let size = HerdrLayout.nativeShellViewportSize(surface: surface, nativeSize: geometry.size,
                availableSize: frame.size, cellSize: cellSize) else { return nil }
            // Content chrome can change without changing the physical viewport or split topology.
            herdrShellViewportCalibration = (tab.id, layout, frame.size, cellSize, TerminalSettings.padding,
                AppAppearanceSettings.workspaceDividerThickness, size)
            return (size, grid.cellWidthPixels, grid.cellHeightPixels)
        }
        func chrome(_ node: LayoutNode) -> NSSize {
            switch node {
            case .panel: return NSSize(width: TerminalSettings.padding * 2, height: TerminalSettings.padding * 2)
            case .split(let axis, let children, _):
                let sizes = children.map(chrome)
                let dividers = CGFloat(max(0, children.count - 1)) * WorkspaceLayoutMetrics.dividerThickness
                return axis == .horizontal
                    ? NSSize(width: sizes.reduce(0) { $0 + $1.width } + dividers, height: sizes.map(\.height).max() ?? 0)
                    : NSSize(width: sizes.map(\.width).max() ?? 0, height: sizes.reduce(0) { $0 + $1.height } + dividers)
            }
        }
        let extra = chrome(layout)
        let columns = floor((frame.width - extra.width) * scale.width / CGFloat(grid.cellWidthPixels))
        let rows = floor((frame.height - extra.height) * scale.height / CGFloat(grid.cellHeightPixels))
        guard columns.isFinite, rows.isFinite, columns >= 1, rows >= 1 else { return nil }
        return (.init(cols: UInt16(min(columns, CGFloat(UInt16.max))), rows: UInt16(min(rows, CGFloat(UInt16.max)))),
                grid.cellWidthPixels, grid.cellHeightPixels)
    }

    private func scheduleHerdrShellResize() {
        guard herdrWindowWorkspaceID != nil, herdrShellSession != nil, herdrShellResizeTask == nil,
              herdrFloatingTask == nil, !herdrFloatingTransition, tilingView?.isDraggingDivider != true else { return }
        let epoch = herdrShellGeneration
        herdrShellResizeTask = Task { [weak self] in
            await Task.yield()
            guard let self, self.herdrShellGeneration == epoch, !Task.isCancelled else { return }
            defer { self.herdrShellResizeTask = nil }
            guard self.tilingView?.isDraggingDivider != true, self.herdrFloatingTask == nil, !self.herdrFloatingTransition else { return }
            guard let session = self.herdrShellSession, session.isPresentationReady,
                  let (size, width, height) = self.herdrClientShellViewport() else { return }
            do { try session.resize(size, cellWidth: width, cellHeight: height) }
            catch { self.herdrLastError = error.localizedDescription }
        }
    }

    private func queueHerdrShellProjection(_ snapshot: HerdrShellSnapshot, _ surface: HerdrShellSurface,
                                          _ assets: [HerdrShellAssetKey: Data]) {
        guard herdrShellSession != nil, !herdrWindowRestoreFailed else { return }
        herdrShellPendingProjection = (snapshot, surface, assets)
        guard herdrShellProjectionTask == nil else { return }
        let epoch = herdrShellGeneration
        herdrShellProjectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.herdrShellGeneration == epoch { self.herdrShellProjectionTask = nil } }
            do {
                while let (snapshot, surface, assets) = self.herdrShellPendingProjection {
                    self.herdrShellPendingProjection = nil
                    var committedOrSuperseded = false
                    for _ in 0..<100 {
                        try Task.checkCancellation()
                        guard self.herdrShellGeneration == epoch else { return }
                        if try await self.applyHerdrShellProjection(snapshot, surface, assets) { committedOrSuperseded = true; break }
                        if self.herdrShellPendingProjection != nil { committedOrSuperseded = true; break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    guard committedOrSuperseded else { throw CLIError("Herdr scene and native presentation did not synchronize") }
                }
            } catch is CancellationError { }
            catch {
                guard self.herdrShellGeneration == epoch else { return }
                self.herdrLastError = error.localizedDescription; self.herdrWindowRestoreFailed = true
                self.herdrShellSession?.disconnect()
            }
        }
    }

    private func applyHerdrShellProjection(_ snapshot: HerdrShellSnapshot, _ surface: HerdrShellSurface,
                                           _ assets: [HerdrShellAssetKey: Data]) async throws -> Bool {
        // Transfers keep the visible scene; the latest frame is queued explicitly after completion.
        if herdrFloatingTransition { return true }
        guard let session = herdrShellSession, let client = herdrClient,
              snapshot.boot_id == session.projection.snapshot?.boot_id,
              session.canPresent(surface) else { return true }
        guard session.beginPresentation(surface) else { return true }
        let stagingGeneration = herdrShellGeneration
        let previousTab = tabs.first { $0.herdrTabBinding?.tabID == herdrShellPresentedSnapshot?.focused_tab_id } ?? selectedTabState
        let previousPanes = Array(previousTab?.paneControllers.values ?? [:].values)
        defer { session.endPresentation(surface) }
        guard let workspace = snapshot.focused_workspace_id, let tabID = snapshot.focused_tab_id else { throw CLIError("Herdr shell has no existing workspace") }
        if hiddenHerdrFloatingTabs.contains(tabID) { return true }
        let ordered = snapshot.tabs.filter { $0.workspace_id == workspace && !hiddenHerdrFloatingTabs.contains($0.tab_id) }.map(\.tab_id)
        let native = tabs.compactMap { $0.herdrTabBinding?.tabID }
        let identityMatches = ordered == native && herdrWindowWorkspaceID == workspace && ordered.allSatisfy { id in
            Set(herdrShellLayouts[id]?.paneIDs ?? []) == Set(snapshot.panes.filter { $0.tab_id == id }.map(\.pane_id))
        }
        var topologyChanged = !identityMatches
        if !identityMatches {
            if herdrShellRetainedPresentation.isEmpty { herdrShellRetainedPresentation = previousPanes }
            guard try await refreshHerdrLayout(workspaceID: workspace, shellProjection: (snapshot, surface)) else { return false }
            guard session.canPresent(surface) else { return true }
        }
        guard let tab = tabs.first(where: { $0.herdrTabBinding?.tabID == tabID }), var tree = herdrShellLayouts[tabID] else {
            throw CLIError("Herdr shell topology is unavailable")
        }
        do { tree = try tree.projected(on: surface) }
        catch {
            topologyChanged = true
            if herdrShellRetainedPresentation.isEmpty { herdrShellRetainedPresentation = previousPanes }
            guard try await refreshHerdrLayout(workspaceID: workspace, shellProjection: (snapshot, surface)) else { return false }
            guard session.canPresent(surface) else { return true }
            guard let fresh = herdrShellLayouts[tabID] else { throw CLIError("Herdr shell layout disappeared") }
            tree = try fresh.projected(on: surface)
        }
        var paneIDs: [String: PaneID] = [:]
        for case let pane as TerminalPaneController in tab.paneControllers.values {
            if let record = floatingRecord(for: pane.id), let placeholder = record.placeholder {
                paneIDs[placeholder.paneID] = pane.id
            } else if let binding = pane.herdrBinding { paneIDs[binding.paneID] = pane.id }
        }
        let references = (Array(tab.paneControllers.values) + previousPanes + herdrShellRetainedPresentation)
            .compactMap { $0 as? TerminalPaneController }
        guard let reference = references.first(where: { $0.herdrBinding != nil && $0.clientShellGridMetrics != nil }),
              let metrics = reference.clientShellGridMetrics else { return false }
        let scale = reference.clientShellBackingScale
        let cell = CGSize(width: CGFloat(metrics.cellWidthPixels) / scale.width, height: CGFloat(metrics.cellHeightPixels) / scale.height)
        let projected = try tree.nativeShellLayout(panes: paneIDs, surface: surface, cellSize: cell,
            padding: TerminalSettings.padding, divider: WorkspaceLayoutMetrics.dividerThickness).layout
        let confirmed = try tree.nativeLayout(panes: paneIDs)
        let previousEditCount = tab.herdrSplitEdits.count
        for (path, edit) in tab.herdrSplitEdits {
            guard let node = confirmed.node(at: path), node.paneIDsInTraversalOrder == edit.paneIDs,
                  case let .split(axis, _, fractions) = node else {
                tab.herdrSplitEdits.removeValue(forKey: path)
                continue
            }
            let ids = Set(edit.paneIDs.compactMap { floatingRecord(for: $0)?.placeholder?.paneID ?? tab.terminalPaneController(for: $0)?.herdrBinding?.paneID })
            let rectangles = surface.panes.filter { ids.contains($0.pane_id) }.map(\.rect)
            let start = rectangles.map { axis == .horizontal ? Int($0.x) : Int($0.y) }.min() ?? 0
            let end = rectangles.map { axis == .horizontal ? Int($0.x) + Int($0.width) : Int($0.y) + Int($0.height) }.max() ?? 0
            // Herdr rounds divider positions to whole terminal cells.
            if edit.acknowledged, end > start, abs(fractions[0] - edit.fractions[0]) <= 1 / CGFloat(end - start) {
                tab.herdrSplitEdits.removeValue(forKey: path)
            }
        }
        let keepLocalFocus = selectedTabID == tab.id
            && (optimisticHerdrFocus.map { $0.tabID != snapshot.focused_tab_id || $0.paneID != snapshot.focused_pane_id } == true
                || tab.focusedPaneController.map { ($0 as? TerminalPaneController)?.herdrBinding == nil } == true
                || tab.activeFloatingPaneState?.paneID == tab.focusedPaneID)
        let focused = snapshot.focused_pane_id.flatMap { paneIDs[$0] }
        let changed = herdrShellNativeLayoutPending || topologyChanged || previousEditCount != tab.herdrSplitEdits.count
            || tab.herdrBackendLayout != projected || selectedTabID != tab.id || previousTab?.id != tab.id
        let chromeChanged = changed || herdrShellPresentedSnapshot != snapshot
            || herdrShellPopup?.terminalID != surface.popup?.terminal_id
        if changed { herdrShellNativeLayoutPending = true }
        tab.herdrBackendLayout = projected; tab.composeHerdrLayout()
        tab.herdrZoomed = snapshot.tabs.first(where: { $0.tab_id == tabID })?.zoomed == true
        let canStageTab = changed
        var candidateViews: [PaneID: NSView] = [:]
        var stagedPanes: [TerminalPaneController] = []
        if canStageTab {
            candidateViews = buildPaneViewsDictionary(for: tab)
            for (id, host) in candidateViews where host.window != nil {
                if let pane = tab.terminalPaneController(for: id), pane.herdrBinding != nil {
                    let native = surface.panes.first { paneIDs[$0.pane_id] == id }
                    let grid = pane.clientShellGridMetrics
                    if previousTab?.id == tab.id, herdrShellPresentedSnapshot?.boot_id == snapshot.boot_id,
                       previousPanes.contains(where: { $0 === pane }),
                       let native, let grid, grid.columns == native.inner_rect.width, grid.rows == native.inner_rect.height {
                        // Keep the visible surface in place until its placeholder is replaced at commit.
                        candidateViews[id] = TerminalPanePlaceholderView(paneID: id)
                    } else {
                        candidateViews[id] = pane.stageClientShellDisplay()
                        stagedPanes.append(pane)
                    }
                } else {
                    candidateViews[id] = TerminalPanePlaceholderView(paneID: id)
                }
            }
        }
        var stagedTiling: WorkspaceTilingView?
        var stagedPopup: HerdrClientShellPopupController?
        var stagedFloating: NSView?
        if canStageTab, let node = tab.renderedLayout ?? tab.layoutNode {
            for case let pane as TerminalPaneController in tab.paneControllers.values where pane.hostView.window == nil {
                pane.setClientShellPresented(false)
            }
            let candidate = WorkspaceTilingView(dividerThickness: AppAppearanceSettings.workspaceDividerThickness)
            candidate.commitsDividerChangesOnMouseUp = true
            candidate.onFractionsChange = { [weak self] path, fractions, source in
                self?.updateSplitFractions(at: path, to: fractions, changeSource: source)
            }
            candidate.setLayoutNode(node, paneViews: candidateViews)
            rootView.stageContentView(candidate)
            stagedTiling = candidate
            herdrShellStagingTab = tab
            let floatingID = tab.activeFloatingPaneState?.paneID ?? tab.activeDetachedPaneID
            if let id = floatingID, let pane = tab.terminalPaneController(for: id), pane.herdrBinding != nil {
                if let display = herdrFloatingDisplays[id], floatingRecord(for: id) != nil {
                    display.pane.setClientShellPresented(false)
                    let host: NSView
                    if display.pane.hostView.window != nil {
                        host = display.pane.stageClientShellDisplay(); stagedPanes.append(display.pane)
                    } else { host = display.pane.hostView }
                    rootView.stageFloatingPaneView(host, size: tab.activeFloatingPaneState?.size ?? tab.floatingPaneSizes[id])
                    stagedFloating = host
                    if display.session.projection.snapshot != nil {
                        display.resize(); try display.session.invalidatePresentation()
                    }
                    try await display.start()
                } else {
                    let display: NSView
                    if pane.hostView.window != nil {
                        display = pane.stageClientShellDisplay(); stagedPanes.append(pane)
                    } else { display = pane.hostView }
                    rootView.stageFloatingPaneView(display,
                        size: tab.activeFloatingPaneState?.size ?? tab.floatingPaneSizes[id])
                    stagedFloating = display
                }
            }
        }
        defer {
            if let candidate = stagedTiling { rootView.cancelStagedContentView(candidate) }
            if let popup = stagedPopup { rootView.cancelStagedHerdrPopupView(popup.terminalView) }
            if let floating = stagedFloating, rootView.isStagedFloatingPaneView(floating) { rootView.cancelStagedFloatingPaneView() }
            for pane in stagedPanes { pane.cancelClientShellDisplay() }
            if herdrShellGeneration == stagingGeneration, herdrShellStagingTab === tab { herdrShellStagingTab = nil }
        }
        if changed && stagedTiling == nil {
            tab.herdrFocusedPaneID = focused
            if !keepLocalFocus { tab.focusedPaneID = focused; selectedTabID = tab.id }
        }
        if !canStageTab, let id = tab.activeFloatingPaneState?.paneID,
           let display = herdrFloatingDisplays[id], !display.session.isPresentationReady {
            try await display.start()
        }
        try client.routeCommands(to: session)
        applyingHerdrLayout = true
        if changed && stagedTiling == nil { rebuildWorkspaceLayout() }
        applyingHerdrLayout = false
        view.layoutSubtreeIfNeeded()
        if tilingView?.isDraggingDivider != true, let (size, width, height) = herdrClientShellViewport(surface: surface) {
            try session.resize(size, cellWidth: width, cellHeight: height)
        }
        guard session.canPresent(surface) else { return true }
        var ready = true
        let preparationAt = ProcessInfo.processInfo.systemUptime
        var requests: [HerdrShellRenderRequest] = []
        for metadata in surface.panes {
            guard let id = paneIDs[metadata.pane_id], let pane = tab.terminalPaneController(for: id) else { throw CLIError("Herdr shell pane is not mapped") }
            if floatingRecord(placeholderID: metadata.pane_id) != nil { continue }
            try pane.bindClientShell(session, bootID: snapshot.boot_id)
            if pane.clientShellRenderHostView.window != nil {
                let viewportAt = ProcessInfo.processInfo.systemUptime
                let request = try await pane.prepareClientShellRenderRequest(surface, assets: assets)
                guard herdrShellSession === session, session.canPresent(surface) else { return true }
                session.recordStage("paneViewport", seconds: ProcessInfo.processInfo.systemUptime - viewportAt)
                if let request { requests.append(request) } else { ready = false }
                if surface.panes.count > 1 || surface.popup != nil {
                    // Calibrating a batch must still give pending input a turn.
                    await Task.yield()
                    try Task.checkCancellation()
                    guard herdrShellSession === session, session.canPresent(surface) else { return true }
                }
            } else if !tab.isPaneDetached(id) || tab.activeDetachedPaneID == id { ready = false }
        }
        if let popup = surface.popup {
            let needsCandidate = stagedTiling != nil || herdrShellPopup?.terminalID != popup.terminal_id
                || herdrShellPopup?.bootID != snapshot.boot_id
            let display: HerdrClientShellPopupController
            if needsCandidate {
                display = HerdrClientShellPopupController(session: session, bootID: snapshot.boot_id, terminalID: popup.terminal_id)
                stagedPopup = display
            } else if let existing = herdrShellPopup { display = existing }
            else { return false }
            var region = NSRect.null
            for id in projected.paneIDsInTraversalOrder {
                if let pane = tab.terminalPaneController(for: id),
                   let frame = rootView.backendPaneFrame(id, host: pane.clientShellRenderHostView) { region = region.union(frame) }
            }
            guard !region.isNull else { return false }
            let popupSize = NSSize(width: CGFloat(popup.frame.width) * cell.width, height: CGFloat(popup.frame.height) * cell.height)
            if needsCandidate { rootView.stageHerdrPopupView(display.terminalView, size: popupSize, backendFrame: region) }
            else { rootView.installHerdrPopupView(display.terminalView, size: popupSize, backendFrame: region) }
            let viewportAt = ProcessInfo.processInfo.systemUptime
            let request = try await display.prepareRenderRequest(surface)
            guard herdrShellSession === session, session.canPresent(surface) else { return true }
            session.recordStage("popupViewport", seconds: ProcessInfo.processInfo.systemUptime - viewportAt)
            if let request { requests.append(request) } else { ready = false }
        }
        guard ready, requests.allSatisfy({ $0.isCurrent() }) else { return false }
        let scene = try await HerdrClientShellRenderer.prepareScene(requests.map(\.input), from: surface, assets: assets)
        try Task.checkCancellation()
        guard herdrShellSession === session, session.canPresent(surface) else { return true }
        guard requests.allSatisfy({ $0.isCurrent() }) else { return false }
        session.recordRenderTiming(scene.timing)
        session.recordStage("scenePrepare", seconds: ProcessInfo.processInfo.systemUptime - preparationAt)
        let preparedOutputs = zip(requests, scene.outputs).map { $0.0.output($0.1) }
        guard preparedOutputs.allSatisfy({ $0.isCurrent() }) else { return false }
        var outputSessions: [InMemoryTerminalSession] = []
        for output in preparedOutputs {
            guard let memory = output.commit() else { return false }
            if output.byteCount > 0 { outputSessions.append(memory) }
        }
        if !outputSessions.isEmpty {
            let waits = outputSessions
            let barrierAt = ProcessInfo.processInfo.systemUptime
            await Task.detached { for memory in waits { memory.waitForPendingOutput() } }.value
            if herdrShellSession === session {
                session.recordStage("ghosttyBarrier", seconds: ProcessInfo.processInfo.systemUptime - barrierAt)
            }
        }
        try Task.checkCancellation()
        guard herdrShellSession === session, snapshot.boot_id == session.projection.snapshot?.boot_id,
              session.canPresent(surface) else { return true }
        guard preparedOutputs.allSatisfy({ $0.isCurrent() }) else { return false }
        if let candidate = stagedTiling, !rootView.isStagedContentView(candidate) { return false }
        if let popup = stagedPopup, !rootView.isStagedHerdrPopupView(popup.terminalView) { return false }
        if let floating = stagedFloating, !rootView.isStagedFloatingPaneView(floating) { return false }
        if herdrFloatingTransition { return true }
        let finalizedAt = ProcessInfo.processInfo.systemUptime
        defer { session.recordStage("hostFinalize", seconds: ProcessInfo.processInfo.systemUptime - finalizedAt) }
        if optimisticHerdrFocus != nil, selectedTabID != tab.id {
            // Parse and acknowledge old frames without replacing the locally selected tab.
            return session.acknowledgePresentation(surface)
        }
        // Existing hosts can retain their old focus until the matching output has parsed.
        applyingHerdrLayout = true
        if let candidate = stagedTiling {
            var animatedFrames: [PaneID: NSRect] = [:]
            if previousTab?.id == tab.id, let previousTiling = tilingView {
                for (id, host) in previousTiling.paneViews where host.layer?.animation(forKey: "santty.paneResize.flip") != nil {
                    animatedFrames[id] = host.layer?.presentation()?.frame ?? host.frame
                }
            }
            let previous = previousTab
            if let previous {
                for case let pane as TerminalPaneController in previous.paneControllers.values {
                    pane.setClientShellPresented(false)
                }
            }
            for pane in stagedPanes { pane.promoteClientShellDisplay() }
            if let node = tab.renderedLayout ?? tab.layoutNode {
                candidate.setLayoutNode(node, paneViews: buildPaneViewsDictionary(for: tab))
            }
            guard rootView.commitStagedContentView(candidate) else { applyingHerdrLayout = false; return false }
            for (id, oldFrame) in animatedFrames {
                if let host = candidate.paneViews[id] {
                    candidate.animateFlip(view: host, oldFrame: oldFrame, newFrame: host.frame,
                        duration: WorkspaceFocusZoomConfiguration.animationDuration,
                        timingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
                }
            }
            if let floating = stagedFloating {
                guard rootView.commitStagedFloatingPaneView(floating) else { applyingHerdrLayout = false; return false }
            } else if let previous { suspendActiveFloatingPresentation(in: previous) }
            tilingView = candidate
        }
        for case let pane as TerminalPaneController in tab.paneControllers.values {
            pane.setClientShellPresented(true)
        }
        if let popup = stagedPopup {
            let previous = herdrShellPopup
            previous?.setPresented(false)
            guard rootView.commitStagedHerdrPopupView(popup.terminalView) else {
                previous?.setPresented(true); applyingHerdrLayout = false; return false
            }
            herdrShellPopup = popup
        }
        herdrShellPopup?.setPresented(true)
        let keepCurrentLocalFocus = selectedTabID == tab.id
            && (optimisticHerdrFocus.map { $0.tabID != snapshot.focused_tab_id || $0.paneID != snapshot.focused_pane_id } == true
                || tab.focusedPaneController.map { ($0 as? TerminalPaneController)?.herdrBinding == nil } == true
                || tab.activeFloatingPaneState?.paneID == tab.focusedPaneID)
        if optimisticHerdrFocus == nil { tab.herdrFocusedPaneID = focused }
        if !keepCurrentLocalFocus { tab.focusedPaneID = focused; selectedTabID = tab.id }
        if stagedTiling != nil && stagedFloating == nil { restoreActiveFloatingPresentation(in: tab) }
        herdrShellRetainedPresentation.removeAll()
        if stagedTiling != nil { updateWindowMinimumSize() }
        if chromeChanged {
            for item in snapshot.tabs where item.workspace_id == workspace {
                tabs.first(where: { $0.herdrTabBinding?.tabID == item.tab_id })?.herdrBackendTitle = item.label
            }
            if let identity = session.serviceIdentity {
                let metadata = Dictionary(uniqueKeysWithValues: snapshot.panes.map { ($0.pane_id, $0) })
                for candidate in tabs {
                    for case let pane as TerminalPaneController in candidate.paneControllers.values {
                        if let id = pane.herdrBinding?.paneID, let item = metadata[id] {
                            pane.applyClientShellMetadata(item, identity: identity)
                        }
                    }
                }
            }
            refreshWorkspacePicker(snapshot.workspaces.map {
                HerdrSnapshot.Workspace(workspace_id: $0.workspace_id, label: $0.label, active_tab_id: $0.active_tab_id)
            })
        }
        if surface.popup == nil, herdrShellPopup != nil {
            herdrShellPopup?.setPresented(false)
            rootView.removeHerdrPopupView(); herdrShellPopup = nil
        }
        if chromeChanged {
            updatePanePresentation(in: tab); updateTabStrip(); updateWindowTitle()
            if let popup = herdrShellPopup {
                if !keepCurrentLocalFocus { view.window?.makeFirstResponder(popup.terminalView) }
            } else if !keepCurrentLocalFocus || previousTab?.id != tab.id { applyFocusedPaneResponder() }
        }
        applyingHerdrLayout = false
        guard preparedOutputs.allSatisfy({ $0.isCurrent() }), session.acknowledgePresentation(surface) else { return false }
        for index in herdrFloatingRecords.indices where herdrFloatingRecords[index].source.endpoint == client.endpoint
            && herdrFloatingRecords[index].source.serviceIdentity == session.serviceIdentity && herdrFloatingRecords[index].source.tabID == tabID {
            herdrFloatingRecords[index].sourceViewport = .init(cols: surface.frame.width, rows: surface.frame.height)
        }
        if let pending = optimisticHerdrFocus, pending.tabID == snapshot.focused_tab_id,
           pending.paneID == snapshot.focused_pane_id {
            optimisticHerdrFocus = nil
        }
        herdrShellNativeLayoutPending = false
        herdrShellPresentedSnapshot = snapshot
        if chromeChanged, view.window?.isKeyWindow == true {
            AgentSessionStore.shared.markViewed(tab.paneControllers.values.compactMap {
                ($0 as? TerminalPaneController)?.herdrBinding
            }, snapshot: snapshot)
        }
        refreshHerdrShellHostColors()
        if chromeChanged { scheduleWorkspaceSave() }
        return true
    }
}


extension WorkspaceViewController {
    private enum PaletteTarget {
        case local(workspace: UUID, tab: UUID?, pane: PaneID?)
        case herdr(binding: HerdrPaneBinding, tab: String?, pane: String?, localPane: PaneID?)
    }

    var paletteNavigationItems: [AppCommand] {
        var items = AgentSessionStore.shared.snapshots.map { session in
            AppCommand(id: "navigate.Agents." + session.id, title: session.agent.displayName,
                shortcut: nil, isEnabled: !herdrWorkspaceClosed, kind: .agent,
                subtitle: [session.paneTitle, session.statusText, session.workingDirectory, session.message]
                    .compactMap { $0 }.joined(separator: " · "),
                symbol: "terminal",
                isCurrent: selectedTabState?.focusedPaneController.flatMap { ($0 as? TerminalPaneController)?.herdrBinding } == session.binding,
                isInCurrentWorkspace: herdrWindowWorkspaceID == session.binding.workspaceID && herdrClient?.endpoint.id == session.binding.endpoint.id,
                perform: { [weak self] in self?.navigateToHerdrAgent(session.binding) })
        }
        let localSelected = herdrWindowWorkspaceID == nil
        func item(_ id: String, _ title: String, _ kind: PaletteItemKind, _ subtitle: String,
                  _ symbol: String, current: Bool, inWorkspace: Bool, target: PaletteTarget) {
            items.append(AppCommand(id: "navigate." + kind.rawValue + "." + id, title: title, shortcut: nil, isEnabled: !herdrWorkspaceClosed,
                kind: kind, subtitle: subtitle, symbol: symbol, isCurrent: current, isInCurrentWorkspace: inWorkspace,
                perform: { [weak self] in self?.navigateFromPalette(to: target) }))
        }
        for workspace in localWorkspaceStates {
            let isSelected = localSelected && workspace.id == localWorkspaceID
            item(workspace.pickerID, workspace.name, .workspace, "Local Workspace", "desktopcomputer",
                 current: isSelected, inWorkspace: isSelected, target: .local(workspace: workspace.id, tab: nil, pane: nil))
            for (index, tab) in workspace.tabs.enumerated() {
                item(tab.id.uuidString, tab.displayTitle, .tab, "\(workspace.name) › Tab \(index + 1)", "rectangle.on.rectangle",
                     current: isSelected && tab.id == selectedTabID, inWorkspace: isSelected,
                     target: .local(workspace: workspace.id, tab: tab.id, pane: nil))
                for pane in paletteOrderedPanes(tab) {
                    item(pane.id.uuidString, pane.name ?? pane.displayTitle, .pane, palettePaneSubtitle(pane, tab: tab, workspace: workspace.name),
                         palettePaneSymbol(pane), current: isSelected && tab.id == selectedTabID && tab.focusedPaneID == pane.id,
                         inWorkspace: isSelected, target: .local(workspace: workspace.id, tab: tab.id, pane: pane.id))
                }
            }
        }
        func metadata(_ shell: HerdrShellSnapshot, identity: HerdrServiceIdentity) -> HerdrSnapshot {
            .init(workspaces: shell.workspaces.map { .init(workspace_id: $0.workspace_id, label: $0.label, active_tab_id: $0.active_tab_id) },
                tabs: shell.tabs.map { .init(tab_id: $0.tab_id, workspace_id: $0.workspace_id, label: $0.label) },
                version: "", protocolVersion: 22, panes: shell.panes.map {
                    .init(pane_id: $0.pane_id, terminal_id: nil, workspace_id: $0.workspace_id, tab_id: $0.tab_id,
                          label: $0.label, cwd: $0.cwd, foreground_cwd: $0.foreground_cwd, serviceIdentity: identity)
                })
        }
        var sources: [String: (HerdrEndpoint, HerdrSnapshot)] = [:]
        for state in herdrCatalog.states.values {
            if let shell = state.snapshot, let identity = state.identity {
                sources[state.endpoint.id] = (state.endpoint, metadata(shell, identity: identity))
            }
        }
        if let endpoint = herdrClient?.endpoint {
            if let shell = herdrShellSession?.projection.snapshot, let identity = herdrShellSession?.serviceIdentity {
                sources[endpoint.id] = (endpoint, metadata(shell, identity: identity))
            } else if let snapshot = herdrLatestQuerySnapshot { sources[endpoint.id] = (endpoint, snapshot) }
        }
        for (endpoint, metadata) in sources.values.sorted(by: { $0.0.id < $1.0.id }) {
        let spaces = metadata.workspaces ?? [], backendTabs = metadata.tabs ?? []
        // Search uses management metadata too, so apply topology limits before indexing it.
        guard spaces.count <= 64, backendTabs.count <= 256, metadata.panes.count <= 512,
              Set(spaces.map(\.workspace_id)).count == spaces.count,
              Set(backendTabs.map(\.tab_id)).count == backendTabs.count,
              Set(metadata.panes.map(\.pane_id)).count == metadata.panes.count,
              spaces.allSatisfy({ !$0.workspace_id.isEmpty && $0.workspace_id.utf8.count <= 1024 && $0.label.utf8.count <= 4096 }),
              backendTabs.allSatisfy({ candidate in !candidate.tab_id.isEmpty && candidate.tab_id.utf8.count <= 1024 && candidate.label.utf8.count <= 4096
                  && spaces.contains(where: { $0.workspace_id == candidate.workspace_id }) }),
              metadata.panes.allSatisfy({ candidate in (candidate.label?.utf8.count ?? 0) <= 4096 && (candidate.title?.utf8.count ?? 0) <= 4096
                  && backendTabs.contains(where: { $0.tab_id == candidate.tab_id && $0.workspace_id == candidate.workspace_id }) })
        else { continue }
        func key(_ kind: String, _ binding: HerdrPaneBinding, _ id: String) -> String {
            let parts = [kind, endpoint.id, endpoint.session, String(describing: binding.serviceIdentity), binding.workspaceID, id]
            return (try? JSONEncoder().encode(parts).base64EncodedString()) ?? id
        }
        for space in spaces {
            let spacePanes = metadata.panes.filter { $0.workspace_id == space.workspace_id }
            guard let first = spacePanes.first, let representative = try? HerdrPaneBinding(endpoint: endpoint, pane: first) else { continue }
            let inWorkspace = space.workspace_id == herdrWindowWorkspaceID && herdrClient?.endpoint.id == endpoint.id
            let sourceTitle = endpoint.machine.map { space.label + " · " + $0.label } ?? space.label
            let kind: WorkspaceKind = endpoint.machine == nil ? .herdr : .remoteHerdr
            item(key("workspace", representative, space.workspace_id), sourceTitle, .workspace, kind.title, kind.symbol,
                 current: inWorkspace, inWorkspace: inWorkspace,
                 target: .herdr(binding: representative, tab: nil, pane: nil, localPane: nil))
            let floatingRecords = herdrFloatingRecords.filter { $0.source.endpoint == endpoint && $0.source.serviceIdentity == representative.serviceIdentity
                && $0.placeholder != nil && $0.floating != nil }
            let hiddenTabs = Set(floatingRecords.compactMap { $0.floating?.tabID })
            for (index, backendTab) in backendTabs.filter({ $0.workspace_id == space.workspace_id && !hiddenTabs.contains($0.tab_id) }).enumerated() {
                let backendPanes = spacePanes.filter { $0.tab_id == backendTab.tab_id }
                guard let first = backendPanes.first, let binding = try? HerdrPaneBinding(endpoint: endpoint, pane: first) else { continue }
                let installed = (tabs + herdrAuxiliaryTabs).first {
                    $0.herdrTabBinding?.endpoint == endpoint && $0.herdrTabBinding?.serviceIdentity == binding.serviceIdentity
                        && $0.herdrTabBinding?.tabID == backendTab.tab_id
                }
                let currentTab = inWorkspace && installed?.id == selectedTabID
                let title = installed?.displayTitle ?? backendTab.label
                item(key("tab", binding, backendTab.tab_id), title, .tab, "\(space.label) › Tab \(index + 1)", "rectangle.on.rectangle",
                     current: currentTab, inWorkspace: inWorkspace,
                     target: .herdr(binding: binding, tab: backendTab.tab_id, pane: nil, localPane: nil))
                for pane in backendPanes {
                    guard let targetBinding = try? HerdrPaneBinding(endpoint: endpoint, pane: pane) else { continue }
                    let floating = floatingRecords.first { $0.placeholder?.paneID == pane.pane_id }
                    let native = installed?.paneControllers.values.compactMap { $0 as? TerminalPaneController }.first {
                        floating == nil ? $0.herdrBinding?.paneID == pane.pane_id : $0.id == floating?.paneID
                    }
                    let label = floating.flatMap { record in metadata.panes.first { $0.pane_id == record.floating?.paneID }?.label } ?? pane.label
                    let subtitle: String
                    if let native, let installed {
                        subtitle = palettePaneSubtitle(native, tab: installed, workspace: space.label)
                    } else { subtitle = "\(space.label) › \(title) · Terminal" }
                    item(key("pane", targetBinding, pane.pane_id), native?.name ?? label ?? native?.displayTitle ?? pane.title ?? pane.pane_id,
                         .pane, subtitle, "terminal",
                         current: currentTab && native != nil && native?.id == installed?.focusedPaneID, inWorkspace: inWorkspace,
                         target: .herdr(binding: targetBinding, tab: backendTab.tab_id, pane: floating == nil ? pane.pane_id : nil, localPane: floating?.paneID))
                }
                if let installed {
                    for pane in paletteOrderedPanes(installed) where (pane as? TerminalPaneController)?.herdrBinding == nil {
                        item(pane.id.uuidString, pane.name ?? pane.displayTitle, .pane, palettePaneSubtitle(pane, tab: installed, workspace: space.label),
                             palettePaneSymbol(pane), current: currentTab && installed.focusedPaneID == pane.id, inWorkspace: inWorkspace,
                             target: .herdr(binding: binding, tab: backendTab.tab_id, pane: nil, localPane: pane.id))
                    }
                }
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
        pane is NotesPaneController ? "note.text" : pane is BrowserPaneController ? "globe" : "terminal"
    }

    private func palettePaneSubtitle(_ pane: any PaneControlling, tab: WorkspaceTabState, workspace: String) -> String {
        let kind = pane is NotesPaneController ? "Notes" : pane is BrowserPaneController ? "Browser" : "Terminal"
        let presentation = tab.activeFloatingPaneState?.paneID == pane.id ? " · Floating" : tab.isPaneDetached(pane.id) ? " · Hidden" : ""
        return "\(workspace) › \(tab.displayTitle) · \(kind)\(presentation)"
    }

    private func navigateFromPalette(to target: PaletteTarget) {
        if case let .herdr(binding, _, paneID, _) = target,
           let record = herdrFloatingRecords.first(where: { $0.floating?.paneID == paneID && $0.source.endpoint == binding.endpoint && $0.source.serviceIdentity == binding.serviceIdentity }),
           let placeholder = record.placeholder {
            navigateFromPalette(to: .herdr(binding: placeholder, tab: record.source.tabID, pane: nil, localPane: record.paneID))
            return
        }
        paletteNavigationTask?.cancel()
        paletteNavigationGeneration += 1
        let generation = paletteNavigationGeneration
        if case let .herdr(binding, tabID, paneID, localPane) = target,
           herdrWindowWorkspaceID == binding.workspaceID, herdrClient?.endpoint == binding.endpoint,
           herdrShellSession?.serviceIdentity == binding.serviceIdentity,
           let tab = tabs.first(where: { $0.herdrTabBinding?.tabID == tabID }),
           let focus = localPane ?? paneID.flatMap({ id in
               tab.paneControllers.values.first { ($0 as? TerminalPaneController)?.herdrBinding?.paneID == id }?.id
           }) ?? (paneID == nil ? tab.focusedPaneID : nil), tab.containsPane(withID: focus) {
            selectTab(withID: tab.id)
            handlePaneFocusRequest(withID: focus)
        }
        paletteNavigationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.waitForPaletteNavigation { !self.herdrOperationPending && !self.isClosingNotes }
                try Task.checkCancellation()
                self.herdrOperationPending = true
                self.herdrLastError = nil
                self.paletteNavigationInProgress = true
                self.pendingHerdrFocus = nil
                self.rootView.toolbarView.showNavigationStatus("Navigating…")
                defer {
                    self.herdrOperationPending = false
                    self.paletteNavigationInProgress = false
                    self.flushHerdrFocus(); self.flushHerdrSplit()
                }
                switch target {
                case .local(let workspaceID, let tabID, let paneID):
                    guard let local = self.localWorkspaceStates.first(where: { $0.id == workspaceID })
                    else { throw CLIError("The selected workspace no longer exists") }
                    let locals = local.tabs
                    if let tabID {
                        guard let tab = locals.first(where: { $0.id == tabID }), paneID.map({ tab.containsPane(withID: $0) }) ?? true
                        else { throw CLIError("The selected tab or pane no longer exists") }
                    }
                    self.selectLocalWorkspace(workspaceID)
                    if let tabID { self.selectTab(withID: tabID) }
                    if let paneID { self.handlePaneFocusRequest(withID: paneID) }
                case .herdr(let binding, let tabID, let paneID, let localPane):
                    if self.herdrClient?.endpoint != binding.endpoint {
                        guard self.herdrCatalog.states[binding.endpoint.id]?.identity == binding.serviceIdentity else { throw CLIError("The selected Herdr service changed or is unavailable") }
                        self.selectLocalWorkspace()
                        self.herdrDiscoveredWorkspaces = []
                        try self.configureHerdrWorkspace(binding.endpoint)
                    }
                    guard let client = self.herdrClient else { throw CLIError("Herdr connection closed") }
                    if self.herdrWindowWorkspaceID != nil {
                        try await self.waitForPaletteNavigation { self.herdrShellSession?.isPresentationReady == true }
                    }
                    try await self.verifyPaletteHerdrTarget(binding, tab: tabID, pane: paneID, localPane: localPane)
                    try Task.checkCancellation()
                    if self.herdrWindowWorkspaceID == nil {
                        self.herdrWindowIdentity = nil
                        try await self.enterHerdrWorkspace(binding.workspaceID)
                    } else if self.herdrWindowWorkspaceID != binding.workspaceID {
                        _ = try await client.request("workspace.focus", params: .init(workspace_id: binding.workspaceID))
                    }
                    try await self.waitForPaletteNavigation {
                        self.herdrWindowWorkspaceID == binding.workspaceID && self.herdrShellSession?.isPresentationReady == true
                    }
                    guard let activeClient = self.herdrClient else { throw CLIError("Herdr connection closed") }
                    try await self.verifyPaletteHerdrTarget(binding, tab: tabID, pane: paneID, localPane: localPane)
                    try Task.checkCancellation()
                    if let tabID {
                        let method = paneID == nil ? "tab.focus" : "pane.focus"
                        let needsPaneFocus = paneID != nil && paneID != self.herdrShellSession?.projection.snapshot?.focused_pane_id
                        if needsPaneFocus || tabID != self.herdrShellSession?.projection.snapshot?.focused_tab_id {
                            _ = try await activeClient.request(method, params: .init(pane_id: paneID, tab_id: paneID == nil ? tabID : nil))
                        }
                        try await self.waitForPaletteNavigation {
                            let selected = self.selectedTabState
                            let focused = selected?.herdrFocusedPaneID.flatMap { selected?.terminalPaneController(for: $0)?.herdrBinding?.paneID }
                            return selected?.herdrTabBinding?.tabID == tabID && self.herdrShellSession?.isPresentationReady == true
                                && (paneID == nil || focused == paneID)
                        }
                        guard self.herdrShellSession?.serviceIdentity == binding.serviceIdentity else { throw CLIError("Herdr service changed during navigation") }
                        if let localPane {
                            guard self.selectedTabState?.containsPane(withID: localPane) == true else { throw CLIError("The selected local pane no longer exists") }
                            self.handlePaneFocusRequest(withID: localPane)
                        } else if let focused = self.selectedTabState?.herdrFocusedPaneID {
                            self.applyingHerdrLayout = true
                            self.focusPane(withID: focused)
                            self.applyingHerdrLayout = false
                        }
                    }
                }
                try Task.checkCancellation()
                self.rootView.toolbarView.showNavigationStatus(nil)
                self.applyFocusedPaneResponder()
                if let selected = self.selectedTabState, let binding = selected.focusedPaneController as? TerminalPaneController,
                   let backend = binding.herdrBinding,
                   let paneID = AgentSessionStore.shared.snapshots.first(where: { $0.binding == backend })?.paneID {
                    AgentSessionStore.shared.markRead(forPaneIDs: [paneID])
                }
            } catch is CancellationError {
                if self.paletteNavigationGeneration == generation { self.rootView.toolbarView.showNavigationStatus(nil) }
            } catch {
                guard self.paletteNavigationGeneration == generation else { return }
                self.herdrLastError = error.localizedDescription
                self.rootView.toolbarView.showNavigationStatus("Navigation failed: \(error.localizedDescription)")
                self.herdrErrorHandler?(error.localizedDescription)
            }
        }
    }

    func focusHerdrAgent(_ paneID: PaneID) {
        guard let binding = AgentSessionStore.shared.binding(for: paneID) else { return }
        navigateToHerdrAgent(binding)
    }

    func navigateToHerdrAgent(_ binding: HerdrPaneBinding) {
        if herdrClient == nil {
            do {
                guard binding.endpoint == HerdrSettings.endpoint || herdrCatalog.states[binding.endpoint.id]?.identity == binding.serviceIdentity else { throw CLIError("Herdr connection settings changed") }
                try configureHerdrWorkspace(binding.endpoint)
            } catch {
                rootView.toolbarView.showNavigationStatus("Navigation failed: \(error.localizedDescription)")
                return
            }
        }
        navigateFromPalette(to: .herdr(binding: binding, tab: binding.tabID, pane: binding.paneID, localPane: nil))
    }

    func startHerdrAgentMonitoring(_ endpoint: HerdrEndpoint) {
        AgentSessionStore.shared.onNotification = { [weak self] message in
            guard let self, self.workspaceStore?.canWrite != false else { return }
            AgentNotifier.shared.notifyAgent(message)
        }
        AgentSessionStore.shared.isTargetVisible = { [weak self] binding in
            guard let self, self.view.window?.isKeyWindow == true, self.herdrShellSession?.isPresentationReady == true else { return false }
            return self.herdrClient?.endpoint == binding.endpoint && self.herdrShellSession?.serviceIdentity == binding.serviceIdentity
                && self.selectedTabState?.herdrTabBinding?.tabID == binding.tabID
        }
        herdrCatalog.onGeneralNotification = { [weak self] endpoint, event in
            guard let self, self.workspaceStore?.canWrite != false else { return }
            AgentNotifier.shared.notifyTerminal(title: event.title, body: event.body, sound: event.sound != nil,
                identity: "herdr.general." + endpoint.id)
        }
        herdrCatalog.onChange = { [weak self] in
            guard let self, !self.herdrWorkspaceClosed else { return }
            if let active = self.herdrClient?.endpoint, active.machine != nil, self.herdrCatalog.states[active.id]?.endpoint != active {
                self.workspaceSelectionGeneration += 1; self.workspaceSelectionTask?.cancel(); self.workspaceSelectionTask = nil
                self.herdrOperationPending = false
                self.selectLocalWorkspace()
                self.herdrDiscoveredWorkspaces = []
                try? self.configureHerdrWorkspace(HerdrSettings.endpoint)
            }
            self.refreshWorkspacePicker()
            if let restored = self.restoredWorkspaceSelection,
               let entry = self.workspaceEntries.first(where: { $0.reference.id == restored.id && $0.isAvailable }) {
                self.restoredWorkspaceSelection = nil
                self.selectWorkspace(entry.reference)
            }
        }
        herdrCatalog.start(local: endpoint)
    }

    private func verifyPaletteHerdrTarget(_ binding: HerdrPaneBinding, tab tabID: String?, pane paneID: String?, localPane: PaneID?) async throws {
        guard let client = herdrClient, client.endpoint == binding.endpoint else { throw CLIError("Herdr connection settings changed") }
        if let localPane {
            guard (tabs + herdrAuxiliaryTabs).contains(where: {
                $0.herdrTabBinding?.endpoint == binding.endpoint && $0.herdrTabBinding?.serviceIdentity == binding.serviceIdentity
                    && $0.herdrTabBinding?.tabID == tabID && $0.containsPane(withID: localPane)
            }) else { throw CLIError("The selected local pane no longer exists") }
        }
        if paneID != nil { try await client.verify(binding); return }
        if let session = herdrShellSession, let snapshot = session.projection.snapshot {
            guard session.serviceIdentity == binding.serviceIdentity,
                  snapshot.workspaces.contains(where: { $0.workspace_id == binding.workspaceID }),
                  tabID.map({ id in snapshot.tabs.contains { $0.tab_id == id && $0.workspace_id == binding.workspaceID } }) ?? true
            else { throw CLIError("The selected Herdr workspace or tab no longer exists") }
        } else {
            let snapshot = try await client.snapshot()
            guard snapshot.panes.contains(where: { $0.workspace_id == binding.workspaceID && $0.serviceIdentity == binding.serviceIdentity }),
                  snapshot.workspaces?.contains(where: { $0.workspace_id == binding.workspaceID }) == true,
                  tabID.map({ id in snapshot.tabs?.contains { $0.tab_id == id && $0.workspace_id == binding.workspaceID } == true }) ?? true
            else { throw CLIError("The selected Herdr workspace or tab changed") }
        }
    }

    private func waitForPaletteNavigation(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while !condition() {
            try Task.checkCancellation()
            guard !herdrWorkspaceClosed else { throw CancellationError() }
            if let failure = herdrShellSession?.failure { throw failure }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CLIError("Navigation timed out waiting for the committed layout") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
    }

    func waitForPaletteNavigationForTesting() async { await paletteNavigationTask?.value }
}
