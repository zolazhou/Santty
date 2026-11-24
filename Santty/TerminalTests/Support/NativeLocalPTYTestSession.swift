import Foundation
@testable import Santty

/// Private filesystem/environment fixture only. PTY ownership lives in the
/// reusable session used by production panes. Never compiled into the app.
@MainActor
final class NativeLocalPTYTestSession {
    let root: URL
    let home: URL
    private let session: NativeLocalPTYSession
    let environment: [String: String]
    private var cleanup: Task<Void, Error>?
    private var closed = false
    var output: NativeTerminalOutput { session.output }
    var onStateChange: ((NativeLocalPTYState) -> Void)? {
        get { session.onStateChange }
        set { session.onStateChange = newValue }
    }
    var state: NativeLocalPTYState { session.state }
    var lastWriteError: NativeLocalPTYError? { session.lastWriteError }
    var processInfo: NativeLocalPTYInfo? { session.processInfo }
    var pendingInputBytes: Int { session.pendingInputBytes }
    var outputDrainComplete: Bool? { session.outputDrainComplete }

    init(driver: GhosttyVTDriver, inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
         onPresentation: @escaping @MainActor @Sendable (Bool) -> Void) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("santty-pty-\(UUID())", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var env = inheritedEnvironment.filter { ["PATH", "LANG", "LC_ALL", "LC_CTYPE"].contains($0.key) }
        do {
            for (key, name) in [("HOME", "home"), ("TMPDIR", "tmp"), ("XDG_CONFIG_HOME", "config"),
                                ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state")] {
                let directory = root.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                env[key] = directory.path
            }
        } catch { try? FileManager.default.removeItem(at: root); throw error }
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["SHELL"] = "/bin/sh"; env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"; env["TERM_PROGRAM"] = "SanttyTerminalLab"
        environment = env
        session = NativeLocalPTYSession(paneID: UUID(), driver: driver, onPresentation: onPresentation)
    }

    isolated deinit {
        guard !closed, cleanup == nil else { return }
        let session = session, root = root
        Task {
            do {
                try await session.stop()
                try await Task.detached(priority: .utility) { try FileManager.default.removeItem(at: root) }.value
            } catch { /* preserve private files if cleanup cannot be verified */ }
        }
    }

    func start(viewport: TerminalStreamViewport, executable: String = "/bin/sh", args: [String] = ["-i"],
               workingDirectory: URL? = nil) throws {
        guard !closed, state == .idle else { throw NativeLocalPTYError.closed }
        let cwd = (workingDirectory ?? home).path
        var env = environment; env["PWD"] = cwd
        let launch = try NativeLocalPTYLaunch(paneID: session.paneID, executable: executable, arguments: args,
            environment: env, workingDirectory: cwd)
        try session.start(launch, viewport: viewport)
    }

    @discardableResult
    func updateViewport(_ viewport: TerminalStreamViewport) -> Bool { session.updateViewport(viewport) }

    func stop() async throws {
        if let cleanup { return try await cleanup.value }
        guard !closed else { return }
        // Stop admission now, not on the next turn when the task starts.
        session.beginClosing()
        let session = session, root = root
        let task = Task {
            try await session.stop()
            try await Task.detached(priority: .utility) { try FileManager.default.removeItem(at: root) }.value
        }
        cleanup = task
        do { try await task.value; closed = true }
        catch { cleanup = nil; throw error }
    }
}
