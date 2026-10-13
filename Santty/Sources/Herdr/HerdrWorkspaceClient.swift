import Foundation

enum HerdrPaneTransport: String, Codable, Sendable {
    case clientShell

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard ["clientShell", "direct"].contains(value) else { throw CLIError("Unsupported saved Herdr transport") }
        self = .clientShell
    }
}

struct HerdrEndpoint: Codable, Sendable, Equatable {
    let binary: URL
    let session: String
    let socketPath: String

    func validate() throws {
        guard binary.isFileURL, binary.path.hasPrefix("/"),
              (try? binary.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isExecutableFile(atPath: binary.path), socketPath.hasPrefix("/"),
              !session.isEmpty, session.utf8.count <= 64,
              session.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { throw CLIError("Choose an executable Herdr binary and a valid existing session name") }
        try CLITransport.withAddress(socketPath) { _, _ in }
    }
}

struct HerdrPaneBinding: Codable, Sendable, Equatable {
    let endpoint: HerdrEndpoint
    let paneID: String
    let terminalID: String?
    let workspaceID: String
    let tabID: String
    let serviceIdentity: HerdrServiceIdentity?

    init(endpoint: HerdrEndpoint, pane: HerdrSnapshot.Pane, includeRuntime: Bool = false) throws {
        guard let workspaceID = pane.workspace_id, let tabID = pane.tab_id,
              [workspaceID, tabID, pane.pane_id].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 })
        else { throw CLIError("Herdr returned incomplete pane identity") }
        let runtime = pane.terminal_id.flatMap { !$0.isEmpty && $0.utf8.count <= 1024 ? $0 : nil }
        guard pane.serviceIdentity != nil, !includeRuntime || runtime != nil else {
            throw CLIError("Herdr returned incomplete runtime or service identity")
        }
        self.endpoint = endpoint
        serviceIdentity = pane.serviceIdentity
        paneID = pane.pane_id
        terminalID = includeRuntime ? runtime : nil
        self.workspaceID = workspaceID
        self.tabID = tabID
    }

    func matches(_ pane: HerdrSnapshot.Pane, requireRuntime: Bool = true) -> Bool {
        pane.pane_id == paneID && pane.workspace_id == workspaceID && pane.tab_id == tabID
            && (serviceIdentity == nil || pane.serviceIdentity == serviceIdentity)
            && (!requireRuntime || terminalID == nil || pane.terminal_id == terminalID)
    }

}

// Management queries are serialized separately from ClientShell commands.
final class HerdrWorkspaceClient: @unchecked Sendable {
    let endpoint: HerdrEndpoint
    private let requests = DispatchQueue(label: "Santty.Herdr.workspace")
    private let commandLock = NSLock()
    private weak var commandSession: HerdrClientShellSession?
    private var commandBootID: String?
    private var endpointCommand: (@MainActor @Sendable (String, HerdrConnection.Request.Params) async throws -> HerdrAPIEnvelope.Result)?
    init(endpoint: HerdrEndpoint) {
        self.endpoint = endpoint
    }

