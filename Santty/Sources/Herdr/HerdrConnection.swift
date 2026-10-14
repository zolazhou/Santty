import Foundation
import Darwin

enum HerdrTerminalMode: String, Codable, Sendable {
    case control

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard ["control", "observe"].contains(value) else { throw CLIError("Unsupported saved Herdr mode") }
        self = .control
    }
}

enum HerdrConnectionState: Sendable, Equatable {
    case disconnected, connecting, reconnecting, interactive, subscribed
    case terminalEnded(String), failed(String)
}

struct HerdrServerInfo: Decodable, Sendable {
    let version: String
    let protocolVersion: Int
    enum CodingKeys: String, CodingKey { case version; case protocolVersion = "protocol" }
    func validate() throws {
        guard protocolVersion == 22, !version.isEmpty, version.utf8.count <= 128,
              !version.utf8.contains(0) else {
            let requirement = "management API protocol 22"
            throw CLIError("Unsupported Herdr \(version), protocol \(protocolVersion). This connection requires \(requirement); Santty will not upgrade or stop the service.")
        }
    }
}

struct HerdrSnapshot: Decodable, Sendable {
    struct Pane: Decodable, Sendable {
        let pane_id: String
        let terminal_id: String?
        var workspace_id: String? = nil
        var tab_id: String? = nil
        var label: String? = nil
        var title: String? = nil
        var cwd: String? = nil
        var foreground_cwd: String? = nil
        var serviceIdentity: HerdrServiceIdentity? = nil
        enum CodingKeys: String, CodingKey { case pane_id, terminal_id, workspace_id, tab_id, label, title, cwd, foreground_cwd }
    }
    struct Tab: Decodable, Sendable { let tab_id: String; let workspace_id: String; let label: String }
    struct Workspace: Decodable, Sendable {
        let workspace_id: String
        let label: String
        let active_tab_id: String?
    }
    var workspaces: [Workspace]? = nil
    var focused_workspace_id: String? = nil
    var tabs: [Tab]? = nil
    let version: String
    let protocolVersion: Int
    var panes: [Pane]
    enum CodingKeys: String, CodingKey { case version, panes, tabs, workspaces, focused_workspace_id; case protocolVersion = "protocol" }
}

struct HerdrRemoteError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { "Herdr \(code): \(message)" }
}

struct HerdrAPIEnvelope: Decodable {
    struct Failure: Decodable { let code: String; let message: String }
    struct Result: Decodable, Sendable {
        let type: String
        let version: String?
        let `protocol`: Int?
        var snapshot: HerdrSnapshot?
        var pane: HerdrSnapshot.Pane?
        var root_pane: HerdrSnapshot.Pane?
        var read: HerdrReadResult?
        var process_info: HerdrProcessInfo?
        var layout: HerdrLayout?

        mutating func assignServiceIdentity(_ identity: HerdrServiceIdentity) {
            layout?.serviceIdentity = identity; pane?.serviceIdentity = identity; root_pane?.serviceIdentity = identity
            process_info?.serviceIdentity = identity; read?.serviceIdentity = identity
            if var snapshot {
                for index in snapshot.panes.indices { snapshot.panes[index].serviceIdentity = identity }
                self.snapshot = snapshot
            }
        }
    }
    let id: String?
    let result: Result?
    let error: Failure?
    let event: String?

    func response(to id: String) throws -> Result {
        guard self.id == id else { throw CLIError("Herdr response ID mismatch") }
        if let error { throw HerdrRemoteError(code: error.code, message: error.message) }
        guard let result else { throw CLIError("Missing Herdr response result") }
        return result
    }
}

// Unlike CLITransport.readLine, this preserves trailing lines on subscription sockets.
struct HerdrLineDecoder {
    static let maximumBytes = 4 * 1024 * 1024
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: newline) <= Self.maximumBytes else { throw CLIError("Herdr message too large") }
            let line = Data(buffer.prefix(upTo: newline))
            buffer.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        guard buffer.count <= Self.maximumBytes else { throw CLIError("Herdr message too large") }
        return lines
    }
    func finish() throws {
        guard buffer.isEmpty else { throw CLIError("Truncated Herdr message") }
    }
}

