import Foundation
import GhosttyTerminal
import XCTest
@testable import Santty

final class HerdrWorkspaceMergeTests: XCTestCase {
    private func root(_ tab: String, terminals: [String]) -> HerdrJSONValue {
        .object(["id": .string(tab), "type": .string("row"),
                 "children": .array(terminals.enumerated().map { index, address in
                     .object(["id": .string("p" + String(repeating: String(index), count: 32)),
                              "type": .string("block"), "content": .object(["terminal": .string(address)])])
                 })])
    }
    private func view(_ name: String = "Shared", tabs: [(String, String, [String])]) -> HerdrSharedView {
        func tabID(_ digit: String) -> String { "c" + String(repeating: digit, count: 32) }
        return HerdrSharedView(id: "s00000000000000000000000000000001", name: name, folder: "/tmp",
                               tabs: tabs.map { .init(id: tabID($0.0), name: $0.1, root: root(tabID($0.0), terminals: $0.2)) })
    }

    func testFirstSyncAdoptsDocumentAndLocalOnlyChangeIsPublished() {
        let document = view("Desktop", tabs: [("1", "shell", ["t1"])])
        let first = HerdrWorkspaceMerge.merge(base: nil, local: view("Local", tabs: [("2", "mine", ["t2"])]), remote: document)
        XCTAssertEqual(first.view, document)
        XCTAssertFalse(first.createSpace)
        let local = view("Local", tabs: [("1", "mine", ["t1"])])
        let second = HerdrWorkspaceMerge.merge(base: document, local: local, remote: document)
        XCTAssertEqual(second.view, local)
        XCTAssertTrue(second.conflicts.isEmpty)
    }

    func testRemoteOnlyChangeIsAdoptedWithoutConflict() {
        let base = view(tabs: [("1", "shell", ["t1"])])
        let remote = view(tabs: [("1", "phone", ["t1"])])
        let result = HerdrWorkspaceMerge.merge(base: base, local: base, remote: remote)
        XCTAssertEqual(result.view, remote)
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    func testSimultaneousEditsKeepTheDocumentAndReportTheLoss() {
        let base = view(tabs: [("1", "shell", ["t1"])])
        let local = view(tabs: [("1", "desktop", ["t1"])])
        let remote = view(tabs: [("1", "phone", ["t1"])])
        let result = HerdrWorkspaceMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(result.view, remote)
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertTrue(result.conflicts[0].contains("phone"))
    }

    func testConcurrentAddsKeepBothTabsAndOrderIsStable() {
        let base = view(tabs: [("1", "a", ["t1"])])
        let local = view(tabs: [("1", "a", ["t1"]), ("2", "local", ["t2"])])
        let remote = view(tabs: [("1", "a", ["t1"]), ("3", "remote", ["t3"])])
        let merged = HerdrWorkspaceMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.view.tabs.map(\.name), ["a", "local", "remote"])
        XCTAssertTrue(merged.conflicts.isEmpty)
        let converged = view(tabs: [("1", "a", ["t1"]), ("2", "local", ["t2"]), ("3", "remote", ["t3"])])
        XCTAssertEqual(HerdrWorkspaceMerge.merge(base: base, local: merged.view, remote: converged).view, converged)
        XCTAssertEqual(HerdrWorkspaceMerge.merge(base: base, local: converged, remote: merged.view).view, converged)
    }

    func testDeletionsAndEditsAcrossSides() {
        let base = view(tabs: [("1", "a", ["t1"]), ("2", "b", ["t2"]), ("3", "c", ["t3"])])
        let local = view(tabs: [("1", "a", ["t1"]), ("3", "c changed here", ["t3"])])
        let remote = view(tabs: [("2", "b", ["t2"]), ("3", "c", ["t3"])])
        let result = HerdrWorkspaceMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(result.view.tabs.map(\.name), ["c changed here"])
        XCTAssertTrue(result.conflicts.isEmpty)

        let deletedLocally = HerdrWorkspaceMerge.merge(base: base, local: view(tabs: [("1", "a", ["t1"]), ("2", "b", ["t2"])]), remote: base)
        XCTAssertEqual(deletedLocally.view.tabs.map(\.name), ["a", "b"])
        XCTAssertTrue(deletedLocally.conflicts.isEmpty)

        // Deleted in the document but changed here: the edit survives and the clash is reported.
        let restored = HerdrWorkspaceMerge.merge(base: base, local: view(tabs: [("1", "a", ["t1"]), ("2", "renamed", ["t2"]), ("3", "c", ["t3"])]),
                                                 remote: view(tabs: [("1", "a", ["t1"]), ("3", "c", ["t3"])]))
        XCTAssertEqual(restored.view.tabs.map(\.name), ["a", "renamed", "c"])
        XCTAssertEqual(restored.conflicts.count, 1)
    }

