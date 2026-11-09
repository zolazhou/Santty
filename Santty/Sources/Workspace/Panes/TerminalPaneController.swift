import AppKit
import Darwin
import GhosttyTerminal

@MainActor
final class TerminalPaneController: NSObject, PaneControlling {
    let id: PaneID
    private let terminalHostView: TerminalPaneHostView

    var hostView: NSView {
        terminalHostView
    }

    private let terminalView: TerminalView
    private let terminalController: TerminalController
    let herdrSession: HerdrTerminalSession?
    private let openURL: @MainActor (URL) -> Bool
    private let foregroundProcessIDProvider: @MainActor () -> Int32?
    private let processWorkingDirectoryProvider: (Int32) -> String?

    private(set) var isLive = true
    private(set) var hasStarted = false
    private(set) var lastKnownTitle = "Shell"
    var name: String? {
        didSet { terminalHostView.nameBadge.name = name }
    }
    private(set) var currentWorkingDirectory: String?
    private var isFloating = false
    private var paneIsFocused = false
    private(set) var isScrollModeActive = false
    private var isAwaitingSecondScrollModeG = false

    var onFocusRequest: ((PaneID) -> Void)? {
        didSet {
            terminalHostView.onFocusRequest = onFocusRequest
        }
    }

    var onTitleChange: ((PaneID) -> Void)?
    var onExit: ((PaneID) -> Void)?

    var displayTitle: String {

        if let herdrSession {
            switch herdrSession.state {
            case .connecting: return lastKnownTitle + " (Connecting)"
            case .disconnected: return lastKnownTitle + " (Disconnected)"
            case let .failed(message): return message
            case .live, .finished: break
            }
        }
        return isLive ? lastKnownTitle : "\(lastKnownTitle) (Exited)"
    }

    var focusTargetView: NSView {
        return terminalHostView.scrollModeView ?? (isLive && (herdrSession == nil || herdrSession?.state == .live) ? terminalView : terminalHostView)
    }


    var foregroundProcessID: Int? {
        if let herdrSession { return herdrSession.record?.foreground.map { Int($0.pid) } }
        guard isLive, let processID = foregroundProcessIDProvider() else {
            return nil
        }

        return Int(processID)
    }

    func inputSourceForeground() async throws -> InputSourceForeground {

        if let session = herdrSession, session.remote != nil {
            guard session.state == .live, let foreground = session.record?.foreground else {
                throw CLIError("Remote foreground process information is unavailable")
            }
            return InputSourceForeground(groupID: Int(foreground.pid), processes: [
                .init(id: Int(foreground.pid), name: foreground.name, command: foreground.name)
            ])
        }
        guard let groupID = foregroundProcessID else { throw CLIError("Foreground process information is unavailable") }
        let processes = await Task.detached(priority: .utility) {
            TerminalProcessInspector.currentProcessTable().filter { $0.processGroupID == groupID }
                .map { InputSourceForeground.Process(id: $0.processID, name: $0.executableName ?? "", command: $0.command) }
        }.value
        try Task.checkCancellation()
        guard foregroundProcessID == groupID else { throw CLIError("Foreground process changed during lookup") }
        return InputSourceForeground(groupID: groupID, processes: processes)
    }

    var inputSourceTargetView: NSView? {
        guard isLive, !isScrollModeActive, herdrSession == nil || herdrSession?.state == .live else { return nil }
        return terminalView
    }

    var workingDirectoryForNewPane: String? {
        if let herdrSession { return herdrSession.record?.foreground?.cwd ?? currentWorkingDirectory }
        guard
            isLive,
            let processID = foregroundProcessIDProvider(),
            let processWorkingDirectory = processWorkingDirectoryProvider(processID),
            !processWorkingDirectory.isEmpty
        else {
            return currentWorkingDirectory
        }

        return processWorkingDirectory
    }

