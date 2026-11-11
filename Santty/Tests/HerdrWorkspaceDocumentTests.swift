import Foundation
import XCTest
@testable import Santty

final class HerdrWorkspaceDocumentTests: XCTestCase {
    private func json(_ text: String) throws -> HerdrJSONValue {
        try JSONDecoder().decode(HerdrJSONValue.self, from: Data(text.utf8))
    }

    func testRenamesPreserveUnknownFieldsNodesAndLargeIntegers() throws {
        let value = try json(#"{"future":{"turn":18446744073709551615,"enabled":true},"spaces":[{"id":"s1","name":"Desktop","folder":"/remote/path","future":[null,1.25],"tabs":[{"id":"c1","name":"Task","extra":"keep","root":{"id":"c1","type":"future-node","payload":{"mod":"unknown"}}}]}]}"#)
        let document = try HerdrWorkspaceDocument(value: value)
        let renamed = try document.applying(.renameTab(spaceID: "s1", id: "c1", expectedName: "Task", name: "Phone"))
        XCTAssertEqual(try renamed.spaces().first?.tabs.first?.name, "Phone")
        let restored = try renamed.applying(.renameTab(spaceID: "s1", id: "c1", expectedName: "Phone", name: "Task"))
        XCTAssertEqual(restored.value, value)
        let renamedSpace = try document.applying(.renameSpace(id: "s1", expectedName: "Desktop", name: "Shared"))
        XCTAssertEqual(try renamedSpace.spaces().first?.name, "Shared")
        XCTAssertEqual(try json(String(decoding: JSONEncoder().encode(renamedSpace.value), as: UTF8.self))["future"], value["future"])
        XCTAssertThrowsError(try document.applying(.renameSpace(id: "s1", expectedName: "Changed", name: "No")))
        XCTAssertThrowsError(try document.applying(.renameTab(spaceID: "s1", id: "missing", expectedName: "", name: "No")))
        XCTAssertThrowsError(try document.applying(.renameTab(spaceID: "other", id: "c1", expectedName: "Task", name: "No")))
    }

    func testInvalidDocumentsFailClosedAndAbsentSpacesRemainCompatible() throws {
        XCTAssertEqual(try HerdrWorkspaceDocument(value: json("{}")).spaces(), [])
        for invalid in ["null", "[]", #"{"spaces":null}"#, #"{"spaces":[{"id":"s1","tabs":{}}]}"#,
                        #"{"spaces":[{"id":"s1","name":3}]}"#, #"{"spaces":[{"id":"box/s1"}]}"#,
                        #"{"spaces":[{"id":"s1"},{"id":"s1"}]}"#,
                        #"{"spaces":[{"id":"s1","tabs":[{"id":"c1","root":null}]}]}"#,
                        #"{"spaces":[{"id":"s1","tabs":[{"id":"c1"}]},{"id":"s2","tabs":[{"id":"c1"}]}]}"#] {
            XCTAssertThrowsError(try HerdrWorkspaceDocument(value: json(invalid)), invalid)
        }
        let tooLarge: HerdrJSONValue = .object(["future": .string(String(repeating: "x", count: HerdrWorkspaceDocument.maximumBytes))])
        XCTAssertThrowsError(try HerdrWorkspaceDocument(value: tooLarge))
    }

    func testStableProjectionPreservesBindingsAndExcludesDeviceState() throws {
        var workspace = Self.workspace(coreID: "core")
        let seed = try HerdrWorkspaceProjection.export(workspace, coreID: "core")
        let document = try HerdrWorkspaceDocument().applying(.insertSpace(seed.space))
        let space = try XCTUnwrap(document.spaces().first)
        let tab = try XCTUnwrap(space.tabs.first)
        XCTAssertEqual(space.id, HerdrWorkspaceProjection.spaceID(workspace.id))
        XCTAssertEqual(tab.id, HerdrWorkspaceProjection.tabID(workspace.tabs[0].id))
        let layout = try HerdrWorkspaceProjection.layout(tab.root)
        guard case let .split(id, axis, children, fractions) = layout else { return XCTFail("Missing split") }
        XCTAssertEqual(id, tab.id)
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(fractions, [0.25, 0.75])
        XCTAssertEqual(children, workspace.tabs[0].panes.map { .terminal(id: HerdrWorkspaceProjection.paneID($0.id), address: $0.herdr!.address) })
        XCTAssertEqual(HerdrWorkspaceProjection.spaceID(workspace.id), space.id)
        XCTAssertEqual(HerdrWorkspaceProjection.tabID(workspace.tabs[0].id), tab.id)
        workspace.tabs[0].focusedPaneID = workspace.tabs[0].panes[1].id
        XCTAssertEqual(try HerdrWorkspaceProjection.export(workspace, coreID: "core").space, seed.space)
        XCTAssertThrowsError(try document.applying(.insertSpace(seed.space)))

        workspace.herdrRemote = .init(id: "core", name: "renamable-alias")
        for index in workspace.tabs[0].panes.indices { workspace.tabs[0].panes[index].herdr?.remote = true }
        XCTAssertEqual(try HerdrWorkspaceProjection.export(workspace, coreID: "core").space, seed.space,
                       "Remote documents must still use bare machine-local addresses and IDs")
        workspace.herdrRemote = .init(id: "core", name: "new-alias")
        XCTAssertEqual(try HerdrWorkspaceProjection.export(workspace, coreID: "core").space, seed.space)
    }

    func testSinglePaneExportUsesHerdrTabRootContainer() throws {
        var workspace = Self.workspace(coreID: "core")
        let pane = workspace.tabs[0].panes[0]
        workspace.tabs[0].panes = [pane]
        workspace.tabs[0].layout = .panel(pane.id)
        let seed = try HerdrWorkspaceProjection.export(workspace, coreID: "core")
        let document = try HerdrWorkspaceDocument().applying(.insertSpace(seed.space))
        let tab = try XCTUnwrap(document.spaces().first?.tabs.first)
        XCTAssertEqual(try HerdrWorkspaceProjection.layout(tab.root),
                       .split(id: tab.id, axis: .horizontal,
                              children: [.terminal(id: HerdrWorkspaceProjection.paneID(pane.id), address: "t1")], fractions: [1]))
    }

    func testProjectionRejectsUnsupportedOrUnownedWorkspaceRatherThanDroppingPanes() throws {
        let valid = Self.workspace(coreID: "core")
        var invalid = valid
        invalid.kind = .local
        XCTAssertThrowsError(try HerdrWorkspaceProjection.export(invalid, coreID: "core"))
        XCTAssertThrowsError(try HerdrWorkspaceProjection.export(valid, coreID: "different-core"))
        invalid = valid; invalid.tabs[0].panes[0].herdrViewer = true
        XCTAssertThrowsError(try HerdrWorkspaceProjection.export(invalid, coreID: "core"))
        invalid = valid; invalid.tabs[0].panes[0].herdrRunPending = true
        XCTAssertThrowsError(try HerdrWorkspaceProjection.export(invalid, coreID: "core"))
        invalid = valid; invalid.tabs[0].panes[0] = .init(id: invalid.tabs[0].panes[0].id, kind: .browser, title: "Browser")
        XCTAssertThrowsError(try HerdrWorkspaceProjection.export(invalid, coreID: "core"))
        invalid = valid; invalid.tabs[0].panes[0].herdr = nil
        XCTAssertThrowsError(try HerdrWorkspaceProjection.export(invalid, coreID: "core"))
        invalid = valid; invalid.tabs[0].floating = .init(paneID: invalid.tabs[0].panes[0].id, size: nil)
        XCTAssertThrowsError(try HerdrWorkspaceProjection.export(invalid, coreID: "core"))
        invalid = valid; invalid.tabs[0].panes[1].herdr = invalid.tabs[0].panes[0].herdr
        XCTAssertThrowsError(try HerdrWorkspaceProjection.export(invalid, coreID: "core"))
    }

    func testProjectionSupportsNestedRowsColumnsAndRejectsUnsupportedNodes() throws {
        let tree = try json(#"{"id":"c1","type":"row","children":[{"id":"p1","type":"block","content":{"terminal":"t1"}},{"id":"split","type":"column","size":{"weight":3},"children":[{"id":"p2","type":"block","content":{"terminal":"t2"}},{"id":"p3","type":"block","content":{"terminal":"t3"}}]}]}"#)
        guard case let .split(_, axis, children, fractions) = try HerdrWorkspaceProjection.layout(tree) else { return XCTFail() }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(fractions, [0.25, 0.75])
        guard case let .split(_, nestedAxis, _, nestedFractions) = children[1] else { return XCTFail() }
        XCTAssertEqual(nestedAxis, .vertical)
        XCTAssertEqual(nestedFractions, [0.5, 0.5])
        for invalid in [#"{"id":"s","type":"stack","children":[]}"#,
                        #"{"id":"s","type":"column","children":[]}"#,
                        #"{"id":"p","type":"block","content":{"mod":"agents"}}"#,
                        #"{"id":"p","type":"block","hidden":true,"content":{"terminal":"t1"}}"#,
                        #"{"id":"p","type":"block","floating":[{}],"content":{"terminal":"t1"}}"#,
                        #"{"id":"p","type":"block","content":{"terminal":"box/t1"}}"#,
                        #"{"id":"r","type":"row","children":[{"id":"p","type":"block","size":{"px":200},"content":{"terminal":"t1"}}]}"#,
                        #"{"id":"r","type":"row","children":[{"id":"p","type":"block","size":{"weight":0},"content":{"terminal":"t1"}}]}"#,
                        #"{"id":"r","type":"row","children":[{"id":"p1","type":"block","size":{"weight":1e308},"content":{"terminal":"t1"}},{"id":"p2","type":"block","size":{"weight":1e-308},"content":{"terminal":"t2"}}]}"#,
                        #"{"id":"r","type":"row","children":[{"id":"p","type":"block","content":{"terminal":"t1"}},{"id":"p","type":"block","content":{"terminal":"t2"}}]}"#] {
            XCTAssertThrowsError(try HerdrWorkspaceProjection.layout(json(invalid)), invalid)
        }
    }

    func testExportMatchesUpstreamParserFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/herdr-workspace-v0.1.14.json")
        let expected = try JSONDecoder().decode(HerdrJSONValue.self, from: Data(contentsOf: fixture))
        let seed = try HerdrWorkspaceProjection.export(Self.workspace(coreID: "core"), coreID: "core")
        let document = try HerdrWorkspaceDocument().applying(.insertSpace(seed.space))
        XCTAssertEqual(document.value, expected)
    }

    /// The `herdr.space` / `herdr.tab` pair each pane of the fixture is published with.
    static func labels(_ workspace: SavedWorkspace.LocalWorkspace) -> [[String: String]] {
        workspace.tabs[0].panes.map { _ in
            ["herdr.space": HerdrWorkspaceProjection.spaceID(workspace.id),
             "herdr.tab": HerdrWorkspaceProjection.tabID(workspace.tabs[0].id)]
        }
    }

    static func workspace(coreID: String, addresses: [String] = ["t1", "t2"]) -> SavedWorkspace.LocalWorkspace {
        func id(_ number: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))! }
        let panes = addresses.enumerated().map { index, address in
            SavedWorkspace.Pane(id: id(index + 3), kind: .herdrTerminal, title: "Terminal", cwd: "/tmp", herdr: .init(coreID: coreID, address: address))
        }
        let tab = SavedWorkspace.Tab(id: id(2), layout: .split(axis: .horizontal, children: panes.map { .panel($0.id) }, fractions: [0.25, 0.75]),
                                    panes: panes, focusedPaneID: panes[0].id, autoResize: [:], detachedPaneIDs: [], activeDetachedPaneID: nil,
                                    floating: nil, floatingSizes: [:])
        return .init(id: id(1), name: "Shared", kind: .herdr, selectedTabID: tab.id, tabs: [tab])
    }
}

