import AppKit
import XCTest
@testable import Santty

@MainActor
final class HerdrWorkspaceTests: XCTestCase {
    func testClientShellPublicPaneBindingDoesNotRequireOrInventRuntimeIdentity() throws {
        let endpoint = HerdrEndpoint(binary: URL(fileURLWithPath: "/usr/bin/true"), session: "default", socketPath: "/tmp/identity.sock")
        var metadata = try JSONDecoder().decode(HerdrSnapshot.Pane.self, from:
            Data(#"{"pane_id":"p","workspace_id":"w","tab_id":"t"}"#.utf8))
        XCTAssertNil(metadata.terminal_id)
        metadata.serviceIdentity = .init(pid: 1, startedSeconds: 2, startedMicroseconds: 3)
        let shell = try HerdrPaneBinding(endpoint: endpoint, pane: metadata)
        XCTAssertNil(shell.terminalID)
        XCTAssertTrue(shell.matches(metadata))
        XCTAssertThrowsError(try HerdrPaneBinding(endpoint: endpoint, pane: metadata, includeRuntime: true), "History mapping requires a real runtime")
        let runtime = HerdrSnapshot.Pane(pane_id: "p", terminal_id: "real-runtime", workspace_id: "w", tab_id: "t",
            serviceIdentity: metadata.serviceIdentity)
        let query = try HerdrPaneBinding(endpoint: endpoint, pane: runtime, includeRuntime: true)
        XCTAssertEqual(query.terminalID, "real-runtime")
        XCTAssertFalse(query.matches(metadata), "Query identity must not silently become a public-only match")
        XCTAssertEqual(try HerdrPaneBinding(endpoint: endpoint, pane: runtime), shell,
            "Acquiring a query mapping must not change the render binding")
        var foreign = runtime; foreign.workspace_id = "other"
        XCTAssertFalse(shell.matches(foreign))
        foreign = runtime; foreign.serviceIdentity = .init(pid: 1, startedSeconds: 9, startedMicroseconds: 3)
        XCTAssertFalse(shell.matches(foreign))
        foreign.serviceIdentity = nil
        XCTAssertThrowsError(try HerdrPaneBinding(endpoint: endpoint, pane: foreign))
    }

    func testLosingClientShellQueryMappingDoesNotEndTheRenderedPane() throws {
        let endpoint = HerdrEndpoint(binary: URL(fileURLWithPath: "/usr/bin/true"), session: "default", socketPath: "/tmp/identity.sock")
        let service = HerdrServiceIdentity(pid: 1, startedSeconds: 2, startedMicroseconds: 3)
        let runtime = HerdrSnapshot.Pane(pane_id: "p", terminal_id: "real-runtime", workspace_id: "w", tab_id: "t", serviceIdentity: service)
        let binding = try HerdrPaneBinding(endpoint: endpoint, pane: runtime)
        let pane = TerminalPaneController(herdr: binding)
        pane.applyHerdrSnapshot(runtime)
        XCTAssertEqual(pane.herdrQueryBinding?.terminalID, "real-runtime")
        pane.applyHerdrSnapshot(nil)
        XCTAssertTrue(pane.isLive)
        XCTAssertEqual(pane.herdrBinding, binding)
        XCTAssertNil(pane.herdrQueryBinding)
        pane.applyHerdrSnapshot(runtime)
        XCTAssertTrue(pane.isLive)
        XCTAssertEqual(pane.herdrQueryBinding?.terminalID, "real-runtime")
        pane.disconnectHerdr()
        XCTAssertNil(pane.herdrQueryBinding)
    }

    func testClientShellPresentationMetadataDoesNotDependOnOrGetOverwrittenByQueryMetadata() throws {
        let endpoint = HerdrEndpoint(binary: URL(fileURLWithPath: "/usr/bin/true"), session: "default", socketPath: "/tmp/metadata.sock")
        let service = HerdrServiceIdentity(pid: 1, startedSeconds: 2, startedMicroseconds: 3)
        let runtime = HerdrSnapshot.Pane(pane_id: "p", terminal_id: "runtime", workspace_id: "w", tab_id: "t",
            label: "Ahead API title", cwd: "/api", serviceIdentity: service)
        let pane = TerminalPaneController(herdr: try HerdrPaneBinding(endpoint: endpoint, pane: runtime))
        let shell = HerdrShellSnapshot.Pane(pane_id: "p", workspace_id: "w", tab_id: "t", label: "Endpoint title",
            cwd: "/endpoint", foreground_cwd: "/foreground", focused: true, right_click_passthrough: false)
        var changes = 0
        pane.onTitleChange = { _ in changes += 1 }
        pane.applyClientShellMetadata(shell, identity: service)
        XCTAssertTrue(pane.displayTitle.hasPrefix("Endpoint title ·"))
        let title = pane.displayTitle
        XCTAssertEqual(pane.currentWorkingDirectory, "/foreground")
        XCTAssertNil(pane.herdrQueryBinding)
        pane.applyHerdrSnapshot(runtime)
        XCTAssertEqual(pane.herdrQueryBinding?.terminalID, "runtime")
        XCTAssertEqual(pane.displayTitle, title)
        XCTAssertEqual(pane.currentWorkingDirectory, "/foreground")
        pane.applyClientShellMetadata(shell, identity: service)
        XCTAssertEqual(changes, 1, "Unchanged endpoint metadata and API identity updates must not trigger presentation callbacks")
        let foreign = HerdrShellSnapshot.Pane(pane_id: "p", workspace_id: "elsewhere", tab_id: "t", label: "Foreign",
            cwd: "/foreign", foreground_cwd: nil, focused: false, right_click_passthrough: false)
        pane.applyClientShellMetadata(foreign, identity: service)
        pane.applyClientShellMetadata(shell, identity: .init(pid: 1, startedSeconds: 9, startedMicroseconds: 3))
        pane.applyHerdrSnapshot(nil)
        XCTAssertNil(pane.herdrQueryBinding)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(pane.displayTitle, title)
        XCTAssertEqual(pane.currentWorkingDirectory, "/foreground")
        XCTAssertTrue(pane.isLive)
    }

    final class Service: @unchecked Sendable {
        let process = Process()
        let path = "/tmp/herdr-workspace-\(UUID().uuidString).sock"
        var endpoint: HerdrEndpoint {
            .init(binary: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Scripts/herdr-stage2-fixture.py"), session: "default", socketPath: path)
        }
        func start(_ scenario: String = "normal") async throws {
            process.executableURL = endpoint.binary
            process.arguments = ["api", path, scenario]
            try process.run()
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: path) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CLIError("Fixture failed to start")
        }
        func state() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".json"))) as? [String: Any])
        }
        func stop() {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            for suffix in ["", ".json", ".json.tmp", ".input.jsonl"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
    }
















    func testProjectionCandidateIsIsolatedUntilCommittedAndRetainsTabIdentity() throws {
        let backend = UUID(), local = UUID(), replacement = UUID()
        let pane = TerminalPaneController(id: local)
        let config = WorkspaceFocusZoomConfiguration.defaultAutoResizeConfiguration
        let original = WorkspaceTabState(layoutNode: .panel(backend), paneControllers: [local: pane],
            paneAutoResizeConfigurations: [backend: config], focusedPaneID: backend, customTitle: "Custom",
            activeAutoZoomState: .init(focusedPaneID: backend, splitStates: []),
            activeFloatingPaneState: .init(paneID: backend, size: NSSize(width: 500, height: 300)))
        let endpoint = HerdrEndpoint(binary: URL(fileURLWithPath: "/usr/bin/true"), session: "default", socketPath: "/tmp/candidate.sock")
        original.herdrTabBinding = try HerdrPaneBinding(endpoint: endpoint,
            pane: .init(pane_id: "p", terminal_id: "runtime", workspace_id: "w", tab_id: "t", serviceIdentity: .init(pid: 1, startedSeconds: 2, startedMicroseconds: 3)))
        original.herdrBackendTitle = "Backend"
        original.herdrBackendLayout = .panel(backend)
        original.herdrLocalLayout = .panel(local)
        original.herdrLocalFraction = 0.6
        original.herdrFocusedPaneID = backend
        original.herdrZoomed = true
        original.detachedPaneIDs = [backend]
        original.activeDetachedPaneID = backend
        original.floatingPaneSizes = [backend: NSSize(width: 500, height: 300)]
        let candidate = original.makeProjectionCandidate()
        XCTAssertFalse(candidate === original)
        XCTAssertEqual(candidate.id, original.id)
        XCTAssertTrue(candidate.paneControllers[local] as? TerminalPaneController === pane)
        XCTAssertEqual(candidate.herdrTabBinding, original.herdrTabBinding)
        XCTAssertEqual(candidate.herdrBackendTitle, "Backend")
        XCTAssertEqual(candidate.herdrLocalLayout, .panel(local))
        XCTAssertEqual(candidate.herdrLocalFraction, 0.6)
        XCTAssertEqual(candidate.activeAutoZoomState, original.activeAutoZoomState)
        XCTAssertTrue(candidate.herdrZoomed)

        candidate.remapPresentationPaneIDs([backend: replacement])
        candidate.herdrBackendLayout = .panel(replacement)
        candidate.composeHerdrLayout()
        candidate.customTitle = nil
        candidate.activeAutoZoomState = nil
        XCTAssertEqual(original.layoutNode, .panel(backend))
        XCTAssertEqual(original.focusedPaneID, backend)
        XCTAssertEqual(original.focusRecency(for: backend), 0)
        XCTAssertEqual(original.detachedPaneIDs, [backend])
        XCTAssertEqual(original.activeDetachedPaneID, backend)
        XCTAssertEqual(original.activeFloatingPaneState?.paneID, backend)
        XCTAssertNotNil(original.paneAutoResizeConfigurations[backend])
        XCTAssertNotNil(original.floatingPaneSizes[backend])
        XCTAssertEqual(original.customTitle, "Custom")
        XCTAssertNotNil(original.activeAutoZoomState)

        let installed = original
        original.applyProjectionCandidate(candidate)
        XCTAssertTrue(installed === original)
        XCTAssertEqual(original.layoutNode, candidate.layoutNode)
        XCTAssertEqual(original.herdrBackendLayout, .panel(replacement))
        XCTAssertEqual(original.focusedPaneID, replacement)
        XCTAssertEqual(original.herdrFocusedPaneID, replacement)
        XCTAssertEqual(original.focusRecency(for: replacement), 0)
        XCTAssertEqual(original.detachedPaneIDs, [replacement])
        XCTAssertEqual(original.activeDetachedPaneID, replacement)
        XCTAssertEqual(original.activeFloatingPaneState?.paneID, replacement)
        XCTAssertEqual(original.paneAutoResizeConfigurations[replacement], config)
        XCTAssertEqual(original.floatingPaneSizes[replacement], NSSize(width: 500, height: 300))
        XCTAssertNil(original.customTitle)
        XCTAssertNil(original.activeAutoZoomState)
        XCTAssertTrue(original.paneControllers[local] as? TerminalPaneController === pane)
    }

    func testPresentationRemappingPreservesFloatingHiddenSizesAndFocusRecency() {
        let floating = UUID(), hidden = UUID(), local = UUID(), newFloating = UUID(), newHidden = UUID()
        let config = WorkspaceFocusZoomConfiguration.defaultAutoResizeConfiguration
        let state = WorkspaceTabState(layoutNode: nil, paneControllers: [:],
            paneAutoResizeConfigurations: [floating: config, local: config], focusedPaneID: floating,
            activeFloatingPaneState: .init(paneID: floating, size: NSSize(width: 500, height: 300)))
        state.detachedPaneIDs = [hidden]
        state.floatingPaneSizes = [floating: NSSize(width: 500, height: 300), local: NSSize(width: 250, height: 200)]
        state.remapPresentationPaneIDs([floating: newFloating, hidden: newHidden])
        XCTAssertEqual(state.focusedPaneID, newFloating)
        XCTAssertEqual(state.focusRecency(for: newFloating), 0)
        XCTAssertNil(state.focusRecency(for: floating))
        XCTAssertEqual(state.detachedPaneIDs, [newHidden])
        XCTAssertEqual(state.activeFloatingPaneState, .init(paneID: newFloating, size: NSSize(width: 500, height: 300)))
        XCTAssertEqual(state.floatingPaneSizes[newFloating], NSSize(width: 500, height: 300))
        XCTAssertEqual(state.floatingPaneSizes[local], NSSize(width: 250, height: 200))
        XCTAssertEqual(state.paneAutoResizeConfigurations[newFloating], config)
        XCTAssertEqual(state.paneAutoResizeConfigurations[local], config)
        XCTAssertNil(state.paneAutoResizeConfigurations[floating])
    }





















}
