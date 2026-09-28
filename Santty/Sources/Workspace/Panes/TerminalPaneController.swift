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
    private let foregroundProcessIDProvider: @MainActor () -> Int32?
    private let processWorkingDirectoryProvider: (Int32) -> String?

    private(set) var isLive = true
    private(set) var hasStarted = false
    private(set) var lastKnownTitle = "Shell"
    private(set) var currentWorkingDirectory: String?
    private var isFloating = false
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
        isLive ? lastKnownTitle : "\(lastKnownTitle) (Exited)"
    }

    var focusTargetView: NSView {
        terminalHostView.scrollModeView ?? (isLive ? terminalView : terminalHostView)
    }

    var foregroundProcessID: Int? {
        guard isLive, let processID = foregroundProcessIDProvider() else {
            return nil
        }

        return Int(processID)
    }

    var workingDirectoryForNewPane: String? {
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
        foregroundProcessIDProvider: (@MainActor () -> Int32?)? = nil,
        processWorkingDirectoryProvider: @escaping (Int32) -> String? = {
            ProcessWorkingDirectoryResolver.workingDirectory(for: $0)
        }
    ) {
        self.id = id
        currentWorkingDirectory = workingDirectory

        let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        let terminalController = TerminalController(
            configuration: Self.terminalConfiguration(
                for: id,
                workingDirectory: workingDirectory
            ),
            theme: TerminalDefaults.theme
        )
        terminalView.configuration = TerminalSurfaceOptions()
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
        AgentPaneRegistry.shared.register(
            paneID: id,
            title: lastKnownTitle,
            workingDirectory: currentWorkingDirectory
        )
        AgentForegroundProcessRegistry.shared.register(paneID: id) { [weak self] in
            self?.foregroundProcessID
        }
        updatePresentation(isFocused: false)
    }

    deinit {
        MainActor.assumeIsolated {
            AgentForegroundProcessRegistry.shared.unregister(paneID: id)
            AgentPaneRegistry.shared.unregister(paneID: id)
        }
    }

    func startIfNeeded() {
        guard !hasStarted else {
            return
        }

        hasStarted = true
    }

    func fitToSize() {
        terminalView.fitToSize()
    }

    func updatePresentation(isFocused: Bool, isFloating: Bool = false) {
        self.isFloating = isFloating
        terminalHostView.updatePresentation(
            isFocused: isFocused,
            isFloating: isFloating,
            isLive: isLive,
            displayTitle: displayTitle
        )
    }

    func copySelection(_ sender: Any?) {
        terminalHostView.copy(sender)
    }

    func readForCLI(_ request: CLIRequest) throws -> CLIResponse {
        // ponytail: snapshot the retained buffer before trimming; add a ranged
        // Ghostty read API if polling large scrollback buffers becomes costly.
        guard let text = terminalView.readScreenText() else {
            throw CLIError("Terminal content is unavailable; the pane may not have started or may have closed.")
        }
        return try CLITextSnapshot.response(text, request: request)
    }

    func enterScrollMode() {
        guard isLive, !isScrollModeActive else {
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

    private func submitPrompt(_ prompt: String) {
        terminalView.window?.makeFirstResponder(terminalView)
        terminalView.sendText(prompt + "\r")
    }

    func updateAppearance() {
        terminalHostView.updateAppearance()
    }

    func applyTerminalSettings() {
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
            builder.withCustom("env", "SANTTY_RUNTIME_OWNER=\(AgentIntegrationPaths.runtimeOwner)")
            builder.withCustom(
                "env",
                "SANTTY_AGENT_SOCKET=\(AgentIntegrationPaths.eventSocketURL.path)"
            )
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

extension TerminalPaneController: TerminalSurfaceTitleDelegate {
    func terminalDidChangeTitle(_ title: String) {
        if !title.isEmpty {
            lastKnownTitle = title
            AgentPaneRegistry.shared.update(paneID: id, title: title)
        }

        onTitleChange?(id)
    }
}

extension TerminalPaneController: TerminalSurfaceResizeDelegate {
    func terminalDidResize(columns _: Int, rows _: Int) {
        terminalHostView.scrollModeView?.needsLayout = true
    }
}

extension TerminalPaneController: TerminalScrollViewportDelegate {
    func terminalDidScroll(_ viewport: TerminalScrollViewport) {
        terminalHostView.scrollModeView?.updateViewport(viewport)
    }
}

extension TerminalPaneController: TerminalSurfacePwdDelegate {
    func terminalDidChangeWorkingDirectory(_ path: String) {
        currentWorkingDirectory = path
        AgentPaneRegistry.shared.update(paneID: id, workingDirectory: path)
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