final class HerdrConnection: @unchecked Sendable {
    struct Request: Encodable, Sendable {
        struct Params: Encodable, Sendable {
            struct Subscription: Encodable, Sendable { let type: String }
            var subscriptions: [Subscription]? = nil
            var workspace_id: String? = nil
            var target_pane_id: String? = nil
            var pane_id: String? = nil
            var tab_id: String? = nil
            var direction: String? = nil
            var label: String? = nil
            var cwd: String? = nil
            var focus: Bool? = nil
            var insert_index: Int? = nil
            var source: String? = nil
            var lines: Int? = nil
            var format: String? = nil
            var strip_ansi: Bool? = nil
            var path: [Bool]? = nil
            var ratio: Double? = nil
        }
        let id: String
        let method: String
        var params = Params()
    }
    private let socketPath: String
    private let endpoint: HerdrEndpoint?
    private let lock = NSRecursiveLock()
    private var generation = 0
    private var hasConnected = false
    private var subscriptionFD: CInt?
    private let snapshotReceived: @Sendable (HerdrSnapshot) -> Void
    private let stateChanged: @Sendable (HerdrConnectionState) -> Void

    init(socketPath: String, endpoint: HerdrEndpoint? = nil, snapshot: @escaping @Sendable (HerdrSnapshot) -> Void,
         state: @escaping @Sendable (HerdrConnectionState) -> Void) {
        self.socketPath = socketPath
        self.endpoint = endpoint
        snapshotReceived = snapshot
        stateChanged = state
    }

    static func preflight(socketPath: String, endpoint: HerdrEndpoint? = nil) throws -> HerdrServerInfo {
        let result = try request(Request(id: UUID().uuidString, method: "ping"), socketPath: socketPath, endpoint: endpoint)
        guard result.type == "pong", let version = result.version, let protocolVersion = result.protocol else {
            throw CLIError("Invalid Herdr ping response")
        }
        let info = HerdrServerInfo(version: version, protocolVersion: protocolVersion)
        try info.validate()
        return info
    }

    private static func openSocket(_ path: String) throws -> CInt {
        do { return try CLITransport.connect(to: path) }
        catch let error as CLIConnectionError {
            throw CLIConnectionError(code: error.code,
                message: "Cannot connect to existing Herdr at \(path). Check the session/socket and running service; Santty will not start or restart it.")
        }
    }

