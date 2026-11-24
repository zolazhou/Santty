import AppKit
import GhosttyVt

@MainActor
final class TerminalPaneController: NSObject, PaneControlling {
    let id: PaneID
    let session: NativeTerminalPaneSession?
    let terminalView: NativeTerminalScrollView?
    private let terminalHostView: TerminalPaneHostView
    private var frontend: NativeTerminalFrontend?
    private var inputSourcePort: NativeTerminalInputSourcePort?
    var nativeInputSourceTarget: PaneInputSourceCoordinator.Target? { inputSourcePort?.target }
    let closeHandle: PaneCloseHandle
    var herdrSession: HerdrTerminalSession? { session?.herdrSession }
    var hostView: NSView { terminalHostView }
    private var requestedStart = false
    private var starting = false
    private var initializationError: String?
    private var lastAppliedSettings: NativeTerminalSettings?
    private var lastRequestedRenderingEngine: TerminalSettings.RenderingEngine?
    private(set) var renderingWarning: String?
    var renderingEngine: TerminalSettings.RenderingEngine? {
        terminalView.map { $0.renderer.isUsingMetalRenderer ? .metal : .coreGraphics }
    }
    private var paneIsFocused = false
    private var isFloating = false
    private var wasLive = true
    private var wasAcceptingInput = false
    private var testingExited = false
    var isCurrent: () -> Bool = { true }
    var onFocusRequest: ((PaneID) -> Void)? { didSet { terminalHostView.onFocusRequest = onFocusRequest } }
    var onTitleChange: ((PaneID) -> Void)?
    var onExit: ((PaneID) -> Void)?
    var name: String? { didSet { terminalHostView.nameBadge.name = name } }
    var hasStarted: Bool { session?.hasStarted == true }
    var isScrollModeActive: Bool { terminalView?.scrollModeController.isActive == true }
    var isLive: Bool {
        guard !testingExited, initializationError == nil, let session, !session.isClosed else { return false }
        if let herdr = session.herdrSession { return herdr.state != .finished }
        switch session.localSession?.state {
        case .exited, .outputIncomplete, .failed: return false
        default: return true
        }
    }
    var lastKnownTitle: String { session?.title ?? "Shell" }
    private(set) var currentWorkingDirectory: String?
    var workingDirectoryForNewPane: String? {
        if session?.localSession != nil, let pid = foregroundProcessIDProvider?(), let path = processWorkingDirectoryProvider?(pid), !path.isEmpty { return path }
        if let local = session?.localSession { return local.processInfo?.workingDirectory ?? currentWorkingDirectory ?? {
            if case let .local(path) = session?.directoryForNewPane { return path }; return nil
        }() }
        guard let directory = session?.directoryForNewPane else { return currentWorkingDirectory }
        switch directory { case let .local(path), let .herdr(path,_): return path }
    }
    /// Real Local group, never a shell PID or a remote PID interpreted locally.
    var foregroundProcessID: Int? { session?.localSession?.processInfo?.foregroundProcessGroupID.map(Int.init) }
    var displayTitle: String {
        if let initializationError { return initializationError }
        if let state = herdrSession?.state {
            switch state {
            case .connecting: return lastKnownTitle+" (Connecting)"
            case .disconnected: return lastKnownTitle+" (Disconnected)"
            case let .failed(message): return message
            default: break
            }
        }
        return isLive ? lastKnownTitle : lastKnownTitle+" (Exited)"
    }
    var focusTargetView: NSView { hasStarted || session?.acceptsInput == true ? terminalView?.renderer ?? terminalHostView : terminalHostView }
    var inputSourceTargetView: NSView? {
        guard isLive, !isScrollModeActive, session?.acceptsInput == true else { return nil }
        return terminalView?.renderer
    }
    private let renderingEngineProvider: @MainActor () -> TerminalSettings.RenderingEngine
    private let configureRenderer: @MainActor (NativeTerminalScrollView, TerminalSettings.RenderingEngine) throws -> Void
    private let openURL: @MainActor (URL) -> Bool
    private let foregroundProcessIDProvider: (@MainActor () -> Int32?)?
    private let processWorkingDirectoryProvider: ((Int32) -> String?)?

