import Combine
import Foundation

struct HerdrTerminalBinding: Codable, Sendable, Hashable {
    let coreID: String
    let address: String
    var remote: Bool? = nil
    var routedAddress: String { remote == true ? coreID + "/" + address : address }
}

struct HerdrRemote: Codable, Sendable, Equatable {
    let id: String
    let name: String
}

struct HerdrMachine: Decodable, Sendable, Equatable {
    let id: String
    let name: String
    let state: String
    let why: String?
    var target: String? = nil
    var host: String? = nil
    var version: String? = nil
    var via: Bool? = nil
    var destination: String { via == true ? (host ?? "Custom connection") : (target ?? host ?? "Unknown host") }
    var reference: HerdrRemote { .init(id: id, name: name) }
    var status: String {
        switch state {
        case "connected": return "Connected"
        case "connecting": return "Connecting"
        case "needs_login": return "Login required — use hc machine login"
        case "needs_update": return "Remote hc update required"
        default: return why ?? "Unreachable"
        }
    }
}

struct HerdrProgramStatus: Decodable, Sendable, Equatable {
    let state: String
    var app: String? = nil
    var title: String? = nil
    var msg: String? = nil
    var kind: String? = nil
    var progress: UInt8? = nil
}

struct HerdrCoreTerminal: Decodable, Sendable {
    struct Foreground: Decodable, Sendable {
        let pid: Int32
        let name: String
        let cwd: String
    }
    let address: String
    let pid: Int32?
    var title: String
    var cwd: String
    var state: String
    var reason: String?
    var foreground: Foreground?
    var cols: UInt16
    var rows: UInt16
    var exit_code: Int32?
    var status: HerdrProgramStatus? = nil
    var records: [String: HerdrProgramStatus]? = nil
    var reported: Bool? = nil
    var turn: UInt64? = nil
    var status_ms: UInt64? = nil
    var parent: String? = nil
    var template: String? = nil
}

struct HerdrConnectionDetails: Equatable {
    let executablePath: String
    let version: String?
    let coreID: String
    let coreName: String
    let session: String
}

@MainActor
final class HerdrCoreClient: ObservableObject {
    static let shared = HerdrCoreClient()
    private let environment: [String: String]
    let settings: HerdrSettings
    let agents = AgentSessionStore()
    private var monitoring = false
    private var monitorRetry: Task<Void, Never>?
    @Published private(set) var configuredExecutablePath: String?
    @Published private(set) var details: HerdrConnectionDetails?
    @Published private(set) var lastError: HerdrCoreError?
    @Published private(set) var machines: [HerdrMachine] = []
    @Published private(set) var isReconnecting = false

    init(executable: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
         settings: HerdrSettings = .shared) {
        self.settings = settings
        self.configuredExecutablePath = executable?.path ?? settings.executablePath
        self.environment = environment
    }
    private var transport: HerdrCoreTransport?
    private var connecting: Task<HerdrCoreTransport, Error>?
    private var generation = 0
    private var terminals: [String: HerdrCoreTerminal] = [:]
    private var sequence = -1
    private var eventTask: Task<Void, Never>?
    private var eventChannel: UInt32?
    private var machineAliases: [String: Set<String>] = [:]
    private var machineTask: Task<Void, Never>?
    private var machineObservers: [UUID: (String, (HerdrMachine?) -> Void)] = [:]
    private var observers: [UUID: (HerdrTerminalBinding, (HerdrCoreTerminal?, HerdrCoreError?) -> Void)] = [:]
    private struct Snapshot: Decodable, Sendable {
        let seq: Int
        let channel: UInt32
        let terminals: [HerdrCoreTerminal]
    }

