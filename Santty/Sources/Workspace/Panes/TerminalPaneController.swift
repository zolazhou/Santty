import AppKit
import Darwin
import GhosttyTerminal

@MainActor
final class TerminalPaneController: NSObject, PaneControlling {
    let id: PaneID
    private var terminalHostView: TerminalPaneHostView

    var hostView: NSView {
        terminalHostView
    }

    private(set) var herdrBinding: HerdrPaneBinding?
    private var clientShellQueryBinding: HerdrPaneBinding?
    private var clientShellQueryEpoch = 0
    var herdrQueryBinding: HerdrPaneBinding? {
        clientShellQueryBinding
    }
    let herdrTransport: HerdrPaneTransport = .clientShell
    private weak var clientShellSession: HerdrClientShellSession?
    private var clientShellBootID: String?
    private var clientShellSurfaceAttached = false
    private var clientShellIsPresented = true
    private(set) var clientShellHostColorEpoch = 0
    private var clientShellRenderer = HerdrClientShellRenderer()
    private var clientShellFeedback: HerdrShellDisplayFeedback?
    private var clientShellCandidate: ClientShellDisplay?
    private(set) var clientShellDisplayError: String?
    private var clientShellPressedKeys: [UInt16: HerdrShellInput.Key] = [:]
    private var clientShellMouseReporting = false
    private var clientShellPixelMouse = false
    private var clientShellPressedButtons = Set<UInt32>()
    private var clientShellWheelX: CGFloat = 0
    private var clientShellWheelY: CGFloat = 0
    private var herdrMemorySession: InMemoryTerminalSession?
    let herdrRestorationMode: HerdrTerminalMode = .control
    private var herdrGeneration = 0
    private(set) var herdrState: HerdrConnectionState = .disconnected
    private var terminalView: TerminalView
    private var terminalController: TerminalController
    private let foregroundProcessIDProvider: @MainActor () -> Int32?
    private let processWorkingDirectoryProvider: (Int32) -> String?

    private(set) var isLive = true
    private(set) var hasStarted = false
    private(set) var lastKnownTitle = "Shell"
    var name: String? {
        didSet { terminalHostView.nameBadge.name = name }
    }
    private(set) var currentWorkingDirectory: String?
    private(set) var herdrProcessInfo: HerdrProcessInfo?
    private var isFloating = false
    private(set) var isScrollModeActive = false
    private var persistentHistory: HerdrHistoryView?
    private var historyTask: Task<Void, Never>?
    private var historyGeneration = 0
    private var isAwaitingSecondScrollModeG = false

    var onFocusRequest: ((PaneID) -> Void)? {
        didSet {
            terminalHostView.onFocusRequest = onFocusRequest
        }
    }

    var onTitleChange: ((PaneID) -> Void)?
    var onExit: ((PaneID) -> Void)?

    var displayTitle: String {
        if herdrBinding != nil, isLive {
            return switch herdrState {
            case .interactive: "\(lastKnownTitle) · Persistent"
            case .subscribed: "\(lastKnownTitle) · Connecting"
            case .connecting, .reconnecting: "\(lastKnownTitle) · Connecting"
            case .failed: "\(lastKnownTitle) · Connection Failed"
            default: "\(lastKnownTitle) · Disconnected"
            }
        }
        return isLive ? lastKnownTitle : "\(lastKnownTitle) (Exited)"
    }

    var focusTargetView: NSView {
        if let persistentHistory { return persistentHistory.textView }
        return terminalHostView.scrollModeView ?? (isLive ? terminalView : terminalHostView)
    }

    var canAcceptInput: Bool {
        guard isLive, let binding = herdrBinding else { return isLive }
        guard clientShellIsPresented, clientShellSurfaceAttached, terminalView.window != nil,
              let session = clientShellSession, clientShellBootID == session.projection.snapshot?.boot_id else { return false }
        return session.state == .interactive && session.isPresentationReady && herdrState == .interactive
            && session.projection.coherentSurface?.containsInputTarget(binding.paneID, popup: false) == true
    }

    private var canSendClientShellInput: Bool {
        guard isLive, let binding = herdrBinding, clientShellIsPresented, clientShellSurfaceAttached,
              terminalView.window != nil, let session = clientShellSession,
              clientShellBootID == session.projection.snapshot?.boot_id else { return false }
        return session.isInputReady && herdrState == .interactive
            && session.projection.coherentSurface?.containsInputTarget(binding.paneID, popup: false) == true
    }

    var foregroundProcessID: Int? {
        if herdrBinding != nil { return isLive ? herdrProcessInfo?.foreground_process_group_id : nil }
        guard isLive, let processID = foregroundProcessIDProvider() else {
            return nil
        }

        return Int(processID)
    }

    func inputSourceForeground() async throws -> InputSourceForeground {
        if herdrBinding != nil {
            try await refreshHerdrProcessInfo()
            guard let info = herdrProcessInfo else { throw CLIError("Foreground process information is unavailable") }
            return InputSourceForeground(groupID: info.foreground_process_group_id,
                processes: (info.foreground_processes ?? []).map {
                    .init(id: $0.pid, name: $0.name, command: $0.cmdline)
                })
        }
        guard let groupID = foregroundProcessID else { throw CLIError("Foreground process information is unavailable") }
        let processes = await Task.detached(priority: .utility) {
            TerminalProcessInspector.currentProcessTable().filter { $0.processGroupID == groupID }
                .map { InputSourceForeground.Process(id: $0.processID, name: $0.executableName ?? "", command: $0.command) }
        }.value
        try Task.checkCancellation()
        guard foregroundProcessID == groupID else { throw CLIError("Foreground process changed during lookup") }
        return InputSourceForeground(groupID: groupID, processes: processes)
    }

    var inputSourceTargetView: NSView? {
        guard canAcceptInput, !isScrollModeActive, persistentHistory == nil else { return nil }
        return clientShellCandidate?.view ?? terminalView
    }

