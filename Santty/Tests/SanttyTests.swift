import AppKit
import Darwin
import GhosttyTerminal
import KeyboardShortcuts
import XCTest
@testable import Santty

final class SanttyTests: XCTestCase {
    override func tearDown() {
        Task { @MainActor in
            AgentNotificationSettings.reset()
            AgentPaneRegistry.shared.reset()
            AgentSessionStore.shared.reset()
        }
        super.tearDown()
    }

    func testSinglePaneTraversalReturnsOnlyPane() {
        let paneID = UUID()
        let layoutNode = LayoutNode.panel(paneID)

        XCTAssertEqual(layoutNode.paneIDsInTraversalOrder, [paneID])
        XCTAssertEqual(layoutNode.nextPaneID(after: paneID), paneID)
        XCTAssertEqual(layoutNode.previousPaneID(before: paneID), paneID)
    }

    func testWindowMinimumSizeFloorMatchesPlanDefaults() {
        XCTAssertEqual(WorkspaceLayoutMetrics.minimumPaneSize, NSSize(width: 240, height: 160))
        XCTAssertEqual(WorkspaceLayoutMetrics.dividerThickness, 6)
        XCTAssertEqual(WorkspaceLayoutMetrics.minimumWindowContentSize, NSSize(width: 480, height: 320))
    }

    func testDefaultTerminalThemeNameIsCatppuccinMocha() {
        XCTAssertEqual(TerminalDefaults.defaultThemeName, "Catppuccin Mocha")
    }

    func testTerminalDebugLoggingIsDisabledWithoutEnvironmentOverride() {
        withRestoredTerminalDebugLogState {
            TerminalDebugLog.enable(.all)

            TerminalLoggingConfiguration.apply(environment: [:])

            XCTAssertFalse(TerminalDebugLog.isEnabled)
        }
    }

    func testTerminalDebugLoggingCanBeEnabledWithStandardEnvironmentOverride() {
        withRestoredTerminalDebugLogState {
            TerminalDebugLog.disable()

            TerminalLoggingConfiguration.apply(environment: ["SANTTY_TERMINAL_DEBUG_LOG": "standard"])

            XCTAssertTrue(TerminalDebugLog.isEnabled)
            XCTAssertEqual(TerminalDebugLog.categories, .standard)
        }
    }

    func testTerminalDebugLoggingCanEnableSelectedCategories() {
        withRestoredTerminalDebugLogState {
            TerminalDebugLog.disable()

            TerminalLoggingConfiguration.apply(
                environment: ["SANTTY_TERMINAL_DEBUG_LOG": "input,render"]
            )

            XCTAssertTrue(TerminalDebugLog.isEnabled)
            XCTAssertEqual(TerminalDebugLog.categories, [.input, .render])
        }
    }

    func testAvailableTerminalThemeNamesIncludeDefaultTheme() {
        XCTAssertTrue(TerminalDefaults.availableThemeNames.contains(TerminalDefaults.defaultThemeName))
    }

    @MainActor
    func testDefaultTerminalThemeRendersCatppuccinMochaColors() {
        TerminalSettings.resetThemeName()
        let renderedTheme = TerminalDefaults.theme.light.rendered

        XCTAssertTrue(renderedTheme.contains("background = 1e1e2e"))
        XCTAssertTrue(renderedTheme.contains("foreground = cdd6f4"))
        TerminalSettings.resetThemeName()
    }

    @MainActor
    func testTerminalThemeUsesThemeNameSetting() {
        TerminalSettings.resetThemeName()

        TerminalSettings.themeName = "3024 Day"
        let renderedTheme = TerminalDefaults.theme.light.rendered

        XCTAssertTrue(renderedTheme.contains("background = f7f7f7"))
        XCTAssertTrue(renderedTheme.contains("foreground = 4a4543"))
        TerminalSettings.resetThemeName()
    }

    @MainActor
    func testTerminalThemeFallsBackToDefaultWhenThemeNameIsUnknown() {
        TerminalSettings.resetThemeName()

        TerminalSettings.themeName = "Missing Theme"
        let renderedTheme = TerminalDefaults.theme.light.rendered

        XCTAssertTrue(renderedTheme.contains("background = 1e1e2e"))
        XCTAssertTrue(renderedTheme.contains("foreground = cdd6f4"))
        TerminalSettings.resetThemeName()
    }

    @MainActor
    func testDefaultTerminalConfigurationMakesBackgroundTransparent() {
        XCTAssertTrue(TerminalDefaults.configuration.rendered.contains("background-opacity = 0"))
    }

    @MainActor
    func testDefaultTerminalConfigurationUsesTerminalFontSettings() {
        TerminalSettings.resetFontFamily()
        TerminalSettings.resetFontSize()

        TerminalSettings.fontFamily = "Monaco"
        TerminalSettings.fontSize = 16
        let renderedConfiguration = TerminalDefaults.configuration.rendered

        XCTAssertTrue(renderedConfiguration.contains("font-family = Monaco"))
        XCTAssertTrue(renderedConfiguration.contains("font-size = 16"))
        TerminalSettings.resetFontFamily()
        TerminalSettings.resetFontSize()
    }

    @MainActor
    func testTerminalPaneConfigurationInjectsAgentEnvironment() {
        let paneID = UUID()
        let paneController = TerminalPaneController(id: paneID)
        let renderedConfiguration = paneController.debugRenderedTerminalConfig

        XCTAssertTrue(renderedConfiguration.contains("env = SANTTY_PANE_ID=\(paneID.uuidString)"))
        XCTAssertTrue(renderedConfiguration.contains("env = SANTTY_RUNTIME_OWNER="))
        XCTAssertTrue(renderedConfiguration.contains("env = SANTTY_AGENT_SOCKET="))
    }

    @MainActor
    func testTerminalPaneConfigurationUsesProvidedWorkingDirectory() {
        let paneController = TerminalPaneController(
            workingDirectory: "/tmp/project"
        )
        let renderedConfiguration = paneController.debugRenderedTerminalConfig

        XCTAssertTrue(renderedConfiguration.contains("working-directory = /tmp/project"))
        XCTAssertTrue(renderedConfiguration.contains("env = SANTTY_PANE_ID="))
        XCTAssertTrue(renderedConfiguration.contains("env = SANTTY_RUNTIME_OWNER="))
        XCTAssertTrue(renderedConfiguration.contains("env = SANTTY_AGENT_SOCKET="))
    }

    func testAppearanceDefaultsUseTransparentTerminalBackground() {
        XCTAssertEqual(AppAppearanceDefaults.terminalBackgroundOpacity, 0)
    }

