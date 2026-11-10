import AppKit
import GhosttyTerminal
import XCTest
@testable import Santty

@MainActor
final class AgentSessionTests: XCTestCase {
    private let binding = HerdrTerminalBinding(coreID: "core-a", address: "t1")
    private func terminal(_ word: String?, app: String = "codex", records: [String: HerdrProgramStatus] = [:],
                          state: String = "live", turn: UInt64 = 0) -> HerdrCoreTerminal {
        .init(address: "t1", pid: 123, title: "Review", cwd: "/srv/project", state: state,
              cols: 80, rows: 24, status: word.map { .init(state: $0, app: app, title: "Task", msg: "Review ready") },
              records: records, reported: true, turn: turn)
    }

    func testBaselineOrderedEventsAndTurnNeverMisclassifyBlockedOrIdleAsComplete() throws {
        let store = AgentSessionStore()
        var notices: [AgentMessage] = []
        store.onNotification = { notices.append($0) }
        store.replaceSnapshot([(binding, terminal("done", turn: 9))])
        XCTAssertTrue(store.messages.isEmpty)
        store.apply(terminal("working", turn: 9), binding: binding)
        store.apply(terminal("blocked", turn: 9), binding: binding)
        store.apply(terminal("blocked", turn: 10), binding: binding)
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.state, .waitingForUser)
        XCTAssertEqual(store.unreadCount, 1)
        let oldScene = try XCTUnwrap(store.snapshots.first)
        store.apply(terminal("working", turn: 10), binding: binding)
        store.apply(terminal("idle", turn: 11), binding: binding)
        XCTAssertEqual(notices.count, 1, "Idle may mean interruption; a turn increment alone is not completion")
        store.apply(terminal("working", turn: 11), binding: binding)
        store.apply(terminal("done", turn: 12), binding: binding)
        store.apply(terminal("done", turn: 12), binding: binding)
        XCTAssertEqual(notices.count, 2)
        store.markViewed([oldScene])
        XCTAssertEqual(store.unreadCount, 2, "An old scene cannot acknowledge a newer report")
        store.markViewed(store.snapshots)
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertEqual(store.snapshots.first?.displayState, .idle)
        store.clearEnded()
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.snapshots.count, 1)
    }

    func testReconnectMissedSnapshotAndCoreIdentityPreserveMessagesWithoutReplay() throws {
        let store = AgentSessionStore()
        var notices = 0
        store.onNotification = { _ in notices += 1 }
        store.replaceSnapshot([(binding, terminal("working"))])
        store.apply(terminal("done", turn: 1), binding: binding)
        store.markUnavailable()
        XCTAssertFalse(try XCTUnwrap(store.snapshots.first).backendStatusAvailable)
        store.replaceSnapshot([(binding, terminal("error", turn: 2))])
        XCTAssertEqual(notices, 1)
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.snapshots.first?.displayState, .failed)
        let second = HerdrTerminalBinding(coreID: "core-b", address: "t1", remote: true)
        store.replaceSnapshot([(second, terminal("working"))])
        XCTAssertEqual(store.snapshots.count, 2)
        XCTAssertFalse(try XCTUnwrap(store.snapshots.first { $0.binding.coreID == "core-a" }).backendStatusAvailable)
        store.apply(terminal("blocked", app: "opencode"), binding: second)
        XCTAssertEqual(notices, 2)
        XCTAssertEqual(store.snapshots.first?.agent.rawValue, "opencode")
        store.remove(second)
        let message = try XCTUnwrap(store.messageSnapshots.first)
        store.acknowledge(message)
        XCTAssertEqual(store.unreadCount, 1, "An ended or unavailable message can still be explicitly read")
    }

    func testChildRecordsVisibilityUnknownStatesAndBoundedMessages() throws {
        let store = AgentSessionStore()
        store.isTargetVisible = { _ in true }
        var notices = 0
        store.onNotification = { _ in notices += 1 }
        store.replaceSnapshot([(binding, terminal("working", records: ["reviewer": .init(state: "idle", app: "custom-agent")]))])
        store.apply(terminal("working", records: ["reviewer": .init(state: "blocked", app: "custom-agent", msg: "Permission?")]), binding: binding)
        XCTAssertEqual(store.snapshots.count, 2)
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(notices, 0)
        XCTAssertEqual(store.snapshots.first?.agent.displayName, "custom-agent")
        store.apply(terminal("working"), binding: binding)
        XCTAssertFalse(store.snapshots.contains { $0.agent.rawValue == "custom-agent" })
        XCTAssertEqual(store.messages.first?.agent.rawValue, "custom-agent")
        for _ in 0..<260 {
            store.apply(terminal("working"), binding: binding)
            store.apply(terminal("done"), binding: binding)
        }
        XCTAssertEqual(store.messages.count, 256)
        let panel = AgentManagerView(sessions: store.snapshots)
        panel.updateSessions(store.snapshots, messages: store.messageSnapshots)
        XCTAssertFalse(panel.subviews.contains { $0 is NSSegmentedControl })
        let root = try XCTUnwrap(store.snapshots.first { !$0.id.hasSuffix("helper") && $0.agent == .codex })
        XCTAssertEqual(panel.messagesForAgent(root.id).count, 256)
        store.apply(terminal("future-state", app: "unknown-tool"), binding: binding)
        XCTAssertEqual(store.snapshots.first { $0.agent.rawValue == "unknown-tool" }?.displayState, .unknown)
    }

    func testEndedAgentsLeaveTheListWithoutLosingMessages() throws {
        for ending in ["clear", "finished", "removed"] {
            let store = AgentSessionStore()
            store.apply(terminal("working"), binding: binding)
            store.apply(terminal("done"), binding: binding)
            let message = try XCTUnwrap(store.messageSnapshots.first)
            var changes = 0
            let observer = NotificationCenter.default.addObserver(
                forName: AgentSessionStore.didChangeNotification, object: store, queue: nil
            ) { _ in MainActor.assumeIsolated { changes += 1 } }
            defer { NotificationCenter.default.removeObserver(observer) }

            switch ending {
            case "clear": store.apply(terminal(nil), binding: binding)
            case "finished": store.apply(terminal("done", state: "finished"), binding: binding)
            default: store.remove(binding)
            }

            XCTAssertTrue(store.snapshots.isEmpty, "\(ending) must remove the agent from every list")
            XCTAssertEqual(changes, 1, "Open lists must refresh when the agent ends")
            XCTAssertEqual(store.messageSnapshots.map(\.id), [message.id])
            XCTAssertEqual(store.unreadCount, 1)
            store.acknowledge(message)
            XCTAssertEqual(store.unreadCount, 0)
            XCTAssertTrue(store.snapshots.isEmpty)
            store.apply(terminal("working"), binding: binding)
            XCTAssertEqual(store.snapshots.first?.displayState, .running)
        }
    }

    func testAgentBrandIconsRefreshWithoutReplacingMessageAnchorsOrStealingFocus() throws {
        let store = AgentSessionStore()
        store.apply(terminal("working"), binding: binding)
        let manager = AgentManagerView(sessions: store.snapshots)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 240), styleMask: [], backing: .buffered, defer: false)
        window.contentView = manager
        defer { window.contentView = nil }
        window.makeFirstResponder(manager)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let icon = try XCTUnwrap(descendants(manager).compactMap { $0 as? NSImageView }.first)
        let messages = try XCTUnwrap(descendants(manager).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier().hasPrefix("agent.messages.") })
        XCTAssertFalse(try XCTUnwrap(icon.image).isTemplate)
        for app in ["copilot", "future-tool", "claude-code"] {
            store.apply(terminal("working", app: app), binding: binding)
            manager.updateSessions(store.snapshots, messages: store.messageSnapshots)
            manager.layoutSubtreeIfNeeded()
            XCTAssertTrue(descendants(manager).contains { $0 === icon })
            XCTAssertTrue(descendants(manager).contains { $0 === messages })
            XCTAssertTrue(window.firstResponder === manager)
            if app == "future-tool" {
                XCTAssertTrue(try XCTUnwrap(icon.image).isTemplate)
            } else {
                XCTAssertEqual(icon.image?.isTemplate, app == "copilot")
            }
            if app == "claude-code" { XCTAssertNil(icon.contentTintColor) }
            else { XCTAssertNotNil(icon.contentTintColor) }
        }
    }

    func testStatusBadgesAlignDotsWithTextAndUseBlueForRunning() throws {
        let store = AgentSessionStore()
        store.apply(terminal("working"), binding: binding)
        let manager = AgentManagerView(sessions: store.snapshots)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 240),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = manager
        defer { window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

        for width: CGFloat in [240, 280, 480] {
            manager.setFrameSize(NSSize(width: width, height: 240))
            for state in ["working", "blocked", "done", "error", "idle", "future-state", "unavailable"] {
                if state == "unavailable" { store.markUnavailable() }
                else { store.apply(terminal(state), binding: binding) }
                manager.updateSessions(store.snapshots, messages: store.messageSnapshots)
                manager.layoutSubtreeIfNeeded()
                let badge = try XCTUnwrap(descendants(manager).compactMap { $0 as? AgentStatusBadgeView }.first)
                XCTAssertEqual(badge.text, store.snapshots.first?.statusText)
                let textWidth = (badge.text as NSString).size(withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                ]).width
                XCTAssertGreaterThanOrEqual(badge.bounds.width, ceil(textWidth) + 27, "Status must fit without truncation")
                XCTAssertNotNil(badge.layer?.backgroundColor)
                XCTAssertGreaterThan(badge.layer?.cornerRadius ?? 0, 0)
                let row = try XCTUnwrap(badge.superview)
                XCTAssertGreaterThanOrEqual(badge.frame.minX, 0)
                XCTAssertLessThanOrEqual(badge.frame.maxX, row.bounds.maxX)
                let title = try XCTUnwrap(row.subviews.compactMap { $0 as? NSTextField }.first)
                let messages = try XCTUnwrap(row.subviews.compactMap { $0 as? NSButton }
                    .first { $0.accessibilityIdentifier().hasPrefix("agent.messages.") })
                XCTAssertEqual(title.frame.maxX, row.bounds.maxX - 10)
                XCTAssertEqual(messages.frame.minX, title.frame.minX)
                XCTAssertEqual(messages.frame.midY, badge.frame.midY)
                XCTAssertLessThanOrEqual(messages.frame.maxX, badge.frame.minX)
                XCTAssertTrue(messages.imageHugsTitle, "The message icon should sit directly beside the count")
                XCTAssertEqual(messages.alignment, .left)
                XCTAssertFalse(messages.isBordered, "Messages should display only the icon and count")
                XCTAssertGreaterThanOrEqual(badge.frame.minY, 45)
                XCTAssertLessThanOrEqual(badge.frame.maxY, row.bounds.maxY - 4)
                let message = try XCTUnwrap(row.subviews.compactMap { $0 as? NSTextField }
                    .first { $0.stringValue == store.snapshots.first?.message })
                if !message.isHidden {
                    XCTAssertGreaterThanOrEqual(message.frame.minX, messages.frame.maxX + 8)
                    XCTAssertLessThanOrEqual(message.frame.maxX + 8, badge.frame.minX)
                }
                if state == "working" { XCTAssertEqual(badge.color, .systemBlue) }

                // Inspect the actual 2x rendered pixels, not the layout's own alignment formula.
                let pixelsWide = Int(ceil(badge.bounds.width * 2))
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: 44,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelsWide, height: 44))
                context.cgContext.scaleBy(x: 2, y: 2)
                badge.draw(badge.bounds)
                NSGraphicsContext.restoreGraphicsState()
                func inkRows(in columns: Range<Int>) -> [Int] {
                    (0..<44).filter { y in
                        columns.contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 }
                    }
                }
                let dotRows = inkRows(in: 16..<28)
                let textRows = inkRows(in: 38..<pixelsWide)
                let dotCenter = CGFloat(try XCTUnwrap(dotRows.first) + XCTUnwrap(dotRows.last)) / 2
                let textCenter = CGFloat(try XCTUnwrap(textRows.first) + XCTUnwrap(textRows.last)) / 2
                XCTAssertEqual(dotCenter, textCenter, accuracy: 1, "Rendered dot and text must align within half a point")
                if width == 280 {
                    let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                                   uniformTypeIdentifier: "public.png")
                    attachment.name = "Status badge — " + badge.text
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testMessageListTitlesUseFullWidthWithoutMessagesButton() throws {
        let store = AgentSessionStore()
        store.apply(terminal("done"), binding: binding)
        let manager = AgentManagerView(sessions: store.messageSnapshots, messageListTitle: "Messages")
        manager.setFrameSize(NSSize(width: 240, height: 240))
        manager.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let badge = try XCTUnwrap(descendants(manager).compactMap { $0 as? AgentStatusBadgeView }.first)
        let row = try XCTUnwrap(badge.superview)
        let title = try XCTUnwrap(row.subviews.compactMap { $0 as? NSTextField }.first)
        let messages = try XCTUnwrap(row.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier().hasPrefix("agent.messages.") })
        XCTAssertTrue(messages.isHidden)
        XCTAssertEqual(title.frame.maxX, row.bounds.maxX - 10)
        XCTAssertGreaterThan(badge.frame.minY, title.frame.maxY)
    }

    func testAllAgentTypesNotifyAndTargetsAreValidated() throws {
        let store = AgentSessionStore()
        for app in ["claude", "codex", "opencode"] {
            store.apply(terminal("blocked", app: app), binding: binding)
            let message = try XCTUnwrap(store.messages.last)
            let request = try XCTUnwrap(AgentNotifier.shared.request(for: message))
            XCTAssertEqual(request.identifier, "herdr.agent." + message.id)
            XCTAssertEqual(AgentNotifier.target(from: request.content.userInfo), binding)
            XCTAssertNotNil(request.content.sound)
        }
        XCTAssertNil(AgentNotifier.target(from: ["herdrTarget": "invalid"]))
        let invalid = try JSONEncoder().encode(HerdrTerminalBinding(coreID: "../core", address: "t1")).base64EncodedString()
        XCTAssertNil(AgentNotifier.target(from: ["herdrTarget": invalid]))
    }

    func testAgentsPanesPersistInMainAndSidebarAndReceiveSharedUpdates() throws {
        let client = HerdrCoreClient()
        let workspace = WorkspaceViewController()
        workspace.herdrCoreClient = client
        workspace.debugLoadForTesting()
        let selectedWorkspace = workspace.debugSelectedWorkspace
        workspace.newAgentsPane(nil)
        let mainID = try XCTUnwrap(workspace.debugFocusedPaneID)
        workspace.debugSetFocusedPaneName("Main Agents")
        workspace.addSidebarAgents(nil)
        let sidebarID = try XCTUnwrap(workspace.debugSidebarFocusedPaneID)
        workspace.debugSetFocusedPaneName("Sidebar Agents")
        XCTAssertTrue(workspace.debugSidebarPane(sidebarID) is AgentsPaneController)
        client.agents.apply(terminal("blocked"), binding: binding)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let managers = descendants(workspace.view).compactMap { $0 as? AgentManagerView }
        XCTAssertEqual(managers.count, 2)
        for manager in managers {
            XCTAssertTrue(descendants(manager).contains { $0.accessibilityLabel()?.hasPrefix("Codex, Waiting for You") == true })
        }
        XCTAssertEqual(try workspace.handleCLIRequest(.init(command: "list")).tabs?.flatMap(\.panes).first { $0.id == mainID }?.kind, "agents")
        XCTAssertTrue(workspace.paletteNavigationItems.contains { $0.kind == .pane && $0.title == "Main Agents" && $0.symbol == "sparkles" })
        workspace.newWorkspace(nil)
        XCTAssertEqual(workspace.debugSidebarPaneIDs, [sidebarID])
        workspace.selectWorkspace(selectedWorkspace)
        workspace.debugFocusSidebarPane(sidebarID)
        let saved = try JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(workspace.savedWorkspace()))
        try saved.validate()
        XCTAssertEqual(saved.tabs.flatMap(\.panes).first { $0.id == mainID }?.kind, .agents)
        XCTAssertEqual(saved.sidebar?.tab.panes.first?.kind, .agents)
        let restored = WorkspaceViewController()
        restored.herdrCoreClient = client
        restored.debugLoadForTesting()
        try restored.restoreWorkspace(saved)
        XCTAssertEqual(restored.savedWorkspace().tabs.flatMap(\.panes).first { $0.id == mainID }?.name, "Main Agents")
        XCTAssertEqual(restored.debugSidebarPane(sidebarID)?.name, "Sidebar Agents")
        XCTAssertTrue(restored.debugSidebarFocused)
        restored.debugPerformClosePane(withID: sidebarID)
        XCTAssertFalse(restored.debugSidebarVisible)
        XCTAssertEqual(client.agents.snapshots.count, 1, "Closing a list must not remove agent status")
    }

    func testEmbeddedAgentsUpdatesPreserveFocusAndFitSidebarWidth() throws {
        let pane = AgentsPaneController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let input = NSTextField(frame: NSRect(x: 260, y: 20, width: 200, height: 24))
        pane.hostView.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        root.addSubview(pane.hostView); root.addSubview(input)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = root
        defer { window.contentView = nil }
        window.makeFirstResponder(input)
        let responder = window.firstResponder
        let store = AgentSessionStore()
        store.apply(terminal("blocked"), binding: binding)
        pane.update(sessions: store.snapshots, messages: store.messageSnapshots)
        XCTAssertTrue(window.firstResponder === responder, "Background status updates must not focus an Agents pane")
        pane.fitToSize(); root.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        XCTAssertFalse(descendants(pane.hostView).contains { $0 is NSSegmentedControl })
        let trigger = try XCTUnwrap(descendants(pane.hostView).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier().hasPrefix("agent.messages.") })
        XCTAssertLessThanOrEqual(trigger.convert(trigger.bounds, to: pane.managerView).maxX, pane.managerView.bounds.maxX)
        XCTAssertEqual(trigger.title, "1")
        let row = try XCTUnwrap(descendants(pane.managerView).compactMap { $0 as? NSControl }.first { $0.accessibilityLabel()?.hasPrefix("Codex,") == true })
        XCTAssertLessThanOrEqual(row.bounds.width, pane.managerView.bounds.width)
        XCTAssertEqual(row.bounds.height, 72, "Rows must keep their height in a tall pane")
        var target: AgentSessionSnapshot?
        pane.managerView.onFocusPane = { target = $0 }
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(target?.binding, binding)
        store.apply(terminal("working"), binding: binding)
        pane.update(sessions: store.snapshots, messages: store.messageSnapshots)
        XCTAssertTrue(descendants(pane.hostView).contains { $0 === trigger }, "Updates must preserve the message popover's anchor")
        XCTAssertTrue(window.firstResponder === responder)
    }

    func testAgentMessageListsSeparateRootChildAndTerminalIdentity() throws {
        let store = AgentSessionStore()
        store.apply(terminal("blocked", records: ["helper": .init(state: "error", app: "codex")]), binding: binding)
        let other = HerdrTerminalBinding(coreID: "other-core", address: binding.address, remote: true)
        store.apply(terminal("done"), binding: other)
        let panel = AgentManagerView(sessions: store.snapshots)
        panel.updateSessions(store.snapshots, messages: store.messageSnapshots)
        XCTAssertEqual(store.snapshots.count, 3)
        for agent in store.snapshots {
            let messages = panel.messagesForAgent(agent.id)
            XCTAssertEqual(messages.count, 1)
            XCTAssertEqual(messages.first?.recordID, agent.id)
            XCTAssertEqual(messages.first?.binding, agent.binding)
            XCTAssertTrue(messages.first?.isUnread == true)
        }
        let root = try XCTUnwrap(store.snapshots.first { $0.id == AgentSessionStore.key(binding) + "#" })
        let message = try XCTUnwrap(panel.messagesForAgent(root.id).first)
        store.acknowledge(message)
        XCTAssertEqual(store.unreadCount, 2)
        panel.updateSessions(store.snapshots, messages: store.messageSnapshots)
        XCTAssertFalse(try XCTUnwrap(panel.messagesForAgent(root.id).first).isUnread)
        store.clearEnded()
        panel.updateSessions(store.snapshots, messages: store.messageSnapshots)
        XCTAssertTrue(panel.messagesForAgent(root.id).isEmpty)
    }

    func testNestedMessagePopoverKeepsItsAnchorAcrossUpdatesAndNavigatesOneMessage() async throws {
        let store = AgentSessionStore()
        store.apply(terminal("blocked"), binding: binding)
        let anchor = NSButton(frame: NSRect(x: 30, y: 30, width: 100, height: 32))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(anchor)
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        var selected: AgentSessionSnapshot?
        let parent = AgentManagerPopoverController(sessions: store.snapshots, previousFirstResponder: nil,
            onFocusPane: { selected = $0; store.acknowledge($0) }, onClose: {})
        parent.updateSessions(store.snapshots, messages: store.messageSnapshots)
        parent.show(relativeTo: anchor)
        defer { parent.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func managers() -> [AgentManagerView] {
            NSApp.windows.flatMap { $0.contentView.map(descendants) ?? [] }.compactMap { $0 as? AgentManagerView }
                .filter { $0.window?.isVisible == true }
        }
        let manager = try XCTUnwrap(managers().first)
        // macOS does not assign a key window to an inactive background test process.
        if NSApp.isActive { XCTAssertTrue(manager.window?.isKeyWindow == true) }
        XCTAssertTrue(manager.window?.firstResponder === manager)
        func key(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = [], in view: NSView) throws {
            let window = try XCTUnwrap(view.window)
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
        }
        let trigger = try XCTUnwrap(descendants(manager).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier().hasPrefix("agent.messages.") })
        try key(124, in: manager)
        let messages = try XCTUnwrap(managers().first { $0 !== manager })
        if NSApp.isActive { XCTAssertTrue(messages.window?.isKeyWindow == true) }
        XCTAssertTrue(messages.window?.firstResponder === messages)
        XCTAssertTrue(parent.isShown, "Opening messages must keep the containing Agents popover open")
        store.apply(terminal("working"), binding: binding)
        store.apply(terminal("done"), binding: binding)
        parent.updateSessions(store.snapshots, messages: store.messageSnapshots)
        XCTAssertTrue(messages.window?.isVisible == true)
        XCTAssertTrue(descendants(manager).contains { $0 === trigger })
        let rows = descendants(messages).compactMap { $0 as? NSControl }.filter { $0.accessibilityRole() == .button && $0.accessibilityLabel()?.hasPrefix("Codex,") == true }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(descendants(messages).compactMap { $0 as? NSButton }.filter { $0.accessibilityIdentifier().hasPrefix("agent.messages.") }.allSatisfy(\.isHidden))
        try key(45, characters: "n", modifiers: .control, in: messages)
        try key(35, characters: "p", modifiers: .control, in: messages)
        try key(36, in: messages)
        for _ in 0..<50 {
            if !parent.isShown { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(parent.isShown)
        XCTAssertEqual(selected?.id, store.messageSnapshots.first?.id)
        XCTAssertEqual(store.unreadCount, 1, "Selecting a message must acknowledge only that message")
    }

    func testExternalViewerPersistenceRequiresAnExistingBinding() throws {
        let workspace = WorkspaceViewController()
        workspace.debugLoadForTesting()
        workspace.newHerdrWorkspace(nil)
        var saved = workspace.savedWorkspace()
        saved.tabs[0].panes[0].herdrViewer = true
        XCTAssertThrowsError(try saved.validate())
        saved.tabs[0].panes[0].herdr = binding
        try saved.validate()
        saved.tabs[0].panes[0].herdrRunPending = true
        XCTAssertThrowsError(try saved.validate(), "A viewer must never restore as a pending creation")
    }

    func testExternalCoreAgentDiscoveryNavigationRestoreAndViewerCloseNeverKill() async throws {
        let executable: URL
        do { executable = try HerdrCoreTransport.executable() }
        catch { throw XCTSkip("hc is required for the real agent integration test") }
        let root = URL(fileURLWithPath: "/tmp/santty-agents-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HC_") }
        env["HC_SESSION"] = "probe"; env["HC_SOCKET"] = root.appendingPathComponent("core.sock").path
        env["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        env["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path; env["XDG_RUNTIME_DIR"] = root.path
        let client = HerdrCoreClient(executable: executable, environment: env)
        defer {
            client.stopAgentMonitoring()
            let process = Process(); process.executableURL = executable; process.arguments = ["server", "stop"]; process.environment = env
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { process.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
        client.startAgentMonitoring()
        let connection = try await client.connection()
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
            throw CLIError("Agent integration condition timed out")
        }
        let script = #"printf '\033]7501;state=idle:app=codex\033\\'; while IFS= read -r word; do printf '\033]7501;state=%s:app=codex:msg=UmV2aWV3IHJlYWR5\033\\' "$word"; done"#
        let created: HerdrCoreTerminal = try await HerdrCoreClient.request(connection, "terminal.run",
            ["argv": ["/bin/sh", "-c", script], "cwd": root.path, "no_parent": true])
        let binding = HerdrTerminalBinding(coreID: connection.hello.core.id, address: created.address)
        try await waitFor { client.agents.snapshots.count == 1 }
        struct Attached: Decodable, Sendable { let channel: UInt32 }
        let control: Attached = try await HerdrCoreClient.request(connection, "terminal.attach", ["terminal": created.address, "cols": 80, "rows": 24])
        connection.register(channel: control.channel) { result in
            if case let .success(frame) = result, frame.kind == 0 { connection.credit(channel: frame.channel, bytes: frame.payload.count) }
        }
        defer { connection.detach(channel: control.channel) }
        connection.send(channel: control.channel, kind: 0, payload: Data("working\n".utf8))
        try await waitFor { client.agents.snapshots.first?.displayState == .running }
        connection.send(channel: control.channel, kind: 0, payload: Data("blocked\n".utf8))
        try await waitFor { client.agents.unreadCount == 1 }
        XCTAssertEqual(client.agents.messages.first?.body, "Review ready")

        var workspace: WorkspaceViewController? = WorkspaceViewController()
        workspace!.herdrCoreClient = client; workspace!.debugLoadForTesting()
        let local = workspace!.debugSelectedWorkspace
        XCTAssertEqual(workspace!.paletteNavigationItems.filter { $0.kind == .agent }.count, 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace!.view; workspace!.viewDidAppear()
        defer { window.contentView = nil; workspace = nil }
        workspace!.addSidebarAgents(nil)
        let agentsPaneID = try XCTUnwrap(workspace!.debugSidebarFocusedPaneID)
        let agentsPane = try XCTUnwrap(workspace!.debugSidebarPane(agentsPaneID) as? AgentsPaneController)
        agentsPane.managerView.onFocusPane?(try XCTUnwrap(client.agents.snapshots.first))
        try await waitFor { workspace!.savedWorkspace().tabs.first?.panes.first?.herdr == binding }
        XCTAssertFalse(workspace!.debugSidebarFocused)
        let viewerWorkspace = workspace!.debugSelectedWorkspace
        XCTAssertNotEqual(viewerWorkspace, local)
        XCTAssertEqual(workspace!.savedWorkspace().tabs[0].panes[0].herdrViewer, true)
        let viewerTab = try XCTUnwrap(workspace!.debugSelectedTabID)
        workspace!.selectWorkspace(local)
        connection.send(channel: control.channel, kind: 0, payload: Data("working\ndone\n".utf8))
        try await waitFor { client.agents.messages.count == 2 }
        workspace!.navigateToAgent(binding)
        try await waitFor { workspace!.debugSelectedWorkspace == viewerWorkspace }
        XCTAssertEqual(workspace!.debugSelectedTabID, viewerTab, "Reopening an agent must reuse its viewer")
        let saved = workspace!.savedWorkspace()
        try saved.validate()
        window.contentView = nil; workspace = nil
        workspace = WorkspaceViewController(); workspace!.herdrCoreClient = client; workspace!.debugLoadForTesting()
        try workspace!.restoreWorkspace(JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(saved)))
        window.contentView = workspace!.view; workspace!.viewDidAppear()
        XCTAssertEqual(workspace!.savedWorkspace().tabs[0].panes[0].herdrViewer, true)
        workspace!.closeLocalWorkspace(viewerWorkspace)
        try await waitFor { workspace!.debugSelectedWorkspace == local }
        let stillLive = try await client.terminal(binding)
        XCTAssertEqual(stillLive.pid, created.pid)
        XCTAssertEqual(stillLive.state, "live")
        connection.send(channel: control.channel, kind: 0, payload: Data("working:id=helper\n".utf8))
        try await waitFor { client.agents.snapshots.contains { $0.id.hasSuffix("#helper") && $0.displayState == .running } }
        connection.send(channel: control.channel, kind: 0, payload: Data("blocked:id=helper\n".utf8))
        try await waitFor { client.agents.messages.count == 3 }
        connection.send(channel: control.channel, kind: 0, payload: Data("clear:id=helper\n".utf8))
        try await waitFor { !client.agents.snapshots.contains { $0.id.hasSuffix("#helper") } }
        XCTAssertEqual(client.agents.messages.count, 3)
        try await client.kill(binding)
        try await waitFor { client.agents.snapshots.isEmpty }
    }
}