    var workingDirectoryForNewPane: String? {
        if herdrBinding != nil { return currentWorkingDirectory }
        guard
            isLive,
            let processID = foregroundProcessIDProvider(),
            let processWorkingDirectory = processWorkingDirectoryProvider(processID),
            !processWorkingDirectory.isEmpty
        else {
            return currentWorkingDirectory
        }

        return processWorkingDirectory
    }

    init(
        id: PaneID = UUID(),
        workingDirectory: String? = nil,
        herdr: HerdrPaneBinding? = nil,
        launchCommand: String? = nil,
        foregroundProcessIDProvider: (@MainActor () -> Int32?)? = nil,
        processWorkingDirectoryProvider: @escaping (Int32) -> String? = {
            ProcessWorkingDirectoryResolver.workingDirectory(for: $0)
        }
    ) {
        self.id = id
        herdrBinding = herdr
        let feedback = herdr.map { _ in HerdrShellDisplayFeedback() }
        clientShellFeedback = feedback
        let memory = herdr.map { _ in
            InMemoryTerminalSession(write: { bytes in feedback?.receive(bytes) }, resize: { _ in feedback?.invalidateViewport() })
        }
        herdrMemorySession = memory
        currentWorkingDirectory = workingDirectory

        let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        let terminalController = TerminalController(
            configuration: Self.terminalConfiguration(
                for: id,
                workingDirectory: workingDirectory,
                clientShell: herdr != nil,
                launchCommand: launchCommand
            ),
            theme: TerminalDefaults.theme
        )
        terminalView.configuration = memory.map { TerminalSurfaceOptions(backend: .inMemory($0)) } ?? TerminalSurfaceOptions()
        terminalView.controller = terminalController

        self.terminalView = terminalView
        self.terminalController = terminalController
        self.foregroundProcessIDProvider = foregroundProcessIDProvider ?? {
            [weak terminalView] in
            terminalView?.foregroundPid
        }
        self.processWorkingDirectoryProvider = processWorkingDirectoryProvider
        terminalHostView = TerminalPaneHostView(paneID: id, terminalView: terminalView)

        super.init()

        if herdrBinding != nil {
            installClientShellInputHandlers()
        }

        terminalView.delegate = self
        updatePresentation(isFocused: false)
    }

    deinit {
        MainActor.assumeIsolated {
            historyTask?.cancel()
            cancelClientShellDisplay()
            clientShellFeedback?.setHandler(nil)
            terminalView.invalidateClipboardWrites()
            terminalView.delegate = nil
            terminalView.controller = nil
        }
    }

    func startIfNeeded() {
        guard !hasStarted else {
            return
        }

        hasStarted = true
    }

    func disconnectHerdr() {
        guard herdrBinding != nil else { return }
        cancelClientShellDisplay()
        terminalView.invalidateClipboardWrites()
        herdrGeneration += 1
        clientShellSession = nil; clientShellBootID = nil; clientShellQueryBinding = nil; clientShellRenderer.reset()
        herdrProcessInfo = nil
        clientShellFeedback?.setHandler(nil); clientShellDisplayError = nil
        clientShellPressedKeys.removeAll(); terminalView.unmarkText()
        clientShellPressedButtons.removeAll(); clientShellWheelX = 0; clientShellWheelY = 0
        herdrState = .disconnected
        terminalHostView.toolTip = nil
        onTitleChange?(id)
    }

    func applyHerdrMove(_ binding: HerdrPaneBinding) throws {
        guard let current = herdrBinding, current.endpoint == binding.endpoint,
              current.serviceIdentity == binding.serviceIdentity, current.workspaceID == binding.workspaceID,
              current.paneID == binding.paneID else { throw CLIError("Herdr moved pane identity changed") }
        disconnectHerdr()
        herdrBinding = binding
        setClientShellPresented(false)
    }


    func setClientShellPresented(_ presented: Bool) {
        clientShellIsPresented = presented
        if !presented { terminalView.invalidateClipboardWrites() }
    }

    // A new native display owns its own image uploads; the pane and Agent identity stay stable.
    private final class ClientShellDisplay: NSObject, TerminalSurfaceLifecycleDelegate {
        let view: TerminalView
        let host: TerminalPaneHostView
        let controller: TerminalController
        let feedback: HerdrShellDisplayFeedback
        let memory: InMemoryTerminalSession
        var renderer = HerdrClientShellRenderer()
        var attached = false
        var epoch = 0
        var mouseReporting = false
        var pixelMouse = false
        var displayError: String?

        init(id: PaneID, configuration: TerminalConfiguration) {
            let feedback = HerdrShellDisplayFeedback()
            self.feedback = feedback
            memory = InMemoryTerminalSession(write: { feedback.receive($0) }, resize: { _ in feedback.invalidateViewport() })
            view = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
            controller = TerminalController(configuration: configuration, theme: TerminalDefaults.theme)
            host = TerminalPaneHostView(paneID: id, terminalView: view)
            super.init()
            view.configuration = .init(backend: .inMemory(memory))
            view.controller = controller
            view.delegate = self
        }
        func terminalDidAttachSurface(_: TerminalSurface) { attached = true; epoch += 1; renderer.reset(); feedback.invalidateViewport() }
        func terminalDidDetachSurface() { attached = false; epoch += 1; renderer.reset(); feedback.invalidateViewport() }
    }

    func stageClientShellDisplay() -> NSView {
        precondition(herdrBinding != nil)
        cancelClientShellDisplay()
        let candidate = ClientShellDisplay(id: id,
            configuration: Self.terminalConfiguration(for: id, workingDirectory: currentWorkingDirectory, clientShell: true))
        clientShellCandidate = candidate
        candidate.host.nameBadge.name = name
        candidate.feedback.setHandler { [weak self, weak candidate] failure in
            Task { @MainActor in
                guard let self, let candidate, candidate.renderer.ownsImage(failure.imageID) else { return }
                let message = "Ghostty image \(failure.imageID): \(failure.message)"
                if self.clientShellCandidate === candidate {
                    candidate.displayError = message; candidate.epoch += 1
                } else if self.terminalView === candidate.view {
                    self.clientShellDisplayError = message; self.terminalHostView.toolTip = message
                    self.onTitleChange?(self.id)
                }
            }
        }
        return candidate.host
    }

