import AppKit
import KeyboardShortcuts
import XCTest
@testable import Santty

final class WorkspaceViewControllerTests: XCTestCase {
    @MainActor
    func testPaletteSearchRanksNamesAndFiltersKindsAndOwnership() {
        let items = [
            AppCommand(id: "command", title: "New Tab", shortcut: nil, isEnabled: true) {},
            AppCommand(id: "space", title: "Default", shortcut: nil, isEnabled: true, kind: .workspace) {},
            AppCommand(id: "remote", title: "Logs", shortcut: nil, isEnabled: true, kind: .pane, subtitle: "Santty › API") {},
            AppCommand(id: "local", title: "Logs", shortcut: nil, isEnabled: true, kind: .pane, subtitle: "Default › API", isInCurrentWorkspace: true) {},
            AppCommand(id: "tab", title: "API", shortcut: nil, isEnabled: true, kind: .tab, isInCurrentWorkspace: true) {},
        ]
        XCTAssertEqual(CommandPaletteFilter.results(items, query: "", kind: nil).map(\.id), ["command", "space", "tab"])
        XCTAssertEqual(CommandPaletteFilter.results(items, query: "logs", kind: nil).map(\.id), ["local", "remote"])
        XCTAssertEqual(CommandPaletteFilter.results(items, query: "Santty logs", kind: nil).map(\.id), ["remote"])
        XCTAssertEqual(CommandPaletteFilter.results(items, query: "", kind: .pane).map(\.id), ["remote", "local"])
        XCTAssertEqual(CommandPaletteFilter.results(items, query: "tab", kind: .command).map(\.id), ["command"])
    }

    @MainActor
    func testPaletteLocalNavigationPreservesFloatingAndRevealsHiddenPanes() async throws {
        let controller = Self.makeController()
        let first = try XCTUnwrap(controller.debugFocusedPaneID)
        controller.debugSplitFocusedPane(along: .horizontal)
        let floating = try XCTUnwrap(controller.debugFocusedPaneID)
        controller.debugSetFocusedPaneName("Floating target")
        controller.debugToggleFloatingPane()
        controller.debugNewTab()
        let target = try XCTUnwrap(controller.paletteNavigationItems.first { $0.kind == .pane && $0.title == "Floating target" })
        target.perform()
        await Task.yield()
        XCTAssertEqual(controller.debugFocusedPaneID, floating)
        XCTAssertEqual(controller.debugActiveFloatingPaneState?.paneID, floating)
        controller.debugHandlePaneFocusRequest(withID: first)
        controller.debugSetFocusedPaneName("Hidden target")
        controller.debugDetachFocusedPane()
        controller.debugNewTab()
        try XCTUnwrap(controller.paletteNavigationItems.first { $0.kind == .pane && $0.title == "Hidden target" }).perform()
        await Task.yield()
        XCTAssertEqual(controller.debugActiveDetachedPaneID, first)
        XCTAssertEqual(controller.debugFocusedPaneID, first)
        XCTAssertTrue(controller.debugCommandSnapshots.allSatisfy { !$0.id.hasPrefix("navigate.") }, "CLI command exports must remain commands only")
    }

    @MainActor
    func testPaletteRejectsRemovedTabWithoutChangingSelection() async throws {
        let controller = Self.makeController()
        let first = try XCTUnwrap(controller.debugSelectedTabID)
        let stale = try XCTUnwrap(controller.paletteNavigationItems.first { $0.kind == .tab })
        controller.debugNewTab()
        let selected = controller.debugSelectedTabID
        controller.debugCloseTab(withID: first)
        stale.perform()
        await Task.yield()
        XCTAssertEqual(controller.debugSelectedTabID, selected)
        XCTAssertTrue(controller.paletteNavigationItems.allSatisfy { $0.id != stale.id })
    }

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

