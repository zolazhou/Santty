import AppKit
import XCTest
@testable import Santty

final class WorkspaceStoreTests: XCTestCase {
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("workspace.json")
    }

    private func document(title: String = "Shell") -> SavedWorkspace {
        let pane = SavedWorkspace.Pane(id: UUID(), kind: .localTerminal, title: title)
        let tab = SavedWorkspace.Tab(id: UUID(), layout: .panel(pane.id), panes: [pane], focusedPaneID: pane.id,
            autoResize: [:], detachedPaneIDs: [], floatingSizes: [:])
        return .init(selectedTabID: tab.id, tabs: [tab])
    }

    func testAtomicRoundTripPrivateFilesAndBackupRecovery() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try WorkspaceStore(url: url)
        let empty = try await store.load(); XCTAssertNil(empty.workspace)
        let first = document(title: "first")
        let second = document(title: "second")
        try await store.save(first); try await store.save(second)
        let saved = try await store.load(); XCTAssertEqual(saved.workspace, second)
        let mode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        try Data("{broken".utf8).write(to: url)
        let recovered = try await store.load()
        XCTAssertEqual(recovered.workspace, first)
        XCTAssertNotNil(recovered.warning)
        try await store.save(first)
        let repaired = try await store.load(); XCTAssertEqual(repaired.workspace, first)
    }

    func testSecondInstanceCannotWriteAndKernelLockCanBeReacquired() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var owner: WorkspaceStore? = try WorkspaceStore(url: url)
        try await owner!.save(document())
        let other = try WorkspaceStore(url: url)
        XCTAssertFalse(other.canWrite)
        let loaded = try await other.load(); XCTAssertNotNil(loaded.warning)
        do { try await other.save(document()); XCTFail("Second instance wrote the file") } catch {}
        owner = nil
        let replacement = try WorkspaceStore(url: url)
        XCTAssertTrue(replacement.canWrite)
    }

    func testLegacyVersionsLoadBeforeWritingCurrentVersion() async throws {
        for version in [1, 2, 3, 4] {
            let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            var legacy = document(); legacy.version = version
            try JSONEncoder().encode(legacy).write(to: url)
            let store = try WorkspaceStore(url: url)
            let loaded = try await store.load()
            XCTAssertEqual(loaded.workspace, legacy)
            XCTAssertEqual(loaded.workspace?.restoredHerdrWindowTransport, .clientShell)
            let current = document()
            XCTAssertEqual(current.version, SavedWorkspace.currentVersion)
            try await store.save(current)
            let saved = try await store.load()
            XCTAssertEqual(saved.workspace, current)
        }
    }

    func testLegacyTransportAndObserveModeDecodeToClientShellControl() throws {
        for value in ["direct", "clientShell"] {
            let decoded = try JSONDecoder().decode(HerdrPaneTransport.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(decoded, .clientShell)
            XCTAssertEqual(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self), "\"clientShell\"")
        }
        for value in ["observe", "control"] {
            XCTAssertEqual(try JSONDecoder().decode(HerdrTerminalMode.self, from: JSONEncoder().encode(value)), .control)
        }
        for value in ["unknown", "takeover"] {
            XCTAssertThrowsError(try JSONDecoder().decode(HerdrTerminalMode.self, from: JSONEncoder().encode(value)))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(HerdrPaneTransport.self, from: Data("\"unknown\"".utf8)))
    }

    func testFutureVersionAndCorruptFilesAreNeverOverwritten() async throws {
        for content in ["{\"version\":99,\"tabs\":[]}", "{broken"] {
            let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = try WorkspaceStore(url: url)
            let bytes = Data(content.utf8)
            try bytes.write(to: url)
            do { _ = try await store.load(); XCTFail("Invalid file accepted") } catch {}
            do { try await store.save(document()); XCTFail("Unreadable file overwritten") } catch {}
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testFuturePrimaryDoesNotFallBackToOlderValidBackup() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try WorkspaceStore(url: url)
        try await store.save(document()); try await store.save(document())
        try Data("{\"version\":99,\"tabs\":[]}".utf8).write(to: url)
        do { _ = try await store.load(); XCTFail("A future file was downgraded") } catch {}
    }

    func testMultipleLocalWorkspacesRoundTripAndValidateAcrossGroups() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try WorkspaceStore(url: url)
        var saved = document()
        saved.localWorkspaceID = UUID(); saved.localWorkspaceName = "Default"
        let other = document(title: "Second shell")
        saved.otherLocalWorkspaces = [.init(id: UUID(), name: "Workspace 1", selectedTabID: other.selectedTabID, tabs: other.tabs)]
        try await store.save(saved)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.workspace, saved)
        var invalid = saved
        invalid.otherLocalWorkspaces?[0].tabs = saved.tabs
        XCTAssertThrowsError(try invalid.validate(), "Tab and pane IDs cannot be reused across workspaces")
        invalid = saved; invalid.otherLocalWorkspaces?[0].selectedTabID = saved.selectedTabID
        XCTAssertThrowsError(try invalid.validate(), "A workspace cannot select another workspace's tab")
        invalid = saved; invalid.otherLocalWorkspaces?[0].name = ""
        XCTAssertThrowsError(try invalid.validate())
        invalid = saved; invalid.otherLocalWorkspaces?.append(saved.otherLocalWorkspaces![0])
        XCTAssertThrowsError(try invalid.validate())
        invalid = saved; invalid.version = 4
        XCTAssertThrowsError(try invalid.validate(), "Older apps must not overwrite the new format")
    }

    func testValidationRejectsBrokenLayoutsAndReferences() throws {
        var saved = document()
        saved.tabs[0].layout = .split(axis: .horizontal, children: [.panel(saved.tabs[0].panes[0].id)], fractions: [1])
        XCTAssertThrowsError(try saved.validate())
        saved = document(); saved.tabs[0].detachedPaneIDs = [saved.tabs[0].panes[0].id]
        XCTAssertThrowsError(try saved.validate())
        saved = document(); saved.tabs[0].floatingSizes[saved.tabs[0].panes[0].id] = CGSize(width: CGFloat.infinity, height: 40)
        XCTAssertThrowsError(try saved.validate())
        saved = document(); saved.herdrWindowTransport = .clientShell
        XCTAssertThrowsError(try saved.validate(), "ClientShell transport belongs to a complete Herdr window")
    }

    func testOversizedFileAndSymlinkLockAreRejected() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try WorkspaceStore(url: url)
        try Data(repeating: 65, count: WorkspaceStore.maximumBytes + 1).write(to: url)
        do { _ = try await store.load(); XCTFail("Oversized file accepted") } catch {}
        let other = url.deletingLastPathComponent().appendingPathComponent("other.json")
        try FileManager.default.createSymbolicLink(atPath: other.appendingPathExtension("lock").path, withDestinationPath: url.path)
        XCTAssertThrowsError(try WorkspaceStore(url: other))
    }
}