    func cancelClientShellDisplay() {
        guard let candidate = clientShellCandidate else { return }
        clientShellCandidate = nil
        candidate.view.delegate = nil
        candidate.host.removeFromSuperview()
        candidate.view.controller = nil
    }

    func promoteClientShellDisplay() {
        guard let candidate = clientShellCandidate, candidate.attached else { return }
        let previous = terminalView
        let nameVisible = terminalHostView.nameBadge.isRevealed
        previous.invalidateClipboardWrites(); previous.unmarkText(); previous.delegate = nil
        terminalHostView = candidate.host; terminalView = candidate.view; terminalController = candidate.controller
        herdrMemorySession = candidate.memory; clientShellFeedback?.setHandler(nil)
        clientShellFeedback = candidate.feedback; clientShellRenderer = candidate.renderer
        clientShellSurfaceAttached = candidate.attached
        clientShellMouseReporting = candidate.mouseReporting; clientShellPixelMouse = candidate.pixelMouse
        clientShellCandidate = nil
        herdrGeneration += 1; clientShellHostColorEpoch += 1
        terminalView.delegate = self
        installClientShellInputHandlers()
        installClientShellFeedbackHandler()
        terminalHostView.onFocusRequest = onFocusRequest
        terminalHostView.nameBadge.isRevealed = nameVisible
        if let persistentHistory { terminalHostView.showPersistentHistory(persistentHistory) }
        previous.controller = nil
    }

    var clientShellRenderHostView: NSView { clientShellCandidate?.host ?? terminalHostView }

    private func installClientShellFeedbackHandler() {
        let generation = herdrGeneration
        clientShellFeedback?.setHandler { [weak self] failure in
            Task { @MainActor in
                guard let self, self.herdrGeneration == generation, self.clientShellSession != nil,
                      self.clientShellRenderer.ownsImage(failure.imageID) else { return }
                self.clientShellDisplayError = "Ghostty image \(failure.imageID): \(failure.message)"
                self.terminalHostView.toolTip = self.clientShellDisplayError
                self.onTitleChange?(self.id)
            }
        }
    }

    func bindClientShell(_ session: HerdrClientShellSession, bootID: String) throws {
        guard let binding = herdrBinding, binding.endpoint == session.endpoint,
              let identity = binding.serviceIdentity, identity == session.serviceIdentity,
              session.projection.snapshot?.boot_id == bootID, isLive else {
            throw CLIError("Herdr pane and ClientShell service identities differ")
        }
        if clientShellBootID != bootID || clientShellSession !== session {
            clientShellRenderer.reset(); clientShellDisplayError = nil
            herdrGeneration += 1
            installClientShellInputHandlers()
            installClientShellFeedbackHandler()
        }
        clientShellSession = session; clientShellBootID = bootID
        applyClientShellState(session.state)
    }

    func applyClientShellState(_ state: HerdrConnectionState) {
        guard herdrBinding != nil else { return }
        if state != .interactive {
            terminalView.invalidateClipboardWrites()
            clientShellWheelX = 0; clientShellWheelY = 0; terminalView.unmarkText()
        }
        clientShellPressedKeys = clientShellPressedKeys.filter { entry in
            clientShellSession?.hasHeldKey(target: herdrBinding?.paneID ?? "", physicalKeyID: UInt32(entry.key)) == true
        }
        clientShellPressedButtons = clientShellPressedButtons.filter { button in
            clientShellSession?.hasHeldMouse(target: herdrBinding?.paneID ?? "", button: button) == true
        }
        let previousState = herdrState, previousToolTip = terminalHostView.toolTip
        herdrState = state
        if case .failed(let message) = state { terminalHostView.toolTip = message }
        else { terminalHostView.toolTip = clientShellDisplayError }
        if previousState != state || previousToolTip != terminalHostView.toolTip { onTitleChange?(id) }
    }

    func prepareClientShellRender(_ surface: HerdrShellSurface, assets: [HerdrShellAssetKey: Data]) async throws
        -> HerdrShellPreparedRender? {
        guard let request = try await prepareClientShellRenderRequest(surface, assets: assets) else { return nil }
        let scene = try await HerdrClientShellRenderer.prepareScene([request.input], from: surface, assets: assets)
        guard request.isCurrent() else { return nil }
        clientShellSession?.recordRenderTiming(scene.timing)
        return request.output(scene.outputs[0])
    }

