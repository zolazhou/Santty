import Foundation
import GhosttyTerminal

@MainActor
final class HerdrTerminalSession {
    enum State: Equatable { case connecting, live, disconnected, failed(String), finished }
    private(set) var binding: HerdrTerminalBinding?
    private(set) var record: HerdrCoreTerminal?
    private(set) var state: State = .connecting
    var onChange: (() -> Void)?
    var onReset: (() -> Void)?
    var beforeRun: (() async throws -> Void)?
    private let observerID = UUID()
    private let paneID: UUID
    let viewerOnly: Bool
    let remote: HerdrRemote?
    private var remoteReady = false
    private var machine: HerdrMachine?
    private let cwd: String?
    private let client: HerdrCoreClient
    private var viewport: InMemoryTerminalViewport?
    private var surfaceReady = false
    private var requested = false
    private var stopped = false
    private var task: Task<Void, Never>?
    private var connection: HerdrCoreTransport?
    private var channel: UInt32?
    private var consumer: HerdrTerminalOutput?
    private var focused = false
    private var sentSize: [UInt16]?
    private var sentFacts: Data?
    private(set) var createResultUnknown = false
    lazy var memory = InMemoryTerminalSession(write: { [weak self] data in
        Task { @MainActor [weak self] in self?.input(data) }
    }, resize: { [weak self] viewport in
        Task { @MainActor [weak self] in self?.resize(viewport) }
    })

    init(paneID: UUID, cwd: String?, binding: HerdrTerminalBinding?, remote: HerdrRemote? = nil, runPending: Bool = false, viewerOnly: Bool = false, client: HerdrCoreClient = .shared) {
        self.paneID = paneID; self.cwd = cwd; self.binding = binding; self.client = client
        self.remote = remote; self.createResultUnknown = runPending; self.viewerOnly = viewerOnly
    }

    func start() {
        guard !requested else { return }
        requested = true
        if let remote {
            client.observeMachine(remote.id, token: observerID) { [weak self] in self?.machineChanged($0) }
        }
        connectIfNeeded()
    }

    private func machineChanged(_ machine: HerdrMachine?) {
        guard !stopped, state != .finished else { return }
        let changed = self.machine != machine
        self.machine = machine
        remoteReady = machine?.state == "connected"
        if !remoteReady {
            let nextState = State.failed(machine?.status ?? "Remote core is unavailable. Check hc machine ls.")
            guard state != nextState else { return }
            onReset?()
            disconnectViewer()
            state = nextState
            onChange?()
        } else if channel == nil, changed || state == .disconnected {
            state = .connecting
            onChange?()
            connectIfNeeded()
        }
    }
    func surfaceAttached() { surfaceReady = true; connectIfNeeded() }
    func surfaceDetached() { surfaceReady = false; disconnectViewer() }

    func retry() {
        guard !stopped, state != .finished else { return }
        state = .disconnected
        connectIfNeeded()
    }

