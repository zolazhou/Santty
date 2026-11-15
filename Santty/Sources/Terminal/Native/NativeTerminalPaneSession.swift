import Foundation

/// One pane's transport/process owner. This does not own a workspace registry,
/// authorization journal, user directories, or a Herdr core daemon.
@MainActor
final class NativeTerminalPaneSession {
    typealias CloseIntent = PaneCloseIntent
    enum Failure: Error, Equatable {
        case closed, invalidViewport, invalidViewer, driverMismatch, frontendBusy, conflictingCloseIntent, resizeRefused
    }
    enum Directory {
        case local(String)
        case herdr(String, remote: HerdrRemote?)
    }
    private enum Backend {
        case local(NativeLocalPTYSession, NativeLocalPTYLaunch)
        case herdr(HerdrTerminalSession, requestedDirectory: String?)
    }
    let paneID: UUID
    let driver: GhosttyVTDriver
    let output: NativeTerminalOutput
    private let reader: NativeTerminalReadService
    private let backend: Backend
    private(set) var hasStarted = false
    private(set) var isClosing = false
    private(set) var isClosed = false
    private(set) var metadata = NativeTerminalMetadata()
    private(set) var lastCloseError: (any Error)?
    private var closeIntent: CloseIntent?
    private var cleanup: Task<Void, Error>?
    private weak var frontend: NativeTerminalFrontend?
    private var frontendToken: UUID?
    var onChange: (() -> Void)?
    var onPresentation: ((Bool) -> Void)?
    var onReset: (() -> Void)?

    private init(paneID: UUID, driver: GhosttyVTDriver, output: NativeTerminalOutput, backend: Backend) {
        self.paneID = paneID; self.driver = driver; self.output = output; self.backend = backend
        reader = NativeTerminalReadService(paneID:paneID,driver:driver)
        metadata = driver.metadata
        output.onMetadataChange = { [weak self] metadata in
            guard let self else { return }
            self.metadata = metadata; self.changed()
        }
    }

    static func local(launch: NativeLocalPTYLaunch, driver: GhosttyVTDriver) -> NativeTerminalPaneSession {
        let relay = NativePanePresentationRelay()
        let local = NativeLocalPTYSession(paneID:launch.paneID,driver:driver) { relay.owner?.parsedOutput(reset:$0) }
        let owner = NativeTerminalPaneSession(paneID:launch.paneID,driver:driver,output:local.output,backend:.local(local,launch))
        relay.owner = owner
        local.onStateChange = { [weak owner] _ in owner?.changed() }
        return owner
    }

    /// beforeRun is deliberately required: production must persist pending-run
    /// identity before sending. Tests supply an explicit private-fixture policy.
    static func herdr(paneID: UUID, driver: GhosttyVTDriver, client: HerdrCoreClient,
                      workingDirectory: String?, binding: HerdrTerminalBinding?, remote: HerdrRemote? = nil,
                      runPending: Bool = false, viewerOnly: Bool = false, controlSocketPath: String? = nil,
                      beforeRun: @escaping @MainActor () async throws -> Void) throws -> NativeTerminalPaneSession {
        guard !viewerOnly || binding != nil else { throw Failure.invalidViewer }
        let relay = NativePanePresentationRelay()
        let output = NativeTerminalOutput(driver:driver) { relay.owner?.parsedOutput(reset:$0) }
        let session = HerdrTerminalSession(paneID:paneID,cwd:workingDirectory,binding:binding,remote:remote,
            runPending:runPending,viewerOnly:viewerOnly,client:client,outputFactory:{ _,_ in output },
            controlSocketPath:remote == nil ? controlSocketPath : nil,displayColors:{ driver.displayColors })
        output.bindChecked { [weak session] data in session?.writeInput(data) ?? false }
        _ = session.output // exact endpoint is installed before restoration/replies
        let owner = NativeTerminalPaneSession(paneID:paneID,driver:driver,output:output,
            backend:.herdr(session,requestedDirectory:workingDirectory))
        relay.owner = owner
        session.beforeRun = beforeRun
        session.onChange = { [weak owner] in owner?.changed() }
        session.onReset = { [weak owner] in
            owner?.frontend?.resetPresentation(); owner?.onReset?()
        }
        return owner
    }

    var localLaunch: NativeLocalPTYLaunch? { if case let .local(_,launch) = backend { return launch }; return nil }
    var localSession: NativeLocalPTYSession? { if case let .local(session,_) = backend { return session }; return nil }
    var herdrSession: HerdrTerminalSession? { if case let .herdr(session,_) = backend { return session }; return nil }
    var acceptsInput: Bool {
        guard hasStarted, !isClosing, !isClosed else { return false }
        switch backend {
        case let .local(session,_): return session.state.acceptsInput
        case let .herdr(session,_): return session.state == .live
        }
    }
    var title: String {
        if let title = herdrSession?.record?.title, !title.isEmpty { return title }
        return metadata.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Shell"
    }
    /// Raw OSC pwd remains metadata, never remote/local path authority.
    /// Resolve Local process facts only for an explicit inheritance request.
    var directoryForNewPane: Directory? {
        switch backend {
        case let .local(session,launch): return .local(session.processInfo?.workingDirectory ?? launch.workingDirectory)
        case let .herdr(session,requested):
            let path = session.record?.foreground?.cwd ?? session.record?.cwd ?? requested
            return path.map { .herdr($0,remote:session.remote) }
        }
    }