    func startAgentMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.connection() }
            catch { self.scheduleMonitorReconnect() }
        }
        startMachinePollingIfNeeded()
    }

    func stopAgentMonitoring() {
        monitoring = false
        monitorRetry?.cancel(); monitorRetry = nil
        if machineObservers.isEmpty { machineTask?.cancel(); machineTask = nil }
    }

    private func scheduleMonitorReconnect() {
        guard monitoring, monitorRetry == nil else { return }
        monitorRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            self.monitorRetry = nil
            do { _ = try await self.connection() }
            catch { self.scheduleMonitorReconnect() }
        }
    }

    func connection() async throws -> HerdrCoreTransport {
        if let transport { return transport }
        if let connecting { return try await connecting.value }
        let generation = self.generation
        let task = Task { () throws -> HerdrCoreTransport in
            let executable = try HerdrSettings.executableURL(for: self.configuredExecutablePath), environment = self.environment
            let transport = try await Task.detached { try HerdrCoreTransport.connect(executable: executable, environment: environment) }.value
            do {
                let (snapshot, machines) = try await Self.prepare(transport)
                try Task.checkCancellation()
                guard generation == self.generation else { throw CancellationError() }
                self.install(transport, snapshot: snapshot, machines: machines)
                return transport
            } catch { transport.close(); throw error }
        }
        connecting = task
        do {
            let result = try await task.value
            if generation == self.generation { connecting = nil }
            return result
        } catch {
            if generation == self.generation { connecting = nil; recordError(error) }
            throw error
        }
    }

    private static func prepare(_ transport: HerdrCoreTransport) async throws -> (Snapshot, [HerdrMachine]) {
        struct List: Decodable, Sendable { let machines: [HerdrMachine] }
        let snapshot: Snapshot = try await request(transport, "events.subscribe", [:])
        let list: List = try await request(transport, "machine.list", [:])
        return (snapshot, list.machines)
    }

    private func install(_ transport: HerdrCoreTransport, snapshot: Snapshot, machines: [HerdrMachine]) {
        if self.transport === transport, let eventChannel { transport.detach(channel: eventChannel) }
        if self.transport !== transport { machineAliases.removeAll() }
        eventChannel = snapshot.channel
        self.transport = transport
        details = .init(executablePath: transport.executableURL.path, version: transport.hello.version,
                        coreID: transport.hello.core.id, coreName: transport.hello.core.name,
                        session: environment["HC_SESSION"] ?? "default")
        lastError = nil
        sequence = snapshot.seq
        updateMachines(machines)
        replaceSnapshot(snapshot.terminals)
        let events = AsyncStream<Result<HerdrCoreFrame, HerdrCoreError>>.makeStream()
        transport.register(channel: snapshot.channel) { result in events.continuation.yield(result) }
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self, weak transport] in
            var buffer = Data()
            for await result in events.stream {
                guard !Task.isCancelled, let self, let transport, self.transport === transport else { break }
                switch result {
                case let .failure(error): self.disconnected(transport, error: error); return
                case let .success(frame):
                    guard frame.kind == 0 else {
                        self.disconnected(transport, error: HerdrCoreError("Core event stream ended")); return
                    }
                    buffer.append(frame.payload)
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end])
                        buffer.removeSubrange(...end)
                        if !line.isEmpty { self.event(line) }
                    }
                    guard buffer.count <= HerdrCoreFrame.maximumPayload else {
                        self.disconnected(transport, error: HerdrCoreError("Oversized core event", kind: "protocol")); return
                    }
                    transport.credit(channel: frame.channel, bytes: frame.payload.count)
                }
            }
        }
    }

    func reconnect() async throws { try await replaceConnection(path: configuredExecutablePath) }

    func applyExecutablePath(_ path: String?) async throws {
        let path = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = path?.isEmpty == false ? path : nil
        try await replaceConnection(path: normalized)
        settings.saveExecutablePath(normalized)
    }

    private func replaceConnection(path: String?) async throws {
        guard !isReconnecting else { throw HerdrCoreError("A connection check is already running", kind: "busy") }
        isReconnecting = true
        defer { isReconnecting = false }
        do {
            let executable = try HerdrSettings.executableURL(for: path), environment = self.environment
            let candidate = try await Task.detached { try HerdrCoreTransport.connect(executable: executable, environment: environment) }.value
            do {
                let (snapshot, machines) = try await Self.prepare(candidate)
                try Task.checkCancellation()
                let old = transport
                generation += 1
                connecting?.cancel(); connecting = nil
                eventTask?.cancel()
                transport = nil
                for (_, observer) in Array(observers.values) { observer(nil, HerdrCoreError("Reconnecting to herdr-core")) }
                configuredExecutablePath = path
                install(candidate, snapshot: snapshot, machines: machines)
                old?.close()
            } catch { candidate.close(); throw error }
        } catch { recordError(error); throw error }
    }

    private func recordError(_ error: Error) {
        lastError = error as? HerdrCoreError ?? HerdrCoreError(error.localizedDescription)
    }

    var diagnosticText: String {
        var lines = ["Santty Herdr diagnostics", "Status: \(details == nil ? "Disconnected" : "Connected")",
                     "Executable: \(details?.executablePath ?? configuredExecutablePath ?? "Automatic detection")",
                     "Core version: \(details?.version ?? "Unknown")", "Core ID: \(details?.coreID ?? "Unknown")",
                     "Session: \(details?.session ?? environment["HC_SESSION"] ?? "default")",
                     "History to restore: \(settings.historyLines)", "Recent error kind: \(lastError?.kind ?? "None")"]
        // Error text and custom connection commands may contain credentials or environment values.
        lines += machines.map { "Machine: \($0.name), ID: \($0.id), state: \($0.state), version: \($0.version ?? "Unknown")" }
        return lines.joined(separator: "\n")
    }

    static func request<T: Decodable & Sendable>(_ transport: HerdrCoreTransport, _ method: String,
                                                 _ params: [String: Any]) async throws -> T {
        let params = try JSONSerialization.data(withJSONObject: params)
        let reply = try await transport.call(method: method, params: params)
        return try JSONDecoder().decode(HerdrCoreReply<T>.self, from: reply).get()
    }

    func observe(_ binding: HerdrTerminalBinding, id: UUID,
                 change: @escaping (HerdrCoreTerminal?, HerdrCoreError?) -> Void) {
        observers[id] = (binding, change)
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    func terminal(_ binding: HerdrTerminalBinding) async throws -> HerdrCoreTerminal {
        let connection = try await connection()
        try check(binding, connection: connection)
        return try await Self.request(connection, "terminal.get", ["terminal": binding.routedAddress])
    }

    func check(_ binding: HerdrTerminalBinding, connection: HerdrCoreTransport) throws {
        guard binding.remote == true || binding.coreID == connection.hello.core.id else {
            throw HerdrCoreError("The herdr-core state has changed. The saved terminal will not be replaced automatically.", kind: "identity_changed")
        }
        guard binding.address.range(of: "^t[0-9a-z]+$", options: .regularExpression) != nil else {
            throw HerdrCoreError("Invalid herdr-core terminal address", kind: "invalid_terminal")
        }
        if binding.remote == true, !machines.contains(where: { $0.id == binding.coreID }) {
            throw HerdrCoreError("The saved remote core is no longer configured. Add the same machine with hc machine add.", kind: "identity_changed")
        }
    }

    func kill(_ binding: HerdrTerminalBinding) async throws {
        struct Result: Decodable, Sendable {}
        let connection = try await connection()
        try check(binding, connection: connection)
        let _: Result = try await Self.request(connection, "terminal.kill", ["terminal": binding.routedAddress])
    }

    func configuredMachines() async throws -> [HerdrMachine] {
        do {
            let connection = try await connection()
            return try await refreshMachines(connection)
        } catch { recordError(error); throw error }
    }

    private func refreshMachines(_ connection: HerdrCoreTransport) async throws -> [HerdrMachine] {
        struct List: Decodable, Sendable { let machines: [HerdrMachine] }
        let list: List = try await Self.request(connection, "machine.list", [:])
        guard self.transport === connection else { return machines }
        let oldNames = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0.name) })
        let newNames = Dictionary(uniqueKeysWithValues: list.machines.map { ($0.id, $0.name) })
        updateMachines(list.machines)
        if oldNames != newNames {
            // Alias changes can remove/recreate mirrored records between machine polls.
            let (snapshot, profiles) = try await Self.prepare(connection)
            guard self.transport === connection else { return machines }
            install(connection, snapshot: snapshot, machines: profiles)
        }
        return machines
    }

    private func updateMachines(_ machines: [HerdrMachine]) {
        for machine in self.machines + machines { machineAliases[machine.name, default: []].insert(machine.id) }
        if self.machines != machines {
            let known = Set(self.machines.map(\.id) + machines.map(\.id))
            self.machines = machines
            let connected = Set(machines.filter { $0.state == "connected" }.map(\.id))
            for id in known.subtracting(connected) { agents.markUnavailable(coreID: id) }
        }
        for (id, observer) in Array(machineObservers.values) {
            observer(machines.first { $0.id == id })
        }
    }

    func observeMachine(_ id: String, token: UUID, change: @escaping (HerdrMachine?) -> Void) {
        machineObservers[token] = (id, change)
        startMachinePollingIfNeeded()
    }

    private func startMachinePollingIfNeeded() {
        guard machineTask == nil else { return }
        machineTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.monitoring || !self.machineObservers.isEmpty else { break }
                do { _ = try await self.configuredMachines() }
                catch { for (_, observer) in Array(self.machineObservers.values) { observer(nil) } }
                try? await Task.sleep(for: .seconds(1))
            }
            self?.machineTask = nil
        }
    }

    func removeMachineObserver(_ token: UUID) { machineObservers.removeValue(forKey: token) }

    private func machine(for prefix: String) -> HerdrMachine? {
        if let exact = machines.first(where: { $0.id == prefix }) { return exact }
        guard let ids = machineAliases[prefix], ids.count == 1, let id = ids.first else { return nil }
        return machines.first { $0.id == id }
    }

    func canonicalAddress(_ address: String) -> String? {
        guard let slash = address.firstIndex(of: "/") else { return address }
        let prefix = String(address[..<slash])
        guard let machine = machine(for: prefix) else { return nil }
        return machine.id + address[slash...]
    }

    func binding(for terminal: HerdrCoreTerminal, remote: HerdrRemote?, connection: HerdrCoreTransport) -> HerdrTerminalBinding? {
        if let remote {
            guard canonicalAddress(terminal.address)?.hasPrefix(remote.id + "/") == true,
                  terminal.address.split(separator: "/").count == 2,
                  let bare = terminal.address.split(separator: "/").last,
                  bare.range(of: "^t[0-9a-z]+$", options: .regularExpression) != nil else { return nil }
            return .init(coreID: remote.id, address: String(bare), remote: true)
        }
        guard !terminal.address.contains("/") else { return nil }
        return .init(coreID: connection.hello.core.id, address: terminal.address)
    }

    func binding(forAddress address: String) -> HerdrTerminalBinding? {
        guard let transport else { return nil }
        let parts = address.split(separator: "/")
        if parts.count == 1, address.range(of: "^t[0-9a-z]+$", options: .regularExpression) != nil {
            return .init(coreID: transport.hello.core.id, address: address)
        }
        guard parts.count == 2, let machine = machine(for: String(parts[0])),
              String(parts[1]).range(of: "^t[0-9a-z]+$", options: .regularExpression) != nil else { return nil }
        return .init(coreID: machine.id, address: String(parts[1]), remote: true)
    }

    private func disconnected(_ connection: HerdrCoreTransport, error: HerdrCoreError) {
        guard transport === connection else { return }
        transport = nil
        eventChannel = nil
        details = nil
        recordError(error)
        agents.markUnavailable()
        scheduleMonitorReconnect()
        connection.close()
        for (_, observer) in Array(observers.values) { observer(nil, error) }
    }

    private func replaceSnapshot(_ snapshot: [HerdrCoreTerminal]) {
        terminals = Dictionary(snapshot.compactMap { record in canonicalAddress(record.address).map { ($0, record) } }, uniquingKeysWith: { _, latest in latest })
        let entries = snapshot.compactMap { record -> (HerdrTerminalBinding, HerdrCoreTerminal)? in
            guard let binding = binding(forAddress: record.address) else { return nil }
            return (binding, record)
        }
        agents.replaceSnapshot(entries)
        for machine in machines where machine.state != "connected" { agents.markUnavailable(coreID: machine.id) }
        for (binding, observer) in Array(observers.values) {
            guard let transport else { return }
            do { try check(binding, connection: transport) }
            catch { observer(nil, error as? HerdrCoreError); continue }
            let address = binding.routedAddress
            if let record = terminals[address] { observer(record, nil) }
            else if !address.contains("/") { observer(nil, nil) }
        }
    }

    private func event(_ data: Data) {
        do {
            guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let params = envelope["params"] as? [String: Any] else { throw HerdrCoreError("Invalid core event", kind: "protocol") }
            guard let seq = params["seq"] as? Int else { return }
            if envelope["method"] as? String == "heartbeat" { return }
            if envelope["method"] as? String == "missed", let snapshot = params["terminals"] {
                let records = try JSONDecoder().decode([HerdrCoreTerminal].self, from: JSONSerialization.data(withJSONObject: snapshot))
                sequence = seq
                replaceSnapshot(records)
                for (binding, observer) in Array(observers.values) where binding.remote == true {
                    observer(nil, HerdrCoreError("Remote viewer must refresh", kind: "remote_resync"))
                }
                return
            }
            guard seq > sequence else { return }
            sequence = seq
            guard let rawAddress = params["terminal"] as? String, let address = canonicalAddress(rawAddress),
                  let kind = params["type"] as? String else { return }
            let body = params["data"] as? [String: Any] ?? [:]
            let wasKnown = terminals[address] != nil
            if kind == "created" || kind == "restarted" {
                terminals[address] = try JSONDecoder().decode(HerdrCoreTerminal.self, from: JSONSerialization.data(withJSONObject: body))
            } else if kind == "removed" { terminals.removeValue(forKey: address) }
            else if var record = terminals[address] {
                switch kind {
                case "title": record.title = body["title"] as? String ?? record.title
                case "foreground":
                    record.foreground = params["data"] is NSNull ? nil : try JSONDecoder().decode(HerdrCoreTerminal.Foreground.self, from: JSONSerialization.data(withJSONObject: body))
                    if let foreground = record.foreground { record.cwd = foreground.cwd }
                case "status":
                    if let value = body["status"], !(value is NSNull) {
                        record.status = try JSONDecoder().decode(HerdrProgramStatus.self, from: JSONSerialization.data(withJSONObject: value))
                    } else { record.status = nil }
                    if let value = body["records"] {
                        record.records = try JSONDecoder().decode([String: HerdrProgramStatus].self, from: JSONSerialization.data(withJSONObject: value))
                    }
                    record.reported = body["reported"] as? Bool
                case "turn": record.turn = (body["turn"] as? NSNumber)?.uint64Value
                case "size":
                    record.cols = (body["cols"] as? UInt16) ?? record.cols
                    record.rows = (body["rows"] as? UInt16) ?? record.rows
                case "finished", "lost":
                    record.state = kind == "finished" ? "finished" : "live"
                    record.reason = body["reason"] as? String
                    record.exit_code = body["exit_code"] as? Int32
                    record.foreground = nil
                default: return
                }
                terminals[address] = record
            }
            if let binding = binding(forAddress: rawAddress) {
                if kind == "removed" { agents.remove(binding) }
                else if let record = terminals[address] { agents.apply(record, binding: binding, baseline: kind == "created" || kind == "restarted") }
            }
            for (binding, observer) in Array(observers.values) where binding.routedAddress == address {
                guard let transport, (try? check(binding, connection: transport)) != nil else { continue }
                // A fresh remote mirror may repaint surviving viewer channels without closing them.
                if address.contains("/"), wasKnown, kind == "created" || kind == "restarted" {
                    observer(nil, HerdrCoreError("Remote viewer must refresh", kind: "remote_resync"))
                } else { observer(terminals[address], nil) }
            }
        } catch {
            if let transport { disconnected(transport, error: HerdrCoreError("Cannot read core events: \(error.localizedDescription)", kind: "protocol")) }
        }
    }
}