    init(
        id: PaneID = UUID(),
        workingDirectory: String? = nil,
        herdrSession: HerdrTerminalSession? = nil,
        foregroundProcessIDProvider: (@MainActor () -> Int32?)? = nil,
        processWorkingDirectoryProvider: @escaping (Int32) -> String? = {
            ProcessWorkingDirectoryResolver.workingDirectory(for: $0)
        },
        openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.id = id
        self.herdrSession = herdrSession
        self.openURL = openURL
        currentWorkingDirectory = workingDirectory

        let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        let terminalController = TerminalController(
            configuration: Self.terminalConfiguration(
                for: id,
                workingDirectory: workingDirectory
            ),
            theme: TerminalDefaults.theme
        )
        terminalView.configuration = TerminalSurfaceOptions(backend: herdrSession.map { .inMemory($0.memory) } ?? .exec)
        terminalView.controller = terminalController

        self.terminalView = terminalView
        self.terminalController = terminalController
        self.foregroundProcessIDProvider = foregroundProcessIDProvider ?? {
            [weak terminalView] in
            terminalView?.foregroundPid
        }
        self.processWorkingDirectoryProvider = processWorkingDirectoryProvider
        terminalHostView = TerminalPaneHostView(paneID: id, terminalView: terminalView)

        super.init()

        terminalView.delegate = self
        herdrSession?.onReset = { [weak self] in self?.exitScrollMode() }
        herdrSession?.onChange = { [weak self] in
            guard let self, let session = self.herdrSession else { return }
            if let record = session.record {
                if !record.title.isEmpty { self.lastKnownTitle = record.title }
                self.currentWorkingDirectory = record.foreground?.cwd ?? record.cwd
            }
            switch session.state {
            case .disconnected, .failed: self.terminalHostView.setRetryAction { [weak session] in session?.retry() }
            default: self.terminalHostView.setRetryAction(nil)
            }
            let wasLive = self.isLive
            self.isLive = session.state != .finished
            self.onTitleChange?(self.id)
            if session.state == .live, self.paneIsFocused, !self.isScrollModeActive,
               self.terminalView.window?.firstResponder === self.terminalHostView {
                self.terminalView.window?.makeFirstResponder(self.terminalView)
            }
            if wasLive, !self.isLive { self.exitScrollMode(); self.onExit?(self.id) }
        }
        if terminalView.scrollModeGrid != nil { herdrSession?.surfaceAttached() }
        updatePresentation(isFocused: false)
    }

    deinit {
        MainActor.assumeIsolated {
            terminalView.delegate = nil
            // Draining the view's controller frees its Ghostty surface, and
            // that free joins the surface's IO thread without a timeout.
            // Doing it from the deallocation of the pane that owns the view
            // parks the main thread whenever the IO thread misses its quit
            // wakeup: the app stops answering events until it is force quit.
            // Retire the view on a later runloop turn instead, outside the
            // release cascade that is running right now.
            TerminalViewRetirement.retire(terminalView)
        }
    }

    func startIfNeeded() {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        herdrSession?.start()
    }

    func fitToSize() {
        terminalView.fitToSize()
    }

    func setNameVisible(_ visible: Bool) {
        terminalHostView.nameBadge.isRevealed = visible
    }

    func updatePresentation(isFocused: Bool, isFloating: Bool = false) {
        self.isFloating = isFloating
        paneIsFocused = isFocused
        terminalHostView.updatePresentation(
            isFocused: isFocused,
            isFloating: isFloating,
            isLive: isLive && (herdrSession == nil || herdrSession?.state == .live),
            displayTitle: displayTitle
        )
    }

    func copySelection(_ sender: Any?) {
        terminalHostView.copy(sender)
    }

    func readForCLI(_ request: CLIRequest) throws -> CLIResponse {
        // shortcut: snapshot the full buffer; use ranged Ghostty reads if polling becomes costly.
        guard let text = terminalView.readScreenText() else {
            throw CLIError("Terminal content is unavailable; the pane may not have started or may have closed.")
        }
        return try CLITextSnapshot.response(text, request: request)
    }

    /// Programmatic terminal input without selecting the pane, committing an IME
    /// composition, changing the clipboard, or leaving Scroll Mode.
    func sendForCLI(_ request: CLIRequest) throws {
        guard isLive, !isScrollModeActive, !terminalView.hasMarkedText(),
              herdrSession == nil || herdrSession?.state == .live else {
            throw CLIError("Terminal is not ready for input (offline, exited, Scroll Mode or IME composition). Input was not queued.", code: "input_unavailable")
        }
        let accepted: Bool
        if request.command == "pane.send-text" {
            accepted = terminalView.paste(text: request.text ?? "")
        } else {
            let key = try CLIKey(request.key ?? "")
            let named: [String: TerminalKey] = ["enter": .enter, "tab": .tab, "escape": .escape,
                "backspace": .backspace, "delete": .delete, "home": .home, "end": .end,
                "pageup": .pageUp, "pagedown": .pageDown, "left": .arrowLeft,
                "right": .arrowRight, "up": .arrowUp, "down": .arrowDown]
            var modifiers: TerminalInputModifiers = []
            if key.control { modifiers.insert(.ctrl) }
            if key.shift { modifiers.insert(.shift) }
            let press: TerminalKeyPress?
            if let namedKey = named[key.base] { press = TerminalKeyPress(namedKey, modifiers: modifiers) }
            else { press = key.base.first.flatMap { TerminalKeyPress(typing: $0, modifiers: modifiers) } }
            guard let press else { throw CLIError("Unsupported key.") }
            accepted = terminalView.sendKey(press)
        }
        guard accepted else { throw CLIError("Terminal surface did not accept input. The pane may not have started.", code: "input_unavailable") }
    }

