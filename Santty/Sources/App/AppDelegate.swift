import Cocoa
import GhosttyTerminal

@MainActor
enum MainWindowAutosave {
    static let frameName = "Santty.MainWindow"

    @discardableResult
    static func install(on window: NSWindow) -> Bool {
        let didRestoreFrame = window.setFrameUsingName(frameName)
        window.setFrameAutosaveName(frameName)
        return didRestoreFrame
    }
}

@MainActor
final class MainWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaultContentSize = NSSize(width: 720, height: 480)
    private let minimumContentSize = NSSize(width: 480, height: 320)
    private var window: NSWindow?
    private var workspaceViewController: WorkspaceViewController?
    private let commandPaletteWindowController = CommandPaletteWindowController()
    private let settingsWindowController = SettingsWindowController()
    private var menuKeyEquivalentMonitor: Any?
    private var terminalSettingsObserver: NSObjectProtocol?
    private var keybindingSettingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_: Notification) {
        TerminalLoggingConfiguration.apply()

        #if DEBUG
            let restorationTest =
                ProcessInfo.processInfo.environment["SANTTY_WORKSPACE_TEST_MODE"] == "1"
        #else
            let restorationTest = false
        #endif

        if !restorationTest {
            installMenuKeyEquivalentMonitor()
            installKeybindingSettingsObserver()
        }

        let _ = TerminalController.shared.setTheme(TerminalDefaults.theme)
        let _ = TerminalController.shared.setTerminalConfiguration(TerminalDefaults.configuration)
        installTerminalSettingsObserver()
        configureCommandPalette()

        Task { await openWorkspaceWindow(restorationTest: restorationTest) }
    }

    private func openWorkspaceWindow(restorationTest: Bool) async {
        let window = MainWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let workspaceViewController = WorkspaceViewController()

        #if DEBUG
            let testPath = ProcessInfo.processInfo.environment["SANTTY_WORKSPACE_TEST_PATH"]
        #else
            let testPath: String? = nil
        #endif

        await workspaceViewController.prepareWorkspacePersistence(
            url: testPath.map { URL(fileURLWithPath: $0) } ?? WorkspaceStore.defaultURL)
        window.title = "Santty"
        window.isMovableByWindowBackground = true

        installWorkspaceContentView(
            for: window,
            workspaceViewController: workspaceViewController
        )
        AppAppearanceDefaults.applyWindowPresentation(
            to: window,
            isWindowHidden: AppAppearanceSettings.isWindowHidden,
            cornerRadius: AppAppearanceSettings.windowCornerRadius
        )
        window.contentMinSize = minimumContentSize
        window.delegate = workspaceViewController
        if !MainWindowAutosave.install(on: window) {
            window.center()
        }
        if restorationTest { window.orderBack(nil) } else { window.makeKeyAndOrderFront(nil) }
        repairRestoredWindowSizeIfNeeded(window)
        if !restorationTest { NSApp.activate(ignoringOtherApps: true) }
        self.window = window
        self.workspaceViewController = workspaceViewController
        if !restorationTest {
            PaneInputSourceCoordinator.shared.targetProvider = { [weak workspaceViewController] in
                workspaceViewController?.inputSourceTarget
            }
            PaneInputSourceCoordinator.shared.start()
        }

        if !restorationTest {
            CLIControlServer.shared.workspace = workspaceViewController
            CLIControlServer.shared.start()
        }
        installMainMenu()
        if !restorationTest, let warning = workspaceViewController.workspacePersistenceError {
            let alert = NSAlert()
            alert.messageText = "Workspace Restore Notice"
            alert.informativeText = warning
            await alert.beginSheetModal(for: window)
        }
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard workspaceViewController?.hasWorkspacePersistence == true else { return .terminateNow }
        Task { @MainActor in
            let saved = await workspaceViewController?.confirmWorkspaceSaveForClose() != false
            NSApp.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_: Notification) {
        PaneInputSourceCoordinator.shared.stop()
        if let menuKeyEquivalentMonitor {
            NSEvent.removeMonitor(menuKeyEquivalentMonitor)
        }
        if let terminalSettingsObserver {
            NotificationCenter.default.removeObserver(terminalSettingsObserver)
        }
        if let keybindingSettingsObserver {
            NotificationCenter.default.removeObserver(keybindingSettingsObserver)
        }
        CLIControlServer.shared.stop()
    }

    private func repairRestoredWindowSizeIfNeeded(_ window: NSWindow) {
        DispatchQueue.main.async { [defaultContentSize, minimumContentSize] in
            let contentRect = window.contentRect(forFrameRect: window.frame)
            guard
                contentRect.width < minimumContentSize.width
                    || contentRect.height < minimumContentSize.height
            else {
                return
            }

            window.setContentSize(defaultContentSize)
            window.center()
        }
    }

    private func installWorkspaceContentView(
        for window: NSWindow,
        workspaceViewController: WorkspaceViewController
    ) {
        let rootView = NSView()
        rootView.frame = window.contentView?.bounds ?? .zero
        rootView.autoresizingMask = [.width, .height]

        let workspaceView = workspaceViewController.view
        workspaceView.frame = rootView.bounds
        workspaceView.autoresizingMask = [.width, .height]
        rootView.addSubview(workspaceView)
        window.contentView = rootView
    }

    private func installMainMenu() {
        guard let workspaceViewController else {
            return
        }

        AppMenu.install(
            applicationTarget: self,
            workspaceTarget: workspaceViewController,
            commandPaletteAction: #selector(showCommandPalette(_:)),
            checkForUpdatesAction: #selector(checkForUpdates(_:)),
            settingsAction: #selector(showSettings(_:))
        )
    }

    private func installMenuKeyEquivalentMonitor() {
        menuKeyEquivalentMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            ]
        ) { event in
            guard let window = self.window, event.window === window else {
                return event
            }

            self.workspaceViewController?.handlePaneNameEvent(event)
            guard event.type == .keyDown else { return event }

            if let action = KeybindingSettings.action(matching: event),
                self.workspaceViewController?.performKeybindingAction(action) == true
            {
                return nil
            }

            if self.workspaceViewController?.handleScrollModeKeyEvent(event) == true {
                return nil
            }

            guard AppMenuKeyEquivalents.perform(event, in: NSApp.mainMenu) else {
                return event
            }

            return nil
        }
    }

    private func installTerminalSettingsObserver() {
        terminalSettingsObserver = NotificationCenter.default.addObserver(
            forName: TerminalSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let _ = TerminalController.shared.setTheme(TerminalDefaults.theme)
                let _ = TerminalController.shared.setTerminalConfiguration(
                    TerminalDefaults.configuration)
            }
        }
    }

    private func installKeybindingSettingsObserver() {
        keybindingSettingsObserver = NotificationCenter.default.addObserver(
            forName: KeybindingSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.installMainMenu()
            }
        }
    }

    @objc private func showCommandPalette(_: Any?) {
        guard let window else {
            return
        }

        commandPaletteWindowController.show(
            commands: makeCommandPaletteCommands(),
            relativeTo: window
        )
    }

    @objc private func checkForUpdates(_: Any?) {
        AppUpdater.shared.checkForUpdates()
    }

    @objc private func showSettings(_: Any?) {
        settingsWindowController.show(relativeTo: window)
    }

    private func configureCommandPalette() {
        commandPaletteWindowController.commandsProvider = { [weak self] in
            self?.makeCommandPaletteCommands() ?? []
        }
        commandPaletteWindowController.onCommand = { [weak self] command in
            command.perform()
            if command.kind == .command {
                self?.workspaceViewController?.restoreFocusAfterCommandPalette()
            }
        }
        commandPaletteWindowController.onDismiss = { [weak self] in
            self?.workspaceViewController?.restoreFocusAfterCommandPalette()
        }
    }

    private func makeCommandPaletteCommands() -> [AppCommand] {
        var commands =
            (workspaceViewController?.paletteNavigationItems ?? [])
            + (workspaceViewController?.commandPaletteCommands ?? [])
        commands.append(contentsOf: makeWindowCommands())
        return commands
    }

    private func makeWindowCommands() -> [AppCommand] {
        [
            AppCommand(
                id: "window.minimize",
                title: "Minimize Window",
                shortcut: "Cmd M",
                isEnabled: window != nil,
                perform: { [weak self] in self?.window?.performMiniaturize(nil) }
            ),
            AppCommand(
                id: KeybindingAction.toggleMaximizeWindow.commandID,
                title: KeybindingAction.toggleMaximizeWindow.title,
                shortcut: KeybindingSettings.displayShortcut(for: .toggleMaximizeWindow),
                isEnabled: window != nil,
                perform: { [weak self] in self?.toggleMaximizeWindow(nil) }
            ),
            AppCommand(
                id: "window.close",
                title: "Close Window",
                shortcut: "Cmd W",
                isEnabled: window != nil,
                perform: { [weak self] in self?.window?.performClose(nil) }
            ),
        ]
    }

    @objc func toggleMaximizeWindow(_ sender: Any?) {
        // Call zoom directly because the standard zoom button is hidden.
        window?.zoom(sender)
    }

}