            XCTAssertNil(hostView.appearance)
            XCTAssertEqual(hostView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
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
            XCTAssertEqual(tabStripFrame.minY, 0, accuracy: 0.0001)
            XCTAssertEqual(contentFrame.maxY, (controller.view as? WindowContentView)?.mainView.bounds.height ?? 0, accuracy: 0.0001)
            XCTAssertGreaterThan(contentFrame.minY, tabStripFrame.maxY)
            XCTAssertEqual(controller.debugRenderedContentFrame, contentFrame)
            XCTAssertGreaterThan(controller.debugRenderedContentFrame.width, 0)
            XCTAssertGreaterThan(controller.debugRenderedContentFrame.height, 0)
        }
    }

    @MainActor
    func testWorkspaceSwitcherInheritsDarkWindowAppearance() throws {
        let toolbar = WorkspaceToolbarView(frame: NSRect(x: 0, y: 0, width: 640, height: 32))
        let window = NSWindow(contentRect: toolbar.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = toolbar
        defer { window.contentView = nil }
        let first = UUID(), second = UUID()
        toolbar.updateWorkspaceEntries([
            .init(reference: first, name: "Santty"),
            .init(reference: second, name: "Other"),
        ], selectedID: "local." + first.uuidString)
        toolbar.layoutSubtreeIfNeeded()
        let button = toolbar.workspaceSwitcher
        XCTAssertNil(toolbar.appearance)
        XCTAssertNil(button.appearance)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.titleOfSelectedItem, "Santty")
        XCTAssertEqual(button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua,
            "Workspace controls must inherit the window's dark appearance")
        XCTAssertGreaterThanOrEqual(button.frame.height, 30)
        XCTAssertGreaterThan(button.frame.width, 0)
        XCTAssertTrue(toolbar.bounds.contains(button.convert(button.bounds, to: toolbar)))
        XCTAssertEqual(button.frame.minX, toolbar.bounds.minX, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(toolbar.tabStripView.frame.minX, button.frame.maxX)
        toolbar.updateDetachedPanes([], target: nil, action: #selector(NSButton.performClick(_:)))
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.frame.minX, toolbar.bounds.minX, accuracy: 0.001)
        XCTAssertLessThanOrEqual(toolbar.tabStripView.frame.maxX,
            toolbar.bounds.maxX)
        var selected: String?
        toolbar.onSelectWorkspace = { selected = $0 }
        button.selectItem(at: 1)
        XCTAssertTrue(button.sendAction(button.action, to: button.target))
        XCTAssertEqual(selected, "local." + second.uuidString)
    }

    @MainActor
    func testAgentsButtonRestoresCapsuleAndUnreadBadge() throws {
        let toolbar = WorkspaceToolbarView(frame: NSRect(x: 0, y: 0, width: 640, height: 32))
        toolbar.updateAgents(count: 2, unread: 100)
        toolbar.layoutSubtreeIfNeeded()
        let button = toolbar.agentStatusButton
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.title, "Agents")
        XCTAssertEqual(button.badgeText, "99+")
        XCTAssertEqual(button.intrinsicContentSize.height, 32)
        XCTAssertEqual(button.layer?.cornerRadius, 16)
        XCTAssertGreaterThan(try XCTUnwrap(button.layer?.backgroundColor).alpha, 0)
        XCTAssertLessThanOrEqual(button.debugBadgeFrame.maxX, button.bounds.maxX)
        toolbar.updateAgents(count: 2, unread: 0)
        XCTAssertNil(button.badgeText)
        toolbar.updateAgents(count: 0, unread: 0)
        XCTAssertTrue(button.isHidden)
    }

    @MainActor
    func testWorkspaceSwitcherHasItsOwnBackgroundInHiddenWindowMode() throws {
        let previousValue = AppAppearanceSettings.isWindowHidden
        defer { AppAppearanceSettings.isWindowHidden = previousValue }
        AppAppearanceSettings.isWindowHidden = true
        let toolbar = WorkspaceToolbarView(frame: NSRect(x: 0, y: 0, width: 640, height: 32))
        toolbar.layoutSubtreeIfNeeded()
        let background = try XCTUnwrap(toolbar.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        XCTAssertFalse(background.isHidden)
        XCTAssertEqual(background.frame, toolbar.workspaceSwitcher.frame)
        XCTAssertEqual(background.blendingMode, .behindWindow)
        XCTAssertEqual(background.layer?.cornerRadius, WorkspaceTabButtonView.cornerRadius)
        XCTAssertTrue(background.subviews.contains { $0.identifier == AppAppearanceDefaults.vibrancyTintIdentifier })

        AppAppearanceSettings.isWindowHidden = false
        toolbar.updateAppearance()
        XCTAssertTrue(background.isHidden)
        AppAppearanceSettings.isWindowHidden = true
        toolbar.updateAppearance()
        XCTAssertFalse(background.isHidden)
    }

    @MainActor
    func testWorkspaceSwitcherKeepsMenuAndSelectionStableAcrossTabUpdates() {
        let toolbar = WorkspaceToolbarView(frame: NSRect(x: 0, y: 0, width: 640, height: 32))
        let first = UUID(), second = UUID()
        let entries = [WorkspaceEntry(reference: first, name: "Santty"), .init(reference: second, name: "Other")]
        toolbar.updateWorkspaceEntries(entries, selectedID: "local." + first.uuidString)
        let items = toolbar.workspaceSwitcher.itemArray
        toolbar.updateWorkspaceEntries(entries, selectedID: "local." + first.uuidString)
        for (before, after) in zip(items, toolbar.workspaceSwitcher.itemArray) { XCTAssertTrue(before === after) }
        var chosen: String?
        toolbar.onSelectWorkspace = { chosen = $0 }
        toolbar.workspaceSwitcher.selectItem(at: 1)
        _ = toolbar.workspaceSwitcher.sendAction(toolbar.workspaceSwitcher.action, to: toolbar.workspaceSwitcher.target)
        XCTAssertEqual(chosen, "local." + second.uuidString)
        XCTAssertEqual(toolbar.workspaceSwitcher.titleOfSelectedItem, "Santty")
        toolbar.updateWorkspaceEntries([.init(reference: first, name: "Renamed"), entries[1]], selectedID: "local." + second.uuidString)
        XCTAssertEqual(toolbar.workspaceSwitcher.titleOfSelectedItem, "Other")
        XCTAssertEqual(toolbar.workspaceSwitcher.item(at: 0)?.title, "Renamed")
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

    func testUnfocusedAutoResizeCollapsesAndKeyboardFocusRestoresOriginalLayout() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let first = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugSplitFocusedPane(along: .horizontal)
            let second = try XCTUnwrap(controller.debugFocusedPaneID)
            let original = controller.debugLayoutNode
            controller.debugSetPaneAutoResizeConfiguration(.init(
                isEnabled: true, ratios: .init(horizontal: 0, vertical: 0), trigger: .unfocused), for: first)
            controller.debugFocusPane(withID: first)
            XCTAssertNil(controller.debugActiveAutoZoomState)
            controller.debugFocusPane(withID: second)
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0, 1], accuracy: 0.0001)
            XCTAssertTrue(try XCTUnwrap(controller.debugRenderedSplitChildFrame(at: [], childIndex: 0)).isEmpty)
            XCTAssertEqual(controller.debugLayoutNode, original)
            try controller.savedWorkspace().validate()

            controller.debugFocusPane(in: .left)
            XCTAssertEqual(controller.debugFocusedPaneID, first)
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.5, 0.5], accuracy: 0.0001)
            controller.debugFocusPane(withID: second)
            controller.focusNextPane(nil)
            XCTAssertEqual(controller.debugFocusedPaneID, first)
            XCTAssertEqual(controller.debugLayoutNode, original)
        }
    }

    func testUnfocusedAutoResizeUsesRatiosAndKeepsFocusedSiblingVisibleAtOneHundredPercent() async throws {
        try await MainActor.run {
            for axis in [SplitAxis.horizontal, .vertical] {
                let controller = Self.makeController()
                let first = try XCTUnwrap(controller.debugFocusedPaneID)
                controller.debugSplitFocusedPane(along: axis)
                let second = try XCTUnwrap(controller.debugFocusedPaneID)
                controller.debugSetPaneAutoResizeConfiguration(.init(
                    isEnabled: true, ratios: .init(
                        horizontal: axis == .horizontal ? 0.35 : 0,
                        vertical: axis == .vertical ? 0.65 : 0), trigger: .unfocused), for: first)
                controller.debugFocusPane(withID: first)
                controller.debugFocusPane(withID: second)
                let ratio: CGFloat = axis == .horizontal ? 0.35 : 0.65
                assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [ratio, 1 - ratio], accuracy: 0.0001)

                controller.debugSetPaneAutoResizeConfiguration(.init(
                    isEnabled: true, ratios: .init(horizontal: 1, vertical: 1), trigger: .unfocused), for: first)
                controller.debugFocusPane(withID: first)
                controller.debugFocusPane(withID: second)
                let fractions = try XCTUnwrap(controller.debugRenderedSplitFractions(at: []))
                XCTAssertLessThan(fractions[0], 1)
                XCTAssertGreaterThan(fractions[1], 0)
                XCTAssertFalse(try XCTUnwrap(controller.debugRenderedSplitChildFrame(at: [], childIndex: 1)).isEmpty)
                try controller.savedWorkspace().validate()
            }
        }
    }

    func testFocusAutoResizeOverridesConflictingUnfocusedCollapse() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let first = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugSplitFocusedPane(along: .horizontal)
            let second = try XCTUnwrap(controller.debugFocusedPaneID)
            controller.debugSetPaneAutoResizeConfiguration(.init(
                isEnabled: true, ratios: .init(horizontal: 0, vertical: 0), trigger: .unfocused), for: first)
            controller.debugSetPaneAutoResizeConfiguration(.init(
                isEnabled: true, ratios: .init(horizontal: 0.7, vertical: 0.7),
                isHorizontalEnabled: false), for: second)
            controller.debugFocusPane(withID: first)
            controller.debugFocusPane(withID: second)
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0, 1], accuracy: 0.0001)
            Self.enableAutoResize(for: second, in: controller)
            controller.debugFocusPane(withID: first)
            controller.debugFocusPane(withID: second)
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.3, 0.7], accuracy: 0.0001)
            XCTAssertFalse(try XCTUnwrap(controller.debugRenderedSplitChildFrame(at: [], childIndex: 0)).isEmpty)
        }
    }

    func testAutoResizeAxesCanBeEnabledIndependentlyForBothTriggers() async throws {
        try await MainActor.run {
            for trigger in [PaneAutoResizeConfiguration.Trigger.focus, .unfocused] {
                for (horizontal, vertical) in [(true, false), (false, true), (true, true), (false, false)] {
                    let controller = Self.makeController()
                    let outside = try XCTUnwrap(controller.debugFocusedPaneID)
                    controller.debugSplitFocusedPane(along: .horizontal)
                    let configured = try XCTUnwrap(controller.debugFocusedPaneID)
                    controller.debugSplitFocusedPane(along: .vertical)
                    controller.debugUpdateSplitFractions(at: [.child(1)], to: [0.35, 0.65])
                    let original = controller.debugLayoutNode
                    controller.debugSetPaneAutoResizeConfiguration(.init(
                        isEnabled: true,
                        ratios: trigger == .focus ? .init(horizontal: 0.65, vertical: 0.6) : .init(horizontal: 0, vertical: 0),
                        trigger: trigger, isHorizontalEnabled: horizontal, isVerticalEnabled: vertical), for: configured)
                    controller.debugFocusPane(withID: outside)
                    controller.debugFocusPane(withID: configured)
                    if trigger == .unfocused { controller.debugFocusPane(withID: outside) }

                    let horizontalFractions: [CGFloat] = horizontal
                        ? (trigger == .focus ? [0.35, 0.65] : [1, 0]) : [0.5, 0.5]
                    let verticalFractions: [CGFloat] = vertical
                        ? (trigger == .focus ? [0.6, 0.4] : [0, 1]) : [0.35, 0.65]
                    assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), horizontalFractions, accuracy: 0.0001)
                    assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [.child(1)])), verticalFractions, accuracy: 0.0001)
                    XCTAssertEqual(controller.debugLayoutNode, original)
                    try controller.savedWorkspace().validate()

                    controller.debugFocusPane(withID: trigger == .focus ? outside : configured)
                    assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.5, 0.5], accuracy: 0.0001)
                    assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [.child(1)])), [0.35, 0.65], accuracy: 0.0001)
                }
            }
        }
    }

    func testUnfocusedZeroCollapsesMatchingAncestorAxisAndRestoresWholeBranch() async throws {
        try await MainActor.run {
            for axis in [SplitAxis.horizontal, .vertical] {
                let controller = Self.makeController()
                let outside = try XCTUnwrap(controller.debugFocusedPaneID)
                controller.debugSplitFocusedPane(along: axis)
                let configured = try XCTUnwrap(controller.debugFocusedPaneID)
                controller.debugSplitFocusedPane(along: axis == .horizontal ? .vertical : .horizontal)
                let sibling = try XCTUnwrap(controller.debugFocusedPaneID)
                let original = controller.debugLayoutNode
                controller.debugSetPaneAutoResizeConfiguration(.init(
                    isEnabled: true, ratios: .init(
                        horizontal: axis == .horizontal ? 0 : 0.6,
                        vertical: axis == .vertical ? 0 : 0.6), trigger: .unfocused), for: configured)

                controller.debugFocusPane(withID: configured)
                controller.debugFocusPane(withID: outside)
                assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [1, 0], accuracy: 0.0001)
                assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [.child(1)])), [0.6, 0.4], accuracy: 0.0001)
                for index in 0...1 {
                    let frame = try XCTUnwrap(controller.debugRenderedSplitChildFrame(at: [.child(1)], childIndex: index))
                    XCTAssertEqual(axis == .horizontal ? frame.width : frame.height, 0)
                    XCTAssertGreaterThan(axis == .horizontal ? frame.height : frame.width, 0)
                }
                XCTAssertEqual(controller.debugLayoutNode, original)
                try controller.savedWorkspace().validate()

                controller.debugFocusPane(in: axis == .horizontal ? .right : .below)
                XCTAssertEqual(controller.debugFocusedPaneID, configured)
                assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.5, 0.5], accuracy: 0.0001)
                assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [.child(1)])), [0.5, 0.5], accuracy: 0.0001)

                controller.debugFocusPane(withID: outside)
                controller.debugFocusPane(withID: sibling)
                assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.5, 0.5], accuracy: 0.0001)
                assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [.child(1)])), [0.6, 0.4], accuracy: 0.0001)

                Self.enableAutoResize(for: outside, in: controller)
                controller.debugFocusPane(withID: outside)
                assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.7, 0.3], accuracy: 0.0001)
                XCTAssertFalse(try XCTUnwrap(controller.debugRenderedSplitChildFrame(at: [], childIndex: 1)).isEmpty)
                XCTAssertEqual(controller.debugLayoutNode, original)
                try controller.savedWorkspace().validate()
            }
        }
    }

    func testMultipleUnfocusedPanesCollapseAndManualDragNeverPersistsZeroFractions() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            controller.debugSplitFocusedPane(along: .horizontal)
            controller.debugSplitFocusedPane(along: .horizontal)
            let ids = controller.debugPaneIDsInTraversalOrder
            for id in ids.prefix(2) {
                controller.debugSetPaneAutoResizeConfiguration(.init(
                    isEnabled: true, ratios: .init(horizontal: 0, vertical: 0), trigger: .unfocused), for: id)
            }
            controller.debugFocusPane(withID: ids[0])
            controller.debugFocusPane(withID: ids[2])
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0, 0, 1], accuracy: 0.0001)
            controller.debugSetPaneAutoResizeConfiguration(WorkspaceFocusZoomConfiguration.defaultAutoResizeConfiguration, for: ids[1])
            controller.debugFocusPane(withID: ids[1])
            controller.debugFocusPane(withID: ids[2])
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let tiling = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? WorkspaceTilingView }
                .first { $0.paneViews[ids[0]] != nil })
            let usableWidth = tiling.bounds.width - AppAppearanceSettings.workspaceDividerThickness
            tiling.debugApplyDragForDivider(at: [], dividerIndex: 1, location: NSPoint(x: usableWidth * 0.55, y: 300))
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0, 0.55, 0.45], accuracy: 0.0001)
            XCTAssertEqual(controller.debugPaneAutoResizeConfiguration(for: ids[0])?.isEnabled, true)
            controller.debugFocusPane(withID: ids[0])
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.5, 0.275, 0.225], accuracy: 0.0001)
            controller.debugFocusPane(withID: ids[2])
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0, 0.55, 0.45], accuracy: 0.0001)
            try controller.savedWorkspace().validate()
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
            for showSidebar in [false, true] {
                let controller = Self.makeController()
                if showSidebar { controller.toggleSidebar(nil) }
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

    func testDraggingActiveAutoZoomSplitPreservesPaneAutoResizeAndReappliesOnFocus() async throws {
        try await MainActor.run {
            let controller = Self.makeController()
            let firstPaneID = try XCTUnwrap(controller.debugFocusedPaneID)

            controller.debugSplitFocusedPane(along: .horizontal)
            let secondPaneID = try XCTUnwrap(controller.debugFocusedPaneID)
            Self.enableAutoResize(for: firstPaneID, in: controller)
            Self.enableAutoResize(for: secondPaneID, in: controller)
            controller.debugFocusPane(withID: firstPaneID)
            controller.debugFocusPane(withID: secondPaneID)
            let configurations = controller.savedWorkspace().tabs[0].autoResize

            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let tiling = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? WorkspaceTilingView }
                .first { $0.paneViews[firstPaneID] != nil })
            let usableWidth = tiling.bounds.width - AppAppearanceSettings.workspaceDividerThickness
            tiling.debugApplyDragForDivider(at: [], dividerIndex: 0, location: NSPoint(x: usableWidth * 0.42, y: 300))

            XCTAssertNil(controller.debugActiveAutoZoomState)
            XCTAssertEqual(controller.savedWorkspace().tabs[0].autoResize, configurations)
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.42, 0.58], accuracy: 0.0001)
            let manualLayout = controller.debugLayoutNode

            controller.debugFocusPane(withID: firstPaneID)

            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.7, 0.3], accuracy: 0.0001)
            controller.debugFocusPane(withID: secondPaneID)
            assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.3, 0.7], accuracy: 0.0001)
            XCTAssertEqual(controller.debugLayoutNode, manualLayout)
            XCTAssertEqual(controller.savedWorkspace().tabs[0].autoResize, configurations)
            try controller.savedWorkspace().validate()
        }
    }

    func testResizeCommandsKeepAutoResizeSettingsAndManualLayoutUntilFocusChanges() async throws {
        try await MainActor.run {
            for trigger in [PaneAutoResizeConfiguration.Trigger.focus, .unfocused] {
                for command in ["pane.resize.left", "pane.resize.equalize"] {
                    let controller = Self.makeController()
                    let first = try XCTUnwrap(controller.debugFocusedPaneID)
                    controller.debugSplitFocusedPane(along: .horizontal)
                    let second = try XCTUnwrap(controller.debugFocusedPaneID)
                    controller.debugSetPaneAutoResizeConfiguration(.init(
                        isEnabled: true,
                        ratios: .init(horizontal: trigger == .focus ? 0.7 : 0.3, vertical: 0.6),
                        trigger: trigger, isVerticalEnabled: false),
                        for: trigger == .focus ? second : first)
                    controller.debugFocusPane(withID: first)
                    controller.debugFocusPane(withID: second)
                    assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.3, 0.7], accuracy: 0.0001)
                    let configurations = controller.savedWorkspace().tabs[0].autoResize

                    controller.debugPerformCommand(withID: command)
                    let fractions: [CGFloat] = command == "pane.resize.left" ? [0.45, 0.55] : [0.5, 0.5]
                    assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), fractions, accuracy: 0.0001)
                    XCTAssertEqual(controller.savedWorkspace().tabs[0].autoResize, configurations)
                    XCTAssertNil(controller.debugActiveAutoZoomState)
                    let manualLayout = controller.debugLayoutNode

                    controller.debugFocusPane(withID: first)
                    assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), fractions, accuracy: 0.0001)
                    controller.debugFocusPane(withID: second)
                    assertFractionsEqual(try XCTUnwrap(controller.debugRenderedSplitFractions(at: [])), [0.3, 0.7], accuracy: 0.0001)
                    XCTAssertEqual(controller.debugLayoutNode, manualLayout)
                    XCTAssertEqual(controller.savedWorkspace().tabs[0].autoResize, configurations)
                    try controller.savedWorkspace().validate()
                }
            }
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
                        "sidebar.toggle", "sidebar.left", "sidebar.right", "sidebar.browser", "sidebar.workspaces", "sidebar.agents",
                        "agents.show", "workspace.new", "workspace.rename", "workspace.new.herdr.remote", "workspace.new.herdr", "workspace.close", "pane.rename",
                        "pane.split.horizontal",
                        "pane.split.vertical",
                        "pane.terminal.new", "pane.workspaces.new",
                        "pane.agents.new", "pane.browser.new",
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
                        "tab.rename",
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
            XCTAssertEqual(controller.debugCommandSnapshots.first(where: { $0.id == "tab.rename" })?.isEnabled, true)

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