    func enterScrollMode() {

        guard isLive, !isScrollModeActive, herdrSession == nil || herdrSession?.state == .live else {
            return
        }

        guard terminalController.setTerminalConfiguration(Self.terminalConfiguration(
            for: id, workingDirectory: currentWorkingDirectory, scrollMode: true
        )) else {
            NSSound.beep()
            return
        }
        terminalView.clearScrollModeSelection()

        isScrollModeActive = true
        isAwaitingSecondScrollModeG = false
        terminalHostView.showScrollMode()
    }

    func exitScrollMode() {
        guard isScrollModeActive else {
            return
        }

        isScrollModeActive = false
        isAwaitingSecondScrollModeG = false

        terminalHostView.hideScrollMode()
        terminalController.setTerminalConfiguration(Self.terminalConfiguration(
            for: id, workingDirectory: currentWorkingDirectory
        ))
    }

    func handleScrollModeKeyEvent(_ event: NSEvent) -> Bool {
        guard isScrollModeActive, event.type == .keyDown else {
            return false
        }
        if let eventWindow = event.window {
            guard eventWindow === terminalView.window,
                  eventWindow.firstResponder === terminalHostView.scrollModeView
            else { return false }
        }

        let action = TerminalScrollModeKeyAction(
            event: event,
            awaitingSecondG: isAwaitingSecondScrollModeG
        )
        isAwaitingSecondScrollModeG = false

        switch action {
        case .exit:
            exitScrollMode()
        case .cancel:
            if terminalHostView.scrollModeView?.cancelSelection() != true { exitScrollMode() }
        case let .move(movement):
            terminalHostView.scrollModeView?.move(movement)
        case let .select(linewise):
            terminalHostView.scrollModeView?.toggleSelection(linewise: linewise)
        case .copy:
            terminalHostView.scrollModeView?.copySelection()
        case .awaitSecondG:
            isAwaitingSecondScrollModeG = true
        case .consume:
            break
        }

        return true
    }