    func startIfNeeded(viewport: TerminalStreamViewport) throws {
        guard !isClosing, !isClosed else { throw Failure.closed }
        guard !hasStarted else { return }
        guard viewport.columns > 0, viewport.rows > 0 else { throw Failure.invalidViewport }
        hasStarted = true // an exec failure must not turn a second start into a new process
        do {
            switch backend {
            case let .local(session,launch): try session.start(launch,viewport:viewport)
            case let .herdr(session,_):
                try resizeDriver(viewport)
                session.updateViewport(viewport)
                // Endpoint readiness is permanent, not NSView attachment.
                session.surfaceAttached(); session.start()
            }
            changed()
        } catch { changed(); throw error }
    }
    func updateViewport(_ viewport: TerminalStreamViewport) throws {
        guard !isClosing, !isClosed else { return }
        guard viewport.columns > 0, viewport.rows > 0 else { throw Failure.invalidViewport }
        switch backend {
        case let .local(session,_):
            if !session.updateViewport(viewport), session.state.acceptsInput { throw Failure.resizeRefused }
        case let .herdr(session,_): try resizeDriver(viewport); session.updateViewport(viewport)
        }
    }
    private func resizeDriver(_ viewport: TerminalStreamViewport) throws {
        let cell = driver.cellSizePixels
        if driver.columns != Int(viewport.columns) || driver.rows != Int(viewport.rows)
            || cell.width != viewport.cellWidthPixels || cell.height != viewport.cellHeightPixels {
            output.sendAutomaticReplies(try driver.resize(columns:Int(viewport.columns),rows:Int(viewport.rows),
                cellWidth:viewport.cellWidthPixels,cellHeight:viewport.cellHeightPixels))
        }
    }
    func setFocused(_ focused: Bool) { if !isClosing { herdrSession?.setFocused(focused) } }
    func updateDisplay() { if !isClosing { herdrSession?.updateDisplay() } }
    func retryConnection() {
        guard !isClosing, !isClosed else { return }
        herdrSession?.retry() // Local never reconnects/relaunches
    }

    /// Caller must check controller AND session ownership. A same-UUID
    /// replacement is not this driver; never retry or resolve another pane.
    func read(_ request: CLIRequest, isCurrent: @MainActor () -> Bool) async throws -> CLIResponse {
        func check() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw CLIError("Pane changed while reading terminal content.",code:"pane_changed") }
        }
        try check()
        let response: CLIResponse
        do { response = try await reader.response(request) }
        catch { try check(); throw error }
        try check(); return response
    }

    private func normalized(_ intent: CloseIntent) -> CloseIntent {
        if localSession != nil { return .terminate }
        if herdrSession?.viewerOnly == true { return .detach }
        return intent
    }
    func validateClose(_ intent: CloseIntent) throws {
        if let closeIntent, closeIntent != normalized(intent) { throw Failure.conflictingCloseIntent }
    }
    func beginClosing(_ intent: CloseIntent) throws {
        try validateClose(intent)
        closeIntent = normalized(intent); isClosing = true
        output.setInputEnabled(false)
        localSession?.beginClosing()
        changed()
    }
    /// Independently retained cleanup, coalesced by owner and intent. Caller
    /// cancellation never abandons cleanup; failure retains this owner/layout.
    func close(_ intent: CloseIntent) async throws {
        try validateClose(intent)
        if let cleanup { return try await cleanup.value }
        guard !isClosed else { return }
        try beginClosing(intent)
        let effective = normalized(intent)
        let operation = Task {
            do {
                switch backend {
                case let .local(session,_): try await session.stop()
                case let .herdr(session,_):
                    if effective == .detach { await session.detachViewer() }
                    else { try await session.closeTerminal() }
                }
                isClosed = true; lastCloseError = nil; changed()
            } catch { cleanup = nil; lastCloseError = error; changed(); throw error }
        }
        cleanup = operation
        try await operation.value
    }

    func install(_ frontend: NativeTerminalFrontend, token: UUID) throws {
        guard frontendToken == nil else { throw Failure.frontendBusy }
        self.frontend = frontend; frontendToken = token
    }
    func ownsFrontend(_ token: UUID) -> Bool { frontendToken == token }
    func removeFrontend(_ token: UUID) {
        guard frontendToken == token else { return }
        frontend = nil; frontendToken = nil
    }
    func refreshMetadata() { metadata = driver.metadata; changed() }

    private func changed() {
        if herdrSession != nil || isClosing { output.setInputEnabled(acceptsInput) }
        frontend?.stateChanged()
        onChange?()
    }
    private func parsedOutput(reset: Bool) {
        frontend?.parsedOutput(reset:reset)
        onPresentation?(reset)
    }
}

@MainActor
private final class NativePanePresentationRelay {
    weak var owner: NativeTerminalPaneSession?
}
