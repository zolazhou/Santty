import AppKit
import Combine

struct InputSourceForeground: Sendable {
    struct Process: Sendable {
        let id: Int
        let name: String
        var command: String? = nil

        var program: String {
            let executable = Self.normalized(name)
            guard ["node", "nodejs", "bun", "deno"].contains(executable), let command else { return executable }
            // shortcut: ps flattens argv, read native argv if wrapper paths with spaces need support.
            let arguments = command.split(whereSeparator: \.isWhitespace).dropFirst()
            guard let script = arguments.first(where: { !$0.hasPrefix("-") }) else { return executable }
            let path = String(script)
            if path.hasSuffix("/@anthropic-ai/claude-code/cli.js") { return "claude" }
            if path.hasSuffix("/@openai/codex/bin/codex.js") { return "codex" }
            return executable
        }

        static func normalized(_ value: String) -> String {
            let name = (value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent.lowercased()
            return name.hasSuffix(".exe") ? String(name.dropLast(4)) : name
        }
    }

    let groupID: Int?
    let processes: [Process]

    @MainActor
    func match(_ rules: [InputSourceSettings.Rule]) -> (Process, InputSourceSettings.Rule)? {
        // An editor launched by an agent can share its foreground process group.
        let ordered = processes.sorted {
            if ($0.program == "nvim") != ($1.program == "nvim") { return $0.program == "nvim" }
            return $0.id > $1.id
        }
        for process in ordered {
            if let rule = rules.first(where: {
                let name = Process.normalized($0.program)
                return !name.isEmpty && !name.contains(where: \.isWhitespace) && name == process.program
            }) {
                return (process, rule)
            }
        }
        return nil
    }
}

@MainActor
final class PaneInputSourceCoordinator: ObservableObject {
    static let shared = PaneInputSourceCoordinator()

    struct Target {
        let paneID: UUID
        let view: NSView
        let foreground: @MainActor () async throws -> InputSourceForeground
    }

    private struct Context: Equatable {
        let paneID: UUID
        let groupID: Int?
        let processID: Int?
        let program: String?
        let sourceID: String?
    }

    @Published private(set) var lastError: String?
    var targetProvider: (() -> Target?)?
    private let configuration: () -> InputSourceSettings.Configuration
    private let currentSource: () -> String?
    private let selectSource: (String, NSView) -> Bool
    private let isActive: () -> Bool
    private let inputView: () -> NSView?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var query: Task<Void, Never>?
    private var paletteRestoreTask: Task<Void, Never>?
    private var generation = 0
    private var targetID: UUID?
    private weak var targetView: NSView?
    private var appliedContext: Context?
    private var paletteIsOpen = false
    private var paletteSourceApplied = false
    private var sourceBeforePalette: String?
    private var pendingRestore: String?

    init(configuration: @escaping () -> InputSourceSettings.Configuration = { InputSourceSettings.configuration },
         currentSource: @escaping () -> String? = { SystemInputSources.currentID },
         selectSource: @escaping (String, NSView) -> Bool = { SystemInputSources.select($0, for: $1) },
         isActive: @escaping () -> Bool = { NSApp.isActive },
         inputView: @escaping () -> NSView? = { NSApp.keyWindow?.firstResponder as? NSView }) {
        self.configuration = configuration
        self.currentSource = currentSource
        self.selectSource = selectSource
        self.isActive = isActive
        self.inputView = inputView
    }