@MainActor
final class WorkspaceRestorationTests: XCTestCase {

    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("restore-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("workspace.json")
    }

    private func document(service: HerdrWorkspaceTests.Service) async throws -> SavedWorkspace {
        let client = HerdrWorkspaceClient(endpoint: service.endpoint)
        let metadata = try await client.create()
        let binding = try HerdrPaneBinding(endpoint: service.endpoint, pane: metadata, includeRuntime: true)
        let pane = SavedWorkspace.Pane(id: UUID(), kind: .persistentTerminal, name: "API", title: "Shell", binding: binding, mode: .control)
        let local = SavedWorkspace.Pane(id: UUID(), kind: .localTerminal, name: "Local", title: "Shell")
        let browser = SavedWorkspace.Pane(id: UUID(), kind: .browser, title: "Browser")
        let tab = SavedWorkspace.Tab(id: UUID(), layout: .split(axis: .horizontal,
            children: [.panel(pane.id), .panel(local.id), .panel(browser.id)], fractions: [0.4, 0.3, 0.3]),
            panes: [pane, local, browser], focusedPaneID: pane.id, customTitle: "Dev", backendBinding: binding,
            autoResize: [:], detachedPaneIDs: [], floatingSizes: [:])
        return .init(selectedTabID: tab.id, tabs: [tab])
    }

