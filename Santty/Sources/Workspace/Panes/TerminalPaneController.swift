import AppKit
import GhosttyTerminal

@MainActor
final class TerminalPaneController: NSObject {
    let id: PaneID
    let hostView: TerminalPaneHostView

    private let terminalView: TerminalView
    private let terminalController: TerminalController

    private(set) var isLive = true
    private(set) var hasStarted = false
    private(set) var lastKnownTitle = "Shell"
    private(set) var currentWorkingDirectory: String?

    var onFocusRequest: ((PaneID) -> Void)? {
        didSet {
            hostView.onFocusRequest = onFocusRequest
        }
    }

    var onTitleChange: ((PaneID) -> Void)?
    var onExit: ((PaneID) -> Void)?

    var displayTitle: String {
        isLive ? lastKnownTitle : "\(lastKnownTitle) (Exited)"
    }

    var focusTargetView: NSView {
        isLive ? terminalView : hostView
    }

    init(id: PaneID = UUID(), workingDirectory: String? = nil) {
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
        hostView = TerminalPaneHostView(paneID: id, terminalView: terminalView)

        super.init()

        terminalView.delegate = self
        AgentPaneRegistry.shared.register(
            paneID: id,
            title: lastKnownTitle,
            workingDirectory: currentWorkingDirectory
        )
        updatePresentation(isFocused: false)
    }

    deinit {
        MainActor.assumeIsolated {
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
        hostView.updatePresentation(
            isFocused: isFocused,
            isFloating: isFloating,
            isLive: isLive,
            displayTitle: displayTitle
        )
    }

    func copySelection(_ sender: Any?) {
        terminalView.copy(sender)
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
        hostView.updateAppearance()
    }

    func applyTerminalSettings() {
        let _ = terminalController.setTheme(TerminalDefaults.theme)
        let _ = terminalController.setTerminalConfiguration(
            Self.terminalConfiguration(
                for: id,
                workingDirectory: currentWorkingDirectory
            )
        )
    }

    var debugBorderColor: NSColor {
        hostView.debugBorderColor
    }

    var debugBorderWidth: CGFloat {
        hostView.debugBorderWidth
    }

    var debugUsesHiddenWindowPresentation: Bool {
        hostView.debugUsesHiddenWindowPresentation
    }

    var debugVibrancyBlendingMode: NSVisualEffectView.BlendingMode {
        hostView.debugVibrancyBlendingMode
    }

    var debugVibrancyTintAlpha: CGFloat? {
        hostView.debugVibrancyTintAlpha
    }

    var debugTerminalFrame: NSRect {
        hostView.debugTerminalFrame
    }

    var debugTerminalPadding: CGFloat {
        hostView.debugTerminalPadding
    }

    var debugPaneBounds: NSRect {
        hostView.debugPaneBounds
    }

    var debugRenderedTerminalConfig: String {
        terminalController.renderedConfig
    }

    private static func terminalConfiguration(
        for paneID: PaneID,
        workingDirectory: String?
    ) -> TerminalConfiguration {
        TerminalConfiguration(startingFrom: TerminalDefaults.configuration) { builder in
            if let workingDirectory {
                builder.withCustom("working-directory", workingDirectory)
            }
            builder.withCustom("env", "SANTTY_PANE_ID=\(paneID.uuidString)")
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
    func terminalDidResize(columns _: Int, rows _: Int) {}
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
        onExit?(id)
    }
}