extension WorkspaceViewControllerTests {
    @MainActor
    func testCommandBTogglesSidebarThroughMenuAndPalette() throws {
        try Self.withRestoredKeybindingUserDefaults {
            let action = KeybindingAction.toggleSidebar
            KeybindingSettings.resetShortcut(for: action)
            XCTAssertEqual(action.defaultShortcut, .init(.b, modifiers: [.command]))
            let controller = Self.makeController()
            let menu = NSMenu()
            let item = NSMenuItem(title: action.title, action: #selector(WorkspaceViewController.toggleSidebar(_:)), keyEquivalent: "")
            item.target = controller
            KeybindingSettings.applyShortcut(for: action, to: item)
            menu.addItem(item)
            XCTAssertEqual(item.keyEquivalent, "b")
            XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
            let event = try XCTUnwrap(Self.makeKeyEvent("b", modifiers: [.command], keyCode: UInt16(KeyboardShortcuts.Key.b.rawValue)))
            XCTAssertEqual(KeybindingSettings.action(matching: event), .toggleSidebar)
            XCTAssertFalse(controller.debugSidebarVisible)
            XCTAssertTrue(AppMenuKeyEquivalents.perform(event, in: menu))
            XCTAssertTrue(controller.debugSidebarVisible)
            let command = try XCTUnwrap(controller.commandPaletteCommands.first { $0.id == "sidebar.toggle" })
            XCTAssertEqual(command.title, "Toggle Sidebar")
            XCTAssertEqual(command.shortcut, KeybindingSettings.displayShortcut(for: action))
            command.perform()
            XCTAssertFalse(controller.debugSidebarVisible)
        }
    }

    @MainActor
    func testTitleUpdatesKeepSidebarAndWorkspaceSelectionExclusive() throws {
        let controller = Self.makeController()
        let main = try XCTUnwrap(controller.debugFocusedPaneID)
        controller.toggleSidebar(nil)
        let sidebar = try XCTUnwrap(controller.debugSidebarPaneIDs.first)
        let mainBadge = try XCTUnwrap(controller.debugPaneNameBadge(for: main))
        let sidebarBadge = try XCTUnwrap(controller.debugPaneNameBadge(for: sidebar))

        for focusSidebar in [false, true, false, true] {
            if focusSidebar { controller.debugFocusSidebarPane(sidebar) }
            else { controller.debugFocusPane(withID: main) }
            for paneID in [main, sidebar] {
                controller.debugSetPaneTitle("Updated shell title", for: paneID)
                XCTAssertEqual(controller.debugSidebarFocused, focusSidebar)
                XCTAssertEqual(mainBadge.isFocused, !focusSidebar)
                XCTAssertEqual(sidebarBadge.isFocused, focusSidebar)
            }
        }

        controller.toggleSidebar(nil)
        controller.debugSetPaneTitle("Hidden sidebar title", for: sidebar)
        XCTAssertTrue(mainBadge.isFocused)
        XCTAssertFalse(sidebarBadge.isFocused)

        controller.debugNewTab()
        let activeBadge = try XCTUnwrap(controller.debugPaneNameBadge(for: try XCTUnwrap(controller.debugFocusedPaneID)))
        controller.debugSetPaneTitle("Background tab title", for: main)
        XCTAssertTrue(activeBadge.isFocused)
        XCTAssertFalse(mainBadge.isFocused)
        XCTAssertFalse(sidebarBadge.isFocused)
    }

    @MainActor
    func testSidebarFocusCrossesBothSidesWithoutSelectingItsTab() throws {
        let controller = Self.makeController()
        let main = try XCTUnwrap(controller.debugFocusedPaneID)
        let tab = controller.debugSelectedTabID
        controller.toggleSidebar(nil)
        XCTAssertEqual(controller.debugSidebarPaneIDs.count, 1)
        XCTAssertFalse(controller.debugSidebarFocused)
        XCTAssertEqual(controller.debugTabIDs.count, 1)
        controller.focusLeftPane(nil)
        XCTAssertTrue(controller.debugSidebarFocused)
        XCTAssertEqual(controller.debugSelectedTabID, tab)
        controller.focusRightPane(nil)
        XCTAssertFalse(controller.debugSidebarFocused)
        XCTAssertEqual(controller.debugFocusedPaneID, main)
        controller.moveSidebarRight(nil)
        let outer = try XCTUnwrap(controller.view as? WindowContentView)
        controller.view.layoutSubtreeIfNeeded()
        let mainFrame = outer.mainView.contentContainerView.convert(outer.mainView.contentContainerView.bounds, to: outer)
        let sideFrame = outer.sidebarView.convert(outer.sidebarView.bounds, to: outer)
        XCTAssertLessThanOrEqual(mainFrame.maxX, sideFrame.minX, "main=\(mainFrame) sidebar=\(sideFrame)")
        controller.focusRightPane(nil)
        XCTAssertTrue(controller.debugSidebarFocused, "main=\(mainFrame) sidebar=\(sideFrame) panes=\(controller.debugSidebarPaneIDs.map { controller.debugSidebarPane($0)!.hostView.convert(controller.debugSidebarPane($0)!.hostView.bounds, to: outer) })")
        controller.focusLeftPane(nil)
        XCTAssertFalse(controller.debugSidebarFocused)
        XCTAssertEqual(controller.debugSidebarSide, .right)
        XCTAssertTrue(controller.commandPaletteCommands.first { $0.id == "pane.focus.right" }?.isEnabled == true)
    }

    @MainActor
    func testSidebarPaneIdentitySurvivesMainTabsWorkspacesAndVisibility() throws {
        let controller = Self.makeController()
        controller.toggleSidebar(nil)
        let ids = controller.debugSidebarPaneIDs
        let pane = try XCTUnwrap(controller.debugSidebarPane(ids[0]))
        controller.debugNewTab()
        controller.newWorkspace(nil)
        XCTAssertEqual(controller.debugSidebarPaneIDs, ids)
        XCTAssertTrue(controller.debugSidebarPane(ids[0]) === pane)
        controller.debugFocusSidebarPane(ids[0])
        controller.toggleSidebar(nil)
        XCTAssertFalse(controller.debugSidebarFocused)
        XCTAssertFalse(controller.debugSidebarVisible)
        controller.toggleSidebar(nil)
        XCTAssertTrue(controller.debugSidebarPane(ids[0]) === pane)
        XCTAssertFalse(controller.debugSidebarFocused)
        XCTAssertFalse(controller.debugWorkspaceEntries.contains { $0.reference == controller.savedWorkspace().sidebar?.tab.id })
        controller.debugFocusSidebarPane(ids[0])
        controller.newWorkspace(nil)
        XCTAssertFalse(controller.debugSidebarFocused)
        XCTAssertTrue(controller.debugSidebarPane(ids[0]) === pane)
    }

    @MainActor
    func testSidebarPaneCommandsStayInsideTheirOwner() throws {
        let controller = Self.makeController()
        let mainLayout = controller.debugLayoutNode
        controller.toggleSidebar(nil)
        controller.debugFocusSidebarPane(try XCTUnwrap(controller.debugSidebarPaneIDs.first))
        controller.newBrowserPane(nil)
        XCTAssertEqual(controller.debugSidebarPaneIDs.count, 2)
        XCTAssertTrue(controller.debugFocusedPaneIsBrowser)
        controller.equalizePaneSplits(nil)
        controller.movePaneDividerUp(nil)
        controller.movePaneDown(nil)
        XCTAssertEqual(controller.debugLayoutNode, mainLayout)
        XCTAssertTrue(controller.savedWorkspace().sidebar?.tab.autoResize.isEmpty == true)
        controller.closePane(nil)
        XCTAssertEqual(controller.debugSidebarPaneIDs.count, 1)
        XCTAssertEqual(controller.debugLayoutNode, mainLayout)
        try controller.savedWorkspace().validate()
    }

    @MainActor
    func testSidebarHorizontalResizeShortcutsMoveOuterDividerOnEitherSide() throws {
        for (side, splitVertically) in [(SidebarSide.left, false), (.right, false), (.left, true), (.right, true)] {
            let controller = Self.makeController()
            if side == .left { controller.moveSidebarLeft(nil) }
            else { controller.moveSidebarRight(nil) }
            controller.debugFocusSidebarPane(try XCTUnwrap(controller.debugSidebarPaneIDs.first))
            if splitVertically { controller.splitPaneVertically(nil) }
            let outer = try XCTUnwrap(controller.view as? WindowContentView)
            let mainLayout = controller.debugLayoutNode
            let sidebarLayout = controller.savedWorkspace().sidebar?.tab.layout
            let width = outer.sidebarView.frame.width
            let grow: KeybindingAction = side == .left ? .movePaneDividerRight : .movePaneDividerLeft
            let shrink: KeybindingAction = side == .left ? .movePaneDividerLeft : .movePaneDividerRight
            let item = NSMenuItem(title: "Resize", action: side == .left ? #selector(WorkspaceViewController.movePaneDividerRight(_:)) : #selector(WorkspaceViewController.movePaneDividerLeft(_:)), keyEquivalent: "")
            XCTAssertTrue(controller.validateMenuItem(item))
            XCTAssertTrue(controller.performKeybindingAction(grow))
            XCTAssertGreaterThan(outer.sidebarView.frame.width, width)
            XCTAssertEqual(try XCTUnwrap(controller.savedWorkspace().sidebar?.preferredWidth), outer.sidebarView.frame.width, accuracy: 0.01)
            XCTAssertTrue(controller.performKeybindingAction(shrink))
            XCTAssertEqual(outer.sidebarView.frame.width, width, accuracy: 0.01)
            for _ in 0..<30 { controller.performKeybindingAction(grow) }
            XCTAssertGreaterThanOrEqual(outer.mainView.contentContainerView.frame.width, WorkspaceLayoutMetrics.minimumPaneSize.width)
            for _ in 0..<30 { controller.performKeybindingAction(shrink) }
            XCTAssertEqual(outer.sidebarView.frame.width, WorkspaceLayoutMetrics.minimumPaneSize.width, accuracy: 0.01)
            XCTAssertEqual(controller.debugLayoutNode, mainLayout)
            XCTAssertEqual(controller.savedWorkspace().sidebar?.tab.layout, sidebarLayout)
            XCTAssertTrue(controller.debugSidebarFocused)
            try controller.savedWorkspace().validate()
        }
    }

    @MainActor
    func testSidebarHorizontalResizePrefersInternalSplitAndFloatingPane() throws {
        let controller = Self.makeController()
        controller.toggleSidebar(nil)
        controller.debugFocusSidebarPane(try XCTUnwrap(controller.debugSidebarPaneIDs.first))
        let outer = try XCTUnwrap(controller.view as? WindowContentView)
        outer.moveSidebarDivider(by: 0.4)
        controller.splitPaneHorizontally(nil)
        let width = outer.sidebarView.frame.width
        XCTAssertTrue(controller.performKeybindingAction(.movePaneDividerLeft))
        let layout = try XCTUnwrap(controller.savedWorkspace().sidebar?.tab.layout)
        guard case let .split(_, _, fractions) = layout else { return XCTFail("Expected internal split") }
        assertFractionsEqual(fractions, [0.45, 0.55], accuracy: 0.0001)
        XCTAssertEqual(outer.sidebarView.frame.width, width, accuracy: 0.01)
        controller.debugToggleFloatingPane()
        let floatingWidth = outer.sidebarFloatingView.floatingPaneTargetFrame().width
        XCTAssertTrue(controller.performKeybindingAction(.movePaneDividerLeft))
        XCTAssertEqual(outer.sidebarFloatingView.floatingPaneTargetFrame().width, floatingWidth - WorkspaceFloatingPaneConfiguration.resizeStep, accuracy: 0.01)
        XCTAssertEqual(outer.sidebarView.frame.width, width, accuracy: 0.01)
        XCTAssertEqual(controller.savedWorkspace().sidebar?.tab.layout, layout)
        try controller.savedWorkspace().validate()
    }

    @MainActor
    func testSidebarPaneKindsFloatAtWindowCenterAndReturnToTheirLayout() throws {
        for addPane: (WorkspaceViewController) -> Void in [
            { $0.toggleSidebar(nil) }, { $0.addSidebarBrowser(nil) },
            { $0.addSidebarWorkspaces(nil) }, { $0.addSidebarAgents(nil) },
        ] {
            let controller = Self.makeController()
            let mainLayout = controller.debugLayoutNode
            addPane(controller)
            let id = try XCTUnwrap(controller.debugSidebarFocusedPaneID)
            controller.debugFocusSidebarPane(id)
            let outer = try XCTUnwrap(controller.view as? WindowContentView)
            let pane = try XCTUnwrap(controller.debugSidebarPane(id))
            let originalFrame = pane.hostView.convert(pane.hostView.bounds, to: outer)
            let layout = controller.savedWorkspace().sidebar?.tab.layout
            let menu = NSMenuItem(title: "Float", action: #selector(WorkspaceViewController.toggleFloatingPane(_:)), keyEquivalent: "")
            XCTAssertTrue(controller.validateMenuItem(menu))
            XCTAssertEqual(controller.debugCommandSnapshots.first { $0.id == "pane.floating.toggle" }?.isEnabled, true)

            controller.debugToggleFloatingPane()
            outer.layoutSubtreeIfNeeded()
            let frame = pane.hostView.convert(pane.hostView.bounds, to: outer)
            XCTAssertEqual(frame.midX, outer.bounds.midX, accuracy: 0.01)
            XCTAssertEqual(frame.midY, outer.bounds.midY, accuracy: 0.01)
            XCTAssertTrue(outer.sidebarView.paneViews[id] is TerminalPanePlaceholderView)
            XCTAssertTrue(outer.sidebarFloatingView.debugHitIsInsideFloatingPane(at: outer.sidebarFloatingView.convert(NSPoint(x: frame.midX, y: frame.midY), from: outer)))
            let outside = NSPoint(x: outer.sidebarFloatingView.frame.minX + 1, y: outer.sidebarFloatingView.frame.minY + 1)
            XCTAssertNil(outer.sidebarFloatingView.hitTest(outside))
            outer.needsLayout = true
            outer.layoutSubtreeIfNeeded()
            XCTAssertTrue(pane.hostView.isDescendant(of: outer.sidebarFloatingView))
            XCTAssertTrue(controller.debugSidebarFocused)
            XCTAssertEqual(controller.savedWorkspace().sidebar?.tab.floating?.paneID, id)
            XCTAssertEqual(controller.savedWorkspace().sidebar?.tab.layout, layout)
            XCTAssertEqual(controller.debugLayoutNode, mainLayout)
            try controller.savedWorkspace().validate()

            controller.debugToggleFloatingPane()
            XCTAssertNil(outer.sidebarFloatingView.debugFloatingPaneFrame)
            XCTAssertTrue(outer.sidebarView.paneViews[id] === pane.hostView)
            assertRectsEqual(pane.hostView.convert(pane.hostView.bounds, to: outer), originalFrame, accuracy: 0.01)
            XCTAssertTrue(controller.debugSidebarPane(id) === pane)
            try controller.savedWorkspace().validate()
        }
    }

    @MainActor
    func testSidebarFloatingSizeAndPresentationRestoreAcrossMainTabsAndSnapshots() throws {
        let controller = Self.makeController()
        controller.addSidebarBrowser(nil)
        let id = try XCTUnwrap(controller.debugSidebarFocusedPaneID)
        controller.debugToggleFloatingPane()
        controller.movePaneDividerRight(nil)
        let size = try XCTUnwrap(controller.savedWorkspace().sidebar?.tab.floating?.size)
        let pane = try XCTUnwrap(controller.debugSidebarPane(id))
        controller.debugNewTab()
        controller.newWorkspace(nil)
        XCTAssertTrue(controller.debugSidebarPane(id) === pane)
        let outer = try XCTUnwrap(controller.view as? WindowContentView)
        XCTAssertTrue(pane.hostView.isDescendant(of: outer.sidebarFloatingView))
        let document = try JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(controller.savedWorkspace()))
        try document.validate()
        let restored = Self.makeController()
        try restored.restoreWorkspace(document)
        let restoredOuter = try XCTUnwrap(restored.view as? WindowContentView)
        let restoredPane = try XCTUnwrap(restored.debugSidebarPane(id))
        XCTAssertTrue(restoredPane.hostView.isDescendant(of: restoredOuter.sidebarFloatingView))
        XCTAssertEqual(restored.savedWorkspace().sidebar?.tab.floating?.size, size)
        restored.debugFocusSidebarPane(id)
        restored.debugToggleFloatingPane()
        restored.debugToggleFloatingPane()
        XCTAssertEqual(restored.savedWorkspace().sidebar?.tab.floating?.size, size)
        try restored.savedWorkspace().validate()
    }

    @MainActor
    func testSidebarFloatingPaneClearsOnFocusSplitHideAndClose() throws {
        let controller = Self.makeController()
        controller.addSidebarBrowser(nil)
        let first = try XCTUnwrap(controller.debugSidebarFocusedPaneID)
        controller.addSidebarAgents(nil)
        let second = try XCTUnwrap(controller.debugSidebarFocusedPaneID)
        let outer = try XCTUnwrap(controller.view as? WindowContentView)
        controller.debugToggleFloatingPane()
        controller.debugFocusSidebarPane(first)
        XCTAssertNil(outer.sidebarFloatingView.debugFloatingPaneFrame)
        XCTAssertNil(controller.savedWorkspace().sidebar?.tab.floating)
        controller.debugToggleFloatingPane()
        controller.splitPaneVertically(nil)
        XCTAssertNil(outer.sidebarFloatingView.debugFloatingPaneFrame)
        XCTAssertNil(controller.savedWorkspace().sidebar?.tab.floating)
        controller.debugFocusSidebarPane(first)
        controller.debugToggleFloatingPane()
        controller.toggleSidebar(nil)
        XCTAssertNil(outer.sidebarFloatingView.debugFloatingPaneFrame)
        XCTAssertFalse(controller.debugSidebarFocused)
        controller.toggleSidebar(nil)
        controller.debugFocusSidebarPane(second)
        controller.debugToggleFloatingPane()
        controller.closePane(nil)
        XCTAssertNil(outer.sidebarFloatingView.debugFloatingPaneFrame)
        XCTAssertNil(controller.debugSidebarPane(second))
        try controller.savedWorkspace().validate()
    }

    @MainActor
    func testSidebarClosingLastPaneHidesAndReopensDefaults() async throws {
        let controller = Self.makeController()
        controller.toggleSidebar(nil)
        for id in controller.debugSidebarPaneIDs {
            controller.debugFocusSidebarPane(id)
            controller.debugPerformClosePane(withID: id)
        }
        for _ in 0..<100 where controller.debugSidebarVisible {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.debugSidebarVisible)
        XCTAssertFalse(controller.debugSidebarFocused)
        XCTAssertEqual(controller.debugTabIDs.count, 1)
        try controller.savedWorkspace().validate()
        controller.toggleSidebar(nil)
        XCTAssertEqual(controller.debugSidebarPaneIDs.count, 1)
        XCTAssertTrue(controller.debugSidebarPane(controller.debugSidebarPaneIDs[0]) is TerminalPaneController)
    }

    @MainActor
    func testSidebarSnapshotRestoresListsAndBrowserWithIndependentFocus() throws {
        let controller = Self.makeController()
        controller.moveSidebarRight(nil)
        controller.addSidebarBrowser(nil)
        let ids = controller.debugSidebarPaneIDs
        let encoded = try JSONEncoder().encode(controller.savedWorkspace())
        let document = try JSONDecoder().decode(SavedWorkspace.self, from: encoded)
        XCTAssertGreaterThanOrEqual(document.sidebar?.preferredWidth ?? 0, 240)
        XCTAssertTrue(document.sidebar?.tab.autoResize.isEmpty == true)
        try document.validate()
        let restored = Self.makeController()
        try restored.restoreWorkspace(document)
        XCTAssertEqual(restored.debugSidebarPaneIDs, ids)
        XCTAssertTrue(restored.debugSidebarFocused)
        XCTAssertTrue(restored.debugSidebarVisible)
        XCTAssertEqual(restored.debugSidebarSide, .right)
        XCTAssertTrue(restored.debugFocusedPaneIsBrowser)
        XCTAssertEqual(restored.debugTabIDs, controller.debugTabIDs)
        XCTAssertEqual(restored.savedWorkspace().sidebar?.tab.panes.map(\.kind), document.sidebar?.tab.panes.map(\.kind))
    }

    @MainActor
    func testSidebarSnapshotRejectsCrossOwnerIDsAndUnsafeState() throws {
        let controller = Self.makeController()
        controller.toggleSidebar(nil)
        let original = controller.savedWorkspace()
        var invalid = original
        invalid.sidebar?.preferredWidth = .infinity
        XCTAssertThrowsError(try invalid.validate())
        invalid = original
        invalid.sidebar?.tab = try XCTUnwrap(original.tabs.first)
        XCTAssertThrowsError(try invalid.validate())
        invalid = original
        invalid.sidebar?.isVisible = false
        invalid.sidebarIsFocused = true
        XCTAssertThrowsError(try invalid.validate())
        invalid = original
        let sidebarPane = try XCTUnwrap(original.sidebar?.tab.panes.first)
        invalid.sidebar?.tab.panes = [.init(id: sidebarPane.id, kind: .herdrTerminal, title: "Remote",
            herdr: .init(coreID: "remote-core", address: "t1", remote: true))]
        XCTAssertThrowsError(try invalid.validate())
        invalid = original
        invalid.sidebar?.tab.panes[0].herdr = .init(coreID: "local-core", address: "../t1")
        XCTAssertThrowsError(try invalid.validate())
        invalid = original
        invalid.sidebar?.tab.panes[0].herdrViewer = true
        XCTAssertThrowsError(try invalid.validate())
        invalid = original
        invalid.sidebar?.tab.panes[0].title = String(repeating: "x", count: 1025)
        XCTAssertThrowsError(try invalid.validate())
        invalid = original
        invalid.version = 7
        XCTAssertThrowsError(try invalid.validate())

    }

    @MainActor
    func testHiddenSidebarIsExcludedFromDirectionalFocusAndCLI() throws {
        let controller = Self.makeController()
        controller.toggleSidebar(nil)
        let tabIDs = controller.debugTabIDs
        controller.toggleSidebar(nil)
        controller.focusLeftPane(nil)
        XCTAssertFalse(controller.debugSidebarFocused)
        let response = try controller.handleCLIRequest(CLIRequest(command: "list"))
        XCTAssertEqual(response.tabs?.map(\.id), tabIDs)
        XCTAssertEqual(response.tabs?.flatMap(\.panes).count, 1)
    }
}

extension WorkspaceViewControllerTests {
    @MainActor
    func testNewWorkspacesPaneNavigatesRefreshesAndRestoresInMainArea() throws {
        let controller = Self.makeController()
        let original = controller.debugSelectedWorkspace
        let command = try XCTUnwrap(controller.commandPaletteCommands.first { $0.id == "pane.workspaces.new" })
        XCTAssertEqual(command.title, "New Workspaces Pane")
        XCTAssertTrue(command.isEnabled)
        command.perform()
        let paneID = try XCTUnwrap(controller.debugFocusedPaneID)
        XCTAssertEqual(try controller.handleCLIRequest(.init(command: "list")).tabs?.flatMap(\.panes).first { $0.id == paneID }?.kind, "workspaces")
        XCTAssertTrue(controller.paletteNavigationItems.contains { $0.kind == .pane && $0.title == "Workspaces" && $0.symbol == "list.bullet" })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let list = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityLabel() == "Workspace list" })
        controller.newWorkspace(nil)
        let other = controller.debugSelectedWorkspace
        controller.selectLocalWorkspace(original)
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 36))
        list.keyDown(with: down)
        list.keyDown(with: enter)
        XCTAssertEqual(controller.debugSelectedWorkspace, other)
        let saved = try JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(controller.savedWorkspace()))
        let restored = Self.makeController()
        try restored.restoreWorkspace(saved)
        restored.selectLocalWorkspace(original)
        XCTAssertEqual(restored.savedWorkspace().tabs.flatMap(\.panes).first { $0.id == paneID }?.kind, .workspaces)
        XCTAssertTrue(descendants(restored.view).contains { $0.accessibilityLabel() == "Workspace list" })
    }

    @MainActor
    func testNewPaneTypesChooseSplitAxisFromFocusedPaneSize() throws {
        let actions: [(SavedWorkspace.Pane.Kind, (WorkspaceViewController) -> Void)] = [
            (.localTerminal, { $0.newTerminalPane(nil) }),
            (.browser, { $0.newBrowserPane(nil) }),
            (.agents, { $0.newAgentsPane(nil) }),
            (.workspaces, { $0.newWorkspacesPane(nil) }),
        ]
        for (sidebar, size, axis) in [
            (false, NSSize(width: 1200, height: 800), SplitAxis.horizontal),
            (false, NSSize(width: 700, height: 1200), .vertical),
            (false, NSSize(width: 900, height: 940), .horizontal),
            (true, NSSize(width: 1200, height: 800), .vertical),
            (true, NSSize(width: 1200, height: 250), .horizontal),
        ] {
            for (kind, create) in actions {
                let controller = Self.makeController()
                controller.view.setFrameSize(size)
                controller.view.layoutSubtreeIfNeeded()
                let mainLayout = controller.debugLayoutNode
                if sidebar {
                    controller.toggleSidebar(nil)
                    controller.debugFocusSidebarPane(try XCTUnwrap(controller.debugSidebarPaneIDs.first))
                }
                let anchor = try XCTUnwrap(sidebar ? controller.debugSidebarFocusedPaneID : controller.debugFocusedPaneID)
                create(controller)
                let saved = controller.savedWorkspace()
                let tab = try XCTUnwrap(sidebar ? saved.sidebar?.tab : saved.tabs.first)
                XCTAssertEqual(tab.panes.count, 2, "\(sidebar) \(kind) \(size)")
                XCTAssertEqual(tab.layout?.parentSplitContext(for: anchor)?.axis, axis, "\(sidebar) \(kind) \(size)")
                XCTAssertEqual(tab.panes.first { $0.id == tab.focusedPaneID }?.kind, sidebar && kind == .localTerminal ? .herdrTerminal : kind)
                if sidebar { XCTAssertEqual(controller.debugLayoutNode, mainLayout) }
                try saved.validate()
            }
        }
    }

    @MainActor
    func testSidebarStartsWithLocalHerdrTerminalAndAllowsExplicitSplits() throws {
        let controller = Self.makeController()
        let mainLayout = controller.debugLayoutNode
        controller.toggleSidebar(nil)
        let first = try XCTUnwrap(controller.debugSidebarPaneIDs.first)
        let terminal = try XCTUnwrap(controller.debugSidebarPane(first) as? TerminalPaneController)
        XCTAssertNotNil(terminal.herdrSession)
        XCTAssertNil(terminal.herdrSession?.remote)
        controller.debugFocusSidebarPane(first)
        XCTAssertTrue(controller.commandPaletteCommands.first { $0.id == "pane.split.horizontal" }?.isEnabled == true)
        controller.splitPaneHorizontally(nil)
        XCTAssertEqual(controller.debugSidebarPaneIDs.count, 2)
        XCTAssertEqual(controller.savedWorkspace().sidebar?.tab.layout?.parentSplitContext(for: first)?.axis, .horizontal)
        controller.debugFocusSidebarPane(first)
        controller.splitPaneVertically(nil)
        XCTAssertEqual(controller.debugSidebarPaneIDs.count, 3)
        XCTAssertEqual(controller.savedWorkspace().sidebar?.tab.layout?.parentSplitContext(for: first)?.axis, .vertical)
        XCTAssertEqual(controller.debugLayoutNode, mainLayout)
        XCTAssertTrue(controller.savedWorkspace().sidebar?.tab.autoResize.isEmpty == true)
        XCTAssertTrue(controller.savedWorkspace().sidebar?.tab.panes.allSatisfy { $0.kind == .herdrTerminal } == true)
        try controller.savedWorkspace().validate()
    }

    @MainActor
    func testSidebarAddCommandsChooseAxisWhenReopened() throws {
        let actions: [(WorkspaceViewController) -> Void] = [
            { $0.addSidebarBrowser(nil) }, { $0.addSidebarWorkspaces(nil) }, { $0.addSidebarAgents(nil) },
        ]
        for (height, axis) in [(CGFloat(250), SplitAxis.horizontal), (800, .vertical)] {
            for create in actions {
                let controller = Self.makeController()
                controller.toggleSidebar(nil)
                let anchor = try XCTUnwrap(controller.debugSidebarPaneIDs.first)
                controller.toggleSidebar(nil)
                controller.view.setFrameSize(NSSize(width: 1200, height: height))
                create(controller)
                XCTAssertTrue(controller.debugSidebarVisible)
                XCTAssertEqual(controller.savedWorkspace().sidebar?.tab.layout?.parentSplitContext(for: anchor)?.axis, axis)
            }
        }
    }

    @MainActor
    func testSidebarTerminalRestoresLocalCoreBindingInRemoteWorkspace() throws {
        let controller = Self.makeController()
        controller.toggleSidebar(nil)
        var saved = controller.savedWorkspace()
        saved.workspaceKind = .herdr
        saved.herdrRemote = .init(id: "remote-core", name: "Remote")
        saved.tabs[0].panes = saved.tabs[0].panes.map {
            .init(id: $0.id, kind: .herdrTerminal, name: $0.name, title: $0.title)
        }
        let binding = HerdrTerminalBinding(coreID: "local-core", address: "t1")
        saved.sidebar?.tab.panes[0].herdr = binding
        let decoded = try JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(saved))
        let restored = Self.makeController()
        try restored.restoreWorkspace(decoded)
        let id = try XCTUnwrap(restored.debugSidebarPaneIDs.first)
        let terminal = try XCTUnwrap(restored.debugSidebarPane(id) as? TerminalPaneController)
        XCTAssertEqual(terminal.herdrSession?.binding, binding)
        XCTAssertNil(terminal.herdrSession?.remote)
        restored.debugFocusSidebarPane(id)
        restored.newTerminalPane(nil)
        XCTAssertTrue(restored.savedWorkspace().sidebar?.tab.panes.allSatisfy { $0.kind == .herdrTerminal } == true)
        for id in restored.debugSidebarPaneIDs {
            let pane = try XCTUnwrap(restored.debugSidebarPane(id) as? TerminalPaneController)
            XCTAssertNil(pane.herdrSession?.remote)
        }
        try restored.savedWorkspace().validate()
    }

    @MainActor
    func testPreviousLocalSidebarRequiresExplicitStartIntoCore() throws {
        let controller = Self.makeController()
        controller.toggleSidebar(nil)
        var saved = controller.savedWorkspace()
        let pane = try XCTUnwrap(saved.sidebar?.tab.panes.first)
        saved.sidebar?.tab.panes = [.init(id: pane.id, kind: .localTerminal, name: "Previous shell", title: pane.title, cwd: "/tmp")]
        let restored = Self.makeController()
        try restored.restoreWorkspace(saved)
        let placeholder = try XCTUnwrap(restored.debugSidebarPane(pane.id) as? RestoredPanePlaceholderController)
        XCTAssertEqual(placeholder.savedPane.kind, .localTerminal)
        placeholder.onActivate?()
        let terminal = try XCTUnwrap(restored.debugSidebarPane(pane.id) as? TerminalPaneController)
        XCTAssertNotNil(terminal.herdrSession)
        XCTAssertNil(terminal.herdrSession?.remote)
        XCTAssertEqual(terminal.currentWorkingDirectory, "/tmp")
        XCTAssertEqual(terminal.name, "Previous shell")
        XCTAssertFalse(terminal.hasStarted)
        try restored.savedWorkspace().validate()
    }

    @MainActor
    func testSidebarSharesWindowEdgePaddingWithMainPanes() throws {
        let controller = Self.makeController()
        defer { AppAppearanceSettings.resetWorkspaceEdgePadding() }
        let view = try XCTUnwrap(controller.view as? WindowContentView)
        controller.toggleSidebar(nil)

        for side in [SidebarSide.left, .right] {
            if side == .left { controller.moveSidebarLeft(nil) }
            else { controller.moveSidebarRight(nil) }
            for padding: CGFloat in [0, 8, 24] {
                AppAppearanceSettings.workspaceEdgePadding = padding
                view.layoutSubtreeIfNeeded()
                let sidebar = view.sidebarView.convert(view.sidebarView.bounds, to: view)
                let main = view.mainView.contentContainerView.convert(view.mainView.contentContainerView.bounds, to: view)
                let toolbar = view.mainView.toolbarView.convert(view.mainView.toolbarView.bounds, to: view)
                XCTAssertEqual(sidebar.minY, main.minY, accuracy: 0.01)
                XCTAssertEqual(sidebar.minY - toolbar.maxY, WorkspaceLayoutMetrics.workspaceSectionSpacing, accuracy: 0.01)
                XCTAssertEqual(sidebar.maxY, view.bounds.maxY - padding, accuracy: 0.01)
                XCTAssertEqual(main.maxY, sidebar.maxY, accuracy: 0.01)
                XCTAssertEqual(toolbar.minY, padding, accuracy: 0.01)
                XCTAssertEqual(toolbar.minX, padding, accuracy: 0.01)
                XCTAssertEqual(toolbar.maxX, view.bounds.maxX - padding, accuracy: 0.01)
                let point = NSPoint(x: sidebar.midX, y: toolbar.midY)
                let hit = try XCTUnwrap(view.hitTest(point))
                XCTAssertTrue(hit === view.mainView.toolbarView || hit.isDescendant(of: view.mainView.toolbarView))
                if side == .left {
                    XCTAssertEqual(sidebar.minX, padding, accuracy: 0.01)
                    XCTAssertEqual(main.maxX, view.bounds.maxX - padding, accuracy: 0.01)
                    XCTAssertEqual(main.minX - sidebar.maxX, AppAppearanceSettings.workspaceDividerThickness, accuracy: 0.01)
                } else {
                    XCTAssertEqual(sidebar.maxX, view.bounds.maxX - padding, accuracy: 0.01)
                    XCTAssertEqual(main.minX, padding, accuracy: 0.01)
                    XCTAssertEqual(sidebar.minX - main.maxX, AppAppearanceSettings.workspaceDividerThickness, accuracy: 0.01)
                }
            }
        }
        controller.toggleSidebar(nil)
        view.layoutSubtreeIfNeeded()
        let main = view.mainView.convert(view.mainView.bounds, to: view)
        assertRectsEqual(main, view.bounds.insetBy(dx: 24, dy: 24), accuracy: 0.01)
    }

    @MainActor
    func testSidebarMinimumWindowHeightIncludesBottomToolbar() throws {
        let controller = Self.makeController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 1200), styleMask: [], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        controller.toggleSidebar(nil)
        controller.debugFocusSidebarPane(try XCTUnwrap(controller.debugSidebarPaneIDs.first))
        for _ in 0..<4 { controller.splitPaneVertically(nil) }
        let layout = try XCTUnwrap(controller.savedWorkspace().sidebar?.tab.layout)
        let expectedHeight = layout.minimumSize(dividerThickness: AppAppearanceSettings.workspaceDividerThickness).height
            + WorkspaceLayoutMetrics.tabStripHeight + WorkspaceLayoutMetrics.workspaceSectionSpacing
            + AppAppearanceSettings.workspaceEdgePadding * 2
        XCTAssertEqual(window.contentMinSize.height, expectedHeight, accuracy: 0.01)
    }

    @MainActor
    func testSidebarWidthUsesPointsAndPreservesPreferenceAfterWindowClamp() throws {
        let view = WindowContentView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let state = WindowSidebarState()
        state.isVisible = true
        view.updateMinimumWidths(main: 500, sidebar: 240)
        view.updateSidebar(state)
        XCTAssertEqual(view.sidebarView.frame.width, 280, accuracy: 0.01)
        view.frame.size.width = 800
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(view.mainView.contentContainerView.frame.width, 500)
        XCTAssertGreaterThanOrEqual(view.sidebarView.frame.width, 240)
        view.frame.size.width = 10000
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.sidebarView.frame.width, 280, accuracy: 0.01)
        XCTAssertEqual(state.preferredWidth, 280)
        state.side = .right
        view.updateSidebar(state)
        XCTAssertEqual(view.sidebarView.frame.width, 280, accuracy: 0.01)
        XCTAssertEqual(view.sidebarView.frame.maxY, view.mainView.contentContainerView.frame.maxY)
    }

    @MainActor
    func testSidebarWidthOnlyPersistsExplicitDividerChanges() throws {
        let view = WindowContentView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let state = WindowSidebarState(); state.isVisible = true
        view.updateSidebar(state)
        let outer = try XCTUnwrap(view.mainView.contentLayoutView.subviews.first as? WorkspaceTilingView)
        var widths: [CGFloat] = []
        view.onWidthChange = { widths.append($0) }
        outer.onFractionsChange?([], [0.3, 0.7], .layoutClamp)
        XCTAssertTrue(widths.isEmpty)
        outer.onFractionsChange?([], [0.3, 0.7], .userDrag)
        XCTAssertEqual(try XCTUnwrap(widths.last), 0.3 * (1200 - AppAppearanceSettings.workspaceEdgePadding * 2 - AppAppearanceSettings.workspaceDividerThickness), accuracy: 0.01)
    }

    @MainActor
    func testSidebarWorkspaceListNavigatesMainAndRejectsMissingTargets() throws {
        let controller = Self.makeController()
        let original = controller.debugSelectedWorkspace
        controller.newWorkspace(nil)
        let other = controller.debugSelectedWorkspace
        controller.addSidebarWorkspaces(nil)
        let id = try XCTUnwrap(controller.debugSidebarPaneIDs.first)
        let pane = try XCTUnwrap(controller.debugSidebarPane(id) as? SidebarListPaneController)
        controller.debugFocusSidebarPane(id)
        pane.onSelectWorkspace?(original)
        XCTAssertEqual(controller.debugSelectedWorkspace, original)
        XCTAssertFalse(controller.debugSidebarFocused)
        controller.debugFocusSidebarPane(id)
        pane.onSelectWorkspace?(UUID())
        XCTAssertEqual(controller.debugSelectedWorkspace, original)
        XCTAssertTrue(controller.debugSidebarFocused)
        pane.onSelectWorkspace?(other)
        XCTAssertEqual(controller.debugSelectedWorkspace, other)
        XCTAssertTrue(controller.debugSidebarPane(id) === pane)
    }

}