    func testLocalWorkspaceSwitchingPaletteAndRestorationKeepIndependentTabs() async throws {
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        defer { workspace.releaseHerdrConnections() }
        let defaultID = try XCTUnwrap(workspace.savedWorkspace().localWorkspaceID)
        workspace.newBrowserPane(nil)
        workspace.debugSetFocusedPaneName("Default browser")
        let browserID = try XCTUnwrap(workspace.debugFocusedPaneID)
        workspace.debugToggleFloatingPane()
        workspace.newTab(nil)
        let defaultTabs = workspace.debugTabIDs
        let defaultSelectedTab = workspace.debugSelectedTabID
        workspace.newWorkspace(nil)
        let secondID = try XCTUnwrap(workspace.savedWorkspace().localWorkspaceID)
        let secondTabs = workspace.debugTabIDs
        XCTAssertNotEqual(secondID, defaultID)
        XCTAssertEqual(workspace.savedWorkspace().localWorkspaceName, "Workspace 1")
        XCTAssertEqual(workspace.savedWorkspace().otherLocalWorkspaces?.first?.selectedTabID, defaultSelectedTab)
        workspace.newBrowserPane(nil)
        workspace.debugSetFocusedPaneName("Second browser")
        let secondBrowserID = try XCTUnwrap(workspace.debugFocusedPaneID)
        let defaultBrowser = try XCTUnwrap(workspace.paletteNavigationItems.first { $0.kind == .pane && $0.title == "Default browser" })
        XCTAssertFalse(defaultBrowser.isInCurrentWorkspace)
        defaultBrowser.perform()
        await workspace.waitForPaletteNavigationForTesting()
        XCTAssertEqual(workspace.savedWorkspace().localWorkspaceID, defaultID)
        XCTAssertEqual(workspace.debugTabIDs, defaultTabs)
        XCTAssertEqual(workspace.debugFocusedPaneID, browserID)
        XCTAssertEqual(workspace.debugActiveFloatingPaneState?.paneID, browserID)
        workspace.selectWorkspace("local." + secondID.uuidString)
        XCTAssertEqual(workspace.debugTabIDs, secondTabs)
        XCTAssertEqual(workspace.debugFocusedPaneID, secondBrowserID)
        let saved = try JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(workspace.savedWorkspace()))
        try saved.validate()
        let restored = WorkspaceViewController(); restored.debugLoadForTesting()
        defer { restored.releaseHerdrConnections() }
        try restored.restoreWorkspace(saved)
        XCTAssertEqual(restored.savedWorkspace().localWorkspaceID, secondID)
        XCTAssertEqual(restored.debugFocusedPaneID, secondBrowserID)
        restored.selectLocalWorkspace(defaultID)
        XCTAssertEqual(restored.debugTabIDs, defaultTabs)
        XCTAssertEqual(restored.debugFocusedPaneID, browserID)
        XCTAssertEqual(restored.debugActiveFloatingPaneState?.paneID, browserID)
        XCTAssertTrue(restored.debugRestoredPlaceholderCount > 0)
        let picker = try XCTUnwrap((restored.view as? WorkspaceRootView)?.toolbarView.workspaceSwitcher)
        XCTAssertEqual(picker.itemTitles, ["Default", "Workspace 1"])
        XCTAssertEqual(picker.titleOfSelectedItem, "Default")
    }

    func testRenamedLocalWorkspacesAndTabsPersistWithoutChangingTheirIDs() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let workspace = WorkspaceViewController()
        await workspace.prepareWorkspacePersistence(url: url)
        workspace.debugLoadForTesting()
        defer { workspace.releaseHerdrConnections() }
        try workspace.restoreWorkspace(workspace.savedWorkspace())
        let projectID = try XCTUnwrap(workspace.savedWorkspace().localWorkspaceID)
        let logsID = try XCTUnwrap(workspace.debugSelectedTabID)
        workspace.updateSelectedWorkspaceName("  Project  ")
        workspace.debugSetSelectedTabTitle("  Logs  ")
        XCTAssertEqual(workspace.savedWorkspace().localWorkspaceID, projectID)
        XCTAssertEqual(workspace.debugSelectedTabID, logsID)
        XCTAssertEqual((workspace.view as? WorkspaceRootView)?.toolbarView.workspaceSwitcher.titleOfSelectedItem, "Project")
        XCTAssertTrue(workspace.paletteNavigationItems.contains { $0.kind == .workspace && $0.title == "Project" && $0.isCurrent })
        workspace.updateSelectedWorkspaceName("   ")
        workspace.updateSelectedWorkspaceName(String(repeating: "x", count: 1025))
        workspace.debugSetSelectedTabTitle(String(repeating: "x", count: 1025))
        XCTAssertEqual(workspace.savedWorkspace().localWorkspaceName, "Project")
        XCTAssertEqual(workspace.savedWorkspace().tabs.first?.customTitle, "Logs")
        try await Task.sleep(for: .milliseconds(350))
        let autosaved = try JSONDecoder().decode(SavedWorkspace.self, from: Data(contentsOf: url))
        XCTAssertEqual(autosaved.localWorkspaceName, "Project")
        XCTAssertEqual(autosaved.tabs.first?.customTitle, "Logs")
        workspace.newWorkspace(nil)
        workspace.updateSelectedWorkspaceName("Tools")
        workspace.debugSetSelectedTabTitle("Build")
        try await workspace.flushWorkspaceState()
        let saved = try JSONDecoder().decode(SavedWorkspace.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.otherLocalWorkspaces?.first?.name, "Project")
        XCTAssertEqual(saved.otherLocalWorkspaces?.first?.tabs.first?.customTitle, "Logs")
        let restored = WorkspaceViewController(); restored.debugLoadForTesting()
        defer { restored.releaseHerdrConnections() }
        try restored.restoreWorkspace(saved)
        XCTAssertEqual(restored.savedWorkspace().localWorkspaceName, "Tools")
        XCTAssertEqual(restored.savedWorkspace().tabs.first?.customTitle, "Build")
        restored.selectLocalWorkspace(projectID)
        XCTAssertEqual(restored.debugSelectedTabID, logsID)
        XCTAssertEqual(restored.savedWorkspace().localWorkspaceName, "Project")
        restored.debugSetSelectedTabTitle("   ")
        XCTAssertNil(restored.savedWorkspace().tabs.first?.customTitle, "Empty tab names restore automatic titles")
    }

    func testCloseLocalWorkspacePreservesOthersAndReplacesLastWithDefault() async throws {
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        defer { workspace.releaseHerdrConnections() }
        let defaultID = try XCTUnwrap(workspace.savedWorkspace().localWorkspaceID)
        let defaultTabs = workspace.debugTabIDs
        workspace.newWorkspace(nil)
        let secondID = try XCTUnwrap(workspace.savedWorkspace().localWorkspaceID)
        let alert = workspace.closeWorkspaceAlert()
        XCTAssertEqual(alert.messageText, "Close Workspace?")
        XCTAssertEqual(alert.alertStyle, .warning)
        XCTAssertEqual(alert.buttons.map(\.title), ["Close Workspace", "Cancel"])
        XCTAssertTrue(alert.informativeText.contains("Workspace 1"))
        await workspace.closeLocalWorkspace(defaultID)
        XCTAssertEqual(workspace.savedWorkspace().localWorkspaceID, secondID, "A stale close target must not close the current workspace")
        await workspace.closeLocalWorkspace(secondID)
        XCTAssertEqual(workspace.savedWorkspace().localWorkspaceID, defaultID)
        XCTAssertEqual(workspace.debugTabIDs, defaultTabs)
        XCTAssertNil(workspace.savedWorkspace().otherLocalWorkspaces)
        XCTAssertFalse(workspace.debugDidRequestWindowClose)
        await workspace.closeLocalWorkspace(defaultID)
        XCTAssertEqual(workspace.savedWorkspace().localWorkspaceName, "Default")
        XCTAssertNotEqual(workspace.savedWorkspace().localWorkspaceID, defaultID)
        XCTAssertFalse(workspace.debugTabIDs.isEmpty)
        XCTAssertTrue(Set(defaultTabs).isDisjoint(with: workspace.debugTabIDs))
        try workspace.savedWorkspace().validate()
    }

    func testClosingLastTabOfOneLocalWorkspaceDoesNotCloseOtherWorkspaces() throws {
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        defer { workspace.releaseHerdrConnections() }
        let defaultID = workspace.savedWorkspace().localWorkspaceID
        let defaultTabs = workspace.debugTabIDs
        workspace.newWorkspace(nil)
        workspace.debugCloseTab(withID: try XCTUnwrap(workspace.debugSelectedTabID))
        XCTAssertEqual(workspace.savedWorkspace().localWorkspaceID, defaultID)
        XCTAssertEqual(workspace.debugTabIDs, defaultTabs)
        XCTAssertFalse(workspace.debugDidRequestWindowClose)
        try workspace.savedWorkspace().validate()
    }

    func testLegacyMixedLayoutRetainsPlaceholdersAndLocalContentWithoutAttaching() async throws {
        let service = HerdrWorkspaceTests.Service(); try await service.start()
        defer { service.stop() }
        let original = try await document(service: service)
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        defer { workspace.releaseHerdrConnections() }
        try workspace.restoreWorkspace(original)
        XCTAssertEqual(workspace.debugRestoredPlaceholderCount, 2)
        XCTAssertEqual(workspace.debugRestoredPlaceholderCount, 2)
        XCTAssertNil(workspace.debugFocusedHerdrPane)
        XCTAssertEqual(workspace.debugLayoutNode, original.tabs[0].layout)
        XCTAssertEqual(workspace.debugTabIDs, [original.tabs[0].id])
        let methods = try XCTUnwrap(try service.state()["requests"] as? [String])
        XCTAssertEqual(methods.filter { $0 == "workspace.create" }.count, 1)
        XCTAssertFalse(methods.contains("pane.close"))
        workspace.debugFocusPane(withID: original.tabs[0].panes[1].id)
        XCTAssertFalse(workspace.debugFocusedPaneIsTerminal)
    }

    func testAutosaveSurvivesOwnerLossAndRestoresSavedPaneIDs() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = HerdrWorkspaceTests.Service(); try await service.start(); defer { service.stop() }
        let original = try await document(service: service)
        var workspace: WorkspaceViewController? = WorkspaceViewController()
        await workspace!.prepareWorkspacePersistence(url: url)
        workspace!.debugLoadForTesting()
        try workspace!.restoreWorkspace(original)
        workspace!.debugFocusPane(withID: original.tabs[0].panes[2].id)
        workspace!.debugSetFocusedPaneName("Docs")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // No orderly save/quit: the debounced snapshot must already be durable.
        workspace!.releaseHerdrConnections()
        workspace = nil
        let restored = WorkspaceViewController()
        await restored.prepareWorkspacePersistence(url: url)
        restored.debugLoadForTesting()
        defer { restored.releaseHerdrConnections() }
        XCTAssertEqual(restored.debugPaneIDsInTraversalOrder, original.tabs[0].layout?.paneIDsInTraversalOrder)
        XCTAssertEqual(restored.savedWorkspace().tabs[0].panes.first { $0.id == original.tabs[0].panes[2].id }?.name, "Docs")
    }

    func testDetachedFloatingAndAutoResizeStateRestoreWithoutChangingRuntime() async throws {
        let service = HerdrWorkspaceTests.Service(); try await service.start(); defer { service.stop() }
        var saved = try await document(service: service)
        let persistent = saved.tabs[0].panes[0].id
        let local = saved.tabs[0].panes[1].id
        let browser = saved.tabs[0].panes[2].id
        saved.tabs[0].layout = .split(axis: .vertical, children: [.panel(persistent), .panel(browser)], fractions: [0.6, 0.4])
        saved.tabs[0].detachedPaneIDs = [local]
        saved.tabs[0].floating = .init(paneID: browser, size: CGSize(width: 400, height: 300))
        saved.tabs[0].floatingSizes[browser] = CGSize(width: 400, height: 300)
        saved.tabs[0].autoResize[persistent] = WorkspaceFocusZoomConfiguration.defaultAutoResizeConfiguration
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        defer { workspace.releaseHerdrConnections() }
        try workspace.restoreWorkspace(saved)
        let restored = workspace.savedWorkspace().tabs[0]
        XCTAssertEqual(restored.layout, saved.tabs[0].layout)
        XCTAssertEqual(restored.detachedPaneIDs, [local])
        XCTAssertEqual(restored.floating, saved.tabs[0].floating)
        XCTAssertEqual(restored.autoResize, saved.tabs[0].autoResize)
        XCTAssertEqual(restored.panes.first { $0.id == persistent }?.binding, saved.tabs[0].panes[0].binding)
    }

    func testMissingSavedNoteDoesNotChooseAnotherDocument() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let directory = url.deletingLastPathComponent()
        try Data("other note".utf8).write(to: directory.appendingPathComponent("other.md"))
        let missing = directory.appendingPathComponent("missing.md")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RestoreNotes-\(UUID())"))
        let library = NotesLibrary(store: NotesStore(fileURL: missing), defaults: defaults)
        await library.load(preferredFileName: "missing.md")
        XCTAssertEqual(library.store.fileURL, missing)
        XCTAssertNotNil(library.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testSecondInstanceKeepsPlaceholdersAndClosesWithoutOverwritingOwner() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = HerdrWorkspaceTests.Service(); try await service.start(); defer { service.stop() }
        var saved = try await document(service: service)
        saved.tabs[0].panes[0].mode = .control
        let owner = try WorkspaceStore(url: url); try await owner.save(saved)
        let before = try Data(contentsOf: url)
        let workspace = WorkspaceViewController()
        await workspace.prepareWorkspacePersistence(url: url); workspace.debugLoadForTesting()
        defer { workspace.releaseHerdrConnections() }
        XCTAssertNil(workspace.debugFocusedHerdrPane)
        XCTAssertEqual(workspace.debugRestoredPlaceholderCount, 2)
        workspace.debugFocusPane(withID: saved.tabs[0].panes[2].id)
        workspace.debugSetFocusedPaneName("Unsaved second instance")
        try await workspace.flushWorkspaceState()
        let allowed = await workspace.confirmWorkspaceSaveForClose()
        XCTAssertTrue(allowed)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(owner.canWrite)
    }

    func testFailedSaveCancelKeepsWorkspaceAndServiceAlive() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let invalid = Data("{broken".utf8); try invalid.write(to: url)
        let service = HerdrWorkspaceTests.Service(); try await service.start(); defer { service.stop() }
        let saved = try await document(service: service)
        let workspace = WorkspaceViewController()
        workspace.herdrErrorHandler = { _ in }
        await workspace.prepareWorkspacePersistence(url: url); workspace.debugLoadForTesting()
        try workspace.restoreWorkspace(saved)
        defer { workspace.releaseHerdrConnections() }
        let allowed = await workspace.confirmWorkspaceSaveForClose()
        XCTAssertFalse(allowed)
        XCTAssertEqual(workspace.debugRestoredPlaceholderCount, 2)
        XCTAssertEqual(workspace.debugLayoutNode, saved.tabs[0].layout)
        XCTAssertTrue(service.process.isRunning)
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }

    func testMissingAndReusedRuntimeRemainPlaceholdersWithoutMutation() async throws {
        for method in ["fixture.external_close", "fixture.replace_runtime"] {
            let service = HerdrWorkspaceTests.Service(); try await service.start(); defer { service.stop() }
            let saved = try await document(service: service)
            let binding = try XCTUnwrap(saved.tabs[0].panes[0].binding)
            _ = try await HerdrWorkspaceClient(endpoint: service.endpoint).request(method, params: .init(pane_id: binding.paneID))
            let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
            try workspace.restoreWorkspace(saved)
            XCTAssertEqual(workspace.debugRestoredPlaceholderCount, 2)
            XCTAssertNil(workspace.debugFocusedHerdrPane)
            XCTAssertEqual(workspace.debugLayoutNode, saved.tabs[0].layout)
            XCTAssertFalse((try service.state()["requests"] as? [String] ?? []).contains("pane.close"))
            workspace.releaseHerdrConnections()
        }
    }

    func testNewServiceWithSamePublicAndRuntimeIDsCannotAutoRestore() async throws {
        let old = HerdrWorkspaceTests.Service(); try await old.start()
        defer { old.stop() }
        var saved = try await document(service: old)
        let originalBinding = try XCTUnwrap(saved.tabs[0].panes[0].binding)
        await Task.detached { old.stop() }.value
        // Reuse exactly the endpoint path and IDs, with a new service process.
        let process = Process(); process.executableURL = old.endpoint.binary; process.arguments = ["api", old.path, "normal"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            for suffix in ["", ".json", ".json.tmp"] { try? FileManager.default.removeItem(atPath: old.path + suffix) }
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: old.path) { try await Task.sleep(for: .milliseconds(10)) }
        let metadata = try await HerdrWorkspaceClient(endpoint: old.endpoint).create()
        XCTAssertEqual(metadata.terminal_id, originalBinding.terminalID)
        XCTAssertNotEqual(metadata.serviceIdentity, originalBinding.serviceIdentity)
        saved.tabs[0].panes[0].binding = originalBinding
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        try workspace.restoreWorkspace(saved)
        XCTAssertNil(workspace.debugFocusedHerdrPane)
        XCTAssertEqual(workspace.debugRestoredPlaceholderCount, 2)
        workspace.releaseHerdrConnections()
        await Task.detached {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }.value
    }

    func testNotesCancelCloseKeepsConnectionsAndLayoutAlive() async throws {
        let service = HerdrWorkspaceTests.Service(); try await service.start(); defer { service.stop() }
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var saved = try await document(service: service)
        let noteURL = url.deletingLastPathComponent().appendingPathComponent("note.md")
        try Data("saved note".utf8).write(to: noteURL)
        let note = SavedWorkspace.Pane(id: UUID(), kind: .notes, title: "note", noteFileName: "note.md", noteFileURL: noteURL)
        saved.tabs[0].panes[2] = note
        saved.tabs[0].layout = .split(axis: .horizontal, children: [.panel(saved.tabs[0].panes[0].id), .panel(saved.tabs[0].panes[1].id), .panel(note.id)], fractions: [0.4, 0.3, 0.3])
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        try workspace.restoreWorkspace(saved)
        workspace.debugFocusPane(withID: note.id)
        let notes = try XCTUnwrap(workspace.debugFocusedNotesPane)
        await notes.content.waitForPendingOperations()
        XCTAssertEqual(notes.content.store.fileURL, noteURL)
        notes.content.store.setSavingSuspended(true)
        let allowed = await workspace.prepareNotesToClose()
        XCTAssertFalse(allowed)
        XCTAssertEqual(workspace.debugLayoutNode, saved.tabs[0].layout)
        XCTAssertTrue(service.process.isRunning)
        XCTAssertFalse((try service.state()["requests"] as? [String] ?? []).contains("pane.close"))
        notes.content.store.setSavingSuspended(false)
        workspace.releaseHerdrConnections()
    }
}
