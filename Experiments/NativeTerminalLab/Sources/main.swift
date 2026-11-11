import AppKit

@MainActor
private final class LabAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var terminal: NativeTerminalScrollView?
    private let rendererPicker = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private var nextLine = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let driver = try GhosttyVTDriver()
            let terminal = NativeTerminalScrollView(driver: driver)
            self.terminal = terminal
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Santty Terminal Lab — fixture only"
            window.contentMinSize = NSSize(width: 480, height: 260)
            let root = NSView()
            window.contentView = root
            let notice = NSTextField(labelWithString: "Ghostty VT → SwiftTerm · NSScrollView · No shell / Herdr connection")
            rendererPicker.addItems(withTitles: ["Core Graphics", "Metal"])
            rendererPicker.target = self
            rendererPicker.action = #selector(changeRenderer)
            let append = NSButton(title: "Append 100 rows", target: self, action: #selector(appendRows))
            let reset = NSButton(title: "Reset fixture", target: self, action: #selector(resetFixture))
            let controls = NSStackView(views: [rendererPicker, append, reset])
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
            terminal.onStatusChange = { [weak status] text in status?.stringValue = text }
            root.layoutSubtreeIfNeeded()
            resetFixture()
            window.center()
            self.window = window
            let menu = NSMenu()
            let app = NSMenuItem()
            let submenu = NSMenu()
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

    @objc private func changeRenderer() {
        do { try terminal?.setMetal(rendererPicker.indexOfSelectedItem == 1) }
        catch {
            rendererPicker.selectItem(at: terminal?.renderer.isUsingMetalRenderer == true ? 1 : 0)
            status.stringValue = "Renderer unavailable: \(error)"
        }
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
            "\u{1b}[0m\(row)  \u{1b}[1;32mGhostty VT\u{1b}[0m  中文 👩🏽‍💻 e\u{301}  ─│┼  \u{1b}[3mitalic\u{1b}[0m  \u{1b}[4:3;58:2::255:160:0munderline\u{1b}[0m\r\n"
        }.joined()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private final class LabTestAppDelegate: NSObject, NSApplicationDelegate {}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.appearance = NSAppearance(named: .darkAqua)
    let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    let delegate: NSApplicationDelegate = testing ? LabTestAppDelegate() : LabAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(testing ? .prohibited : .regular)
    app.run()
}