extension WorkspaceViewControllerTests {
    @MainActor
    func testStalePaneAndTabTargetsCannotStealSidebarFocus() throws {
        let controller = Self.makeController()
        controller.toggleSidebar(nil)
        let paneID = try XCTUnwrap(controller.debugSidebarPaneIDs.first)
        controller.debugFocusSidebarPane(paneID)
        controller.debugFocusPane(withID: UUID())
        XCTAssertTrue(controller.debugSidebarFocused)
        controller.debugSelectTab(withID: UUID())
        XCTAssertTrue(controller.debugSidebarFocused)
        controller.selectLocalWorkspace(UUID())
        XCTAssertTrue(controller.debugSidebarFocused)
        XCTAssertEqual(controller.debugSidebarFocusedPaneID, paneID)
    }
}

extension WorkspaceViewControllerTests {
    @MainActor
    func testSidebarRestoresCanonicalFractionsBeforeWindowHasGeometry() throws {
        let original = Self.makeController()
        original.toggleSidebar(nil)
        original.addSidebarWorkspaces(nil)
        var saved = original.savedWorkspace()
        let ids = original.debugSidebarPaneIDs
        let layout = LayoutNode.split(axis: .vertical, children: ids.map { .panel($0) }, fractions: [0.8, 0.2])
        saved.sidebar?.tab.layout = layout
        let restored = WorkspaceViewController()
        restored.loadViewIfNeeded()
        try restored.restoreWorkspace(saved)
        XCTAssertEqual(restored.savedWorkspace().sidebar?.tab.layout, layout)
        restored.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        restored.view.needsLayout = true
        restored.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(restored.savedWorkspace().sidebar?.tab.layout, layout)
        let outer = try XCTUnwrap(restored.view as? WindowContentView)
        XCTAssertEqual(outer.sidebarView.paneViews.count, 2)
        restored.view.frame.size.height = 350
        restored.view.needsLayout = true
        restored.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(restored.savedWorkspace().sidebar?.tab.layout, layout)
        restored.view.frame.size.height = 1000
        restored.view.needsLayout = true
        restored.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(restored.savedWorkspace().sidebar?.tab.layout, layout)
        let top = try XCTUnwrap(restored.debugSidebarPane(ids[0]))
        XCTAssertEqual(top.hostView.frame.height / (outer.sidebarView.bounds.height - AppAppearanceSettings.workspaceDividerThickness), 0.8, accuracy: 0.01)
    }
}

