import AppKit

/// One checked view binding to one process/transport owner. Detaching a view
/// never disconnects a Herdr viewer or closes a Local process.
@MainActor
final class NativeTerminalFrontend {
    let session: NativeTerminalPaneSession
    let view: NativeTerminalScrollView
    private let token = UUID()
    private let isCurrent: @MainActor () -> Bool
    private var detached = false
    private(set) var lastError: (any Error)?
    var onChange: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    init(session: NativeTerminalPaneSession, view: NativeTerminalScrollView,
         isCurrent: @escaping @MainActor () -> Bool) throws {
        guard session.driver === view.driver else { throw NativeTerminalPaneSession.Failure.driverMismatch }
        guard view.renderer.output == nil else { throw NativeTerminalPaneSession.Failure.frontendBusy }
        self.session = session; self.view = view; self.isCurrent = isCurrent
        try session.install(self,token:token)
        view.renderer.output = session.output
        view.renderer.onFocusChange = { [weak self] focused in
            guard let self, bound else { return }
            session.setFocused(focused)
            onFocusChange?(focused)
        }
        view.onViewportChange = { [weak self] viewport in
            guard let self, bound else { return }
            do { try session.updateViewport(viewport) } catch { lastError = error }
        }
        view.onAutomaticReplies = { [weak self] bytes in
            guard let self, bound else { return }; session.output.sendAutomaticReplies(bytes)
        }
        view.onSettingsChange = { [weak self] in
            guard let self, bound else { return }; session.updateDisplay()
        }
        stateChanged()
    }
    isolated deinit { detach() }

    private var ownsBinding: Bool {
        !detached && session.ownsFrontend(token) && view.renderer.output === session.output
    }
    var bound: Bool { ownsBinding && isCurrent() }
    func startIfNeeded() throws {
        guard bound else { throw NativeTerminalPaneSession.Failure.closed }
        // Initial real layout before declaring the endpoint ready.
        let viewport = try view.synchronizeViewport()
        try session.startIfNeeded(viewport:viewport)
    }
    func applySettings(_ settings: NativeTerminalSettings, relayout: () -> Void = {}) throws {
        guard bound else { throw NativeTerminalPaneSession.Failure.closed }
        view.hostActions.zoomResetSize = settings.fontSize
        try view.applySettings(settings,relayout:relayout)
    }
    func stateChanged() {
        guard bound else { return }
        view.renderer.inputEnabled = session.acceptsInput
        if !session.acceptsInput {
            view.hostActions.invalidateReview()
            view.scrollModeController.exit()
            view.renderer.resetInputState()
        }
        // Reflect actual responder/key-window state; never makeFirstResponder.
        view.renderer.refreshFocus()
        onChange?()
    }
    func parsedOutput(reset: Bool) {
        guard bound else { return }
        view.parsedOutput(reset:reset)
    }
    func resetPresentation() {
        guard bound else { return }
        view.resetPresentation()
    }
    func read(_ request: CLIRequest) async throws -> CLIResponse {
        try await session.read(request,isCurrent:{ [self] in bound })
    }
    func detach() {
        guard !detached else { return }
        if ownsBinding {
            view.hostActions.invalidateReview()
            view.scrollModeController.exit()
            view.renderer.inputEnabled = false
            view.renderer.resetInputState()
            view.renderer.refreshFocus()
            view.renderer.output = nil
            view.renderer.onFocusChange = nil
            view.onViewportChange = nil; view.onAutomaticReplies = nil; view.onSettingsChange = nil
        }
        session.removeFrontend(token)
        detached = true
    }
}
