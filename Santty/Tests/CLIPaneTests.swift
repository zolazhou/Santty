import AppKit
import GhosttyTerminal
import XCTest
@testable import Santty

@MainActor
final class CLIPaneTests: XCTestCase {
    private func withPermissions<T>(control: Bool = true, input: Bool = true,
                                    _ body: (CLICommandRouter) async throws -> T) async rethrows -> T {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var values = previous
        values["cliControlEnabled"] = control; values["cliInputEnabled"] = input
        defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        return try await body(CLICommandRouter())
    }

    private func request(_ command: String, router: CLICommandRouter, pane: UUID? = nil) -> CLIRequest {
        CLIRequest(command: "pane." + command, paneID: pane, requestID: CLIRequestToken(instance: router.instanceID).rawValue)
    }

    func testParserValidatesOptionsBeforeConnecting() throws {
        let id = UUID().uuidString
        let parsed = try CLIInvocation.parse(["pane", "split", id, "--direction", "left", "--type", "agents", "--json"])
        XCTAssertEqual(parsed.request.command, "pane.split")
        XCTAssertEqual(parsed.request.paneType, "agents")
        XCTAssertTrue(parsed.json)
        let stdin = try CLIInvocation.parse(["pane", "send-text", id, "--stdin"])
        XCTAssertTrue(stdin.readsStdin)
        for args in [
            ["pane", "new"], ["pane", "split", id], ["pane", "split", id, "--direction", "diagonal"],
            ["pane", "close", id, "--focus"], ["pane", "rename", id, "a\nb"],
            ["pane", "resize", id, "--direction", "left", "--amount", "0"],
            ["pane", "send-text", id, "--text", "x", "--stdin"], ["read", id, "--stdin"],
            ["pane", "send-key", id, "Cmd+Q"], ["pane", "send-key", id, "Ctrl+Ctrl+C"],
            ["pane", "send-text", id, "--text", ""], ["pane", "close", id, "--force", "--force"],
            ["pane", "focus", id, "--request-id", "bad"], ["list", "--force"],
        ] { XCTAssertThrowsError(try CLIInvocation.parse(args), "\(args)") }
        for key in ["Enter", "Ctrl+C", "Shift+Tab", "Ctrl+Shift+A", "PageDown", "Left"] {
            XCTAssertNoThrow(try CLIKey(key))
        }
        var invalid = CLIRequest(command: "pane.send-text", paneID: UUID(), text: String(repeating: "x", count: 65537),
                                 requestID: CLIRequestToken(instance: UUID()).rawValue)
        XCTAssertThrowsError(try invalid.validate())
        invalid.text = "a\0b"
        XCTAssertThrowsError(try invalid.validate())
        invalid.text = "中文🙂\nsecond line"
        XCTAssertNoThrow(try invalid.validate())
    }

    func testCapabilitiesAndSeparatePermissions() async throws {
        await withPermissions(control: false, input: false) { router in
            let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
            let id = workspace.debugFocusedPaneID!
            let capabilities = await router.handle(CLIRequest(command: "capabilities"), workspace: workspace)
            XCTAssertEqual(capabilities.version, 2)
            XCTAssertEqual(capabilities.capabilities?.controlEnabled, false)
            XCTAssertTrue(capabilities.capabilities?.commands.contains("pane.close") == true)
            let close = await router.handle(request("close", router: router, pane: id), workspace: workspace)
            XCTAssertEqual(close.errorCode, "permission_denied")
            var input = request("send-text", router: router, pane: id); input.text = "hello"
            let denied = await router.handle(input, workspace: workspace)
            XCTAssertEqual(denied.errorCode, "permission_denied")
            let list = await router.handle(CLIRequest(command: "list"), workspace: workspace)
            XCTAssertNil(list.error)
        }
        await withPermissions(control: true, input: false) { router in
            let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
            var rename = request("rename", router: router, pane: workspace.debugFocusedPaneID); rename.name = "API"
            let result = await router.handle(rename, workspace: workspace)
            XCTAssertNil(result.error)
            var input = request("send-key", router: router, pane: workspace.debugFocusedPaneID); input.key = "Enter"
            let denied = await router.handle(input, workspace: workspace)
            XCTAssertEqual(denied.errorCode, "permission_denied")
        }
    }

