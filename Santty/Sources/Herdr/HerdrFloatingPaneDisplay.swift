import AppKit

@MainActor
final class HerdrFloatingPaneDisplay {
    let pane: TerminalPaneController
    let session: HerdrClientShellSession
    private let binding: HerdrPaneBinding
    private var renderTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var pending: (HerdrShellSnapshot, HerdrShellSurface, [HerdrShellAssetKey: Data])?
    private var active = false
    private var resizing = false
    private var frozen = false
    private let initialViewport: () -> (HerdrShellSize, UInt32, UInt32)?
    private var selectingInitialTab = false
    var onFailure: ((any Error) -> Void)?

    init(record: HerdrFloatingPaneRecord, session: HerdrClientShellSession? = nil, initialViewport: @escaping () -> (HerdrShellSize, UInt32, UInt32)?) throws {
        guard let floating = record.floating else { throw CLIError("Herdr floating pane identity is missing") }
        binding = floating
        self.initialViewport = initialViewport
        let metadata = HerdrSnapshot.Pane(pane_id: binding.paneID, terminal_id: nil,
            workspace_id: binding.workspaceID, tab_id: binding.tabID, serviceIdentity: binding.serviceIdentity)
        pane = TerminalPaneController(id: record.paneID, herdr: try .init(endpoint: binding.endpoint, pane: metadata))
        self.session = session ?? HerdrClientShellSession(endpoint: binding.endpoint)
        pane.setClientShellPresented(false)
        self.session.onState = { [weak pane] in pane?.applyClientShellState($0) }
        self.session.onFailure = { [weak self] error, _ in self?.pane.setClientShellPresented(false); self?.onFailure?(error) }
        self.session.onProjection = { [weak self] snapshot, surface, assets in
            self?.pending = (snapshot, surface, assets); self?.render()
        }
    }