    private static func open(socketPath: String, endpoint: HerdrEndpoint?) throws -> (fd: CInt, bridge: HerdrSSHBridge?) {
        if let endpoint, endpoint.machine != nil {
            let connection = try HerdrSSHBridge.connect(endpoint: endpoint, lane: .api)
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            _ = setsockopt(connection.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            _ = setsockopt(connection.fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            return (connection.fd, connection.bridge)
        }
        return (try openSocket(socketPath), nil)
    }

    static func request(_ request: Request, socketPath: String, endpoint: HerdrEndpoint? = nil) throws -> HerdrAPIEnvelope.Result {
        let connection = try open(socketPath: socketPath, endpoint: endpoint)
        let fd = connection.fd
        defer { Darwin.close(fd); connection.bridge?.stop() }
        do {
            let identity: HerdrServiceIdentity
            if let endpoint, endpoint.machine != nil { identity = .remote(endpoint: endpoint, bootID: "") }
            else { identity = try HerdrServiceIdentity.read(socket: fd) }
            try CLITransport.write(request, to: fd)
            let data = try CLITransport.readLine(fd, limit: HerdrLineDecoder.maximumBytes)
            var result = try JSONDecoder().decode(HerdrAPIEnvelope.self, from: data).response(to: request.id)
            result.assignServiceIdentity(identity)
            return result
        } catch {
            if connection.bridge != nil, let endpoint, !(error is HerdrRemoteError) { HerdrSSHBridge.invalidate(endpoint) }
            throw error
        }
    }

    func connect() {
        disconnect()
        lock.lock()
        generation += 1
        let current = generation
        stateChanged(hasConnected ? .reconnecting : .connecting)
        hasConnected = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                _ = try Self.preflight(socketPath: socketPath, endpoint: endpoint)
                let connection = try Self.open(socketPath: socketPath, endpoint: endpoint)
                let fd = connection.fd
                defer {
                    lock.lock()
                    if generation == current { subscriptionFD = nil }
                    Darwin.close(fd)
                    connection.bridge?.stop()
                    lock.unlock()
                }
                lock.lock()
                guard generation == current else { lock.unlock(); return }
                subscriptionFD = fd
                lock.unlock()
                let types = ["workspace.created", "workspace.updated", "workspace.renamed", "workspace.closed",
                             "workspace.moved", "workspace.reordered", "workspace.focused", "workspace.metadata_updated",
                             "tab.created", "tab.closed", "tab.renamed", "tab.moved", "tab.focused",
                             "pane.created", "pane.closed", "pane.updated", "pane.moved", "pane.focused", "pane.exited", "layout.updated"]
                let subscription = Request(id: UUID().uuidString, method: "events.subscribe",
                    params: .init(subscriptions: types.map { .init(type: $0) }))
                try CLITransport.write(subscription, to: fd)
                var decoder = HerdrLineDecoder()
                var subscribed = false
                var bytes = [UInt8](repeating: 0, count: 65536)
                while true {
                    lock.lock(); let active = generation == current; lock.unlock()
                    guard active else { return }
                    let count = Darwin.read(fd, &bytes, bytes.count)
                    if count < 0, errno == EINTR { continue }
                    if count < 0, (errno == EAGAIN || errno == EWOULDBLOCK), subscribed {
                        _ = try Self.preflight(socketPath: socketPath, endpoint: endpoint)
                        continue
                    }
                    guard count > 0 else {
                        if count == 0 { try decoder.finish() }
                        throw CLIError("Herdr management connection ended or timed out; reconnect to refresh the snapshot")
                    }
                    var refresh = false
                    for line in try decoder.append(Data(bytes.prefix(count))) {
                        let envelope = try JSONDecoder().decode(HerdrAPIEnvelope.self, from: line)
                        if !subscribed {
                            let result = try envelope.response(to: subscription.id)
                            guard result.type == "subscription_started" else { throw CLIError("Unexpected Herdr subscription response") }
                            subscribed = true
                            refresh = true
                        } else if let error = envelope.error {
                            throw CLIError("Herdr subscription \(error.code): \(error.message); reconnect to resync")
                        } else if envelope.event != nil {
                            // Events invalidate state; never apply potentially stale mutation payloads.
                            refresh = true
                        }
                    }
                    if refresh {
                        try deliverSnapshot(generation: current)
                    }
                }
            } catch {
                lock.lock()
                if generation == current { stateChanged(.failed(error.localizedDescription)) }
                lock.unlock()
            }
        }
    }

    private func deliverSnapshot(generation current: Int) throws {
        let result = try Self.request(Request(id: UUID().uuidString, method: "session.snapshot"), socketPath: socketPath, endpoint: endpoint)
        guard result.type == "session_snapshot", var snapshot = result.snapshot else { throw CLIError("Invalid Herdr snapshot") }
        try HerdrServerInfo(version: snapshot.version, protocolVersion: snapshot.protocolVersion).validate()
        lock.lock()
        if generation == current { snapshotReceived(snapshot); stateChanged(.subscribed) }
        lock.unlock()
    }

    func disconnect() {
        lock.lock()
        generation += 1
        if let fd = subscriptionFD { _ = shutdown(fd, SHUT_RDWR) }
        subscriptionFD = nil
        stateChanged(.disconnected)
        lock.unlock()
    }
}