    private func connectIfNeeded() {
        guard requested, surfaceReady, viewport != nil, task == nil, channel == nil, !stopped,
              state != .finished, remote == nil || remoteReady else { return }
        state = .connecting
        onChange?()
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
                if self.state == .connecting, self.channel == nil { self.connectIfNeeded() }
            }
            do {
                let connection = try await client.connection()
                try Task.checkCancellation()
                guard !stopped, surfaceReady, remote == nil || remoteReady else { return }
                if viewerOnly, binding == nil { throw HerdrCoreError("An external viewer requires its original terminal binding", kind: "invalid_terminal") }
                if binding == nil {
                    // Reconcile a previous ambiguous run by the stable pane label before creating.
                    struct List: Decodable, Sendable { let terminals: [HerdrCoreTerminal] }
                    let existing: List = try await HerdrCoreClient.request(connection, "terminal.list",
                        ["all": true, "labels": ["santty-pane": paneID.uuidString]])
                    let matches = existing.terminals.filter { client.binding(for: $0, remote: remote, connection: connection) != nil }
                    guard matches.count <= 1 else { throw HerdrCoreError("Multiple terminals have this pane label; resolve them with hc before retrying.", kind: "ambiguous_run") }
                    if let record = matches.first {
                        binding = client.binding(for: record, remote: remote, connection: connection)
                        createResultUnknown = false
                    } else {
                        guard !createResultUnknown else {
                            throw HerdrCoreError("The previous run result is unknown. Retry checks for its pane label; it will not start a duplicate shell.", kind: "ambiguous_run")
                        }
                        var environment = ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "Santty",
                                           "SANTTY_PANE_ID": paneID.uuidString]
                        if remote == nil { environment["SANTTY_CONTROL_SOCKET"] = CLITransport.socketPath }
                        var params: [String: Any] = ["keep": true, "no_parent": true,
                            "labels": ["santty-pane": paneID.uuidString], "env": environment]
                        if let remote {
                            params["on"] = remote.id
                            if let cwd { params["cwd"] = cwd }
                        } else { params["cwd"] = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path }
                        createResultUnknown = true
                        onChange?()
                        do { try await beforeRun?() }
                        catch { createResultUnknown = false; onChange?(); throw error }
                        guard !stopped, surfaceReady, remote == nil || remoteReady else {
                            createResultUnknown = false
                            onChange?()
                            return
                        }
                        let created: HerdrCoreTerminal = try await HerdrCoreClient.request(connection, "terminal.run", params)
                        guard let createdBinding = client.binding(for: created, remote: remote, connection: connection) else {
                            throw HerdrCoreError("Core returned a terminal on an unexpected machine", kind: "protocol")
                        }
                        binding = createdBinding
                        createResultUnknown = false
                    }
                    onChange?()
                }
                guard let binding else { return }
                // A close racing a run still ends exactly the terminal that run created.
                if stopped { return }
                try client.check(binding, connection: connection)
                client.observe(binding, id: observerID) { [weak self] record, error in
                    guard let self, !self.stopped else { return }
                    if let error { self.streamEnded(error) }
                    else if let record {
                        self.apply(record)
                        if record.state == "live", record.reason == nil, self.channel == nil { self.connectIfNeeded() }
                    } else if self.remote != nil { self.streamEnded(nil) }
                    else { self.fail(HerdrCoreError("This terminal was removed from herdr-core", kind: "not_found")) }
                }
                let current = try await client.terminal(binding)
                apply(current)
                guard current.state == "live", !stopped, surfaceReady, let viewport else { return }
                struct Attached: Decodable, Sendable { let channel: UInt32; let terminal: HerdrCoreTerminal }
                let attached: Attached = try await HerdrCoreClient.request(connection, "terminal.attach",
                    ["terminal": binding.routedAddress, "cols": viewport.columns, "rows": viewport.rows,
                     "history": client.settings.historyLines, "resumed": true, "display": displayFacts()])
                guard !stopped, surfaceReady, remote == nil || remoteReady else { connection.detach(channel: attached.channel); return }
                onReset?()
                memory.receive("\u{1b}c\u{1b}[3J")
                self.connection = connection
                channel = attached.channel
                let consumer = HerdrTerminalOutput(memory: memory, connection: connection, channel: attached.channel) { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, self.connection === connection, self.channel == attached.channel else { return }
                        self.streamEnded(error)
                    }
                }
                self.consumer = consumer
                connection.register(channel: attached.channel) { result in consumer.receive(result) }
                apply(attached.terminal)
                state = .live
                if let latest = self.viewport { resize(latest) }
                setFocused(focused)
                onChange?()
            } catch is CancellationError { }
            catch {
                guard !stopped else { return }
                let error = error as? HerdrCoreError ?? HerdrCoreError(error.localizedDescription)
                if binding == nil, !["connection", "unavailable", "protocol", "ambiguous_run"].contains(error.kind) {
                    createResultUnknown = false
                }
                if error.kind == "connection", !createResultUnknown { state = .disconnected; onChange?(); scheduleReconnect() }
                else { fail(error) }
            }
        }
    }

    private func apply(_ record: HerdrCoreTerminal) {
        self.record = record
        if record.state == "finished" { state = .finished; disconnectViewer() }
        onChange?()
    }

    private func resize(_ viewport: InMemoryTerminalViewport) {
        guard viewport.columns > 0, viewport.rows > 0 else { return }
        self.viewport = viewport
        if let channel, let connection {
            let size = [viewport.columns, viewport.rows]
            if sentSize != size {
                sentSize = size
                connection.send(channel: channel, kind: 3,
                    payload: HerdrCoreFrame.little(viewport.columns) + HerdrCoreFrame.little(viewport.rows))
            }
            updateDisplay()
        } else { connectIfNeeded() }
    }

    private func input(_ data: Data) {
        guard state == .live, let channel, let connection else { return }
        // Keep a large paste within the protocol's frame limit.
        for start in stride(from: 0, to: data.count, by: 16 * 1024) {
            connection.send(channel: channel, kind: 0, payload: Data(data[start..<min(start + 16 * 1024, data.count)]))
        }
    }

    func setFocused(_ focused: Bool) {
        self.focused = focused
        // Ghostty sends requested focus reports through DATA. FACTS claims size ownership
        // without asking core to inject a duplicate focus report into the program.
        if focused, let channel, let connection {
            if let facts = try? JSONSerialization.data(withJSONObject: displayFacts(), options: .sortedKeys) {
                connection.send(channel: channel, kind: 5, payload: facts)
                sentFacts = facts
            }
        }
    }

    private func displayFacts() -> [String: Any] {
        var facts: [String: Any] = [:]
        if let theme = TerminalDefaults.themeDefinition {
            func hex(_ text: String) -> String { text.hasPrefix("#") ? text : "#" + text }
            facts["fg"] = hex(theme.foreground)
            facts["bg"] = hex(theme.background)
            facts["cursor"] = hex(theme.cursorColor ?? theme.foreground)
        }
        if let viewport, viewport.cellWidthPixels > 0, viewport.cellHeightPixels > 0 {
            facts["cell"] = [viewport.cellWidthPixels, viewport.cellHeightPixels]
        }
        return facts
    }
    func updateDisplay() {
        guard let channel, let connection,
              let facts = try? JSONSerialization.data(withJSONObject: displayFacts(), options: .sortedKeys),
              facts != sentFacts else { return }
        sentFacts = facts
        connection.send(channel: channel, kind: 5, payload: facts)
    }

    private func streamEnded(_ error: HerdrCoreError?) {
        guard !stopped else { return }
        if remote != nil { onReset?() }
        disconnectViewer()
        if state == .finished { return }
        state = .disconnected
        onChange?()
        scheduleReconnect()
    }
    private func scheduleReconnect() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.state == .disconnected else { return }
            self.connectIfNeeded()
        }
    }
    private func fail(_ error: HerdrCoreError) {
        disconnectViewer()
        state = .failed(error.localizedDescription)
        onChange?()
    }
    private func disconnectViewer() {
        consumer?.invalidate(); consumer = nil
        if let channel { connection?.detach(channel: channel) }
        channel = nil; connection = nil; sentSize = nil; sentFacts = nil
    }
    func closeTerminal() async throws {
        stopped = true
        disconnectViewer()
        client.removeObserver(observerID)
        if let task { await task.value }
        if viewerOnly {
            client.removeMachineObserver(observerID)
            state = .finished
            return
        }
        do {
            if let binding { try await client.kill(binding) }
            else if createResultUnknown {
                struct List: Decodable, Sendable { let terminals: [HerdrCoreTerminal] }
                let connection = try await client.connection()
                let list: List = try await HerdrCoreClient.request(connection, "terminal.list", ["all": true, "labels": ["santty-pane": paneID.uuidString]])
                let matches = list.terminals.compactMap { client.binding(for: $0, remote: remote, connection: connection) }
                guard !matches.isEmpty else { throw HerdrCoreError("The run result is still unknown; keep this pane until its terminal can be reconciled.", kind: "ambiguous_run") }
                for binding in matches { try await client.kill(binding) }
            }
            state = .finished
            client.removeMachineObserver(observerID)
        } catch let error as HerdrCoreError where ["not_found", "finished"].contains(error.kind) {
            state = .finished
            client.removeMachineObserver(observerID)
        } catch {
            stopped = false
            if remote != nil, let coreError = error as? HerdrCoreError,
               ["connection", "unavailable"].contains(coreError.kind) {
                state = .disconnected
                scheduleReconnect()
            } else { state = .failed(error.localizedDescription) }
            onChange?()
            throw error
        }
    }
    deinit {
        MainActor.assumeIsolated {
            task?.cancel()
            consumer?.invalidate()
            if let channel { connection?.detach(channel: channel) }
            client.removeObserver(observerID)
            client.removeMachineObserver(observerID)
        }
    }
}

/// Runs on one transport stream queue. Credit follows parsing, not receive() enqueue.
private final class HerdrTerminalOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let memory: InMemoryTerminalSession
    private let connection: HerdrCoreTransport
    private let channel: UInt32
    private let ended: @Sendable (HerdrCoreError?) -> Void
    init(memory: InMemoryTerminalSession, connection: HerdrCoreTransport, channel: UInt32,
         ended: @escaping @Sendable (HerdrCoreError?) -> Void) {
        self.memory = memory; self.connection = connection; self.channel = channel; self.ended = ended
    }
    func invalidate() { lock.withLock { active = false } }
    func receive(_ result: Result<HerdrCoreFrame, HerdrCoreError>) {
        switch result {
        case let .failure(error): if lock.withLock({ active }) { ended(error) }
        case let .success(frame):
            if frame.kind == 2 { if lock.withLock({ active }) { ended(nil) }; return }
            guard frame.kind == 0 else { return }
            let enqueued = lock.withLock {
                guard active else { return false }
                memory.receive(frame.payload)
                return true
            }
            guard enqueued, memory.waitForPendingOutput(), lock.withLock({ active }) else { return }
            connection.credit(channel: channel, bytes: frame.payload.count)
        }
    }
}