    func testBackgroundCreationRenameAndRetryKeepSelectionAndResponder() async throws {
        try await withPermissions { router in
            let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
            let owner = workspace.debugSelectedWorkspace
            let selected = workspace.debugSelectedTabID
            let focused = try XCTUnwrap(workspace.debugFocusedPaneID)
            let window = NSWindow(contentRect: workspace.view.frame, styleMask: [], backing: .buffered, defer: false)
            window.contentView = workspace.view
            workspace.viewDidAppear()
            defer { window.contentView = nil }
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
            workspace.view.addSubview(field); window.makeFirstResponder(field)
            let responder = window.firstResponder
            var create = request("new", router: router); create.workspaceID = owner; create.paneType = "agents"
            let operation = create
            let firstAttempt = Task { @MainActor in await router.handle(operation, workspace: workspace) }
            let concurrentAttempt = Task { @MainActor in await router.handle(operation, workspace: workspace) }
            let created = await firstAttempt.value
            let concurrent = await concurrentAttempt.value
            XCTAssertEqual(created.paneID, concurrent.paneID)
            XCTAssertNil(created.error)
            let id = try XCTUnwrap(created.paneID)
            let retried = await router.handle(create, workspace: workspace)
            XCTAssertEqual(retried.paneID, id)
            var caseVariant = create; caseVariant.requestID = create.requestID?.lowercased()
            let canonicalRetry = await router.handle(caseVariant, workspace: workspace)
            XCTAssertEqual(canonicalRetry.paneID, id)
            XCTAssertEqual(workspace.debugTabIDs.count, 2)
            var split = request("split", router: router, pane: id); split.direction = "left"; split.paneType = "browser"
            let second = await router.handle(split, workspace: workspace)
            XCTAssertNil(second.error)
            XCTAssertEqual(workspace.debugLayoutNode(forTabID: created.tabID!)?.paneIDsInTraversalOrder, [second.paneID!, id])
            var rename = request("rename", router: router, pane: second.paneID); rename.name = " API 中文 "
            let renamed = await router.handle(rename, workspace: workspace)
            XCTAssertNil(renamed.error)
            let list = try workspace.handleCLIRequest(.init(command: "list"))
            XCTAssertEqual(list.tabs?.flatMap(\.panes).first { $0.id == second.paneID }?.name, "API 中文")
            rename.requestID = CLIRequestToken(instance: router.instanceID).rawValue; rename.name = ""
            _ = await router.handle(rename, workspace: workspace)
            XCTAssertNil(try workspace.handleCLIRequest(.init(command: "list")).tabs?.flatMap(\.panes).first { $0.id == second.paneID }?.name)
            XCTAssertEqual(workspace.debugSelectedTabID, selected)
            XCTAssertEqual(workspace.debugFocusedPaneID, focused)
            XCTAssertTrue(window.firstResponder === responder)
            var visibleSplit = request("split", router: router, pane: focused)
            visibleSplit.direction = "right"; visibleSplit.paneType = "browser"
            let visible = await router.handle(visibleSplit, workspace: workspace)
            XCTAssertNil(visible.error)
            XCTAssertTrue(window.firstResponder === responder)
            XCTAssertEqual(workspace.debugFocusedPaneID, focused)
            var conflict = create; conflict.paneType = "browser"
            let rejected = await router.handle(conflict, workspace: workspace)
            XCTAssertEqual(rejected.errorCode, "request_conflict")
            var expired = create
            expired.requestID = CLIRequestToken(instance: router.instanceID, now: Date().addingTimeInterval(-601)).rawValue
            let old = await router.handle(expired, workspace: workspace)
            XCTAssertEqual(old.errorCode, "request_expired")
            expired.requestID = CLIRequestToken(instance: UUID()).rawValue
            let stale = await router.handle(expired, workspace: workspace)
            XCTAssertEqual(stale.errorCode, "stale_request")
            try workspace.savedWorkspace().validate()
        }
    }

