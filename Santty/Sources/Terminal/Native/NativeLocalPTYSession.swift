import Darwin
import Foundation
import SwiftTerm

// Standalone LocalProcess / serial lifecycle adaptation; see the PTY notice.
enum NativeLocalPTYState: Equatable, Sendable {
    case idle, starting, running, closing, exited(Int32?), outputIncomplete(Int32?), failed(LocalProcessError)
    var acceptsInput: Bool { self == .running }
}
enum NativeLocalPTYError: Error, Equatable, Sendable {
    case closed, invalidArgument, inputBackpressure, write(LocalProcessError), shutdownTimeout
}

struct NativeLocalPTYInfo: Sendable {
    let shellPid: Int32
    let foregroundProcessGroupID: Int32?
    let foregroundPid: Int32?
    let ttyName: String
    let workingDirectory: String?
}


/// Owns exactly one local launch, independent of views and private lab files.
/// Production hosts must await stop() before removing the pane/binding.
@MainActor
final class NativeLocalPTYSession {
    let paneID: UUID
    let output: NativeTerminalOutput
    private let bridge: NativeLocalPTYBridge
    private var cleanup: Task<Void, Error>?
    private var closed = false
    private var revision: UInt64 = 0
    var onStateChange: ((NativeLocalPTYState) -> Void)?
    var state: NativeLocalPTYState { bridge.state }
    var lastWriteError: NativeLocalPTYError? { bridge.lastWriteError }
    var processInfo: NativeLocalPTYInfo? { bridge.processInfo() }
    var pendingInputBytes: Int { bridge.pendingInputBytes }
    var outputDrainComplete: Bool? { bridge.outputDrainComplete }

    init(paneID: UUID, driver: GhosttyVTDriver,
         onPresentation: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.paneID = paneID
        output = NativeTerminalOutput(driver: driver, onPresentation: onPresentation)
        bridge = NativeLocalPTYBridge(output: output)
        let bridge = self.bridge
        output.bindChecked(writer: { [weak bridge] data in bridge?.enqueue(data, automatic: false) ?? false },
            automaticReplies: { [weak bridge] data in bridge?.enqueue(data, automatic: true) ?? false })
        bridge.observe { [weak self] revision, state in
            guard let self, revision > self.revision else { return }
            self.revision = revision
            guard state == self.state else { return }
            self.onStateChange?(state)
        }
    }

    isolated deinit {
        guard !closed, cleanup == nil else { return }
        let bridge = bridge
        Task.detached { try? await Self.close(bridge) }
    }

    func start(_ launch: NativeLocalPTYLaunch, viewport: TerminalStreamViewport) throws {
        guard !closed, state == .idle else { throw NativeLocalPTYError.closed }
        guard launch.paneID == paneID else { throw NativeLocalPTYError.invalidArgument }
        output.reset()
        try updateDriver(viewport)
        try bridge.start(executable: launch.executable, args: launch.arguments,
            environment: launch.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" },
            execName: launch.execName, cwd: launch.workingDirectory, size: Self.size(viewport))
    }

    @discardableResult
    func updateViewport(_ viewport: TerminalStreamViewport) -> Bool {
        do { try updateDriver(viewport); return bridge.resize(Self.size(viewport)) }
        catch { return false }
    }

    private func updateDriver(_ viewport: TerminalStreamViewport) throws {
        let driver = output.driver, metrics = driver.cellSizePixels
        if driver.columns != Int(viewport.columns) || driver.rows != Int(viewport.rows)
            || metrics.width != viewport.cellWidthPixels || metrics.height != viewport.cellHeightPixels {
            let replies = try driver.resize(columns: Int(viewport.columns), rows: Int(viewport.rows),
                cellWidth: viewport.cellWidthPixels, cellHeight: viewport.cellHeightPixels)
            output.sendAutomaticReplies(replies)
        }
    }

    private static func size(_ viewport: TerminalStreamViewport) -> winsize {
        winsize(ws_row: viewport.rows, ws_col: viewport.columns,
            ws_xpixel: UInt16(clamping: viewport.widthPixels), ws_ypixel: UInt16(clamping: viewport.heightPixels))
    }

