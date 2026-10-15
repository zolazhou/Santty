import Foundation
import AppKit
import GhosttyTerminal
import XCTest
@testable import Santty

@MainActor
final class HerdrClientShellSessionTests: XCTestCase {
    func testInitialTabSelectionRequiresActivationAndFreshPresentation() async throws {
        let (process, endpoint, path) = try await fixture("window-tabs-palette")
        defer { cleanup(process, path) }
        let session = HerdrClientShellSession(endpoint: endpoint)
        defer { session.disconnect() }
        var offered = 0
        session.onProjection = { _, _, _ in offered += 1 }
        try await session.start(size: .init(cols: 1, rows: 1), cellWidth: 0, cellHeight: 0,
            focused: false, activateWhenMetadataReady: false)
        for _ in 0..<200 where session.projection.snapshot == nil { try await Task.sleep(for: .milliseconds(10)) }
        let snapshot = try XCTUnwrap(session.projection.snapshot)
        let target = try XCTUnwrap(snapshot.tabs.first { $0.tab_id != snapshot.focused_tab_id })
        do { try await session.selectInitialTab(target.tab_id); XCTFail("Inactive navigation must be rejected") } catch { }
        try session.activate(size: .init(cols: 100, rows: 30), cellWidth: 8, cellHeight: 16)
        try await session.selectInitialTab(target.tab_id)
        for _ in 0..<200 where session.projection.snapshot?.focused_tab_id != target.tab_id { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(session.projection.snapshot?.focused_tab_id, target.tab_id)
        XCTAssertFalse(session.isPresentationReady)
        XCTAssertGreaterThan(offered, 0)
        let surface = try XCTUnwrap(session.projection.coherentSurface)
        XCTAssertTrue(session.acknowledgePresentation(surface))
        do { try await session.selectInitialTab(snapshot.focused_tab_id!); XCTFail("Initial navigation must end after presentation") } catch { }
        try await session.deactivateAndWait()
        XCTAssertFalse(session.isPresentationReady)
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        XCTAssertTrue(trace.contains { $0["method"] as? String == "client_shell.surface.set" })
    }

    func testSinglePaneRoundtripAvoidsAPILayoutQueriesButSplitFetchesTopology() async throws {
        let (process, endpoint, path) = try await fixture("window-split-queries")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        let local = workspace.debugSelectedWorkspace
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let selected = workspace.debugSelectedWorkspace
        workspace.selectWorkspace(local)
        workspace.selectWorkspace(selected); await workspace.waitForWorkspaceSelection()
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true)
        func exports() throws -> [[String: Any]] {
            let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
            return trace.filter { $0["method"] as? String == "layout.export" }
        }
        XCTAssertTrue(try exports().isEmpty, "ClientShell already provides the complete single-pane topology")
        workspace.debugSetFocusedPaneName("trigger external split")
        for _ in 0..<500 where workspace.debugPaneIDsInTraversalOrder.count != 2 || workspace.debugHerdrOperationPending || workspace.debugFocusedHerdrPane?.canAcceptInput != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(workspace.debugPaneIDsInTraversalOrder.count, 2)
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true)
        XCTAssertFalse(try exports().isEmpty, "Split topology must still come from the native API")
        XCTAssertNil(workspace.herdrLastError)
    }

    func testDividerKeyboardPreviewAnimatesAndSurvivesDelayedOldProjection() async throws {
        let (process, endpoint, path) = try await fixture("window-split-slow")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        workspace.debugSetFocusedPaneName("trigger external split")
        for _ in 0..<300 where workspace.debugPaneIDsInTraversalOrder.count != 2 || workspace.debugHerdrOperationPending || workspace.debugFocusedHerdrPane?.canAcceptInput != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        let initial = try XCTUnwrap(workspace.debugRenderedSplitFractions(at: [])?.first)
        workspace.debugPerformCommand(withID: "pane.resize.right")
        XCTAssertEqual(try XCTUnwrap(workspace.debugRenderedSplitFractions(at: [])?.first), initial + 0.05, accuracy: 0.0001)
        let root = try XCTUnwrap(workspace.view as? WorkspaceRootView)
        let tiling = try XCTUnwrap(root.contentContainerView.subviews.compactMap { $0 as? WorkspaceTilingView }.first)
        XCTAssertTrue(tiling.paneViews.values.contains { $0.layer?.animation(forKey: "santty.paneResize.flip") != nil })
        // Let the first request start, then merge repeated keys into its final successor.
        try await Task.sleep(for: .milliseconds(60))
        workspace.debugPerformCommand(withID: "pane.resize.right")
        workspace.debugPerformCommand(withID: "pane.resize.right")
        let final = initial + 0.15
        for _ in 0..<100 {
            XCTAssertEqual(try XCTUnwrap(workspace.debugRenderedSplitFractions(at: [])?.first), final, accuracy: 0.02)
            if !workspace.debugHerdrOperationPending, workspace.debugFocusedHerdrPane?.canAcceptInput == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<300 where workspace.debugHerdrOperationPending || workspace.debugFocusedHerdrPane?.canAcceptInput != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(workspace.herdrLastError)
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true)
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        let requests = trace.filter { $0["method"] as? String == "layout.set_split_ratio" }
        XCTAssertEqual(requests.count, 2)
        let params = try XCTUnwrap(requests.last?["params"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(params["ratio"] as? Double), Double(final), accuracy: 0.0001)
        workspace.debugPerformCommand(withID: "pane.resize.equalize")
        XCTAssertEqual(try XCTUnwrap(workspace.debugRenderedSplitFractions(at: [])?.first), 0.5, accuracy: 0.0001)
        for _ in 0..<300 where workspace.debugHerdrOperationPending || workspace.debugFocusedHerdrPane?.canAcceptInput != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(workspace.herdrLastError)
        let reversed = try XCTUnwrap(workspace.debugRenderedSplitFractions(at: [])?.first)
        workspace.debugPerformCommand(withID: "pane.resize.right")
        try await Task.sleep(for: .milliseconds(60))
        workspace.debugPerformCommand(withID: "pane.resize.left")
        for _ in 0..<300 {
            XCTAssertEqual(try XCTUnwrap(workspace.debugRenderedSplitFractions(at: [])?.first), reversed, accuracy: 0.02,
                           "Returning to the old ratio must not let an intermediate reply undo the latest edit")
            if !workspace.debugHerdrOperationPending, workspace.debugFocusedHerdrPane?.canAcceptInput == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(workspace.herdrLastError)
        try workspace.savedWorkspace().validate()
    }

    func testTabSelectionRespondsImmediatelyAndKeepsLatestChoiceDuringSync() async throws {
        let (process, endpoint, path) = try await fixture("window-tabs-slow")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let first = try XCTUnwrap(workspace.debugSelectedTabID)
        let second = try XCTUnwrap(workspace.debugTabIDs.first { $0 != first })
        let presentedPane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        let presentedHost = presentedPane.hostView
        let presentedTerminal = try XCTUnwrap(presentedHost.subviews.compactMap { $0 as? TerminalView }.first)
        let presentedText = presentedTerminal.readScreenText()
        let root = try XCTUnwrap(workspace.view as? WorkspaceRootView)
        let presentedLayout = try XCTUnwrap(root.contentContainerView.subviews.first)
        workspace.debugSelectTab(withID: second)
        XCTAssertEqual(workspace.debugSelectedTabID, second)
        XCTAssertTrue(presentedHost.window === window, "Keep the rendered pane attached until the target scene is ready")
        XCTAssertTrue(root.contentContainerView.subviews.first === presentedLayout)
        XCTAssertEqual(presentedTerminal.readScreenText(), presentedText)
        XCTAssertFalse(presentedPane.canAcceptInput, "The retained old pane must not receive input for the selected tab")
        XCTAssertNil(workspace.debugFocusedHerdrPane?.hostView.window, "The target pane must be staged before it becomes visible")
        workspace.debugSelectTab(withID: second)
        XCTAssertTrue(presentedHost.window === window, "Selecting the pending tab again must not install its unrendered pane")
        try await Task.sleep(for: .milliseconds(60))
        workspace.debugSelectTab(withID: first)
        XCTAssertEqual(workspace.debugSelectedTabID, first)
        workspace.debugSelectTab(withID: second)
        XCTAssertEqual(workspace.debugSelectedTabID, second)
        for _ in 0..<300 {
            XCTAssertEqual(workspace.debugSelectedTabID, second, "Older projections must not undo a newer local selection")
            if !workspace.debugHerdrOperationPending, workspace.debugFocusedHerdrPane?.canAcceptInput == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(workspace.herdrLastError)
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true)
        XCTAssertEqual(workspace.debugFocusedHerdrPane?.herdrBinding?.paneID, "w5:pB")
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.hostView.window === window)
        try XCTUnwrap(workspace.paletteNavigationItems.first { $0.kind == .tab && $0.isInCurrentWorkspace && !$0.isCurrent }).perform()
        XCTAssertEqual(workspace.debugSelectedTabID, first, "Cached palette targets must select locally before waiting for Herdr")
        await workspace.waitForPaletteNavigationForTesting()
        XCTAssertEqual(workspace.debugSelectedTabID, first)
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true)
    }

    func testRejectedDividerEditRestoresConfirmedLayout() async throws {
        let (process, endpoint, path) = try await fixture("window-split-rejected")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        workspace.debugSetFocusedPaneName("trigger external split")
        for _ in 0..<300 where workspace.debugPaneIDsInTraversalOrder.count != 2 || workspace.debugHerdrOperationPending || workspace.debugFocusedHerdrPane?.canAcceptInput != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        let initial = try XCTUnwrap(workspace.debugRenderedSplitFractions(at: [])?.first)
        workspace.debugPerformCommand(withID: "pane.resize.right")
        XCTAssertGreaterThan(try XCTUnwrap(workspace.debugRenderedSplitFractions(at: [])?.first), initial)
        for _ in 0..<300 where workspace.herdrLastError == nil || workspace.debugHerdrOperationPending {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(workspace.herdrLastError?.contains("rejected resizing") == true)
        XCTAssertEqual(try XCTUnwrap(workspace.debugRenderedSplitFractions(at: [])?.first), initial, accuracy: 0.02)
    }

    func testPaletteNavigatesUnopenedHerdrTabsOtherWorkspacesAndCachedLocalPanes() async throws {
        let (process, endpoint, path) = try await fixture("window-tabs-palette")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        var errors: [String] = []
        workspace.herdrErrorHandler = { errors.append($0) }
        try workspace.configureHerdrWorkspace(endpoint)
        let locals = workspace.debugTabIDs
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        for _ in 0..<300 where workspace.paletteNavigationItems.filter({ $0.kind == .workspace }).count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".trace"), "Searching unopened workspaces must not attach ClientShell")
        func choose(_ predicate: (AppCommand) -> Bool) async throws {
            try XCTUnwrap(workspace.paletteNavigationItems.first(where: predicate)).perform()
            await workspace.waitForPaletteNavigationForTesting()
            XCTAssertNil(workspace.herdrLastError)
        }
        try await choose { $0.kind == .pane && $0.title == "Secondary shell" }
        XCTAssertEqual(workspace.debugFocusedHerdrPane?.herdrBinding?.paneID, "w5:pB")
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true)
        workspace.newBrowserPane(nil)
        workspace.debugSetFocusedPaneName("Local companion")
        let browser = try XCTUnwrap(workspace.debugFocusedPaneID)
        let companion = try XCTUnwrap(workspace.paletteNavigationItems.first { $0.title == "Local companion" && $0.kind == .pane })
        try await choose { $0.kind == .pane && $0.title == "Remote logs" }
        XCTAssertEqual(workspace.debugFocusedHerdrPane?.herdrBinding?.workspaceID, "w6")
        try await choose { $0.kind == .workspace && $0.title == "Default" }
        XCTAssertEqual(workspace.debugTabIDs, locals)
        XCTAssertTrue(workspace.paletteNavigationItems.contains { $0.kind == .pane && $0.title == "Local companion" })
        companion.perform()
        await workspace.waitForPaletteNavigationForTesting()
        XCTAssertNil(workspace.herdrLastError)
        XCTAssertEqual(workspace.debugFocusedPaneID, browser)
        XCTAssertTrue(workspace.debugFocusedPaneIsBrowser)
        try await choose { $0.kind == .tab && $0.isInCurrentWorkspace && !$0.isCurrent }
        XCTAssertEqual(workspace.debugFocusedHerdrPane?.herdrBinding?.paneID, "w5:pA")
        let local = try XCTUnwrap(workspace.paletteNavigationItems.first { $0.kind == .workspace && $0.title == "Default" })
        let remote = try XCTUnwrap(workspace.paletteNavigationItems.first { $0.kind == .pane && $0.title == "Remote logs" })
        remote.perform(); local.perform()
        await workspace.waitForPaletteNavigationForTesting()
        XCTAssertEqual(workspace.debugTabIDs, locals, "Only the latest unexecuted navigation should run")
        XCTAssertNil(workspace.herdrLastError)
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        XCTAssertEqual(trace.filter { $0["method"] as? String == "workspace.focus" && ($0["params"] as? [String: Any])?["workspace_id"] as? String == "w6" }.count, 1)
        XCTAssertEqual(trace.filter {
            let params = $0["params"] as? [String: Any]
            return ($0["method"] as? String == "tab.focus" && params?["tab_id"] as? String == "w5:t4")
                || ($0["method"] as? String == "pane.focus" && params?["pane_id"] as? String == "w5:pA")
        }.count, 1, "Cached tab navigation shares the normal local focus route and synchronizes once")
        XCTAssertTrue(process.isRunning)
        try workspace.savedWorkspace().validate()
        try workspace.configureHerdrWorkspace(.init(binary: endpoint.binary, session: endpoint.session, socketPath: path + ".missing"))
        remote.perform()
        await workspace.waitForPaletteNavigationForTesting()
        XCTAssertTrue(errors.last?.contains("changed") == true)
        XCTAssertEqual(workspace.debugTabIDs, locals)

    }

    func testWorkspaceDiscoveryAndPickerRoundTripPreserveLocalContentAndAuxiliaries() async throws {
        let (process, endpoint, path) = try await fixture("window")
        defer { cleanup(process, path) }
        let defaults = UserDefaults.standard
        let keys = ["HerdrBinary", "HerdrSession", "HerdrSocket"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(endpoint.binary.path, forKey: keys[0])
        defaults.set(endpoint.session, forKey: keys[1])
        defaults.set(endpoint.socketPath, forKey: keys[2])
        XCTAssertThrowsError(try HerdrSettings.save(binary: "relative/herdr", session: endpoint.session, socket: endpoint.socketPath))
        XCTAssertEqual(HerdrSettings.endpoint, endpoint, "Rejected settings must not change the saved endpoint")

        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        let toolbar = try XCTUnwrap((workspace.view as? WorkspaceRootView)?.toolbarView)
        XCTAssertFalse(toolbar.workspaceSwitcher.isHidden)
        XCTAssertEqual(toolbar.workspaceSwitcher.titleOfSelectedItem, "Default")
        let locals = workspace.debugTabIDs
        let herdrPickerID = WorkspaceReference(source: .herdr(endpoint: endpoint, workspaceID: "w5")).id
        let localPickerID = workspace.debugSelectedWorkspace.id
        workspace.discoverHerdrWorkspaces()
        await workspace.waitForHerdrWorkspaceDiscovery()
        XCTAssertTrue(toolbar.workspaceSwitcher.itemArray.contains { $0.representedObject as? String == herdrPickerID })
        XCTAssertNil(workspace.debugFocusedHerdrPane, "Discovery must not attach a terminal or change the selected workspace")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".trace"))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        func choose(_ id: String) {
            let item = toolbar.workspaceSwitcher.itemArray.first { $0.representedObject as? String == id }
            XCTAssertNotNil(item, "Missing workspace target \(id)")
            XCTAssertTrue(item?.isEnabled == true, "A freshly discovered workspace must be selectable")
            toolbar.workspaceSwitcher.select(item)
            _ = toolbar.workspaceSwitcher.sendAction(toolbar.workspaceSwitcher.action, to: toolbar.workspaceSwitcher.target)
        }
        func waitForSwitch() async throws {
            for _ in 0..<600 where workspace.debugHerdrOperationPending { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(workspace.debugHerdrOperationPending)
        }
        choose(herdrPickerID); try await waitForSwitch()
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true)
        workspace.debugPerformCommand(withID: "pane.notes.new")
        let notes = workspace.savedWorkspace().tabs.flatMap(\.panes).filter { $0.kind == .notes }.map(\.id)
        XCTAssertEqual(notes.count, 1)
        choose(localPickerID)
        XCTAssertEqual(workspace.debugTabIDs, locals)
        XCTAssertEqual(toolbar.workspaceSwitcher.titleOfSelectedItem, "Default")
        let localSaved = workspace.savedWorkspace()
        try localSaved.validate()
        XCTAssertEqual(localSaved.herdrAuxiliaryTabs?.flatMap(\.panes).map(\.id), notes)
        XCTAssertTrue(toolbar.workspaceSwitcher.itemArray.contains { $0.representedObject as? String == herdrPickerID })
        try workspace.restoreWorkspace(localSaved)
        choose(herdrPickerID); try await waitForSwitch()
        let reconnected = await workspace.collectHerdrDiagnostics()
        XCTAssertTrue(reconnected.clientShell?.presentationReady == true, workspace.herdrLastError ?? "Restored workspace was not presented")
        XCTAssertNil(workspace.debugFocusedHerdrPane, "The restored Notes pane keeps local focus")
        XCTAssertEqual(workspace.savedWorkspace().tabs.flatMap(\.panes).filter { $0.kind == .notes }.map(\.id), notes)
        try workspace.savedWorkspace().validate()
        XCTAssertTrue(process.isRunning)

        choose(localPickerID)
        var stale = workspace.savedWorkspace()
        let currentMetadata = try await HerdrWorkspaceClient(endpoint: endpoint).snapshot()
        var metadata = try XCTUnwrap(currentMetadata.panes.first)
        let identity = try XCTUnwrap(metadata.serviceIdentity)
        metadata.serviceIdentity = .init(pid: identity.pid, startedSeconds: identity.startedSeconds + 1, startedMicroseconds: identity.startedMicroseconds)
        stale.herdrAuxiliaryTabs?[0].backendBinding = try HerdrPaneBinding(endpoint: endpoint, pane: metadata)
        try workspace.restoreWorkspace(stale)
        choose(herdrPickerID); try await waitForSwitch()
        choose(localPickerID)
        XCTAssertEqual(workspace.savedWorkspace().tabs.flatMap(\.panes).filter { $0.kind == .notes }.map(\.id), notes,
                       "A restarted service recovers old local additions into Default instead of attaching them to reused backend IDs")
        try workspace.savedWorkspace().validate()
        let recoveredLocals = workspace.debugTabIDs
        defaults.set(path + ".missing", forKey: "HerdrSocket")
        workspace.discoverHerdrWorkspaces()
        await workspace.waitForHerdrWorkspaceDiscovery()
        XCTAssertEqual(toolbar.workspaceSwitcher.titleOfSelectedItem, "Default")
        XCTAssertEqual(toolbar.workspaceSwitcher.numberOfItems, 1)
        XCTAssertEqual(workspace.debugTabIDs, recoveredLocals)
        XCTAssertNotNil(workspace.herdrLastError)
    }

    func testAcceptedKeyReleaseSurvivesSnapshotWithoutItsMatchingSurface() async throws {
        let (process, endpoint, path) = try await fixture("snapshot-gap")
        defer { cleanup(process, path) }
        let session = autoPresentedSession(endpoint)
        defer { session.disconnect() }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: true)
        for _ in 0..<200 where !session.isPresentationReady { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.isPresentationReady)
        let down = HerdrShellInput.key(.init(code: 1, tracksRelease: true, physicalKeyID: 36))
        let up = HerdrShellInput.key(.init(code: 1, kind: 2, tracksRelease: true, physicalKeyID: 36))
        XCTAssertTrue(session.input(target: "w5:pA", events: [down]))
        for _ in 0..<200 where session.projection.coherentSurface != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(session.projection.coherentSurface)
        XCTAssertEqual(session.state, .connecting)
        XCTAssertTrue(session.hasHeldKey(target: "w5:pA", physicalKeyID: 36))
        XCTAssertFalse(session.hasHeldKey(target: "w5:pA", popup: true, physicalKeyID: 36))
        XCTAssertFalse(session.input(target: "w5:pA", events: [.text("must wait")]))
        XCTAssertTrue(session.input(target: "w5:pA", events: [up]))
        XCTAssertFalse(session.hasHeldKey(target: "w5:pA", physicalKeyID: 36))
        XCTAssertFalse(session.input(target: "w5:pA", events: [up]))
        var inputs: [String] = []
        for _ in 0..<100 {
            let trace = try JSONSerialization.jsonObject(with:
                Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]]
            inputs = trace?.compactMap { $0["payload"] as? String } ?? []
            if inputs.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let expected = try [down, up].map { event in
            try HerdrShellClientMessage.input(target: "w5:pA", popup: false, events: [event]).encoded()
                .dropFirst(4).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(inputs, expected, "A projection gap must neither drop the accepted release nor authorize new input")
    }

    func testNewHerdrWorkspaceCreatesAndSelectsWorkspaceFromDefaultAndHerdr() async throws {
        let (process, endpoint, path) = try await fixture("window-workspace-create")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let defaultID = try XCTUnwrap(workspace.savedWorkspace().localWorkspaceID)
        let defaultTabs = workspace.debugTabIDs
        workspace.newWorkspace(nil)
        let localID = workspace.savedWorkspace().localWorkspaceID
        let localTabs = workspace.debugTabIDs
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        for index in 1...2 {
            workspace.newHerdrWorkspace(nil)
            for _ in 0..<500 {
                if !workspace.debugHerdrOperationPending,
                   workspace.debugFocusedHerdrPane?.herdrBinding?.workspaceID == "wNew\(index)",
                   workspace.debugFocusedHerdrPane?.canAcceptInput == true { break }
                if workspace.herdrLastError != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(workspace.herdrLastError)
            XCTAssertEqual(workspace.debugFocusedHerdrPane?.herdrBinding?.workspaceID, "wNew\(index)")
            XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true)
        }
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        XCTAssertEqual(trace.filter { $0["method"] as? String == "workspace.create" }.count, 2)
        XCTAssertFalse(trace.contains { $0["method"] as? String == "tab.create" })
        workspace.newWorkspace(nil)
        XCTAssertEqual(workspace.savedWorkspace().localWorkspaceName, "Workspace 2")
        XCTAssertNil(workspace.debugFocusedHerdrPane)
        XCTAssertTrue(workspace.savedWorkspace().otherLocalWorkspaces?.contains { $0.id == localID && $0.tabs.map(\.id) == localTabs } == true)
        workspace.selectLocalWorkspace(try XCTUnwrap(localID))
        XCTAssertEqual(workspace.debugTabIDs, localTabs)
        XCTAssertEqual(workspace.savedWorkspace().localWorkspaceID, localID)
        workspace.selectLocalWorkspace(defaultID)
        XCTAssertEqual(workspace.debugTabIDs, defaultTabs)
        XCTAssertTrue(workspace.savedWorkspace().otherLocalWorkspaces?.contains { $0.id == localID } == true)
    }

    func testHerdrTabDragReordersBothDirectionsAndKeepsSelection() async throws {
        let (process, endpoint, path) = try await fixture("window-tabs-reorder")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        for _ in 0..<500 {
            if workspace.debugTabIDs.count == 3, workspace.debugFocusedHerdrPane?.canAcceptInput == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let original = workspace.debugTabIDs
        XCTAssertEqual(original.count, 3)
        guard original.count == 3 else { return }
        let selected = workspace.debugSelectedTabID
        let strip = try XCTUnwrap((workspace.view as? WorkspaceRootView)?.tabStripView)
        let cases: [(tab: UUID, drop: Int, expected: [UUID], insertion: Int)] = [
            (original[0], 2, [original[1], original[0], original[2]], 2),
            (original[0], 3, [original[1], original[2], original[0]], 3),
            (original[0], 0, original, 0),
            (original[2], 0, [original[2], original[0], original[1]], 0)
        ]
        for test in cases {
            let plan = try XCTUnwrap(WorkspaceTabReorderPreviewPlan.make(draggedTabID: test.tab, modelIDs: workspace.debugTabIDs,
                currentPreviewIDs: nil, proposedDisplayIndex: test.drop))
            strip.onMoveTab?(test.tab, plan.modelDestinationIndex)
            for _ in 0..<200 {
                if !workspace.debugHerdrOperationPending, workspace.debugTabIDs == test.expected,
                   workspace.debugFocusedHerdrPane?.canAcceptInput == true { break }
                if workspace.herdrLastError != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(workspace.herdrLastError)
            let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
            let params = try XCTUnwrap(trace.last { $0["method"] as? String == "tab.move" }?["params"] as? [String: Any])
            XCTAssertEqual(params["insert_index"] as? Int, test.insertion)
            XCTAssertEqual(workspace.debugTabIDs, test.expected)
            XCTAssertEqual(workspace.debugSelectedTabID, selected)
            guard workspace.debugTabIDs == test.expected else { return }
        }
        let backend = try await HerdrWorkspaceClient(endpoint: endpoint).snapshot()
        XCTAssertEqual(backend.tabs?.map(\.tab_id), ["w5:t6", "w5:t4", "w5:t5"])
    }

    func testHerdrTabDropStaysSettledDuringSyncAndRollsBackOnRejection() async throws {
        for rejected in [false, true] {
            let (process, endpoint, path) = try await fixture(rejected ? "window-tabs-reorder-rejected" : "window-tabs-reorder-slow")
            defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
            let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
            workspace.herdrErrorHandler = { _ in }
            try workspace.configureHerdrWorkspace(endpoint)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
            window.contentView = workspace.view; window.orderBack(nil)
            defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
            try await workspace.enterHerdrWorkspace("w5")
            for _ in 0..<500 {
                if workspace.debugTabIDs.count == 3, workspace.debugFocusedHerdrPane?.canAcceptInput == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let original = workspace.debugTabIDs
            guard original.count == 3 else { XCTFail("Missing fixture tabs"); return }
            let expected = [original[1], original[2], original[0]]
            let strip = try XCTUnwrap((workspace.view as? WorkspaceRootView)?.tabStripView)
            XCTAssertTrue(strip.commitTabDrop(original[0], proposedDisplayIndex: 3))
            strip.finishTabDrag()
            XCTAssertEqual(strip.debugDisplayedTabIDs, expected, "Mouse-up must keep the dropped order before backend acknowledgement")
            for _ in 0..<200 {
                if strip.items.contains(where: { $0.title == "Updated while waiting" }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(workspace.debugHerdrOperationPending)
            XCTAssertTrue(strip.items.contains { $0.title == "Updated while waiting" })
            XCTAssertEqual(strip.debugDisplayedTabIDs, expected, "Metadata updates must not restore the old order while the request is pending")
            for _ in 0..<500 where workspace.debugHerdrOperationPending { try await Task.sleep(for: .milliseconds(10)) }
            for _ in 0..<200 {
                if workspace.debugTabIDs == (rejected ? original : expected), strip.debugDisplayedTabIDs == workspace.debugTabIDs { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(workspace.debugTabIDs, rejected ? original : expected)
            XCTAssertEqual(strip.debugDisplayedTabIDs, rejected ? original : expected)
            XCTAssertEqual(workspace.debugSelectedTabID, original[0])
            if rejected { XCTAssertNotNil(workspace.herdrLastError) }
            else { XCTAssertNil(workspace.herdrLastError) }
        }
    }

    func testRenameHerdrWorkspaceAndTabUsesBackendLabels() async throws {
        let (process, endpoint, path) = try await fixture("window-workspace-create")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let localID = workspace.savedWorkspace().localWorkspaceID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        workspace.newHerdrWorkspace(nil)
        for _ in 0..<500 {
            if !workspace.debugHerdrOperationPending, workspace.debugFocusedHerdrPane?.canAcceptInput == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let binding = try XCTUnwrap(workspace.debugFocusedHerdrPane?.herdrBinding)
        workspace.updateSelectedWorkspaceName("  Remote Project  ")
        for _ in 0..<500 {
            if !workspace.debugHerdrOperationPending, (workspace.view as? WorkspaceRootView)?.toolbarView.workspaceSwitcher.titleOfSelectedItem == "Remote Project" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(workspace.herdrLastError)
        XCTAssertTrue(workspace.paletteNavigationItems.contains { $0.kind == .workspace && $0.title == "Remote Project" && $0.isCurrent })
        workspace.debugSetSelectedTabTitle("  Build logs  ")
        for _ in 0..<500 {
            if !workspace.debugHerdrOperationPending, workspace.paletteNavigationItems.contains(where: { $0.kind == .tab && $0.title == "Build logs" && $0.isCurrent }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(workspace.herdrLastError)
        XCTAssertTrue(workspace.paletteNavigationItems.contains { $0.kind == .tab && $0.title == "Build logs" && $0.isCurrent })
        XCTAssertNil(workspace.savedWorkspace().tabs.first?.customTitle, "Herdr supplies the tab title")
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        let renameWorkspace = try XCTUnwrap(trace.first { $0["method"] as? String == "workspace.rename" }?["params"] as? [String: Any])
        XCTAssertEqual(renameWorkspace["workspace_id"] as? String, binding.workspaceID)
        XCTAssertEqual(renameWorkspace["label"] as? String, "Remote Project")
        let renameTab = try XCTUnwrap(trace.first { $0["method"] as? String == "tab.rename" }?["params"] as? [String: Any])
        XCTAssertEqual(renameTab["tab_id"] as? String, binding.tabID)
        XCTAssertEqual(renameTab["label"] as? String, "Build logs")
        workspace.selectLocalWorkspace()
        XCTAssertEqual(workspace.savedWorkspace().localWorkspaceID, localID)
        XCTAssertEqual(workspace.savedWorkspace().localWorkspaceName, "Default")
    }

    func testCloseHerdrWorkspaceKeepsLocalPanesAndOtherWorkspaces() async throws {
        let (process, endpoint, path) = try await fixture("window-workspace-create")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let defaultID = workspace.savedWorkspace().localWorkspaceID
        workspace.newWorkspace(nil)
        let localID = workspace.savedWorkspace().localWorkspaceID
        let localTabs = workspace.debugTabIDs
        let command = NSMenuItem(title: "Close Workspace", action: #selector(WorkspaceViewController.closeWorkspace(_:)), keyEquivalent: "")
        XCTAssertTrue(workspace.validateMenuItem(command))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        workspace.newHerdrWorkspace(nil)
        for _ in 0..<500 {
            if !workspace.debugHerdrOperationPending, workspace.debugFocusedHerdrPane?.canAcceptInput == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let binding = try XCTUnwrap(workspace.debugFocusedHerdrPane?.herdrBinding)
        XCTAssertEqual(binding.workspaceID, "wNew1")
        let alert = workspace.closeWorkspaceAlert()
        XCTAssertEqual(alert.messageText, "Close Workspace?")
        XCTAssertEqual(alert.buttons.map(\.title), ["Close Workspace", "Cancel"])
        XCTAssertTrue(alert.informativeText.contains("Herdr workspace"))
        workspace.newBrowserPane(nil)
        let browserID = try XCTUnwrap(workspace.debugFocusedPaneID)
        XCTAssertTrue(workspace.validateMenuItem(command), "Workspace closing must work with a local browser focused")
        workspace.closeHerdrWorkspace(binding: binding)
        for _ in 0..<500 where workspace.debugHerdrOperationPending { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(workspace.herdrLastError)
        XCTAssertTrue(Set(localTabs).isSubset(of: Set(workspace.debugTabIDs)))
        XCTAssertEqual(workspace.savedWorkspace().localWorkspaceID, localID)
        XCTAssertEqual(workspace.savedWorkspace().otherLocalWorkspaces?.first?.id, defaultID)
        XCTAssertTrue(workspace.savedWorkspace().tabs.contains { $0.panes.contains { $0.id == browserID } })
        XCTAssertTrue(workspace.validateMenuItem(command))
        let client = HerdrWorkspaceClient(endpoint: endpoint)
        let snapshot = try await client.snapshot()
        XCTAssertEqual(snapshot.workspaces?.map(\.workspace_id), ["w5"])
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        let closes = trace.filter { $0["method"] as? String == "workspace.close" }
        XCTAssertEqual(closes.count, 1)
        XCTAssertEqual((closes.first?["params"] as? [String: Any])?["workspace_id"] as? String, "wNew1")
        try await workspace.enterHerdrWorkspace("w5")
        for _ in 0..<500 {
            if workspace.validateMenuItem(command) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(workspace.validateMenuItem(command))
        let lastBinding = try XCTUnwrap(workspace.debugFocusedHerdrPane?.herdrBinding)
        workspace.closeHerdrWorkspace(binding: lastBinding)
        for _ in 0..<500 where workspace.debugHerdrOperationPending { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(workspace.herdrLastError)
        XCTAssertTrue(workspace.validateMenuItem(command))
        let emptySnapshot = try await client.snapshot()
        XCTAssertEqual(emptySnapshot.workspaces?.count, 0)
        XCTAssertTrue(workspace.savedWorkspace().tabs.contains { $0.panes.contains { $0.id == browserID } })
    }

    func testEndpointCreationRequestsServerFocusWithoutManagementQueriesOrFollowupNavigation() async throws {
        let (process, endpoint, path) = try await fixture("creation")
        defer { cleanup(process, path) }
        let session = autoPresentedSession(endpoint)
        defer { session.disconnect() }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: true)
        for _ in 0..<200 where !session.isPresentationReady { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.isPresentationReady)
        let client = HerdrWorkspaceClient(endpoint: endpoint)
        try client.routeCommands(to: session)
        let created = try await client.create(workspaceID: "w5")
        XCTAssertEqual(created.pane_id, "w5:pNew")
        XCTAssertEqual(created.serviceIdentity, session.serviceIdentity)
        let binding = try HerdrPaneBinding(endpoint: endpoint,
            pane: .init(pane_id: "w5:pA", terminal_id: nil, workspace_id: "w5", tab_id: "w5:t4",
                        serviceIdentity: session.serviceIdentity))
        _ = try await client.create(split: binding, axis: .vertical)
        let workspace = try await client.create()
        XCTAssertEqual(workspace.workspace_id, "wNew")
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        let creations = trace.filter { ["workspace.create", "tab.create", "pane.split"].contains($0["method"] as? String ?? "") }
        XCTAssertEqual(creations.count, 3)
        XCTAssertTrue(creations.allSatisfy { ($0["params"] as? [String: Any])?["focus"] as? Bool == true })
        XCTAssertFalse(trace.contains { $0["method"] as? String == "pane.focus" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.socketPath))
    }

    func testOrphanDragAndTrackedRepeatDoNotCreateHeldInputOrReachTheWire() async throws {
        let (process, endpoint, path) = try await fixture("normal")
        defer { cleanup(process, path) }
        let session = autoPresentedSession(endpoint)
        defer { session.disconnect() }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: true)
        for _ in 0..<200 where !session.isPresentationReady { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.isPresentationReady)
        let down = HerdrShellInput.mouse(.init(kind: 0, button: 0, column: 0, row: 0))
        let drag = HerdrShellInput.mouse(.init(kind: 2, button: 0, column: 1, row: 0))
        let up = HerdrShellInput.mouse(.init(kind: 1, button: 0, column: 1, row: 0))
        XCTAssertFalse(session.input(target: "w5:pA", events: [drag]))
        XCTAssertFalse(session.hasHeldMouse(target: "w5:pA", button: 0))
        XCTAssertFalse(session.input(target: "w5:pA", events: [.key(.init(code: 1, kind: 1,
            tracksRelease: true, physicalKeyID: 36))]))
        XCTAssertTrue(session.input(target: "w5:pA", events: [down, drag, up]))
        XCTAssertFalse(session.hasHeldMouse(target: "w5:pA", button: 0))
        XCTAssertFalse(session.input(target: "w5:pA", events: [drag]))
        XCTAssertFalse(session.input(target: "w5:pA", events: [up]))
        XCTAssertFalse(session.input(target: "w5:pA", events: [.key(.init(code: 1, kind: 2,
            tracksRelease: true, physicalKeyID: 36))]))
        _ = try await session.request("pane.rename", params: .init(pane_id: "w5:pA", label: "input ledger"))
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        let expected = try HerdrShellClientMessage.input(target: "w5:pA", popup: false,
            events: [down, drag, up]).encoded().dropFirst(4).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(trace.compactMap { $0["payload"] as? String }, [expected],
            "Rejected input cannot create a synthetic release when the next command is sent")
    }

    func testVisibleSiblingFocusKeepsTheGestureAndTabFocusReleasesIt() async throws {
        let (process, endpoint, path) = try await fixture("mouse-focus")
        defer { cleanup(process, path) }
        let session = autoPresentedSession(endpoint)
        defer { session.disconnect() }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: true)
        for _ in 0..<200 where !session.isPresentationReady { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.isPresentationReady)
        XCTAssertEqual(session.projection.snapshot?.focused_pane_id, "w5:pA")
        let down = HerdrShellInput.mouse(.init(kind: 0, button: 0, column: 0, row: 0))
        let drag = HerdrShellInput.mouse(.init(kind: 2, button: 0, column: 0, row: 0))
        let up = HerdrShellInput.mouse(.init(kind: 1, button: 0, column: 0, row: 0))
        XCTAssertTrue(session.input(target: "w5:pB", events: [down]), "The clicked sibling is already a known visible input target")
        _ = try await session.request("pane.focus", params: .init(pane_id: "w5:pB"))
        for _ in 0..<200 where !session.isPresentationReady { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(session.projection.snapshot?.focused_pane_id, "w5:pB")
        XCTAssertTrue(session.isPresentationReady)
        XCTAssertTrue(session.hasHeldMouse(target: "w5:pB", button: 0))
        XCTAssertTrue(session.input(target: "w5:pB", events: [drag]))
        XCTAssertTrue(session.input(target: "w5:pB", events: [up]))
        XCTAssertFalse(session.hasHeldMouse(target: "w5:pB", button: 0))
        XCTAssertTrue(session.input(target: "w5:pB", events: [down]))
        _ = try await session.request("tab.focus", params: .init(tab_id: "w5:t4"))
        XCTAssertFalse(session.hasHeldMouse(target: "w5:pB", button: 0), "The preservation exception belongs only to pane.focus")
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        let expected = try [down, drag, up, down, up].map { event in
            try HerdrShellClientMessage.input(target: "w5:pB", popup: false, events: [event]).encoded()
                .dropFirst(4).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(trace.compactMap { $0["payload"] as? String }, expected,
            "Sibling focus must not inject an early release or route motion into the previously focused pane")
    }

    func testSameViewportPaneFocusKeepsMousePressAndAcceptsItsRealReleaseWhilePending() async throws {
        let (process, endpoint, path) = try await fixture("slow-focus")
        defer { cleanup(process, path) }
        let session = autoPresentedSession(endpoint)
        defer { session.disconnect() }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: true)
        for _ in 0..<200 where !session.isPresentationReady { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.isPresentationReady)
        let down = HerdrShellInput.mouse(.init(kind: 0, button: 0, column: 0, row: 0))
        let up = HerdrShellInput.mouse(.init(kind: 1, button: 0, column: 1, row: 0))
        XCTAssertTrue(session.input(target: "w5:pA", events: [down]))
        let focus = Task { try await session.request("pane.focus", params: .init(pane_id: "w5:pA")) }
        for _ in 0..<100 where session.diagnostics.pendingRequests == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.diagnostics.pendingRequests, 1)
        XCTAssertTrue(session.hasHeldMouse(target: "w5:pA", button: 0))
        XCTAssertFalse(session.input(target: "w5:pA", events: [.mouse(.init(kind: 2, button: 0, column: 1, row: 0))]),
            "Motion is not replayed across pending focus")
        XCTAssertTrue(session.input(target: "w5:pA", events: [up]))
        XCTAssertFalse(session.hasHeldMouse(target: "w5:pA", button: 0))
        _ = try await focus.value
        var trace: [[String: Any]] = []
        for _ in 0..<100 {
            trace = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]]) ?? []
            if trace.compactMap({ $0["payload"] as? String }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let expected = try [down, up].map { event in
            try HerdrShellClientMessage.input(target: "w5:pA", popup: false, events: [event]).encoded()
                .dropFirst(4).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(trace.compactMap { $0["payload"] as? String }, expected,
            "No synthetic early mouse-up may replace the user's actual release coordinates")
    }

    func testRoutedPublicPaneVerificationDoesNotQueryTheManagementSocket() async throws {
        let (process, endpoint, path) = try await fixture("normal")
        defer { cleanup(process, path) }
        let session = autoPresentedSession(endpoint)
        defer { session.disconnect() }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: true)
        for _ in 0..<200 where !session.isPresentationReady { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.isPresentationReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.socketPath), "This fixture has only a client socket")
        let client = HerdrWorkspaceClient(endpoint: endpoint)
        try client.routeCommands(to: session)
        let metadata = HerdrSnapshot.Pane(pane_id: "w5:pA", terminal_id: nil, workspace_id: "w5", tab_id: "w5:t4",
            serviceIdentity: session.serviceIdentity)
        let binding = try HerdrPaneBinding(endpoint: endpoint, pane: metadata)
        let verified = try await client.verify(binding)
        XCTAssertEqual(verified.pane_id, binding.paneID)
        XCTAssertNil(verified.terminal_id, "Endpoint metadata cannot invent a runtime identity")
        let tabIDs = try await client.orderedTabIDs(for: binding)
        XCTAssertEqual(tabIDs, ["w5:t4"], "Tab order comes from the bound endpoint without an API listener")
        _ = try await client.request("pane.rename", params: .init(pane_id: binding.paneID, label: "verified endpoint"))
        let foreign = try HerdrPaneBinding(endpoint: endpoint,
            pane: .init(pane_id: binding.paneID, terminal_id: nil, workspace_id: "another", tab_id: binding.tabID,
                        serviceIdentity: session.serviceIdentity))
        do { _ = try await client.verify(foreign); XCTFail("Foreign endpoint scope was accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no API fallback")) }
        session.disconnect()
        do { _ = try await client.verify(binding); XCTFail("Disconnected endpoint fell back to management API") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no API fallback")) }
        do { _ = try await client.orderedTabIDs(for: binding); XCTFail("Disconnected tab ordering fell back to management API") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no API fallback")) }
    }

    func testFutureEffectsStayQueuedAcrossPinnedAckAndAreDiscardedOnResize() async throws {
        for resize in [false, true] {
            let (process, endpoint, path) = try await fixture("effects-in-flight")
            defer { cleanup(process, path) }
            let session = HerdrClientShellSession(endpoint: endpoint)
            defer { session.disconnect() }
            let pinned = expectation(description: "second frame pinned")
            let latest = resize ? nil : expectation(description: "third frame offered")
            var second: HerdrShellSurface?, third: HerdrShellSurface?
            var effects: [HerdrShellServerMessage] = []
            session.onProjection = { [weak session] _, frame, _ in
                if frame.surface_revision == 65536 { XCTAssertTrue(session?.acknowledgePresentation(frame) == true) }
                else if frame.surface_revision == 65537 {
                    second = frame
                    XCTAssertTrue(session?.beginPresentation(frame) == true)
                    pinned.fulfill()
                } else if frame.surface_revision == 65538 { third = frame; latest?.fulfill() }
            }
            session.onEffect = { effects.append($0) }
            try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: true)
            await fulfillment(of: [pinned], timeout: 5)
            for _ in 0..<200 where session.diagnostics.deferredEffects != 2 {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(session.diagnostics.deferredEffects, 2)
            XCTAssertTrue(effects.isEmpty)
            let frame = try XCTUnwrap(second)
            if resize {
                try session.resize(.init(cols: 3, rows: 1), cellWidth: 8, cellHeight: 16)
                XCTAssertFalse(session.acknowledgePresentation(frame))
                XCTAssertEqual(session.diagnostics.deferredEffects, 0)
                session.disconnect()
                XCTAssertTrue(effects.isEmpty, "Invalidated future effects must not run during disconnect")
            } else {
                XCTAssertTrue(session.acknowledgePresentation(frame))
                XCTAssertTrue(session.isPresentationReady)
                XCTAssertTrue(effects.isEmpty, "An earlier native ACK cannot execute a later picture's effects")
                XCTAssertEqual(session.diagnostics.deferredEffects, 2)
                session.endPresentation(frame)
                await fulfillment(of: [try XCTUnwrap(latest)], timeout: 5)
                XCTAssertTrue(session.acknowledgePresentation(try XCTUnwrap(third)))
                XCTAssertEqual(effects, [.clipboard("future clipboard"), .bell(1)])
                XCTAssertEqual(session.diagnostics.deferredEffects, 0)
                XCTAssertTrue(session.acknowledgePresentation(try XCTUnwrap(third)))
                XCTAssertEqual(effects.count, 2)
            }
        }
    }

    func testPinnedPresentationCompletesDespiteNewerContentAndThenOffersLatest() async throws {
        let (process, endpoint, path) = try await fixture("presentation")
        defer { cleanup(process, path) }
        let session = HerdrClientShellSession(endpoint: endpoint)
        defer { session.disconnect() }
        let initial = expectation(description: "initial offer"), latest = expectation(description: "latest offer after commit")
        var offers: [HerdrShellSurface] = []
        session.onProjection = { _, frame, _ in
            offers.append(frame)
            if offers.count == 1 { initial.fulfill() }
            else if offers.count == 2 { latest.fulfill() }
        }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: true)
        await fulfillment(of: [initial], timeout: 5)
        let first = try XCTUnwrap(offers.first)
        XCTAssertTrue(session.beginPresentation(first))
        for _ in 0..<200 where session.projection.coherentSurface?.surface_revision == first.surface_revision {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(try XCTUnwrap(session.projection.coherentSurface?.surface_revision), first.surface_revision)
        XCTAssertEqual(offers.count, 1, "Continuous content cannot replace an in-progress offer with identical input geometry")
        XCTAssertTrue(session.canPresent(first))
        XCTAssertTrue(session.acknowledgePresentation(first))
        XCTAssertTrue(session.isPresentationReady)
        XCTAssertTrue(session.input(target: "w5:pA", events: [.text("stable geometry")]))
        session.endPresentation(first)
        XCTAssertTrue(session.isPresentationReady)
        XCTAssertTrue(session.isInputReady)
        await fulfillment(of: [latest], timeout: 5)
        let next = try XCTUnwrap(offers.last)
        XCTAssertGreaterThan(next.surface_revision, first.surface_revision)
        XCTAssertTrue(session.beginPresentation(next))
        try session.resize(.init(cols: 3, rows: 1), cellWidth: 8, cellHeight: 16)
        XCTAssertFalse(session.canPresent(next))
        XCTAssertFalse(session.acknowledgePresentation(next))
        XCTAssertFalse(session.isPresentationReady)
        session.endPresentation(next)
    }

    func testMetadataOnlyStartupWaitsForMeasuredNativeViewportBeforeActivation() async throws {
        let (process, endpoint, path) = try await fixture("normal")
        defer { cleanup(process, path) }
        let session = HerdrClientShellSession(endpoint: endpoint)
        defer { session.disconnect() }
        let metadata = expectation(description: "inactive metadata")
        let presented = expectation(description: "activated native presentation")
        var receivedMetadata = false
        session.onMetadata = { _ in
            if !receivedMetadata { receivedMetadata = true; metadata.fulfill() }
        }
        session.onProjection = { [weak session] _, frame, _ in
            if session?.acknowledgePresentation(frame) == true { presented.fulfill() }
        }
        XCTAssertThrowsError(try session.activate(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16))
        try await session.start(size: .init(cols: 80, rows: 24), cellWidth: 0, cellHeight: 0,
            focused: true, activateWhenMetadataReady: false)
        await fulfillment(of: [metadata], timeout: 5)
        XCTAssertNotNil(session.projection.snapshot)
        XCTAssertNil(session.projection.coherentSurface)
        XCTAssertFalse(session.isPresentationReady)
        let inactiveTrace = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        XCTAssertTrue(inactiveTrace.compactMap { $0["tag"] as? Int }.isEmpty,
                      "Metadata must not send resize, activation or focus")
        XCTAssertThrowsError(try session.activate(size: .init(cols: 2, rows: 1), cellWidth: 0, cellHeight: 16))
        try session.activate(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16)
        XCTAssertThrowsError(try session.activate(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16))
        await fulfillment(of: [presented], timeout: 5)
        XCTAssertTrue(session.isPresentationReady)
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        XCTAssertEqual(Array(trace.compactMap { $0["tag"] as? Int }.prefix(3)), [12, 15, 18],
            "Measured resize must precede activation and host focus on the same transport")
    }

    func testPresentationEffectsWaitForNativeCommitAndAreNotReplayed() async throws {
        let (process, endpoint, path) = try await fixture("effects")
        defer { cleanup(process, path) }
        let session = HerdrClientShellSession(endpoint: endpoint)
        defer { session.disconnect() }
        let ready = expectation(description: "first frame committed"), updated = expectation(description: "next frame offered")
        var initial: HerdrShellSurface?, pending: HerdrShellSurface?
        var effects: [HerdrShellServerMessage] = []
        session.onProjection = { [weak session] _, frame, _ in
            if initial == nil { initial = frame; XCTAssertTrue(session?.acknowledgePresentation(frame) == true); ready.fulfill() }
            else { pending = frame; updated.fulfill() }
        }
        session.onEffect = { effects.append($0) }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: false)
        await fulfillment(of: [ready, updated], timeout: 5)
        for _ in 0..<100 where session.diagnostics.deferredEffects != 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(session.diagnostics.deferredEffects, 2)
        XCTAssertTrue(effects.isEmpty)
        XCTAssertFalse(session.isPresentationReady)
        XCTAssertTrue(session.acknowledgePresentation(try XCTUnwrap(pending)))
        XCTAssertEqual(effects, [.clipboard("fixture clipboard"), .bell(1)])
        XCTAssertEqual(session.diagnostics.deferredEffects, 0)
        XCTAssertTrue(session.acknowledgePresentation(try XCTUnwrap(pending)))
        XCTAssertEqual(effects.count, 2)
    }

    func testHostColorsBaselineAndOnlyChangedColorsAreSent() async throws {
        let (process, endpoint, path) = try await fixture("normal")
        defer { cleanup(process, path) }
        let session = autoPresentedSession(endpoint)
        defer { session.disconnect() }
        let ready = expectation(description: "color baseline active")
        session.onState = { if $0 == .interactive { ready.fulfill() } }
        let colors = HerdrShellHostColors(foreground: .init(r: 255, g: 251, b: 254),
            background: .init(r: 1, g: 2, b: 3), palette: [255: .init(r: 4, g: 5, b: 6)])
        try session.setHostColors(colors)
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: false)
        await fulfillment(of: [ready], timeout: 5)
        session.onState = nil
        try session.setHostColors(colors)
        try session.setHostColors(.init(foreground: colors.foreground,
            background: .init(r: 7, g: 8, b: 9), palette: colors.palette))
        var trace: [[String: Any]] = []
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path + ".trace")),
               let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { trace = value }
            if trace.filter({ $0["tag"] as? Int == 17 }).count == 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(trace.filter { $0["tag"] as? Int == 17 }.compactMap { $0["payload"] as? String },
            ["110000fffbfe", "110001010203", "110101ff040506", "110001070809"])
        XCTAssertLessThan(try XCTUnwrap(trace.firstIndex { $0["method"] as? String == "client_shell.surface.set" }),
                          try XCTUnwrap(trace.firstIndex { $0["tag"] as? Int == 17 }))
    }

    func testHostAppearanceBaselineIsSentAfterActivationAndChangesAreDeduplicated() async throws {
        let (process, endpoint, path) = try await fixture("normal")
        defer { cleanup(process, path) }
        let session = autoPresentedSession(endpoint)
        defer { session.disconnect() }
        let ready = expectation(description: "theme baseline active")
        session.onState = { if $0 == .interactive { ready.fulfill() } }
        try session.setAppearance(dark: true)
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: false)
        await fulfillment(of: [ready], timeout: 5)
        session.onState = nil
        try session.setAppearance(dark: true)
        try session.setAppearance(dark: false)
        try session.setAppearance(dark: false)
        var trace: [[String: Any]] = []
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path + ".trace")),
               let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { trace = value }
            if trace.filter({ $0["tag"] as? Int == 17 }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(trace.filter { $0["tag"] as? Int == 17 }.compactMap { $0["payload"] as? String }, ["110200", "110201"])
        XCTAssertLessThan(try XCTUnwrap(trace.firstIndex { $0["method"] as? String == "client_shell.surface.set" }),
                          try XCTUnwrap(trace.firstIndex { $0["tag"] as? Int == 17 }))
        XCTAssertEqual(session.diagnostics.hostDark, false)
    }

    func testEstablishedWindowReportsFatalClientShellFailureInsteadOfSilentlyFreezing() async throws {
        let (process, endpoint, path) = try await fixture("window-tabs-failure")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        var reported: [String] = []
        workspace.herdrErrorHandler = { reported.append($0) }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let pane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        let second = try XCTUnwrap(workspace.debugTabIDs.first { $0 != workspace.debugSelectedTabID })
        workspace.debugSelectTab(withID: second)
        for _ in 0..<300 where !reported.contains("Invalid Herdr boolean") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(reported.contains("Invalid Herdr boolean"))
        XCTAssertFalse(pane.canAcceptInput)
        let report = await workspace.collectHerdrDiagnostics()
        XCTAssertEqual(report.clientShell?.state, "failed")
        XCTAssertTrue(process.isRunning)
    }

    func testEndpointRejectionReportsNoticeAndKeepsTabNavigationAndInputWorking() async throws {
        let (process, endpoint, path) = try await fixture("window-tabs-rejection")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        var reported: [String] = []
        workspace.herdrErrorHandler = { reported.append($0) }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let first = try XCTUnwrap(workspace.debugSelectedTabID)
        let second = try XCTUnwrap(workspace.debugTabIDs.first { $0 != first })
        workspace.debugSelectTab(withID: second)
        for _ in 0..<300 where workspace.debugSelectedTabID != second || workspace.debugFocusedHerdrPane?.canAcceptInput != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(workspace.debugSelectedTabID, second)
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true)
        XCTAssertTrue(reported.contains("Paste rejected: fixture"))
        workspace.debugSelectTab(withID: first)
        for _ in 0..<300 where workspace.debugSelectedTabID != first || workspace.debugFocusedHerdrPane?.canAcceptInput != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(workspace.debugSelectedTabID, first)
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true)
        let report = await workspace.collectHerdrDiagnostics()
        XCTAssertEqual(report.clientShell?.state, "control")
        XCTAssertEqual(report.clientShell?.recoveryAttempts, 0)
        XCTAssertTrue(process.isRunning)
    }

    func testWindowReconnectsAfterAnEstablishedStreamDropsWithoutRestartingService() async throws {
        let (process, endpoint, path) = try await fixture("window-drop")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let pane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        var connectionCount = 0
        for _ in 0..<800 {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path + ".trace")),
               let trace = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                connectionCount = trace.filter { $0["connection"] != nil }.count
            }
            if connectionCount == 2, !workspace.debugHerdrOperationPending, pane.canAcceptInput { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(connectionCount, 2)
        XCTAssertFalse(workspace.debugHerdrOperationPending)
        XCTAssertTrue(pane.canAcceptInput)
        XCTAssertEqual(workspace.debugFocusedHerdrPane?.id, pane.id)
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(pane.herdrBinding?.serviceIdentity?.pid, process.processIdentifier)
    }

    func testWindowPopupRendersAndRoutesInputBeforeRestoringPaneFocus() async throws {
        let (process, endpoint, path) = try await fixture("window-popup")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let root = try XCTUnwrap(workspace.view as? WorkspaceRootView)
        let popup = try XCTUnwrap(root.debugHerdrPopupView as? TerminalView)
        let pane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        let popupController = try XCTUnwrap(popup.delegate as? HerdrClientShellPopupController)
        XCTAssertTrue(popupController.canAcceptInput, "Popup focus commits with native presentation readiness")
        XCTAssertTrue(popup.readScreenText()?.contains("Herdr popup") == true)
        XCTAssertFalse(pane.canAcceptInput)
        XCTAssertTrue(window.firstResponder === popup)
        XCTAssertEqual(workspace.savedWorkspace().tabs.flatMap(\.panes).count, 1, "Popup is not a persisted backend pane")
        popup.insertText("close fixture popup", replacementRange: NSRange(location: NSNotFound, length: 0))
        for _ in 0..<200 {
            if root.debugHerdrPopupView == nil, pane.canAcceptInput { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(root.debugHerdrPopupView)
        XCTAssertTrue(pane.canAcceptInput)
        XCTAssertTrue(window.firstResponder === pane.focusTargetView)
        XCTAssertTrue(pane.clientShellGridMetrics != nil, "Popup dismissal restores an already prepared pane host")
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        XCTAssertEqual(trace.filter { $0["tag"] as? Int == 14 }.count, 1)
        XCTAssertFalse(trace.contains { $0["tag"] as? Int == 13 }, "Popup text must not enter the underlying pane")
        XCTAssertTrue(process.isRunning)
    }

    func testClientShellTabSwitchFromLocalBrowserShowsTargetPopupAndRetainsAuxiliaryContent() async throws {
        let (process, endpoint, path) = try await fixture("window-tabs")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let root = try XCTUnwrap(workspace.view as? WorkspaceRootView)
        let firstTab = try XCTUnwrap(workspace.debugSelectedTabID)
        let firstPane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        let secondTab = try XCTUnwrap(workspace.debugTabIDs.first { $0 != firstTab })
        workspace.newBrowserPane(nil)
        let browserID = try XCTUnwrap(workspace.debugFocusedPaneID)
        workspace.debugSetFocusedPaneName("Keep local browser")
        await Task.yield()
        for _ in 0..<200 where !firstPane.canAcceptInput { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(workspace.debugFocusedPaneIsBrowser, "Same-tab surface updates preserve local focus")
        workspace.debugSelectTab(withID: secondTab)
        for _ in 0..<300 {
            if workspace.debugSelectedTabID == secondTab, root.debugHerdrPopupView != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(workspace.debugSelectedTabID, secondTab,
                       "Local focus cannot pin the old backend tab: \(workspace.herdrLastError ?? "no error")")
        let popup = try XCTUnwrap(root.debugHerdrPopupView as? TerminalView)
        for _ in 0..<200 where popup.readScreenText()?.contains("Herdr popup") != true { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(popup.readScreenText()?.contains("Herdr popup") == true)
        let popupController = try XCTUnwrap(popup.delegate as? HerdrClientShellPopupController)
        for _ in 0..<200 where !popupController.canAcceptInput { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(popupController.canAcceptInput)
        XCTAssertTrue(window.firstResponder === popup)
        let secondPane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        XCTAssertEqual(secondPane.herdrBinding?.paneID, "w5:pB")
        XCTAssertFalse(secondPane.canAcceptInput)
        workspace.debugSelectTab(withID: firstTab)
        workspace.debugSelectTab(withID: secondTab)
        XCTAssertFalse(popupController.canAcceptInput)
        for _ in 0..<300 {
            let current = (root.debugHerdrPopupView as? TerminalView)?.delegate as? HerdrClientShellPopupController
            if !workspace.debugHerdrOperationPending, current?.canAcceptInput == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let resumedPopup = try XCTUnwrap(root.debugHerdrPopupView as? TerminalView)
        let resumedController = try XCTUnwrap(resumedPopup.delegate as? HerdrClientShellPopupController)
        XCTAssertTrue(resumedController.canAcceptInput, "A rapid round trip must restore input to the presented popup")
        resumedPopup.insertText("dismiss", replacementRange: NSRange(location: NSNotFound, length: 0))
        for _ in 0..<200 where root.debugHerdrPopupView != nil || !secondPane.canAcceptInput {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(root.debugHerdrPopupView)
        XCTAssertTrue(secondPane.canAcceptInput)
        workspace.debugSelectTab(withID: firstTab)
        for _ in 0..<200 where workspace.debugSelectedTabID != firstTab || !firstPane.canAcceptInput {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(workspace.debugSelectedTabID, firstTab)
        XCTAssertTrue(workspace.debugSelectedTabContainsPane(withID: browserID))
        let saved = workspace.savedWorkspace()
        XCTAssertEqual(saved.tabs.first { $0.id == firstTab }?.panes.first { $0.id == browserID }?.name, "Keep local browser")
        try saved.validate()
        workspace.debugFocusPane(withID: browserID)
        XCTAssertTrue(workspace.debugFocusedPaneIsBrowser)
        XCTAssertTrue(process.isRunning)
    }

    func testExternalSplitTopologyPromotesNewDisplaysWithoutReplacingExistingPaneIdentity() async throws {
        let (process, endpoint, path) = try await fixture("window-split")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let pane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        let oldHost = pane.hostView, tab = try XCTUnwrap(workspace.debugSelectedTabID)
        workspace.debugSetFocusedPaneName("trigger external split")
        for _ in 0..<300 where workspace.debugPaneIDsInTraversalOrder.count != 2 || !pane.canAcceptInput || pane.hostView === oldHost {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(workspace.debugPaneIDsInTraversalOrder.count, 2, workspace.herdrLastError ?? "")
        XCTAssertEqual(workspace.debugSelectedTabID, tab)
        XCTAssertTrue(workspace.debugFocusedHerdrPane === pane)
        XCTAssertFalse(pane.hostView === oldHost, "The resized backend uses a separately prepared native display")
        XCTAssertTrue(pane.canAcceptInput)
        XCTAssertTrue(process.isRunning)
        try workspace.savedWorkspace().validate()
        let root = try XCTUnwrap(workspace.view as? WorkspaceRootView)
        let tiling = try XCTUnwrap(root.contentContainerView.subviews.compactMap { $0 as? WorkspaceTilingView }.first)
        XCTAssertTrue(tiling.commitsDividerChangesOnMouseUp)
        let firstFrame = try XCTUnwrap(tiling.paneViews[pane.id]?.frame)
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            let point = tiling.convert(NSPoint(x: x, y: tiling.bounds.midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseDragged, x: tiling.bounds.width * 0.6), atStart: false)
        NSApp.postEvent(try event(.leftMouseDragged, x: tiling.bounds.width * 0.65), atStart: false)
        NSApp.postEvent(try event(.leftMouseUp, x: tiling.bounds.width * 0.65), atStart: false)
        tiling.mouseDown(with: try event(.leftMouseDown, x: firstFrame.maxX + WorkspaceLayoutMetrics.dividerThickness / 2))
        let finalRatio = try XCTUnwrap(tiling.debugCurrentFractions(at: [])?.first)
        var requests: [[String: Any]] = []
        for _ in 0..<200 {
            let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
            requests = trace.filter { $0["method"] as? String == "layout.set_split_ratio" }
            if !workspace.debugHerdrOperationPending, pane.canAcceptInput, !requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(requests.count, 1, "The entire drag sends only its final ratio")
        let params = try XCTUnwrap(requests.first?["params"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(params["ratio"] as? Double), Double(finalRatio), accuracy: 0.0001)
    }

    func testRepeatedNativeTabSwitchesAcceptStableContentPatchAfterUnstableRender() async throws {
        let (process, endpoint, path) = try await fixture("window-tabs-patch-content")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let first = try XCTUnwrap(workspace.debugSelectedTabID)
        let second = try XCTUnwrap(workspace.debugTabIDs.first { $0 != first })
        for index in 0..<40 {
            let target = index % 2 == 0 ? second : first
            workspace.debugSelectTab(withID: target)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while ProcessInfo.processInfo.systemUptime < deadline {
                if workspace.debugSelectedTabID == target, !workspace.debugHerdrOperationPending,
                   workspace.debugFocusedHerdrPane?.canAcceptInput == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(workspace.debugSelectedTabID, target, "Tab switch \(index): \(workspace.herdrLastError ?? "no error")")
            XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true, "Input after switch \(index)")
            XCTAssertFalse(workspace.debugHerdrOperationPending)
        }
        let report = await workspace.collectHerdrDiagnostics()
        XCTAssertTrue(report.clientShell?.presentationReady == true)
        XCTAssertTrue(process.isRunning)
    }

    func testTypingPatchesReachNativePaneWithoutDroppingInput() async throws {
        do { try await exerciseTypingPatches("window-typing") }
        catch { XCTFail("Native typing benchmark: \(error)") }
    }

    func testRealHerdrServiceTypingAndScrollBenchmark() async throws {
        try await exerciseRealHerdrService(scenarios: ["single", "large", "split"], typingCount: 1100)
    }

    func testRealHerdrFloatingPaneRestoresInputAfterTabSwitch() async throws {
        try await exerciseRealHerdrService(scenarios: ["floating"], typingCount: 0)
    }

    func testRealHerdrFloatingPaneStaysCurrentAcrossWorkspaceSwitches() async throws {
        try await exerciseRealHerdrService(scenarios: ["floating-workspace"], typingCount: 0)
    }

    func testRealHerdrAlternateScreenKeepsInactivePaneSurface() async throws {
        try await exerciseRealHerdrService(scenarios: ["split"], typingCount: 4)
    }

    func testRealHerdrSharedBordersKeepInactivePaneSurface() async throws {
        try await exerciseRealHerdrService(scenarios: ["split"], typingCount: 4,
            uiConfig: "[ui]\npane_gaps = false\npane_outer_borders = false\n")
    }

    func testRealHerdrDisabledScrollbarsKeepInactivePaneSurface() async throws {
        try await exerciseRealHerdrService(scenarios: ["split"], typingCount: 4,
            uiConfig: "[ui]\npane_borders = \"always\"\npane_gaps = true\npane_outer_borders = false\npane_scrollbars = false\n", focusFirstPane: true)
    }

    private func exerciseRealHerdrService(scenarios: [String], typingCount: Int, uiConfig: String = "", focusFirstPane: Bool = false) async throws {
        guard let binary = ProcessInfo.processInfo.environment["SANTTY_HERDR_PERF_BINARY"] else {
            throw XCTSkip("Set TEST_RUNNER_SANTTY_HERDR_PERF_BINARY to an installed Herdr binary")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let workload = root.appendingPathComponent("Scripts/herdr-performance-workload.py")
        let directory = URL(fileURLWithPath: "/tmp/santty-real-herdr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.toml")
        let configEncoder = JSONEncoder(); configEncoder.outputFormatting = [.withoutEscapingSlashes]
        let shell = String(decoding: try configEncoder.encode(workload.path), as: UTF8.self)
        try ("[terminal]\ndefault_shell = \(shell)\nshell_mode = \"non_login\"\n[update]\nversion_check = false\nmanifest_check = false\n" + uiConfig).write(to: config, atomically: true, encoding: .utf8)
        let socket = directory.appendingPathComponent("herdr.sock").path
        let endpoint = HerdrEndpoint(binary: URL(fileURLWithPath: binary), session: "benchmark", socketPath: socket)
        let process = Process()
        process.executableURL = endpoint.binary; process.arguments = ["server"]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["HERDR_SOCKET_PATH"] = socket; environment["HERDR_CONFIG_PATH"] = config.path
        environment["XDG_CONFIG_HOME"] = directory.appendingPathComponent("config").path
        environment["XDG_STATE_HOME"] = directory.appendingPathComponent("state").path
        process.environment = environment
        let log = directory.appendingPathComponent("server.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        process.standardOutput = output; process.standardError = output
        defer { try? output.close() }
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: socket) && process.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard process.isRunning, FileManager.default.fileExists(atPath: socket) else {
            throw CLIError(String(decoding: try Data(contentsOf: log), as: UTF8.self))
        }
        do {
            let client = HerdrWorkspaceClient(endpoint: endpoint)
            let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
            workspace.herdrErrorHandler = { _ in }
            try workspace.configureHerdrWorkspace(endpoint)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
            window.ignoresMouseEvents = true
            window.contentView = workspace.view; window.orderBack(nil)
            defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
            func terminal(in view: NSView) -> TerminalView? {
                if let terminal = view as? TerminalView { return terminal }
                return view.subviews.lazy.compactMap { terminal(in: $0) }.first
            }
            for scenario in scenarios {
                if scenario == "large" || scenario == "split" { window.setContentSize(NSSize(width: 2400, height: 1200)) }
                let created = try await client.create(cwd: directory.path)
                if scenario == "floating-workspace" {
                    let split = try await client.create(split: HerdrPaneBinding(endpoint: endpoint, pane: created))
                    _ = try await client.request("pane.focus", params: .init(pane_id: split.pane_id))
                }
                try await workspace.enterHerdrWorkspace(try XCTUnwrap(created.workspace_id))
                if scenario == "split" { workspace.debugPerformCommand(withID: "pane.split.horizontal") }
                for _ in 0..<500 where workspace.debugFocusedHerdrPane?.canAcceptInput != true || workspace.debugHerdrOperationPending
                    || workspace.debugHerdrShellSession?.isPresentationReady != true
                    || (["split", "floating-workspace"].contains(scenario) && workspace.debugPaneIDsInTraversalOrder.count != 2) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                if focusFirstPane {
                    workspace.debugHandlePaneFocusRequest(withID: try XCTUnwrap(workspace.debugPaneIDsInTraversalOrder.first))
                    for _ in 0..<500 where workspace.debugHerdrOperationPending || workspace.debugFocusedHerdrPane?.canAcceptInput != true {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                if scenario == "floating" || scenario == "floating-workspace" {
                    let tabID = try XCTUnwrap(workspace.debugSelectedTabID)
                    workspace.debugToggleFloatingPane(animated: false)
                    await workspace.waitForHerdrFloatingTransitionForTesting()
                    let floating = try XCTUnwrap(workspace.debugFocusedHerdrPane)
                    XCTAssertEqual(workspace.debugActiveFloatingPaneState?.paneID, floating.id)
                    XCTAssertTrue(floating.canAcceptInput, workspace.herdrLastError ?? "Floating input unavailable")
                    guard workspace.debugActiveFloatingPaneState?.paneID == floating.id, floating.canAcceptInput else { return }
                    if scenario == "floating-workspace" {
                        let selected = workspace.debugSelectedWorkspace
                        let other = try await client.create(cwd: directory.path)
                        let targets = [try XCTUnwrap(workspace.debugWorkspaceEntries.first { $0.kind == .local }?.reference),
                            WorkspaceReference(source: .herdr(endpoint: endpoint, workspaceID: try XCTUnwrap(other.workspace_id)))]
                        for target in targets {
                            workspace.selectWorkspace(target); await workspace.waitForWorkspaceSelection()
                            for _ in 0..<1000 where workspace.debugSelectedWorkspace != target || workspace.debugHerdrOperationPending
                                || (target.kind != .local && workspace.debugFocusedHerdrPane?.canAcceptInput != true) {
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            XCTAssertEqual(workspace.debugSelectedWorkspace, target, "Leaving floating workspace: \(workspace.herdrLastError ?? "no error")")
                            workspace.selectWorkspace(selected); await workspace.waitForWorkspaceSelection()
                            for _ in 0..<1000 where workspace.debugSelectedWorkspace != selected || workspace.debugHerdrOperationPending
                                || workspace.debugHerdrShellSession?.isPresentationReady != true || !floating.canAcceptInput {
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            XCTAssertEqual(workspace.debugSelectedWorkspace, selected, "Returning floating workspace: \(workspace.herdrLastError ?? "no error")")
                            XCTAssertEqual(workspace.debugActiveFloatingPaneState?.paneID, floating.id)
                            XCTAssertEqual(workspace.debugFocusedPaneID, floating.id, "The visible floating pane must remain current")
                            XCTAssertTrue(window.firstResponder === floating.focusTargetView,
                                "Return from \(target.kind) must restore floating keyboard focus; responder=\(String(describing: window.firstResponder)), expected=\(floating.focusTargetView)")
                            workspace.debugHandlePaneFocusRequest(withID: floating.id)
                            await workspace.waitForHerdrFloatingTransitionForTesting()
                            XCTAssertEqual(workspace.debugActiveFloatingPaneState?.paneID, floating.id, "Clicking the floating pane must keep it floating")
                            XCTAssertEqual(workspace.debugFocusedPaneID, floating.id)
                        }
                        continue
                    }
                    workspace.newTab(nil)
                    for _ in 0..<1000 where workspace.debugTabIDs.count != 2 || workspace.debugSelectedTabID == tabID
                        || workspace.debugHerdrOperationPending || workspace.debugFocusedHerdrPane?.canAcceptInput != true {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertEqual(workspace.debugTabIDs.count, 2)
                    XCTAssertNotEqual(workspace.debugSelectedTabID, tabID)
                    workspace.debugSelectTab(withID: tabID)
                    for _ in 0..<1000 where workspace.debugFocusedHerdrPane?.id != floating.id
                        || workspace.debugHerdrOperationPending || !floating.canAcceptInput {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertTrue(floating.canAcceptInput, workspace.herdrLastError ?? "Floating input did not resume")
                    XCTAssertTrue(window.firstResponder === floating.focusTargetView, "Tab return must restore keyboard focus without a click")
                    (window.firstResponder as? TerminalView)?.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
                    for _ in 0..<500 where terminal(in: floating.hostView)?.readScreenText()?.hasPrefix("X") != true {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertTrue(terminal(in: floating.hostView)?.readScreenText()?.hasPrefix("X") == true,
                                  "Typing through the restored first responder must reach the floating PTY")
                    continue
                }
                let pane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
                let display = try XCTUnwrap(terminal(in: pane.hostView))
                let rootView = try XCTUnwrap(workspace.view as? WorkspaceRootView)
                let tiling = try XCTUnwrap(rootView.contentContainerView.subviews.compactMap { $0 as? WorkspaceTilingView }.first)
                let sibling = tiling.paneViews.values.compactMap { terminal(in: $0) }.first { $0 !== display }
                for _ in 0..<500 where display.readScreenText()?.hasPrefix("READY") != true || (sibling != nil && sibling?.readScreenText()?.hasPrefix("READY") != true) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let siblingText = sibling?.readScreenText()
                let logs = RenderOutputLog()
                let oldSink = TerminalDebugLog.sink, oldCategories = TerminalDebugLog.categories, oldEnabled = TerminalDebugLog.isEnabled
                TerminalDebugLog.sink = { logs.append($0) }; TerminalDebugLog.enable(.output)
                defer { TerminalDebugLog.sink = oldSink; TerminalDebugLog.categories = oldCategories; TerminalDebugLog.isEnabled = oldEnabled }
                var milliseconds: [Double] = []
                for index in 0..<typingCount {
                    let text = index % 2 == 0 ? "X" : "Y"
                    let start = ProcessInfo.processInfo.systemUptime
                    guard pane.sendClientShellInput([.text(text)]) else { throw CLIError("Real service input rejected") }
                    while display.readScreenText()?.hasPrefix(text) != true && ProcessInfo.processInfo.systemUptime - start < 2 {
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    guard display.readScreenText()?.hasPrefix(text) == true else {
                        throw CLIError(workspace.herdrLastError ?? "Real service echo missing: \(String((display.readScreenText() ?? "nil").prefix(300)))")
                    }
                    if let sibling {
                        XCTAssertTrue(sibling.window === window, "Typing must preserve the inactive surface")
                        XCTAssertEqual(sibling.readScreenText(), siblingText)
                    }
                    if index >= 100 { milliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                print("HERDR_REAL_TYPING scenario=\(scenario) " + String(decoding: try encoder.encode(milliseconds), as: UTF8.self))
                let scrollAt = ProcessInfo.processInfo.systemUptime
                XCTAssertTrue(pane.sendClientShellInput([.text("S")]))
                while display.readScreenText()?.contains("SCROLL_DONE") != true && ProcessInfo.processInfo.systemUptime - scrollAt < 5 {
                    try await Task.sleep(for: .milliseconds(1))
                }
                XCTAssertTrue(display.readScreenText()?.contains("SCROLL_DONE") == true, "Continuous output must reach its final frame")
                XCTAssertTrue(logs.clears.isEmpty, "Real Herdr content updates cleared Ghostty: \(logs.clears.prefix(3))")
                if let sibling {
                    XCTAssertTrue(sibling.window === window, "Scroll output must preserve the inactive surface")
                    XCTAssertEqual(sibling.readScreenText(), siblingText)
                    for kind: UInt32 in [4, 5, 4, 5] {
                        XCTAssertTrue(pane.sendClientShellInput([.mouse(.init(kind: kind, column: 0, row: 0, lines: 5))]))
                        try await Task.sleep(for: .milliseconds(50))
                        XCTAssertTrue(sibling.window === window, "Wheel input must preserve the inactive surface")
                        XCTAssertEqual(sibling.readScreenText(), siblingText)
                    }
                    let normalSurface = try XCTUnwrap(workspace.debugHerdrShellSession?.projection.coherentSurface)
                    let nativeSibling = try XCTUnwrap(normalSurface.panes.first { $0.pane_id != pane.herdrBinding?.paneID })
                    XCTAssertTrue(pane.sendClientShellInput([.text("A")]))
                    for _ in 0..<500 where terminal(in: pane.hostView)?.readScreenText()?.hasPrefix("ALTERNATE") != true || !pane.canAcceptInput {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertTrue(terminal(in: pane.hostView)?.readScreenText()?.hasPrefix("ALTERNATE") == true)
                    XCTAssertEqual(workspace.debugHerdrShellSession?.projection.coherentSurface?.frame.width, normalSurface.frame.width)
                    XCTAssertEqual(workspace.debugHerdrShellSession?.projection.coherentSurface?.panes.first { $0.pane_id == nativeSibling.pane_id }?.inner_rect,
                                   nativeSibling.inner_rect, "Alternate screen must not resize the inactive PTY")
                    XCTAssertTrue(sibling.window === window, "Entering an alternate screen in one pane must preserve the inactive surface")
                    XCTAssertEqual(sibling.readScreenText(), siblingText)
                    XCTAssertTrue(pane.sendClientShellInput([.text("N")]))
                    for _ in 0..<500 where terminal(in: pane.hostView)?.readScreenText()?.contains("SCROLL_DONE") != true || !pane.canAcceptInput {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertTrue(sibling.window === window, "Leaving an alternate screen in one pane must preserve the inactive surface")
                    XCTAssertEqual(workspace.debugHerdrShellSession?.projection.coherentSurface?.frame.width, normalSurface.frame.width)
                    XCTAssertEqual(workspace.debugHerdrShellSession?.projection.coherentSurface?.panes.first { $0.pane_id == nativeSibling.pane_id }?.inner_rect, nativeSibling.inner_rect)
                }
                let report = await workspace.collectHerdrDiagnostics()
                print("HERDR_REAL_DIAGNOSTICS scenario=\(scenario) " + String(decoding: try encoder.encode(report.clientShell), as: UTF8.self))
                print("HERDR_REAL_SCROLL scenario=\(scenario) milliseconds=\((ProcessInfo.processInfo.systemUptime - scrollAt) * 1000)")
                XCTAssertNil(workspace.herdrLastError)
            }
        } catch {
            XCTFail("Real service benchmark: \(error)")
        }
    }

    func testTypingPatchesKeepTheUnchangedSplitPanePresented() async throws {
        do { try await exerciseTypingPatches("window-typing-split") }
        catch { XCTFail("Native split typing benchmark: \(error)") }
    }

    func testTypingFullFramesDoNotClearTheUnchangedSplitPane() async throws {
        try await exerciseTypingPatches("window-typing-full-split")
    }

    private func exerciseTypingPatches(_ scenario: String) async throws {
        let (process, endpoint, path) = try await fixture(scenario)
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2400, height: 1200), styleMask: [], backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let pane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        func terminal(in view: NSView) -> TerminalView? {
            if let terminal = view as? TerminalView { return terminal }
            return view.subviews.lazy.compactMap { terminal(in: $0) }.first
        }
        let display = try XCTUnwrap(terminal(in: pane.hostView))
        var sibling: TerminalView?
        if scenario.hasSuffix("split") {
            let root = try XCTUnwrap(workspace.view as? WorkspaceRootView)
            let tiling = try XCTUnwrap(root.contentContainerView.subviews.compactMap { $0 as? WorkspaceTilingView }.first)
            sibling = try XCTUnwrap(tiling.paneViews.values.compactMap { terminal(in: $0) }.first { $0 !== display })
            XCTAssertTrue(sibling?.readScreenText()?.contains("Unchanged sibling") == true)
        }
        let siblingText = sibling?.readScreenText()
        let logs = RenderOutputLog()
        let oldSink = TerminalDebugLog.sink, oldCategories = TerminalDebugLog.categories, oldEnabled = TerminalDebugLog.isEnabled
        TerminalDebugLog.sink = { logs.append($0) }
        TerminalDebugLog.enable(.output)
        defer { TerminalDebugLog.sink = oldSink; TerminalDebugLog.categories = oldCategories; TerminalDebugLog.isEnabled = oldEnabled }
        var samples = HerdrShellLatencySamples()
        var echoMilliseconds: [Double] = []
        let count = scenario == "window-typing-full-split" ? 180 : 1100
        for index in 0..<count {
            let text = index % 2 == 0 ? "X" : "Y"
            let start = ProcessInfo.processInfo.systemUptime
            guard pane.sendClientShellInput([.text(text)]) else { throw CLIError("Input \(index) was rejected") }
            while display.readScreenText()?.hasPrefix(text) != true && ProcessInfo.processInfo.systemUptime - start < 2 {
                try await Task.sleep(for: .milliseconds(1))
            }
            guard display.readScreenText()?.hasPrefix(text) == true else {
                throw CLIError(workspace.herdrLastError ?? "Missing echo \(index)")
            }
            if let sibling {
                XCTAssertTrue(sibling.window === window, "Content updates must retain the sibling surface")
                XCTAssertEqual(sibling.readScreenText(), siblingText)
            }
            if index >= 100 {
                let duration = ProcessInfo.processInfo.systemUptime - start
                samples.record(seconds: duration); echoMilliseconds.append(duration * 1000)
            }
        }
        let report = await workspace.collectHerdrDiagnostics()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print("HERDR_TYPING_BENCHMARK scenario=\(scenario) echo=" + String(decoding: try encoder.encode(samples.summary), as: UTF8.self))
        print("HERDR_TYPING_BENCHMARK scenario=\(scenario) host=" + String(decoding: try encoder.encode(report.clientShell?.sceneOfferToHostCommit), as: UTF8.self))
        print("HERDR_TYPING_SAMPLES scenario=\(scenario) " + String(decoding: try encoder.encode(echoMilliseconds), as: UTF8.self))
        print("HERDR_STAGE_BENCHMARK scenario=\(scenario) " + String(decoding: try encoder.encode(report.clientShell?.stages), as: UTF8.self))
        let stages = try XCTUnwrap(report.clientShell?.stages)
        for stage in ["payloadRead", "wireDecode", "mainActorQueue", "patchApply", "publish", "encodeQueue", "encode", "encodeActorResume", "paneViewport", "scenePrepare", "ghosttyBarrier", "hostFinalize"] {
            if stage == "patchApply", scenario == "window-typing-full-split" { continue }
            let timing = try XCTUnwrap(stages[stage], stage)
            XCTAssertGreaterThan(timing.sampleCount, 0, stage)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(timing.p99Milliseconds), try XCTUnwrap(timing.p95Milliseconds), stage)
        }
        // Let input arrive while earlier patches are still being rendered and coalesced.
        for index in 0..<100 {
            display.insertText(index == 99 ? "Z" : "x", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(1))
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while display.readScreenText()?.hasPrefix("Z") != true && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(display.readScreenText()?.hasPrefix("Z") == true, "Burst input must reach the latest echo")
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        XCTAssertEqual(trace.filter { $0["text_input"] as? Bool == true }.count, count + 100, "Every text commit must reach Herdr during rendering")
        XCTAssertTrue(logs.clears.isEmpty, "Content-only updates cleared Ghostty: \(logs.clears.prefix(3))")
        if let sibling {
            XCTAssertTrue(sibling.window === window)
            XCTAssertEqual(sibling.readScreenText(), siblingText, "Unchanged pane must retain its displayed content")
        }
        XCTAssertNil(workspace.herdrLastError)
    }

    private final class RenderOutputLog: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        func append(_ message: String) {
            if message.contains("terminal <- host"), message.contains("[2J") {
                lock.withLock { messages.append(message) }
            }
        }
        var clears: [String] { lock.withLock { messages } }
    }

    func testRapidNativeTabSwitchesWhileEndpointIsPendingRemainResponsive() async throws {
        let (process, endpoint, path) = try await fixture("window-tabs-slow")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let first = try XCTUnwrap(workspace.debugSelectedTabID)
        let second = try XCTUnwrap(workspace.debugTabIDs.first { $0 != first })
        for index in 0..<60 {
            workspace.debugSelectTab(withID: index % 2 == 0 ? second : first)
            try await Task.sleep(for: .milliseconds(2))
            XCTAssertTrue((workspace.view as? WorkspaceRootView)?.toolbarView.workspaceSwitcher.isEnabled == true,
                          "Tab navigation must not dim the workspace picker")
        }
        workspace.debugSelectTab(withID: second)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if workspace.debugSelectedTabID == second, !workspace.debugHerdrOperationPending,
               workspace.debugFocusedHerdrPane?.canAcceptInput == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(workspace.debugSelectedTabID, second, workspace.herdrLastError ?? "no error")
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true)
        XCTAssertFalse(workspace.debugHerdrOperationPending)
        let report = await workspace.collectHerdrDiagnostics()
        XCTAssertTrue(report.clientShell?.presentationReady == true)
        XCTAssertTrue(process.isRunning)
    }

    func testFloatingSizeSurvivesWorkspaceRoundtripAfterTransferEnds() async throws {
        let (process, endpoint, path) = try await fixture("window-tabs")
        defer { cleanup(process, path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        let local = workspace.debugSelectedWorkspace
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let selected = workspace.debugSelectedWorkspace
        workspace.debugToggleFloatingPane(animated: false)
        workspace.debugPerformCommand(withID: "pane.resize.left")
        let size = try XCTUnwrap(workspace.debugActiveFloatingPaneState?.size)
        // The fixture rejects the transfer, exercising the same record cleanup as a completed return.
        await workspace.waitForHerdrFloatingTransitionForTesting()
        XCTAssertNil(workspace.debugActiveFloatingPaneState)
        let saved = workspace.savedWorkspace()
        try saved.validate()
        let decoded = try JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, saved)
        XCTAssertEqual(saved.herdrFloatingPanes?.first?.size, size)
        XCTAssertNil(saved.herdrFloatingPanes?.first?.placeholder)
        XCTAssertNil(saved.herdrFloatingPanes?.first?.floating)
        try workspace.restoreWorkspace(decoded)
        try await workspace.enterHerdrWorkspace("w5")
        workspace.selectWorkspace(local)
        workspace.selectWorkspace(selected); await workspace.waitForWorkspaceSelection()
        workspace.debugToggleFloatingPane(animated: false)
        XCTAssertEqual(workspace.debugActiveFloatingPaneState?.size, size)
        let frame = try XCTUnwrap(workspace.debugFloatingPaneFrame)
        XCTAssertEqual(frame.width, size.width, accuracy: 0.0001)
        XCTAssertEqual(frame.height, size.height, accuracy: 0.0001)
        await workspace.waitForHerdrFloatingTransitionForTesting()
    }

    func testRejectedFloatingTransferPreservesOriginalPane() async throws {
        let (process, endpoint, path) = try await fixture("window-tabs")
        defer { cleanup(process, path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let pane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        let tabs = workspace.debugTabIDs
        workspace.debugToggleFloatingPane(animated: false)
        XCTAssertEqual(workspace.debugActiveFloatingPaneState?.paneID, pane.id)
        for _ in 0..<10 {
            workspace.debugToggleFloatingPane(animated: false)
            workspace.toggleFloatingPane(nil)
            XCTAssertEqual(workspace.debugActiveFloatingPaneState?.paneID, pane.id,
                           "An unfinished native transfer owns the floating preview")
        }
        await workspace.waitForHerdrFloatingTransitionForTesting()
        XCTAssertNil(workspace.debugActiveFloatingPaneState)
        XCTAssertEqual(workspace.debugTabIDs, tabs)
        XCTAssertTrue(workspace.debugFocusedHerdrPane === pane)
        XCTAssertTrue(pane.canAcceptInput)
        XCTAssertNotNil(workspace.herdrLastError)
        XCTAssertTrue(process.isRunning)
    }

    func testWindowClientShellRendersAndPersistsWithoutAnAPIRuntimeID() async throws {
        let (process, endpoint, path) = try await fixture("window-no-runtime")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let pane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        XCTAssertNil(pane.herdrBinding?.terminalID)
        XCTAssertNil(pane.herdrQueryBinding)
        XCTAssertTrue(pane.isLive)
        XCTAssertTrue(pane.canAcceptInput)
        let saved = workspace.savedWorkspace()
        try saved.validate()
        XCTAssertEqual(try JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(saved)), saved)
        do {
            _ = try await workspace.handleCLIRequestAsync(.init(command: "read", paneID: pane.id))
            XCTFail("History must not use a fabricated runtime identity")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("runtime identity"))
        }
        XCTAssertTrue(pane.canAcceptInput, "Unavailable history must not close ClientShell input")
        XCTAssertTrue(pane.sendClientShellInput([.text("public identity input")]))
        let tabID = try XCTUnwrap(workspace.debugSelectedTabID)
        workspace.debugSetSelectedTabTitle("endpoint label")
        for _ in 0..<200 {
            if workspace.debugDisplayTitle(forTabID: tabID) == "endpoint label",
               !workspace.debugHerdrOperationPending, pane.canAcceptInput { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(workspace.debugDisplayTitle(forTabID: tabID), "endpoint label")
        XCTAssertNil(workspace.savedWorkspace().tabs.first { $0.id == tabID }?.customTitle,
            "An endpoint rename must not install a local title override that hides later backend labels")
        workspace.selectLocalWorkspace()
        XCTAssertTrue(process.isRunning)
    }

    func testClientShellNativeCLIReadsBackendHistoryAndProcesses() async throws {
        let (process, endpoint, path) = try await fixture("window")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let pane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        let read = try await workspace.handleCLIRequestAsync(.init(command: "read", paneID: pane.id, startLine: 2, endLine: 2))
        XCTAssertEqual(read.text, "中文🙂")
        XCTAssertEqual(read.textSource, "herdr_recent_1000")
        XCTAssertEqual(read.backendRevision, 42)
        XCTAssertEqual(read.historyTruncated, true)
        let search = try await workspace.handleCLIRequestAsync(.init(command: "search", paneID: pane.id, query: "last", ignoreCase: true))
        XCTAssertEqual(search.matches?.map(\.line), [3])
        let listed = try await workspace.handleCLIRequestAsync(.init(command: "list"))
        let info = try XCTUnwrap(listed.tabs?.flatMap(\.panes).first { $0.id == pane.id })
        XCTAssertEqual(info.backend, "herdr")
        XCTAssertEqual(info.foregroundProcessGroupID, 12345)
        XCTAssertEqual(info.processes.map(\.pid), [12346])
        XCTAssertTrue(pane.canAcceptInput)
    }

    func testLegacyWholeWindowsRestoreOnlyThroughClientShellAndKeepLocalPanes() async throws {
        let (process, endpoint, path) = try await fixture("window")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        let parked = workspace.debugTabIDs
        try await workspace.enterHerdrWorkspace("w5")
        workspace.debugPerformCommand(withID: "pane.notes.new")
        let saved = workspace.savedWorkspace()
        let notes = saved.tabs.flatMap(\.panes).filter { $0.kind == .notes }.map(\.id)
        XCTAssertEqual(notes.count, 1)
        for version in [1, 2, 3] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
            func legacyBindings(_ value: Any) -> Any {
                if var object = value as? [String: Any] {
                    for (key, child) in object { object[key] = legacyBindings(child) }
                    if object["paneID"] != nil, object["endpoint"] != nil { object["terminalID"] = "fixture-runtime" }
                    return object
                }
                if let array = value as? [Any] { return array.map(legacyBindings) }
                return value
            }
            json = try XCTUnwrap(legacyBindings(json) as? [String: Any])
            json["version"] = version
            for key in ["workspaces", "selectedWorkspace", "localWorkspaceID", "localWorkspaceName", "otherLocalWorkspaces"] { json.removeValue(forKey: key) }
            json["herdrWindowMode"] = "observe"
            if version < 3 { json.removeValue(forKey: "herdrWindowTransport") }
            else { json["herdrWindowTransport"] = "direct" }
            let legacy = try JSONDecoder().decode(SavedWorkspace.self, from: JSONSerialization.data(withJSONObject: json))
            try workspace.restoreWorkspace(legacy)
            XCTAssertNil(workspace.debugFocusedHerdrPane)
            XCTAssertEqual(workspace.debugTabIDs, parked)
            XCTAssertEqual((workspace.view as? WorkspaceRootView)?.toolbarView.workspaceSwitcher.titleOfSelectedItem, "Default")
            XCTAssertEqual(workspace.savedWorkspace().herdrAuxiliaryTabs?.flatMap(\.panes).filter { $0.kind == .notes }.map(\.id), notes)
            try workspace.savedWorkspace().validate()
            try await workspace.enterHerdrWorkspace("w5")
            XCTAssertNil(workspace.herdrLastError)
            XCTAssertEqual(workspace.savedWorkspace().herdrWindowTransport, .clientShell)
            XCTAssertEqual(workspace.savedWorkspace().herdrWindowMode, .control)
            XCTAssertEqual(workspace.savedWorkspace().tabs.flatMap(\.panes).filter { $0.kind == .notes }.map(\.id), notes)
            let report = await workspace.collectHerdrDiagnostics()
            XCTAssertTrue(report.clientShell?.presentationReady == true)
            XCTAssertEqual(report.clientShell?.assetCount, 1)
            XCTAssertTrue(report.panes.allSatisfy { $0.transport == .clientShell })
        }
        workspace.selectLocalWorkspace()
        XCTAssertTrue(Set(parked).isSubset(of: Set(workspace.debugTabIDs)))
        XCTAssertTrue(process.isRunning)
    }

    func testSecondInstanceDoesNotActivateSavedClientShellWindow() async throws {
        let (process, endpoint, path) = try await fixture("window")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let saved = workspace.savedWorkspace()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-single-transport-\(UUID())")
        let url = directory.appendingPathComponent("workspace.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try WorkspaceStore(url: url); try await owner.save(saved)
        let before = try Data(contentsOf: url)
        let second = WorkspaceViewController()
        await second.prepareWorkspacePersistence(url: url)
        second.debugLoadForTesting()
        second.herdrErrorHandler = { _ in }
        defer { second.releaseHerdrConnections() }
        XCTAssertNil(second.debugFocusedHerdrPane)
        XCTAssertEqual((second.view as? WorkspaceRootView)?.toolbarView.workspaceSwitcher.titleOfSelectedItem, "Default")
        XCTAssertNil(second.herdrLastError)
        do {
            try second.configureHerdrWorkspace(endpoint)
            try await second.enterHerdrWorkspace("w5")
            XCTFail("A second instance must not activate ClientShell")
        } catch { XCTAssertTrue(error.localizedDescription.contains("owns workspace saving")) }
        let report = await second.collectHerdrDiagnostics()
        XCTAssertNil(report.clientShell)
        try await second.flushWorkspaceState()
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(owner.canWrite)
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true)
    }

    func testLeaveConvertsParkedLegacyTerminalToLocalAndPreservesNotes() async throws {
        let (process, endpoint, path) = try await fixture("window")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        var document = workspace.savedWorkspace()
        let oldPane = try XCTUnwrap(document.tabs.first?.panes.first)
        let metadata = try await HerdrWorkspaceClient(endpoint: endpoint).snapshot()
        let binding = try HerdrPaneBinding(endpoint: endpoint, pane: XCTUnwrap(metadata.panes.first))
        document.tabs[0].panes[0] = .init(id: oldPane.id, kind: .persistentTerminal,
            name: "Legacy", title: "Legacy", cwd: "/tmp", binding: binding)
        try workspace.restoreWorkspace(document)
        XCTAssertEqual(workspace.debugRestoredPlaceholderCount, 1)
        workspace.debugPerformCommand(withID: "pane.notes.new")
        let notes = workspace.savedWorkspace().tabs.flatMap(\.panes).filter { $0.kind == .notes }.map(\.id)
        let layout = workspace.debugLayoutNode
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        workspace.selectLocalWorkspace()
        let saved = workspace.savedWorkspace()
        XCTAssertEqual(workspace.debugRestoredPlaceholderCount, 0)
        XCTAssertEqual(saved.tabs.flatMap(\.panes).filter { $0.kind == .notes }.map(\.id), notes)
        XCTAssertEqual(workspace.debugLayoutNode, layout)
        let local = try XCTUnwrap(saved.tabs.flatMap(\.panes).first { $0.id == oldPane.id })
        XCTAssertEqual(local.kind, .localTerminal)
        XCTAssertEqual(local.name, "Legacy")
        XCTAssertNil(local.binding)
        XCTAssertNil(saved.herdrWindowBinding)
        XCTAssertTrue(process.isRunning)
    }

    func testWindowClientShellRendersAndLeaveKeepsExternalServiceAlive() async throws {
        let (process, endpoint, path) = try await fixture("window")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController()
        workspace.debugLoadForTesting()
        let paneMenu = NSMenu(title: "Pane")
        paneMenu.delegate = workspace
        let reconnectItem = paneMenu.addItem(withTitle: KeybindingAction.reconnectPersistentTerminal.title,
            action: #selector(WorkspaceViewController.reconnectPersistentTerminal(_:)), keyEquivalent: "")
        paneMenu.delegate?.menuNeedsUpdate?(paneMenu)
        XCTAssertTrue(reconnectItem.isHidden)
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let locals = workspace.debugTabIDs
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.delegate = workspace; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        paneMenu.delegate?.menuNeedsUpdate?(paneMenu)
        XCTAssertTrue(reconnectItem.isHidden, "Connected windows do not need a reconnect menu item")
        let pane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        XCTAssertEqual(pane.herdrTransport, .clientShell)
        XCTAssertTrue(pane.canAcceptInput)
        func terminal(in view: NSView) -> TerminalView? {
            if let value = view as? TerminalView { return value }
            return view.subviews.lazy.compactMap { terminal(in: $0) }.first
        }
        let display = try XCTUnwrap(terminal(in: pane.hostView))
        XCTAssertTrue(display.readScreenText()?.contains("ClientShell native image") == true)
        XCTAssertNil(pane.clientShellDisplayError)
        XCTAssertEqual((workspace.view as? WorkspaceRootView)?.toolbarView.workspaceSwitcher.titleOfSelectedItem, "repo")
        let diagnostics = await workspace.collectHerdrDiagnostics()
        let shell = try XCTUnwrap(diagnostics.clientShell)
        XCTAssertEqual(diagnostics.windowTransport, .clientShell)
        XCTAssertEqual(diagnostics.panes.first?.transport, .clientShell)
        XCTAssertEqual(shell.generation, 1)
        XCTAssertTrue(shell.presentationReady)
        XCTAssertEqual(shell.requestedColumns, shell.actualColumns)
        XCTAssertEqual(shell.requestedRows, shell.actualRows)
        XCTAssertEqual(shell.assetCount, 1)
        XCTAssertGreaterThan(shell.requestToResponse.sampleCount, 0)
        XCTAssertGreaterThan(shell.sceneOfferToHostCommit.sampleCount, 0)
        XCTAssertGreaterThan(try XCTUnwrap(shell.queues?.peakReadPayloadBytes), 0)
        XCTAssertGreaterThan(try XCTUnwrap(shell.queues?.peakDecodedBytes), 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(shell.queues?.peakDecodedBytes), HerdrClientShellTransport.decodedQueueBudget)
        let diagnosticJSON = try diagnostics.json()
        XCTAssertFalse(diagnosticJSON.contains("ClientShell native image"))
        XCTAssertFalse(diagnosticJSON.contains("fixture-runtime-cwd"))
        let saved = workspace.savedWorkspace()
        try saved.validate()
        XCTAssertEqual(saved.version, SavedWorkspace.currentVersion)
        XCTAssertEqual(saved.herdrWindowTransport, .clientShell)
        let restored = try JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored, saved)
        XCTAssertEqual(restored.restoredHerdrWindowTransport, .clientShell)
        var invalid = restored
        invalid.version = 2
        XCTAssertThrowsError(try invalid.validate(), "Older formats cannot silently select ClientShell")
        let controller = display.controller
        display.controller = nil
        XCTAssertFalse(pane.canAcceptInput, "A torn-down display must invalidate the previous presentation")
        display.controller = controller
        XCTAssertFalse(pane.canAcceptInput, "Reattachment must await repaint, even when Herdr sends no new frame")
        for _ in 0..<200 {
            if pane.canAcceptInput, display.readScreenText()?.contains("ClientShell native image") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(pane.canAcceptInput)
        XCTAssertTrue(display.readScreenText()?.contains("ClientShell native image") == true)
        XCTAssertNil(pane.clientShellDisplayError)
        let initialColumns = try XCTUnwrap(display.scrollModeGrid?.columns)
        window.setContentSize(NSSize(width: 1100, height: 650))
        workspace.view.layoutSubtreeIfNeeded()
        workspace.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        for _ in 0..<200 {
            if pane.canAcceptInput, let columns = display.scrollModeGrid?.columns, columns > initialColumns { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(try XCTUnwrap(display.scrollModeGrid?.columns), initialColumns)
        XCTAssertTrue(pane.canAcceptInput)
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        XCTAssertEqual(trace.filter { $0["resize"] != nil }.count, 2, "Window resize sends one tab-level size, not per-pane PTY sizes")
        workspace.disconnectPersistentTerminal(nil)
        paneMenu.delegate?.menuNeedsUpdate?(paneMenu)
        XCTAssertFalse(reconnectItem.isHidden, "Disconnected windows must expose reconnect")
        XCTAssertEqual(pane.herdrState, .disconnected)
        XCTAssertFalse(pane.canAcceptInput)
        XCTAssertTrue(workspace.validateMenuItem(NSMenuItem(title: "Reconnect", action: #selector(WorkspaceViewController.reconnectPersistentTerminal(_:)), keyEquivalent: "")),
                      "A disconnected ClientShell must remain reconnectable without presentation readiness")
        XCTAssertTrue(process.isRunning, "Disconnect must leave the separately running service alive")
        let identity = pane.herdrBinding?.serviceIdentity
        workspace.reconnectPersistentTerminal(nil)
        for _ in 0..<600 {
            if !workspace.debugHerdrOperationPending, pane.canAcceptInput { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(workspace.debugHerdrOperationPending)
        XCTAssertTrue(pane.canAcceptInput)
        XCTAssertEqual(workspace.debugFocusedHerdrPane?.id, pane.id, "Same-runtime reconnection retains the native controller")
        paneMenu.delegate?.menuNeedsUpdate?(paneMenu)
        XCTAssertTrue(reconnectItem.isHidden, "Successful reconnect hides the menu item again")
        XCTAssertEqual(pane.herdrBinding?.serviceIdentity, identity)
        XCTAssertTrue(display.readScreenText()?.contains("ClientShell native image") == true)
        XCTAssertNil(pane.clientShellDisplayError)
        let reconnected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        XCTAssertEqual(reconnected.compactMap { $0["connection"] as? Int }, [1, 2])
        XCTAssertEqual(reconnected.filter { $0["method"] as? String == "client_shell.surface.set" }.count, 2)
        XCTAssertTrue(process.isRunning)
        workspace.takeOverPersistentTerminal(nil)
        for _ in 0..<600 {
            if !workspace.debugHerdrOperationPending, pane.canAcceptInput { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(workspace.debugHerdrOperationPending)
        XCTAssertTrue(pane.canAcceptInput)
        XCTAssertEqual(workspace.savedWorkspace().herdrWindowMode, .control)
        XCTAssertEqual(workspace.savedWorkspace().herdrWindowTransport, .clientShell)
        let controlled = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        XCTAssertEqual(controlled.compactMap { $0["connection"] as? Int }, [1, 2, 3])
        XCTAssertTrue(controlled.contains { $0["method"] as? String == "pane.focus" }, "Control must claim geometry through the endpoint rather than a per-pane direct takeover")
        workspace.selectLocalWorkspace()
        XCTAssertEqual(workspace.debugTabIDs, locals)
        XCTAssertTrue(process.isRunning)
        let result = try await HerdrWorkspaceClient(endpoint: endpoint).request("ping")
        XCTAssertEqual(result.type, "pong", "Leave detaches the client, not the separately running service")
    }

    func testBorderedWindowFillsNativePaneAfterInitialSceneAndResize() async throws {
        let (process, endpoint, path) = try await fixture("window-borders")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let pane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        for size in [NSSize(width: 1000, height: 650), NSSize(width: 1100, height: 750)] {
            window.setContentSize(size)
            workspace.view.layoutSubtreeIfNeeded()
            workspace.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
            for _ in 0..<200 {
                let diagnostics = await workspace.collectHerdrDiagnostics()
                if diagnostics.clientShell?.presentationReady == true, pane.canAcceptInput { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let grid = try XCTUnwrap(pane.clientShellGridMetrics)
            let cellHeight = CGFloat(grid.cellHeightPixels) / pane.clientShellBackingScale.height
            let expectedRows = floor((pane.hostView.bounds.height - TerminalSettings.padding * 2) / cellHeight)
            XCTAssertEqual(CGFloat(grid.rows), expectedRows, "Hidden backend borders must not leave whole rows unused")
            XCTAssertTrue(pane.canAcceptInput, workspace.herdrLastError ?? "")
        }
    }

    func testLocalDividerResizeUpdatesClientShellViewportWithoutWindowResize() async throws {
        let (process, endpoint, path) = try await fixture("window")
        defer { cleanup(process, path); try? FileManager.default.removeItem(atPath: path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let pane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        let initialDiagnostics = await workspace.collectHerdrDiagnostics()
        let initial = try XCTUnwrap(initialDiagnostics.clientShell)
        workspace.newBrowserPane(nil)
        var before = initial
        for _ in 0..<200 {
            let diagnostics = await workspace.collectHerdrDiagnostics()
            before = try XCTUnwrap(diagnostics.clientShell)
            if before.requestedColumns < initial.requestedColumns, before.presentationReady,
               pane.clientShellGridMetrics?.columns == before.actualColumns { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertLessThan(before.requestedColumns, initial.requestedColumns)
        let windowSize = window.frame.size
        workspace.debugUpdateSplitFractions(at: [], to: [0.5, 0.5])
        workspace.view.layoutSubtreeIfNeeded()
        var after = before
        for _ in 0..<200 {
            let diagnostics = await workspace.collectHerdrDiagnostics()
            after = try XCTUnwrap(diagnostics.clientShell)
            if after.requestedColumns < before.requestedColumns, after.presentationReady,
               pane.clientShellGridMetrics?.columns == after.actualColumns { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(window.frame.size, windowSize)
        XCTAssertLessThan(after.requestedColumns, before.requestedColumns)
        XCTAssertEqual(after.requestedColumns, after.actualColumns)
        XCTAssertTrue(after.presentationReady, workspace.herdrLastError ?? "Presentation did not recover")
        XCTAssertTrue(pane.canAcceptInput)
        XCTAssertEqual(pane.clientShellGridMetrics?.columns, after.actualColumns)
    }

    func testWorkspaceMutationsUseEndpointAndNeverFallbackAfterDisconnect() async throws {
        let (process, endpoint, path) = try await fixture("normal")
        defer { cleanup(process, path) }
        let session = autoPresentedSession(endpoint)
        defer { session.disconnect() }
        let ready = expectation(description: "endpoint ready")
        session.onState = { if $0 == .interactive { ready.fulfill() } }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: false)
        await fulfillment(of: [ready], timeout: 5)
        session.onState = nil
        let client = HerdrWorkspaceClient(endpoint: endpoint)
        try client.routeCommands(to: session)
        try client.routeCommands(to: session)
        XCTAssertThrowsError(try client.routeCommands(to: HerdrClientShellSession(endpoint: endpoint)),
                             "A pending caller must not be redirected to a replacement session")
        let result = try await client.request("pane.rename", params: .init(pane_id: "w5:pA", label: "fixture"))
        XCTAssertEqual(result.type, "ok")
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        XCTAssertTrue(trace.contains(where: { $0["method"] as? String == "pane.rename" }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.socketPath), "Mutation must not require or contact the global API socket")
        session.disconnect()
        do { _ = try await client.request("pane.rename", params: .init(pane_id: "w5:pA", label: "late")); XCTFail("Disconnected commands cannot use global API") }
        catch { XCTAssertTrue(error.localizedDescription.contains("another transport")) }
    }

    func testDisplayInvalidationRequiresNewHostAcknowledgementWithoutLosingScene() async throws {
        let (process, endpoint, path) = try await fixture("normal")
        defer { cleanup(process, path) }
        let session = autoPresentedSession(endpoint)
        defer { session.disconnect() }
        let ready = expectation(description: "initial display ready")
        session.onState = { if $0 == .interactive { ready.fulfill() } }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: false)
        await fulfillment(of: [ready], timeout: 5)
        session.onState = nil; session.onProjection = nil
        let frame = try XCTUnwrap(session.projection.coherentSurface)
        let assets = session.projection.assets
        try session.invalidatePresentation()
        XCTAssertFalse(session.isPresentationReady)
        XCTAssertEqual(session.state, .connecting)
        XCTAssertFalse(session.input(target: "w5:pA", events: [.text("not repainted")]))
        XCTAssertEqual(session.projection.coherentSurface?.surface_revision, frame.surface_revision)
        XCTAssertEqual(session.projection.assets, assets, "Repaint must reuse CPU pixels even if the server sends no new assets")
        XCTAssertTrue(session.acknowledgePresentation(frame))
        XCTAssertTrue(session.isPresentationReady)
        try session.resize(.init(cols: 3, rows: 1), cellWidth: 8, cellHeight: 16)
        XCTAssertFalse(session.isPresentationReady, "An old ACK cannot authorize commands at a new requested geometry")
        XCTAssertEqual(session.state, .connecting)
    }

    func testContentRefreshAllowsInputButPreservesAcceptedReleases() async throws {
        let (process, endpoint, path) = try await fixture("presentation")
        defer { cleanup(process, path) }
        let session = HerdrClientShellSession(endpoint: endpoint)
        defer { session.disconnect() }
        let initial = expectation(description: "initial offered"), updated = expectation(description: "updated offered")
        var first: HerdrShellSurface?, second: HerdrShellSurface?
        session.onProjection = { _, frame, _ in
            if first == nil { first = frame; initial.fulfill() }
            else if second == nil { second = frame; updated.fulfill() }
        }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: false)
        await fulfillment(of: [initial], timeout: 5)
        XCTAssertFalse(session.isPresentationReady)
        XCTAssertFalse(session.input(target: "w5:pA", events: [.text("not presented")]))
        XCTAssertTrue(session.acknowledgePresentation(try XCTUnwrap(first)))
        XCTAssertTrue(session.isPresentationReady)
        let down = HerdrShellInput.key(.init(code: 1, tracksRelease: true, physicalKeyID: 36))
        XCTAssertTrue(session.input(target: "w5:pA", events: [down]))
        await fulfillment(of: [updated], timeout: 5)
        XCTAssertEqual(session.state, .interactive, "Content refresh does not clear native pressed-key state")
        XCTAssertFalse(session.isPresentationReady)
        XCTAssertTrue(session.isInputReady)
        XCTAssertTrue(session.input(target: "w5:pA", events: [.text("pending content")]))
        let up = HerdrShellInput.key(.init(code: 1, kind: 2, tracksRelease: true, physicalKeyID: 36))
        XCTAssertTrue(session.input(target: "w5:pA", events: [up]))
        XCTAssertFalse(session.input(target: "w5:pA", events: [up]), "Only a previously accepted press may release during pending presentation")
        XCTAssertFalse(session.acknowledgePresentation(try XCTUnwrap(first)), "Late host acknowledgements cannot open a newer picture")
        XCTAssertTrue(session.acknowledgePresentation(try XCTUnwrap(second)))
        XCTAssertTrue(session.input(target: "w5:pA", events: [.text("presented")]))
    }

    func testNativePaneRendersFromWindowSessionWithoutStartingDirectBridge() async throws {
        let (process, endpoint, path) = try await fixture("normal")
        defer { cleanup(process, path) }
        let session = HerdrClientShellSession(endpoint: endpoint)
        defer { session.disconnect() }
        let ready = expectation(description: "window session ready")
        var seen = false
        session.onProjection = { _, _, _ in if !seen { seen = true; ready.fulfill() } }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: false)
        await fulfillment(of: [ready], timeout: 5)
        let metadata = HerdrSnapshot.Pane(pane_id: "w5:pA", terminal_id: "fixture-runtime",
            workspace_id: "w5", tab_id: "w5:t4", serviceIdentity: session.serviceIdentity)
        let binding = try HerdrPaneBinding(endpoint: endpoint, pane: metadata)
        let pane = TerminalPaneController(herdr: binding)
        pane.startIfNeeded()
        XCTAssertEqual(pane.herdrState, .disconnected, "Pane must not launch its own direct process")
        XCTAssertFalse(pane.canAcceptInput)
        XCTAssertThrowsError(try pane.bindClientShell(session, bootID: "stale"))
        try pane.bindClientShell(session, bootID: "boot")
        XCTAssertFalse(pane.canAcceptInput, "Native presentation has not been acknowledged")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = pane.hostView; window.orderBack(nil); pane.fitToSize()
        defer { window.orderOut(nil); window.contentView = nil; pane.disconnectHerdr() }
        func terminal(in view: NSView) -> TerminalView? {
            if let value = view as? TerminalView { return value }
            return view.subviews.lazy.compactMap { terminal(in: $0) }.first
        }
        let display = try XCTUnwrap(terminal(in: pane.hostView))
        let surface = try XCTUnwrap(session.projection.coherentSurface)
        try pane.bindClientShell(session, bootID: "boot")
        var prepared: HerdrShellPreparedRender?
        for _ in 0..<100 {
            prepared = try await pane.prepareClientShellRender(surface, assets: session.projection.assets)
            if prepared != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let output = try XCTUnwrap(prepared)
        XCTAssertGreaterThan(output.byteCount, 0)
        XCTAssertFalse(display.readScreenText()?.contains("界") == true, "Preparing must not write terminal output")
        var invalidAssets = session.projection.assets
        let assetKey = try XCTUnwrap(invalidAssets.keys.first)
        invalidAssets[assetKey] = Data()
        do { _ = try await pane.prepareClientShellRender(surface, assets: invalidAssets); XCTFail("Invalid asset bytes were accepted") }
        catch { }
        let repeatedOutput = try await pane.prepareClientShellRender(surface, assets: session.projection.assets)
        let repeated = try XCTUnwrap(repeatedOutput)
        XCTAssertEqual(repeated.byteCount, output.byteCount, "Discarded preparations must not advance the renderer")
        let outputSession = try XCTUnwrap(output.commit())
        await Task.detached { outputSession.waitForPendingOutput() }.value
        XCTAssertTrue(output.isCurrent())
        XCTAssertTrue(session.acknowledgePresentation(surface))
        pane.applyClientShellState(session.state)
        XCTAssertTrue(pane.canAcceptInput)
        XCTAssertEqual(display.scrollModeGrid?.columns, 2)
        XCTAssertEqual(display.scrollModeGrid?.rows, 1)
        let fixedFrame = pane.debugTerminalFrame
        window.setContentSize(NSSize(width: 900, height: 600))
        pane.hostView.layoutSubtreeIfNeeded(); pane.fitToSize()
        XCTAssertEqual(pane.debugTerminalFrame.size, fixedFrame.size)
        XCTAssertEqual(display.scrollModeGrid?.columns, 2, "Floating/zoom containers must not reflow backend content")
        XCTAssertEqual(display.scrollModeGrid?.rows, 1)
        for _ in 0..<100 where display.readScreenText()?.contains("界") != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(display.readScreenText()?.contains("界") == true)
        func mouse(_ type: NSEvent.EventType, point: NSPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: display.convert(point, to: nil),
                modifierFlags: flags, timestamp: 1, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let inside = NSPoint(x: 1, y: display.bounds.height - 1)
        let outside = NSPoint(x: -10, y: display.bounds.height + 10)
        display.mouseDown(with: try mouse(.leftMouseDown, point: inside))
        display.mouseDragged(with: try mouse(.leftMouseDragged, point: outside))
        display.mouseUp(with: try mouse(.leftMouseUp, point: outside))
        display.mouseDown(with: try mouse(.leftMouseDown, point: inside, flags: .shift))
        display.mouseUp(with: try mouse(.leftMouseUp, point: inside, flags: .shift))
        display.mouseDown(with: try mouse(.leftMouseDown, point: inside))
        try session.setFocused(false)
        try session.setFocused(true)
        display.mouseDragged(with: try mouse(.leftMouseDragged, point: outside, flags: .shift))
        display.mouseUp(with: try mouse(.leftMouseUp, point: inside, flags: .shift))
        _ = try await session.request("pane.rename", params: .init(pane_id: "w5:pA", label: "fixture"))
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        let inputs = trace.compactMap { $0["payload"] as? String }
        let expected = try [UInt32(0), 2, 1, 0, 1].map { kind in
            try HerdrShellClientMessage.input(target: "w5:pA", popup: false,
                events: [.mouse(.init(kind: kind, button: 0, column: 0, row: 0))]).encoded()
                .dropFirst(4).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(inputs, expected, "Native mouse gestures route once; Shift selection remains local")
        XCTAssertTrue(pane.submitPrompt("fixture"))
        let staleIMECommit = try XCTUnwrap(display.semanticTextCommitHandler)
        pane.showPromptEditor(relativeTo: window)
        let sheet = try XCTUnwrap(window.attachedSheet)
        func promptTextView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            for child in view.subviews {
                if let text = promptTextView(in: child) { return text }
            }
            return nil
        }
        let promptEditor = try XCTUnwrap(promptTextView(in: try XCTUnwrap(sheet.contentView)))
        promptEditor.string = "stale prompt after reconnect"
        pane.disconnectHerdr()
        try pane.bindClientShell(session, bootID: surface.boot_id)
        XCTAssertTrue(pane.canAcceptInput, "The replacement connection would otherwise accept the old prompt")
        staleIMECommit("stale IME after reconnect")
        display.semanticTextCommitHandler?("fresh IME after reconnect")
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await Task.sleep(for: .milliseconds(100))
        _ = try await session.request("pane.rename", params: .init(pane_id: "w5:pA", label: "after prompt"))
        let promptTrace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        let stalePromptPayload = try HerdrShellClientMessage.input(target: "w5:pA", popup: false,
            events: [.paste(promptEditor.string), .key(.init(code: 1))]).encoded()
            .dropFirst(4).map { String(format: "%02x", $0) }.joined()
        XCTAssertFalse(promptTrace.contains { ($0["payload"] as? String) == stalePromptPayload },
            "A sheet created before disconnect cannot send into the replacement connection")
        func textPayload(_ text: String) throws -> String {
            try HerdrShellClientMessage.input(target: "w5:pA", popup: false, events: [.text(text)]).encoded()
                .dropFirst(4).map { String(format: "%02x", $0) }.joined()
        }
        let staleIMEPayload = try textPayload("stale IME after reconnect")
        let freshIMEPayload = try textPayload("fresh IME after reconnect")
        XCTAssertFalse(promptTrace.contains { ($0["payload"] as? String) == staleIMEPayload })
        XCTAssertTrue(promptTrace.contains { ($0["payload"] as? String) == freshIMEPayload },
            "Rebinding installs a current handler while saved callbacks remain invalid")
        let preparedStale = try await pane.prepareClientShellRender(surface, assets: session.projection.assets)
        let staleOutput = try XCTUnwrap(preparedStale)
        pane.disconnectHerdr()
        XCTAssertFalse(staleOutput.isCurrent())
        XCTAssertNil(staleOutput.commit(), "A prepared output cannot revive a disconnected surface")
        XCTAssertFalse(pane.canAcceptInput)
        XCTAssertEqual(session.state, .interactive, "Closing a pane display does not detach the window endpoint")
        do { _ = try await pane.prepareClientShellRender(surface, assets: session.projection.assets); XCTFail("Disconnected target was prepared") }
        catch { }
    }

    func testSamePaneCandidatePreservesOldNativeDisplayAndStableIdentityUntilPromotion() async throws {
        let (process, endpoint, path) = try await fixture("normal")
        defer { cleanup(process, path) }
        let session = HerdrClientShellSession(endpoint: endpoint)
        defer { session.disconnect() }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: false)
        for _ in 0..<200 where session.projection.coherentSurface == nil { try await Task.sleep(for: .milliseconds(10)) }
        let frame = try XCTUnwrap(session.projection.coherentSurface)
        let binding = try HerdrPaneBinding(endpoint: endpoint, pane: .init(pane_id: "w5:pA",
            terminal_id: nil, workspace_id: "w5", tab_id: "w5:t4", serviceIdentity: session.serviceIdentity))
        let pane = TerminalPaneController(herdr: binding)
        let id = pane.id, oldHost = pane.hostView
        let root = WorkspaceRootView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        let window = NSWindow(contentRect: root.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = root; root.installRenderedContentView(oldHost); window.orderBack(nil)
        defer { pane.disconnectHerdr(); window.orderOut(nil); window.contentView = nil }
        try pane.bindClientShell(session, bootID: "boot")
        func prepare() async throws -> HerdrShellPreparedRender {
            for _ in 0..<100 {
                if let output = try await pane.prepareClientShellRender(frame, assets: session.projection.assets) { return output }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CLIError("Native test display did not attach")
        }
        let initial = try await prepare()
        let initialMemory = try XCTUnwrap(initial.commit())
        await Task.detached { initialMemory.waitForPendingOutput() }.value
        XCTAssertTrue(session.acknowledgePresentation(frame))
        pane.applyClientShellState(session.state)
        let abandoned = pane.stageClientShellDisplay()
        root.stageContentView(abandoned)
        let discarded = try await prepare()
        let rejectedMemory = try XCTUnwrap(discarded.commit())
        rejectedMemory.receive("\u{1b}_Ga=t,f=32,s=2,v=2,i=1,q=0;AAAA\u{1b}\\")
        await Task.detached { rejectedMemory.waitForPendingOutput() }.value
        for _ in 0..<100 where discarded.isCurrent() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(discarded.isCurrent(), "A Ghostty image rejection must invalidate the candidate frame")
        do { _ = try await prepare(); XCTFail("A rejected candidate image must be reported") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Ghostty image")) }
        root.cancelStagedContentView(abandoned); pane.cancelClientShellDisplay()
        XCTAssertFalse(discarded.isCurrent()); XCTAssertNil(discarded.commit())
        XCTAssertTrue(pane.hostView === oldHost)
        XCTAssertNotNil(initialMemory.readViewportText())
        let candidate = pane.stageClientShellDisplay()
        root.stageContentView(candidate)
        let replacement = try await prepare()
        let replacementMemory = try XCTUnwrap(replacement.commit())
        await Task.detached { replacementMemory.waitForPendingOutput() }.value
        XCTAssertTrue(pane.hostView === oldHost)
        XCTAssertNotNil(initialMemory.readViewportText(), "Preparing the new C surface must retain the old surface")
        pane.promoteClientShellDisplay()
        XCTAssertTrue(root.commitStagedContentView(candidate))
        XCTAssertEqual(pane.id, id)
        XCTAssertTrue(pane.hostView === candidate)
        XCTAssertNil(initialMemory.readViewportText())
        XCTAssertNotNil(replacementMemory.readViewportText())
        XCTAssertTrue(replacement.isCurrent(), "Promotion cannot invalidate its own prepared frame")
        XCTAssertTrue(session.acknowledgePresentation(frame))
        pane.applyClientShellState(session.state)
        XCTAssertTrue(pane.canAcceptInput)
        XCTAssertTrue(pane.sendClientShellInput([.text("promoted native display")]))
    }

    private func autoPresentedSession(_ endpoint: HerdrEndpoint) -> HerdrClientShellSession {
        let session = HerdrClientShellSession(endpoint: endpoint)
        session.onProjection = { [weak session] _, frame, _ in _ = session?.acknowledgePresentation(frame) }
        return session
    }

    func testHerdrPaneLabelsSynchronizeNameBadgesAndRevealOnCommandHold() async throws {
        let (process, endpoint, path) = try await fixture("window")
        defer { cleanup(process, path) }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.herdrErrorHandler = { _ in }
        try workspace.configureHerdrWorkspace(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        try await workspace.enterHerdrWorkspace("w5")
        let pane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        let badge = try XCTUnwrap(workspace.debugPaneNameBadge(for: pane.id))
        XCTAssertEqual(pane.name, "shell", "Endpoint labels must populate the name used by Command overlays")
        XCTAssertEqual(badge.name, "shell")
        XCTAssertTrue(badge.isHidden)
        let initialItem = try XCTUnwrap(CommandPaletteFilter.results(workspace.paletteNavigationItems, query: "shell", kind: .pane).first)
        XCTAssertEqual(initialItem.title, "shell")
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
        workspace.handlePaneNameEvent(down)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(badge.isHidden, "Holding Command must reveal a named Herdr pane")
        workspace.debugSetFocusedPaneName("Backend name")
        for _ in 0..<300 where pane.lastKnownTitle != "Backend name" || workspace.debugHerdrOperationPending {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(pane.lastKnownTitle, "Backend name", "Renaming must reach the backend and return through metadata")
        XCTAssertEqual(pane.name, "Backend name"); XCTAssertEqual(badge.name, "Backend name")
        let renamedItem = try XCTUnwrap(CommandPaletteFilter.results(workspace.paletteNavigationItems, query: "Backend name", kind: .pane).first)
        XCTAssertEqual(renamedItem.title, "Backend name")
        XCTAssertEqual(renamedItem.id, initialItem.id, "A rename must update the existing search target")
        XCTAssertNotEqual(renamedItem.paletteSnapshot, initialItem.paletteSnapshot, "The open palette must detect renamed data")
        let up = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
        workspace.handlePaneNameEvent(up)
        workspace.handlePaneNameEvent(down)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(badge.isHidden)
        workspace.debugSetFocusedPaneName("")
        for _ in 0..<300 where pane.lastKnownTitle == "Backend name" || workspace.debugHerdrOperationPending {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(pane.name); XCTAssertNil(badge.name); XCTAssertTrue(badge.isHidden)
        XCTAssertFalse(workspace.paletteNavigationItems.contains { $0.id == initialItem.id && $0.title == "Backend name" })
        XCTAssertTrue(CommandPaletteFilter.results(workspace.paletteNavigationItems, query: "Backend name", kind: .pane).isEmpty)
        XCTAssertTrue(process.isRunning)
    }

    func testAgentNavigationFromDefaultUsesGlobalCatalogAndPreservesLocalTabs() async throws {
        let (process, endpoint, path) = try await fixture("window-tabs-palette")
        defer { cleanup(process, path); AgentSessionStore.shared.reset() }
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        var errors: [String] = []
        workspace.herdrErrorHandler = { errors.append($0) }
        try workspace.configureHerdrWorkspace(endpoint)
        let locals = workspace.debugTabIDs
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil }
        workspace.startHerdrAgentMonitoring(endpoint)
        for _ in 0..<300 where !AgentSessionStore.shared.snapshots.contains(where: { $0.binding.workspaceID == "w6" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let agent = try XCTUnwrap(AgentSessionStore.shared.snapshots.first { $0.binding.workspaceID == "w6" })
        XCTAssertEqual(agent.agent.rawValue, "opencode")
        XCTAssertNil(workspace.debugFocusedHerdrPane)
        XCTAssertEqual(workspace.debugTabIDs, locals)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".trace"), "Global discovery must not activate a surface")
        let agentItem = try XCTUnwrap(CommandPaletteFilter.results(workspace.paletteNavigationItems, query: "opencode", kind: .agent).first)
        XCTAssertEqual(agentItem.title, agent.agent.displayName)
        XCTAssertTrue(agentItem.subtitle?.contains(agent.paneTitle) == true)
        XCTAssertTrue(agentItem.subtitle?.contains(agent.statusText) == true)
        agentItem.perform()
        await workspace.waitForPaletteNavigationForTesting()
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
        XCTAssertEqual(workspace.debugFocusedHerdrPane?.herdrBinding?.paneID, "w6:pC")
        workspace.selectLocalWorkspace()
        XCTAssertEqual(workspace.debugTabIDs, locals)
        XCTAssertTrue(AgentSessionStore.shared.snapshots.contains { $0.binding.workspaceID == "w6" && $0.backendStatusAvailable })
    }

    func testInactiveHerdrAgentObserverReceivesMessagesWithoutTerminalPresentation() async throws {
        let (process, endpoint, path) = try await fixture("window-agents")
        defer { cleanup(process, path) }
        let store = AgentSessionStore()
        // Use a separate store to prove the observer does not depend on instantiated terminal panes.
        let observer = HerdrAgentMonitor(store: store)
        defer { observer.stop() }
        let message = expectation(description: "independent semantic message")
        var delivered = 0
        store.onNotification = { _ in delivered += 1; message.fulfill() }
        observer.start(endpoint); observer.start(endpoint)
        await fulfillment(of: [message], timeout: 5)
        XCTAssertEqual(delivered, 1); XCTAssertEqual(store.messages.first?.body, "Ready to review")
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertFalse(observer.session?.isPresentationReady ?? true)
        XCTAssertEqual(observer.session?.agentCompletions?.completions["w5:pA"], 11)
        XCTAssertTrue(process.isRunning)
        observer.stop()
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertFalse(try XCTUnwrap(store.snapshots.first).backendStatusAvailable)
    }

    private func fixture(_ scenario: String) async throws -> (Process, HerdrEndpoint, String) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Scripts/herdr-clientshell-fixture.py")
        let path = "/tmp/herdr-shell-\(UUID().uuidString).sock"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, path, scenario]
        try process.run()
        let clientPath = String(path.dropLast(5)) + "-client.sock"
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: clientPath) { return (process, .init(binary: script, session: "fixture", socketPath: path), path) }
            try await Task.sleep(for: .milliseconds(10))
        }
        process.terminate(); process.waitUntilExit()
        throw CLIError("ClientShell fixture did not create its socket")
    }

    private func cleanup(_ process: Process, _ path: String) {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        for file in [path + ".trace", path + ".trace.tmp", String(path.dropLast(5)) + "-client.sock"] {
            if FileManager.default.fileExists(atPath: file) { try? FileManager.default.removeItem(atPath: file) }
        }
    }

    func testActivationRequiresMatchingSurfaceAndFenceAndSerializesRequests() async throws {
        let (process, endpoint, path) = try await fixture("normal")
        defer { cleanup(process, path) }
        let session = autoPresentedSession(endpoint)
        defer { session.disconnect() }
        let ready = expectation(description: "coherent image surface")
        var presented = false
        session.onProjection = { [weak session] snapshot, surface, assets in
            XCTAssertTrue(session?.acknowledgePresentation(surface) == true)
            XCTAssertEqual(snapshot.revision, surface.projection_revision)
            XCTAssertEqual(surface.graphics.assets.first?.data, Data([255, 0, 0, 255]))
            XCTAssertEqual(assets.count, 1)
            if !presented { presented = true; ready.fulfill() }
        }
        XCTAssertFalse(session.input(target: "w5:pA", events: [.text("offline")]))
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: true)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(session.state, .interactive)
        XCTAssertEqual(session.serviceIdentity?.pid, process.processIdentifier,
                       "Runtime lookups must bind to the same server process as ClientShell")
        async let pane = session.request("pane.rename", params: .init(pane_id: "w5:pA", label: "fixture"))
        async let tab = session.request("tab.rename", params: .init(tab_id: "w5:t4", label: "fixture"))
        let replies = try await [pane, tab]
        XCTAssertEqual(replies.count, 2)
        for reply in replies {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
            XCTAssertEqual((json["result"] as? [String: String])?["type"], "ok")
        }
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        XCTAssertEqual(trace.compactMap { $0["method"] as? String }.first, "client_shell.surface.set")
        XCTAssertEqual(Set(trace.compactMap { $0["method"] as? String }), ["client_shell.surface.set", "pane.rename", "tab.rename"])
        XCTAssertFalse(session.input(target: "unknown", events: [.text("x")]))
        XCTAssertTrue(session.input(target: "w5:pA", events: [.text("x")]))
    }

    func testMalformedPacketFailsAndDisconnectDoesNotReplayPendingRequest() async throws {
        let (broken, endpoint, path) = try await fixture("malformed")
        defer { cleanup(broken, path) }
        let session = autoPresentedSession(endpoint)
        let failed = expectation(description: "invalid packet rejected")
        var retryable: Bool?
        session.onFailure = { _, value in retryable = value }
        session.onState = { if case .failed = $0 { failed.fulfill() } }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: false)
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(retryable, false, "Malformed wire data must not initiate automatic reconnection")
        XCTAssertTrue(session.diagnostics.capturedAtFailure)
        XCTAssertEqual(session.diagnostics.state, "failed")
        XCTAssertFalse(session.diagnostics.presentationReady)
        session.disconnect()

        let (stalled, other, otherPath) = try await fixture("stalled")
        defer { cleanup(stalled, otherPath) }
        let ready = expectation(description: "activated")
        var didReady = false
        session.onState = { if $0 == .interactive, !didReady { didReady = true; ready.fulfill() } }
        let second = autoPresentedSession(other)
        second.onState = session.onState
        defer { second.disconnect() }
        try await second.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: false)
        await fulfillment(of: [ready], timeout: 5)
        let request = Task { try await second.request("pane.rename", params: .init(pane_id: "w5:pA", label: "fixture")) }
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: otherPath + ".trace")),
               String(decoding: data, as: UTF8.self).contains("pane.rename") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        second.disconnect()
        do { _ = try await request.value; XCTFail("Disconnected operation must have an unknown result") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not replayed")) }
        XCTAssertEqual(second.state, .disconnected)
        XCTAssertNil(second.serviceIdentity)
    }

    func testNavigationTimingsSeparateResponseSceneAndAcceptedHostCommit() async throws {
        let (process, endpoint, path) = try await fixture("navigation")
        defer { cleanup(process, path) }
        let session = HerdrClientShellSession(endpoint: endpoint)
        defer { session.disconnect() }
        let initial = expectation(description: "initial presented"), matched = expectation(description: "navigation scene offered")
        var targetFrame: HerdrShellSurface?
        session.onProjection = { [weak session] snapshot, frame, _ in
            if snapshot.focused_pane_id == "w5:pA" {
                XCTAssertTrue(session?.acknowledgePresentation(frame) == true)
                initial.fulfill()
            } else { targetFrame = frame; matched.fulfill() }
        }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: false)
        await fulfillment(of: [initial], timeout: 5)
        _ = try await session.request("pane.focus", params: .init(pane_id: "w5:pB"))
        XCTAssertEqual(session.diagnostics.navigationRequestToResponse.sampleCount, 1)
        XCTAssertEqual(session.diagnostics.navigationResponseToMatchingScene.sampleCount, 0)
        XCTAssertEqual(session.diagnostics.navigationTotal.sampleCount, 0)
        await fulfillment(of: [matched], timeout: 5)
        XCTAssertEqual(session.diagnostics.navigationResponseToMatchingScene.sampleCount, 1)
        XCTAssertTrue(session.diagnostics.navigationAwaitingHostCommit)
        XCTAssertEqual(session.diagnostics.navigationMatchingSceneToHostCommit.sampleCount, 0)
        XCTAssertEqual(session.diagnostics.navigationTotal.sampleCount, 0)
        XCTAssertTrue(session.acknowledgePresentation(try XCTUnwrap(targetFrame)))
        let report = session.diagnostics
        XCTAssertEqual(report.navigationMatchingSceneToHostCommit.sampleCount, 1)
        XCTAssertEqual(report.navigationTotal.sampleCount, 1)
        XCTAssertFalse(report.navigationAwaitingHostCommit)
        let components = try XCTUnwrap(report.navigationRequestToResponse.lastMilliseconds)
            + XCTUnwrap(report.navigationResponseToMatchingScene.lastMilliseconds)
            + XCTUnwrap(report.navigationMatchingSceneToHostCommit.lastMilliseconds)
        XCTAssertEqual(try XCTUnwrap(report.navigationTotal.lastMilliseconds), components, accuracy: 0.001)
        XCTAssertTrue(session.acknowledgePresentation(try XCTUnwrap(targetFrame)))
        XCTAssertEqual(session.diagnostics.navigationTotal.sampleCount, 1, "Repeated ACK must not count another completed navigation")
    }

    func testNavigationAcknowledgementCannotEnableInputOnPreviousSurface() async throws {
        let (process, endpoint, path) = try await fixture("navigation")
        defer { cleanup(process, path) }
        let session = autoPresentedSession(endpoint)
        defer { session.disconnect() }
        let initial = expectation(description: "initial pane"), switched = expectation(description: "new coherent pane")
        var initialSeen = false, switchedSeen = false
        session.onProjection = { [weak session] snapshot, frame, _ in
            XCTAssertTrue(session?.acknowledgePresentation(frame) == true)
            if snapshot.focused_pane_id == "w5:pA", !initialSeen { initialSeen = true; initial.fulfill() }
            if snapshot.focused_pane_id == "w5:pB", !switchedSeen { switchedSeen = true; switched.fulfill() }
        }
        try await session.start(size: .init(cols: 2, rows: 1), cellWidth: 8, cellHeight: 16, focused: true)
        await fulfillment(of: [initial], timeout: 5)
        let press = HerdrShellInput.key(.init(code: 1, tracksRelease: true, physicalKeyID: 36))
        let down = HerdrShellInput.mouse(.init(kind: 0, button: 0, column: 0, row: 0))
        XCTAssertTrue(session.input(target: "w5:pA", events: [press, down]))
        _ = try await session.request("pane.focus", params: .init(pane_id: "w5:pB"))
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        let focusIndex = try XCTUnwrap(trace.firstIndex(where: { $0["method"] as? String == "pane.focus" }))
        XCTAssertGreaterThan(focusIndex, 1)
        let release = HerdrShellInput.key(.init(code: 1, kind: 2, tracksRelease: true, physicalKeyID: 36))
        let up = HerdrShellInput.mouse(.init(kind: 1, button: 0, column: 0, row: 0))
        let expected = try [[release, up], [up, release]].map { events in
            try HerdrShellClientMessage.input(target: "w5:pA", popup: false, events: events).encoded()
                .dropFirst(4).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertTrue(expected.contains(trace[focusIndex - 1]["payload"] as? String ?? ""),
                      "Held keys and buttons must be released to the old pane before endpoint navigation")
        XCTAssertEqual(session.state, .connecting)
        XCTAssertFalse(session.input(target: "w5:pA", events: [.text("must not reach old pane")]))
        await fulfillment(of: [switched], timeout: 5)
        XCTAssertEqual(session.state, .interactive)
        XCTAssertFalse(session.input(target: "w5:pA", events: [.text("old pane")]))
        XCTAssertTrue(session.input(target: "w5:pB", events: [.text("new pane")]))
    }
}