    @MainActor
    func routeCommands(to session: HerdrClientShellSession) throws {
        guard session.endpoint == endpoint else { throw CLIError("Herdr command endpoint changed") }
        commandLock.lock()
        defer { commandLock.unlock() }
        if endpointCommand != nil {
            guard commandSession === session else { throw CLIError("Herdr command client is already bound; use a new client for another session") }
            return
        }
        guard let identity = session.serviceIdentity, let boot = session.projection.snapshot?.boot_id else {
            throw CLIError("Herdr endpoint identity is not ready")
        }
        commandSession = session
        commandBootID = boot
        endpointCommand = { [weak session] method, params in
            guard let session, session.serviceIdentity != nil else {
                throw CLIError("Herdr ClientShell is disconnected; command was not sent through another transport")
            }
            guard session.serviceIdentity == identity, session.projection.snapshot?.boot_id == boot else {
                throw CLIError("Herdr service changed; command was not sent through another transport")
            }
            // A resize can invalidate presentation between the caller's check and this actor hop.
            if ["workspace.focus", "workspace.close", "workspace.rename", "tab.rename", "tab.focus", "pane.focus"].contains(method) {
                let deadline = ProcessInfo.processInfo.systemUptime + 12
                while !session.isPresentationReady {
                    try Task.checkCancellation()
                    guard session.serviceIdentity == identity, session.projection.snapshot?.boot_id == boot,
                          session.state != .disconnected else { throw CLIError("Herdr connection changed before navigation") }
                    if let failure = session.failure { throw failure }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw CLIError("Herdr navigation timed out waiting for presentation") }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            let bytes = try await session.request(method, params: params)
            guard session.serviceIdentity == identity, session.projection.snapshot?.boot_id == boot else {
                throw CLIError("Herdr service changed before command result could be applied")
            }
            let envelope = try JSONDecoder().decode(HerdrAPIEnvelope.self, from: bytes)
            guard var result = envelope.result else { throw CLIError("Missing Herdr endpoint command result") }
            result.assignServiceIdentity(identity)
            return result
        }
    }

    private func commandHandler() -> (@MainActor @Sendable (String, HerdrConnection.Request.Params) async throws -> HerdrAPIEnvelope.Result)? {
        commandLock.lock(); defer { commandLock.unlock() }; return endpointCommand
    }

    func snapshot() async throws -> HerdrSnapshot {
        let result = try await request("session.snapshot")
        guard let snapshot = result.snapshot else { throw CLIError("Missing Herdr snapshot") }
        return snapshot
    }

    @MainActor
    func orderedTabIDs(for binding: HerdrPaneBinding) async throws -> [String] {
        try await verify(binding, requireRuntime: commandHandler() == nil)
        if commandHandler() != nil {
            guard let session = commandSession, session.serviceIdentity == binding.serviceIdentity,
                  let snapshot = session.projection.snapshot, snapshot.boot_id == commandBootID,
                  session.isPresentationReady,
                  snapshot.workspaces.contains(where: { $0.workspace_id == binding.workspaceID }) else {
                throw CLIError("Herdr endpoint workspace changed or is not ready; no API fallback was used")
            }
            return snapshot.tabs.filter { $0.workspace_id == binding.workspaceID }.map(\.tab_id)
        }
        let metadata = try await snapshot()
        return metadata.tabs?.filter { $0.workspace_id == binding.workspaceID }.map(\.tab_id) ?? []
    }

    func request(_ method: String, params: HerdrConnection.Request.Params = .init()) async throws -> HerdrAPIEnvelope.Result {
        if !["ping", "session.snapshot", "layout.export", "pane.read", "pane.process_info", "agent.list"].contains(method),
           let command = commandHandler() {
            return try await command(method, params)
        }
        return try await withCheckedThrowingContinuation { continuation in
            requests.async { [self] in
                do {
                    try endpoint.validate()
                    _ = try HerdrConnection.preflight(socketPath: endpoint.socketPath)
                    let result: HerdrAPIEnvelope.Result
                    do {
                        result = try HerdrConnection.request(.init(id: UUID().uuidString, method: method, params: params), socketPath: endpoint.socketPath)
                    } catch {
                        if error is HerdrRemoteError { throw error }
                        if method != "session.snapshot" {
                            // A lost acknowledgement never authorizes repeating a mutation.
                            let snapshot = try? HerdrConnection.request(.init(id: UUID().uuidString, method: "session.snapshot"), socketPath: endpoint.socketPath).snapshot
                            let count = snapshot.map { String($0.panes.count) } ?? "unknown"
                            throw CLIError("\(method) failed or its result is unknown: \(error.localizedDescription). Refreshed pane count: \(count). Refresh Connect Existing Terminal before retrying; no operation was repeated.")
                        }
                        throw error
                    }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }


    @MainActor
    @discardableResult
    func verify(_ binding: HerdrPaneBinding, requireRuntime: Bool = true) async throws -> HerdrSnapshot.Pane {
        // shortcut: verification and mutation are separate requests; use conditional mutations when Herdr exposes an identity token.
        guard binding.endpoint == endpoint else { throw CLIError("Herdr endpoint changed") }
        if commandHandler() != nil, binding.terminalID == nil || !requireRuntime {
            guard let session = commandSession, let identity = session.serviceIdentity,
                  identity == binding.serviceIdentity, let snapshot = session.projection.snapshot,
                  snapshot.boot_id == commandBootID, session.isPresentationReady,
                  let pane = snapshot.panes.first(where: {
                      $0.pane_id == binding.paneID && $0.workspace_id == binding.workspaceID && $0.tab_id == binding.tabID
                  }) else { throw CLIError("Herdr endpoint target changed or is not ready; no API fallback was used") }
            return .init(pane_id: pane.pane_id, terminal_id: nil, workspace_id: pane.workspace_id, tab_id: pane.tab_id,
                label: pane.label, cwd: pane.cwd, foreground_cwd: pane.foreground_cwd, serviceIdentity: identity)
        }
        let snapshot = try await snapshot()
        guard (requireRuntime && binding.terminalID != nil) || binding.serviceIdentity != nil,
              let pane = snapshot.panes.first(where: { binding.matches($0, requireRuntime: requireRuntime) }) else { throw CLIError("Herdr terminal identity changed; refresh existing terminals before modifying it") }
        return pane
    }

    func create(workspaceID: String? = nil, split: HerdrPaneBinding? = nil, axis: SplitAxis = .horizontal,
                cwd: String? = nil) async throws -> HerdrSnapshot.Pane {
        var params = HerdrConnection.Request.Params()
        params.focus = commandHandler() != nil
        params.cwd = cwd
        let method: String
        if let split {
            let pane = try await verify(split)
            params.cwd = cwd ?? pane.foreground_cwd ?? pane.cwd
            method = "pane.split"
            params.target_pane_id = split.paneID
            params.direction = axis == .horizontal ? "right" : "down"
        } else if let workspaceID {
            method = "tab.create"
            params.workspace_id = workspaceID
        } else {
            method = "workspace.create"
            params.label = "Santty"
        }
        let result = try await request(method, params: params)
        guard let pane = result.root_pane ?? result.pane else { throw CLIError("Herdr created an object without a pane acknowledgement; refresh existing terminals before retrying") }
        return pane
    }
}
