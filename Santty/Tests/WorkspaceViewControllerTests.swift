import AppKit
import KeyboardShortcuts
import XCTest
@testable import Santty

final class WorkspaceViewControllerTests: XCTestCase {
    @MainActor
    func testPaneNamesRevealAfterCommandHoldAndCancelForShortcutsAndFocusLoss() async throws {
        let controller = Self.makeController()
        let firstID = try XCTUnwrap(controller.debugFocusedPaneID)
        controller.debugSetFocusedPaneName("API")
        controller.debugSplitFocusedPane(along: .horizontal)
        let secondID = try XCTUnwrap(controller.debugFocusedPaneID)
        controller.debugSetFocusedPaneName("Frontend")
        controller.debugSplitFocusedPane(along: .vertical)
        let unnamedID = try XCTUnwrap(controller.debugFocusedPaneID)
        let badges = try [firstID, secondID, unnamedID].map {
            try XCTUnwrap(controller.debugPaneNameBadge(for: $0))
        }
        let terminalFrame = controller.debugTerminalFrame(for: firstID)
        func flags(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
        }
        let down = try flags(.command)
        let up = try flags([])
        XCTAssertTrue(badges.allSatisfy(\.isHidden))
        controller.handlePaneNameEvent(down)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(badges.allSatisfy(\.isHidden))
        controller.handlePaneNameEvent(up)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(badges.allSatisfy(\.isHidden))

        controller.handlePaneNameEvent(down)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(badges[0].isHidden)
        XCTAssertFalse(badges[1].isHidden)
        XCTAssertTrue(badges[2].isHidden)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.debugTerminalFrame(for: firstID), terminalFrame)
        XCTAssertNil(badges[0].hitTest(.zero))
        controller.handlePaneNameEvent(up)
        XCTAssertTrue(badges.allSatisfy(\.isHidden))

        controller.handlePaneNameEvent(down)
        controller.handlePaneNameEvent(try XCTUnwrap(Self.makeKeyEvent("c", modifiers: .command)))
        controller.handlePaneNameEvent(down)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(badges.allSatisfy(\.isHidden))

        controller.handlePaneNameEvent(up)
        controller.handlePaneNameEvent(down)
        controller.handlePaneNameEvent(try flags([.command, .shift]))
        controller.handlePaneNameEvent(down)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(badges.allSatisfy(\.isHidden))

        controller.handlePaneNameEvent(up)
        controller.handlePaneNameEvent(down)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(badges[0].isHidden)
        controller.handlePaneNameEvent(try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        XCTAssertTrue(badges.allSatisfy(\.isHidden))
        controller.handlePaneNameEvent(up)
        controller.handlePaneNameEvent(down)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(badges[0].isHidden)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertTrue(badges.allSatisfy(\.isHidden))
        controller.handlePaneNameEvent(down)
        controller.debugNewTab()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(badges.allSatisfy(\.isHidden))
    }

    @MainActor
    func testNameBadgeDoesNotTruncateShortNamesAfterRenaming() throws {
        let terminal = TerminalPaneController()
        let browser = BrowserPaneController()
        for pane in [terminal as any PaneControlling, browser as any PaneControlling] {
            pane.hostView.frame = NSRect(x: 0, y: 0, width: 640, height: 240)
            let badge = try XCTUnwrap(pane.hostView.subviews.compactMap { $0 as? PaneNameBadgeView }.first)
            let label = try XCTUnwrap(badge.subviews.compactMap { $0 as? NSTextField }.first)
            pane.setNameVisible(true)
            for name in ["API", "Frontend", "中文", "Dev", "ssh", "a", "server", "Santty"] {
                pane.name = name
                pane.hostView.layoutSubtreeIfNeeded()
                XCTAssertGreaterThanOrEqual(label.bounds.width, ceil(try XCTUnwrap(label.cell).cellSize.width), name)
                func renderedText() throws -> Data {
                    let bitmap = try XCTUnwrap(label.bitmapImageRepForCachingDisplay(in: label.bounds))
                    label.cacheDisplay(in: label.bounds, to: bitmap)
                    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                }
                let truncated = try renderedText()
                label.lineBreakMode = .byClipping
                let full = try renderedText()
                XCTAssertEqual(truncated, full, "Short name rendered with an ellipsis: \(name)")
                label.lineBreakMode = .byTruncatingTail
            }
        }
    }