    @MainActor
    func testTerminalSettingsPersistThemeName() {
        TerminalSettings.resetThemeName()

        TerminalSettings.themeName = "3024 Day"

        XCTAssertEqual(TerminalSettings.themeName, "3024 Day")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "terminal.themeName"), "3024 Day")
        TerminalSettings.resetThemeName()
    }

    @MainActor
    func testTerminalSettingsNormalizeBlankThemeName() {
        TerminalSettings.themeName = "  "

        XCTAssertEqual(TerminalSettings.themeName, TerminalSettings.defaultThemeName)
        TerminalSettings.resetThemeName()
    }

    @MainActor
    func testTerminalSettingsPersistFontFamily() {
        TerminalSettings.resetFontFamily()

        TerminalSettings.fontFamily = "Monaco"

        XCTAssertEqual(TerminalSettings.fontFamily, "Monaco")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "terminal.fontFamily"), "Monaco")
        TerminalSettings.resetFontFamily()
    }

    @MainActor
    func testTerminalSettingsNormalizeBlankFontFamily() {
        TerminalSettings.fontFamily = "  "

        XCTAssertEqual(TerminalSettings.fontFamily, TerminalSettings.defaultFontFamily)
        TerminalSettings.resetFontFamily()
    }

    @MainActor
    func testTerminalSettingsPersistFontSize() {
        TerminalSettings.resetFontSize()

        TerminalSettings.fontSize = 16

        XCTAssertEqual(TerminalSettings.fontSize, 16)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "terminal.fontSize"), 16)
        TerminalSettings.resetFontSize()
    }

    @MainActor
    func testTerminalSettingsClampFontSize() {
        TerminalSettings.fontSize = 100

        XCTAssertEqual(TerminalSettings.fontSize, TerminalSettings.fontSizeRange.upperBound)

        TerminalSettings.fontSize = -10

        XCTAssertEqual(TerminalSettings.fontSize, TerminalSettings.fontSizeRange.lowerBound)
        TerminalSettings.resetFontSize()
    }

    @MainActor
    func testTerminalSettingsPersistPadding() {
        TerminalSettings.resetPadding()

        TerminalSettings.padding = 18

        XCTAssertEqual(TerminalSettings.padding, 18)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "terminal.padding"), 18)
        TerminalSettings.resetPadding()
    }

    @MainActor
    func testTerminalSettingsClampPadding() {
        TerminalSettings.padding = 100

        XCTAssertEqual(TerminalSettings.padding, TerminalSettings.paddingRange.upperBound)

        TerminalSettings.padding = -10

        XCTAssertEqual(TerminalSettings.padding, TerminalSettings.paddingRange.lowerBound)
        TerminalSettings.resetPadding()
    }

    @MainActor
    func testAppearanceSettingsPersistAccentColor() {
        AppAppearanceSettings.resetAccentColor()
        let accentColor = NSColor(
            red: CGFloat(0x33) / 255,
            green: CGFloat(0x66) / 255,
            blue: CGFloat(0xCC) / 255,
            alpha: CGFloat(0xB3) / 255
        )

        AppAppearanceSettings.accentColor = accentColor
        let storedColor = AppAppearanceSettings.accentColor.usingColorSpace(.deviceRGB)

        XCTAssertEqual(UserDefaults.standard.string(forKey: "appearance.accentColor"), "#3366CCB3")
        XCTAssertEqual(storedColor?.redComponent ?? 0, CGFloat(0x33) / 255, accuracy: 0.001)
        XCTAssertEqual(storedColor?.greenComponent ?? 0, CGFloat(0x66) / 255, accuracy: 0.001)
        XCTAssertEqual(storedColor?.blueComponent ?? 0, CGFloat(0xCC) / 255, accuracy: 0.001)
        XCTAssertEqual(storedColor?.alphaComponent ?? 0, CGFloat(0xB3) / 255, accuracy: 0.001)
        AppAppearanceSettings.resetAccentColor()
    }

    @MainActor
    func testAppearanceSettingsResetReturnsDefaultAccentColor() {
        AppAppearanceSettings.accentColor = NSColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)

        AppAppearanceSettings.resetAccentColor()

        XCTAssertEqual(AppAppearanceSettings.accentColor, AppAppearanceSettings.defaultAccentColor)
    }

    @MainActor
    func testAppearanceSettingsPersistActiveTabSolidBackground() {
        AppAppearanceSettings.resetActiveTabBackground()
        let color = NSColor(
            red: CGFloat(0xAA) / 255,
            green: CGFloat(0x44) / 255,
            blue: CGFloat(0xDD) / 255,
            alpha: CGFloat(0xCC) / 255
        )

        AppAppearanceSettings.activeTabBackground = .solid(color)

        XCTAssertEqual(UserDefaults.standard.string(forKey: "appearance.activeTabBackground.kind"), "solid")
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "appearance.activeTabBackground.solidColor"),
            "#AA44DDCC"
        )
        guard case let .solid(storedColor) = AppAppearanceSettings.activeTabBackground else {
            return XCTFail("Expected active tab solid background")
        }
        assertColorEqual(storedColor, color, accuracy: 0.001)
        AppAppearanceSettings.resetActiveTabBackground()
    }

    @MainActor
    func testAppearanceSettingsPersistActiveTabGradientBackground() {
        AppAppearanceSettings.resetActiveTabBackground()
        let startColor = NSColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 0.8)
        let endColor = NSColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 0.9)

        AppAppearanceSettings.activeTabBackground = .gradient(startColor, endColor)

        XCTAssertEqual(UserDefaults.standard.string(forKey: "appearance.activeTabBackground.kind"), "gradient")
        XCTAssertNil(UserDefaults.standard.string(forKey: "appearance.activeTabBackground.solidColor"))
        guard case let .gradient(storedStartColor, storedEndColor) =
            AppAppearanceSettings.activeTabBackground
        else {
            return XCTFail("Expected active tab gradient background")
        }
        assertColorEqual(storedStartColor, startColor, accuracy: 0.003)
        assertColorEqual(storedEndColor, endColor, accuracy: 0.003)
        AppAppearanceSettings.resetActiveTabBackground()
    }

    @MainActor
    func testAppearanceSettingsPersistWindowHidden() {
        AppAppearanceSettings.resetWindowHidden()

        AppAppearanceSettings.isWindowHidden = false

        XCTAssertFalse(AppAppearanceSettings.isWindowHidden)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "appearance.windowHidden"))
        AppAppearanceSettings.resetWindowHidden()
    }

    @MainActor
    func testAppearanceSettingsPersistActivePaneBorderWidth() {
        AppAppearanceSettings.resetActivePaneBorderWidth()

        AppAppearanceSettings.activePaneBorderWidth = 6

        XCTAssertEqual(AppAppearanceSettings.activePaneBorderWidth, 6)
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: "appearance.activePane.borderWidth"),
            6
        )
        AppAppearanceSettings.resetActivePaneBorderWidth()
    }

    @MainActor
    func testAppearanceSettingsClampActivePaneBorderWidth() {
        AppAppearanceSettings.activePaneBorderWidth = 100

        XCTAssertEqual(
            AppAppearanceSettings.activePaneBorderWidth,
            AppAppearanceSettings.activePaneBorderWidthRange.upperBound
        )

        AppAppearanceSettings.activePaneBorderWidth = -10

        XCTAssertEqual(
            AppAppearanceSettings.activePaneBorderWidth,
            AppAppearanceSettings.activePaneBorderWidthRange.lowerBound
        )
        AppAppearanceSettings.resetActivePaneBorderWidth()
    }

    @MainActor
    func testAppearanceSettingsResetReturnsDefaultActivePaneBorderWidth() {
        AppAppearanceSettings.activePaneBorderWidth = 6

        AppAppearanceSettings.resetActivePaneBorderWidth()

        XCTAssertEqual(
            AppAppearanceSettings.activePaneBorderWidth,
            AppAppearanceSettings.defaultActivePaneBorderWidth
        )
    }

    @MainActor
    func testAppearanceSettingsResetReturnsDefaultWindowHidden() {
        AppAppearanceSettings.isWindowHidden = false

        AppAppearanceSettings.resetWindowHidden()

        XCTAssertEqual(AppAppearanceSettings.isWindowHidden, AppAppearanceSettings.defaultIsWindowHidden)
    }

    @MainActor
    func testWindowPresentationFollowsHiddenWindowSetting() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        AppAppearanceDefaults.applyWindowPresentation(to: window, isWindowHidden: true)

        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertTrue(window.titlebarAppearsTransparent)

        AppAppearanceDefaults.applyWindowPresentation(to: window, isWindowHidden: false)

        XCTAssertTrue(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .windowBackgroundColor)
        XCTAssertTrue(window.titlebarAppearsTransparent)
    }

    @MainActor
    func testWindowPresentationKeepsRootVibrancyInSyncWithVisibleWindowState() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let rootView = NSView(frame: window.contentView?.bounds ?? .zero)
        let workspaceView = NSView(frame: rootView.bounds)
        rootView.addSubview(workspaceView)
        window.contentView = rootView

        AppAppearanceDefaults.applyWindowPresentation(to: window, isWindowHidden: false)
        AppAppearanceDefaults.applyWindowPresentation(to: window, isWindowHidden: false)

        XCTAssertEqual(rootView.subviews.compactMap { $0 as? NSVisualEffectView }.count, 1)
        XCTAssertTrue(workspaceView.superview === rootView)

        AppAppearanceDefaults.applyWindowPresentation(to: window, isWindowHidden: true)

        XCTAssertEqual(rootView.subviews.compactMap { $0 as? NSVisualEffectView }.count, 0)
        XCTAssertTrue(workspaceView.superview === rootView)
    }

    func testAppearanceDefaultsUseBehindWindowVibrancy() {
        XCTAssertEqual(AppAppearanceDefaults.vibrancyMaterial, .hudWindow)
        XCTAssertEqual(AppAppearanceDefaults.vibrancyBlendingMode, .behindWindow)
        XCTAssertEqual(AppAppearanceDefaults.vibrancyState, .active)
        XCTAssertEqual(AppAppearanceDefaults.vibrancyAppearanceName, .darkAqua)
    }

    @MainActor
    func testMainWindowAutosaveInstallsFrameName() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )

        MainWindowAutosave.install(on: window)

        XCTAssertEqual(window.frameAutosaveName, MainWindowAutosave.frameName)
    }

    @MainActor
    func testVibrancyViewCanIncludeTransparentDarkTintView() {
        let view = AppAppearanceDefaults.makeVibrancyView(
            tintViewAlpha: AppAppearanceDefaults.vibrancyTintAlpha
        )
        let tintView = try? XCTUnwrap(view.subviews.first)
        let backgroundColor = try? XCTUnwrap(tintView?.layer?.backgroundColor)
        let nsColor = try? XCTUnwrap(
            backgroundColor
                .flatMap(NSColor.init(cgColor:))?
                .usingColorSpace(.deviceRGB)
        )

        XCTAssertTrue(tintView?.wantsLayer ?? false)
        XCTAssertEqual(nsColor?.redComponent ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(nsColor?.greenComponent ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(nsColor?.blueComponent ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(nsColor?.alphaComponent ?? 0, AppAppearanceDefaults.vibrancyTintAlpha, accuracy: 0.001)
    }

    @MainActor
    func testVibrancyViewCanUseCustomTintAlpha() {
        let view = AppAppearanceDefaults.makeVibrancyView(tintViewAlpha: 0.42)
        let tintView = try? XCTUnwrap(view.subviews.first)
        let backgroundColor = try? XCTUnwrap(tintView?.layer?.backgroundColor)
        let nsColor = try? XCTUnwrap(
            backgroundColor
                .flatMap(NSColor.init(cgColor:))?
                .usingColorSpace(.deviceRGB)
        )

        XCTAssertEqual(nsColor?.alphaComponent ?? 0, 0.42, accuracy: 0.001)
    }

    @MainActor
    func testVibrancyViewDoesNotOwnDarkBackgroundLayer() {
        let view = AppAppearanceDefaults.makeVibrancyView()

        XCTAssertEqual(view.appearance?.name, AppAppearanceDefaults.vibrancyAppearanceName)
        XCTAssertNil(view.layer?.backgroundColor)
        XCTAssertTrue(view.subviews.isEmpty)
    }

    @MainActor
    func testVibrancyViewSkipsTintViewWhenAlphaIsNotPositive() {
        let zeroTintView = AppAppearanceDefaults.makeVibrancyView(tintViewAlpha: 0)
        let negativeTintView = AppAppearanceDefaults.makeVibrancyView(tintViewAlpha: -0.1)

        XCTAssertTrue(zeroTintView.subviews.isEmpty)
        XCTAssertTrue(negativeTintView.subviews.isEmpty)
    }

    @MainActor
    func testMenuKeyEquivalentPerformsMatchingMenuItem() throws {
        let target = MenuActionTarget()
        let menu = NSMenu()
        let item = menu.addItem(
            withTitle: "Command Palette",
            action: #selector(MenuActionTarget.handleMenuItem(_:)),
            keyEquivalent: "p"
        )
        item.target = target
        item.keyEquivalentModifierMask = [.command, .shift]

        let event = try XCTUnwrap(Self.makeKeyEvent(
            characters: "P",
            charactersIgnoringModifiers: "p",
            modifierFlags: [.command, .shift]
        ))

        XCTAssertTrue(AppMenuKeyEquivalents.perform(event, in: menu))
    }

    @MainActor
    func testMenuKeyEquivalentMatchesControlLetterByKeyCode() throws {
        let target = MenuActionTarget()
        let menu = NSMenu()
        let item = menu.addItem(
            withTitle: "Move Divider Down",
            action: #selector(MenuActionTarget.handleMenuItem(_:)),
            keyEquivalent: "j"
        )
        item.target = target
        item.keyEquivalentModifierMask = [.control, .command]

        let event = try XCTUnwrap(Self.makeKeyEvent(
            characters: "\n",
            charactersIgnoringModifiers: "\n",
            modifierFlags: [.control, .command],
            keyCode: UInt16(KeyboardShortcuts.Key.j.rawValue)
        ))

        XCTAssertTrue(AppMenuKeyEquivalents.perform(event, in: menu))
        XCTAssertTrue(target.didPerform)
    }

    @MainActor
    func testMenuKeyEquivalentIgnoresNonMatchingKeyEvent() throws {
        let target = MenuActionTarget()
        let menu = NSMenu()
        let item = menu.addItem(
            withTitle: "Command Palette",
            action: #selector(MenuActionTarget.handleMenuItem(_:)),
            keyEquivalent: "p"
        )
        item.target = target
        item.keyEquivalentModifierMask = [.command, .shift]

        let event = try XCTUnwrap(Self.makeKeyEvent(
            characters: "O",
            charactersIgnoringModifiers: "o",
            modifierFlags: [.command, .shift],
            keyCode: 31
        ))

        XCTAssertFalse(AppMenuKeyEquivalents.perform(event, in: menu))
        XCTAssertFalse(target.didPerform)
    }

    @MainActor
    func testCommandPaletteKeyActionsIncludeEscapeReturnAndArrowNavigation() throws {
        XCTAssertEqual(
            CommandPaletteKeyAction(event: try XCTUnwrap(Self.makeKeyEvent(
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                modifierFlags: [],
                keyCode: 53
            ))),
            .cancel
        )
        XCTAssertEqual(
            CommandPaletteKeyAction(event: try XCTUnwrap(Self.makeKeyEvent(
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                modifierFlags: [],
                keyCode: 36
            ))),
            .confirm
        )
        XCTAssertEqual(
            CommandPaletteKeyAction(event: try XCTUnwrap(Self.makeKeyEvent(
                characters: "",
                charactersIgnoringModifiers: "",
                modifierFlags: [],
                keyCode: 125
            ))),
            .moveSelection(1)
        )
        XCTAssertEqual(
            CommandPaletteKeyAction(event: try XCTUnwrap(Self.makeKeyEvent(
                characters: "",
                charactersIgnoringModifiers: "",
                modifierFlags: [],
                keyCode: 126
            ))),
            .moveSelection(-1)
        )
    }

    @MainActor
    func testCommandPaletteKeyActionsIncludeEmacsNavigation() throws {
        XCTAssertEqual(
            CommandPaletteKeyAction(event: try XCTUnwrap(Self.makeKeyEvent(
                characters: "\u{E}",
                charactersIgnoringModifiers: "\u{E}",
                modifierFlags: [.control],
                keyCode: 45
            ))),
            .moveSelection(1)
        )
        XCTAssertEqual(
            CommandPaletteKeyAction(event: try XCTUnwrap(Self.makeKeyEvent(
                characters: "\u{10}",
                charactersIgnoringModifiers: "\u{10}",
                modifierFlags: [.control],
                keyCode: 35
            ))),
            .moveSelection(-1)
        )
    }

    @MainActor
    func testCommandPaletteKeyActionsIgnorePlainLetters() throws {
        XCTAssertNil(CommandPaletteKeyAction(event: try XCTUnwrap(Self.makeKeyEvent(
            characters: "n",
            charactersIgnoringModifiers: "n",
            modifierFlags: [],
            keyCode: 45
        ))))
    }

    @MainActor
    func testCommandPaletteViewHandlesShortcutKeysOutsideSearchFieldKeyDown() throws {
        var performedCommandID: String?
        let view = CommandPaletteView(commands: [
            AppCommand(id: "one", title: "One", shortcut: nil, isEnabled: true) {},
            AppCommand(id: "two", title: "Two", shortcut: nil, isEnabled: true) {},
        ])
        view.onPerformCommand = { command in
            performedCommandID = command.id
        }

        XCTAssertTrue(view.handleKeyDown(try XCTUnwrap(Self.makeKeyEvent(
            characters: "\u{E}",
            charactersIgnoringModifiers: "\u{E}",
            modifierFlags: [.control],
            keyCode: 45
        ))))
        XCTAssertTrue(view.handleKeyDown(try XCTUnwrap(Self.makeKeyEvent(
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            modifierFlags: [],
            keyCode: 36
        ))))
        XCTAssertEqual(performedCommandID, "two")
    }

    @MainActor
    func testAgentNotificationSettingsPersistEnabledAgents() {
        AgentNotificationSettings.reset()

        AgentNotificationSettings.isClaudeCodeEnabled = true
        AgentNotificationSettings.isCodexEnabled = true

        XCTAssertTrue(AgentNotificationSettings.isClaudeCodeEnabled)
        XCTAssertTrue(AgentNotificationSettings.isCodexEnabled)
        AgentNotificationSettings.reset()
    }

    @MainActor
    func testAgentEventMonitorCanStartAndStop() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let monitor = AgentEventMonitor(
            socketURL: tempDirectory.appendingPathComponent("agent-events.sock")
        )

        monitor.start()
        monitor.stop()
    }

    @MainActor
    func testAgentEventMonitorReceivesSocketEvent() async throws {
        AgentNotificationSettings.isCodexEnabled = true
        let socketURL = URL(fileURLWithPath: "/private/tmp/santty-agent-\(UUID().uuidString).sock")
        defer { try? FileManager.default.removeItem(at: socketURL) }
        let paneID = UUID()
        AgentPaneRegistry.shared.register(paneID: paneID, title: "Codex", workingDirectory: nil)

        let monitor = AgentEventMonitor(socketURL: socketURL)
        monitor.start()
        defer { monitor.stop() }
        for _ in 0..<20 where !FileManager.default.fileExists(atPath: socketURL.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let line = try wrappedAgentEventLine(
            agent: .codex,
            payload: [
                "type": "agent-turn-complete",
                "thread-id": "thread-1",
                "cwd": "/tmp/project",
                "last-assistant-message": "Finished",
            ],
            paneID: paneID
        )
        try sendSocketMessage(line + "\n", to: socketURL)

        for _ in 0..<20 {
            if AgentSessionStore.shared.snapshots(forPaneIDs: [paneID]).count == 1 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let snapshot = try XCTUnwrap(AgentSessionStore.shared.snapshots(forPaneIDs: [paneID]).first)
        XCTAssertEqual(snapshot.agent, .codex)
        XCTAssertEqual(snapshot.displayState, .turnCompleted)
        XCTAssertEqual(snapshot.sessionID, "thread-1")
    }

    func testAgentEventParserParsesCodexStopEvent() throws {
        let paneID = UUID()
        let payload: [String: Any] = [
            "type": "agent-turn-complete",
            "thread-id": "thread-1",
            "cwd": "/tmp/project",
            "last-assistant-message": "Finished the task",
        ]
        let line = try wrappedAgentEventLine(agent: .codex, payload: payload, paneID: paneID)

        let event = AgentEventParser().parseLine(line)

        XCTAssertEqual(event?.agent, .codex)
        XCTAssertEqual(event?.eventName, "agent-turn-complete")
        XCTAssertEqual(event?.paneID, paneID)
        XCTAssertEqual(event?.sessionID, "thread-1")
        XCTAssertEqual(event?.workingDirectory, "/tmp/project")
        XCTAssertEqual(event?.message, "Finished the task")
    }

    func testAgentEventParserParsesCodexHookStopEvent() throws {
        let paneID = UUID()
        let payload: [String: Any] = [
            "hook_event_name": "Stop",
            "thread_id": "thread-1",
            "cwd": "/tmp/project",
        ]
        let line = try wrappedAgentEventLine(agent: .codex, payload: payload, paneID: paneID)

        let event = AgentEventParser().parseLine(line)

        XCTAssertEqual(event?.agent, .codex)
        XCTAssertEqual(event?.eventName, "Stop")
        XCTAssertEqual(event?.paneID, paneID)
        XCTAssertEqual(event?.sessionID, "thread-1")
    }

    func testAgentEventParserParsesCodexSessionStartEvent() throws {
        let paneID = UUID()
        let payload: [String: Any] = [
            "hook_event_name": "SessionStart",
            "thread_id": "thread-1",
            "cwd": "/tmp/project",
        ]
        let line = try wrappedAgentEventLine(agent: .codex, payload: payload, paneID: paneID)

        let event = AgentEventParser().parseSessionEventLine(line)

        XCTAssertEqual(event?.kind, .sessionStarted)
        XCTAssertEqual(event?.agent, .codex)
        XCTAssertEqual(event?.paneID, paneID)
        XCTAssertEqual(event?.sessionID, "thread-1")
    }

    func testAgentEventParserParsesCodexTurnStartEvent() throws {
        let paneID = UUID()
        let payload: [String: Any] = [
            "type": "agent-turn-start",
            "thread-id": "thread-1",
            "cwd": "/tmp/project",
        ]
        let line = try wrappedAgentEventLine(agent: .codex, payload: payload, paneID: paneID)

        let event = AgentEventParser().parseSessionEventLine(line)

        XCTAssertEqual(event?.kind, .turnStarted)
        XCTAssertEqual(event?.agent, .codex)
        XCTAssertEqual(event?.paneID, paneID)
        XCTAssertEqual(event?.sessionID, "thread-1")
    }

    func testAgentEventParserParsesCodexPermissionRequestEvent() throws {
        let paneID = UUID()
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "thread_id": "thread-1",
            "cwd": "/tmp/project",
            "message": "Need permission to run rm",
        ]
        let line = try wrappedAgentEventLine(agent: .codex, payload: payload, paneID: paneID)

        let event = AgentEventParser().parseSessionEventLine(line)

        XCTAssertEqual(event?.kind, .permissionRequested)
        XCTAssertEqual(event?.agent, .codex)
        XCTAssertEqual(event?.paneID, paneID)
        XCTAssertEqual(event?.sessionID, "thread-1")
        XCTAssertEqual(event?.message, "Need permission to run rm")
    }

    func testAgentEventParserIgnoresCodexSessionEndEvent() throws {
        let payload: [String: Any] = [
            "hook_event_name": "SessionEnd",
            "thread_id": "thread-1",
        ]
        let line = try wrappedAgentEventLine(agent: .codex, payload: payload)

        XCTAssertNil(AgentEventParser().parseSessionEventLine(line))
    }

    func testAgentEventParserParsesClaudeStopEvent() throws {
        let paneID = UUID()
        let payload: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": "session-1",
            "cwd": "/tmp/project",
        ]
        let line = try wrappedAgentEventLine(agent: .claude, payload: payload, paneID: paneID)

        let event = AgentEventParser().parseLine(line)

        XCTAssertEqual(event?.agent, .claude)
        XCTAssertEqual(event?.eventName, "Stop")
        XCTAssertEqual(event?.paneID, paneID)
        XCTAssertEqual(event?.sessionID, "session-1")
        XCTAssertEqual(event?.workingDirectory, "/tmp/project")
    }

    func testAgentEventParserParsesClaudeSessionStartEvent() throws {
        let paneID = UUID()
        let payload: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "session-1",
            "cwd": "/tmp/project",
        ]
        let line = try wrappedAgentEventLine(agent: .claude, payload: payload, paneID: paneID)

        let event = AgentEventParser().parseSessionEventLine(line)

        XCTAssertEqual(event?.kind, .sessionStarted)
        XCTAssertEqual(event?.agent, .claude)
        XCTAssertEqual(event?.paneID, paneID)
        XCTAssertEqual(event?.sessionID, "session-1")
    }

    func testAgentEventParserParsesClaudePermissionDeniedEvent() throws {
        let paneID = UUID()
        let payload: [String: Any] = [
            "hook_event_name": "PermissionDenied",
            "session_id": "session-1",
            "cwd": "/tmp/project",
            "permissionDecisionReason": "Denied by policy",
        ]
        let line = try wrappedAgentEventLine(agent: .claude, payload: payload, paneID: paneID)

        let event = AgentEventParser().parseSessionEventLine(line)

        XCTAssertEqual(event?.kind, .permissionDenied)
        XCTAssertEqual(event?.agent, .claude)
        XCTAssertEqual(event?.paneID, paneID)
        XCTAssertEqual(event?.sessionID, "session-1")
        XCTAssertEqual(event?.message, "Denied by policy")
    }

    func testAgentEventParserParsesClaudeNotificationEvent() throws {
        let paneID = UUID()
        let payload: [String: Any] = [
            "hook_event_name": "Notification",
            "session_id": "session-1",
            "cwd": "/tmp/project",
            "message": "Claude sent a notification",
        ]
        let line = try wrappedAgentEventLine(agent: .claude, payload: payload, paneID: paneID)

        let event = AgentEventParser().parseSessionEventLine(line)

        XCTAssertEqual(event?.kind, .notification)
        XCTAssertEqual(event?.agent, .claude)
        XCTAssertEqual(event?.paneID, paneID)
        XCTAssertEqual(event?.message, "Claude sent a notification")
    }

    func testAgentEventParserParsesClaudeSessionEndEvent() throws {
        let paneID = UUID()
        let payload: [String: Any] = [
            "hook_event_name": "SessionEnd",
            "session_id": "session-1",
            "cwd": "/tmp/project",
        ]
        let line = try wrappedAgentEventLine(agent: .claude, payload: payload, paneID: paneID)

        let event = AgentEventParser().parseSessionEventLine(line)

        XCTAssertEqual(event?.kind, .sessionEnded)
        XCTAssertEqual(event?.agent, .claude)
        XCTAssertEqual(event?.paneID, paneID)
        XCTAssertEqual(event?.sessionID, "session-1")
    }

    func testAgentEventParserIgnoresNonStopClaudeEvents() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "session_id": "session-1",
        ]
        let line = try wrappedAgentEventLine(agent: .claude, payload: payload)

        XCTAssertNil(AgentEventParser().parseLine(line))
    }

    @MainActor
    func testAgentSessionStoreTracksStatusTransitionsAndUnreadCount() {
        AgentSessionStore.shared.reset()
        let paneID = UUID()
        AgentPaneRegistry.shared.register(paneID: paneID, title: "Codex Pane", workingDirectory: "/tmp/project")

        AgentSessionStore.shared.handle(
            AgentSessionEvent(
                kind: .turnStarted,
                agent: .codex,
                eventName: "agent-turn-start",
                paneID: paneID,
                sessionID: "thread-1",
                workingDirectory: "/tmp/project",
                message: nil,
                timestamp: Date(timeIntervalSince1970: 1)
            )
        )

        var snapshots = AgentSessionStore.shared.snapshots(forPaneIDs: [paneID])
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.displayState, .running)
        XCTAssertEqual(AgentSessionStore.shared.unreadSessionCount(forPaneIDs: [paneID]), 0)

        AgentSessionStore.shared.handle(
            AgentSessionEvent(
                kind: .turnCompleted,
                agent: .codex,
                eventName: "agent-turn-complete",
                paneID: paneID,
                sessionID: "thread-1",
                workingDirectory: nil,
                message: "Done",
                timestamp: Date(timeIntervalSince1970: 2)
            )
        )

        snapshots = AgentSessionStore.shared.snapshots(forPaneIDs: [paneID])
        XCTAssertEqual(snapshots.first?.displayState, .turnCompleted)
        XCTAssertEqual(snapshots.first?.isUnread, true)
        XCTAssertEqual(snapshots.first?.message, "Done")
        XCTAssertEqual(AgentSessionStore.shared.unreadSessionCount(forPaneIDs: [paneID]), 1)
    }

    @MainActor
    func testAgentSessionStoreSessionStartCreatesRunningSession() {
        AgentSessionStore.shared.reset()
        let paneID = UUID()
        AgentPaneRegistry.shared.register(paneID: paneID, title: "Claude Pane", workingDirectory: nil)

        AgentSessionStore.shared.handle(
            AgentSessionEvent(
                kind: .sessionStarted,
                agent: .claude,
                eventName: "SessionStart",
                paneID: paneID,
                sessionID: "session-1",
                workingDirectory: nil,
                message: nil,
                timestamp: Date(timeIntervalSince1970: 1)
            )
        )

        let snapshot = AgentSessionStore.shared.snapshots(forPaneIDs: [paneID]).first
        XCTAssertEqual(snapshot?.displayState, .running)
        XCTAssertEqual(snapshot?.isUnread, false)
    }

    @MainActor
    func testAgentSessionStoreStartAfterUnreadKeepsUnread() {
        AgentSessionStore.shared.reset()
        let paneID = UUID()
        AgentPaneRegistry.shared.register(paneID: paneID, title: "Codex Pane", workingDirectory: nil)

        AgentSessionStore.shared.handle(agentSessionEvent(.turnCompleted, paneID: paneID))
        AgentSessionStore.shared.handle(agentSessionEvent(.turnStarted, paneID: paneID))

        let snapshot = AgentSessionStore.shared.snapshots(forPaneIDs: [paneID]).first
        XCTAssertEqual(snapshot?.displayState, .running)
        XCTAssertEqual(snapshot?.isUnread, true)
        XCTAssertEqual(AgentSessionStore.shared.unreadSessionCount(forPaneIDs: [paneID]), 1)
    }

    @MainActor
    func testAgentSessionStoreSessionEndPreservesUnreadAndClearEnded() {
        AgentSessionStore.shared.reset()
        let paneID = UUID()
        AgentPaneRegistry.shared.register(paneID: paneID, title: "Claude Pane", workingDirectory: nil)

        AgentSessionStore.shared.handle(agentSessionEvent(.turnCompleted, agent: .claude, paneID: paneID))
        AgentSessionStore.shared.handle(agentSessionEvent(.sessionEnded, agent: .claude, paneID: paneID))

        var snapshot = AgentSessionStore.shared.snapshots(forPaneIDs: [paneID]).first
        XCTAssertEqual(snapshot?.displayState, .sessionEnded)
        XCTAssertEqual(snapshot?.isUnread, true)

        AgentSessionStore.shared.markRead(forPaneIDs: [paneID])
        AgentSessionStore.shared.clearEnded(forPaneIDs: [paneID])

        snapshot = AgentSessionStore.shared.snapshots(forPaneIDs: [paneID]).first
        XCTAssertNil(snapshot)
    }

    @MainActor
    func testAgentSessionStoreClearEndedKeepsTurnCompletedSessions() {
        AgentSessionStore.shared.reset()
        let paneID = UUID()
        AgentPaneRegistry.shared.register(paneID: paneID, title: "Claude Pane", workingDirectory: nil)

        AgentSessionStore.shared.handle(agentSessionEvent(.turnCompleted, agent: .claude, paneID: paneID))
        AgentSessionStore.shared.markRead(forPaneIDs: [paneID])
        AgentSessionStore.shared.clearEnded(forPaneIDs: [paneID])

        let snapshot = AgentSessionStore.shared.snapshots(forPaneIDs: [paneID]).first
        XCTAssertEqual(snapshot?.displayState, .turnCompleted)
        XCTAssertEqual(snapshot?.isUnread, false)
    }

    @MainActor
    func testAgentSessionStoreFiltersAndSortsWindowSessions() {
        AgentSessionStore.shared.reset()
        let waitingPaneID = UUID()
        let runningPaneID = UUID()
        let otherPaneID = UUID()
        for paneID in [waitingPaneID, runningPaneID, otherPaneID] {
            AgentPaneRegistry.shared.register(paneID: paneID, title: "Pane", workingDirectory: nil)
        }

        AgentSessionStore.shared.handle(
            agentSessionEvent(.turnStarted, paneID: runningPaneID, timestamp: Date(timeIntervalSince1970: 3))
        )
        AgentSessionStore.shared.handle(
            agentSessionEvent(.waitingForUser, paneID: waitingPaneID, timestamp: Date(timeIntervalSince1970: 2))
        )
        AgentSessionStore.shared.handle(
            agentSessionEvent(.turnCompleted, paneID: otherPaneID, timestamp: Date(timeIntervalSince1970: 4))
        )

        let snapshots = AgentSessionStore.shared.snapshots(forPaneIDs: [runningPaneID, waitingPaneID])
        XCTAssertEqual(snapshots.map(\.paneID), [waitingPaneID, runningPaneID])
    }

    @MainActor
    func testAgentSessionStoreRemovesSessionsForClosedPane() {
        AgentSessionStore.shared.reset()
        let paneID = UUID()
        AgentPaneRegistry.shared.register(paneID: paneID, title: "Codex Pane", workingDirectory: nil)

        AgentSessionStore.shared.handle(agentSessionEvent(.turnCompleted, paneID: paneID))
        AgentSessionStore.shared.removeSessions(forPaneID: paneID)

        XCTAssertTrue(AgentSessionStore.shared.snapshots(forPaneIDs: [paneID]).isEmpty)
    }

    func testCodexInstallerInstallsNewHookSetAndEnablesHooks() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let homeDirectory = tempDirectory.appendingPathComponent("home")
        let installer = AgentIntegrationInstaller(
            homeDirectory: homeDirectory,
            applicationSupportDirectory: tempDirectory.appendingPathComponent("support"),
            runtimeOwner: "com.zolazhou.santty.tests"
        )
        let codexDirectory = homeDirectory.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try """
            model = "gpt-5"
            notify = ["/usr/local/bin/existing-notify", "turn-ended"]

            [profiles.default]
            model = "gpt-5"
            """.write(
                to: codexDirectory.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )

        try installer.installCodexIntegration()

        let hooksData = try Data(contentsOf: codexDirectory.appendingPathComponent("hooks.json"))
        let hooksRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: hooksData) as? [String: Any])
        let hooks = try XCTUnwrap(hooksRoot["hooks"] as? [String: Any])
        let sessionStartEntries = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(sessionStartEntries.count, 1)
        let sessionStartCommandHooks = try XCTUnwrap(sessionStartEntries.first?["hooks"] as? [[String: Any]])
        let sessionStartCommand = try XCTUnwrap(sessionStartCommandHooks.first?["command"] as? String)
        XCTAssertTrue(sessionStartCommand.contains("'session-start'"))

        let promptEntries = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        XCTAssertEqual(promptEntries.count, 1)
        let promptCommandHooks = try XCTUnwrap(promptEntries.first?["hooks"] as? [[String: Any]])
        let promptCommand = try XCTUnwrap(promptCommandHooks.first?["command"] as? String)
        XCTAssertTrue(promptCommand.contains("'turn-start'"))

        let stopEntries = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stopEntries.count, 1)
        let stopCommandHooks = try XCTUnwrap(stopEntries.first?["hooks"] as? [[String: Any]])
        let stopCommand = try XCTUnwrap(stopCommandHooks.first?["command"] as? String)
        XCTAssertTrue(stopCommand.contains("'stop'"))
        XCTAssertTrue(stopCommand.contains("'com.zolazhou.santty.tests'"))

        let permissionEntries = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual(permissionEntries.count, 1)
        let permissionCommandHooks = try XCTUnwrap(permissionEntries.first?["hooks"] as? [[String: Any]])
        let permissionCommand = try XCTUnwrap(permissionCommandHooks.first?["command"] as? String)
        XCTAssertTrue(permissionCommand.contains("'permission-request'"))

        let updatedConfig = try String(
            contentsOf: codexDirectory.appendingPathComponent("config.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(updatedConfig.contains("notify = [\"/usr/local/bin/existing-notify\", \"turn-ended\"]"))
        XCTAssertTrue(updatedConfig.contains("[features]"))
        XCTAssertTrue(updatedConfig.contains("hooks = true"))
        XCTAssertTrue(updatedConfig.contains("[hooks.state."))
        XCTAssertTrue(updatedConfig.contains("trusted_hash = \"sha256:"))
    }

    func testCodexInstallerSkipsUnchangedConfigFilesOnReinstall() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let homeDirectory = tempDirectory.appendingPathComponent("home")
        let installer = AgentIntegrationInstaller(
            homeDirectory: homeDirectory,
            applicationSupportDirectory: tempDirectory.appendingPathComponent("support"),
            runtimeOwner: "com.zolazhou.santty.tests"
        )
        let codexDirectory = homeDirectory.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        try """
            model = "gpt-5"
            notify = ["/usr/local/bin/existing-notify", "turn-ended"]
            """.write(to: configURL, atomically: true, encoding: .utf8)

        try installer.installCodexIntegration()
        let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
        let firstHooksData = try Data(contentsOf: hooksURL)
        let firstConfigData = try Data(contentsOf: configURL)
        let firstBackupCount = try backupFiles(in: codexDirectory).count

        try installer.installCodexIntegration()

        let secondHooksData = try Data(contentsOf: hooksURL)
        let secondConfigData = try Data(contentsOf: configURL)
        let secondBackupCount = try backupFiles(in: codexDirectory).count
        XCTAssertEqual(secondHooksData, firstHooksData)
        XCTAssertEqual(secondConfigData, firstConfigData)
        XCTAssertEqual(secondBackupCount, firstBackupCount)
    }

    func testCodexUninstallerRemovesManagedHookTrustAndScripts() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let homeDirectory = tempDirectory.appendingPathComponent("home")
        let installer = AgentIntegrationInstaller(
            homeDirectory: homeDirectory,
            applicationSupportDirectory: tempDirectory.appendingPathComponent("support"),
            runtimeOwner: "com.zolazhou.santty.tests"
        )
        let codexDirectory = homeDirectory.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try """
            model = "gpt-5"
            notify = ["/usr/local/bin/existing-notify", "turn-ended"]
            """.write(
                to: codexDirectory.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )

        try installer.installCodexIntegration()
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.hookScriptURL.path))

        try installer.uninstallCodexIntegration(removeScripts: true)

        let hooksData = try Data(contentsOf: codexDirectory.appendingPathComponent("hooks.json"))
        let hooksRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: hooksData) as? [String: Any])
        XCTAssertNil(hooksRoot["hooks"])

        let updatedConfig = try String(
            contentsOf: codexDirectory.appendingPathComponent("config.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(updatedConfig.contains("notify = [\"/usr/local/bin/existing-notify\", \"turn-ended\"]"))
        XCTAssertFalse(updatedConfig.contains("[hooks.state."))
        XCTAssertFalse(updatedConfig.contains("trusted_hash = \"sha256:"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.hookScriptURL.path))
    }

    func testCodexUninstallerSkipsUnchangedConfigFiles() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let homeDirectory = tempDirectory.appendingPathComponent("home")
        let installer = AgentIntegrationInstaller(
            homeDirectory: homeDirectory,
            applicationSupportDirectory: tempDirectory.appendingPathComponent("support"),
            runtimeOwner: "com.zolazhou.santty.tests"
        )
        let codexDirectory = homeDirectory.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        try writeCanonicalJSON(
            [
                "hooks": [
                    "SessionStart": [
                        [
                            "matcher": "",
                            "hooks": [
                                [
                                    "type": "command",
                                    "command": "echo existing start",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            to: hooksURL
        )
        try """
            model = "gpt-5"
            notify = ["/usr/local/bin/existing-notify", "turn-ended"]
            """.write(to: configURL, atomically: true, encoding: .utf8)

        let firstHooksData = try Data(contentsOf: hooksURL)
        let firstConfigData = try Data(contentsOf: configURL)

        try installer.uninstallCodexIntegration(removeScripts: false)

        XCTAssertEqual(try Data(contentsOf: hooksURL), firstHooksData)
        XCTAssertEqual(try Data(contentsOf: configURL), firstConfigData)
        XCTAssertEqual(try backupFiles(in: codexDirectory).count, 0)
    }

    func testClaudeInstallerMergesNewHookSet() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let homeDirectory = tempDirectory.appendingPathComponent("home")
        let claudeDirectory = homeDirectory.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(
            at: claudeDirectory,
            withIntermediateDirectories: true
        )
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let installer = AgentIntegrationInstaller(
            homeDirectory: homeDirectory,
            applicationSupportDirectory: tempDirectory.appendingPathComponent("support"),
            runtimeOwner: "com.zolazhou.santty.tests"
        )
        try """
            {
              "theme": "dark",
              "hooks": {
                "SessionStart": [
                  {
                    "matcher": "",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "echo existing start"
                      }
                    ]
                  }
                ],
                "Stop": [
                  {
                    "matcher": "",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "echo existing"
                      }
                    ]
                  }
                ],
                "PermissionRequest": [
                  {
                    "matcher": "",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "echo existing permission"
                      }
                    ]
                  }
                ],
                "Notification": [
                  {
                    "matcher": "",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "echo existing notification"
                      }
                    ]
                  }
                ],
                "PermissionDenied": [
                  {
                    "matcher": "",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "echo existing denied"
                      }
                    ]
                  }
                ],
                "SessionEnd": [
                  {
                    "matcher": "",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "'\(installer.legacyClaudeHookScriptURL.path)'"
                      }
                    ]
                  }
                ]
              }
            }
            """.write(to: settingsURL, atomically: true, encoding: .utf8)

        try installer.installClaudeCodeIntegration()

        let data = try Data(contentsOf: settingsURL)
        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(settings["theme"] as? String, "dark")
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let sessionStartEntries = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(sessionStartEntries.count, 2)
        let sessionStartCommandHooks = try XCTUnwrap(sessionStartEntries.last?["hooks"] as? [[String: Any]])
        let sessionStartCommand = try XCTUnwrap(sessionStartCommandHooks.first?["command"] as? String)
        XCTAssertTrue(sessionStartCommand.contains("'session-start'"))

        let promptEntries = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        XCTAssertEqual(promptEntries.count, 1)
        let promptCommandHooks = try XCTUnwrap(promptEntries.first?["hooks"] as? [[String: Any]])
        let promptCommand = try XCTUnwrap(promptCommandHooks.first?["command"] as? String)
        XCTAssertTrue(promptCommand.contains("'turn-start'"))

        let stopEntries = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stopEntries.count, 2)
        let stopCommandHooks = try XCTUnwrap(stopEntries.last?["hooks"] as? [[String: Any]])
        let stopCommand = try XCTUnwrap(stopCommandHooks.first?["command"] as? String)
        XCTAssertTrue(stopCommand.contains("'stop'"))
        XCTAssertNotNil(hooks["PermissionRequest"])
        XCTAssertNotNil(hooks["Notification"])
        XCTAssertNotNil(hooks["PermissionDenied"])
        XCTAssertNotNil(hooks["SessionEnd"])
    }

    func testClaudeInstallerSkipsUnchangedConfigFilesOnReinstall() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let homeDirectory = tempDirectory.appendingPathComponent("home")
        let claudeDirectory = homeDirectory.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(
            at: claudeDirectory,
            withIntermediateDirectories: true
        )
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let installer = AgentIntegrationInstaller(
            homeDirectory: homeDirectory,
            applicationSupportDirectory: tempDirectory.appendingPathComponent("support"),
            runtimeOwner: "com.zolazhou.santty.tests"
        )
        try """
            {
              "theme": "dark",
              "hooks": {
                "SessionStart": [
                  {
                    "matcher": "",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "echo existing start"
                      }
                    ]
                  }
                ],
                "Stop": [
                  {
                    "matcher": "",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "echo existing"
                      }
                    ]
                  }
                ],
                "PermissionRequest": [
                  {
                    "matcher": "",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "echo existing permission"
                      }
                    ]
                  }
                ],
                "Notification": [
                  {
                    "matcher": "",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "echo existing notification"
                      }
                    ]
                  }
                ],
                "PermissionDenied": [
                  {
                    "matcher": "",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "echo existing denied"
                      }
                    ]
                  }
                ],
                "SessionEnd": [
                  {
                    "matcher": "",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "echo existing end"
                      }
                    ]
                  }
                ]
              }
            }
            """.write(to: settingsURL, atomically: true, encoding: .utf8)

        try installer.installClaudeCodeIntegration()
        let firstSettingsData = try Data(contentsOf: settingsURL)
        let firstBackupCount = try backupFiles(in: claudeDirectory).count

        try installer.installClaudeCodeIntegration()

        XCTAssertEqual(try Data(contentsOf: settingsURL), firstSettingsData)
        XCTAssertEqual(try backupFiles(in: claudeDirectory).count, firstBackupCount)
    }

    func testClaudeUninstallerRemovesManagedHooksAndScripts() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let homeDirectory = tempDirectory.appendingPathComponent("home")
        let installer = AgentIntegrationInstaller(
            homeDirectory: homeDirectory,
            applicationSupportDirectory: tempDirectory.appendingPathComponent("support"),
            runtimeOwner: "com.zolazhou.santty.tests"
        )
        let claudeDirectory = homeDirectory.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        try """
            {
              "theme": "dark",
              "hooks": {
                "SessionStart": [
                  {
                    "matcher": "",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "echo existing start"
                      }
                    ]
                  }
                ],
                "Stop": [
                  {
                    "matcher": "",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "echo existing"
                      }
                    ]
                  }
                ]
              }
            }
            """.write(to: settingsURL, atomically: true, encoding: .utf8)

        try installer.installClaudeCodeIntegration()
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.hookScriptURL.path))

        try installer.uninstallClaudeCodeIntegration(removeScripts: true)

        let data = try Data(contentsOf: settingsURL)
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(settings["theme"] as? String, "dark")
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let sessionStartEntries = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(sessionStartEntries.count, 1)
        let sessionStartCommandHooks = try XCTUnwrap(sessionStartEntries.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(sessionStartCommandHooks.first?["command"] as? String, "echo existing start")

        let stopEntries = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stopEntries.count, 1)
        let commandHooks = try XCTUnwrap(stopEntries.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(commandHooks.first?["command"] as? String, "echo existing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.hookScriptURL.path))
    }

    func testClaudeUninstallerSkipsUnchangedConfigFiles() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let homeDirectory = tempDirectory.appendingPathComponent("home")
        let claudeDirectory = homeDirectory.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(
            at: claudeDirectory,
            withIntermediateDirectories: true
        )
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        try writeCanonicalJSON(
            [
                "theme": "dark",
                "hooks": [
                    "SessionStart": [
                        [
                            "matcher": "",
                            "hooks": [
                                [
                                    "type": "command",
                                    "command": "echo existing start",
                                ],
                            ],
                        ],
                    ],
                    "Stop": [
                        [
                            "matcher": "",
                            "hooks": [
                                [
                                    "type": "command",
                                    "command": "echo existing",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            to: settingsURL
        )
        let installer = AgentIntegrationInstaller(
            homeDirectory: homeDirectory,
            applicationSupportDirectory: tempDirectory.appendingPathComponent("support"),
            runtimeOwner: "com.zolazhou.santty.tests"
        )

        let firstSettingsData = try Data(contentsOf: settingsURL)

        try installer.uninstallClaudeCodeIntegration(removeScripts: false)

        XCTAssertEqual(try Data(contentsOf: settingsURL), firstSettingsData)
        XCTAssertEqual(try backupFiles(in: claudeDirectory).count, 0)
    }

    @MainActor
    private final class MenuActionTarget: NSObject {
        var didPerform = false

        @objc func handleMenuItem(_: Any?) {
            didPerform = true
        }
    }

    private static func makeKeyEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        modifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16 = 35
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func wrappedAgentEventLine(
        agent: AgentKind,
        payload: [String: Any],
        paneID: PaneID? = nil
    ) throws -> String {
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        var wrapper: [String: Any] = [
            "agent": agent.rawValue,
            "payloadBase64": payloadData.base64EncodedString(),
            "timestamp": 1_771_785_600,
        ]
        wrapper["paneID"] = paneID?.uuidString
        let wrapperData = try JSONSerialization.data(withJSONObject: wrapper)
        return String(decoding: wrapperData, as: UTF8.self)
    }

    private func agentSessionEvent(
        _ kind: AgentSessionEventKind,
        agent: AgentKind = .codex,
        paneID: PaneID,
        sessionID: String = "session-1",
        timestamp: Date = Date(timeIntervalSince1970: 1)
    ) -> AgentSessionEvent {
        AgentSessionEvent(
            kind: kind,
            agent: agent,
            eventName: String(describing: kind),
            paneID: paneID,
            sessionID: sessionID,
            workingDirectory: nil,
            message: nil,
            timestamp: timestamp
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SanttyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func backupFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".santty-backup-") }
    }

    private func writeCanonicalJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
    }

    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    private func sendSocketMessage(_ message: String, to socketURL: URL) throws {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fileDescriptor, 0)
        defer { close(fileDescriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        path.withCString { pathPointer in
            withUnsafeMutablePointer(to: &address.sun_path) { sunPathPointer in
                sunPathPointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                    strncpy(destination, pathPointer, 103)
                }
            }
        }

        let didConnect = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(didConnect, 0)

        let bytes = [UInt8](message.utf8)
        let written = bytes.withUnsafeBytes { buffer in
            write(fileDescriptor, buffer.baseAddress, buffer.count)
        }
        XCTAssertEqual(written, bytes.count)
    }
}

private func assertColorEqual(
    _ lhs: NSColor,
    _ rhs: NSColor,
    accuracy: CGFloat,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let left = lhs.usingColorSpace(.deviceRGB)
    let right = rhs.usingColorSpace(.deviceRGB)

    XCTAssertEqual(left?.redComponent ?? 0, right?.redComponent ?? 0, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(left?.greenComponent ?? 0, right?.greenComponent ?? 0, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(left?.blueComponent ?? 0, right?.blueComponent ?? 0, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(left?.alphaComponent ?? 0, right?.alphaComponent ?? 0, accuracy: accuracy, file: file, line: line)
}

private func withRestoredTerminalDebugLogState(_ body: () -> Void) {
    let originalEnabled = TerminalDebugLog.isEnabled
    let originalCategories = TerminalDebugLog.categories
    let originalSink = TerminalDebugLog.sink
    defer {
        TerminalDebugLog.isEnabled = originalEnabled
        TerminalDebugLog.categories = originalCategories
        TerminalDebugLog.sink = originalSink
    }

    body()
}
