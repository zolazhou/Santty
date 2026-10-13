import AppKit
import XCTest
@testable import Santty

@MainActor
final class HerdrCapabilityTests: XCTestCase {
    private let agentEndpoint = HerdrEndpoint(binary: URL(fileURLWithPath: "/missing/herdr"), session: "test", socketPath: "/tmp/agent-test.sock")
    private let agentIdentity = HerdrServiceIdentity(pid: 42, startedSeconds: 1, startedMicroseconds: 0)

    private func agentSnapshot(_ status: String, sequence: UInt64, revision: UInt64 = 7,
                               boot: String = "boot-v1", kind: String = "claude") throws -> HerdrShellSnapshot {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Fixtures/herdr-clientshell-snapshot-v1.json"))) as? [String: Any])
        var agents = try XCTUnwrap(value["agents"] as? [[String: Any]])
        agents[0]["agent_status"] = status; agents[0]["state_change_seq"] = sequence; agents[0]["agent"] = kind
        value["agents"] = agents; value["revision"] = revision; value["boot_id"] = boot
        return try JSONDecoder().decode(HerdrShellSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func agentNotice(_ kind: UInt32, pane: String = "w1:p1") -> HerdrShellNotification {
        .init(kind: kind, title: "Agent update", body: "Review ready", sound: 0, agent: "claude",
              workspace_id: "w1", tab_id: "w1:t1", pane_id: pane, position: nil)
    }

    func testHerdrAgentBaselineDoesNotReplayAndMessagesDeduplicate() throws {
        let store = AgentSessionStore()
        var delivered = 0
        store.onNotification = { _ in delivered += 1 }
        try store.apply(agentSnapshot("idle", sequence: 9), completions: .init(boot_id: "boot-v1", revision: 7, completions: ["w1:p1": 9]), endpoint: agentEndpoint, identity: agentIdentity)
        store.receive(agentNotice(1))
        XCTAssertEqual(delivered, 0); XCTAssertEqual(store.unreadCount, 0)
        try store.apply(agentSnapshot("working", sequence: 10, revision: 8), completions: nil, endpoint: agentEndpoint, identity: agentIdentity)
        try store.apply(agentSnapshot("idle", sequence: 11, revision: 9), completions: .init(boot_id: "boot-v1", revision: 9, completions: ["w1:p1": 11]), endpoint: agentEndpoint, identity: agentIdentity)
        store.receive(agentNotice(1)); store.receive(agentNotice(1))
        XCTAssertEqual(delivered, 1); XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(store.messages.first?.body, "Review ready")
        XCTAssertEqual(store.snapshots.first?.displayState, .turnCompleted)
        let paneID = try XCTUnwrap(store.snapshots.first?.paneID)
        store.markRead(forPaneIDs: [paneID])
        XCTAssertEqual(store.unreadCount, 0)
        store.markUnavailable()
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertFalse(try XCTUnwrap(store.snapshots.first).backendStatusAvailable)
        store.receive(agentNotice(1))
        XCTAssertEqual(delivered, 1, "Disconnected metadata cannot accept stale notifications")
    }

    func testHerdrAttentionWaitsForMetadataAndValidatesTarget() throws {
        let store = AgentSessionStore()
        var delivered = 0
        store.onNotification = { _ in delivered += 1 }
        try store.apply(agentSnapshot("working", sequence: 10), completions: nil, endpoint: agentEndpoint, identity: agentIdentity)
        store.receive(agentNotice(0))
        XCTAssertEqual(delivered, 0)
        try store.apply(agentSnapshot("blocked", sequence: 11, revision: 8), completions: nil, endpoint: agentEndpoint, identity: agentIdentity)
        XCTAssertEqual(delivered, 1); XCTAssertEqual(store.unreadCount, 1)
        store.receive(agentNotice(0, pane: "w1:missing"))
        store.receive(agentNotice(0))
        XCTAssertEqual(delivered, 1)
        try store.apply(agentSnapshot("working", sequence: 10, revision: 7), completions: nil, endpoint: agentEndpoint, identity: agentIdentity)
        XCTAssertEqual(store.snapshots.first?.displayState, .waitingForUser)
    }

    func testHerdrCompletionEvidenceMustMatchBootAndRevisionAndSupportsOtherAgents() throws {
        let store = AgentSessionStore()
        let snap = try agentSnapshot("idle", sequence: 9, kind: "opencode")
        try store.apply(snap, completions: .init(boot_id: "stale", revision: 7, completions: ["w1:p1": 9]), endpoint: agentEndpoint, identity: agentIdentity)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.snapshots.first?.agent.rawValue, "opencode")
        try store.apply(snap, completions: .init(boot_id: "boot-v1", revision: 6, completions: ["w1:p1": 9]), endpoint: agentEndpoint, identity: agentIdentity)
        XCTAssertTrue(store.messages.isEmpty)
        try store.apply(snap, completions: .init(boot_id: "boot-v1", revision: 7, completions: ["w1:p1": 9]), endpoint: agentEndpoint, identity: agentIdentity)
        XCTAssertEqual(store.messages.count, 1, "Late matching completion evidence is applied")
        try store.apply(agentSnapshot("idle", sequence: 9, boot: "new-boot", kind: "opencode"), completions: .init(boot_id: "new-boot", revision: 7, completions: ["w1:p1": 9]), endpoint: agentEndpoint, identity: agentIdentity)
        XCTAssertEqual(store.messages.count, 1, "Restart baselines cannot replay completions")
        XCTAssertEqual(store.snapshots.filter(\.backendStatusAvailable).count, 1)
    }

    func testHerdrVisibleTargetSuppressesSystemBannerAndReadStateRemainsLocal() throws {
        let store = AgentSessionStore()
        var delivered = 0
        store.onNotification = { _ in delivered += 1 }; store.isTargetVisible = { _ in true }
        try store.apply(agentSnapshot("working", sequence: 10), completions: nil, endpoint: agentEndpoint, identity: agentIdentity)
        let next = try agentSnapshot("blocked", sequence: 11, revision: 8)
        try store.apply(next, completions: nil, endpoint: agentEndpoint, identity: agentIdentity)
        store.receive(agentNotice(0))
        XCTAssertEqual(delivered, 0); XCTAssertEqual(store.unreadCount, 1)
        let binding = try XCTUnwrap(store.snapshots.first?.binding)
        store.markViewed([binding], snapshot: try agentSnapshot("working", sequence: 10))
        XCTAssertEqual(store.unreadCount, 1, "An older displayed scene cannot mark a newer event read")
        store.markViewed([binding], snapshot: next)
        XCTAssertEqual(store.unreadCount, 0)
    }

    func testAgentPanelCategoriesAndMessageHistoryAreBounded() throws {
        let store = AgentSessionStore.shared
        store.reset(); defer { store.reset() }
        try store.apply(agentSnapshot("working", sequence: 10), completions: nil, endpoint: agentEndpoint, identity: agentIdentity)
        for index in 0..<260 {
            store.receive(.init(kind: 3, title: "Message \(index)", body: nil, sound: nil, agent: "claude", workspace_id: "w1", tab_id: "w1:t1", pane_id: "w1:p1", position: nil))
        }
        XCTAssertEqual(store.messages.count, 256)
        XCTAssertEqual(store.messages.first?.title, "Message 4")
        let panel = AgentManagerView(sessions: store.snapshots)
        let category = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(category.segmentCount, 2)
        XCTAssertEqual(category.label(forSegment: 0), "Agents")
        XCTAssertEqual(category.label(forSegment: 1), "Messages")
        var resized = false; panel.onContentSizeChange = { resized = true }
        category.selectedSegment = 1
        _ = category.sendAction(category.action, to: category.target)
        XCTAssertTrue(resized); XCTAssertEqual(panel.preferredHeight, 520)
        let paneID = try XCTUnwrap(store.snapshots.first?.paneID)
        store.markRead(forPaneIDs: [paneID]); store.clearEnded()
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.snapshots.count, 1, "Clearing read history must preserve live agents")
    }

