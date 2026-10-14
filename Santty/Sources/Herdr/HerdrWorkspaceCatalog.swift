import Foundation

@MainActor
final class HerdrWorkspaceCatalog {
    struct EndpointState {
        let endpoint: HerdrEndpoint
        let monitor: HerdrAgentMonitor
        var snapshot: HerdrShellSnapshot?
        var identity: HerdrServiceIdentity?
        var status: HerdrConnectionState = .connecting
    }
    private(set) var states: [String: EndpointState] = [:]
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var localEndpoint: HerdrEndpoint?
    var onChange: (() -> Void)?
    var onGeneralNotification: ((HerdrEndpoint, HerdrShellNotification) -> Void)?
    private(set) var error: String?

    var workspaces: [WorkspaceEntry] {
        states.values.sorted { $0.endpoint.id < $1.endpoint.id }.flatMap { state in
            (state.snapshot?.workspaces ?? []).map {
                WorkspaceEntry(reference: .init(source: .herdr(endpoint: state.endpoint, workspaceID: $0.workspace_id)),
                    name: $0.label, isAvailable: state.identity != nil && state.monitor.session?.failure == nil,
                    status: state.monitor.session?.failure?.localizedDescription)
            }
        }
    }

    func start(local endpoint: HerdrEndpoint) {
        if localEndpoint == endpoint, refreshTask != nil { return }
        stop(); localEndpoint = endpoint
        add(endpoint)
        let epoch = generation
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let profiles = try await Task.detached { try HerdrMachineProfile.list(binary: endpoint.binary) }.value
                    guard let self, self.generation == epoch else { return }
                    self.reconcile(profiles, local: endpoint)
                    self.error = nil
                } catch {
                    guard let self, self.generation == epoch else { return }
                    self.error = error.localizedDescription
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func reconcile(_ profiles: [HerdrMachineProfile], local: HerdrEndpoint) {
        let endpoints = [local] + profiles.filter(\.enabled).map {
            HerdrEndpoint(binary: local.binary, session: $0.session, socketPath: local.socketPath, machine: $0)
        }
        let ids = Set(endpoints.map(\.id))
        for id in states.keys where !ids.contains(id) { states.removeValue(forKey: id)?.monitor.stop() }
        for endpoint in endpoints {
            if let old = states[endpoint.id], old.endpoint != endpoint || old.endpoint.machine?.label != endpoint.machine?.label {
                let oldMachine = old.endpoint.machine, newMachine = endpoint.machine
                if oldMachine?.target == newMachine?.target, oldMachine?.session == newMachine?.session,
                   old.endpoint.binary == endpoint.binary, old.endpoint.socketPath == endpoint.socketPath {
                    // A label edit changes presentation without reconnecting the service.
                    states[endpoint.id] = .init(endpoint: endpoint, monitor: old.monitor, snapshot: old.snapshot, identity: old.identity, status: old.status)
                    old.monitor.updatePresentation(endpoint)
                } else { old.monitor.stop(); states.removeValue(forKey: endpoint.id); add(endpoint) }
            } else if states[endpoint.id] == nil { add(endpoint) }
        }
        onChange?()
    }

    private func add(_ endpoint: HerdrEndpoint) {
        let monitor = HerdrAgentMonitor()
        states[endpoint.id] = .init(endpoint: endpoint, monitor: monitor)
        monitor.onMetadata = { [weak self, weak monitor] snapshot, identity in
            guard let self, self.states[endpoint.id]?.monitor === monitor else { return }
            self.states[endpoint.id]?.snapshot = snapshot; self.states[endpoint.id]?.identity = identity
            self.onChange?()
        }
        monitor.onState = { [weak self, weak monitor] state in
            guard let self, self.states[endpoint.id]?.monitor === monitor else { return }
            self.states[endpoint.id]?.status = state
            if case .failed = state { self.states[endpoint.id]?.identity = nil }
            self.onChange?()
        }
        monitor.onGeneralNotification = { [weak self] in self?.onGeneralNotification?(endpoint, $0) }
        monitor.start(endpoint)
    }

    func stop() {
        generation += 1; refreshTask?.cancel(); refreshTask = nil
        for state in states.values { state.monitor.stop() }
        states.removeAll(); localEndpoint = nil
    }
}