    /// Synchronously stop admission before any asynchronous close barrier.
    /// Does not wait/join, drop the driver or remove files.
    func beginClosing() { bridge.requestStop(force: false) }

    /// Cancellation of a caller cannot abandon an already-started shutdown.
    /// Failures retain the owner; a later explicit stop may try cleanup again.
    func stop() async throws {
        if let cleanup { return try await cleanup.value }
        guard !closed else { return }
        beginClosing()
        let bridge = bridge
        let task = Task { try await Self.awaitClose(bridge) }
        cleanup = task
        do { try await task.value; closed = true }
        catch { cleanup = nil; throw error }
    }

    nonisolated private static func close(_ bridge: NativeLocalPTYBridge) async throws {
        bridge.requestStop(force: false)
        try await awaitClose(bridge)
    }

    nonisolated private static func awaitClose(_ bridge: NativeLocalPTYBridge) async throws {
        let escalation = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            bridge.requestStop(force: true)
        }
        defer { escalation.cancel() }
        try await bridge.waitForExit(timeout: 5)
    }
}

/// Audited non-Sendable runner boundary: the recursive lock serializes runner
/// calls/state. Output uses the runner's serial parse worker directly, never
/// main or a sync hop to the lifecycle queue. Natural exit waits for that
/// callback to finish; no second output history is kept.
private final class NativeLocalPTYBridge: LocalProcessDelegate, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let output: NativeTerminalOutput
    private var process: LocalProcess!
    private var phase = NativeLocalPTYState.idle
    private var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 640, ws_ypixel: 384)
    private var observer: (@MainActor @Sendable (UInt64, NativeLocalPTYState) -> Void)?
    private var revision: UInt64 = 0
    private var pending: [Data] = []
    private var inFlight = 0
    private var queuedBytes = 0
    private var writeError: NativeLocalPTYError?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    static let maximumInputBytes = 1024 * 1024
    static let maximumInputChunks = 1024

    init(output: NativeTerminalOutput) {
        self.output = output
        // An unstarted pane owns no PTY runtime, descriptor or IO pipeline.
        // SwiftTerm's idle pipeline must not be retired as a launched process.
    }
    var state: NativeLocalPTYState { lock.withLock { phase } }
    var lastWriteError: NativeLocalPTYError? { lock.withLock { writeError } }
    var pendingInputBytes: Int { lock.withLock { queuedBytes } }
    var outputDrainComplete: Bool? { lock.withLock { process?.outputDrainComplete } }
    func observe(_ body: @escaping @MainActor @Sendable (UInt64, NativeLocalPTYState) -> Void) { lock.withLock { observer = body } }
    private func publish() {
        revision &+= 1
        let revision = revision, phase = phase, observer = observer
        Task { @MainActor in observer?(revision, phase) }
    }
    func start(executable: String, args: [String], environment: [String], execName: String?, cwd: String, size: winsize) throws {
        try lock.withLock {
            guard phase == .idle else { throw NativeLocalPTYError.closed }
            phase = .starting; self.size = size; publish()
            process = LocalProcess(delegate:self,dispatchQueue:DispatchQueue(label:"santty.native-pty.lifecycle"),directDelivery:true)
            process.completeAvailableOutputOnExit = true
            switch process.startProcessChecked(executable: executable, args: args, environment: environment, execName: execName, currentDirectory: cwd) {
            case .success: phase = .running; output.setInputEnabled(true); publish()
            case .failure(let error): phase = .failed(error); output.setInputEnabled(false); publish(); throw error
            }
        }
    }
    func resize(_ size: winsize) -> Bool {
        lock.withLock { self.size = size; var size = size; return process?.updateWindowSize(&size) ?? false }
    }
    func getWindowSize() -> winsize { lock.withLock { size } }
    func enqueue(_ bytes: Data, automatic: Bool) -> Bool {
        lock.withLock {
            guard phase == .running || (automatic && phase == .closing) else { return false }
            guard !bytes.isEmpty else { return true }
            guard bytes.count <= Self.maximumInputBytes - queuedBytes, pending.count < Self.maximumInputChunks else {
                writeError = .inputBackpressure; publish(); return false
            }
            pending.append(bytes); queuedBytes += bytes.count
            pump()
            return true
        }
    }
    private func pump() {
        guard inFlight == 0, !pending.isEmpty else { return }
        let bytes = pending.removeFirst(); inFlight = bytes.count
        process.send(data: Array(bytes)[...]) { [weak self] result in self?.completed(result) }
    }
    private func completed(_ result: Result<Int, LocalProcessError>) {
        lock.withLock {
            guard phase == .running || phase == .closing else { return }
            queuedBytes -= inFlight; inFlight = 0
            switch result {
            case .success: pump()
            case .failure(let error):
                pending = []; queuedBytes = 0; writeError = .write(error); publish()
                // Partial writes are not retried: the child may have consumed
                // any prefix. Input is never replayed on another process.
            }
        }
    }
    func dataReceived(slice: ArraySlice<UInt8>) {
        guard lock.withLock({ phase == .running || phase == .closing }) else { return }
        output.receive(Data(slice))
    }
    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        lock.withLock { phase = .failed(error); output.setInputEnabled(false); publish() }
    }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        let completions = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            guard source === process else { return [] }
            // Explicit close can discard output, but a natural incomplete
            // drain must not masquerade as a normal successful exit.
            phase = phase == .closing || source.outputDrainComplete == true ? .exited(exitCode) : .outputIncomplete(exitCode)
            pending = []; queuedBytes = 0; inFlight = 0
            output.setInputEnabled(false); publish()
            let completions = Array(waiters.values); waiters = [:]
            return completions
        }
        completions.forEach { $0.resume() }
    }
    func requestStop(force: Bool) {
        let completions = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            output.setInputEnabled(false)
            if phase == .idle { phase = .exited(nil); publish() }
            switch phase {
            case .running, .closing:
                phase = .closing
                pending = []; queuedBytes = inFlight
                process.terminateTerminal(force: force); publish()
                return []
            case .exited, .outputIncomplete, .failed:
                let completions = Array(waiters.values); waiters = [:]; return completions
            default: return []
            }
        }
        completions.forEach { $0.resume() }
    }
    func waitForExit(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let done = lock.withLock { () -> Bool in
                switch phase {
                case .exited, .outputIncomplete, .failed: return true
                default: waiters[id] = continuation; return false
                }
            }
            if done { continuation.resume(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
                waiter?.resume(throwing: NativeLocalPTYError.shutdownTimeout)
            }
        }
    }

    func processInfo() -> NativeLocalPTYInfo? {
        lock.withLock {
            guard let info = process?.terminalInfo() else { return nil }
            var foreground: Int32?, directory: String?
            if let group = info.foregroundProcessGroupID, getsid(group) == info.shellPid {
                var before = proc_bsdinfo(), after = proc_bsdinfo(), paths = proc_vnodepathinfo(), tty = stat()
                let length = Int32(MemoryLayout<proc_bsdinfo>.size)
                if stat(info.ttyName, &tty) == 0,
                   proc_pidinfo(group, PROC_PIDTBSDINFO, 0, &before, length) == length,
                   before.pbi_pgid == UInt32(group), before.e_tdev == UInt32(bitPattern: tty.st_rdev),
                   proc_pidinfo(group, PROC_PIDVNODEPATHINFO, 0, &paths, Int32(MemoryLayout<proc_vnodepathinfo>.size)) == MemoryLayout<proc_vnodepathinfo>.size,
                   proc_pidinfo(group, PROC_PIDTBSDINFO, 0, &after, length) == length,
                   before.pbi_start_tvsec == after.pbi_start_tvsec, before.pbi_start_tvusec == after.pbi_start_tvusec,
                   before.pbi_pgid == after.pbi_pgid, before.e_tdev == after.e_tdev,
                   process?.terminalInfo()?.foregroundProcessGroupID == group {
                    foreground = group
                    directory = withUnsafeBytes(of: &paths.pvi_cdir.vip_path) { raw in
                        let bytes = raw.bindMemory(to: UInt8.self)
                        return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
                    }
                }
            }
            return NativeLocalPTYInfo(shellPid: info.shellPid, foregroundProcessGroupID: info.foregroundProcessGroupID,
                foregroundPid: foreground, ttyName: info.ttyName, workingDirectory: directory)
        }
    }
}