    init(id: PaneID = UUID(), workingDirectory: String? = nil, session supplied: NativeTerminalPaneSession? = nil,
         initializationError suppliedError: (any Error)? = nil, resourceCloseHandle: PaneCloseHandle? = nil,
         foregroundProcessIDProvider: (@MainActor () -> Int32?)? = nil,
         processWorkingDirectoryProvider: ((Int32) -> String?)? = nil,
         renderingEngineProvider: @escaping @MainActor () -> TerminalSettings.RenderingEngine = { TerminalSettings.renderingEngine },
         configureRenderer: @escaping @MainActor (NativeTerminalScrollView, TerminalSettings.RenderingEngine) throws -> Void = { view, engine in try view.setMetal(engine == .metal) },
         openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.id = id; self.openURL = openURL
        self.renderingEngineProvider = renderingEngineProvider; self.configureRenderer = configureRenderer
        self.foregroundProcessIDProvider = foregroundProcessIDProvider; self.processWorkingDirectoryProvider = processWorkingDirectoryProvider
        currentWorkingDirectory = workingDirectory
        var owner = supplied, problem = suppliedError
        if owner == nil, problem == nil {
            do {
                let driver = try GhosttyVTDriver()
                let launch = try NativeLocalPTYLaunch.productionLocal(paneID:id,controlSocket:CLITransport.socketPath,
                    context:.current(),workingDirectory:workingDirectory,
                    appVersion:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0")
                owner = .local(launch:launch,driver:driver)
            } catch { problem = error }
        }
        precondition(owner == nil || owner?.paneID == id)
        self.session = owner
        initializationError = problem.map { "Terminal unavailable: \($0.localizedDescription)" }
        terminalView = owner.map { NativeTerminalScrollView(driver:$0.driver,frame:.init(x:0,y:0,width:720,height:480)) }
        terminalHostView = TerminalPaneHostView(paneID:id,terminalView:terminalView)
        precondition(resourceCloseHandle == nil || resourceCloseHandle?.id == id)
        closeHandle = resourceCloseHandle ?? PaneCloseHandle(id:id,policy:.awaitedOwner,
            hasResources:{ owner?.hasStarted == true || owner?.herdrSession?.binding != nil || owner?.herdrSession?.createResultUnknown == true },
            normalize:{ owner?.herdrSession?.viewerOnly == true ? .detach : owner?.localSession != nil ? .terminate : $0 },
            validateOwner:{ try owner?.validateClose($0) },suspend:{ try? owner?.beginClosing($0) },operation:{ intent in try await owner?.close(intent) })
        super.init()
        terminalHostView.paneController = self
        if let owner, let terminalView {
            do {
                frontend = try NativeTerminalFrontend(session:owner,view:terminalView,isCurrent:{ [weak self] in self?.isCurrent() == true })
                frontend?.onFocusChange = { [weak self] focused in self?.reflectTerminalFocus(focused) }
                inputSourcePort = NativeTerminalInputSourcePort(paneID:id,view:terminalView,
                    isCurrent:{ [weak self] in self?.isCurrent() == true },foreground:{ [weak self] in
                        guard let self else { throw CLIError("Pane changed") }; return try await self.inputSourceForeground()
                    })
                try applySettings()
                terminalView.openLink = openURL
            } catch { initializationError = "Terminal unavailable: \(error.localizedDescription)" }
            owner.onChange = { [weak self] in self?.stateChanged() }
            terminalHostView.onGeometryChange = { [weak self] in self?.startWhenReady() }
        }
        terminalHostView.onFocusRequest = { [weak self] id in self?.onFocusRequest?(id) }
        updatePresentation(isFocused:false)
    }
    isolated deinit { frontend?.detach() } // process cleanup is an awaited close transaction, never a view free/join

    func startIfNeeded() { requestedStart = true; startWhenReady() }
    private func startWhenReady() {
        guard requestedStart, !hasStarted, !starting, !closeHandle.hasBegun, isCurrent(), let frontend else { return }
        starting = true; defer { starting = false }
        do { try frontend.startIfNeeded(); initializationError = nil }
        catch NativeTerminalScrollView.GeometryError.unavailable { return }
        catch { initializationError = "Terminal unavailable: \(error.localizedDescription)" }
        stateChanged()
    }
    func fitToSize() {
        guard let terminalView else { return }
        if requestedStart, !hasStarted { startWhenReady() }
        else { _ = try? terminalView.synchronizeViewport(); terminalView.presentPendingOutput() }
    }
    func setNameVisible(_ visible: Bool) { terminalHostView.nameBadge.isRevealed = visible }
    func updatePresentation(isFocused: Bool,isFloating: Bool = false) {
        paneIsFocused = isFocused; self.isFloating = isFloating
        terminalHostView.updatePresentation(isFocused:isFocused,isFloating:isFloating,
            isLive:isLive && (session?.acceptsInput == true || !hasStarted),displayTitle:displayTitle,
            renderingWarning:renderingWarning)
    }
    private func stateChanged() {
        guard isCurrent() else { return }
        if let record = herdrSession?.record { currentWorkingDirectory = record.foreground?.cwd ?? record.cwd }
        terminalHostView.setRetryAction(herdrSession?.state == .disconnected || {
            if case .failed = herdrSession?.state { return true }; return false
        }() ? { [weak self] in self?.session?.retryConnection() } : nil)
        let acceptsInput = session?.acceptsInput == true
        if acceptsInput, !wasAcceptingInput, isCurrent(), paneIsFocused,
           let view = terminalView, let window = view.window, window.firstResponder === terminalHostView {
            // Finish an explicit focus request that landed on our own loading
            // host. Metadata, reconnects and other responders cannot gain focus.
            window.makeFirstResponder(view.renderer)
        }
        wasAcceptingInput = acceptsInput
        if wasLive, !isLive { terminalView?.scrollModeController.exit(); if !closeHandle.hasBegun { onExit?(id) } }
        wasLive = isLive
        updatePresentation(isFocused:paneIsFocused,isFloating:isFloating)
        onTitleChange?(id)
    }
    private func applySettings() throws {
        guard let frontend else { return }
        let next = try TerminalDefaults.settings()
        if next != lastAppliedSettings {
            try frontend.applySettings(next) { [weak self] in self?.terminalHostView.updateAppearance() }
            lastAppliedSettings = next
        }
        applyRenderingEngine()
    }
    private func applyRenderingEngine() {
        let requested = renderingEngineProvider()
        guard let terminalView, requested != lastRequestedRenderingEngine else { return }
        lastRequestedRenderingEngine = requested
        do {
            if requested != renderingEngine { try configureRenderer(terminalView, requested) }
            renderingWarning = nil
        } catch {
            // A presentation failure must not become a session failure/onExit.
            // Do not retry on every font/theme/layout notification.
            renderingWarning = "Unable to switch to \(requested.title). Using \(renderingEngine?.title ?? "Core Graphics")."
        }
        updatePresentation(isFocused: paneIsFocused, isFloating: isFloating)
    }
    func applyTerminalSettings() { guard isCurrent() else { return }; do { try applySettings() } catch { initializationError = error.localizedDescription; stateChanged() } }
    func updateAppearance() { terminalHostView.updateAppearance(); if isCurrent() { applyTerminalSettings() } }
    func copySelection(_ sender: Any?) { terminalHostView.copy(sender) }
    func readForCLI(_ request: CLIRequest, isCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> CLIResponse {
        guard let session else { throw CLIError("Terminal content unavailable.",code:"read_unavailable") }
        return try await session.read(request,isCurrent:{ [weak self] in self?.isCurrent() == true && isCurrent() })
    }
    func sendForCLI(_ request: CLIRequest) throws {
        guard isCurrent(), isLive, !closeHandle.hasBegun, !isScrollModeActive, terminalView?.renderer.hasMarkedText() == false,
              let session, session.acceptsInput else { throw CLIError("Terminal is not ready for input. Input was not queued.",code:"input_unavailable") }
        let accepted: Bool
        if request.command == "pane.send-text" { accepted = try session.output.paste(request.text ?? "") }
        else { accepted = try session.output.send(NativeTerminalNamedKey.event(CLIKey(request.key ?? ""))) }
        guard accepted else { throw CLIError("Terminal did not accept input.",code:"input_unavailable") }
    }
    func enterScrollMode() {
        guard isLive, let terminalView else { return }
        if terminalView.scrollModeController.enter() { terminalView.window?.makeFirstResponder(terminalView.renderer) }
    }
    func exitScrollMode() { terminalView?.scrollModeController.exit() }
    func handleScrollModeKeyEvent(_ event: NSEvent) -> Bool { terminalView?.scrollModeController.keyDown(event) ?? false }
    func inputSourceForeground() async throws -> InputSourceForeground {
        if session?.localSession != nil, let group = foregroundProcessIDProvider?(), group > 0 {
            let processes = await Task.detached(priority:.utility) { TerminalProcessInspector.currentProcessTable(processGroupID:group) }.value
            try Task.checkCancellation()
            guard isCurrent(), foregroundProcessIDProvider?() == group else { throw CLIError("Foreground changed") }
            return .init(groupID:Int(group),processes:processes.map { .init(id:$0.processID,name:$0.executableName ?? "",command:$0.command) })
        }
        guard let session, session.acceptsInput else { throw CLIError("Foreground information unavailable") }
        if let herdr = session.herdrSession {
            guard let foreground = herdr.record?.foreground else { throw CLIError("Core foreground information unavailable") }
            return .init(groupID:Int(foreground.pid),processes:[.init(id:Int(foreground.pid),name:foreground.name,command:foreground.name)])
        }
        guard let local = session.localSession, let before = local.processInfo,
              let group = before.foregroundProcessGroupID else { throw CLIError("Owned foreground group unavailable") }
        let processes = await Task.detached(priority:.utility) {
            TerminalProcessInspector.currentProcessTable(processGroupID:group).map {
                InputSourceForeground.Process(id:$0.processID,name:$0.executableName ?? "",command:$0.command)
            }
        }.value
        try Task.checkCancellation()
        guard let after = local.processInfo, before.shellPid == after.shellPid,
              after.foregroundProcessGroupID == group else { throw CLIError("Foreground changed during lookup") }
        return .init(groupID:Int(group),processes:processes)
    }
    func simulateExitForTesting() { testingExited = true; session?.output.setInputEnabled(false); stateChanged() }
    func reflectTerminalFocus(_ focused: Bool) { if focused, !isFloating { onFocusRequest?(id) } }
    func setTitleForTesting(_ title: String) {
        session?.output.receive(Data(("\u{1b}]2;"+title+"\u{7}").utf8)); session?.refreshMetadata()
    }
    func setWorkingDirectoryForTesting(_ path: String) { currentWorkingDirectory = path }
    static func linkURL(_ text: String) -> URL? { NativeTerminalLink.url(text) }
    func terminalDidRequestOpenURL(_ text: String) { if let url = Self.linkURL(text) { _ = openURL(url) } }
    @discardableResult func submitPrompt(_ prompt: String, expected: NativeUserInputLease? = nil) -> Bool {
        guard isCurrent(), !closeHandle.hasBegun, !prompt.isEmpty, !isScrollModeActive, let session, session.acceptsInput,
              terminalView?.renderer.hasMarkedText() == false,
              expected == nil || session.output.userInputLease == expected else { return false }
        terminalView?.window?.makeFirstResponder(terminalView?.renderer)
        guard (try? session.output.paste(prompt)) == true else { return false }
        return (try? session.output.sendKey(GHOSTTY_KEY_ENTER)) == true
    }
    func showPromptEditor(relativeTo window: NSWindow) {
        guard let session, session.acceptsInput, let lease = session.output.userInputLease else { return }
        let text = PromptEditorTextView(frame:.init(x:0,y:0,width:480,height:180))
        text.font = .monospacedSystemFont(ofSize:13,weight:.regular); text.isRichText = false; text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        let scroll = NSScrollView(frame:.init(x:0,y:0,width:500,height:200)); scroll.documentView = text; scroll.hasVerticalScroller = true
        let alert = NSAlert(); alert.messageText = "Prompt Editor"; alert.accessoryView = scroll
        alert.addButton(withTitle:"Send"); alert.addButton(withTitle:"Cancel"); alert.window.initialFirstResponder = text
        text.onCancel = { [weak alert] in if let alert { alert.window.sheetParent?.endSheet(alert.window,returnCode:.alertSecondButtonReturn) } }
        alert.beginSheetModal(for:window) { [weak self,text] result in
            guard result == .alertFirstButtonReturn, !text.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  self?.submitPrompt(text.string,expected:lease) == true else { return }
        }
    }
    var debugBorderColor: NSColor { terminalHostView.debugBorderColor }
    var debugBorderWidth: CGFloat { terminalHostView.debugBorderWidth }
    var debugUsesHiddenWindowPresentation: Bool { terminalHostView.debugUsesHiddenWindowPresentation }
    var debugVibrancyBlendingMode: NSVisualEffectView.BlendingMode { terminalHostView.debugVibrancyBlendingMode }
    var debugVibrancyTintAlpha: CGFloat? { terminalHostView.debugVibrancyTintAlpha }
    var debugTerminalFrame: NSRect { terminalHostView.debugTerminalFrame }
    var debugTerminalPadding: CGFloat { terminalHostView.debugTerminalPadding }
    var debugPaneBounds: NSRect { terminalHostView.debugPaneBounds }
    var debugNativeSettings: NativeTerminalSettings? { terminalView?.settings }
    var debugScrollModeIndicatorIsVisible: Bool { terminalHostView.debugScrollModeIndicatorIsVisible }
    var debugScrollModeIndicatorFrames: (background:NSRect,label:NSRect) { terminalHostView.debugScrollModeIndicatorFrames }
}

private final class PromptEditorTextView: NSTextView {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onCancel?() } else { super.keyDown(with:event) } }
}