    func prepareClientShellRenderRequest(_ surface: HerdrShellSurface, assets: [HerdrShellAssetKey: Data]) async throws
        -> HerdrShellRenderRequest? {
        guard let binding = herdrBinding, let session = clientShellSession,
              clientShellBootID == surface.boot_id, let snapshot = session.projection.snapshot,
              snapshot.boot_id == surface.boot_id,
              session.canPresent(surface),
              snapshot.panes.contains(where: { $0.pane_id == binding.paneID && $0.tab_id == binding.tabID
                  && $0.workspace_id == binding.workspaceID }), isLive else {
            throw CLIError("Herdr pane render target is stale or unavailable")
        }
        let candidate = clientShellCandidate
        if let error = candidate?.displayError { throw CLIError(error) }
        let terminalView = candidate?.view ?? self.terminalView
        let terminalHostView = candidate?.host ?? self.terminalHostView
        guard let memory = candidate?.memory ?? herdrMemorySession,
              candidate?.attached ?? clientShellSurfaceAttached, terminalView.window != nil else { return nil }
        guard let pane = surface.panes.first(where: { $0.pane_id == binding.paneID }),
              pane.inner_rect.width > 0, pane.inner_rect.height > 0 else {
            throw CLIError("Herdr pane is absent from the visible surface")
        }
        let rect = pane.inner_rect
        guard let metrics = terminalView.scrollModeGrid, metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 else { return nil }
        let scale = terminalView.convertToBacking(NSSize(width: 1, height: 1))
        guard scale.width > 0, scale.height > 0 else { return nil }
        let cursorRect = surface.frame.cursor.flatMap { cursor -> NSRect? in
            guard pane.focused, cursor.visible, cursor.x >= rect.x, cursor.y >= rect.y,
                  Int(cursor.x) < Int(rect.x) + Int(rect.width),
                  Int(cursor.y) < Int(rect.y) + Int(rect.height) else { return nil }
            let width = CGFloat(metrics.cellWidthPixels) / scale.width
            let height = CGFloat(metrics.cellHeightPixels) / scale.height
            return NSRect(x: CGFloat(cursor.x - rect.x) * width, y: CGFloat(cursor.y - rect.y) * height,
                          width: width, height: height)
        }
        let generation = herdrGeneration, displayEpoch = clientShellHostColorEpoch
        let candidateEpoch = candidate?.epoch
        let isCurrent: @MainActor () -> Bool = { [self] in
            let displayCurrent: Bool
            if let candidate {
                displayCurrent = candidate.epoch == candidateEpoch && candidate.attached
                    && (clientShellCandidate === candidate || self.terminalView === candidate.view)
            } else {
                displayCurrent = herdrGeneration == generation && clientShellHostColorEpoch == displayEpoch
                    && clientShellSurfaceAttached && self.terminalView === terminalView
            }
            return displayCurrent && terminalView.window != nil && clientShellSession === session
                && clientShellBootID == surface.boot_id
                && session.canPresent(surface)
        }
        guard let feedback = candidate?.feedback ?? clientShellFeedback else { return nil }
        var renderer = candidate?.renderer ?? clientShellRenderer
        let size = HerdrShellSize(cols: rect.width, rows: rect.height)
        let confirmedViewport = feedback.hasConfirmedViewport(size, in: memory)
        let reusesViewport = try confirmedViewport && renderer.canReuse(.pane(binding.paneID), from: surface, assets: assets)
        if !reusesViewport {
            terminalHostView.setFixedTerminalSize(NSSize(
                width: CGFloat(rect.width) * CGFloat(metrics.cellWidthPixels) / scale.width,
                height: CGFloat(rect.height) * CGFloat(metrics.cellHeightPixels) / scale.height))
            terminalView.fitToSize()
            guard let grid = terminalView.scrollModeGrid,
                  grid.columns == rect.width, grid.rows == rect.height else { return nil }
            // A native resize can discard cells even when the backend returns to the same grid.
            if !confirmedViewport { renderer.reset() }
            try await feedback.waitForViewport(size, in: memory)
            guard isCurrent() else { return nil }
        }
        try Task.checkCancellation()
        guard isCurrent() else { return nil }
        return .init(input: .init(renderer: renderer, target: .pane(binding.paneID)),
                     isCurrent: isCurrent, commit: { [self] preparedRenderer, bytes in
            guard isCurrent() else { return nil }
            if !bytes.isEmpty {
                guard memory.receiveIfAttached(bytes) else { return nil }
                terminalHostView.setFixedTerminalCursorRect(cursorRect)
            }
            if let candidate, clientShellCandidate === candidate {
                candidate.renderer = preparedRenderer
                candidate.mouseReporting = pane.mouse_reporting; candidate.pixelMouse = pane.sgr_pixel_mouse
            } else {
                clientShellRenderer = preparedRenderer
                clientShellMouseReporting = pane.mouse_reporting; clientShellPixelMouse = pane.sgr_pixel_mouse
            }
            return memory
        })
    }

