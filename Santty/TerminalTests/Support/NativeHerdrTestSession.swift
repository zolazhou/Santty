import Foundation
@testable import Santty

/// Owns an entirely private core/session/config/home. The normal core and
/// existing terminals are never enumerated, attached, stopped or modified.
@MainActor
final class NativeHerdrTestSession {
    let root: URL
    let client: HerdrCoreClient
    let output: NativeTerminalOutput
    private(set) var session: HerdrTerminalSession!
    private let executable: URL
    private let environment: [String: String]
    private let defaults: UserDefaults
    private let defaultsName: String
    private var connection: HerdrCoreTransport?
    private var closed = false
    private var stopping = false
    private var connecting: Task<HerdrCoreTransport, Error>?
    private var cleanup: Task<Void, Error>?
    private var ownsCore = false
    private var lastState: HerdrTerminalSession.State?
    var onStateChange: ((HerdrTerminalSession.State) -> Void)?

    init(driver: GhosttyVTDriver,
         onPresentation: @escaping @MainActor @Sendable (Bool) -> Void) throws {
        executable = try HerdrCoreTransport.executable()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("santty-native-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        // Do not inherit user shell startup hooks, control sockets, credentials
        // or arbitrary HC_* routing overrides into the private test daemon.
        let allowed = Set(["PATH", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "COLORTERM", "TMPDIR"])
        var env = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        env["SHELL"] = "/bin/sh"
        env["HC_SESSION"] = "native-lab"
        env["HC_SOCKET"] = root.appendingPathComponent("core.sock").path
        env["XDG_RUNTIME_DIR"] = root.path
        for (key, directory) in [("XDG_STATE_HOME", "state"), ("XDG_CONFIG_HOME", "config"),
                                 ("XDG_CACHE_HOME", "cache"), ("XDG_DATA_HOME", "data"), ("HOME", "home")] {
            let url = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            env[key] = url.path
        }
        environment = env
        defaultsName = "SanttyTerminalLab.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)!
        client = HerdrCoreClient(executable: executable, environment: env, settings: HerdrSettings(defaults: defaults))
        output = NativeTerminalOutput(driver: driver, onPresentation: onPresentation)
        let output = self.output
        session = HerdrTerminalSession(paneID: UUID(), cwd: root.appendingPathComponent("home").path,
            binding: nil, client: client, outputFactory: { write, _ in
                output.bind(writer: write)
                return output
            }, displayColors: { driver.displayColors })
        session.onChange = { [weak self] in
            guard let self else { return }
            self.output.setInputEnabled(self.session.state == .live)
            if self.lastState != self.session.state {
                self.lastState = self.session.state
                self.onStateChange?(self.session.state)
            }
        }
    }

    func start(viewport: TerminalStreamViewport) async throws {
        guard !closed, !stopping, connecting == nil else {
            throw HerdrCoreError("This test session is closed or already starting", kind: "closed")
        }
        let client = self.client
        let task = Task { try await client.connection() }
        connecting = task
        defer { connecting = nil }
        let connection = try await task.value
        self.connection = connection
        // Fail closed if hc did not honor the private socket. Never send a
        // server-stop command to an unverified/default connection.
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("core.sock").path) else {
            connection.close()
            throw HerdrCoreError("hc did not create the private lab socket", kind: "isolation")
        }
        ownsCore = true
        guard !closed, !stopping else { throw CancellationError() }
        _ = session.output
        session.updateViewport(viewport)
        session.surfaceAttached()
        session.start()
    }

    func updateViewport(_ viewport: TerminalStreamViewport) { session.updateViewport(viewport) }
    func setFocused(_ focused: Bool) { session.setFocused(focused) }

    /// Replaces only this lab's hc connect transport; never restarts a core.
    func reconnect() async throws {
        guard !closed, !stopping else { return }
        try await client.reconnect()
        connection = try await client.connection()
    }

    /// Explicit end of the owned test terminal. Not used for external viewers.
    func stop() async throws {
        if let cleanup { return try await cleanup.value }
        guard !closed else { return }
        stopping = true
        output.setInputEnabled(false)
        let task = Task { @MainActor in try await self.stopOnce() }
        cleanup = task
        do { try await task.value }
        catch { cleanup = nil; stopping = false; throw error }
    }

    private func stopOnce() async throws {
        // A quit racing the helper handshake must wait for ownership to be
        // established, rather than remove its socket directory underneath it.
        if let connecting {
            if let connection = try? await connecting.value { self.connection = connection }
            ownsCore = FileManager.default.fileExists(atPath: root.appendingPathComponent("core.sock").path)
        }
        output.setInputEnabled(false)
        try await session.closeTerminal()
        connection?.close()
        connection = nil
        if !ownsCore {
            closed = true
            defaults.removePersistentDomain(forName: defaultsName)
            try FileManager.default.removeItem(at: root)
            return
        }
        // This environment was constructed here, with a unique private socket.
        // Stop only this private core, off the main thread.
        let executable = self.executable, environment = self.environment
        let status = try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["server", "stop"]
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            defer { timeout.cancel() }
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        guard status == 0 else { throw HerdrCoreError("Private core cleanup failed", kind: "cleanup") }
        closed = true
        defaults.removePersistentDomain(forName: defaultsName)
        try FileManager.default.removeItem(at: root)
    }
}