    func start() async throws {
        if active {
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            while !session.isPresentationReady { try check(deadline); try await Task.sleep(for: .milliseconds(20)) }
            return
        }
        active = true
        selectingInitialTab = true
        frozen = false
        if session.state == .disconnected {
            try await session.start(size: .init(cols: 1, rows: 1), cellWidth: 0, cellHeight: 0,
                focused: pane.hostView.window?.isKeyWindow == true, activateWhenMetadataReady: false)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + (binding.endpoint.machine == nil ? 12 : 40)
        while session.projection.snapshot?.tabs.contains(where: { $0.tab_id == binding.tabID }) != true {
            try check(deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
        guard session.serviceIdentity == binding.serviceIdentity else { throw CLIError("Herdr floating service changed") }
        while viewport() == nil {
            try check(deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let (size, width, height) = initialViewport() else { throw CLIError("Herdr source viewport is unavailable") }
        try session.activate(size: size, cellWidth: width, cellHeight: height)
        try await session.selectInitialTab(binding.tabID)
        selectingInitialTab = false
        resize()
        while !session.isPresentationReady {
            try check(deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func resume() {
        guard !active, startTask == nil else { return }
        startTask = Task { [weak self] in
            guard let self else { return }
            defer { self.startTask = nil }
            do { try await self.start(); self.pane.setClientShellPresented(true) }
            catch is CancellationError { }
            catch { self.onFailure?(error) }
        }
    }

    func stop() {
        active = false; startTask?.cancel(); startTask = nil
        renderTask?.cancel(); renderTask = nil; pending = nil
        pane.setClientShellPresented(false); session.disconnect(); pane.disconnectHerdr()
    }

    func freeze() {
        frozen = true; startTask?.cancel(); startTask = nil; pane.setClientShellPresented(false)
        renderTask?.cancel(); renderTask = nil; pending = nil
    }

    func resize() {
        guard active, !frozen, !selectingInitialTab, !resizing, session.projection.snapshot?.focused_tab_id == binding.tabID, let (size, width, height) = viewport() else { return }
        resizing = true; defer { resizing = false }
        do { try session.resize(size, cellWidth: width, cellHeight: height) }
        catch { onFailure?(error) }
    }

    private func viewport() -> (HerdrShellSize, UInt32, UInt32)? {
        guard pane.clientShellRenderHostView.window != nil, let metrics = pane.clientShellGridMetrics,
              metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 else { return nil }
        let scale = pane.clientShellBackingScale
        let width = pane.clientShellRenderHostView.bounds.width - TerminalSettings.padding * 2
        let height = pane.clientShellRenderHostView.bounds.height - TerminalSettings.padding * 2
        let surface = session.projection.coherentSurface
        let inner = surface?.panes.first(where: { $0.pane_id == binding.paneID })?.inner_rect
        let extraCols = Int(surface?.frame.width ?? 0) - Int(inner?.width ?? 0)
        let extraRows = Int(surface?.frame.height ?? 0) - Int(inner?.height ?? 0)
        let cols = floor(width * scale.width / CGFloat(metrics.cellWidthPixels)) + CGFloat(extraCols)
        let rows = floor(height * scale.height / CGFloat(metrics.cellHeightPixels)) + CGFloat(extraRows)
        guard cols.isFinite, rows.isFinite, cols >= 1, rows >= 1 else { return nil }
        return (.init(cols: UInt16(min(cols, CGFloat(UInt16.max))), rows: UInt16(min(rows, CGFloat(UInt16.max)))),
                metrics.cellWidthPixels, metrics.cellHeightPixels)
    }

    private func check(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard active, ProcessInfo.processInfo.systemUptime < deadline else { throw CLIError("Herdr floating presentation timed out") }
        if let failure = session.failure { throw failure }
        if let snapshot = session.projection.snapshot {
            guard session.serviceIdentity == binding.serviceIdentity else { throw CLIError("Herdr floating service changed") }
            guard selectingInitialTab && !snapshot.tabs.contains(where: { $0.tab_id == binding.tabID })
                || snapshot.panes.contains(where: { $0.pane_id == binding.paneID && $0.tab_id == binding.tabID }) else {
                throw CLIError("Herdr floating pane changed")
            }
        }
    }

    private func render() {
        guard active, !frozen, renderTask == nil else { return }
        renderTask = Task { [weak self] in
            guard let self else { return }
            defer { self.renderTask = nil }
            do {
                while self.active, !self.frozen, let (snapshot, surface, assets) = self.pending {
                    self.pending = nil
                    if self.selectingInitialTab && snapshot.focused_tab_id != self.binding.tabID { continue }
                    // shortcut: floating native popups need a separate overlay; return the pane before opening one.
                    guard surface.popup == nil else { throw CLIError("Return the floating pane to its tab to use Herdr popups") }
                    guard snapshot.focused_tab_id == self.binding.tabID, surface.panes.count == 1,
                          surface.panes.first?.pane_id == self.binding.paneID else {
                        throw CLIError("Herdr floating tab is no longer a single pane")
                    }
                    guard self.session.beginPresentation(surface) else { continue }
                    defer { self.session.endPresentation(surface) }
                    try self.pane.bindClientShell(self.session, bootID: snapshot.boot_id)
                    self.resize()
                    guard self.session.canPresent(surface) else { continue }
                    guard let request = try await self.pane.prepareClientShellRenderRequest(surface, assets: assets) else {
                        if self.pending == nil { self.pending = (snapshot, surface, assets) }
                        try await Task.sleep(for: .milliseconds(20)); continue
                    }
                    let scene = try await HerdrClientShellRenderer.prepareScene([request.input], from: surface, assets: assets)
                    guard let output = scene.outputs.first, request.isCurrent(),
                          let memory = request.output(output).commit() else { continue }
                    await Task.detached { memory.waitForPendingOutput() }.value
                    if request.isCurrent() { _ = self.session.acknowledgePresentation(surface) }
                }
            } catch is CancellationError { }
            catch { if !self.frozen { self.pane.setClientShellPresented(false); self.onFailure?(error) } }
        }
    }
}