    private func handleClientShellMouse(_ event: NSEvent) -> Bool {
        clientShellPressedButtons = clientShellPressedButtons.filter { button in
            clientShellSession?.hasHeldMouse(target: herdrBinding?.paneID ?? "", button: button) == true
        }
        let wheel = event.type == .scrollWheel
        let button: UInt32? = event.buttonNumber == 0 ? 0 : event.buttonNumber == 1 ? 1 : event.buttonNumber == 2 ? 2 : nil
        let held = button.map { clientShellPressedButtons.contains($0) } == true
        if !wheel, !held, (!clientShellMouseReporting || event.modifierFlags.contains(.shift)) { return false }
        let release = [NSEvent.EventType.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type) && held
        guard canSendClientShellInput || release, let grid = terminalView.scrollModeGrid,
              grid.cellWidthPixels > 0, grid.cellHeightPixels > 0 else { return true }
        let scale = terminalView.convertToBacking(NSSize(width: 1, height: 1))
        let p = terminalView.convert(event.locationInWindow, from: nil)
        let point = NSPoint(x: p.x, y: terminalView.bounds.height - p.y)
        var events: [HerdrShellInput] = []
        func mouse(_ kind: UInt32, _ button: UInt32? = nil, _ lines: UInt16 = 1) -> HerdrShellInput.Mouse? {
            HerdrClientShellInput.mouse(kind: kind, button: button, point: point, grid: grid, scale: scale,
                pixel: clientShellPixelMouse, flags: event.modifierFlags, lines: lines, clamp: held)
        }
        if wheel {
            guard event.scrollingDeltaX.isFinite, event.scrollingDeltaY.isFinite else { return true }
            let cellWidth = CGFloat(grid.cellWidthPixels) / scale.width
            let cellHeight = CGFloat(grid.cellHeightPixels) / scale.height
            let limit = CGFloat(UInt16.max)
            clientShellWheelX = min(max(clientShellWheelX + event.scrollingDeltaX / (event.hasPreciseScrollingDeltas ? cellWidth : 1), -limit), limit)
            clientShellWheelY = min(max(clientShellWheelY + event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? cellHeight : 1), -limit), limit)
            for vertical in [true, false] {
                let delta = vertical ? clientShellWheelY : clientShellWheelX
                let count = min(floor(abs(delta)), CGFloat(UInt16.max))
                if count >= 1, let value = mouse(vertical ? (delta > 0 ? 4 : 5) : (delta > 0 ? 6 : 7), nil, UInt16(count)) {
                    events.append(.mouse(value))
                    let consumed = delta > 0 ? count : -count
                    if vertical { clientShellWheelY -= consumed } else { clientShellWheelX -= consumed }
                }
            }
        } else {
            let kind: UInt32
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                terminalView.window?.makeFirstResponder(terminalView); kind = 0
            case .leftMouseUp, .rightMouseUp, .otherMouseUp: guard held else { return true }; kind = 1
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: guard held else { return true }; kind = 2
            case .mouseMoved: kind = 3
            default: return true
            }
            guard let value = mouse(kind, kind <= 2 ? button : nil) else { return true }
            if kind == 1, let button { clientShellPressedButtons.remove(button) }
            let sent = kind == 1 ? sendClientShellRelease(.mouse(value)) : sendClientShellInput([.mouse(value)])
            if sent, let button {
                if kind == 0 { clientShellPressedButtons.insert(button) }
            }
            return true
        }
        if !events.isEmpty { _ = sendClientShellInput(events) }
        return true
    }

    private func installClientShellInputHandlers() {
        let view = terminalView, host = terminalHostView, generation = herdrGeneration
        view.semanticKeyHandler = { [weak self, weak view] event, translated, text in
            guard let self, self.terminalView === view, self.herdrGeneration == generation else { return }
            if event.type == .keyUp {
                guard var key = self.clientShellPressedKeys.removeValue(forKey: event.keyCode) else { return }
                key.kind = 2; key.text = nil
                _ = self.sendClientShellRelease(.key(key))
            } else {
                guard !event.isARepeat || self.clientShellPressedKeys[event.keyCode] != nil,
                      let key = HerdrClientShellInput.key(event, translated: translated, text: text) else { return }
                if self.sendClientShellInput([.key(key)]) { self.clientShellPressedKeys[event.keyCode] = key }
            }
        }
        view.semanticTextCommitHandler = { [weak self, weak view] text in
            guard let self, self.terminalView === view, self.herdrGeneration == generation else { return }
            _ = self.sendClientShellInput([.text(text)])
        }
        view.semanticPasteHandler = { [weak self, weak view, weak host] in
            guard let self, self.terminalView === view, self.terminalHostView === host,
                  self.herdrGeneration == generation else { return }
            self.terminalHostView.paste(nil)
        }
        view.semanticMouseHandler = { [weak self, weak view] event in
            guard let self, self.terminalView === view, self.herdrGeneration == generation else { return true }
            return self.handleClientShellMouse(event)
        }
        host.onPasteText = { [weak self, weak host] text in
            guard let self, self.terminalHostView === host, self.herdrGeneration == generation else { return false }
            return self.sendClientShellInput([.paste(text)])
        }
    }

    @discardableResult
    func sendClientShellInput(_ events: [HerdrShellInput]) -> Bool {
        guard canSendClientShellInput, let binding = herdrBinding,
              let session = clientShellSession, clientShellBootID == session.projection.snapshot?.boot_id else { return false }
        return session.input(target: binding.paneID, events: events)
    }

    func queryClientShellHostColors() async throws -> HerdrShellHostColors {
        guard herdrBinding != nil, clientShellSurfaceAttached, terminalView.window != nil,
              let memory = herdrMemorySession, let feedback = clientShellFeedback,
              let session = clientShellSession, let boot = clientShellBootID else {
            throw CLIError("Ghostty host color query target is unavailable")
        }
        let epoch = clientShellHostColorEpoch, generation = herdrGeneration
        let colors = try await feedback.queryHostColors(in: memory)
        try Task.checkCancellation()
        guard epoch == clientShellHostColorEpoch, generation == herdrGeneration,
              clientShellSurfaceAttached, terminalView.window != nil,
              clientShellSession === session, clientShellBootID == boot else {
            throw CancellationError()
        }
        return colors
    }

    func receiveClientShellClipboard(_ text: String) throws {
        guard herdrBinding != nil, canAcceptInput else { return }
        guard terminalView.requestClipboardWrite(text) else { throw CLIError("Ghostty clipboard target or policy is unavailable") }
    }

    private func sendClientShellRelease(_ event: HerdrShellInput) -> Bool {
        guard isLive, let binding = herdrBinding, let session = clientShellSession,
              clientShellBootID == session.projection.snapshot?.boot_id else { return false }
        return session.input(target: binding.paneID, events: [event])
    }



    func applyHerdrSnapshot(_ pane: HerdrSnapshot.Pane?) {
        guard let binding = herdrBinding else { return }
        clientShellQueryEpoch += 1
        let previous = clientShellQueryBinding
        clientShellQueryBinding = nil
        if let pane, binding.matches(pane, requireRuntime: false), pane.terminal_id != nil {
            clientShellQueryBinding = try? HerdrPaneBinding(endpoint: binding.endpoint, pane: pane, includeRuntime: true)
        }
        if previous != clientShellQueryBinding {
            herdrProcessInfo = nil
            historyGeneration += 1
            historyTask?.cancel(); historyTask = nil
            persistentHistory?.showError("History identity changed. Reopen history to refresh.")
        }
    }

    func applyClientShellMetadata(_ pane: HerdrShellSnapshot.Pane, identity: HerdrServiceIdentity) {
        guard let binding = herdrBinding,
              binding.serviceIdentity == identity, binding.paneID == pane.pane_id,
              binding.workspaceID == pane.workspace_id, binding.tabID == pane.tab_id else { return }
        let title = pane.label ?? "Shell"
        let backendName = pane.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = backendName?.isEmpty == false ? backendName : nil
        let cwd = pane.foreground_cwd ?? pane.cwd
        guard lastKnownTitle != title || currentWorkingDirectory != cwd || self.name != name else { return }
        self.name = name
        lastKnownTitle = title
        currentWorkingDirectory = cwd
        onTitleChange?(id)
    }

    func resolveHerdrQueryBinding(using client: HerdrWorkspaceClient? = nil) async throws -> HerdrPaneBinding {
        try Task.checkCancellation()
        guard isLive, let binding = herdrBinding else { throw CLIError("Herdr query target is unavailable") }
        if let query = herdrQueryBinding { return query }
        guard herdrBinding != nil else { throw CLIError("Herdr runtime identity is unavailable") }
        let generation = herdrGeneration, epoch = clientShellQueryEpoch
        let metadata: HerdrSnapshot.Pane
        if let client {
            guard client.endpoint == binding.endpoint else { throw CLIError("Herdr query endpoint changed") }
            guard let pane = try await client.snapshot().panes.first(where: { binding.matches($0, requireRuntime: false) }) else {
                throw CLIError("Herdr query target changed")
            }
            metadata = pane
        } else {
            metadata = try await HerdrWorkspaceClient(endpoint: binding.endpoint, identity: binding.serviceIdentity).verify(binding, requireRuntime: false)
        }
        try Task.checkCancellation()
        guard let runtime = metadata.terminal_id, !runtime.isEmpty else {
            throw CLIError("Herdr runtime identity is unavailable for this pane")
        }
        let query = try HerdrPaneBinding(endpoint: binding.endpoint, pane: metadata, includeRuntime: true)
        guard isLive, herdrGeneration == generation, clientShellQueryEpoch == epoch,
              clientShellQueryBinding == nil || clientShellQueryBinding == query else {
            throw CLIError("Herdr query identity changed while resolving it")
        }
        // Acquiring the first mapping must not cancel the history task that requested it.
        clientShellQueryBinding = query
        return query
    }

    func refreshHerdrProcessInfo() async throws {
        herdrProcessInfo = nil
        guard herdrBinding != nil, isLive else { return }
        let generation = herdrGeneration
        let binding = try await resolveHerdrQueryBinding()
        let info = try await HerdrWorkspaceClient(endpoint: binding.endpoint, identity: binding.serviceIdentity).processInfo(binding)
        guard isLive, generation == herdrGeneration, herdrQueryBinding == binding else { return }
        herdrProcessInfo = info
    }

    func fitToSize() {
        terminalView.fitToSize()
    }

    var clientShellGridMetrics: TerminalGridMetrics? { clientShellCandidate?.view.scrollModeGrid ?? terminalView.scrollModeGrid }
    var clientShellBackingScale: NSSize { (clientShellCandidate?.view ?? terminalView).convertToBacking(NSSize(width: 1, height: 1)) }

    func setNameVisible(_ visible: Bool) {
        terminalHostView.nameBadge.isRevealed = visible
    }

    func updatePresentation(isFocused: Bool, isFloating: Bool = false) {
        self.isFloating = isFloating
        terminalHostView.updatePresentation(
            isFocused: isFocused,
            isFloating: isFloating,
            isLive: isLive,
            displayTitle: displayTitle
        )
    }

    func copySelection(_ sender: Any?) {
        if let persistentHistory { persistentHistory.copy(); return }
        terminalHostView.copy(sender)
    }

    func readForCLI(_ request: CLIRequest) throws -> CLIResponse {
        // shortcut: snapshot the full buffer; use ranged Ghostty reads if polling becomes costly.
        guard herdrBinding == nil else { throw CLIError("Persistent history requires the asynchronous backend read path") }
        guard let text = terminalView.readScreenText() else {
            throw CLIError("Terminal content is unavailable; the pane may not have started or may have closed.")
        }
        return try CLITextSnapshot.response(text, request: request)
    }

    func enterScrollMode() {
        if herdrBinding != nil {
            guard isLive, !isScrollModeActive else { return }
            isScrollModeActive = true
            historyGeneration += 1
            let generation = historyGeneration
            let history = HerdrHistoryView(frame: .zero)
            persistentHistory = history
            terminalHostView.showPersistentHistory(history)
            historyTask = Task { [weak self, weak history] in
                do {
                    guard let self else { return }
                    let binding = try await self.resolveHerdrQueryBinding()
                    guard self.historyGeneration == generation, self.isScrollModeActive else { return }
                    let read = try await HerdrWorkspaceClient(endpoint: binding.endpoint, identity: binding.serviceIdentity).read(binding)
                    guard self.historyGeneration == generation, self.isScrollModeActive,
                          self.herdrQueryBinding == binding else { return }
                    try history?.load(read, paneID: self.id)
                } catch {
                    guard let self, self.historyGeneration == generation else { return }
                    history?.showError(error.localizedDescription)
                }
            }
            return
        }
        guard isLive, !isScrollModeActive else {
            return
        }

        guard terminalController.setTerminalConfiguration(Self.terminalConfiguration(
            for: id, workingDirectory: currentWorkingDirectory, scrollMode: true
        )) else {
            NSSound.beep()
            return
        }
        terminalView.clearScrollModeSelection()

        isScrollModeActive = true
        isAwaitingSecondScrollModeG = false
        terminalHostView.showScrollMode()
    }

    func exitScrollMode() {
        guard isScrollModeActive else {
            return
        }

        isScrollModeActive = false
        isAwaitingSecondScrollModeG = false
        if let persistentHistory {
            historyGeneration += 1
            historyTask?.cancel(); historyTask = nil
            persistentHistory.removeFromSuperview()
            self.persistentHistory = nil
            terminalHostView.hidePersistentHistory()
            return
        }
        terminalHostView.hideScrollMode()
        terminalController.setTerminalConfiguration(Self.terminalConfiguration(
            for: id, workingDirectory: currentWorkingDirectory
        ))
    }

    func handleScrollModeKeyEvent(_ event: NSEvent) -> Bool {
        guard isScrollModeActive, event.type == .keyDown else {
            return false
        }
        if let eventWindow = event.window {
            guard eventWindow === terminalView.window,
                  eventWindow.firstResponder === (persistentHistory?.textView ?? terminalHostView.scrollModeView as NSView?)
            else { return false }
        }

        let action = TerminalScrollModeKeyAction(
            event: event,
            awaitingSecondG: isAwaitingSecondScrollModeG
        )
        isAwaitingSecondScrollModeG = false

        switch action {
        case .exit:
            exitScrollMode()
        case .cancel:
            if (persistentHistory?.cancelSelection() ?? terminalHostView.scrollModeView?.cancelSelection()) != true { exitScrollMode() }
        case let .move(movement):
            if let persistentHistory { persistentHistory.move(movement) } else { terminalHostView.scrollModeView?.move(movement) }
        case let .select(linewise):
            if let persistentHistory { persistentHistory.toggleSelection(linewise: linewise) } else { terminalHostView.scrollModeView?.toggleSelection(linewise: linewise) }
        case .copy:
            if let persistentHistory { persistentHistory.copy() } else { terminalHostView.scrollModeView?.copySelection() }
        case .awaitSecondG:
            isAwaitingSecondScrollModeG = true
        case .consume:
            break
        }

        return true
    }

    func showPromptEditor(relativeTo window: NSWindow) {
        guard canAcceptInput else {
            NSSound.beep()
            return
        }

        let generation = herdrGeneration, bootID = clientShellBootID

        let textView = PromptEditorTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        let alert = NSAlert()
        alert.messageText = "Prompt Editor"
        alert.informativeText = currentWorkingDirectory.map { "Current directory: \($0)" }
            ?? "Current directory is not available yet."
        alert.accessoryView = scrollView
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = textView
        textView.onCancel = { [weak alert] in
            guard let alert else {
                return
            }

            alert.window.sheetParent?.endSheet(
                alert.window,
                returnCode: .alertSecondButtonReturn
            )
        }

        alert.beginSheetModal(for: window) { [weak self, textView] response in
            guard response == .alertFirstButtonReturn else {
                return
            }

            guard let self else {
                return
            }

            // A prompt opened before reconnect must not reach the replacement terminal.
            guard self.herdrGeneration == generation, self.clientShellBootID == bootID else {
                NSSound.beep()
                return
            }

            let prompt = textView.string
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSSound.beep()
                return
            }

            self.submitPrompt(prompt)
        }
    }

    @discardableResult func submitPrompt(_ prompt: String) -> Bool {
        guard canAcceptInput else { NSSound.beep(); return false }
        terminalView.window?.makeFirstResponder(terminalView)
        if herdrBinding != nil {
            guard (try? Self.persistentPromptBytes(prompt)) != nil else { NSSound.beep(); return false }
            let text = prompt.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            return sendClientShellInput([.paste(text), .key(.init(code: 1))])
        }
        terminalView.sendText(prompt + "\r")
        return true
    }

    static func persistentPromptBytes(_ prompt: String) throws -> Data {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 64 * 1024,
              !prompt.contains("\u{1B}"), !prompt.contains("\0") else { throw CLIError("Prompt must be nonempty text without escape controls, at most 64 KiB") }
        let normalized = prompt.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return Data(("\u{1B}[200~" + normalized + "\u{1B}[201~\r").utf8)
    }

    func waitForPersistentHistory() async { await historyTask?.value }

    func updateAppearance() {
        terminalHostView.updateAppearance()
    }

    func applyTerminalSettings() {
        if herdrBinding != nil {
            clientShellHostColorEpoch += 1
            clientShellRenderer.reset()
            clientShellDisplayError = nil
        }
        persistentHistory?.applySettings()
        let _ = terminalController.setTheme(TerminalDefaults.theme)
        let _ = terminalController.setTerminalConfiguration(
            Self.terminalConfiguration(
                for: id,
                workingDirectory: currentWorkingDirectory,
                scrollMode: isScrollModeActive && herdrBinding == nil,
                clientShell: herdrBinding != nil
            )
        )
    }

    var debugBorderColor: NSColor {
        terminalHostView.debugBorderColor
    }

    var debugBorderWidth: CGFloat {
        terminalHostView.debugBorderWidth
    }

    var debugUsesHiddenWindowPresentation: Bool {
        terminalHostView.debugUsesHiddenWindowPresentation
    }

    var debugVibrancyBlendingMode: NSVisualEffectView.BlendingMode {
        terminalHostView.debugVibrancyBlendingMode
    }

    var debugVibrancyTintAlpha: CGFloat? {
        terminalHostView.debugVibrancyTintAlpha
    }

    var debugTerminalFrame: NSRect {
        terminalHostView.debugTerminalFrame
    }

    var debugTerminalPadding: CGFloat {
        terminalHostView.debugTerminalPadding
    }

    var debugPaneBounds: NSRect {
        terminalHostView.debugPaneBounds
    }

    var debugRenderedTerminalConfig: String {
        terminalController.renderedConfig
    }

    var debugScrollModeIndicatorIsVisible: Bool {
        terminalHostView.debugScrollModeIndicatorIsVisible
    }

    var debugScrollModeIndicatorFrames: (background: NSRect, label: NSRect) {
        terminalHostView.debugScrollModeIndicatorFrames
    }

    private static func terminalConfiguration(
        for paneID: PaneID,
        workingDirectory: String?,
        scrollMode: Bool = false,
        clientShell: Bool = false,
        launchCommand: String? = nil
    ) -> TerminalConfiguration {
        TerminalConfiguration(startingFrom: TerminalDefaults.configuration) { builder in
            if let launchCommand { builder.withCustom("command", launchCommand) }
            if clientShell {
                builder.withCustom("window-padding-x", "0")
                builder.withCustom("window-padding-y", "0")
                builder.withCustom("window-padding-balance", "false")
            }
            if scrollMode {
                // Synthetic selection gestures must never reach the running app,
                // activate links or move the shell's input cursor.
                builder.withCustom("mouse-reporting", "false")
                builder.withCustom("cursor-click-to-move", "false")
                builder.withCustom("copy-on-select", "false")
                builder.withCustom("link-url", "false")
            }
            if let workingDirectory {
                builder.withCustom("working-directory", workingDirectory)
            }
            builder.withCustom("env", "SANTTY_PANE_ID=\(paneID.uuidString)")
            builder.withCustom("env", "SANTTY_CONTROL_SOCKET=\(CLITransport.socketPath)")
        }
    }
}

