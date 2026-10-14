import Foundation

@MainActor
final class HerdrAgentMonitor {
    private(set) var session: HerdrClientShellSession?
    private var connectionTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var notificationTimer: Task<Void, Never>?
    private var generation = 0
    private var endpoint: HerdrEndpoint?
    private let store: AgentSessionStore
    private var stopped = true
    private var retryDelay: Double = 1
    private var healthySince: TimeInterval?
    var onGeneralNotification: ((HerdrShellNotification) -> Void)?
    var onMetadata: ((HerdrShellSnapshot, HerdrServiceIdentity) -> Void)?
    var onState: ((HerdrConnectionState) -> Void)?

    init(store: AgentSessionStore = .shared) { self.store = store }

    func start(_ endpoint: HerdrEndpoint) {
        if !stopped, self.endpoint == endpoint { return }
        stop()
        stopped = false; self.endpoint = endpoint; retryDelay = 1; healthySince = nil
        store.configure(endpoint)
        connect()
        notificationTimer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
                guard let store = self?.store else { break }
                store.drainPending()
            }
        }
    }

    func stop() {
        stopped = true; generation += 1
        connectionTask?.cancel(); retryTask?.cancel(); notificationTimer?.cancel()
        connectionTask = nil; retryTask = nil; notificationTimer = nil
        session?.disconnect(); session = nil
        store.markUnavailable(endpoint: endpoint)
    }

    func updatePresentation(_ endpoint: HerdrEndpoint) {
        guard self.endpoint == endpoint else { return }
        self.endpoint = endpoint
        if let session, let snapshot = session.projection.snapshot, let identity = session.serviceIdentity {
            try? store.apply(snapshot, completions: session.agentCompletions, endpoint: endpoint, identity: identity)
        }
    }

    private func connect() {
        guard !stopped, let endpoint else { return }
        generation += 1
        let epoch = generation
        let connection = HerdrClientShellSession(endpoint: endpoint)
        session = connection
        connection.onMetadata = { [weak self, weak connection] snapshot in
            guard let self, let connection, self.generation == epoch, let identity = connection.serviceIdentity else { return }
            do {
                try self.store.apply(snapshot, completions: connection.agentCompletions, endpoint: self.endpoint ?? endpoint, identity: identity)
                let now = ProcessInfo.processInfo.systemUptime
                if self.healthySince == nil { self.healthySince = now }
                if let since = self.healthySince, now - since >= 60 { self.retryDelay = 1 }
                self.onMetadata?(snapshot, identity)
            } catch { connection.disconnect(); self.retry(epoch) }
        }
        connection.onNotification = { [weak self] event in
            guard let self, self.generation == epoch else { return }
            if event.kind >= 2 && event.pane_id == nil { self.onGeneralNotification?(event) }
            else { self.store.receive(event, endpoint: endpoint) }
        }
        connection.onFailure = { [weak self] error, _ in self?.retry(epoch, attention: (error as? HerdrSSHFailure)?.needsAttention == true) }
        connection.onState = { [weak self] state in
            guard let self, self.generation == epoch else { return }
            self.onState?(state)
        }
        connectionTask = Task { [weak self, weak connection] in
            guard let connection else { return }
            do {
                try await connection.start(size: .init(cols: 1, rows: 1), cellWidth: 0, cellHeight: 0,
                    focused: false, activateWhenMetadataReady: false)
            } catch is CancellationError { }
            catch { self?.retry(epoch) }
        }
    }

    private func retry(_ epoch: Int, attention: Bool = false) {
        guard !stopped, generation == epoch, retryTask == nil else { return }
        store.markUnavailable(endpoint: endpoint)
        healthySince = nil
        let delay = attention ? 30 : retryDelay; retryDelay = min(120, retryDelay * 2)
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == epoch, !self.stopped else { return }
            self.session?.disconnect(); self.session = nil
            self.retryTask = nil
            self.connect()
        }
    }
}