    func showPromptEditor(relativeTo window: NSWindow) {
        guard isLive else {
            NSSound.beep()
            return
        }

        let textView = PromptEditorTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        let alert = NSAlert()
        alert.messageText = "Prompt Editor"
        alert.informativeText = currentWorkingDirectory.map { "Current directory: \($0)" }
            ?? "Current directory is not available yet."
        alert.accessoryView = scrollView
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = textView
        textView.onCancel = { [weak alert] in
            guard let alert else {
                return
            }

            alert.window.sheetParent?.endSheet(
                alert.window,
                returnCode: .alertSecondButtonReturn
            )
        }

        alert.beginSheetModal(for: window) { [weak self, textView] response in
            guard response == .alertFirstButtonReturn else {
                return
            }

            guard let self else {
                return
            }

            let prompt = textView.string
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSSound.beep()
                return
            }

            self.submitPrompt(prompt)
        }
    }

    @discardableResult func submitPrompt(_ prompt: String) -> Bool {
        guard isLive, herdrSession == nil || herdrSession?.state == .live else { NSSound.beep(); return false }
        terminalView.window?.makeFirstResponder(terminalView)

        guard terminalView.paste(text: prompt) else { return false }
        return terminalView.sendKey(.enter)
    }

    func updateAppearance() {
        terminalHostView.updateAppearance()
    }

    func applyTerminalSettings() {
        herdrSession?.updateDisplay()

        let _ = terminalController.setTheme(TerminalDefaults.theme)
        let _ = terminalController.setTerminalConfiguration(
            Self.terminalConfiguration(
                for: id,
                workingDirectory: currentWorkingDirectory,
                scrollMode: isScrollModeActive
            )
        )
    }

    var debugBorderColor: NSColor {
        terminalHostView.debugBorderColor
    }

    var debugBorderWidth: CGFloat {
        terminalHostView.debugBorderWidth
    }

    var debugUsesHiddenWindowPresentation: Bool {
        terminalHostView.debugUsesHiddenWindowPresentation
    }

    var debugVibrancyBlendingMode: NSVisualEffectView.BlendingMode {
        terminalHostView.debugVibrancyBlendingMode
    }

    var debugVibrancyTintAlpha: CGFloat? {
        terminalHostView.debugVibrancyTintAlpha
    }

    var debugTerminalFrame: NSRect {
        terminalHostView.debugTerminalFrame
    }

    var debugTerminalPadding: CGFloat {
        terminalHostView.debugTerminalPadding
    }

    var debugPaneBounds: NSRect {
        terminalHostView.debugPaneBounds
    }

    var debugRenderedTerminalConfig: String {
        terminalController.renderedConfig
    }

    var debugScrollModeIndicatorIsVisible: Bool {
        terminalHostView.debugScrollModeIndicatorIsVisible
    }

    var debugScrollModeIndicatorFrames: (background: NSRect, label: NSRect) {
        terminalHostView.debugScrollModeIndicatorFrames
    }

    private static func terminalConfiguration(
        for paneID: PaneID,
        workingDirectory: String?,
        scrollMode: Bool = false
    ) -> TerminalConfiguration {
        TerminalConfiguration(startingFrom: TerminalDefaults.configuration) { builder in

            if scrollMode {
                // Synthetic selection gestures must never reach the running app,
                // activate links or move the shell's input cursor.
                builder.withCustom("mouse-reporting", "false")
                builder.withCustom("cursor-click-to-move", "false")
                builder.withCustom("copy-on-select", "false")
                builder.withCustom("link-url", "false")
            }
            if let workingDirectory {
                builder.withCustom("working-directory", workingDirectory)
            }
            builder.withCustom("env", "SANTTY_PANE_ID=\(paneID.uuidString)")
            builder.withCustom("env", "SANTTY_CONTROL_SOCKET=\(CLITransport.socketPath)")
        }
    }
}

private final class PromptEditorTextView: NSTextView {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode != 53 else {
            onCancel?()
            return
        }

        super.keyDown(with: event)
    }
}

extension TerminalPaneController: TerminalSurfaceOpenURLDelegate {
    static func linkURL(_ text: String) -> URL? {
        guard !text.isEmpty,
              text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        guard let url = URL(string: text, encodingInvalidCharacters: false),
              let scheme = url.scheme?.lowercased() else { return nil }
        if ["http", "https"].contains(scheme), url.host?.isEmpty != false { return nil }
        return url
    }

    func terminalDidRequestOpenURL(_ text: String, kind _: TerminalOpenURLKind) {
        guard let url = Self.linkURL(text) else { NSSound.beep(); return }
        guard herdrSession?.remote == nil || !url.isFileURL else { NSSound.beep(); return }
        // OSC 8 targets are producer-controlled; confirm potentially executable handlers.
        if !["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            let alert = NSAlert()
            alert.messageText = "Open terminal link?"
            alert.informativeText = "This link may open a file or another application:\n\(url.absoluteString)"
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Open")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        if !openURL(url) { NSSound.beep() }
    }
}

extension TerminalPaneController: TerminalSurfaceTitleDelegate {
    func terminalDidChangeTitle(_ title: String) {
        if !title.isEmpty {
            lastKnownTitle = title
        }

        onTitleChange?(id)
    }
}

extension TerminalPaneController: TerminalSurfaceResizeDelegate {
    func terminalDidResize(columns _: Int, rows _: Int) {
        terminalHostView.scrollModeView?.needsLayout = true
    }
}

extension TerminalPaneController: TerminalSurfaceScrollbarDelegate {
    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        terminalHostView.scrollModeView?.updateViewport(TerminalScrollViewport(scrollbar))
    }
}

extension TerminalPaneController: TerminalSurfacePwdDelegate {
    func terminalDidChangeWorkingDirectory(_ path: String) {
        currentWorkingDirectory = path
    }
}

extension TerminalPaneController: TerminalSurfaceCloseDelegate {
    func terminalDidClose(processAlive _: Bool) {
        guard isLive else {
            return
        }

        isLive = false
        exitScrollMode()
        onExit?(id)
    }
}

extension TerminalPaneController: TerminalSurfaceFocusDelegate {
    func terminalDidChangeFocus(_ focused: Bool) {
        herdrSession?.setFocused(focused)
        guard focused, !isFloating else {
            return
        }

        onFocusRequest?(id)
    }
}

