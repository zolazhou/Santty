import AppKit
import Darwin
import GhosttyTerminal
import KeyboardShortcuts
import XCTest
@testable import Santty

final class SanttyTests: XCTestCase {

    @MainActor
    func testAutoResizePanelTriggerChangesSliderRangesAndClampsFocusValues() throws {
        let panel = PaneAutoResizePanelController()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(try XCTUnwrap(panel.window?.contentView))
        let trigger = try XCTUnwrap(controls.compactMap { $0 as? NSSegmentedControl }.first)
        let enabled = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "Enable Auto Resize" })
        let sliders = controls.compactMap { $0 as? NSSlider }
        XCTAssertEqual(sliders.count, 2)
        trigger.selectedSegment = 1
        enabled.state = .on
        enabled.sendAction(enabled.action, to: enabled.target)
        XCTAssertEqual(trigger.selectedSegment, 1)
        for slider in sliders {
            XCTAssertEqual(slider.minValue, 0)
            XCTAssertEqual(slider.maxValue, 1)
        }
        sliders[0].doubleValue = 0
        sliders[1].doubleValue = 1
        var updated: PaneAutoResizeConfiguration?
        panel.onChange = { updated = $0 }
        trigger.selectedSegment = 0
        trigger.sendAction(trigger.action, to: trigger.target)
        XCTAssertEqual(updated?.trigger, .focus)
        XCTAssertEqual(updated?.ratios, .init(horizontal: 0.25, vertical: 0.95))
        for slider in sliders {
            XCTAssertEqual(slider.minValue, 0.25)
            XCTAssertEqual(slider.maxValue, 0.95)
        }
        trigger.selectedSegment = 1
        trigger.sendAction(trigger.action, to: trigger.target)
        XCTAssertEqual(updated?.trigger, .unfocused)
        for slider in sliders {
            XCTAssertEqual(slider.minValue, 0)
            XCTAssertEqual(slider.maxValue, 1)
        }
    }

    @MainActor
    func testAutoResizePanelAxesToggleIndependentlyAndRememberRatios() throws {
        let panel = PaneAutoResizePanelController()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(try XCTUnwrap(panel.window?.contentView))
        let buttons = controls.compactMap { $0 as? NSButton }
        let enabled = try XCTUnwrap(buttons.first { $0.title == "Enable Auto Resize" })
        let horizontal = try XCTUnwrap(buttons.first { $0.title == "Horizontal" })
        let vertical = try XCTUnwrap(buttons.first { $0.title == "Vertical" })
        let sliders = controls.compactMap { $0 as? NSSlider }
        let horizontalSlider = try XCTUnwrap(sliders.first { $0.accessibilityLabel() == "Horizontal" })
        let verticalSlider = try XCTUnwrap(sliders.first { $0.accessibilityLabel() == "Vertical" })
        var updated: PaneAutoResizeConfiguration?
        panel.onChange = { updated = $0 }
        func set(_ button: NSButton, _ state: NSControl.StateValue) {
            button.state = state
            button.sendAction(button.action, to: button.target)
        }
        XCTAssertEqual(horizontal.state, .on)
        XCTAssertEqual(vertical.state, .on)
        XCTAssertFalse(horizontal.isEnabled)
        XCTAssertFalse(vertical.isEnabled)
        set(enabled, .on)
        horizontalSlider.doubleValue = 0.8
        verticalSlider.doubleValue = 0.6
        horizontalSlider.sendAction(horizontalSlider.action, to: horizontalSlider.target)

        set(vertical, .off)
        XCTAssertEqual(updated?.isHorizontalEnabled, true)
        XCTAssertEqual(updated?.isVerticalEnabled, false)
        XCTAssertTrue(horizontalSlider.isEnabled)
        XCTAssertFalse(verticalSlider.isEnabled)
        XCTAssertEqual(updated?.ratios, .init(horizontal: 0.8, vertical: 0.6))
        set(horizontal, .off)
        XCTAssertFalse(horizontalSlider.isEnabled)
        XCTAssertFalse(verticalSlider.isEnabled)
        set(vertical, .on)
        XCTAssertEqual(updated?.isHorizontalEnabled, false)
        XCTAssertEqual(updated?.isVerticalEnabled, true)
        XCTAssertFalse(horizontalSlider.isEnabled)
        XCTAssertTrue(verticalSlider.isEnabled)

        set(enabled, .off)
        XCTAssertFalse(horizontal.isEnabled)
        XCTAssertFalse(vertical.isEnabled)
        XCTAssertFalse(verticalSlider.isEnabled)
        set(enabled, .on)
        XCTAssertEqual(horizontal.state, .off)
        XCTAssertEqual(vertical.state, .on)
        XCTAssertFalse(horizontalSlider.isEnabled)
        XCTAssertTrue(verticalSlider.isEnabled)
        set(horizontal, .on)
        XCTAssertTrue(horizontalSlider.isEnabled)
        XCTAssertTrue(verticalSlider.isEnabled)
        XCTAssertEqual(updated?.ratios, .init(horizontal: 0.8, vertical: 0.6))
    }

    @MainActor
    func testWindowsAndPaneControlsInheritApplicationDarkAppearance() throws {
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        let settings = SettingsWindowController()
        let resize = PaneAutoResizePanelController()
        let main = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        let palette = CommandPalettePanel(contentView: CommandPaletteView())
        for window in [main, palette, try XCTUnwrap(settings.window), try XCTUnwrap(resize.window)] {
            XCTAssertNil(window.appearance)
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        }
        let toolbar = WorkspaceToolbarView()
        let agents = AgentsPaneController()
        let workspaces = SidebarListPaneController()
        let browser = BrowserPaneController()
        let views: [NSView] = [toolbar, toolbar.workspaceSwitcher, agents.hostView, agents.managerView,
            workspaces.hostView, browser.hostView, browser.browserHostView.locationBar,
            browser.browserHostView.addressField, AppAppearanceDefaults.makeVibrancyView()]
        for view in [toolbar, agents.hostView, workspaces.hostView, browser.hostView] { main.contentView?.addSubview(view) }
        for view in views {
            XCTAssertNil(view.appearance)
            XCTAssertEqual(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        }
    }

    @MainActor
    func testSidebarLayersResolveInheritedAppearanceAndRefreshOnWindowChanges() throws {
        let view = ListPaneHostView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            window.appearance = appearance
            // A caller's drawing context must not override the view's inherited appearance.
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { view.updateAppearance() }
            XCTAssertNil(view.appearance)
            var expected: CGColor?
            appearance.performAsCurrentDrawingAppearance { expected = NSColor.separatorColor.cgColor }
            XCTAssertEqual(view.layer?.borderColor, expected)
        }
    }

    @MainActor
    func testListPanesFollowBrowserVibrancyAcrossWindowAndFloatingModes() throws {
        let previousHidden = AppAppearanceSettings.isWindowHidden
        defer { AppAppearanceSettings.isWindowHidden = previousHidden }
        let browser = BrowserPaneHostView(paneID: UUID())
        let panes: [any PaneControlling] = [SidebarListPaneController(), AgentsPaneController()]
        let reference = try XCTUnwrap(browser.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func tintAlpha(_ view: NSVisualEffectView) throws -> CGFloat {
            try XCTUnwrap(view.subviews.first { $0.identifier == AppAppearanceDefaults.vibrancyTintIdentifier }?.layer?.backgroundColor).alpha
        }
        for hidden in [false, true] {
            AppAppearanceSettings.isWindowHidden = hidden
            for floating in [false, true] {
                browser.updatePresentation(isFocused: true, isFloating: floating)
                for pane in panes {
                    pane.updatePresentation(isFocused: true, isFloating: floating)
                    let effect = try XCTUnwrap(pane.hostView.subviews.compactMap { $0 as? NSVisualEffectView }.first)
                    XCTAssertEqual(effect.isHidden, reference.isHidden)
                    XCTAssertEqual(effect.material, reference.material)
                    XCTAssertEqual(effect.blendingMode, reference.blendingMode)
                    XCTAssertEqual(try tintAlpha(effect), try tintAlpha(reference), accuracy: 0.001)
                    XCTAssertEqual(pane.hostView.layer?.backgroundColor?.alpha, browser.layer?.backgroundColor?.alpha)
                    XCTAssertLessThan(pane.focusTargetView.layer?.backgroundColor?.alpha ?? 0, 1)
                    for case let table as NSTableView in descendants(pane.hostView) {
                        XCTAssertEqual(table.backgroundColor.alphaComponent, 0)
                        XCTAssertFalse(table.isOpaque)
                    }
                }
            }
        }
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
    func testTerminalPaneConfigurationKeepsCLIEnvironmentWithoutAgentHooks() {
        let paneID = UUID()
        let paneController = TerminalPaneController(id: paneID)
        let renderedConfiguration = paneController.debugRenderedTerminalConfig

        XCTAssertTrue(renderedConfiguration.contains("env = SANTTY_PANE_ID=\(paneID.uuidString)"))
        XCTAssertTrue(renderedConfiguration.contains("env = SANTTY_CONTROL_SOCKET="))
        XCTAssertFalse(renderedConfiguration.contains("SANTTY_RUNTIME_OWNER="))
        XCTAssertFalse(renderedConfiguration.contains("SANTTY_AGENT_SOCKET="))
    }

    @MainActor
    func testTerminalPaneConfigurationUsesProvidedWorkingDirectory() {
        let paneController = TerminalPaneController(
            workingDirectory: "/tmp/project"
        )
        let renderedConfiguration = paneController.debugRenderedTerminalConfig

        XCTAssertTrue(renderedConfiguration.contains("working-directory = /tmp/project"))
        XCTAssertTrue(renderedConfiguration.contains("env = SANTTY_PANE_ID="))
        XCTAssertTrue(renderedConfiguration.contains("env = SANTTY_CONTROL_SOCKET="))
        XCTAssertFalse(renderedConfiguration.contains("SANTTY_RUNTIME_OWNER="))
        XCTAssertFalse(renderedConfiguration.contains("SANTTY_AGENT_SOCKET="))
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
    func testAppearanceSettingsClampWindowCornerRadius() {
        AppAppearanceSettings.windowCornerRadius = 100

        XCTAssertEqual(
            AppAppearanceSettings.windowCornerRadius,
            AppAppearanceSettings.windowCornerRadiusRange.upperBound
        )

        AppAppearanceSettings.windowCornerRadius = -10

        XCTAssertEqual(
            AppAppearanceSettings.windowCornerRadius,
            AppAppearanceSettings.windowCornerRadiusRange.lowerBound
        )
        AppAppearanceSettings.resetWindowCornerRadius()
    }

    @MainActor
    func testAppearanceSettingsResetReturnsDefaultWindowCornerRadius() {
        AppAppearanceSettings.windowCornerRadius = 20

        AppAppearanceSettings.resetWindowCornerRadius()

        XCTAssertEqual(
            AppAppearanceSettings.windowCornerRadius,
            AppAppearanceSettings.defaultWindowCornerRadius
        )
    }

    @MainActor
    func testWindowPresentationAppliesCornerRadiusOnlyWhenWindowHidden() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        guard let defaultRadius = AppAppearanceDefaults.debugEffectiveCornerRadius(of: window) else {
            throw XCTSkip("This macOS version does not expose the private effective corner radius getter")
        }

        AppAppearanceDefaults.applyWindowPresentation(
            to: window,
            isWindowHidden: true,
            cornerRadius: 24
        )

        XCTAssertEqual(AppAppearanceDefaults.debugEffectiveCornerRadius(of: window), 24)

        // A true zero radius must go through `_setEffectiveCornerRadius:`:
        // `_setCornerRadius:` treats 0 as "reset to the system default".
        AppAppearanceDefaults.applyWindowPresentation(
            to: window,
            isWindowHidden: true,
            cornerRadius: 0
        )

        XCTAssertEqual(AppAppearanceDefaults.debugEffectiveCornerRadius(of: window), 0)

        AppAppearanceDefaults.applyWindowPresentation(
            to: window,
            isWindowHidden: false,
            cornerRadius: 24
        )

        XCTAssertEqual(
            AppAppearanceDefaults.debugEffectiveCornerRadius(of: window), defaultRadius)
    }

    @MainActor
    func testWindowPresentationFollowsHiddenWindowSetting() {
        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        AppAppearanceDefaults.applyWindowPresentation(to: window, isWindowHidden: true)

        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        // The window stays titled even when hidden: AppKit does not deliver
        // drop events to borderless windows, which breaks tab reordering.
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.canBecomeMain)

        AppAppearanceDefaults.applyWindowPresentation(to: window, isWindowHidden: false)

        XCTAssertTrue(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .windowBackgroundColor)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.styleMask.contains(.titled))
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
    }

    @MainActor
    func testMainWindowZoomFillsVisibleScreenAndRestoresFrameWithHiddenButtons() async throws {
        XCTAssertFalse(NSScreen.screens.isEmpty)
        for screen in NSScreen.screens {
            for isWindowHidden in [false, true] {
                let window = MainWindow(
                    contentRect: NSRect(x: screen.visibleFrame.minX + 40,
                        y: screen.visibleFrame.minY + 40, width: 720, height: 480),
                    styleMask: [.titled, .resizable, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                let controller = WorkspaceViewController()
                window.delegate = controller
                AppAppearanceDefaults.applyWindowPresentation(to: window, isWindowHidden: isWindowHidden)
                // Keep test windows offscreen so external window managers cannot retile them.
                defer { window.close() }
                let originalFrame = window.frame
                let visibleFrame = try XCTUnwrap(window.screen).visibleFrame
                XCTAssertTrue(try XCTUnwrap(window.standardWindowButton(.zoomButton)).isHidden)

                window.zoom(nil)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(window.frame, visibleFrame, "hidden=\(isWindowHidden)")
                XCTAssertFalse(window.styleMask.contains(.fullScreen))

                window.zoom(nil)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(window.frame, originalFrame, "hidden=\(isWindowHidden)")
            }
        }
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

        XCTAssertNil(view.appearance)
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
    func testPaletteInputTabCyclesCategoriesWithoutMovingFocusOrChangingQuery() throws {
        let commands = PaletteItemKind.allCases.map { kind in
            AppCommand(id: kind.rawValue, title: "Logs", shortcut: nil, isEnabled: true, kind: kind) {}
        }
        let view = CommandPaletteView(commands: commands, searchQuery: "logs")
        let panel = CommandPalettePanel(contentView: view)
        panel.orderBack(nil)
        defer { panel.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        view.focusSearchField()
        func input(in root: NSView) -> NSTextField? {
            if let field = root as? NSTextField, field.isEditable { return field }
            return root.subviews.lazy.compactMap { input(in: $0) }.first
        }
        let search = try XCTUnwrap(input(in: view))
        let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
        let picker = try XCTUnwrap(firstSubview(ofType: NSSegmentedControl.self, in: view))
        let table = try XCTUnwrap(firstSubview(ofType: NSTableView.self, in: view))
        XCTAssertEqual((0..<picker.segmentCount).map { picker.label(forSegment: $0) },
                       ["All", "Agent", "Workspace", "Tab", "Pane", "Command"])
        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48))
        for segment in Array(1..<picker.segmentCount) + [0] {
            editor.keyDown(with: tab)
            XCTAssertEqual(picker.selectedSegment, segment)
            XCTAssertEqual(table.numberOfRows, segment == 0 ? commands.count : 1)
            XCTAssertEqual(search.stringValue, "logs")
            XCTAssertTrue(panel.firstResponder === editor)
        }
    }

    @MainActor
    func testPaletteCategoriesStayAboveScrollableResults() throws {
        let view = CommandPaletteView()
        let panel = CommandPalettePanel(contentView: view)
        panel.setContentSize(view.preferredContentSize)
        view.layoutSubtreeIfNeeded()
        let picker = try XCTUnwrap(firstSubview(ofType: NSSegmentedControl.self, in: view))
        let scroll = try XCTUnwrap(firstSubview(ofType: NSScrollView.self, in: view))
        XCTAssertLessThanOrEqual(scroll.frame.maxY, picker.frame.minY - 8)
    }

    @MainActor
    func testPaletteRefreshPreservesSearchCategoryAndSelectedIdentity() throws {
        let first = AppCommand(id: "first", title: "Logs", shortcut: nil, isEnabled: true, kind: .pane, subtitle: "Default › API") {}
        let second = AppCommand(id: "second", title: "Logs", shortcut: nil, isEnabled: true, kind: .pane, subtitle: "Tools › API") {}
        let view = CommandPaletteView(commands: [first, second], searchQuery: "logs")
        let table = try XCTUnwrap(firstSubview(ofType: NSTableView.self, in: view))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        view.updateCommands([second, first], resetSearch: false)
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(table.selectedRow, 0)
        let picker = try XCTUnwrap(firstSubview(ofType: NSSegmentedControl.self, in: view))
        picker.selectedSegment = 1
        _ = picker.sendAction(picker.action, to: picker.target)
        XCTAssertEqual(table.numberOfRows, 0)
        view.updateCommands([second, first], resetSearch: false)
        XCTAssertEqual(table.numberOfRows, 0)
    }

    @MainActor
    func testCommandPaletteViewHidesDisabledCommands() throws {
        let view = CommandPaletteView(commands: [
            AppCommand(id: "one", title: "One", shortcut: nil, isEnabled: true) {},
            AppCommand(id: "two", title: "Two", shortcut: nil, isEnabled: false) {},
            AppCommand(id: "three", title: "Three", shortcut: nil, isEnabled: true) {},
        ])

        let tableView = try XCTUnwrap(firstSubview(ofType: NSTableView.self, in: view))

        XCTAssertEqual(tableView.numberOfRows, 2)
    }

    @MainActor
    func testCommandPalettePanelKeepsFixedPreferredContentSize() {
        let view = CommandPaletteView()
        let panel = CommandPalettePanel(contentView: view)

        XCTAssertEqual(panel.contentMinSize.width, view.preferredContentSize.width, accuracy: 0.001)
        XCTAssertEqual(panel.contentMinSize.height, view.preferredContentSize.height, accuracy: 0.001)
        XCTAssertEqual(panel.contentMaxSize.width, view.preferredContentSize.width, accuracy: 0.001)
        XCTAssertEqual(panel.contentMaxSize.height, view.preferredContentSize.height, accuracy: 0.001)
    }

    @MainActor
    func testCommandPaletteShowRestoresPreferredContentSizeAfterShrink() throws {
        let controller = CommandPaletteWindowController()
        let panel = try XCTUnwrap(controller.window)
        let expectedContentSize = panel.contentMinSize
        let parentWindow = NSWindow(
            contentRect: NSRect(x: 80, y: 120, width: 1200, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        panel.contentMinSize = .zero
        panel.contentMaxSize = NSSize(width: 2000, height: 2000)
        panel.setContentSize(NSSize(width: 320, height: 140))

        controller.show(
            commands: [
                AppCommand(id: "one", title: "One", shortcut: nil, isEnabled: true) {},
            ],
            relativeTo: parentWindow
        )

        let restoredContentSize = try XCTUnwrap(panel.contentView?.bounds.size)
        XCTAssertEqual(restoredContentSize.width, expectedContentSize.width, accuracy: 0.001)
        XCTAssertEqual(restoredContentSize.height, expectedContentSize.height, accuracy: 0.001)
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

private func firstSubview<View: NSView>(ofType type: View.Type, in rootView: NSView) -> View? {
    if let view = rootView as? View {
        return view
    }

    for subview in rootView.subviews {
        if let view = firstSubview(ofType: type, in: subview) {
            return view
        }
    }

    return nil
}