    func testIdentityIsStableForSanttyAndForeignNodeIDs() {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-00000000002a")!
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        XCTAssertEqual(HerdrWorkspaceIdentity.uuid("p" + hex, coreID: "core"), uuid)
        XCTAssertEqual(HerdrWorkspaceIdentity.uuid("c" + hex, coreID: "core"), uuid)
        XCTAssertEqual(HerdrWorkspaceIdentity.uuid("s" + hex, coreID: "core"), uuid)
        let foreign = HerdrWorkspaceIdentity.uuid("s1a2b3c4", coreID: "core")
        XCTAssertEqual(foreign, HerdrWorkspaceIdentity.uuid("s1a2b3c4", coreID: "core"))
        XCTAssertNotEqual(foreign, HerdrWorkspaceIdentity.uuid("s1a2b3c4", coreID: "other"))
        XCTAssertNotEqual(foreign, HerdrWorkspaceIdentity.uuid("s1a2b3c5", coreID: "core"))
    }

    func testAdapterRoundTripsSanttyWorkspaceAndRejectsUnsupportedContent() throws {
        let workspace = HerdrWorkspaceDocumentTests.workspace(coreID: "core")
        let view = try HerdrWorkspaceAdapter.view(workspace, coreID: "core")
        XCTAssertEqual(view.tabs.count, 1)
        let tabs = try HerdrWorkspaceAdapter.tabs(view, coreID: "core", existing: [:])
        XCTAssertEqual(tabs.map { $0.panes.map(\.id) }, [workspace.tabs[0].panes.map(\.id)])
        XCTAssertEqual(tabs[0].panes.map { $0.herdr?.address }, ["t1", "t2"])
        XCTAssertTrue(tabs[0].panes.allSatisfy { $0.herdrViewer == true })
        XCTAssertEqual(tabs[0].focusedPaneID, workspace.tabs[0].panes[0].id)
        let existing = Dictionary(uniqueKeysWithValues: workspace.tabs[0].panes.map { ($0.id, $0) })
        let kept = try HerdrWorkspaceAdapter.tabs(view, coreID: "core", existing: existing)
        XCTAssertEqual(kept[0].panes, workspace.tabs[0].panes, "Known panes keep their identity and ownership")
        XCTAssertEqual(kept[0].layout, workspace.tabs[0].layout)

        var broken = workspace
        broken.tabs[0].floating = .init(paneID: workspace.tabs[0].panes[0].id, size: nil)
        XCTAssertThrowsError(try HerdrWorkspaceAdapter.view(broken, coreID: "core"))
    }