    func start() {
        guard observers.isEmpty else { return }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     InputSourceSettings.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let settingsChanged = note.name == InputSourceSettings.didChangeNotification
                MainActor.assumeIsolated {
                    if settingsChanged {
                        self?.lastError = nil
                        self?.invalidateContext()
                    }
                    self?.refresh()
                }
            })
        }
        refresh()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        invalidateContext()
        paletteRestoreTask?.cancel(); paletteRestoreTask = nil
        targetProvider = nil
        paletteIsOpen = false
        sourceBeforePalette = nil
        pendingRestore = nil
    }

    func paletteWillOpen() {
        guard !paletteIsOpen else { return }
        paletteIsOpen = true
        paletteSourceApplied = false
        paletteRestoreTask?.cancel(); paletteRestoreTask = nil
        sourceBeforePalette = configuration().commandPaletteEnglish ? (pendingRestore ?? currentSource()) : nil
        pendingRestore = nil
        generation += 1
        query?.cancel(); query = nil
    }

    func paletteDidFocus(_ view: NSView) {
        let settings = configuration()
        guard settings.commandPaletteEnglish, !paletteSourceApplied, isActive(), !hasMarkedText(view) else { return }
        paletteSourceApplied = true
        select(settings.englishInputSourceID, for: view)
    }

    func paletteDidClose() {
        guard paletteIsOpen else { return }
        paletteIsOpen = false
        if let sourceBeforePalette {
            pendingRestore = sourceBeforePalette
            invalidateContext()
        }
        sourceBeforePalette = nil
        // The dismiss callback or selected command establishes the destination responder first.
        paletteRestoreTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.paletteRestoreTask = nil
            self?.refresh()
        }
    }

    func refresh() {
        updateTimer()
        guard isActive() else {
            invalidateContext()
            pendingRestore = nil
            return
        }
        guard !paletteIsOpen else { return }
        let settings = configuration()
        guard let target = targetProvider?() else {
            invalidateContext()
            restoreIfNeeded(to: inputView())
            return
        }
        if target.paneID != targetID || target.view !== targetView {
            invalidateContext()
            targetID = target.paneID
            targetView = target.view
        }
        guard settings.paneRulesEnabled else {
            restoreIfNeeded(to: target.view)
            return
        }
        guard query == nil else { return }
        let epoch = generation
        let sourceAtRequest = currentSource()
        query = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let foreground: InputSourceForeground
            do { foreground = try await target.foreground() }
            catch {
                guard let self, self.generation == epoch else { return }
                self.query = nil
                if self.isActive(), !self.paletteIsOpen,
                   let current = self.targetProvider?(), current.paneID == target.paneID,
                   current.view === target.view { self.restoreIfNeeded(to: target.view) }
                return
            }
            guard let self, self.generation == epoch else { return }
            self.query = nil
            guard !Task.isCancelled, self.isActive(), !self.paletteIsOpen,
                  let current = self.targetProvider?(), current.paneID == target.paneID,
                  current.view === target.view else { return }
            let match = foreground.match(settings.rules)
            let sourceID = match.map { settings.sourceID(for: $0.1) }
            let context = Context(paneID: target.paneID, groupID: foreground.groupID,
                                  processID: match?.0.id, program: match?.0.program, sourceID: sourceID)
            guard context != self.appliedContext || self.pendingRestore != nil,
                  !self.hasMarkedText(target.view) else { return }
            // A manual selection made while a slow process query was pending wins.
            if self.currentSource() == sourceAtRequest,
               let desired = sourceID.flatMap({ $0.isEmpty ? nil : $0 }) ?? self.pendingRestore {
                self.select(desired, for: target.view)
            }
            self.pendingRestore = nil
            self.appliedContext = context
        }
    }

    private func invalidateContext() {
        generation += 1
        query?.cancel(); query = nil
        targetID = nil
        targetView = nil
        appliedContext = nil
    }

    private func select(_ id: String, for view: NSView) {
        guard !id.isEmpty else { lastError = "Choose an input source in Terminal settings."; return }
        guard currentSource() != id else { lastError = nil; return }
        lastError = selectSource(id, view) ? nil : "Could not select the configured input source. Check that it is enabled in System Settings."
    }

    private func hasMarkedText(_ view: NSView) -> Bool {
        (view as? NSTextInputClient)?.hasMarkedText() == true
    }

    private func restoreIfNeeded(to view: NSView?) {
        guard let id = pendingRestore, let view, view.inputContext != nil, !hasMarkedText(view) else { return }
        select(id, for: view)
        pendingRestore = nil
    }

    private func updateTimer() {
        let needed = isActive() && (configuration().paneRulesEnabled || pendingRestore != nil)
        if needed, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } else if !needed {
            timer?.invalidate(); timer = nil
        }
    }

    func waitForPendingQuery() async {
        await paletteRestoreTask?.value
        await query?.value
    }
}
