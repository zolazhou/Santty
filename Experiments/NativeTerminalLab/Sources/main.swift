import AppKit

@MainActor
private final class LabAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow?
    private var terminal: NativeTerminalScrollView?
    private let rendererPicker = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private var nextLine = 0
    private var lab: NativeHerdrLab?
    private var localPTY: NativeLocalPTYLab?
    private var changingSession = false
    private var currentOutput: NativeTerminalOutput? { localPTY?.output ?? lab?.output }
    private var shouldFocusTestTerminal = false
    private let sessionButton = NSButton(title: "Start private Herdr shell", target: nil, action: nil)
    private let appendButton = NSButton(title: "Append 100 rows", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset fixture", target: nil, action: nil)
    private let clipboardButton = NSButton(title: "Review Copy…", target: nil, action: nil)
    private let reconnectButton = NSButton(title: "Reconnect viewer", target: nil, action: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let driver = try GhosttyVTDriver()
            let terminal = NativeTerminalScrollView(driver: driver)
            self.terminal = terminal
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Santty Terminal Lab — fixture only"
            window.contentMinSize = NSSize(width: 900, height: 260)
            let root = NSView()
            window.contentView = root
            let notice = NSTextField(labelWithString: "Ghostty VT → SwiftTerm · Fixture by default · Private local PTY via app menu")
            rendererPicker.addItems(withTitles: ["Core Graphics", "Metal"])
            rendererPicker.target = self
            rendererPicker.action = #selector(changeRenderer)
            appendButton.target = self; appendButton.action = #selector(appendRows)
            resetButton.target = self; resetButton.action = #selector(resetFixture)
            sessionButton.target = self; sessionButton.action = #selector(toggleSession)
            reconnectButton.target = self; reconnectButton.action = #selector(reconnectViewer)
            reconnectButton.isEnabled = false
            clipboardButton.target = self; clipboardButton.action = #selector(reviewClipboard)
            clipboardButton.isEnabled = false
            clipboardButton.toolTip = "Review the latest terminal-provided text. Nothing is copied automatically."
            let controls = NSStackView(views: [rendererPicker, appendButton, resetButton, sessionButton, reconnectButton, clipboardButton])
            controls.orientation = .horizontal
            controls.spacing = 12
            for view in [notice, controls, terminal, status] {
                view.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview(view)
            }
            NSLayoutConstraint.activate([
                notice.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
                notice.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                notice.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
                controls.topAnchor.constraint(equalTo: notice.bottomAnchor, constant: 10),
                controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                terminal.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10),
                terminal.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                status.topAnchor.constraint(equalTo: terminal.bottomAnchor, constant: 8),
                status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                status.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
                status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            ])
            status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            terminal.onStatusChange = { [weak self] text in
                guard let self else { return }
                self.status.stringValue = self.localPTY.map { "Local PTY \($0.state) · " }
                    ?? self.lab.map { "\($0.session.state) · " } ?? "Fixture · "
                self.status.stringValue += text
                self.lab?.session.updateDisplay()
            }
            root.layoutSubtreeIfNeeded()
            resetFixture()
            window.center()
            self.window = window
            let menu = NSMenu()
            let app = NSMenuItem()
            let submenu = NSMenu()
            let localPTY = submenu.addItem(withTitle: "Start private local PTY", action: #selector(toggleLocalPTY), keyEquivalent: "")
            localPTY.target = self
            submenu.addItem(NSMenuItem.separator())
            let imageFixture = submenu.addItem(withTitle: "Image fixture", action: #selector(showImageFixture), keyEquivalent: "")
            imageFixture.target = self
            let animationFixture = submenu.addItem(withTitle: "Animation fixture", action: #selector(showAnimationFixture), keyEquivalent: "")
            animationFixture.target = self
            let accessibilityFixture = submenu.addItem(withTitle: "Accessibility fixture", action: #selector(showAccessibilityFixture), keyEquivalent: "")
            accessibilityFixture.target = self
            submenu.addItem(NSMenuItem.separator())
            submenu.addItem(withTitle: "Quit Terminal Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            app.submenu = submenu
            menu.addItem(app)
            NSApp.mainMenu = menu
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            status.stringValue = String(describing: error)
            let alert = NSAlert()
            alert.messageText = "Terminal Lab could not start"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    @objc private func toggleSession() {
        guard let terminal, localPTY == nil, !changingSession else { return }
        changingSession = true
        sessionButton.isEnabled = false
        Task { @MainActor in
            defer { self.changingSession = false; self.sessionButton.isEnabled = self.localPTY == nil }
            do {
                if let lab = self.lab {
                    try await lab.stop()
                    self.lab = nil
                    self.clipboardButton.isEnabled = false
                    terminal.renderer.inputEnabled = false
                    terminal.renderer.output = nil
                    terminal.onViewportChange = nil
                    terminal.onAutomaticReplies = nil
                    self.sessionButton.title = "Start private Herdr shell"
                    self.reconnectButton.isEnabled = false
                    self.appendButton.isEnabled = true
                    self.resetButton.isEnabled = true
                    self.window?.title = "Santty Terminal Lab — fixture only"
                    self.resetFixture()
                } else {
                    let lab = try NativeHerdrLab(driver: terminal.driver) { [weak terminal] reset in
                        terminal?.parsedOutput(reset: reset)
                    }
                    self.lab = lab
                    lab.output.onClipboardOfferChange = { [weak self] in
                        self?.clipboardButton.isEnabled = self?.lab?.output.clipboardOffer != nil
                    }
                    self.shouldFocusTestTerminal = true
                    terminal.renderer.output = lab.output
                    terminal.renderer.onFocusChange = { [weak lab] focused in lab?.setFocused(focused) }
                    terminal.onViewportChange = { [weak lab] viewport in lab?.updateViewport(viewport) }
                    terminal.onAutomaticReplies = { [weak lab] data in lab?.output.sendAutomaticReplies(data) }
                    lab.onStateChange = { [weak self, weak terminal] state in
                        terminal?.renderer.inputEnabled = state == .live
                        self?.status.stringValue = "Private Herdr: \(state)"
                        if state == .live {
                            if self?.shouldFocusTestTerminal == true {
                                self?.shouldFocusTestTerminal = false
                                self?.window?.makeFirstResponder(terminal?.renderer)
                            }
                            terminal?.renderer.refreshFocus()
                        }
                    }
                    self.appendButton.isEnabled = false
                    self.resetButton.isEnabled = false
                    self.reconnectButton.isEnabled = true
                    self.sessionButton.title = "End private test session"
                    self.window?.title = "Santty Terminal Lab — private Herdr shell"
                    try await lab.start(viewport: terminal.viewport)
                }
            } catch {
                self.status.stringValue = "Test session error: \(error)"
            }
        }
    }

    @objc private func toggleLocalPTY() {
        guard let terminal, lab == nil, !changingSession else { return }
        changingSession = true; sessionButton.isEnabled = false
        Task { @MainActor in
            defer { self.changingSession = false; self.sessionButton.isEnabled = self.localPTY == nil }
            do {
                if let local = self.localPTY {
                    try await local.stop()
                    self.localPTY = nil
                    terminal.renderer.inputEnabled = false; terminal.renderer.output = nil
                    terminal.renderer.onFocusChange = nil
                    terminal.onViewportChange = nil; terminal.onAutomaticReplies = nil
                    self.appendButton.isEnabled = true; self.resetButton.isEnabled = true
                    self.clipboardButton.isEnabled = false; self.reconnectButton.isEnabled = false
                    self.window?.title = "Santty Terminal Lab — fixture only"
                    self.resetFixture()
                } else {
                    let local = try NativeLocalPTYLab(driver: terminal.driver) { [weak terminal] reset in terminal?.parsedOutput(reset: reset) }
                    self.localPTY = local
                    self.shouldFocusTestTerminal = true
                    terminal.renderer.output = local.output; terminal.renderer.onFocusChange = nil
                    terminal.onViewportChange = { [weak local] viewport in _ = local?.updateViewport(viewport) }
                    terminal.onAutomaticReplies = { [weak local] data in local?.output.sendAutomaticReplies(data) }
                    local.output.onClipboardOfferChange = { [weak self] in self?.clipboardButton.isEnabled = self?.currentOutput?.clipboardOffer != nil }
                    local.onStateChange = { [weak self, weak terminal, weak local] state in
                        terminal?.renderer.inputEnabled = state.acceptsInput
                        self?.status.stringValue = "Local PTY: \(state)" + (local?.lastWriteError.map { " · \($0)" } ?? "")
                        if state == .running, self?.shouldFocusTestTerminal == true {
                            self?.shouldFocusTestTerminal = false
                            self?.window?.makeFirstResponder(terminal?.renderer)
                            terminal?.renderer.refreshFocus()
                        }
                    }
                    self.appendButton.isEnabled = false; self.resetButton.isEnabled = false
                    self.reconnectButton.isEnabled = false
                    self.window?.title = "Santty Terminal Lab — private local PTY"
                    try local.start(viewport: terminal.viewport)
                }
            } catch { self.status.stringValue = "Local PTY error: \(error)" }
        }
    }

    @objc private func reviewClipboard() {
        guard let output = currentOutput, let window else { return }
        clipboardButton.isEnabled = output.clipboardOffer != nil
        NativeClipboardReview.present(output: output, window: window)
    }

    @objc private func reconnectViewer() {
        guard let lab else { return }
        reconnectButton.isEnabled = false
        Task { @MainActor in
            defer { self.reconnectButton.isEnabled = true }
            do { try await lab.reconnect() }
            catch { self.status.stringValue = "Reconnect error: \(error)" }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard lab != nil || localPTY != nil else { return .terminateNow }
        Task { @MainActor in
            do {
                try await self.localPTY?.stop()
                try await self.lab?.stop()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            catch {
                self.status.stringValue = "Cleanup failed: \(error)"
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    @objc private func changeRenderer() {
        do { try terminal?.setMetal(rendererPicker.indexOfSelectedItem == 1) }
        catch {
            rendererPicker.selectItem(at: terminal?.renderer.isUsingMetalRenderer == true ? 1 : 0)
            status.stringValue = "Renderer unavailable: \(error)"
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleLocalPTY) {
            menuItem.title = localPTY == nil ? "Start private local PTY" : "End local PTY session"
            return lab == nil && !changingSession
        }
        if menuItem.action == #selector(showImageFixture) || menuItem.action == #selector(showAnimationFixture)
            || menuItem.action == #selector(showAccessibilityFixture) { return lab == nil && localPTY == nil && !changingSession }
        return true
    }

    @objc private func showImageFixture() {
        guard lab == nil, sessionButton.isEnabled else { return }
        terminal?.reset(with: "\u{1b}[?25lStatic RGBA + PNG transport — Animation fixture is separate\r\n"
            + "Switch Core Graphics / Metal; Reset fixture restores the text sample.\r\n"
            + "\u{1b}[4;3H\u{1b}_Ga=T,f=32,s=2,v=2,i=7,p=3,c=12,r=6,C=1;/wAA/wD/AP8AAP///////w==\u{1b}\\"
            + "\u{1b}[4;22H\u{1b}_Ga=p,i=7,p=4,x=1,w=1,h=2,c=6,r=6,C=1\u{1b}\\"
            + "\u{1b}[4;34H\u{1b}_Ga=T,f=100,i=9,p=1,c=12,r=6,C=1;iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGP4z8DAAMIM/4EAAB/uBfsL2WiLAAAAAElFTkSuQmCC\u{1b}\\"
            + "\u{1b}[12;1HLeft: RGBA quadrants. Middle: green / white crop. Right: f=100 PNG quadrants.\r\n")
        nextLine = 0
    }

    @objc private func showAnimationFixture() {
        guard lab == nil, sessionButton.isEnabled else { return }
        terminal?.reset(with: "\u{1b}[?25lVT-owned animation: red -> green -> blue, 500 ms per frame\r\n"
            + "Hide/occlude this window to suspend ticks; no GIF/APNG decoder.\r\n"
            + "\u{1b}[4;3H\u{1b}_Ga=T,f=32,s=1,v=1,i=7,p=3,c=20,r=10,C=1;/wAA/w==\u{1b}\\"
            + "\u{1b}_Ga=f,f=32,s=1,v=1,i=7,z=500,X=1;AP8A/w==\u{1b}\\"
            + "\u{1b}_Ga=f,f=32,s=1,v=1,i=7,z=500,X=1;AAD//w==\u{1b}\\"
            + "\u{1b}_Ga=a,i=7,r=1,z=500,s=3,c=1,v=1\u{1b}\\\u{1b}[16;1H")
        nextLine = 0
    }

    @objc private func showAccessibilityFixture() {
        guard lab == nil, sessionButton.isEnabled else { return }
        terminal?.reset(with: "\u{1b}[?2027hAccessibility fixture (read-only AX; native history scrolling)\r\n"
            + "ASCII: alpha beta\r\nWide: 界 😀\r\nCombining: e\u{301}\r\nZWJ: 👩‍👩‍👦\r\n"
            + "Concealed: \u{1b}[8mnot spoken\u{1b}[28m visible\r\n"
            + "\tIndented text\r\nWrap: " + String(repeating: "word ", count: 40)
            + "\r\nEnd. AX setters cannot execute commands or replace terminal text.\r\n")
        nextLine = 0
    }

    @objc private func appendRows() {
        terminal?.feed(Self.fixture(start: nextLine, count: 100))
        nextLine += 100
    }

    @objc private func resetFixture() {
        terminal?.reset(with: Self.fixture(start: 0, count: 2_000))
        nextLine = 2_000
    }

    static func fixture(start: Int, count: Int) -> String {
        "\u{1b}[?2027h" + (start..<(start + count)).map { row in
            let links = row % 20 == 19
                ? "  Cmd-hover / Cmd-click: https://example.com/path  \u{1b}]8;;https://example.com/osc8\u{1b}\\OSC 8 label\u{1b}]8;;\u{1b}\\\r\n" : ""
            return "\u{1b}[0m\(row)  \u{1b}[1;32mGhostty VT\u{1b}[0m  中文 👩🏽‍💻 e\u{301}  ─│┼  \u{1b}[3mitalic\u{1b}[0m  \u{1b}[4:3;58:2::255:160:0munderline\u{1b}[0m  \u{1b}[53moverline\u{1b}[55m\r\n" + links
        }.joined()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private final class LabTestAppDelegate: NSObject, NSApplicationDelegate {}

// Before NSApplication, tests or transport tasks can enter the VT library.
do { try GhosttyVTSystem.prepare() }
catch { fatalError("Ghostty VT system initialization failed: \(error)") }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.appearance = NSAppearance(named: .darkAqua)
    let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    let delegate: NSApplicationDelegate = testing ? LabTestAppDelegate() : LabAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(testing ? .prohibited : .regular)
    app.run()
}