    func testSetSpacePreservesUnknownKeysAndGuardsTheName() throws {
        let original = try JSONDecoder().decode(HerdrJSONValue.self, from: Data(#"""
        {"spaces":[{"id":"s1","name":"Old","folder":"/a","tabs":[],"future":{"k":1}}],"other":true}
        """#.utf8))
        let document = try HerdrWorkspaceDocument(value: original)
        let replacement: HerdrJSONValue = .object(["id": .string("s1"), "name": .string("New"), "folder": .string("/b"),
                                                   "tabs": .array([]), "unknownFromReplacement": .string("dropped")])
        let updated = try document.applying(.setSpace(replacement, expectedName: "Old"))
        XCTAssertEqual(updated.value["other"], original["other"])
        let space = try XCTUnwrap(updated.value["spaces"]?.array?.first?.object)
        XCTAssertEqual(space["future"]?["k"], .integer(1))
        XCTAssertEqual(space["name"], .string("New"))
        XCTAssertNil(space["unknownFromReplacement"])
        XCTAssertThrowsError(try document.applying(.setSpace(replacement, expectedName: "Renamed")))
        let removed = try document.applying(.removeSpace(id: "s1", expectedName: "Old"))
        XCTAssertEqual(removed.value["spaces"], .array([]))
        XCTAssertThrowsError(try document.applying(.removeSpace(id: "s1", expectedName: "Stale")))
    }
}

@MainActor
final class HerdrWorkspaceSharingIntegrationTests: XCTestCase {
    private struct DocGet: Decodable, Sendable { let value: HerdrJSONValue; let version: UInt64 }
    private struct DocSet: Decodable, Sendable { let version: UInt64 }
    private struct Labels: Decodable, Sendable { let labels: [String: String]? }

    func testTwoClientsConvergeAndLayoutDeletionNeverEndsPrograms() async throws {
        let executable: URL
        do { executable = try HerdrCoreTransport.executable() }
        catch { throw XCTSkip("hc is required for the two-way sharing test") }
        let scratch = URL(fileURLWithPath: "/tmp/santty-sync-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HC_") }
        env["HC_SESSION"] = "probe"; env["HC_SOCKET"] = scratch.appendingPathComponent("core.sock").path
        env["XDG_STATE_HOME"] = scratch.appendingPathComponent("state").path
        env["XDG_CONFIG_HOME"] = scratch.appendingPathComponent("config").path; env["XDG_RUNTIME_DIR"] = scratch.path
        let suite = "HerdrSharingTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = HerdrSettings(defaults: defaults)
        settings.shareWorkspaces = true
        let client = HerdrCoreClient(executable: executable, environment: env, settings: settings)
        defer {
            client.stopAgentMonitoring()
            let stop = Process(); stop.executableURL = executable; stop.arguments = ["server", "stop"]; stop.environment = env
            stop.standardOutput = FileHandle.nullDevice; stop.standardError = FileHandle.nullDevice
            if (try? stop.run()) != nil { stop.waitUntilExit() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: scratch)
        }
        var workspace: WorkspaceViewController? = WorkspaceViewController()
        workspace!.herdrCoreClient = client
        workspace!.debugLoadForTesting()
        workspace!.newHerdrWorkspace(nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace!.view
        workspace!.viewDidAppear()
        defer { window.contentView = nil; workspace = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func waitFor(_ stage: String, _ condition: @escaping @MainActor () async throws -> Bool) async throws {
            for _ in 0..<600 {
                if try await condition() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("Timed out at \(stage)")
            throw CLIError("Timed out at \(stage)")
        }
        let terminal = try XCTUnwrap(descendants(workspace!.view).compactMap { $0 as? TerminalView }.first)
        workspace!.view.layoutSubtreeIfNeeded(); terminal.fitToSize()
        let pane = try XCTUnwrap(terminal.delegate as? TerminalPaneController)
        let session = try XCTUnwrap(pane.herdrSession)
        try await waitFor("initial attach") { session.state == .live }
        let binding = try XCTUnwrap(session.binding)
        let original = try await client.terminal(binding)
        let connection = try await client.connection()

        let workspaceID = workspace!.debugSelectedWorkspace
        let tabID = workspace!.debugSelectedTabID!
        func hex(_ id: UUID) -> String { id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        let spaceID = "s" + hex(workspaceID), tabNode = "c" + hex(tabID)
        func read() async throws -> DocGet { try await HerdrCoreClient.request(connection, "doc.get", ["name": HerdrWorkspaceDocument.name]) }
        func write(_ document: HerdrWorkspaceDocument, version: UInt64) async throws -> DocSet {
            let params: [String: HerdrJSONValue] = ["name": .string(HerdrWorkspaceDocument.name),
                                                    "version": .unsigned(version), "value": document.value]
            let reply = try await connection.call(method: "doc.set", params: try JSONEncoder().encode(params))
            return try JSONDecoder().decode(HerdrCoreReply<DocSet>.self, from: reply).get()
        }
        func document(_ value: HerdrJSONValue) throws -> HerdrWorkspaceDocument {
            value == .null ? try HerdrWorkspaceDocument() : try HerdrWorkspaceDocument(value: value)
        }
        func sharedTab() async throws -> HerdrJSONValue? {
            let document = try document(try await read().value)
            guard let tab = try document.space(id: spaceID)?.tabs.first(where: { $0.id == tabNode }) else { return nil }
            return .object(["id": .string(tab.id), "name": .string(tab.name), "root": tab.root])
        }
        func terminalAddresses() async throws -> [String] {
            guard let tab = try await sharedTab() else { return [] }
            return Self.addresses(tab["root"] ?? .null)
        }

        // Local -> document: Santty publishes the workspace, its pane and the Herdr membership labels.
        try await waitFor("workspace published") { try await terminalAddresses().isEmpty == false }
        let publishedAddresses = try await terminalAddresses()
        XCTAssertEqual(publishedAddresses, [binding.address])
        let labels: Labels = try await HerdrCoreClient.request(connection, "terminal.get", ["terminal": binding.address])
        XCTAssertEqual(labels.labels?["herdr.space"], spaceID)
        XCTAssertEqual(labels.labels?["herdr.tab"], tabNode)

        // Another client renames the tab; Santty adopts it without restarting the program.
        var snapshot = try await read()
        let renamed = try document(snapshot.value).applying(.renameTab(spaceID: spaceID, id: tabNode, expectedName: "", name: "Phone edit"))
        _ = try await write(renamed, version: snapshot.version)
        try await waitFor("remote rename adopted") { workspace!.savedWorkspace().tabs.first { $0.id == tabID }?.customTitle == "Phone edit" }
        let afterRename = try await client.terminal(binding)
        XCTAssertEqual(afterRename.pid, original.pid)

        // Local -> document: splitting here adds a second terminal block and label.
        workspace!.debugSplitFocusedPane(along: .horizontal)
        try await waitFor("local split published") { try await terminalAddresses().count == 2 }
        let splitPanes = workspace!.savedWorkspace().tabs.first { $0.id == tabID }!.panes
        let removedPane = try XCTUnwrap(splitPanes.first { $0.herdr?.address != binding.address })
        let removedBinding = try XCTUnwrap(removedPane.herdr)
        let removedRecord = try await client.terminal(removedBinding)
        let splitAddresses = try await terminalAddresses()
        XCTAssertEqual(splitAddresses.count, 2)

        // Another client closes that pane: Santty drops it, clears its membership and keeps the program.
        snapshot = try await read()
        let sharedTabValue = try await sharedTab()
        var tabValue = try XCTUnwrap(sharedTabValue)
        var rootObject = try XCTUnwrap(tabValue["root"]?.object)
        let children = try XCTUnwrap(rootObject["children"]?.array)
        let survivor = try XCTUnwrap(children.first { child in
            child["content"]?["terminal"]?.string == binding.address
        })
        rootObject["children"] = .array([survivor])
        rootObject["type"] = .string("row")
        tabValue = .object(["id": tabValue["id"]!, "name": tabValue["name"]!, "root": .object(rootObject)])
        let remaining = try document(snapshot.value)
        let spaceName = try XCTUnwrap(try remaining.space(id: spaceID)?.name)
        let replacement: HerdrJSONValue = .object(["id": .string(spaceID), "name": .string(spaceName),
                                                   "folder": .string(""), "tabs": .array([tabValue])])
        let edited = try remaining.applying(.setSpace(replacement, expectedName: spaceName))
        _ = try await write(edited, version: snapshot.version)
        try await waitFor("remote pane removal adopted") { workspace!.savedWorkspace().tabs.first { $0.id == tabID }?.panes.count == 1 }
        let survivorAfterRemoval = try await client.terminal(binding)
        let removedAfterRemoval = try await client.terminal(removedBinding)
        XCTAssertEqual(survivorAfterRemoval.pid, original.pid)
        XCTAssertEqual(removedAfterRemoval.pid, removedRecord.pid, "Closing a pane elsewhere never ends the program")
        XCTAssertEqual(removedAfterRemoval.state, "live")
        try await waitFor("removed pane leaves the shared structure") {
            let current: Labels = try await HerdrCoreClient.request(connection, "terminal.get", ["terminal": removedBinding.address])
            return current.labels?["herdr.space"] == nil
        }

        // A space deleted elsewhere is not re-created from here, and its programs stay alive.
        snapshot = try await read()
        let beforeDelete = try document(snapshot.value)
        let deleted = try beforeDelete.applying(.removeSpace(id: spaceID, expectedName: try XCTUnwrap(beforeDelete.space(id: spaceID)?.name)))
        _ = try await write(deleted, version: snapshot.version)
        try await Task.sleep(for: .milliseconds(1200))
        let resurrected = try await sharedTab()
        XCTAssertNil(resurrected, "A workspace closed in the document must not be resurrected")
        XCTAssertEqual(workspace!.savedWorkspace().tabs.first { $0.id == tabID }?.panes.count, 1)
        let stillLive = try await client.terminal(binding)
        XCTAssertEqual(stillLive.state, "live")
    }

    private static func addresses(_ value: HerdrJSONValue) -> [String] {
        if let address = value["content"]?["terminal"]?.string { return [address] }
        return (value["children"]?.array ?? []).flatMap(addresses)
    }
}
