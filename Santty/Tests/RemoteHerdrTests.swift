import AppKit
import Darwin
import GhosttyTerminal
import XCTest
@testable import Santty

@MainActor
final class RemoteHerdrTests: XCTestCase {
    private func endpoint(_ digit: Character = "a", label: String = "Workbox") -> HerdrEndpoint {
        .init(binary: URL(fileURLWithPath: "/usr/bin/true"), session: "agents", socketPath: "/tmp/local.sock",
              machine: .init(id: String(repeating: String(digit), count: 32), label: label, target: "you@workbox", session: "agents", enabled: true))
    }

    func testWorkspaceIdentityScopesDuplicateIDsAndSurvivesMachineRename() throws {
        let first = WorkspaceReference(source: .herdr(endpoint: endpoint(), workspaceID: "w1"))
        let second = WorkspaceReference(source: .herdr(endpoint: endpoint("b"), workspaceID: "w1"))
        let renamed = WorkspaceReference(source: .herdr(endpoint: endpoint(label: "Renamed"), workspaceID: "w1"))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first, renamed); XCTAssertEqual(first.id, renamed.id)
        XCTAssertEqual(first.kind, .remoteHerdr)
        XCTAssertEqual(WorkspaceReference(source: .local(UUID())).kind, .local)
        let local = HerdrEndpoint(binary: URL(fileURLWithPath: "/usr/bin/true"), session: "default", socketPath: "/tmp/local.sock")
        XCTAssertEqual(WorkspaceReference(source: .herdr(endpoint: local, workspaceID: "w1")).kind, .herdr)
        XCTAssertNotEqual(HerdrServiceIdentity.remote(endpoint: endpoint(), bootID: "old"), .remote(endpoint: endpoint(), bootID: "new"))
        XCTAssertNotEqual(HerdrServiceIdentity.remote(endpoint: endpoint(), bootID: "same"), .remote(endpoint: endpoint("b"), bootID: "same"))
    }

    func testMachineCatalogRejectsDuplicatesAndSSHOptionInjection() throws {
        let machine = try XCTUnwrap(endpoint().machine)
        XCTAssertEqual(try HerdrMachineProfile.decodeList(JSONEncoder().encode([machine])), [machine])
        XCTAssertThrowsError(try HerdrMachineProfile.decodeList(JSONEncoder().encode([machine, machine])))
        for target in ["-oProxyCommand=bad", "host\ncommand", ""] {
            let invalid = HerdrMachineProfile(id: machine.id, label: machine.label, target: target, session: machine.session, enabled: true)
            XCTAssertThrowsError(try invalid.validate())
            XCTAssertThrowsError(try HerdrSSHBridge.arguments(target: target, configuration: nil))
        }
        XCTAssertThrowsError(try HerdrMachineProfile(id: "not-an-id", label: "x", target: "host", session: "default", enabled: true).validate())
    }

    func testNativeSSHCommandsAndConfigurationPreserveBoundaries() throws {
        for path in ["1:\\herdr.exe", "C:herdr.exe", "relative.exe"] {
            XCTAssertThrowsError(try HerdrSSHBridge.Executable(os: "windows", executable: path).validate())
        }
        let binary = HerdrSSHBridge.Executable(os: "linux", executable: "/home/you/a'b/herdr")
        let command = try HerdrSSHBridge.command(executable: binary, session: "agents", lane: .client)
        XCTAssertTrue(command.contains("remote-client-bridge")); XCTAssertFalse(command.contains("--remote"))
        let output = try HerdrProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '%s' " + HerdrSSHBridge.quote("a'b\n$HOME; $(exit 7)")])
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "a'b\n$HOME; $(exit 7)")
        let args = try HerdrSSHBridge.arguments(target: "workbox", configuration: URL(fileURLWithPath: "/tmp/config"))
        XCTAssertTrue(args.contains("BatchMode=yes")); XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("ControlPersist=600")); XCTAssertTrue(args.contains("-C")); XCTAssertTrue(args.contains("-T"))
        XCTAssertFalse(HerdrSSHBridge.managesSSH("[remote]\nmanage_ssh_config = false # custom auth\n"))
        XCTAssertTrue(HerdrSSHBridge.managesSSH("[other]\nmanage_ssh_config = false\n[remote]\nmanage_ssh_config = true"))
        let windows = try HerdrSSHBridge.command(executable: .init(os: "windows", executable: "C:\\Program Files\\herdr.exe"), session: "agents", lane: .client)
        let encoded = try XCTUnwrap(windows.components(separatedBy: " ").last)
        let script = try XCTUnwrap(String(data: XCTUnwrap(Data(base64Encoded: encoded)), encoding: .utf16LittleEndian))
        XCTAssertTrue(script.contains("Start-Process")); XCTAssertTrue(script.contains("-NoNewWindow"))
        XCTAssertTrue(script.contains("remote-client-bridge"))
    }

    func testBridgeMarkerDoesNotConsumeBinaryFrameAndRejectsTruncation() throws {
        var pair = [CInt](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        let bytes = Data(("login banner\r\n" + HerdrSSHBridge.marker + "\r\n").utf8) + Data([4, 0, 0, 0, 255])
        _ = bytes.withUnsafeBytes { Darwin.write(pair[1], $0.baseAddress, $0.count) }
        try HerdrSSHBridge.readMarker(fd: pair[0], timeout: 0.5)
        var frame = [UInt8](repeating: 0, count: 5)
        XCTAssertEqual(Darwin.read(pair[0], &frame, frame.count), 5)
        XCTAssertEqual(frame, [4, 0, 0, 0, 255])
        _ = shutdown(pair[1], SHUT_WR)
        XCTAssertThrowsError(try HerdrSSHBridge.readMarker(fd: pair[0], timeout: 0.5))
    }

    func testProcessOutputIsBoundedAndTimesOutWithoutWaitingForEOF() throws {
        XCTAssertThrowsError(try HerdrProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 123456789"], limit: 4))
        XCTAssertThrowsError(try HerdrProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec 1>&-; exec 2>&-; sleep 2"], timeout: 0.05))
    }

    func testUnifiedPickerShowsAllThreeTypesWithDistinctTargets() {
        let remote = WorkspaceEntry(reference: .init(source: .herdr(endpoint: endpoint(), workspaceID: "w1")), name: "Backend")
        var localEndpoint = endpoint(); localEndpoint.machine = nil
        let herdr = WorkspaceEntry(reference: .init(source: .herdr(endpoint: localEndpoint, workspaceID: "w1")), name: "Backend")
        let local = WorkspaceEntry(reference: .init(source: .local(UUID())), name: "Frontend")
        let toolbar = WorkspaceToolbarView()
        toolbar.updateWorkspaceEntries([local, herdr, remote], selectedID: remote.id)
        XCTAssertEqual(toolbar.workspaceSwitcher.itemArray.map(\.title), ["Frontend", "Backend", "Backend · Workbox"])
        XCTAssertEqual(toolbar.workspaceSwitcher.itemArray.map { $0.toolTip }, ["Local Workspace", "Herdr Workspace", "Remote Herdr Workspace"])
        XCTAssertEqual(toolbar.workspaceSwitcher.selectedItem?.representedObject as? String, remote.id)
        var offline = remote; offline.isAvailable = false; offline.status = "Reconnecting"
        toolbar.updateWorkspaceEntries([local, herdr, offline], selectedID: remote.id)
        XCTAssertFalse(toolbar.workspaceSwitcher.itemArray[2].isEnabled)
    }

    func testUnifiedWorkspaceDirectoryRoundTripsAndRejectsUnknownSelection() throws {
        let remote = WorkspaceEntry(reference: .init(source: .herdr(endpoint: endpoint(), workspaceID: "w1")), name: "Backend")
        var saved = SavedWorkspace(tabs: [], workspaces: [remote], selectedWorkspace: remote.reference)
        try saved.validate()
        XCTAssertEqual(try JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(saved)), saved)
        saved.selectedWorkspace = .init(source: .herdr(endpoint: endpoint("b"), workspaceID: "w1"))
        XCTAssertThrowsError(try saved.validate())
    }

    func testCatalogRenamesWithoutReconnectAndRetiresChangedOrDisabledProfiles() {
        var local = endpoint(); local.machine = nil
        let catalog = HerdrWorkspaceCatalog()
        defer { catalog.stop() }
        var profile = endpoint().machine!
        catalog.reconcile([profile], local: local)
        let monitor = catalog.states[endpoint().id]?.monitor
        profile = .init(id: profile.id, label: "Renamed", target: profile.target, session: profile.session, enabled: true)
        catalog.reconcile([profile], local: local)
        XCTAssertTrue(catalog.states[endpoint().id]?.monitor === monitor)
        XCTAssertEqual(catalog.states[endpoint().id]?.endpoint.machine?.label, "Renamed")
        profile = .init(id: profile.id, label: profile.label, target: "changed-host", session: profile.session, enabled: true)
        catalog.reconcile([profile], local: local)
        XCTAssertFalse(catalog.states[endpoint().id]?.monitor === monitor)
        profile = .init(id: profile.id, label: profile.label, target: profile.target, session: profile.session, enabled: false)
        catalog.reconcile([profile], local: local)
        XCTAssertNil(catalog.states[endpoint().id])
        XCTAssertEqual(catalog.states.count, 1)
    }

    func testLegacyWholeWindowSchemasDecodeWithLocalCompanions() throws {
        var localEndpoint = endpoint(); localEndpoint.machine = nil
        let identity = HerdrServiceIdentity(pid: 1, startedSeconds: 2, startedMicroseconds: 3)
        let binding = try HerdrPaneBinding(endpoint: localEndpoint,
            pane: .init(pane_id: "p1", terminal_id: "runtime", workspace_id: "w1", tab_id: "t1", serviceIdentity: identity), includeRuntime: true)
        let terminal = SavedWorkspace.Pane(id: UUID(), kind: .persistentTerminal, title: "Shell", binding: binding)
        let note = SavedWorkspace.Pane(id: UUID(), kind: .notes, title: "Notes")
        let local = SavedWorkspace.Pane(id: UUID(), kind: .localTerminal, title: "Local")
        let backend = LayoutNode.panel(terminal.id), companion = LayoutNode.panel(note.id)
        let tab = SavedWorkspace.Tab(id: UUID(), layout: .split(axis: .horizontal, children: [backend, companion], fractions: [0.7, 1 - 0.7]),
            panes: [terminal, note], focusedPaneID: note.id, backendBinding: binding,
            autoResize: [:], detachedPaneIDs: [], floatingSizes: [:], herdrBackendLayout: backend, herdrLocalLayout: companion, herdrLocalFraction: 0.7)
        let parked = SavedWorkspace.Tab(id: UUID(), layout: .panel(local.id), panes: [local], autoResize: [:], detachedPaneIDs: [], floatingSizes: [:])
        for version in [1, 2, 3] {
            var saved = SavedWorkspace(selectedTabID: tab.id, tabs: [tab], herdrWindowBinding: binding,
                herdrWindowMode: .control, parkedTabs: [parked], parkedSelectedTabID: parked.id)
            saved.version = version
            if version == 3 { saved.herdrWindowTransport = .clientShell }
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
            let decoded = try JSONDecoder().decode(SavedWorkspace.self, from: JSONSerialization.data(withJSONObject: json))
            try decoded.validate()
            XCTAssertEqual(decoded.tabs[0].panes.map(\.id), [terminal.id, note.id])
            XCTAssertEqual(decoded.parkedTabs?.first?.panes.first?.id, local.id)
            XCTAssertEqual(decoded.restoredHerdrWindowTransport, .clientShell)
        }
    }

    func testMetadataCatalogRecoversAfterServerRestart() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = repository.appendingPathComponent("Scripts/herdr-clientshell-fixture.py")
        let path = "/tmp/herdr-catalog-\(UUID().uuidString).sock"
        func launch() throws -> Process {
            for file in [path, String(path.dropLast(5)) + "-client.sock"] { try? FileManager.default.removeItem(atPath: file) }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, path, "window"]; try process.run(); return process
        }
        var service = try launch()
        let catalog = HerdrWorkspaceCatalog()
        defer {
            catalog.stop()
            if service.isRunning { service.terminate(); service.waitUntilExit() }
            for file in [path, String(path.dropLast(5)) + "-client.sock", path + ".trace", path + ".trace.tmp"] { try? FileManager.default.removeItem(atPath: file) }
            AgentSessionStore.shared.reset()
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: String(path.dropLast(5)) + "-client.sock") { try await Task.sleep(for: .milliseconds(10)) }
        let local = HerdrEndpoint(binary: script, session: "fixture", socketPath: path)
        catalog.reconcile([], local: local)
        for _ in 0..<500 where catalog.states[local.id]?.identity == nil { try await Task.sleep(for: .milliseconds(10)) }
        let first = try XCTUnwrap(catalog.states[local.id]?.identity)
        XCTAssertFalse(catalog.workspaces.isEmpty)
        service.terminate(); service.waitUntilExit()
        for _ in 0..<500 where catalog.states[local.id]?.identity != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(catalog.states[local.id]?.identity)
        XCTAssertTrue(catalog.workspaces.allSatisfy { !$0.isAvailable })
        service = try launch()
        for _ in 0..<1000 where catalog.states[local.id]?.identity == nil { try await Task.sleep(for: .milliseconds(10)) }
        let recovered = try XCTUnwrap(catalog.states[local.id]?.identity, catalog.states[local.id]?.monitor.session?.failure?.localizedDescription ?? "No metadata after restart")
        XCTAssertNotEqual(first, recovered)
        XCTAssertTrue(catalog.workspaces.allSatisfy(\.isAvailable))
    }

    func testSelectingLocalCancelsPendingRemoteSelectionImmediately() async throws {
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        defer { workspace.releaseHerdrConnections() }
        var errors: [String] = []; workspace.herdrErrorHandler = { errors.append($0) }
        let local = workspace.debugSelectedWorkspace, tabs = workspace.debugTabIDs
        let remote = HerdrEndpoint(binary: URL(fileURLWithPath: "/usr/bin/true"), session: "agents", socketPath: "/tmp/unused.sock",
            machine: .init(id: String(repeating: "a", count: 32), label: "Unavailable", target: "ssh://localhost:1", session: "agents", enabled: true))
        workspace.selectWorkspace(.init(source: .herdr(endpoint: remote, workspaceID: "w1")))
        XCTAssertTrue(workspace.debugHerdrOperationPending)
        await Task.yield()
        workspace.selectWorkspace(local)
        XCTAssertEqual(workspace.debugSelectedWorkspace, local)
        XCTAssertEqual(workspace.debugTabIDs, tabs)
        XCTAssertFalse(workspace.debugHerdrOperationPending)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(workspace.debugSelectedWorkspace, local)
    }

    func testNativeSSHBridgeCarriesMetadataSurfaceImagesInputAndAPIQueries() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Scripts/herdr-clientshell-fixture.py")
        let ssh = root.appendingPathComponent("Scripts/herdr-ssh-fixture.py")
        let path = "/tmp/herdr-remote-\(UUID().uuidString).sock"
        let service = Process(); service.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        service.arguments = [script.path, path, "window"]
        try service.run()
        defer {
            if service.isRunning { service.terminate(); service.waitUntilExit() }
            for file in [path, String(path.dropLast(5)) + "-client.sock", path + ".trace", path + ".trace.tmp"] { try? FileManager.default.removeItem(atPath: file) }
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: String(path.dropLast(5)) + "-client.sock") { try await Task.sleep(for: .milliseconds(10)) }
        let endpoint = HerdrEndpoint(binary: script, session: "agents", socketPath: path,
            machine: .init(id: String(repeating: "a", count: 32), label: "Fixture", target: path, session: "agents", enabled: true))
        let resolved = HerdrSSHBridge.Executable(os: "linux", executable: "/fixture/herdr")
        let session = HerdrClientShellSession(endpoint: endpoint, makeTransport: {
            let connection = try HerdrSSHBridge.connect(endpoint: $0, lane: .client, sshExecutable: ssh, resolved: resolved)
            return try HerdrClientShellTransport(socketPath: $0.clientSocketPath, endpoint: $0, connection: connection)
        })
        defer { session.disconnect() }
        session.onProjection = { [weak session] _, surface, _ in _ = session?.acknowledgePresentation(surface) }
        try await session.start(size: .init(cols: 80, rows: 24), cellWidth: 8, cellHeight: 16, focused: false)
        for _ in 0..<500 where !session.isPresentationReady && session.failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(session.failure)
        XCTAssertTrue(session.isPresentationReady)
        XCTAssertEqual(session.serviceIdentity, .remote(endpoint: endpoint, bootID: "boot"))
        XCTAssertFalse(session.projection.assets.isEmpty)
        let firstRevision = try XCTUnwrap(session.projection.snapshot?.revision)
        let bytes = try await session.request("pane.rename", params: .init(pane_id: "w5:pA", label: "SSH native command"))
        XCTAssertNotNil(try JSONDecoder().decode(HerdrAPIEnvelope.self, from: bytes).result)
        for _ in 0..<200 where session.projection.snapshot?.revision == firstRevision { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(try XCTUnwrap(session.projection.snapshot?.revision), firstRevision)
        let connection = try await Task.detached { try HerdrSSHBridge.connect(endpoint: endpoint, lane: .api, sshExecutable: ssh, resolved: resolved) }.value
        defer { close(connection.fd); connection.bridge.stop() }
        let result = try await Task.detached {
            let request = HerdrConnection.Request(id: "remote-query", method: "session.snapshot")
            try CLITransport.write(request, to: connection.fd)
            let data = try CLITransport.readLine(connection.fd, limit: HerdrLineDecoder.maximumBytes)
            return try JSONDecoder().decode(HerdrAPIEnvelope.self, from: data).response(to: request.id)
        }.value
        XCTAssertEqual(result.snapshot?.protocolVersion, 22)
        XCTAssertTrue(result.snapshot?.panes.contains { $0.pane_id == "w5:pA" } == true)
        let retired = HerdrWorkspaceClient(endpoint: endpoint)
        try retired.routeCommands(to: session)
        try session.deactivate()
        XCTAssertFalse(session.isPresentationReady)
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(session.failure)
        let waiting = Task { try await retired.request("workspace.rename", params: .init(workspace_id: "w5", label: "Retired write")) }
        try await Task.sleep(for: .milliseconds(50))
        retired.retireCommands()
        try session.activate(size: .init(cols: 80, rows: 24), cellWidth: 8, cellHeight: 16)
        for _ in 0..<500 where !session.isPresentationReady && session.failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.isPresentationReady)
        XCTAssertNil(session.failure)
        do { _ = try await waiting.value; XCTFail("A retired command route wrote after reactivation") } catch { }
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".trace"))) as? [[String: Any]])
        XCTAssertEqual(trace.filter { $0["connection"] != nil }.count, 1, "Activation changes reuse the native endpoint connection")
        let interests = trace.filter { $0["method"] as? String == "client_shell.surface.set" }
        XCTAssertEqual(interests.compactMap { ($0["params"] as? [String: Any])?["active"] as? Bool }, [true, false, true])
        XCTAssertFalse(trace.contains { $0["method"] as? String == "workspace.rename" })
        XCTAssertTrue(service.isRunning, "Detaching must leave server-owned processes running")
    }

    func testAuthorizedSSHHostRendersInputAndPreservesLocalWorkspace() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let target = environment["SANTTY_HERDR_SSH_TARGET"],
              let remoteBinary = environment["SANTTY_HERDR_REMOTE_BINARY"] else {
            throw XCTSkip("Set TEST_RUNNER_SANTTY_HERDR_SSH_TARGET and TEST_RUNNER_SANTTY_HERDR_REMOTE_BINARY for an authorized host")
        }
        try HerdrSSHBridge.Executable(os: "linux", executable: remoteBinary).validate()
        let sessionName = "santty-verify-" + UUID().uuidString.prefix(8).lowercased()
        let native = URL(fileURLWithPath: HerdrExecutable.suggestedPath())
        let remote = HerdrEndpoint(binary: native, session: sessionName, socketPath: "/tmp/unused-remote.sock",
            machine: .init(id: String(repeating: "f", count: 32), label: target, target: target, session: sessionName, enabled: true))
        try remote.validate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(sessionName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = environment["HERDR_CONFIG_PATH"]
        let configuration = root.appendingPathComponent("client.toml")
        try Data("[remote]\nmanage_ssh_config = true\n".utf8).write(to: configuration)
        setenv("HERDR_CONFIG_PATH", configuration.path, 1)
        defer { if let previous { setenv("HERDR_CONFIG_PATH", previous, 1) } else { unsetenv("HERDR_CONFIG_PATH") } }
        let sshConfig = try HerdrSSHBridge.configuration(target: target)
        defer { if let sshConfig { try? FileManager.default.removeItem(at: sshConfig.deletingLastPathComponent()) } }
        let sshArguments = try HerdrSSHBridge.arguments(target: target, configuration: sshConfig)
        defer {
            let controlArguments = Array(sshArguments.dropLast()) + ["-O", "exit", target]
            _ = try? HerdrProcess.run(URL(fileURLWithPath: "/usr/bin/ssh"), arguments: controlArguments, timeout: 10)
        }
        defer {
            for action in ["stop", "delete"] {
                let command = [remoteBinary, "session", action, sessionName, "--json"].map(HerdrSSHBridge.quote).joined(separator: " ")
                do {
                    let result = try HerdrProcess.run(URL(fileURLWithPath: "/usr/bin/ssh"), arguments: sshArguments + [command])
                    XCTAssertEqual(result.status, 0, "Temporary session \(action): \(String(decoding: result.stderr, as: UTF8.self))")
                } catch { XCTFail("Temporary session cleanup failed: \(error)") }
            }
        }
        print("AUTHORIZED_SSH_TEST target=\(target) session=\(sessionName)")
        let observer = HerdrClientShellSession(endpoint: remote)
        defer { observer.disconnect() }
        try await observer.start(size: .init(cols: 1, rows: 1), cellWidth: 0, cellHeight: 0, focused: false, activateWhenMetadataReady: false)
        for _ in 0..<4000 where observer.projection.snapshot == nil && observer.failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        if let failure = observer.failure { throw failure }
        let workspaceID = try XCTUnwrap(observer.projection.snapshot?.workspaces.first?.workspace_id)
        let identity = try XCTUnwrap(observer.serviceIdentity)
        XCTAssertEqual(identity.endpointID, remote.id)
        XCTAssertFalse(observer.isPresentationReady)
        observer.disconnect()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let localPath = root.appendingPathComponent("local.sock").path
        let localService = Process(); localService.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        localService.arguments = [repository.appendingPathComponent("Scripts/herdr-clientshell-fixture.py").path, localPath, "window"]
        try localService.run()
        defer { if localService.isRunning { localService.terminate(); localService.waitUntilExit() } }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: root.appendingPathComponent("local-client.sock").path) { try await Task.sleep(for: .milliseconds(10)) }
        let catalogBinary = root.appendingPathComponent("catalog-herdr")
        let catalogJSON = String(decoding: try JSONEncoder().encode([try XCTUnwrap(remote.machine)]), as: UTF8.self)
        try Data(("#!/bin/sh\nif [ \"$1\" = machine ] && [ \"$2\" = list ]; then printf '%s\\n' \(HerdrSSHBridge.quote(catalogJSON)); else exec \(HerdrSSHBridge.quote(native.path)) \"$@\"; fi\n").utf8).write(to: catalogBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: catalogBinary.path)
        let localEndpoint = HerdrEndpoint(binary: catalogBinary, session: "fixture", socketPath: localPath)
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        var errors: [String] = []; workspace.herdrErrorHandler = { errors.append($0) }
        let local = workspace.debugSelectedWorkspace, tabs = workspace.debugTabIDs
        try workspace.configureHerdrWorkspace(localEndpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil; AgentSessionStore.shared.reset() }
        workspace.startHerdrAgentMonitoring(localEndpoint)
        for _ in 0..<4000 where !workspace.debugWorkspaceEntries.contains(where: { $0.kind == .remoteHerdr && $0.isAvailable }) { try await Task.sleep(for: .milliseconds(10)) }
        let entry = try XCTUnwrap(workspace.debugWorkspaceEntries.first { $0.kind == .remoteHerdr && $0.isAvailable })
        XCTAssertEqual(entry.reference, WorkspaceReference(source: .herdr(endpoint: HerdrEndpoint(binary: catalogBinary, session: sessionName, socketPath: localPath, machine: remote.machine), workspaceID: workspaceID)))
        let firstSwitchStarted = ProcessInfo.processInfo.systemUptime
        workspace.selectWorkspace(entry.reference); await workspace.waitForWorkspaceSelection()
        print("REMOTE_SWITCH_BENCH first_ms=\((ProcessInfo.processInfo.systemUptime - firstSwitchStarted) * 1000)")
        let pane = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        let display = try XCTUnwrap(pane.hostView.subviews.compactMap { $0 as? TerminalView }.first)
        XCTAssertTrue(pane.canAcceptInput)
        XCTAssertEqual(pane.herdrBinding?.serviceIdentity, identity)
        XCTAssertEqual(workspace.debugSelectedWorkspace.kind, .remoteHerdr)
        let suffix = String(sessionName.dropFirst("santty-verify-".count))
        let marker = "SANTTY_DELLPC_" + suffix
        XCTAssertTrue(pane.sendClientShellInput([.paste("printf 'SANTTY_%s\\n' " + HerdrSSHBridge.quote("DELLPC_" + suffix)), .key(.init(code: 1))]))
        for _ in 0..<1000 where display.readScreenText()?.contains(marker) != true { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(display.readScreenText()?.contains(marker) == true, "Remote command output did not reach the native display")
        let read = try await workspace.handleCLIRequestAsync(.init(command: "read", paneID: pane.id))
        XCTAssertTrue(read.text?.contains(marker) == true)
        workspace.newTab(nil)
        for _ in 0..<1000 where workspace.debugHerdrOperationPending || workspace.debugTabIDs.count != 2 || workspace.debugFocusedHerdrPane?.canAcceptInput != true { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(workspace.debugTabIDs.count, 2)
        workspace.debugPerformCommand(withID: "pane.notes.new")
        let notes = workspace.savedWorkspace().tabs.flatMap(\.panes).filter { $0.kind == .notes }.map(\.id)
        XCTAssertEqual(notes.count, 1)
        let selected = workspace.debugSelectedWorkspace
        workspace.selectWorkspace(local)
        XCTAssertEqual(workspace.debugTabIDs, tabs)
        XCTAssertFalse(pane.canAcceptInput)
        let warmSwitchStarted = ProcessInfo.processInfo.systemUptime
        workspace.selectWorkspace(selected); await workspace.waitForWorkspaceSelection()
        print("REMOTE_SWITCH_BENCH warm_ms=\((ProcessInfo.processInfo.systemUptime - warmSwitchStarted) * 1000)")
        XCTAssertEqual(workspace.debugSelectedWorkspace, selected)
        XCTAssertEqual(workspace.savedWorkspace().tabs.flatMap(\.panes).filter { $0.kind == .notes }.map(\.id), notes)
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
        try workspace.savedWorkspace().validate()
        for sample in 1...3 {
            workspace.selectWorkspace(local)
            let started = ProcessInfo.processInfo.systemUptime
            workspace.selectWorkspace(selected); await workspace.waitForWorkspaceSelection()
            print("REMOTE_SWITCH_BENCH warm_sample=\(sample) tabs=2 ms=\((ProcessInfo.processInfo.systemUptime - started) * 1000)")
            XCTAssertEqual(workspace.debugSelectedWorkspace, selected)
            XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
        }
        print("AUTHORIZED_SSH_TEST passed metadata=true rendered_command=true api_read=true local_roundtrip=true")
    }

    func testRealNativeSSHWorkspacesSwitchAcrossDuplicateIDsAndPreserveLocalContent() async throws {
        let native = HerdrExecutable.suggestedPath()
        guard FileManager.default.isExecutableFile(atPath: native), FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") else {
            throw XCTSkip("Installed Herdr and OpenSSH server are required for the isolated native integration")
        }
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("srn-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let previousConfig = ProcessInfo.processInfo.environment["HERDR_CONFIG_PATH"]
        let localConfig = root.appendingPathComponent("client.toml")
        try Data("[remote]\nmanage_ssh_config = true\n".utf8).write(to: localConfig)
        setenv("HERDR_CONFIG_PATH", localConfig.path, 1)
        defer { if let previousConfig { setenv("HERDR_CONFIG_PATH", previousConfig, 1) } else { unsetenv("HERDR_CONFIG_PATH") } }
        for name in ["host", "key"] {
            let output = try await Task.detached {
                try HerdrProcess.run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"), arguments: ["-q", "-t", "ed25519", "-N", "", "-f", root.appendingPathComponent(name).path])
            }.value
            XCTAssertEqual(output.status, 0)
        }
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw CLIError("Cannot allocate isolated SSH port") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } }
        close(socketFD)
        guard bound == 0, named == 0 else { throw CLIError("Cannot reserve isolated SSH port") }
        let port = UInt16(bigEndian: address.sin_port)
        let target = "ssh://\(NSUserName())@127.0.0.1:\(port)"
        let configRoot = root.appendingPathComponent("remote-config"), stateRoot = root.appendingPathComponent("remote-state")
        try FileManager.default.createDirectory(at: configRoot.appendingPathComponent("herdr"), withIntermediateDirectories: true)
        let remoteConfig = configRoot.appendingPathComponent("herdr/config.toml")
        try Data("onboarding = false\n[terminal]\ndefault_shell = \"/bin/sh\"\n".utf8).write(to: remoteConfig)
        let remoteWrapper = root.appendingPathComponent("herdr")
        let remoteScript = "#!/bin/sh\nexport XDG_CONFIG_HOME=\(HerdrSSHBridge.quote(configRoot.path))\nexport XDG_STATE_HOME=\(HerdrSSHBridge.quote(stateRoot.path))\nexport HERDR_CONFIG_PATH=\(HerdrSSHBridge.quote(remoteConfig.path))\nexec \(HerdrSSHBridge.quote(native)) \"$@\"\n"
        try Data(remoteScript.utf8).write(to: remoteWrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: remoteWrapper.path)
        let forced = root.appendingPathComponent("ssh-command")
        try Data(("#!/bin/sh\nexport PATH=\(HerdrSSHBridge.quote(root.path + ":/usr/bin:/bin:/usr/sbin:/sbin"))\nexec /bin/sh -c \"$SSH_ORIGINAL_COMMAND\"\n").utf8).write(to: forced)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: forced.path)
        let serverConfig = root.appendingPathComponent("sshd.config")
        let config = "Port \(port)\nListenAddress 127.0.0.1\nHostKey \(root.path)/host\nPidFile \(root.path)/sshd.pid\nAuthorizedKeysFile \(root.path)/key.pub\nStrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nAllowUsers \(NSUserName())\nForceCommand \(forced.path)\n"
        try Data(config.utf8).write(to: serverConfig)
        let known = root.appendingPathComponent("known_hosts")
        try Data(("[127.0.0.1]:\(port) " + String(contentsOf: root.appendingPathComponent("host.pub"), encoding: .utf8)).utf8).write(to: known)
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        server.arguments = ["-D", "-f", serverConfig.path, "-E", root.appendingPathComponent("sshd.log").path]
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        try await Task.sleep(for: .milliseconds(200))
        guard server.isRunning else { throw CLIError("Isolated SSH server did not start") }
        let sshConfig = try HerdrSSHBridge.configuration(target: target)
        defer { if let sshConfig { try? FileManager.default.removeItem(at: sshConfig.deletingLastPathComponent()) } }
        var sshArguments = try HerdrSSHBridge.arguments(target: target, configuration: sshConfig)
        sshArguments.removeLast()
        let managedArguments = sshArguments
        func authenticate() async throws {
            let master = try await Task.detached {
                try HerdrProcess.run(URL(fileURLWithPath: "/usr/bin/ssh"), arguments: managedArguments + ["-i", root.appendingPathComponent("key").path, "-o", "UserKnownHostsFile=" + known.path, "-o", "IdentitiesOnly=yes", "-M", "-N", "-f", target])
            }.value
            guard master.status == 0 else { throw CLIError("Isolated SSH authentication failed: " + String(decoding: master.stderr, as: UTF8.self)) }
        }
        try await authenticate()
        defer { _ = try? HerdrProcess.run(URL(fileURLWithPath: "/usr/bin/ssh"), arguments: sshArguments + ["-O", "exit", target], timeout: 5) }
        let firstSession = "santty-a", secondSession = "santty-b"
        defer {
            for session in [firstSession, secondSession] { _ = try? HerdrProcess.run(remoteWrapper, arguments: ["--session", session, "server", "stop"], timeout: 5) }
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.appendingPathComponent("Scripts/herdr-clientshell-fixture.py")
        let localPath = root.appendingPathComponent("local.sock").path
        let localService = Process(); localService.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); localService.arguments = [fixture.path, localPath, "window"]
        try localService.run()
        defer { if localService.isRunning { localService.terminate(); localService.waitUntilExit() } }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: root.appendingPathComponent("local-client.sock").path) { try await Task.sleep(for: .milliseconds(10)) }
        let profiles = [HerdrMachineProfile(id: String(repeating: "a", count: 32), label: "Remote A", target: target, session: firstSession, enabled: true),
                        HerdrMachineProfile(id: String(repeating: "b", count: 32), label: "Remote B", target: target, session: secondSession, enabled: true)]
        let catalogBinary = root.appendingPathComponent("catalog-herdr")
        let catalogJSON = String(decoding: try JSONEncoder().encode(profiles), as: UTF8.self)
        try Data(("#!/bin/sh\nif [ \"$1\" = machine ] && [ \"$2\" = list ]; then printf '%s\\n' \(HerdrSSHBridge.quote(catalogJSON)); else exec \(HerdrSSHBridge.quote(native)) \"$@\"; fi\n").utf8).write(to: catalogBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: catalogBinary.path)
        let local = HerdrEndpoint(binary: catalogBinary, session: "fixture", socketPath: localPath)
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        var errors: [String] = []; workspace.herdrErrorHandler = { errors.append($0) }
        try workspace.configureHerdrWorkspace(local)
        let localReference = workspace.debugSelectedWorkspace, localTabs = workspace.debugTabIDs
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace.view; window.orderBack(nil)
        defer { workspace.releaseHerdrConnections(); window.orderOut(nil); window.contentView = nil; AgentSessionStore.shared.reset() }
        workspace.startHerdrAgentMonitoring(local)
        for _ in 0..<4000 where workspace.debugWorkspaceEntries.filter({ $0.kind == .remoteHerdr && $0.isAvailable }).count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let remoteEntries = workspace.debugWorkspaceEntries.filter { $0.kind == .remoteHerdr && $0.isAvailable }
        XCTAssertEqual(remoteEntries.count, 2, workspace.debugHerdrEndpointStatus.description)
        let first = try XCTUnwrap(remoteEntries.first { if case .herdr(let endpoint, _) = $0.reference.source { return endpoint.machine?.session == firstSession }; return false })
        let second = try XCTUnwrap(remoteEntries.first { if case .herdr(let endpoint, _) = $0.reference.source { return endpoint.machine?.session == secondSession }; return false })
        if case .herdr(_, let firstID) = first.reference.source, case .herdr(_, let secondID) = second.reference.source {
            XCTAssertEqual(firstID, secondID, "The integration must exercise duplicate server workspace IDs")
        }
        XCTAssertNotEqual(first.id, second.id)
        workspace.selectWorkspace(first.id); await workspace.waitForWorkspaceSelection()
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true)
        workspace.reconnectPersistentTerminal(nil)
        XCTAssertTrue((workspace.view as? WorkspaceRootView)?.toolbarView.workspaceSwitcher.isEnabled == true)
        workspace.selectWorkspace(localReference.id)
        XCTAssertEqual(workspace.debugTabIDs, localTabs)
        XCTAssertFalse(workspace.debugHerdrOperationPending)
        workspace.selectWorkspace(first.id); await workspace.waitForWorkspaceSelection()
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true)
        let firstIdentity = workspace.debugFocusedHerdrPane?.herdrBinding?.serviceIdentity
        workspace.debugPerformCommand(withID: "pane.notes.new")
        let noteIDs = workspace.savedWorkspace().tabs.flatMap(\.panes).filter { $0.kind == .notes }.map(\.id)
        XCTAssertEqual(noteIDs.count, 1)
        workspace.selectWorkspace(second.id); await workspace.waitForWorkspaceSelection()
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
        XCTAssertEqual(workspace.debugSelectedWorkspace.id, second.id)
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true)
        XCTAssertNotEqual(workspace.debugFocusedHerdrPane?.herdrBinding?.serviceIdentity, firstIdentity)
        try workspace.savedWorkspace().validate()
        workspace.selectWorkspace(localReference.id)
        XCTAssertEqual(workspace.debugTabIDs, localTabs)
        workspace.selectWorkspace(first.id); await workspace.waitForWorkspaceSelection()
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
        XCTAssertEqual(workspace.debugSelectedWorkspace.id, first.id)
        XCTAssertEqual(workspace.savedWorkspace().tabs.flatMap(\.panes).filter { $0.kind == .notes }.map(\.id), noteIDs)
        try workspace.savedWorkspace().validate()

        let terminalID = try XCTUnwrap(workspace.savedWorkspace().tabs.flatMap(\.panes).first { $0.kind == .persistentTerminal }?.id)
        workspace.debugFocusPane(withID: terminalID)
        for _ in 0..<500 where workspace.debugHerdrOperationPending || workspace.debugFocusedHerdrPane?.canAcceptInput != true { try await Task.sleep(for: .milliseconds(10)) }
        let presented = try XCTUnwrap(workspace.debugFocusedHerdrPane)
        XCTAssertTrue(presented.canAcceptInput)
        let layout = workspace.debugLayoutNode
        let closed = try await Task.detached {
            try HerdrProcess.run(URL(fileURLWithPath: "/usr/bin/ssh"), arguments: managedArguments + ["-O", "exit", target], timeout: 5)
        }.value
        XCTAssertEqual(closed.status, 0)
        for _ in 0..<500 where presented.canAcceptInput { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(presented.canAcceptInput, "Losing SSH must invalidate input for the retained scene")
        XCTAssertEqual(workspace.debugSelectedWorkspace.id, first.id)
        XCTAssertEqual(workspace.debugLayoutNode, layout)
        try await authenticate()
        for _ in 0..<4000 where workspace.debugHerdrOperationPending || workspace.debugFocusedHerdrPane?.canAcceptInput != true { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(workspace.debugFocusedHerdrPane?.canAcceptInput == true, workspace.herdrLastError ?? "Native scene did not recover after SSH authentication returned")
        XCTAssertEqual(workspace.debugSelectedWorkspace.id, first.id)
        XCTAssertEqual(workspace.debugFocusedHerdrPane?.herdrBinding?.serviceIdentity, firstIdentity, "Transport loss must not restart the existing remote server")
        XCTAssertEqual(workspace.savedWorkspace().tabs.flatMap(\.panes).filter { $0.kind == .notes }.map(\.id), noteIDs)
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
        try workspace.savedWorkspace().validate()
    }
}