    func testCrossWorkspaceAndSidebarTargetsPreserveBackendAndFocus() async throws {
        try await withPermissions { router in
            let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
            let local = workspace.debugSelectedWorkspace
            let localPane = try XCTUnwrap(workspace.debugFocusedPaneID)
            let remote = HerdrRemote(id: "cli-test-remote-core", name: "box")
            XCTAssertTrue(workspace.createRemoteHerdrWorkspace(remote))
            let remoteID = workspace.debugSelectedWorkspace
            let remotePane = try XCTUnwrap(workspace.debugFocusedPaneID)
            var create = request("new", router: router); create.workspaceID = local
            let created = await router.handle(create, workspace: workspace)
            XCTAssertNil(created.error)
            let saved = workspace.savedWorkspace()
            XCTAssertEqual(saved.otherLocalWorkspaces?.first { $0.id == local }?.tabs.first { $0.id == created.tabID }?.panes.first?.kind, .localTerminal)
            var backgroundClose = request("close", router: router, pane: created.paneID); backgroundClose.force = true
            let closedBackground = await router.handle(backgroundClose, workspace: workspace)
            XCTAssertNil(closedBackground.error)
            XCTAssertEqual(workspace.debugSelectedWorkspace, remoteID)
            XCTAssertEqual(workspace.savedWorkspace().otherLocalWorkspaces?.first { $0.id == local }?.tabs.count, 1)
            var split = request("split", router: router, pane: remotePane); split.direction = "down"
            let remoteSplit = await router.handle(split, workspace: workspace)
            XCTAssertNil(remoteSplit.error)
            XCTAssertEqual(workspace.savedWorkspace().herdrRemote, remote)
            XCTAssertTrue(workspace.savedWorkspace().tabs[0].panes.allSatisfy { $0.kind == .herdrTerminal })
            workspace.toggleSidebar(nil)
            let sidebar = try XCTUnwrap(workspace.debugSidebarPaneIDs.first)
            split = request("split", router: router, pane: sidebar); split.direction = "down"; split.paneType = "agents"
            let sidebarSplit = await router.handle(split, workspace: workspace)
            XCTAssertNil(sidebarSplit.error)
            XCTAssertEqual(workspace.debugSelectedWorkspace, remoteID)
            XCTAssertEqual(workspace.debugFocusedPaneID, remotePane)
            XCTAssertFalse(workspace.debugSidebarFocused)
            let list = try workspace.handleCLIRequest(.init(command: "list"))
            XCTAssertTrue(list.tabs?.contains { $0.workspaceID == local && $0.panes.contains { $0.id == localPane } } == true)
            XCTAssertTrue(list.tabs?.contains { $0.region == "sidebar" && $0.panes.contains { $0.id == sidebarSplit.paneID } } == true)
            workspace.toggleSidebar(nil)
            let focusedSidebar = await router.handle(request("focus", router: router, pane: sidebarSplit.paneID), workspace: workspace)
            XCTAssertNil(focusedSidebar.error)
            XCTAssertTrue(workspace.debugSidebarVisible)
            XCTAssertTrue(workspace.debugSidebarFocused)
            let focus = await router.handle(request("focus", router: router, pane: localPane), workspace: workspace)
            XCTAssertNil(focus.error)
            XCTAssertEqual(workspace.debugSelectedWorkspace, local)
            XCTAssertEqual(workspace.debugFocusedPaneID, localPane)
            var closeWorkspacePane = request("close", router: router, pane: localPane); closeWorkspacePane.force = true
            let removedWorkspace = await router.handle(closeWorkspacePane, workspace: workspace)
            XCTAssertNil(removedWorkspace.error)
            XCTAssertEqual(workspace.debugSelectedWorkspace, remoteID)
            XCTAssertFalse(workspace.savedWorkspace().otherLocalWorkspaces?.contains { $0.id == local } == true)
            try workspace.savedWorkspace().validate()
        }
    }

    func testCloseRequiresForceAndDoesNotFocusUnrelatedPanes() async throws {
        try await withPermissions { router in
            let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
            let first = try XCTUnwrap(workspace.debugFocusedPaneID)
            var split = request("split", router: router, pane: first); split.direction = "right"
            let created = await router.handle(split, workspace: workspace)
            let second = try XCTUnwrap(created.paneID)
            let denied = await router.handle(request("close", router: router, pane: second), workspace: workspace)
            XCTAssertEqual(denied.errorCode, "confirmation_required")
            var close = request("close", router: router, pane: second); close.force = true
            let closed = await router.handle(close, workspace: workspace)
            XCTAssertNil(closed.error)
            XCTAssertEqual(closed.status, "closed")
            XCTAssertEqual(workspace.debugFocusedPaneID, first)
            XCTAssertEqual(workspace.debugPaneIDsInTraversalOrder, [first])
            let retry = await router.handle(close, workspace: workspace)
            XCTAssertNil(retry.error)
            XCTAssertEqual(retry.status, "closed")
            var missing = close; missing.requestID = CLIRequestToken(instance: router.instanceID).rawValue
            let absent = await router.handle(missing, workspace: workspace)
            XCTAssertEqual(absent.errorCode, "pane_not_found")
            close = request("close", router: router, pane: first); close.force = true
            let last = await router.handle(close, workspace: workspace)
            XCTAssertNil(last.error)
            XCTAssertFalse(workspace.debugDidRequestWindowClose)
            workspace.finishCLIReply(requestID: closed.requestID)
            XCTAssertFalse(workspace.debugDidRequestWindowClose, "Another completed close must not finalize this operation")
            workspace.finishCLIReply(requestID: last.requestID)
            XCTAssertTrue(workspace.debugDidRequestWindowClose)
        }
    }