extension WorkspaceViewControllerTests {
    @MainActor
    func testSidebarOuterDividerDragUpdatesSnapshotAndHonorsMainMinimum() throws {
        let controller = Self.makeController()
        controller.toggleSidebar(nil)
        let windowView = try XCTUnwrap(controller.view as? WindowContentView)
        let outer = try XCTUnwrap(windowView.mainView.contentLayoutView.subviews.first as? WorkspaceTilingView)
        outer.debugApplyDragForDivider(at: [], dividerIndex: 0, location: NSPoint(x: 400, y: 400))
        XCTAssertGreaterThan(windowView.sidebarView.frame.width, 280)
        XCTAssertEqual(try XCTUnwrap(controller.savedWorkspace().sidebar?.preferredWidth), windowView.sidebarView.frame.width, accuracy: 0.01)
        controller.debugSplitFocusedPane(along: .horizontal)
        controller.view.layoutSubtreeIfNeeded()
        outer.debugApplyDragForDivider(at: [], dividerIndex: 0, location: NSPoint(x: 1150, y: 400))
        let minimum = try XCTUnwrap(controller.debugLayoutNode).minimumSize().width
        XCTAssertGreaterThanOrEqual(windowView.mainView.contentContainerView.frame.width + 0.01, minimum)
        XCTAssertEqual(try XCTUnwrap(controller.savedWorkspace().sidebar?.preferredWidth), windowView.sidebarView.frame.width, accuracy: 0.01)
        try controller.savedWorkspace().validate()
    }
}