@MainActor
final class HerdrWorkspaceDocumentIntegrationTests: XCTestCase {
    func testIndependentClientsShareDocumentsWithCASInvalidationAndNoProgramReplacement() async throws {
        let executable: URL
        do { executable = try HerdrCoreTransport.executable() }
        catch { throw XCTSkip("hc is required for the shared document integration test") }
        let root = URL(fileURLWithPath: "/tmp/santty-doc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HC_") }
        environment["HC_SESSION"] = "probe"
        environment["HC_SOCKET"] = root.appendingPathComponent("core.sock").path
        environment["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_RUNTIME_DIR"] = root.path
        var connections: [HerdrCoreTransport] = []
        defer {
            connections.forEach { $0.close() }
            let stop = Process(); stop.executableURL = executable; stop.arguments = ["server", "stop"]; stop.environment = environment
            stop.standardOutput = FileHandle.nullDevice; stop.standardError = FileHandle.nullDevice
            if (try? stop.run()) != nil { stop.waitUntilExit(); XCTAssertEqual(stop.terminationStatus, 0) }
            try? FileManager.default.removeItem(at: root)
        }
        let first = HerdrCoreClient(executable: executable, environment: environment)
        let second = HerdrCoreClient(executable: executable, environment: environment)
        let a = try await first.connection(), b = try await second.connection()
        connections += [a, b]
        XCTAssertFalse(a === b)
        XCTAssertEqual(a.hello.core.id, b.hello.core.id)
        let coreID = a.hello.core.id
        let desktop = HerdrWorkspaceDocumentStore(client: first, coreID: coreID)
        let phonePeer = HerdrWorkspaceDocumentStore(client: second, coreID: coreID)
        let empty = try await desktop.read()
        XCTAssertFalse(empty.exists)
        XCTAssertEqual(empty.version, 0)
        let fixture = HerdrWorkspaceDocumentTests.workspace(coreID: coreID)
        let plan = try HerdrWorkspaceProjection.export(fixture, coreID: coreID)
        var terminals: [HerdrCoreTerminal] = []
        for labels in HerdrWorkspaceDocumentTests.labels(fixture) {
            // Fixture-only publishing: production code still returns labels as intent, never applies them.
            let terminal: HerdrCoreTerminal = try await HerdrCoreClient.request(a, "terminal.run",
                ["argv": ["/bin/cat"], "no_parent": true, "keep": true, "cwd": root.path, "labels": labels])
            terminals.append(terminal)
        }
        let workspace = HerdrWorkspaceDocumentTests.workspace(coreID: coreID, addresses: terminals.map(\.address))
        let seed = try HerdrWorkspaceProjection.export(workspace, coreID: coreID)
        let before = second.workspaceDocumentsGeneration
        let published = try await desktop.apply(.insertSpace(seed.space), to: empty)
        for _ in 0..<100 {
            if second.workspaceDocumentsGeneration > before { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(second.workspaceDocumentsGeneration, before, "A doc event has no terminal address but must invalidate the document")
        let observed = try await phonePeer.read()
        XCTAssertEqual(observed.version, published.version)
        XCTAssertEqual(observed.document, published.document)
        let space = try XCTUnwrap(observed.document.spaces().first)
        let tab = try XCTUnwrap(space.tabs.first)
        _ = try HerdrWorkspaceProjection.layout(tab.root)
        let renamed = try await phonePeer.apply(.renameTab(spaceID: space.id, id: tab.id, expectedName: "", name: "Phone edit"), to: observed)
        XCTAssertGreaterThan(renamed.version, published.version)
        do {
            _ = try await desktop.apply(.renameSpace(id: space.id, expectedName: "Shared", name: "Stale"), to: published)
            XCTFail("A stale whole-document write must not overwrite the other client's edit")
        } catch { XCTAssertEqual((error as? HerdrCoreError)?.kind, "conflict") }
        let fresh = try await desktop.read()
        XCTAssertEqual(try fresh.document.spaces().first?.tabs.first?.name, "Phone edit")
        XCTAssertEqual(try fresh.document.spaces().first?.name, "Shared")
        let wrong = HerdrWorkspaceDocumentStore(client: first, coreID: "other-core")
        do { _ = try await wrong.read(); XCTFail("Different core accepted") }
        catch { XCTAssertEqual((error as? HerdrCoreError)?.kind, "identity_changed") }
        let wrongRemote = HerdrWorkspaceDocumentStore(client: first, coreID: "unknown-remote", remote: true)
        do { _ = try await wrongRemote.read(); XCTFail("Missing remote accepted") }
        catch { XCTAssertEqual((error as? HerdrCoreError)?.kind, "identity_changed") }
        try await first.reconnect()
        connections.append(try await first.connection())
        do {
            _ = try await desktop.apply(.renameSpace(id: space.id, expectedName: "Shared", name: "Old connection"), to: fresh)
            XCTFail("A snapshot must be re-read after reconnect, even on the same core")
        } catch { XCTAssertEqual((error as? HerdrCoreError)?.kind, "stale_workspace") }
        b.close()
        let afterQuit = try await desktop.read()
        XCTAssertEqual(afterQuit.document, fresh.document)
        for terminal in terminals {
            let binding = HerdrTerminalBinding(coreID: coreID, address: terminal.address)
            let record = try await first.terminal(binding)
            XCTAssertEqual(record.pid, terminal.pid)
            XCTAssertEqual(record.state, "live")
            struct Labeled: Decodable, Sendable { let labels: [String: String] }
            let connection = try await first.connection()
            let labeled: Labeled = try await HerdrCoreClient.request(connection, "terminal.get", ["terminal": binding.address])
            XCTAssertEqual(labeled.labels["herdr.space"], space.id)
            XCTAssertEqual(labeled.labels["herdr.tab"], tab.id)
            try await first.kill(binding)
        }
        // A deleted document retains its revision. Recreating it must not assume version zero.
        struct Written: Decodable, Sendable { let version: UInt64 }
        let connection = try await first.connection()
        let deleted: Written = try await HerdrCoreClient.request(connection, "doc.set",
            ["name": HerdrWorkspaceDocument.name, "version": afterQuit.version, "value": NSNull()])
        let tombstone = try await desktop.read()
        XCTAssertFalse(tombstone.exists)
        XCTAssertEqual(tombstone.version, deleted.version)
        let recreated = try await desktop.apply(.insertSpace(seed.space), to: tombstone)
        XCTAssertTrue(recreated.exists)
        XCTAssertGreaterThan(recreated.version, deleted.version)
    }

    func testRemoteDocumentUsesPermanentCoreIDAndStaysOnOwningCoreAfterAliasRename() async throws {
        let executable: URL
        do { executable = try HerdrCoreTransport.executable() }
        catch { throw XCTSkip("hc is required for the remote document integration test") }
        let root = URL(fileURLWithPath: "/tmp/santty-rdoc-\(UUID().uuidString.prefix(8))")
        func environment(_ name: String) throws -> [String: String] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HC_") }
            env["HC_SESSION"] = "probe"; env["HC_SOCKET"] = directory.appendingPathComponent("core.sock").path
            env["XDG_STATE_HOME"] = directory.appendingPathComponent("state").path
            env["XDG_CONFIG_HOME"] = directory.appendingPathComponent("config").path
            env["XDG_RUNTIME_DIR"] = directory.path
            env["PATH"] = executable.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            return env
        }
        let local = try environment("local"), remote = try environment("remote")
        var connections: [HerdrCoreTransport] = []
        defer {
            connections.forEach { $0.close() }
            for env in [local, remote] {
                let stop = Process(); stop.executableURL = executable; stop.arguments = ["server", "stop"]; stop.environment = env
                stop.standardOutput = FileHandle.nullDevice; stop.standardError = FileHandle.nullDevice
                if (try? stop.run()) != nil { stop.waitUntilExit(); XCTAssertEqual(stop.terminationStatus, 0) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        let desktop = HerdrCoreClient(executable: executable, environment: local)
        let remotePeer = HerdrCoreClient(executable: executable, environment: remote)
        let a = try await desktop.connection(), b = try await remotePeer.connection()
        connections += [a, b]
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let via = root.appendingPathComponent("via.sh")
        let keys = ["HC_SESSION", "HC_SOCKET", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "PATH"]
        let script = "#!/bin/sh\nexec /usr/bin/env " + keys.map { quote($0 + "=" + remote[$0]!) }.joined(separator: " ") + " /bin/sh -c \"$1\"\n"
        try script.write(to: via, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: via.path)
        let machine: HerdrRemote = try await HerdrCoreClient.request(a, "machine.add", ["name": "box", "via": quote(via.path)])
        XCTAssertEqual(machine.id, b.hello.core.id)
        XCTAssertNotEqual(machine.id, a.hello.core.id)
        func waitForRemote() async throws {
            for _ in 0..<250 {
                if try await desktop.configuredMachines().first(where: { $0.id == machine.id })?.state == "connected" { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw HerdrCoreError("Private remote did not connect", kind: "test_timeout")
        }
        try await waitForRemote()
        let throughProxy = HerdrWorkspaceDocumentStore(client: desktop, coreID: machine.id, remote: true)
        let direct = HerdrWorkspaceDocumentStore(client: remotePeer, coreID: machine.id)
        let localStore = HerdrWorkspaceDocumentStore(client: desktop, coreID: a.hello.core.id)
        let before = try await throughProxy.read()
        let fixture = HerdrWorkspaceDocumentTests.workspace(coreID: machine.id)
        let plan = try HerdrWorkspaceProjection.export(fixture, coreID: machine.id)
        var terminals: [HerdrCoreTerminal] = []
        for labels in HerdrWorkspaceDocumentTests.labels(fixture) {
            let terminal: HerdrCoreTerminal = try await HerdrCoreClient.request(b, "terminal.run",
                ["argv": ["/bin/cat"], "no_parent": true, "cwd": root.path, "labels": labels])
            terminals.append(terminal)
        }
        var workspace = HerdrWorkspaceDocumentTests.workspace(coreID: machine.id, addresses: terminals.map(\.address))
        workspace.herdrRemote = machine
        for index in workspace.tabs[0].panes.indices { workspace.tabs[0].panes[index].herdr?.remote = true }
        let seed = try HerdrWorkspaceProjection.export(workspace, coreID: machine.id)
        let published = try await throughProxy.apply(.insertSpace(seed.space), to: before)
        let fromOwner = try await direct.read()
        XCTAssertEqual(fromOwner.document, published.document)
        let untouchedLocal = try await localStore.read()
        XCTAssertFalse(untouchedLocal.exists, "A remote layout must never be written to the proxy's local document")
        // Scope checks include local-vs-remote routing even when the destination core ID is equal.
        do {
            _ = try await direct.apply(.renameSpace(id: HerdrWorkspaceProjection.spaceID(workspace.id), expectedName: "Shared", name: "No"), to: published)
            XCTFail("A snapshot from another connection/routing scope was accepted")
        } catch { XCTAssertEqual((error as? HerdrCoreError)?.kind, "stale_workspace") }
        struct Renamed: Decodable, Sendable { let name: String }
        let _: Renamed = try await HerdrCoreClient.request(a, "machine.rename", ["machine": "box", "new_name": "renamed-box"])
        try await waitForRemote()
        let afterAliasRename = try await throughProxy.read()
        XCTAssertEqual(afterAliasRename.document, published.document)
        XCTAssertEqual(afterAliasRename.coreID, machine.id)
        let spaceID = try XCTUnwrap(afterAliasRename.document.spaces().first?.id)
        let updated = try await throughProxy.apply(.renameSpace(id: spaceID, expectedName: "Shared", name: "Remote edit"), to: afterAliasRename)
        let final = try await direct.read()
        XCTAssertEqual(final.document, updated.document)
        XCTAssertEqual(try final.document.spaces().first?.name, "Remote edit")
        for terminal in terminals {
            let record = try await desktop.terminal(.init(coreID: machine.id, address: terminal.address, remote: true))
            XCTAssertEqual(record.pid, terminal.pid)
            XCTAssertEqual(record.state, "live")
            try await remotePeer.kill(.init(coreID: machine.id, address: terminal.address))
        }
    }
}