    func testLegacyAgentCleanupPreservesCustomHooksAndIsIdempotent() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-cleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let config = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let helper = support.appendingPathComponent("agent-hook")
        let command = [helper.path, "stop", "test.owner", "claude"].map { "'" + $0 + "'" }.joined(separator: " ")
        let value: [String: Any] = ["theme": "dark", "hooks": ["Stop": [["hooks": [["type": "command", "command": command], ["type": "command", "command": "echo custom"]]]]]]
        let original = try JSONSerialization.data(withJSONObject: value)
        try original.write(to: config); try Data("SANTTY_AGENT_SOCKET".utf8).write(to: helper)
        let cleanup = LegacyAgentHookCleanup(home: home, support: support, owner: "test.owner")
        try cleanup.run()
        let cleaned = try Data(contentsOf: config)
        let text = String(decoding: cleaned, as: UTF8.self)
        XCTAssertTrue(text.contains("echo custom")); XCTAssertTrue(text.contains("dark")); XCTAssertFalse(text.contains("test.owner"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.path))
        let backups = try FileManager.default.contentsOfDirectory(at: config.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.path.contains("santty-backup") }
        XCTAssertEqual(backups.count, 1); XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        try cleanup.run(); XCTAssertEqual(try Data(contentsOf: config), cleaned)
    }

    func testLegacyCodexCleanupPreservesOtherOwnerTrustAndGlobalFeatures() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-cleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let support = home.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let helper = support.appendingPathComponent("agent-hook")
        try Data("SANTTY_RUNTIME_OWNER".utf8).write(to: helper)
        let hooks = folder.appendingPathComponent("hooks.json")
        func command(_ owner: String) -> String { [helper.path, "stop", owner, "codex"].map { "'" + $0 + "'" }.joined(separator: " ") }
        let root: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": command("test.owner")], ["type": "command", "command": command("other.owner")]]]]]]
        try JSONSerialization.data(withJSONObject: root).write(to: hooks)
        let config = folder.appendingPathComponent("config.toml")
        let text = "[features]\ncodex_hooks = true\n[hooks.state.\"\(hooks.path):stop:0:0\"]\ntrusted_hash = \"mine\"\n[hooks.state.\"other\"]\ntrusted_hash = \"keep\"\n"
        try Data(text.utf8).write(to: config)
        try LegacyAgentHookCleanup(home: home, support: support, owner: "test.owner").run()
        let cleaned = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(cleaned.contains("codex_hooks = true")); XCTAssertTrue(cleaned.contains("keep")); XCTAssertFalse(cleaned.contains("mine"))
        XCTAssertTrue(try String(contentsOf: hooks, encoding: .utf8).contains("other.owner"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path), "Another owner's hook still needs its helper")
    }

    func testLegacyAgentCleanupRejectsMalformedConfigBeforeAnyWrite() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-cleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for directory in [".claude", ".codex"] { try FileManager.default.createDirectory(at: home.appendingPathComponent(directory), withIntermediateDirectories: true) }
        let support = home.appendingPathComponent("support")
        let config = home.appendingPathComponent(".claude/settings.json")
        let command = [support.appendingPathComponent("agent-hook").path, "stop", "test.owner", "claude"].map { "'" + $0 + "'" }.joined(separator: " ")
        let original = try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": [["hooks": [["type": "command", "command": command]]]]]])
        try original.write(to: config)
        try Data("invalid JSON".utf8).write(to: home.appendingPathComponent(".codex/hooks.json"))
        XCTAssertThrowsError(try LegacyAgentHookCleanup(home: home, support: support, owner: "test.owner").run())
        XCTAssertEqual(try Data(contentsOf: config), original)
    }

    private func pane(_ service: HerdrWorkspaceTests.Service) async throws -> TerminalPaneController {
        let metadata = try await HerdrWorkspaceClient(endpoint: service.endpoint).create()
        let pane = TerminalPaneController(herdr: try HerdrPaneBinding(endpoint: service.endpoint, pane: metadata))
        pane.applyHerdrSnapshot(metadata)
        return pane
    }

    func testClientShellQueriesUseSocketsWithoutLaunchingTheConfiguredExecutable() async throws {
        let service = HerdrWorkspaceTests.Service(); try await service.start()
        defer { service.stop() }
        let binary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("herdr-query-probe-\(UUID().uuidString).sh")
        let marker = URL(fileURLWithPath: binary.path + ".invoked")
        try Data("#!/bin/sh\ntouch \"$0.invoked\"\nprintf 'herdr 0.9.4\\n'\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        defer { try? FileManager.default.removeItem(at: binary); try? FileManager.default.removeItem(at: marker) }
        let endpoint = HerdrEndpoint(binary: binary, session: "default", socketPath: service.path)
        _ = try await HerdrWorkspaceClient(endpoint: endpoint).snapshot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        _ = try await HerdrWorkspaceClient(endpoint: endpoint).snapshot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testClientShellHistoryAndProcessQueriesResolveMissingRuntimeWithoutChangingPresentation() async throws {
        let service = HerdrWorkspaceTests.Service(); try await service.start("capabilities")
        defer { service.stop() }
        let runtime = try await HerdrWorkspaceClient(endpoint: service.endpoint).create()
        let pane = TerminalPaneController(herdr: try HerdrPaneBinding(endpoint: service.endpoint, pane: runtime))
        defer { pane.disconnectHerdr() }
        let shell = HerdrShellSnapshot.Pane(pane_id: runtime.pane_id, workspace_id: try XCTUnwrap(runtime.workspace_id),
            tab_id: try XCTUnwrap(runtime.tab_id), label: "Endpoint", cwd: "/endpoint", foreground_cwd: nil,
            focused: true, right_click_passthrough: false)
        pane.applyClientShellMetadata(shell, identity: try XCTUnwrap(runtime.serviceIdentity))
        let title = pane.displayTitle
        XCTAssertNil(pane.herdrQueryBinding)
        pane.enterScrollMode()
        await pane.waitForPersistentHistory()
        XCTAssertEqual((pane.focusTargetView as? NSTextView)?.string, "first\n中文🙂\nLast line")
        XCTAssertEqual(pane.herdrQueryBinding?.terminalID, runtime.terminal_id)
        XCTAssertNil(pane.herdrBinding?.terminalID)
        XCTAssertEqual(pane.displayTitle, title)
        XCTAssertEqual(pane.currentWorkingDirectory, "/endpoint")
        try await pane.refreshHerdrProcessInfo()
        XCTAssertEqual(pane.herdrProcessInfo?.foreground_process_group_id, 12345)
        XCTAssertEqual(pane.currentWorkingDirectory, "/endpoint", "Query results cannot replace endpoint cwd")
        let requests = try XCTUnwrap(try service.state()["requests"] as? [String])
        XCTAssertFalse(requests.contains("pane.send_text"))
        pane.exitScrollMode()
    }

    func testClientShellPaneNameRejectsStaleIdentityAndOverridesSavedLocalName() throws {
        let metadata = HerdrSnapshot.Pane(pane_id: "w1:p1", terminal_id: nil,
            workspace_id: "w1", tab_id: "w1:t1", serviceIdentity: agentIdentity)
        let pane = TerminalPaneController(herdr: try HerdrPaneBinding(endpoint: agentEndpoint, pane: metadata))
        defer { pane.disconnectHerdr() }
        let named = HerdrShellSnapshot.Pane(pane_id: "w1:p1", workspace_id: "w1", tab_id: "w1:t1",
            label: "Backend", cwd: nil, foreground_cwd: nil, focused: true, right_click_passthrough: false)
        pane.applyClientShellMetadata(named, identity: agentIdentity)
        XCTAssertEqual(pane.name, "Backend")
        pane.name = "Saved local override"
        pane.applyClientShellMetadata(named, identity: .init(pid: 43, startedSeconds: 1, startedMicroseconds: 0))
        XCTAssertEqual(pane.name, "Saved local override", "A stale service cannot rename a current pane")
        pane.applyClientShellMetadata(named, identity: agentIdentity)
        XCTAssertEqual(pane.name, "Backend", "Unchanged titles must still correct stale saved names")
        let cleared = HerdrShellSnapshot.Pane(pane_id: "w1:p1", workspace_id: "w1", tab_id: "w1:t1",
            label: nil, cwd: nil, foreground_cwd: nil, focused: true, right_click_passthrough: false)
        pane.applyClientShellMetadata(cleared, identity: agentIdentity)
        XCTAssertNil(pane.name); XCTAssertEqual(pane.lastKnownTitle, "Shell")
    }

    func testClientShellLateRuntimeResolutionCannotReviveInvalidatedQueryIdentity() async throws {
        for disconnect in [false, true] {
            let service = HerdrWorkspaceTests.Service(); try await service.start("slow_snapshot")
            defer { service.stop() }
            let runtime = try await HerdrWorkspaceClient(endpoint: service.endpoint).create()
            let pane = TerminalPaneController(herdr: try HerdrPaneBinding(endpoint: service.endpoint, pane: runtime))
            defer { pane.disconnectHerdr() }
            let resolution = Task { try await pane.resolveHerdrQueryBinding() }
            var requestStarted = false
            for _ in 0..<100 {
                if (try service.state()["requests"] as? [String])?.contains("session.snapshot") == true {
                    requestStarted = true; break
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(requestStarted)
            if disconnect { pane.disconnectHerdr() }
            else { pane.applyHerdrSnapshot(nil) }
            do { _ = try await resolution.value; XCTFail("Late identity was installed after invalidation") }
            catch { }
            XCTAssertNil(pane.herdrQueryBinding)
            XCTAssertTrue(pane.isLive)
        }
    }



    func testInvalidBackendReadAndProcessDataAreRejected() async throws {
        for scenario in ["bad_read", "bad_process"] {
            let service = HerdrWorkspaceTests.Service(); try await service.start(scenario)
            defer { service.stop() }
            let metadata = try await HerdrWorkspaceClient(endpoint: service.endpoint).create()
            let binding = try HerdrPaneBinding(endpoint: service.endpoint, pane: metadata, includeRuntime: true)
            let client = HerdrWorkspaceClient(endpoint: service.endpoint)
            do {
                if scenario == "bad_read" { _ = try await client.read(binding) }
                else { _ = try await client.processInfo(binding) }
                XCTFail("Malformed query result accepted")
            } catch { }
        }
    }

    func testHistorySelectionIsFrozenAndDoesNotSendTerminalInput() async throws {
        let service = HerdrWorkspaceTests.Service(); try await service.start(); defer { service.stop() }
        let pane = try await pane(service); defer { pane.disconnectHerdr() }
        pane.enterScrollMode(); await pane.waitForPersistentHistory()
        XCTAssertTrue(pane.isScrollModeActive)
        let text = try XCTUnwrap(pane.focusTargetView as? NSTextView)
        XCTAssertEqual(text.string, "first\n中文🙂\nLast line")
        XCTAssertFalse(text.isEditable)
        text.setSelectedRange((text.string as NSString).range(of: "中文🙂"))
        let pasteboard = NSPasteboard(name: .init("HerdrCopy-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let view = try XCTUnwrap(pane.hostView.subviews.compactMap { $0 as? HerdrHistoryView }.first)
        XCTAssertTrue(view.isOpaque)
        view.copy(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "中文🙂")
        pane.applyTerminalSettings()
        XCTAssertFalse(pane.debugRenderedTerminalConfig.contains("mouse-reporting = false"))
        XCTAssertFalse(pane.submitPrompt("must not send"))
        pane.exitScrollMode(); XCTAssertFalse(pane.isScrollModeActive)
        let requests = try XCTUnwrap(try service.state()["requests"] as? [String])
        XCTAssertFalse(requests.contains("pane.send_text"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.path + ".input.jsonl"))
    }

    func testPromptValidationAndDisconnectedRejection() throws {
        XCTAssertEqual(String(decoding: try TerminalPaneController.persistentPromptBytes("中文🙂\r\nsecond"), as: UTF8.self), "\u{1B}[200~中文🙂\nsecond\u{1B}[201~\r")
        for text in [" ", "bad\0", "\u{1B}[201~injection", String(repeating: "a", count: 65537)] {
            XCTAssertThrowsError(try TerminalPaneController.persistentPromptBytes(text))
        }
    }


    func testInstanceDiscoveryRecoversStaleHintsAndRejectsAmbiguousHerdrViews() throws {
        let id = UUID()
        let pane = CLIPane(id: id, title: "test", kind: "terminal", cwd: nil, foregroundProcessGroupID: nil,
            isFocused: true, isLive: true, isDetached: false, backend: "herdr", herdrPaneID: "w1:p1", herdrSocketPath: "/tmp/herdr.sock")
        let response = CLIResponse(tabs: [.init(id: UUID(), title: "test", isSelected: true, panes: [pane])])
        let found = try CLIInstanceDiscovery.resolve(explicit: nil, inherited: "stale", herdrPaneID: "w1:p1", herdrSocketPath: "/tmp/herdr.sock", candidates: ["new"]) { path in
            if path == "stale" { throw CLIError("closed") }; return response
        }
        XCTAssertEqual(found, "new")
        XCTAssertThrowsError(try CLIInstanceDiscovery.resolve(explicit: nil, inherited: "old", herdrPaneID: "w1:p1", herdrSocketPath: "/tmp/herdr.sock", candidates: ["new"]) { _ in response })
        XCTAssertThrowsError(try CLIInstanceDiscovery.resolve(explicit: nil, inherited: nil, herdrPaneID: "w1:p1", herdrSocketPath: "/tmp/other.sock", candidates: ["new"]) { _ in response })
        XCTAssertEqual(try CLIInstanceDiscovery.resolve(explicit: "forced", inherited: "old", herdrPaneID: nil, herdrSocketPath: nil, candidates: []) { _ in throw CLIError("must not probe") }, "forced")
    }

    func testLiveExternalReadAndProcessInfoWithoutMutations() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let target = environment["SANTTY_HERDR_TARGET"], let binary = environment["SANTTY_HERDR_BIN"] else { throw XCTSkip("Authorized external pane required") }
        let endpoint = HerdrEndpoint(binary: URL(fileURLWithPath: binary), session: "default",
            socketPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/herdr/herdr.sock").path)
        let client = HerdrWorkspaceClient(endpoint: endpoint)
        let snapshot = try await client.snapshot()
        let metadata = try XCTUnwrap(snapshot.panes.first { $0.pane_id == target })
        let binding = try HerdrPaneBinding(endpoint: endpoint, pane: metadata, includeRuntime: true)
        let read = try await client.read(binding)
        XCTAssertEqual(read.source, "recent")
        let processes = try await client.processInfo(binding)
        XCTAssertEqual(processes.pane_id, target)
        let after = try await client.snapshot()
        XCTAssertEqual(after.panes.first { $0.pane_id == target }?.terminal_id, binding.terminalID)
    }
}