private final class PromptEditorTextView: NSTextView {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode != 53 else {
            onCancel?()
            return
        }

        super.keyDown(with: event)
    }
}

extension TerminalPaneController: TerminalSurfaceClipboardWriteDelegate {
    func terminalShouldWriteClipboard(afterConfirmation: Bool) -> Bool {
        guard herdrBinding != nil else { return true }
        guard clientShellIsPresented, clientShellSurfaceAttached, let window = terminalView.window,
              window.firstResponder === terminalView else { return false }
        return window.isKeyWindow || afterConfirmation
    }
}

extension TerminalPaneController: TerminalSurfaceTitleDelegate {
    func terminalDidChangeTitle(_ title: String) {
        if !title.isEmpty {
            lastKnownTitle = title
        }

        onTitleChange?(id)
    }
}

extension TerminalPaneController: TerminalSurfaceResizeDelegate {
    func terminalDidResize(columns _: Int, rows _: Int) {
        terminalHostView.scrollModeView?.needsLayout = true
    }
}

extension TerminalPaneController: TerminalSurfaceLifecycleDelegate {
    func terminalDidAttachSurface(_: TerminalSurface) {
        clientShellSurfaceAttached = true
        invalidateClientShellSurface()
    }
    func terminalDidDetachSurface() {
        clientShellSurfaceAttached = false
        invalidateClientShellSurface()
    }