enum TerminalScrollModeKeyAction: Equatable {
    case exit
    case cancel
    case move(TerminalScrollMovement)
    case select(linewise: Bool)
    case copy
    case awaitSecondG
    case consume

    init(event: NSEvent, awaitingSecondG: Bool) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 || event.characters == "\u{1b}" {
            self = .cancel
            return
        }

        if modifiers.isEmpty, key == "q" || key == "i" || event.keyCode == 36 {
            self = .exit
            return
        }

        if awaitingSecondG {
            if modifiers.isEmpty, key == "g" {
                self = .move(.top)
                return
            }
        }

        switch (modifiers, key, event.keyCode) {
        case ([], "h", _), ([], _, 123): self = .move(.left)
        case ([], "l", _), ([], _, 124): self = .move(.right)
        case ([], "j", _), ([], _, 125): self = .move(.down)
        case ([], "k", _), ([], _, 126): self = .move(.up)
        case ([], "0", _): self = .move(.lineStart)
        case ([.shift], "^", _), ([.shift], "6", _), ([], "^", _): self = .move(.firstNonblank)
        case ([], "w", _): self = .move(.wordForward(big: false))
        case ([], "b", _): self = .move(.wordBackward(big: false))
        case ([], "e", _): self = .move(.wordEnd(big: false))
        case ([.shift], "w", _): self = .move(.wordForward(big: true))
        case ([.shift], "b", _): self = .move(.wordBackward(big: true))
        case ([.shift], "e", _): self = .move(.wordEnd(big: true))
        case ([.shift], "$", _), ([.shift], "4", _), ([], "$", _): self = .move(.lineEnd)
        case ([], "v", _): self = .select(linewise: false)
        case ([.shift], "v", _): self = .select(linewise: true)
        case ([], "y", _), ([.command], "c", _): self = .copy
        case ([.control], "d", _):
            self = .move(.halfDown)
        case ([.control], "u", _):
            self = .move(.halfUp)
        case ([.control], "f", _), ([], _, 121):
            self = .move(.pageDown)
        case ([.control], "b", _), ([], _, 116):
            self = .move(.pageUp)
        case ([.shift], "g", _), ([], _, 119):
            self = .move(.bottom)
        case ([], "g", _):
            self = .awaitSecondG
        case ([], _, 115):
            self = .move(.top)
        default:
            self = .consume
        }
    }
}

enum ProcessWorkingDirectoryResolver {
    static func workingDirectory(for processID: Int32) -> String? {
        guard processID > 0 else {
            return nil
        }

        var pathInfo = proc_vnodepathinfo()
        let expectedByteCount = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let byteCount = proc_pidinfo(
            processID,
            PROC_PIDVNODEPATHINFO,
            0,
            &pathInfo,
            expectedByteCount
        )
        guard byteCount == expectedByteCount else {
            return nil
        }

        let path: String? = withUnsafeBytes(of: pathInfo.pvi_cdir.vip_path) { pathBytes in
            guard let baseAddress = pathBytes.baseAddress else {
                return nil
            }

            return String(
                validatingCString: baseAddress.assumingMemoryBound(to: CChar.self)
            )
        }
        guard let path, !path.isEmpty else {
            return nil
        }

        return path
    }
}


extension TerminalPaneController: TerminalSurfaceLifecycleDelegate {
    func terminalDidAttachSurface(_ surface: TerminalSurface) { herdrSession?.surfaceAttached() }
    func terminalDidDetachSurface() { herdrSession?.surfaceDetached() }
}

/// Tears a terminal surface down after the pane graph that owned it has
/// finished releasing.
///
/// Setting `controller` to nil re-enters the surface coordinator, which calls
/// `ghostty_surface_free`; that call joins the surface's IO thread and cannot
/// be interrupted. Releasing a pane happens inside layout, responder changes
/// and workspace switches, so the join must not run there: one missed wakeup
/// leaves the main thread blocked indefinitely. Views are held until the next
/// runloop turn, which keeps the surface valid until then.
@MainActor
private enum TerminalViewRetirement {
    private static var pending: [TerminalView] = []
    private static var isDraining = false

    static func retire(_ view: TerminalView) {
        guard view.controller != nil else { return }
        pending.append(view)
        guard !isDraining else { return }
        isDraining = true
        DispatchQueue.main.async {
            isDraining = false
            drain()
        }
    }

    private static func drain() {
        let views = pending
        pending.removeAll()
        for view in views {
            view.delegate = nil
            view.controller = nil
        }
    }
}