    @MainActor
    func testNameBadgeClipsLongNamesWithoutResizingBrowserContent() {
        let host = BrowserPaneHostView(paneID: UUID())
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.nameBadge.name = String(repeating: "长名字", count: 100)
        host.nameBadge.isRevealed = true
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.webView.frame, host.bounds)
        XCTAssertEqual(host.nameBadge.frame.minX, 8, accuracy: 0.001)
        XCTAssertEqual(host.nameBadge.frame.maxY, host.bounds.maxY - 8, accuracy: 0.001)
        XCTAssertLessThanOrEqual(host.nameBadge.frame.maxX, host.bounds.maxX - 8)
        XCTAssertGreaterThan(host.nameBadge.frame.height, 0)
        XCTAssertNil(host.nameBadge.hitTest(host.nameBadge.frame.origin))
    }

    func testClearingKeybindingDoesNotRestoreDefaultShortcut() async throws {
        try await MainActor.run {
            try Self.withRestoredKeybindingUserDefaults {
                let action = KeybindingAction.splitPaneHorizontally
                KeybindingSettings.resetShortcut(for: action)
                XCTAssertNotNil(KeybindingSettings.effectiveShortcut(for: action))

                KeyboardShortcuts.setShortcut(nil, for: action.shortcutName)
                KeybindingSettings.notifyChange(for: action)

                XCTAssertNil(KeybindingSettings.effectiveShortcut(for: action))
                XCTAssertNil(KeybindingSettings.displayShortcut(for: action))
                let menuItem = NSMenuItem()
                KeybindingSettings.applyShortcut(for: action, to: menuItem)
                XCTAssertTrue(menuItem.keyEquivalent.isEmpty)
                let event = try XCTUnwrap(Self.makeKeyEvent(
                    "\\", modifiers: [.command, .shift],
                    keyCode: UInt16(KeyboardShortcuts.Key.backslash.rawValue)
                ))
                XCTAssertNil(KeybindingSettings.action(matching: event))
                XCTAssertFalse(KeyboardShortcuts.isEnabled(for: action.shortcutName))
            }
        }
    }

    func testInitialWorkspaceCreatesOneTabWithOnePane() async throws {
        try await MainActor.run {
            let controller = Self.makeController()

            XCTAssertEqual(controller.debugTabIDs.count, 1)
            XCTAssertEqual(controller.debugSelectedTabID, controller.debugTabIDs.first)
            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder.count, 1)
            let focusedPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            XCTAssertEqual(controller.debugPaneAutoResizeConfiguration(for: focusedPaneID)?.isEnabled, false)
        }
    }

    func testConvertPaneToBrowserAndBackPreservesPaneID() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let paneID = try XCTUnwrap(controller.debugFocusedPaneID)

            XCTAssertTrue(controller.debugFocusedPaneIsTerminal)

            controller.debugPerformCommand(withID: "pane.browser.convert")

            XCTAssertTrue(controller.debugFocusedPaneIsBrowser)
            XCTAssertEqual(controller.debugFocusedPaneID, paneID)

            controller.debugPerformCommand(withID: "pane.terminal.convert")

            XCTAssertTrue(controller.debugFocusedPaneIsTerminal)
            XCTAssertEqual(controller.debugFocusedPaneID, paneID)
        }
    }

    func testLocationShortcutNeverRegistersAsGlobalHotkey() async throws {
        try await MainActor.run {
            try Self.withRestoredKeybindingUserDefaults {
                let action = KeybindingAction.focusBrowserLocation
                UserDefaults.standard.removeObject(forKey: "KeyboardShortcuts_Santty.focusBrowserLocation")
                let name = action.shortcutName
                XCTAssertFalse(KeyboardShortcuts.isEnabled(for: name), "Creating the default must not capture Ctrl+L globally")

                KeybindingSettings.resetShortcut(for: action)
                XCTAssertFalse(KeyboardShortcuts.isEnabled(for: name), "Resetting must keep dispatch local")

                KeyboardShortcuts.setShortcut(.init(.l, modifiers: [.control, .shift]), for: name)
                KeybindingSettings.notifyChange(for: action)
                XCTAssertFalse(KeyboardShortcuts.isEnabled(for: name), "Recording a shortcut must keep dispatch local")
                XCTAssertEqual(KeybindingSettings.effectiveShortcut(for: action), .init(.l, modifiers: [.control, .shift]))
            }
        }
    }

    func testFocusLocationShortcutOnlyConsumesEventsInBrowserPane() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let terminalPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            let menu = NSMenu()
            let paneMenu = NSMenu()
            let parent = NSMenuItem()
            parent.submenu = paneMenu
            menu.addItem(parent)
            let item = paneMenu.addItem(
                withTitle: "Focus Location Bar",
                action: #selector(WorkspaceViewController.focusBrowserLocationBar(_:)),
                keyEquivalent: "l"
            )
            item.target = controller
            item.keyEquivalentModifierMask = [.control]
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{0C}",
                charactersIgnoringModifiers: "\u{0C}",
                isARepeat: false,
                keyCode: UInt16(KeyboardShortcuts.Key.l.rawValue)
            ))

            XCTAssertFalse(controller.performKeybindingAction(.focusBrowserLocation))
            XCTAssertFalse(AppMenuKeyEquivalents.perform(event, in: menu))

            controller.debugPerformCommand(withID: "pane.browser.new")
            XCTAssertTrue(controller.performKeybindingAction(.focusBrowserLocation))
            XCTAssertTrue(AppMenuKeyEquivalents.perform(event, in: menu))

            controller.debugFocusPane(withID: terminalPaneID)
            XCTAssertFalse(controller.performKeybindingAction(.focusBrowserLocation))
            XCTAssertFalse(AppMenuKeyEquivalents.perform(event, in: menu))
        }
    }

    func testNewBrowserPaneSplitsFocusedPane() async throws {
        try await MainActor.run {
            let controller = Self.makeController()

            controller.debugPerformCommand(withID: "pane.browser.new")

            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder.count, 2)
            XCTAssertTrue(controller.debugFocusedPaneIsBrowser)
        }
    }

    func testSplitFromBrowserPaneCreatesTerminalPane() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            controller.debugPerformCommand(withID: "pane.browser.new")

            XCTAssertTrue(controller.debugFocusedPaneIsBrowser)

            controller.debugSplitFocusedPane(along: .horizontal)

            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder.count, 3)
            XCTAssertTrue(controller.debugFocusedPaneIsTerminal)
        }
    }

    func testBrowserPaneHostViewWebViewCoversBounds() async throws {
        try await MainActor.run {
            let hostView = BrowserPaneHostView(paneID: UUID())
            hostView.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
            hostView.layoutSubtreeIfNeeded()

            XCTAssertEqual(hostView.appearance?.name, .darkAqua)
            XCTAssertTrue(hostView.webView.isHidden)
            XCTAssertEqual(hostView.webView.frame, hostView.bounds)

            hostView.showWebView()

            XCTAssertFalse(hostView.webView.isHidden)
            // The location bar floats above the web content at the bottom.
            XCTAssertEqual(hostView.locationBar.frame.minY, BrowserLocationBarView.bottomMargin)

            hostView.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            hostView.layoutSubtreeIfNeeded()

            XCTAssertEqual(hostView.webView.frame, hostView.bounds)
        }
    }

    func testNewTabSelectsItAndCreatesIndependentPaneTree() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let originalTabID = try XCTUnwrap(controller.debugSelectedTabID)
            let originalPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            controller.debugNewTab()

            let tabIDs = controller.debugTabIDs
            XCTAssertEqual(tabIDs.count, 2)

            let selectedTabID = try XCTUnwrap(controller.debugSelectedTabID)
            XCTAssertNotEqual(selectedTabID, originalTabID)
            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder.count, 1)
            XCTAssertEqual(controller.debugLayoutNode, controller.debugPaneIDsInTraversalOrder.last.map(LayoutNode.panel))

            let originalTabPaneIDs = controller.debugPaneIDsInTraversalOrder(forTabID: originalTabID)
            XCTAssertEqual(originalTabPaneIDs.count, 2)
            XCTAssertTrue(originalTabPaneIDs.contains(originalPaneID))
        }
    }

    func testSplitInOneTabDoesNotAffectAnotherTab() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstTabID = try XCTUnwrap(controller.debugSelectedTabID)

            controller.debugNewTab()
            let secondTabID = try XCTUnwrap(controller.debugSelectedTabID)

            controller.debugSelectTab(withID: firstTabID)
            controller.debugSplitFocusedPane(along: .horizontal)

            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder(forTabID: firstTabID).count, 2)
            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder(forTabID: secondTabID).count, 1)
            XCTAssertEqual(controller.debugLayoutNode(forTabID: secondTabID), controller.debugPaneIDsInTraversalOrder(forTabID: secondTabID).first.map(LayoutNode.panel))
        }
    }

    func testSplitPaneInheritsFocusedPaneWorkingDirectory() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let parentPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSetPaneWorkingDirectory("/tmp/project", for: parentPaneID)
            controller.debugSplitFocusedPane(along: .horizontal)

            let childPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            let renderedConfiguration = try XCTUnwrap(
                controller.debugRenderedTerminalConfig(for: childPaneID)
            )

            XCTAssertNotEqual(childPaneID, parentPaneID)
            XCTAssertTrue(renderedConfiguration.contains("working-directory = /tmp/project"))
        }
    }

    func testPaneWorkingDirectoryForNewPanePrefersForegroundProcessDirectory() async {
        await MainActor.run {
            let expectedProcessID: Int32 = 42
            let paneController = TerminalPaneController(
                workingDirectory: "/tmp/stale-shell-report",
                foregroundProcessIDProvider: { expectedProcessID },
                processWorkingDirectoryProvider: { processID in
                    XCTAssertEqual(processID, expectedProcessID)
                    return "/tmp/live-foreground-directory"
                }
            )

            XCTAssertEqual(
                paneController.workingDirectoryForNewPane,
                "/tmp/live-foreground-directory"
            )
        }
    }

    func testProcessWorkingDirectoryResolverReadsCurrentProcessDirectory() {
        let processID = Int32(ProcessInfo.processInfo.processIdentifier)

        XCTAssertEqual(
            ProcessWorkingDirectoryResolver.workingDirectory(for: processID),
            FileManager.default.currentDirectoryPath
        )
    }

    func testSplitPaneWithoutFocusedPaneWorkingDirectoryUsesDefaultConfiguration() async throws {
        try await MainActor.run {
            let controller = Self.makeController()

            controller.debugSplitFocusedPane(along: .horizontal)

            let childPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            let renderedConfiguration = try XCTUnwrap(
                controller.debugRenderedTerminalConfig(for: childPaneID)
            )

            XCTAssertFalse(renderedConfiguration.contains("working-directory ="))
        }
    }

    func testCustomTabTitleOverridesFocusedPaneTitleUntilCleared() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let tabID = try XCTUnwrap(controller.debugSelectedTabID)
            let paneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSetPaneTitle("Shell One", for: paneID)
            XCTAssertEqual(controller.debugDisplayTitle(forTabID: tabID), "Shell One")

            controller.debugSetSelectedTabTitle("Project Logs")
            controller.debugSetPaneTitle("Shell Two", for: paneID)
            XCTAssertEqual(controller.debugDisplayTitle(forTabID: tabID), "Project Logs")

            controller.debugSetSelectedTabTitle("   ")
            XCTAssertEqual(controller.debugDisplayTitle(forTabID: tabID), "Shell Two")
        }
    }

    func testClosingSelectedTabSelectsAdjacentTab() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstTabID = try XCTUnwrap(controller.debugSelectedTabID)

            controller.debugNewTab()
            let secondTabID = try XCTUnwrap(controller.debugSelectedTabID)
            let secondTabPaneIDs = controller.debugPaneIDsInTraversalOrder(forTabID: secondTabID)

            controller.debugCloseTab(withID: secondTabID)

            XCTAssertEqual(controller.debugTabIDs, [firstTabID])
            XCTAssertEqual(controller.debugSelectedTabID, firstTabID)
            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder(forTabID: firstTabID).count, 1)
            XCTAssertEqual(secondTabPaneIDs.count, 1)
        }
    }

    func testTabStripShowsOneBasedTabIndices() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            controller.debugNewTab()
            controller.debugNewTab()

            let tabIDs = controller.debugTabIDs

            XCTAssertEqual(controller.debugTabIndexText(for: tabIDs[0]), "1")
            XCTAssertEqual(controller.debugTabIndexText(for: tabIDs[1]), "2")
            XCTAssertEqual(controller.debugTabIndexText(for: tabIDs[2]), "3")
            XCTAssertEqual(controller.debugTabCloseButtonIsHidden(for: tabIDs[0]), true)
        }
    }

    func testFocusTabAtIndexSelectsMatchingTab() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            controller.debugNewTab()
            controller.debugNewTab()
            let tabIDs = controller.debugTabIDs
            let menuItem = NSMenuItem(
                title: "Focus Tab 1",
                action: #selector(WorkspaceViewController.focusTabAtIndex(_:)),
                keyEquivalent: "1"
            )
            menuItem.tag = 0

            XCTAssertTrue(controller.validateMenuItem(menuItem))
            controller.focusTabAtIndex(menuItem)

            XCTAssertEqual(controller.debugSelectedTabID, tabIDs[0])
        }
    }

    func testMovingTabsReordersStateAndKeepsSelection() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            controller.debugNewTab()
            controller.debugNewTab()
            let tabIDs = controller.debugTabIDs
            let selectedTabID = try XCTUnwrap(controller.debugSelectedTabID)

            controller.debugMoveTab(withID: tabIDs[0], to: 2)

            XCTAssertEqual(controller.debugTabIDs, [tabIDs[1], tabIDs[2], tabIDs[0]])
            XCTAssertEqual(controller.debugSelectedTabID, selectedTabID)
            XCTAssertEqual(controller.debugTabIndexText(for: tabIDs[1]), "1")
            XCTAssertEqual(controller.debugTabIndexText(for: tabIDs[2]), "2")
            XCTAssertEqual(controller.debugTabIndexText(for: tabIDs[0]), "3")
        }
    }

    func testClosingLastTabRequestsWindowClosePath() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let onlyTabID = try XCTUnwrap(controller.debugSelectedTabID)
            let paneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugPerformClosePane(withID: paneID)

            XCTAssertTrue(controller.debugDidRequestWindowClose)
            XCTAssertNil(controller.debugSelectedTabID)
            XCTAssertTrue(controller.debugTabIDs.isEmpty)
            XCTAssertNil(controller.debugLayoutNode(forTabID: onlyTabID))
        }
    }

    func testPaneExitClosesPaneWithoutLeavingExitedPresentation() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugSplitFocusedPane(along: .horizontal)
            let exitedPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSimulatePaneExit(withID: exitedPaneID)

            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder, [firstPaneID])
            XCTAssertEqual(controller.debugFocusedPaneID, firstPaneID)
            XCTAssertEqual(controller.debugLayoutNode, .panel(firstPaneID))
        }
    }

    func testPaneExitClosesPaneInBackgroundTab() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstTabID = try XCTUnwrap(controller.debugSelectedTabID)
            controller.debugSplitFocusedPane(along: .horizontal)
            let firstTabPaneIDs = controller.debugPaneIDsInTraversalOrder
            let backgroundExitedPaneID = firstTabPaneIDs[1]

            controller.debugNewTab()
            let selectedTabID = try XCTUnwrap(controller.debugSelectedTabID)

            controller.debugSimulatePaneExit(withID: backgroundExitedPaneID)

            XCTAssertEqual(controller.debugSelectedTabID, selectedTabID)
            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder(forTabID: firstTabID), [firstTabPaneIDs[0]])
            XCTAssertEqual(controller.debugLayoutNode(forTabID: firstTabID), .panel(firstTabPaneIDs[0]))
        }
    }

    func testRootViewSeparatesContentAndTabStripFrames() async throws {
        try await MainActor.run {
            let controller = Self.makeController()

            let contentFrame = controller.debugContentFrame
            let tabStripFrame = controller.debugTabStripFrame

            XCTAssertEqual(tabStripFrame.height, WorkspaceLayoutMetrics.tabStripHeight, accuracy: 0.0001)
            XCTAssertEqual(tabStripFrame.minY, WorkspaceLayoutMetrics.workspaceEdgePadding, accuracy: 0.0001)
            XCTAssertEqual(contentFrame.maxY, controller.view.bounds.height - WorkspaceLayoutMetrics.workspaceEdgePadding, accuracy: 0.0001)
            XCTAssertGreaterThan(contentFrame.minY, tabStripFrame.maxY)
            XCTAssertEqual(controller.debugRenderedContentFrame, contentFrame)
            XCTAssertGreaterThan(controller.debugRenderedContentFrame.width, 0)
            XCTAssertGreaterThan(controller.debugRenderedContentFrame.height, 0)
        }
    }

    func testAgentStatusBadgeStaysInsideButtonTrailingEdge() async throws {
        try await MainActor.run {
            let button = WorkspaceStatusButtonView(
                frame: NSRect(x: 0, y: 0, width: 98, height: 32)
            )

            button.title = "Agents"
            button.symbolName = "sparkles"
            button.badgeText = "3"

            XCTAssertLessThanOrEqual(button.debugBadgeFrame.maxX, button.bounds.maxX)
        }
    }

    func testAccentColorAppliesToFocusedPaneAndSelectedTab() async throws {
        try await MainActor.run {
            AppAppearanceSettings.resetAccentColor()
            AppAppearanceSettings.resetActiveTabBackground()
            AppAppearanceSettings.resetWindowHidden()
            AppAppearanceSettings.resetActivePaneBorderWidth()
            let controller = Self.makeController()
            let focusedPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            let selectedTabID = try XCTUnwrap(controller.debugSelectedTabID)
            let accentColor = NSColor(
                red: CGFloat(0x4D) / 255,
                green: CGFloat(0x99) / 255,
                blue: CGFloat(0xE6) / 255,
                alpha: 1
            )

            AppAppearanceSettings.accentColor = accentColor

            assertColorEqual(
                try XCTUnwrap(controller.debugPaneBorderColor(for: focusedPaneID)),
                accentColor,
                accuracy: 0.001
            )
            assertColorEqual(
                try XCTUnwrap(controller.debugSelectedTabBackgroundColor(for: selectedTabID)),
                accentColor.withAlphaComponent(0.9),
                accuracy: 0.002
            )
            AppAppearanceSettings.resetAccentColor()
            AppAppearanceSettings.resetActiveTabBackground()
            AppAppearanceSettings.resetWindowHidden()
            AppAppearanceSettings.resetActivePaneBorderWidth()
        }
    }

    func testActivePaneBorderWidthAppliesToFocusedPane() async throws {
        try await MainActor.run {
            AppAppearanceSettings.resetActivePaneBorderWidth()
            let controller = Self.makeController()
            let focusedPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            AppAppearanceSettings.activePaneBorderWidth = 6

            XCTAssertEqual(controller.debugPaneBorderWidth(for: focusedPaneID), 6)
            AppAppearanceSettings.resetActivePaneBorderWidth()
        }
    }

    func testActiveTabBackgroundSettingOverridesAccentColor() async throws {
        try await MainActor.run {
            AppAppearanceSettings.resetAccentColor()
            AppAppearanceSettings.resetActiveTabBackground()
            let controller = Self.makeController()
            let selectedTabID = try XCTUnwrap(controller.debugSelectedTabID)
            let activeTabColor = NSColor(
                red: CGFloat(0xCC) / 255,
                green: CGFloat(0x66) / 255,
                blue: CGFloat(0x33) / 255,
                alpha: CGFloat(0xE6) / 255
            )

            AppAppearanceSettings.activeTabBackground = .solid(activeTabColor)

            assertColorEqual(
                try XCTUnwrap(controller.debugSelectedTabBackgroundColor(for: selectedTabID)),
                activeTabColor,
                accuracy: 0.002
            )
            AppAppearanceSettings.resetAccentColor()
            AppAppearanceSettings.resetActiveTabBackground()
        }
    }

    func testActiveTabGradientBackgroundAppliesToSelectedTab() async throws {
        try await MainActor.run {
            AppAppearanceSettings.resetActiveTabBackground()
            let controller = Self.makeController()
            let selectedTabID = try XCTUnwrap(controller.debugSelectedTabID)
            let startColor = NSColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 0.85)
            let endColor = NSColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 0.9)

            AppAppearanceSettings.activeTabBackground = .gradient(startColor, endColor)

            guard case let .gradient(actualStartColor, actualEndColor) =
                try XCTUnwrap(controller.debugSelectedTabBackground(for: selectedTabID))
            else {
                return XCTFail("Expected a gradient active tab background")
            }
            assertColorEqual(actualStartColor, startColor, accuracy: 0.002)
            assertColorEqual(actualEndColor, endColor, accuracy: 0.002)
            AppAppearanceSettings.resetActiveTabBackground()
        }
    }

    func testHideWindowSettingControlsPaneAndTabVibrancy() async throws {
        try await MainActor.run {
            AppAppearanceSettings.resetWindowHidden()
            let controller = Self.makeController()
            let focusedPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            let selectedTabID = try XCTUnwrap(controller.debugSelectedTabID)

            XCTAssertEqual(controller.debugPaneUsesHiddenWindowPresentation(for: focusedPaneID), false)
            XCTAssertEqual(controller.debugTabUsesHiddenWindowPresentation(for: selectedTabID), false)

            AppAppearanceSettings.isWindowHidden = true

            XCTAssertEqual(controller.debugPaneUsesHiddenWindowPresentation(for: focusedPaneID), true)
            XCTAssertEqual(controller.debugTabUsesHiddenWindowPresentation(for: selectedTabID), true)

            AppAppearanceSettings.resetWindowHidden()
        }
    }

    func testTerminalPaddingSettingControlsTerminalFrame() async throws {
        try await MainActor.run {
            TerminalSettings.resetPadding()
            let controller = Self.makeController()
            let focusedPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            TerminalSettings.padding = 18
            controller.view.layoutSubtreeIfNeeded()

            let paneBounds = try XCTUnwrap(controller.debugPaneBounds(for: focusedPaneID))
            let terminalFrame = try XCTUnwrap(controller.debugTerminalFrame(for: focusedPaneID))

            XCTAssertEqual(controller.debugTerminalPadding(for: focusedPaneID), 18)
            XCTAssertEqual(terminalFrame.minX, 18, accuracy: 0.0001)
            XCTAssertEqual(terminalFrame.minY, 18, accuracy: 0.0001)
            XCTAssertEqual(terminalFrame.width, paneBounds.width - 36, accuracy: 0.0001)
            XCTAssertEqual(terminalFrame.height, paneBounds.height - 36, accuracy: 0.0001)
            TerminalSettings.resetPadding()
        }
    }

    func testFocusSwitchRestoresPreviousSplitAndAppliesNextAutoZoom() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let secondPaneID = try XCTUnwrap(controller.debugPaneIDsInTraversalOrder.last)
            Self.enableAutoResize(for: firstPaneID, in: controller)
            Self.enableAutoResize(for: secondPaneID, in: controller)
            controller.debugFocusPane(withID: firstPaneID)
            controller.debugFocusPane(withID: secondPaneID)

            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.3, 0.7], accuracy: 0.0001)
            XCTAssertEqual(controller.debugActiveAutoZoomState?.focusedPaneID, secondPaneID)

            controller.debugFocusPane(withID: firstPaneID)

            XCTAssertEqual(controller.debugFocusedPaneID, firstPaneID)
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.7, 0.3], accuracy: 0.0001)
            XCTAssertEqual(controller.debugActiveAutoZoomState?.focusedPaneID, firstPaneID)
            assertFractionsEqual(try XCTUnwrap(controller.debugActiveAutoZoomState?.originalFractions), [0.5, 0.5], accuracy: 0.0001)
        }
    }

    func testFocusingSamePaneDoesNotCreateNewAutoZoomState() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            controller.debugSplitFocusedPane(along: .horizontal)
            let focusedPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            Self.enableAutoResize(for: focusedPaneID, in: controller)
            controller.debugFocusPane(withID: try XCTUnwrap(controller.debugPaneIDsInTraversalOrder.first))
            controller.debugFocusPane(withID: focusedPaneID)
            let initialState = controller.debugActiveAutoZoomState

            controller.debugFocusPane(withID: focusedPaneID)

            XCTAssertEqual(controller.debugActiveAutoZoomState, initialState)
        }
    }

    func testDisabledPaneAutoResizeSkipsAutoZoom() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .vertical)
            controller.debugSetPaneAutoResizeConfiguration(
                PaneAutoResizeConfiguration(
                    isEnabled: false,
                    ratios: PaneFocusRatios(horizontal: 0.7, vertical: 0.7)
                ),
                for: firstPaneID
            )
            controller.debugFocusPane(withID: firstPaneID)

            XCTAssertNil(controller.debugActiveAutoZoomState)
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.5, 0.5], accuracy: 0.0001)
        }
    }

    func testPaneAutoResizeUsesSeparateHorizontalAndVerticalRatios() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .vertical)
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.5, 0.5], accuracy: 0.0001)

            controller.debugSetPaneAutoResizeConfiguration(
                PaneAutoResizeConfiguration(
                    isEnabled: true,
                    ratios: PaneFocusRatios(horizontal: 0.65, vertical: 0.8)
                ),
                for: firstPaneID
            )
            controller.debugFocusPane(withID: firstPaneID)

            XCTAssertEqual(controller.debugFocusedPaneID, firstPaneID)
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.7831978320, 0.2168021680], accuracy: 0.0001)
            XCTAssertEqual(controller.debugActiveAutoZoomState?.focusedPaneID, firstPaneID)
        }
    }

    func testNestedFocusedPaneAutoResizeAppliesHorizontalAndVerticalAncestors() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let leftPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let topRightPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            Self.enableAutoResize(for: topRightPaneID, in: controller)

            controller.debugSplitFocusedPane(along: .vertical)
            let bottomRightPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugFocusPane(withID: topRightPaneID)

            XCTAssertEqual(
                controller.debugPaneIDsInTraversalOrder,
                [leftPaneID, topRightPaneID, bottomRightPaneID]
            )
            assertFractionsEqual(
                try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])),
                [0.3, 0.7],
                accuracy: 0.0001
            )
            assertFractionsEqual(
                try XCTUnwrap(controller.debugRenderedSplitFractions(at: [.child(1)])),
                [0.7, 0.3],
                accuracy: 0.0001
            )
            XCTAssertEqual(controller.debugActiveAutoZoomState?.focusedPaneID, topRightPaneID)
        }
    }

    func testSameAxisSecondSplitKeepsSingleThreePaneRoot() async throws {
        try await MainActor.run {
            let controller = Self.makeController()

            controller.debugSplitFocusedPane(along: .horizontal)
            controller.debugSplitFocusedPane(along: .horizontal)

            let paneIDs = controller.debugPaneIDsInTraversalOrder
            XCTAssertEqual(paneIDs.count, 3)
            guard case let .split(axis, children, fractions) = try XCTUnwrap(controller.debugLayoutNode) else {
                return XCTFail("Expected a horizontal three-pane root split")
            }

            XCTAssertEqual(axis, .horizontal)
            XCTAssertEqual(children, paneIDs.map(LayoutNode.panel))
            assertFractionsEqual(fractions, [0.5, 0.25, 0.25], accuracy: 0.0001)
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.5, 0.25, 0.25], accuracy: 0.0001)
            XCTAssertNil(controller.debugActiveAutoZoomState)
        }
    }

    func testDirectionalPaneFocusUsesRenderedPanePositions() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let topLeftPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let topRightPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugSplitFocusedPane(along: .vertical)
            let bottomRightPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugFocusPane(withID: topLeftPaneID)
            controller.debugSplitFocusedPane(along: .vertical)
            let bottomLeftPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugFocusPane(withID: topRightPaneID)
            controller.debugFocusPane(in: .left)
            XCTAssertEqual(controller.debugFocusedPaneID, topLeftPaneID)

            controller.debugFocusPane(withID: bottomRightPaneID)
            controller.debugFocusPane(in: .left)
            XCTAssertEqual(controller.debugFocusedPaneID, bottomLeftPaneID)

            controller.debugFocusPane(withID: topLeftPaneID)
            controller.debugFocusPane(in: .right)
            XCTAssertEqual(controller.debugFocusedPaneID, topRightPaneID)

            controller.debugFocusPane(withID: bottomLeftPaneID)
            controller.debugFocusPane(in: .right)
            XCTAssertEqual(controller.debugFocusedPaneID, bottomRightPaneID)

            controller.debugFocusPane(withID: topRightPaneID)
            controller.debugFocusPane(in: .below)
            XCTAssertEqual(controller.debugFocusedPaneID, bottomRightPaneID)

            controller.debugFocusPane(in: .above)
            XCTAssertEqual(controller.debugFocusedPaneID, topRightPaneID)
        }
    }

    func testDirectionalPaneFocusUsesRecencyForAmbiguousPositionMatch() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let leftPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let topRightPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugSplitFocusedPane(along: .vertical)
            let bottomRightPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugFocusPane(withID: leftPaneID)
            controller.debugFocusPane(in: .right)
            XCTAssertEqual(controller.debugFocusedPaneID, bottomRightPaneID)

            controller.debugFocusPane(withID: topRightPaneID)
            controller.debugFocusPane(withID: leftPaneID)
            controller.debugFocusPane(in: .right)
            XCTAssertEqual(controller.debugFocusedPaneID, topRightPaneID)
        }
    }

    func testMovePaneCommandSwapsFocusedPaneWithDirectionalTargetAndKeepsFocus() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let topLeftPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let topRightPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugSplitFocusedPane(along: .vertical)
            let bottomRightPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugFocusPane(withID: topLeftPaneID)
            controller.debugSplitFocusedPane(along: .vertical)
            let bottomLeftPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugFocusPane(withID: bottomRightPaneID)
            controller.debugPerformCommand(withID: "pane.move.left")

            XCTAssertEqual(controller.debugFocusedPaneID, bottomRightPaneID)
            XCTAssertEqual(
                controller.debugPaneIDsInTraversalOrder,
                [topLeftPaneID, bottomRightPaneID, topRightPaneID, bottomLeftPaneID]
            )
        }
    }

    func testMovePaneReappliesFocusedPaneAutoResizeAfterSwap() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let secondPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            Self.enableAutoResize(for: secondPaneID, in: controller)
            controller.debugFocusPane(withID: firstPaneID)
            controller.debugFocusPane(withID: secondPaneID)

            assertFractionsEqual(
                try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])),
                [0.3, 0.7],
                accuracy: 0.0001
            )

            controller.debugPerformCommand(withID: "pane.move.left")

            XCTAssertEqual(controller.debugFocusedPaneID, secondPaneID)
            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder, [secondPaneID, firstPaneID])
            XCTAssertEqual(controller.debugActiveAutoZoomState?.focusedPaneID, secondPaneID)
            assertFractionsEqual(
                try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])),
                [0.7, 0.3],
                accuracy: 0.0001
            )
        }
    }

    func testMenuKeyEquivalentPerformsMovePaneActionThroughWorkspaceTarget() async throws {
        try await MainActor.run {
            try Self.withRestoredKeybindingUserDefaults {
                KeybindingAction.allCases.forEach(KeybindingSettings.resetShortcut)

                let controller = Self.makeController()
                let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
                controller.debugSplitFocusedPane(along: .horizontal)
                let secondPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

                let previousMainMenu = NSApp.mainMenu
                defer {
                    NSApp.mainMenu = previousMainMenu
                }

                let appTarget = AppMenuTestTarget()
                AppMenu.install(
                    applicationTarget: appTarget,
                    workspaceTarget: controller,
                    commandPaletteAction: #selector(AppMenuTestTarget.handleCommandPalette(_:)),
                    checkForUpdatesAction: #selector(AppMenuTestTarget.handleCheckForUpdates(_:)),
                    settingsAction: #selector(AppMenuTestTarget.handleSettings(_:))
                )

                let event = try XCTUnwrap(NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [.option, .command],
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    characters: "h",
                    charactersIgnoringModifiers: "h",
                    isARepeat: false,
                    keyCode: UInt16(KeyboardShortcuts.Key.h.rawValue)
                ))

                XCTAssertTrue(AppMenuKeyEquivalents.perform(event, in: NSApp.mainMenu))
                XCTAssertEqual(controller.debugFocusedPaneID, secondPaneID)
                XCTAssertEqual(controller.debugPaneIDsInTraversalOrder, [secondPaneID, firstPaneID])
            }
        }
    }

    func testOptionCommandMovePaneShortcutPerformsDirectWorkspaceKeybinding() async throws {
        try await MainActor.run {
            try Self.withRestoredKeybindingUserDefaults {
                KeybindingAction.allCases.forEach(KeybindingSettings.resetShortcut)

                let controller = Self.makeController()
                let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
                controller.debugSplitFocusedPane(along: .horizontal)
                let secondPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

                let event = try XCTUnwrap(NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [.option, .command],
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    characters: "h",
                    charactersIgnoringModifiers: "h",
                    isARepeat: false,
                    keyCode: UInt16(KeyboardShortcuts.Key.h.rawValue)
                ))
                let action = try XCTUnwrap(KeybindingSettings.action(matching: event))

                XCTAssertEqual(action, .movePaneLeft)
                XCTAssertTrue(controller.performKeybindingAction(action))
                XCTAssertEqual(controller.debugFocusedPaneID, secondPaneID)
                XCTAssertEqual(controller.debugPaneIDsInTraversalOrder, [secondPaneID, firstPaneID])
            }
        }
    }

    func testAutoZoomOnThreePaneSplitGrowsFocusedPaneToAbsoluteShare() async throws {
        try await MainActor.run {
            let controller = Self.makeController()

            controller.debugSplitFocusedPane(along: .horizontal)
            controller.debugSplitFocusedPane(along: .horizontal)
            let paneIDs = controller.debugPaneIDsInTraversalOrder
            let middlePaneID = paneIDs[1]
            Self.enableAutoResize(for: middlePaneID, in: controller)

            controller.debugFocusPane(withID: middlePaneID)

            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.2047781570, 0.5904436860, 0.2047781570], accuracy: 0.0001)
            XCTAssertEqual(controller.debugActiveAutoZoomState?.focusedPaneID, middlePaneID)
            assertFractionsEqual(try XCTUnwrap(controller.debugActiveAutoZoomState?.originalFractions), [0.5, 0.25, 0.25], accuracy: 0.0001)
        }
    }

    func testClosingFocusedPaneReappliesAutoZoomToPromotedPane() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            controller.debugSplitFocusedPane(along: .horizontal)
            let focusedPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            let paneIDsBeforeClose = controller.debugPaneIDsInTraversalOrder
            Self.enableAutoResize(for: paneIDsBeforeClose[1], in: controller)

            controller.debugPerformClosePane(withID: focusedPaneID)

            let paneIDs = controller.debugPaneIDsInTraversalOrder
            XCTAssertEqual(controller.debugFocusedPaneID, paneIDs[1])
            guard case let .split(axis, children, fractions) = try XCTUnwrap(controller.debugLayoutNode) else {
                return XCTFail("Expected a two-pane split after closing the focused pane")
            }

            XCTAssertEqual(axis, .horizontal)
            XCTAssertEqual(children, paneIDs.map(LayoutNode.panel))
            assertFractionsEqual(fractions, [0.6666666667, 0.3333333333], accuracy: 0.0001)
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.3, 0.7], accuracy: 0.0001)
            XCTAssertEqual(controller.debugActiveAutoZoomState?.focusedPaneID, paneIDs[1])
        }
    }

    func testDraggingActiveAutoZoomSplitDisablesAffectedPaneAutoResize() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let secondPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            Self.enableAutoResize(for: firstPaneID, in: controller)
            Self.enableAutoResize(for: secondPaneID, in: controller)
            controller.debugFocusPane(withID: firstPaneID)
            controller.debugFocusPane(withID: secondPaneID)

            controller.debugUpdateSplitFractions(at: [], to: [0.42, 0.58])

            XCTAssertNil(controller.debugActiveAutoZoomState)
            XCTAssertEqual(controller.debugPaneAutoResizeConfiguration(for: firstPaneID)?.isEnabled, false)
            XCTAssertEqual(controller.debugPaneAutoResizeConfiguration(for: secondPaneID)?.isEnabled, false)
            XCTAssertEqual(
                controller.debugLayoutNode?.node(at: []),
                .split(
                    axis: .horizontal,
                    children: [.panel(firstPaneID), .panel(secondPaneID)],
                    fractions: [0.42, 0.58]
                )
            )

            controller.debugFocusPane(withID: firstPaneID)

            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.42, 0.58], accuracy: 0.0001)
            XCTAssertNil(controller.debugActiveAutoZoomState)
        }
    }

    func testToggleFloatingPaneKeepsLayoutAndCentersFocusedPane() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let floatingPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            let layoutBeforeFloating = controller.debugLayoutNode

            controller.debugToggleFloatingPane()

            XCTAssertEqual(controller.debugActiveFloatingPaneState?.paneID, floatingPaneID)
            XCTAssertEqual(controller.debugFocusedPaneID, floatingPaneID)
            XCTAssertEqual(controller.debugLayoutNode, layoutBeforeFloating)
            XCTAssertNotNil(controller.debugPlaceholderFrame(for: floatingPaneID))

            let contentFrame = controller.debugContentFrame
            let floatingFrame = try XCTUnwrap(controller.debugFloatingPaneFrame)
            XCTAssertEqual(floatingFrame.width, contentFrame.width * 0.8, accuracy: 0.0001)
            XCTAssertEqual(floatingFrame.height, contentFrame.height * 0.9, accuracy: 0.0001)
            XCTAssertEqual(floatingFrame.midX, contentFrame.midX, accuracy: 0.0001)
            XCTAssertEqual(floatingFrame.midY, contentFrame.midY, accuracy: 0.0001)

            controller.debugToggleFloatingPane()

            XCTAssertNil(controller.debugActiveFloatingPaneState)
            XCTAssertNil(controller.debugFloatingPaneFrame)
            XCTAssertNil(controller.debugPlaceholderFrame(for: floatingPaneID))
            XCTAssertEqual(controller.debugLayoutNode, layoutBeforeFloating)
            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder, [firstPaneID, floatingPaneID])
        }
    }

    func testFocusRequestFromFloatingPaneKeepsItFloating() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let floatingPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugToggleFloatingPane()
            XCTAssertEqual(controller.debugActiveFloatingPaneState?.paneID, floatingPaneID)

            controller.debugHandlePaneFocusRequest(withID: floatingPaneID)

            XCTAssertEqual(controller.debugActiveFloatingPaneState?.paneID, floatingPaneID)
            XCTAssertEqual(controller.debugFocusedPaneID, floatingPaneID)

            controller.debugHandlePaneFocusRequest(withID: firstPaneID)

            XCTAssertNil(controller.debugActiveFloatingPaneState)
        }
    }

    func testFloatingPaneStaysFloatingAcrossTabSwitch() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstTabID = try XCTUnwrap(controller.debugSelectedTabID)
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let floatingPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugToggleFloatingPane()
            let floatingFrame = try XCTUnwrap(controller.debugFloatingPaneFrame)

            controller.debugNewTab()

            XCTAssertNotEqual(controller.debugSelectedTabID, firstTabID)
            XCTAssertNil(controller.debugActiveFloatingPaneState)
            XCTAssertNil(controller.debugFloatingPaneFrame)

            controller.debugSelectTab(withID: firstTabID)

            XCTAssertEqual(controller.debugActiveFloatingPaneState?.paneID, floatingPaneID)
            XCTAssertEqual(controller.debugFocusedPaneID, floatingPaneID)
            XCTAssertNotNil(controller.debugPlaceholderFrame(for: floatingPaneID))
            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder, [firstPaneID, floatingPaneID])
            assertRectsEqual(
                try XCTUnwrap(controller.debugFloatingPaneFrame),
                floatingFrame,
                accuracy: 0.0001
            )
        }
    }

    func testAnimatedFloatingPaneStartsFromRestoredVerticalSplitFrame() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let floatingPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .vertical)
            Self.enableAutoResize(for: floatingPaneID, in: controller)
            controller.debugFocusPane(withID: floatingPaneID)
            XCTAssertEqual(controller.debugActiveAutoZoomState?.focusedPaneID, floatingPaneID)

            controller.debugToggleFloatingPane(animated: true)

            let initialFrame = try XCTUnwrap(controller.debugLastFloatingPaneInitialFrame)
            let restoredPlaceholderFrame = try XCTUnwrap(controller.debugPlaceholderFrame(for: floatingPaneID))
            assertRectsEqual(initialFrame, restoredPlaceholderFrame, accuracy: 0.0001)

            controller.debugToggleFloatingPane(animated: false)
        }
    }

    func testAnimatedFloatingPaneStartsFromRightNestedSplitFrame() async throws {
        try await MainActor.run {
            let controller = Self.makeController()

            controller.debugSplitFocusedPane(along: .horizontal)
            controller.debugSplitFocusedPane(along: .vertical)
            let floatingPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugToggleFloatingPane(animated: true)

            let initialFrame = try XCTUnwrap(controller.debugLastFloatingPaneInitialFrame)
            let placeholderFrame = try XCTUnwrap(controller.debugPlaceholderFrame(for: floatingPaneID))
            XCTAssertGreaterThan(initialFrame.minX, controller.debugContentFrame.midX)
            assertRectsEqual(initialFrame, placeholderFrame, accuracy: 0.0001)

            controller.debugToggleFloatingPane(animated: false)
        }
    }

    func testAnimatedFloatingPaneStartsFromRightNestedSplitFrameInWindowCoordinates() async throws {
        try await MainActor.run {
            let controller = WorkspaceViewController()
            let window = NSWindow(contentRect: NSRect(x: 120, y: 80, width: 1200, height: 800), styleMask: [], backing: .buffered, defer: false)
            window.contentViewController = controller
            controller.debugLoadForTesting()

            controller.debugSplitFocusedPane(along: .horizontal)
            controller.debugSplitFocusedPane(along: .vertical)
            let floatingPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugToggleFloatingPane(animated: true)

            let initialFrame = try XCTUnwrap(controller.debugLastFloatingPaneInitialFrame)
            let placeholderFrame = try XCTUnwrap(controller.debugPlaceholderFrame(for: floatingPaneID))
            XCTAssertGreaterThan(initialFrame.minX, controller.debugContentFrame.midX)
            assertRectsEqual(initialFrame, placeholderFrame, accuracy: 0.0001)

            controller.debugToggleFloatingPane(animated: false)
            window.contentViewController = nil
        }
    }

    func testFloatingPaneShowsVibrancyWhenWindowIsNotHidden() async throws {
        try await MainActor.run {
            AppAppearanceSettings.resetWindowHidden()
            let controller = Self.makeController()
            let paneID = try XCTUnwrap(controller.debugFocusedPaneID)

            XCTAssertEqual(controller.debugPaneUsesHiddenWindowPresentation(for: paneID), false)

            controller.debugToggleFloatingPane()

            XCTAssertEqual(controller.debugActiveFloatingPaneState?.paneID, paneID)
            XCTAssertEqual(controller.debugPaneUsesHiddenWindowPresentation(for: paneID), true)
            XCTAssertEqual(
                controller.debugPaneVibrancyBlendingMode(for: paneID),
                AppAppearanceDefaults.floatingPaneVibrancyBlendingMode
            )
            XCTAssertEqual(
                try XCTUnwrap(controller.debugPaneVibrancyTintAlpha(for: paneID)),
                AppAppearanceDefaults.floatingPaneVibrancyTintAlpha,
                accuracy: 0.001
            )

            controller.debugToggleFloatingPane()
            XCTAssertEqual(
                controller.debugPaneVibrancyBlendingMode(for: paneID),
                AppAppearanceDefaults.vibrancyBlendingMode
            )
            XCTAssertEqual(
                try XCTUnwrap(controller.debugPaneVibrancyTintAlpha(for: paneID)),
                AppAppearanceDefaults.vibrancyTintAlpha,
                accuracy: 0.001
            )
            AppAppearanceSettings.resetWindowHidden()
        }
    }

    func testFloatingPanePlaceholderShowsVibrancyOnlyWhenWindowIsHidden() async throws {
        try await MainActor.run {
            AppAppearanceSettings.resetWindowHidden()
            let controller = Self.makeController()
            let paneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugToggleFloatingPane()

            XCTAssertEqual(
                controller.debugPlaceholderUsesHiddenWindowPresentation(for: paneID),
                false
            )
            XCTAssertEqual(
                controller.debugPlaceholderVibrancyBlendingMode(for: paneID),
                AppAppearanceDefaults.vibrancyBlendingMode
            )
            XCTAssertEqual(
                try XCTUnwrap(controller.debugPlaceholderVibrancyTintAlpha(for: paneID)),
                AppAppearanceDefaults.vibrancyTintAlpha,
                accuracy: 0.001
            )

            AppAppearanceSettings.isWindowHidden = true

            XCTAssertEqual(
                controller.debugPlaceholderUsesHiddenWindowPresentation(for: paneID),
                true
            )
            XCTAssertEqual(
                controller.debugPlaceholderVibrancyBlendingMode(for: paneID),
                AppAppearanceDefaults.vibrancyBlendingMode
            )
            XCTAssertEqual(
                try XCTUnwrap(controller.debugPlaceholderVibrancyTintAlpha(for: paneID)),
                AppAppearanceDefaults.vibrancyTintAlpha,
                accuracy: 0.001
            )

            AppAppearanceSettings.resetWindowHidden()
        }
    }

    func testPaneFocusSwitchExitsFloatingBeforeChangingFocus() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugSplitFocusedPane(along: .horizontal)
            let secondPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugToggleFloatingPane()
            controller.debugFocusPane(withID: firstPaneID)

            XCTAssertNil(controller.debugActiveFloatingPaneState)
            XCTAssertNil(controller.debugFloatingPaneFrame)
            XCTAssertEqual(controller.debugFocusedPaneID, firstPaneID)
            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder, [firstPaneID, secondPaneID])
        }
    }

    func testFloatingPaneHitTestingKeepsInsideClicksAndPassesThroughOutsideClicks() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugSplitFocusedPane(along: .horizontal)
            let floatingPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugToggleFloatingPane()
            XCTAssertEqual(controller.debugActiveFloatingPaneState?.paneID, floatingPaneID)
            XCTAssertEqual(controller.debugFocusedPaneID, floatingPaneID)

            let contentFrame = controller.debugContentFrame
            let floatingFrame = try XCTUnwrap(controller.debugFloatingPaneFrame)
            let insidePoint = NSPoint(
                x: floatingFrame.minX + 1,
                y: floatingFrame.midY
            )
            let topInsidePoint = NSPoint(
                x: floatingFrame.midX,
                y: floatingFrame.maxY - 1
            )
            let bottomInsidePoint = NSPoint(
                x: floatingFrame.midX,
                y: floatingFrame.minY + 1
            )
            let outsidePoint = NSPoint(
                x: contentFrame.minX + 1,
                y: floatingFrame.midY
            )
            let abovePoint = NSPoint(
                x: floatingFrame.minX + 1,
                y: min(contentFrame.maxY - 1, floatingFrame.maxY + 1)
            )

            XCTAssertTrue(floatingFrame.contains(insidePoint))
            XCTAssertTrue(floatingFrame.contains(topInsidePoint))
            XCTAssertTrue(floatingFrame.contains(bottomInsidePoint))
            XCTAssertFalse(floatingFrame.contains(outsidePoint))
            XCTAssertEqual(controller.debugFocusedPaneID, floatingPaneID)

            controller.debugClickWorkspace(at: insidePoint)

            XCTAssertEqual(controller.debugActiveFloatingPaneState?.paneID, floatingPaneID)
            XCTAssertEqual(controller.debugFocusedPaneID, floatingPaneID)
            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder, [firstPaneID, floatingPaneID])
            XCTAssertNotNil(controller.debugFloatingPaneFrame)

            controller.debugClickWorkspace(at: topInsidePoint)

            XCTAssertEqual(controller.debugActiveFloatingPaneState?.paneID, floatingPaneID)
            XCTAssertEqual(controller.debugFocusedPaneID, floatingPaneID)

            controller.debugClickWorkspace(at: bottomInsidePoint)

            XCTAssertEqual(controller.debugActiveFloatingPaneState?.paneID, floatingPaneID)
            XCTAssertEqual(controller.debugFocusedPaneID, floatingPaneID)

            controller.debugClickWorkspace(at: abovePoint)

            XCTAssertNil(controller.debugActiveFloatingPaneState)
            XCTAssertEqual(controller.debugFocusedPaneID, firstPaneID)

            XCTAssertFalse(floatingFrame.contains(outsidePoint))
        }
    }

    func testClickBelowFloatingPanePassesThroughToBackgroundPane() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            controller.debugSplitFocusedPane(along: .horizontal)
            let floatingPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugToggleFloatingPane()

            let contentFrame = controller.debugContentFrame
            let floatingFrame = try XCTUnwrap(controller.debugFloatingPaneFrame)
            let belowPoint = NSPoint(
                x: floatingFrame.minX + 1,
                y: max(contentFrame.minY + 1, floatingFrame.minY - 1)
            )

            XCTAssertFalse(floatingFrame.contains(belowPoint))
            XCTAssertFalse(controller.debugHitIsInsideFloatingPane(at: belowPoint))
            XCTAssertEqual(controller.debugFocusedPaneID, floatingPaneID)
            XCTAssertEqual(controller.debugActiveFloatingPaneState?.paneID, floatingPaneID)
        }
    }

    func testFloatingPanePreservesAutoResizePlaceholderAndExitLayout() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            Self.enableAutoResize(for: firstPaneID, in: controller)
            controller.debugFocusPane(withID: firstPaneID)
            XCTAssertEqual(controller.debugActiveAutoZoomState?.focusedPaneID, firstPaneID)
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.7, 0.3], accuracy: 0.0001)

            controller.debugToggleFloatingPane()

            XCTAssertEqual(controller.debugActiveAutoZoomState?.focusedPaneID, firstPaneID)
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.7, 0.3], accuracy: 0.0001)
            XCTAssertEqual(controller.debugActiveFloatingPaneState?.paneID, firstPaneID)

            controller.debugToggleFloatingPane()

            XCTAssertNil(controller.debugActiveFloatingPaneState)
            XCTAssertEqual(controller.debugActiveAutoZoomState?.focusedPaneID, firstPaneID)
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.7, 0.3], accuracy: 0.0001)
        }
    }

    func testClosingFloatingPaneClearsFloatingState() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let floatingPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugToggleFloatingPane()

            controller.debugPerformClosePane(withID: floatingPaneID)

            XCTAssertNil(controller.debugActiveFloatingPaneState)
            XCTAssertNil(controller.debugFloatingPaneFrame)
            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder, [firstPaneID])
            XCTAssertEqual(controller.debugFocusedPaneID, firstPaneID)
        }
    }

    func testDetachingPaneRemovesItFromLayoutAndAddsStatusCell() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let detachedPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugDetachFocusedPane()

            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder, [firstPaneID])
            XCTAssertEqual(controller.debugDetachedPaneIDs, [detachedPaneID])
            XCTAssertNil(controller.debugActiveDetachedPaneID)
            XCTAssertEqual(controller.debugFocusedPaneID, firstPaneID)
            XCTAssertNotNil(controller.debugDetachedPaneStatusCellFrame(for: detachedPaneID))
            XCTAssertEqual(controller.debugDetachedPaneStatusCellIsActive(for: detachedPaneID), false)
        }
    }

    func testDetachedPaneToggleShowsAndHidesFloatingPane() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let detachedPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugDetachFocusedPane()

            controller.debugToggleDetachedPane(at: 0)

            XCTAssertEqual(controller.debugActiveDetachedPaneID, detachedPaneID)
            XCTAssertEqual(controller.debugFocusedPaneID, detachedPaneID)
            XCTAssertNotNil(controller.debugFloatingPaneFrame)
            XCTAssertEqual(controller.debugDetachedPaneStatusCellIsActive(for: detachedPaneID), true)
            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder, [firstPaneID])

            controller.debugToggleDetachedPane(at: 0)

            XCTAssertNil(controller.debugActiveDetachedPaneID)
            XCTAssertNil(controller.debugFloatingPaneFrame)
            XCTAssertEqual(controller.debugFocusedPaneID, firstPaneID)
            XCTAssertEqual(controller.debugDetachedPaneStatusCellIsActive(for: detachedPaneID), false)
        }
    }

    func testActiveDetachedPaneStaysVisibleAcrossTabSwitch() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstTabID = try XCTUnwrap(controller.debugSelectedTabID)
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let detachedPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugDetachFocusedPane()
            controller.debugToggleDetachedPane(at: 0)
            let floatingFrame = try XCTUnwrap(controller.debugFloatingPaneFrame)

            controller.debugNewTab()

            XCTAssertNotEqual(controller.debugSelectedTabID, firstTabID)
            XCTAssertNil(controller.debugActiveDetachedPaneID)
            XCTAssertNil(controller.debugFloatingPaneFrame)

            controller.debugSelectTab(withID: firstTabID)

            XCTAssertEqual(controller.debugActiveDetachedPaneID, detachedPaneID)
            XCTAssertEqual(controller.debugFocusedPaneID, detachedPaneID)
            XCTAssertEqual(controller.debugDetachedPaneIDs, [detachedPaneID])
            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder, [firstPaneID])
            XCTAssertEqual(controller.debugDetachedPaneStatusCellIsActive(for: detachedPaneID), true)
            assertRectsEqual(
                try XCTUnwrap(controller.debugFloatingPaneFrame),
                floatingFrame,
                accuracy: 0.0001
            )
        }
    }

    func testToggleFloatingPaneHidesActiveDetachedPane() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let detachedPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugDetachFocusedPane()
            controller.debugToggleDetachedPane(at: 0)

            XCTAssertEqual(controller.debugActiveDetachedPaneID, detachedPaneID)
            XCTAssertEqual(controller.debugFocusedPaneID, detachedPaneID)
            XCTAssertNotNil(controller.debugFloatingPaneFrame)

            controller.debugToggleFloatingPane()

            XCTAssertNil(controller.debugActiveDetachedPaneID)
            XCTAssertNil(controller.debugFloatingPaneFrame)
            XCTAssertEqual(controller.debugFocusedPaneID, firstPaneID)
            XCTAssertEqual(controller.debugDetachedPaneIDs, [detachedPaneID])
            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder, [firstPaneID])
            XCTAssertEqual(controller.debugDetachedPaneStatusCellIsActive(for: detachedPaneID), false)
        }
    }

    func testDetachedPaneKeepsFloatingSizeAcrossHideAndShow() async throws {
        try await MainActor.run {
            let controller = Self.makeController()

            controller.debugSplitFocusedPane(along: .horizontal)
            controller.debugDetachFocusedPane()

            controller.debugToggleDetachedPane(at: 0)
            let firstFloatingFrame = try XCTUnwrap(controller.debugFloatingPaneFrame)

            controller.debugToggleDetachedPane(at: 0)
            controller.debugToggleDetachedPane(at: 0)

            let secondFloatingFrame = try XCTUnwrap(controller.debugFloatingPaneFrame)
            assertRectsEqual(secondFloatingFrame, firstFloatingFrame, accuracy: 0.0001)
        }
    }

    func testAttachingDetachedPaneReinsertsBesideFocusedTiledPane() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let detachedPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugDetachFocusedPane()
            controller.debugToggleDetachedPane(at: 0)

            controller.debugAttachFocusedDetachedPane()

            XCTAssertEqual(controller.debugDetachedPaneIDs, [])
            XCTAssertNil(controller.debugActiveDetachedPaneID)
            XCTAssertEqual(controller.debugFocusedPaneID, detachedPaneID)
            XCTAssertEqual(
                controller.debugLayoutNode,
                .split(
                    axis: .horizontal,
                    children: [.panel(firstPaneID), .panel(detachedPaneID)],
                    fractions: [0.5, 0.5]
                )
            )
        }
    }

    func testLastTiledPaneCanBeDetachedAndReattachedAsRoot() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let paneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugDetachFocusedPane()

            XCTAssertNil(controller.debugLayoutNode)
            XCTAssertEqual(controller.debugPaneIDsInTraversalOrder, [])
            XCTAssertEqual(controller.debugDetachedPaneIDs, [paneID])

            controller.debugToggleDetachedPane(at: 0)
            controller.debugAttachFocusedDetachedPane()

            XCTAssertEqual(controller.debugLayoutNode, .panel(paneID))
            XCTAssertEqual(controller.debugDetachedPaneIDs, [])
            XCTAssertEqual(controller.debugFocusedPaneID, paneID)
        }
    }

    func testCommandPaletteCommandListIncludesExistingWorkspaceActions() async throws {
        try await MainActor.run {
            try Self.withRestoredKeybindingUserDefaults {
                KeybindingAction.allCases.forEach(KeybindingSettings.resetShortcut)

                let controller = Self.makeController()

                XCTAssertEqual(
                    controller.debugCommandSnapshots.map(\.id),
                    [
                        "pane.split.horizontal",
                        "pane.split.vertical",
                        "pane.browser.new",
                        "pane.browser.location",
                        "pane.browser.convert",
                        "pane.terminal.convert",
                        "pane.resize.equalize",
                        "pane.resize.up",
                        "pane.resize.down",
                        "pane.resize.left",
                        "pane.resize.right",
                        "pane.focus.previous",
                        "pane.focus.next",
                        "pane.focus.left",
                        "pane.focus.right",
                        "pane.focus.above",
                        "pane.focus.below",
                        "pane.move.left",
                        "pane.move.right",
                        "pane.move.up",
                        "pane.move.down",
                        "pane.autoResize",
                        "pane.floating.toggle",
                        "pane.detach",
                        "pane.detached.attach",
                        "pane.promptEditor",
                        "pane.scrollMode.enter",
                        "pane.close",
                        "tab.new",
                        "tab.close",
                        "tab.title.change",
                        "tab.focus.previous",
                        "tab.focus.next",
                    ]
                )
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "tab.new" })?.shortcut, "⌘T")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.focus.previous" })?.shortcut, "⌘[")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.focus.next" })?.shortcut, "⌘]")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.focus.above" })?.shortcut, "⌘K")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.focus.below" })?.shortcut, "⌘J")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.resize.equalize" })?.shortcut, "⇧⌘=")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.resize.left" })?.shortcut, "⇧⌘H")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.move.left" })?.shortcut, "⌥⌘H")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.move.down" })?.shortcut, "⌥⌘J")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.move.up" })?.shortcut, "⌥⌘K")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.move.right" })?.shortcut, "⌥⌘L")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.floating.toggle" })?.shortcut, "⇧⌘F")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.move.left" })?.title, "Move Pane Left")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.floating.toggle" })?.title, "Toggle Floating Pane")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.detach" })?.title, "Detach Pane")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.detached.attach" })?.title, "Attach Detached Pane")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.promptEditor" })?.title, "Open Prompt Editor")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.scrollMode.enter" })?.title, "Enter Scroll Mode")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.scrollMode.enter" })?.shortcut, "⇧⌘S")
                XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.close" })?.title, "Close Pane")
            }
        }
    }

    func testCommandPaletteEnabledStatesFollowWorkspaceState() async throws {
        try await MainActor.run {
            let controller = Self.makeController()

            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.focus.next" })?.isEnabled, false)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.focus.left" })?.isEnabled, false)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.resize.equalize" })?.isEnabled, false)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.resize.left" })?.isEnabled, false)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.move.left" })?.isEnabled, false)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "tab.focus.next" })?.isEnabled, false)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.close" })?.isEnabled, true)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.floating.toggle" })?.isEnabled, true)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.detach" })?.isEnabled, true)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.detached.attach" })?.isEnabled, false)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.promptEditor" })?.isEnabled, true)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.scrollMode.enter" })?.isEnabled, true)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "tab.new" })?.isEnabled, true)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "tab.title.change" })?.isEnabled, true)

            controller.debugSplitFocusedPane(along: .horizontal)
            controller.debugNewTab()

            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "tab.focus.next" })?.isEnabled, true)
            controller.debugSelectTab(withID: try XCTUnwrap(controller.debugTabIDs.first))
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.focus.next" })?.isEnabled, true)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.focus.left" })?.isEnabled, true)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.resize.equalize" })?.isEnabled, true)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.resize.left" })?.isEnabled, true)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.move.left" })?.isEnabled, true)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.move.right" })?.isEnabled, false)

            controller.debugDetachFocusedPane()
            controller.debugToggleDetachedPane(at: 0)

            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.floating.toggle" })?.isEnabled, true)
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "pane.move.left" })?.isEnabled, false)
        }
    }

    func testScrollModeCommandEntersAndEscapeExitsMode() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let paneID = try XCTUnwrap(controller.debugFocusedPaneID)

            XCTAssertFalse(controller.debugFocusedPaneIsInScrollMode)
            XCTAssertEqual(controller.debugScrollModeIndicatorIsVisible(for: paneID), false)
            XCTAssertTrue(controller.performKeybindingAction(.enterScrollMode))
            XCTAssertTrue(controller.debugFocusedPaneIsInScrollMode)
            XCTAssertEqual(controller.debugScrollModeIndicatorIsVisible(for: paneID), true)
            let indicatorFrames = try XCTUnwrap(
                controller.debugScrollModeIndicatorFrames(for: paneID)
            )
            XCTAssertEqual(
                indicatorFrames.label.midX,
                indicatorFrames.background.midX,
                accuracy: 0.001
            )
            XCTAssertEqual(
                indicatorFrames.label.midY,
                indicatorFrames.background.midY,
                accuracy: 0.001
            )
            XCTAssertFalse(
                controller.debugCommandSnapshots.first(where: {
                    $0.id == "pane.scrollMode.enter"
                })?.isEnabled ?? true
            )

            let escape = try XCTUnwrap(Self.makeKeyEvent("\u{1b}", keyCode: 53))
            XCTAssertTrue(controller.debugHandleScrollModeKeyEvent(escape))
            XCTAssertFalse(controller.debugFocusedPaneIsInScrollMode)
            XCTAssertEqual(controller.debugScrollModeIndicatorIsVisible(for: paneID), false)
            XCTAssertFalse(controller.debugHandleScrollModeKeyEvent(escape))
        }
    }

    func testChangingFocusedPaneExitsScrollMode() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugSplitFocusedPane(along: .horizontal)
            let secondPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugPerformCommand(withID: "pane.scrollMode.enter")
            XCTAssertTrue(controller.debugFocusedPaneIsInScrollMode)

            controller.debugFocusPane(withID: firstPaneID)

            XCTAssertNotEqual(firstPaneID, secondPaneID)
            XCTAssertFalse(controller.debugFocusedPaneIsInScrollMode)
        }
    }

    func testScrollModeMapsVimKeysToNavigation() async throws {
        try await MainActor.run {
            func action(
                _ key: String,
                modifiers: NSEvent.ModifierFlags = [],
                keyCode: UInt16 = 0,
                awaitingSecondG: Bool = false
            ) throws -> TerminalScrollModeKeyAction {
                TerminalScrollModeKeyAction(
                    event: try XCTUnwrap(
                        Self.makeKeyEvent(key, modifiers: modifiers, keyCode: keyCode)
                    ),
                    awaitingSecondG: awaitingSecondG
                )
            }

            XCTAssertEqual(
                try action("j"),
                .move(.down)
            )
            XCTAssertEqual(
                try action("k"),
                .move(.up)
            )
            XCTAssertEqual(
                try action("d", modifiers: .control),
                .move(.halfDown)
            )
            XCTAssertEqual(
                try action("u", modifiers: .control),
                .move(.halfUp)
            )
            XCTAssertEqual(
                try action("f", modifiers: .control),
                .move(.pageDown)
            )
            XCTAssertEqual(
                try action("b", modifiers: .control),
                .move(.pageUp)
            )
            XCTAssertEqual(try action("g"), .awaitSecondG)
            XCTAssertEqual(
                try action("g", awaitingSecondG: true),
                .move(.top)
            )
            XCTAssertEqual(
                try action("g", modifiers: .shift),
                .move(.bottom)
            )
            XCTAssertEqual(try action("h"), .move(.left))
            XCTAssertEqual(try action("l"), .move(.right))
            let wordActions: [(String, TerminalScrollMovement, TerminalScrollMovement)] = [
                ("w", .wordForward(big: false), .wordForward(big: true)),
                ("b", .wordBackward(big: false), .wordBackward(big: true)),
                ("e", .wordEnd(big: false), .wordEnd(big: true)),
            ]
            for (key, small, big) in wordActions {
                XCTAssertEqual(try action(key), .move(small))
                XCTAssertEqual(try action(key, modifiers: .shift), .move(big))
            }
            XCTAssertEqual(try action("^", modifiers: .shift), .move(.firstNonblank))
            XCTAssertEqual(try action("0"), .move(.lineStart))
            XCTAssertEqual(try action("$", modifiers: .shift), .move(.lineEnd))
            XCTAssertEqual(try action("v"), .select(linewise: false))
            XCTAssertEqual(try action("v", modifiers: .shift), .select(linewise: true))
            XCTAssertEqual(try action("y"), .copy)
            XCTAssertEqual(try action("c", modifiers: .command), .copy)
            XCTAssertEqual(try action("\u{1b}", keyCode: 53), .cancel)
            XCTAssertEqual(try action("y", awaitingSecondG: true), .copy)
            XCTAssertEqual(try action("q"), .exit)
            XCTAssertEqual(try action("x"), .consume)
        }
    }

    func testCommandPaletteFilteringUsesSubstringAndOrderedCharacterMatching() {
        XCTAssertTrue(CommandPaletteFilter.matches(query: "tab", title: "New Tab"))
        XCTAssertTrue(CommandPaletteFilter.matches(query: "ftp", title: "Focus Next Pane"))
        XCTAssertTrue(CommandPaletteFilter.matches(query: "  CLOSE  ", title: "Close Window"))
        XCTAssertFalse(CommandPaletteFilter.matches(query: "xyz", title: "Close Window"))
    }

    func testCommandPaletteCommandExecutionUsesExistingActions() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            XCTAssertEqual(controller.debugTabIDs.count, 1)

            controller.debugPerformCommand(withID: "tab.new")

            XCTAssertEqual(controller.debugTabIDs.count, 2)
            XCTAssertEqual(controller.debugSelectedTabID, controller.debugTabIDs.last)
        }
    }

    func testPaneResizeCommandsMoveAndEqualizeFocusedSplit() async throws {
        try await MainActor.run {
            let controller = Self.makeController()

            controller.debugSplitFocusedPane(along: .horizontal)
            assertFractionsEqual(
                try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])),
                [0.5, 0.5],
                accuracy: 0.0001
            )

            controller.debugPerformCommand(withID: "pane.resize.left")
            assertFractionsEqual(
                try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])),
                [0.45, 0.55],
                accuracy: 0.0001
            )
            XCTAssertLessThan(
                try XCTUnwrap(controller.debugRenderedSplitChildFrame(at: [], childIndex: 0))
                    .width,
                try XCTUnwrap(controller.debugRenderedSplitChildFrame(at: [], childIndex: 1))
                    .width
            )

            controller.debugPerformCommand(withID: "pane.resize.equalize")
            assertFractionsEqual(
                try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])),
                [0.5, 0.5],
                accuracy: 0.0001
            )
        }
    }

    func testPaneResizeCommandMovesHorizontalDividerAfterNestedVerticalSplit() async throws {
        try await MainActor.run {
            let controller = Self.makeController()

            controller.debugSplitFocusedPane(along: .horizontal)
            controller.debugSplitFocusedPane(along: .vertical)

            let initialLeftWidth = try XCTUnwrap(
                controller.debugRenderedSplitChildFrame(at: [], childIndex: 0)
            ).width
            let initialRightWidth = try XCTUnwrap(
                controller.debugRenderedSplitChildFrame(at: [], childIndex: 1)
            ).width

            controller.debugPerformCommand(withID: "pane.resize.left")

            let updatedLeftWidth = try XCTUnwrap(
                controller.debugRenderedSplitChildFrame(at: [], childIndex: 0)
            ).width
            let updatedRightWidth = try XCTUnwrap(
                controller.debugRenderedSplitChildFrame(at: [], childIndex: 1)
            ).width

            XCTAssertLessThan(updatedLeftWidth, initialLeftWidth)
            XCTAssertGreaterThan(updatedRightWidth, initialRightWidth)
        }
    }

    func testPaneResizeRightCanShrinkNestedVerticalSplitToMinimumWidth() async throws {
        try await MainActor.run {
            let controller = Self.makeController()

            controller.debugSplitFocusedPane(along: .horizontal)
            controller.debugSplitFocusedPane(along: .vertical)

            for _ in 0..<8 {
                controller.debugPerformCommand(withID: "pane.resize.right")
            }

            let rightWidth = try XCTUnwrap(
                controller.debugRenderedSplitChildFrame(at: [], childIndex: 1)
            ).width
            let rootFractions = try XCTUnwrap(controller.debugRenderedSplitFractions(at: []))

            XCTAssertLessThan(rootFractions[1], 0.25)
            XCTAssertEqual(
                rightWidth,
                WorkspaceLayoutMetrics.minimumPaneSize.width,
                accuracy: WorkspaceLayoutMetrics.dividerThickness
            )
        }
    }

    @MainActor
    private static func makeController() -> WorkspaceViewController {
        AppAppearanceSettings.resetWorkspaceEdgePadding()
        let controller = WorkspaceViewController()
        controller.debugLoadForTesting()
        return controller
    }

    private static func makeKeyEvent(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        keyCode: UInt16 = 0
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false,
            keyCode: keyCode
        )
    }

    @MainActor
    private static func withRestoredKeybindingUserDefaults(_ operation: () throws -> Void) rethrows {
        let keys = KeybindingAction.allCases.map {
            "KeyboardShortcuts_\($0.shortcutName.rawValue)"
        }
        let savedValues = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, UserDefaults.standard.object(forKey: $0))
        })

        defer {
            for (key, value) in savedValues {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        try operation()
    }

    @MainActor
    private static func enableAutoResize(
        for paneID: PaneID,
        in controller: WorkspaceViewController
    ) {
        controller.debugSetPaneAutoResizeConfiguration(
            PaneAutoResizeConfiguration(
                isEnabled: true,
                ratios: PaneFocusRatios(horizontal: 0.7, vertical: 0.7)
            ),
            for: paneID
        )
    }
}

@MainActor
private final class AppMenuTestTarget: NSObject {
    @objc func handleCommandPalette(_: Any?) {}
    @objc func handleCheckForUpdates(_: Any?) {}
    @objc func handleSettings(_: Any?) {}
}

private func assertFractionsEqual(
    _ lhs: [CGFloat],
    _ rhs: [CGFloat],
    accuracy: CGFloat,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
    for (left, right) in zip(lhs, rhs) {
        XCTAssertEqual(left, right, accuracy: accuracy, file: file, line: line)
    }
}

private func assertRectsEqual(
    _ lhs: NSRect,
    _ rhs: NSRect,
    accuracy: CGFloat,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(lhs.minX, rhs.minX, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(lhs.minY, rhs.minY, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(lhs.width, rhs.width, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(lhs.height, rhs.height, accuracy: accuracy, file: file, line: line)
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