    private func invalidateClientShellSurface() {
        guard herdrBinding != nil else { return }
        clientShellFeedback?.invalidateViewport()
        clientShellHostColorEpoch += 1
        clientShellFeedback?.resetHostColorQueries()
        clientShellRenderer.reset()
        clientShellDisplayError = nil
        clientShellBootID = nil
        clientShellPressedKeys.removeAll(); clientShellPressedButtons.removeAll()
        clientShellWheelX = 0; clientShellWheelY = 0
        terminalView.unmarkText()
        guard clientShellIsPresented else { return }
        do { try clientShellSession?.invalidatePresentation() }
        catch {
            clientShellSession?.disconnect()
            clientShellDisplayError = error.localizedDescription
            applyClientShellState(.failed(error.localizedDescription))
        }
    }
}

extension TerminalPaneController: TerminalScrollViewportDelegate {
    func terminalDidScroll(_ viewport: TerminalScrollViewport) {
        terminalHostView.scrollModeView?.updateViewport(viewport)
    }
}

extension TerminalPaneController: TerminalSurfacePwdDelegate {
    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard herdrBinding == nil else { return }
        currentWorkingDirectory = path
    }
}

extension TerminalPaneController: TerminalSurfaceCloseDelegate {
    func terminalDidClose(processAlive _: Bool) {
        guard isLive else {
            return
        }

        isLive = false
        exitScrollMode()
        onExit?(id)
    }
}