extension WorkspaceViewControllerTests {
    @MainActor
    func testWorkspaceListControlNavigationFromPaneAndTable() throws {
        let pane = SidebarListPaneController()
        let entries = [WorkspaceEntry(reference: UUID(), name: "First"), WorkspaceEntry(reference: UUID(), name: "Second")]
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = try XCTUnwrap(descendants(pane.hostView).compactMap { $0 as? NSTableView }.first)
        var activated: [UUID] = []
        pane.onSelectWorkspace = { activated.append($0) }
        func key(_ character: String, code: UInt16, on responder: NSResponder) throws {
            responder.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil,
                characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)))
        }
        for responder in [pane.focusTargetView, table] {
            pane.update(entries: entries, selected: entries[0].reference)
            try key("p", code: 35, on: responder)
            XCTAssertEqual(table.selectedRow, 0)
            try key("n", code: 45, on: responder)
            XCTAssertEqual(table.selectedRow, 1)
            try key("n", code: 45, on: responder)
            XCTAssertEqual(table.selectedRow, 1)
            try key("p", code: 35, on: responder)
            XCTAssertEqual(table.selectedRow, 0)
            XCTAssertTrue(activated.isEmpty, "Navigation must not activate a workspace")
            pane.update(entries: [], selected: nil)
            try key("n", code: 45, on: responder)
            try key("p", code: 35, on: responder)
            XCTAssertEqual(table.selectedRow, -1)
        }
    }

    @MainActor
    func testWorkspaceListCardsKeepCurrentWorkspaceAndRemoteDetailsDuringKeyboardSelection() throws {
        let pane = SidebarListPaneController()
        pane.hostView.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
        pane.fitToSize()
        let first = WorkspaceEntry(reference: UUID(), name: "Local")
        let second = WorkspaceEntry(reference: UUID(), name: "Remote", kind: .herdr, remote: .init(id: "remote-core", name: "Server"))
        pane.update(entries: [first, second], selected: first.reference)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = try XCTUnwrap(descendants(pane.hostView).compactMap { $0 as? NSTableView }.first)
        func cell(_ row: Int) throws -> NSView { try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true)) }
        XCTAssertEqual(try cell(0).accessibilityLabel(), "Local, Local Workspace, Current")
        XCTAssertEqual(try cell(1).accessibilityLabel(), "Remote, Herdr · Server")
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
        pane.focusTargetView.keyDown(with: down)
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertEqual(try cell(0).accessibilityLabel(), "Local, Local Workspace, Current")
        pane.update(entries: [second, first], selected: second.reference)
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertEqual(try cell(0).accessibilityLabel(), "Remote, Herdr · Server, Current")
        XCTAssertEqual(try cell(1).accessibilityLabel(), "Local, Local Workspace")
    }

    @MainActor
    func testSidebarWorkspaceListKeyboardSelectionTracksStableIdentity() throws {
        let controller = Self.makeController()
        controller.addSidebarWorkspaces(nil)
        let pane = try XCTUnwrap(controller.debugSidebarPane(try XCTUnwrap(controller.debugSidebarPaneIDs.first)) as? SidebarListPaneController)
        let first = WorkspaceEntry(reference: UUID(), name: "First")
        let second = WorkspaceEntry(reference: UUID(), name: "Second")
        var selected: [UUID] = []
        var cancelled = false
        pane.onSelectWorkspace = { selected.append($0) }
        pane.onCancel = { cancelled = true }
        func key(_ code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
            pane.focusTargetView.keyDown(with: event)
        }
        pane.update(entries: [first, second], selected: first.reference)
        try key(125); try key(36)
        XCTAssertEqual(selected, [second.reference])
        pane.update(entries: [first, second], selected: first.reference)
        try key(36)
        XCTAssertEqual(selected.last, second.reference)
        pane.update(entries: [first], selected: first.reference)
        try key(36)
        XCTAssertEqual(selected.last, first.reference)
        pane.update(entries: [], selected: nil)
        try key(125); try key(126); try key(36)
        XCTAssertEqual(selected.count, 3)
        try key(53)
        XCTAssertTrue(cancelled)
    }
}