    func testLayoutDirectionsResizeClampingAndUnsupportedOverlays() async throws {
        let a = UUID(), b = UUID()
        let node = LayoutNode.split(axis: .horizontal, children: [.panel(a), .panel(b)], fractions: [0.5, 0.5])
        var resize = CLIRequest(command: "pane.resize", paneID: a, direction: "right", amount: 40)
        let changed = try CLIPaneLayout.apply(resize, to: node, size: NSSize(width: 1000, height: 600))
        XCTAssertGreaterThan(try XCTUnwrap(changed.parentSplitContext(for: a)).currentFocusedFraction, 0.5)
        resize.amount = 10000
        let clamped = try CLIPaneLayout.apply(resize, to: node, size: NSSize(width: 1000, height: 600))
        let geometry = TilingLayout.compute(node: clamped, rect: NSRect(x: 0, y: 0, width: 1000, height: 600), dividerThickness: AppAppearanceSettings.workspaceDividerThickness)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(geometry.panePlacements.first { $0.paneID == b }).frame.width, 239.99)
        resize.direction = "left"
        XCTAssertThrowsError(try CLIPaneLayout.apply(resize, to: node, size: NSSize(width: 1000, height: 600)))
        let vertical = LayoutNode.split(axis: .vertical, children: [.panel(a), .panel(b)], fractions: [0.5, 0.5])
        let moved = try CLIPaneLayout.apply(.init(command: "pane.move", paneID: b, direction: "up"), to: vertical, size: NSSize(width: 1000, height: 600))
        XCTAssertEqual(moved.paneIDsInTraversalOrder, [b, a])
        try await withPermissions { router in
            let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
            let id = try XCTUnwrap(workspace.debugFocusedPaneID)
            workspace.debugToggleFloatingPane()
            let before = workspace.debugLayoutNode
            var split = request("split", router: router, pane: id); split.direction = "right"
            let denied = await router.handle(split, workspace: workspace)
            XCTAssertEqual(denied.errorCode, "unsupported_layout")
            XCTAssertEqual(workspace.debugLayoutNode, before)
            XCTAssertNotNil(workspace.debugActiveFloatingPaneState)
        }
    }

    func testLocalTerminalInputDoesNotChangeResponderOrClipboard() async throws {
        let pane = TerminalPaneController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [], backing: .buffered, defer: false)
        window.contentView = pane.hostView
        defer { window.contentView = nil }
        pane.startIfNeeded(); pane.fitToSize()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        pane.hostView.addSubview(field); window.makeFirstResponder(field)
        let responder = window.firstResponder
        let changeCount = NSPasteboard.general.changeCount
        let text = "printf 'CLI-%s-OK\\n' INPUT"
        try pane.sendForCLI(.init(command: "pane.send-text", text: text))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(try pane.readForCLI(.init(command: "read", paneID: pane.id)).text?.contains("CLI-INPUT-OK") == true, "Sending text must not submit it")
        try pane.sendForCLI(.init(command: "pane.send-key", key: "Enter"))
        var found = false
        for _ in 0..<200 {
            if try pane.readForCLI(.init(command: "read", paneID: pane.id)).text?.contains("CLI-INPUT-OK") == true { found = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(found)
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertEqual(NSPasteboard.general.changeCount, changeCount)
        pane.enterScrollMode()
        XCTAssertThrowsError(try pane.sendForCLI(.init(command: "pane.send-key", key: "Enter")))
        let offline = TerminalPaneController(herdrSession: HerdrTerminalSession(paneID: UUID(), cwd: nil, binding: nil))
        XCTAssertThrowsError(try offline.sendForCLI(.init(command: "pane.send-text", text: "never replay")))
    }
}