extension TerminalPaneController: TerminalSurfaceFocusDelegate {
    func terminalDidChangeFocus(_ focused: Bool) {
        guard focused, !isFloating else {
            return
        }

        onFocusRequest?(id)
    }
}

enum TerminalScrollModeKeyAction: Equatable {
    case exit
    case cancel
    case move(TerminalScrollMovement)
    case select(linewise: Bool)
    case copy
    case awaitSecondG
    case consume

    init(event: NSEvent, awaitingSecondG: Bool) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 || event.characters == "\u{1b}" {
            self = .cancel
            return
        }

        if modifiers.isEmpty, key == "q" || key == "i" || event.keyCode == 36 {
            self = .exit
            return
        }

        if awaitingSecondG {
            if modifiers.isEmpty, key == "g" {
                self = .move(.top)
                return
            }
        }

        switch (modifiers, key, event.keyCode) {
        case ([], "h", _), ([], _, 123): self = .move(.left)
        case ([], "l", _), ([], _, 124): self = .move(.right)
        case ([], "j", _), ([], _, 125): self = .move(.down)
        case ([], "k", _), ([], _, 126): self = .move(.up)
        case ([], "0", _): self = .move(.lineStart)
        case ([.shift], "^", _), ([.shift], "6", _), ([], "^", _): self = .move(.firstNonblank)
        case ([], "w", _): self = .move(.wordForward(big: false))
        case ([], "b", _): self = .move(.wordBackward(big: false))
        case ([], "e", _): self = .move(.wordEnd(big: false))
        case ([.shift], "w", _): self = .move(.wordForward(big: true))
        case ([.shift], "b", _): self = .move(.wordBackward(big: true))
        case ([.shift], "e", _): self = .move(.wordEnd(big: true))
        case ([.shift], "$", _), ([.shift], "4", _), ([], "$", _): self = .move(.lineEnd)
        case ([], "v", _): self = .select(linewise: false)
        case ([.shift], "v", _): self = .select(linewise: true)
        case ([], "y", _), ([.command], "c", _): self = .copy
        case ([.control], "d", _):
            self = .move(.halfDown)
        case ([.control], "u", _):
            self = .move(.halfUp)
        case ([.control], "f", _), ([], _, 121):
            self = .move(.pageDown)
        case ([.control], "b", _), ([], _, 116):
            self = .move(.pageUp)
        case ([.shift], "g", _), ([], _, 119):
            self = .move(.bottom)
        case ([], "g", _):
            self = .awaitSecondG
        case ([], _, 115):
            self = .move(.top)
        default:
            self = .consume
        }
    }
}

enum ProcessWorkingDirectoryResolver {
    static func workingDirectory(for processID: Int32) -> String? {
        guard processID > 0 else {
            return nil
        }

        var pathInfo = proc_vnodepathinfo()
        let expectedByteCount = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let byteCount = proc_pidinfo(
            processID,
            PROC_PIDVNODEPATHINFO,
            0,
            &pathInfo,
            expectedByteCount
        )
        guard byteCount == expectedByteCount else {
            return nil
        }

        let path: String? = withUnsafeBytes(of: pathInfo.pvi_cdir.vip_path) { pathBytes in
            guard let baseAddress = pathBytes.baseAddress else {
                return nil
            }

            return String(
                validatingCString: baseAddress.assumingMemoryBound(to: CChar.self)
            )
        }
        guard let path, !path.isEmpty else {
            return nil
        }

        return path
    }
}
