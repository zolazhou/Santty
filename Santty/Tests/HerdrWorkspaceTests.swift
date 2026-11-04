import AppKit
@testable import GhosttyTerminal
import XCTest
@testable import Santty

@MainActor
final class HerdrWorkspaceTests: XCTestCase {
    func testWorkspaceKindsPersistAndRejectCrossBackendBindings() throws {
        let workspace = WorkspaceViewController()
        workspace.debugLoadForTesting()
        let local = workspace.debugSelectedWorkspace
        workspace.newHerdrWorkspace(nil)
        let herdr = workspace.debugSelectedWorkspace
        XCTAssertNotEqual(local, herdr)
        XCTAssertEqual(workspace.debugWorkspaceEntries.first { $0.reference == herdr }?.kind, .herdr)
        XCTAssertTrue(workspace.paletteNavigationItems.contains { $0.kind == .workspace && $0.subtitle == "Herdr Workspace" })
        let saved = workspace.savedWorkspace()
        XCTAssertEqual(saved.workspaceKind, .herdr)
        XCTAssertEqual(saved.tabs.first?.panes.first?.kind, .herdrTerminal)
        try saved.validate()
        let decoded = try JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(saved))
        let restored = WorkspaceViewController()
        restored.debugLoadForTesting()
        try restored.restoreWorkspace(decoded)
        XCTAssertEqual(restored.debugSelectedWorkspace, herdr)
        restored.selectWorkspace(local)
        XCTAssertEqual(restored.savedWorkspace().workspaceKind, nil)
        XCTAssertEqual(restored.savedWorkspace().tabs.first?.panes.first?.kind, .localTerminal)
        var invalid = saved
        invalid.workspaceKind = .local
        XCTAssertThrowsError(try invalid.validate())
        invalid = saved
        invalid.tabs[0].panes[0].herdr = .init(coreID: "test", address: "remote/t1")
        XCTAssertThrowsError(try invalid.validate())
    }

    func testRemoteWorkspaceIdentityPersistsAndRejectsOtherMachines() throws {
        let remote = HerdrRemote(id: "remote-core-123", name: "box")
        let workspace = WorkspaceViewController()
        workspace.debugLoadForTesting()
        workspace.createRemoteHerdrWorkspace(remote)
        let remoteWorkspace = workspace.debugSelectedWorkspace
        var saved = workspace.savedWorkspace()
        XCTAssertEqual(saved.herdrRemote, remote)
        XCTAssertEqual(workspace.debugWorkspaceEntries.first { $0.reference == remoteWorkspace }?.symbol, "network")
        saved.tabs[0].panes[0].herdr = .init(coreID: remote.id, address: "t1", remote: true)
        try saved.validate()
        let restored = WorkspaceViewController()
        restored.debugLoadForTesting()
        try restored.restoreWorkspace(JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(saved)))
        restored.newWorkspace(nil)
        XCTAssertNil(restored.savedWorkspace().herdrRemote)
        restored.selectWorkspace(remoteWorkspace)
        XCTAssertEqual(restored.savedWorkspace().herdrRemote, remote)
        XCTAssertEqual(restored.savedWorkspace().tabs[0].panes[0].herdr?.routedAddress, "remote-core-123/t1")
        var invalid = saved
        invalid.herdrRemote = .init(id: "another-core", name: "box")
        XCTAssertThrowsError(try invalid.validate())
        invalid = saved
        invalid.herdrRemote = nil
        XCTAssertThrowsError(try invalid.validate())
        invalid = saved
        invalid.tabs[0].panes[0].herdr = .init(coreID: remote.id, address: "box/t1", remote: true)
        XCTAssertThrowsError(try invalid.validate())
        invalid = saved
        invalid.herdrRemote = .init(id: "../local", name: "box")
        XCTAssertThrowsError(try invalid.validate())
        let session = HerdrTerminalSession(paneID: UUID(), cwd: nil, binding: nil, remote: remote)
        var opened = false
        let pane = TerminalPaneController(herdrSession: session, openURL: { _ in opened = true; return true })
        pane.terminalDidRequestOpenURL("/srv/app/file.txt", kind: .unknown)
        XCTAssertFalse(opened, "Remote paths must not open files on this Mac")
    }

    func testRemoteWorkspaceThroughLocalProxyRecoversAndKeepsIdentity() async throws {
        let executable: URL
        do { executable = try HerdrCoreTransport.executable() }
        catch { throw XCTSkip("hc is required for the remote integration test") }
        let root = URL(fileURLWithPath: "/tmp/santty-remote-\(UUID().uuidString.prefix(8))")
        func environment(_ name: String) throws -> [String: String] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HC_") }
            env["HC_RECONNECT_MS"] = "250"
            env["HC_SESSION"] = "probe"; env["HC_SOCKET"] = directory.appendingPathComponent("core.sock").path
            env["XDG_STATE_HOME"] = directory.appendingPathComponent("state").path
            env["XDG_CONFIG_HOME"] = directory.appendingPathComponent("config").path; env["XDG_RUNTIME_DIR"] = directory.path
            env["PATH"] = executable.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            return env
        }
        let local = try environment("local"), remote = try environment("remote")
        func command(_ env: [String: String], _ args: [String]) async throws -> Data {
            try await Task.detached {
                let process = Process(), output = Pipe()
                process.executableURL = executable; process.arguments = ["--json"] + args; process.environment = env
                process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CLIError("Private hc failed: \(args)") }
                return data
            }.value
        }
        defer {
            // Both cores and every terminal belong only to this fixture.
            for env in [local, remote] {
                let list = Process(), output = Pipe()
                list.executableURL = executable; list.arguments = ["--json", "ls", "--all"]; list.environment = env
                list.standardOutput = output; list.standardError = FileHandle.nullDevice
                if (try? list.run()) != nil {
                    let data = output.fileHandleForReading.readDataToEndOfFile(); list.waitUntilExit()
                    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let terminals = object["terminals"] as? [[String: Any]] {
                        for terminal in terminals {
                            guard let address = terminal["address"] as? String, !address.contains("/") else { continue }
                            let kill = Process(); kill.executableURL = executable; kill.arguments = ["kill", address]; kill.environment = env
                            kill.standardOutput = FileHandle.nullDevice; kill.standardError = FileHandle.nullDevice
                            if (try? kill.run()) != nil { kill.waitUntilExit() }
                        }
                    }
                }
                let process = Process(); process.executableURL = executable; process.arguments = ["server", "stop"]; process.environment = env
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try? process.run(); process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: root)
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let gate = root.appendingPathComponent("offline"), via = root.appendingPathComponent("via.sh")
        let pairs = ["HC_SESSION", "HC_SOCKET", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "PATH"]
        let script = "#!/bin/sh\n[ -f " + quote(gate.path) + " ] && exit 1\nexec env " + pairs.map { quote($0 + "=" + remote[$0]!) }.joined(separator: " ") + " sh -c \"$1\"\n"
        try script.write(to: via, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: via.path)
        _ = try await command(remote, ["server", "start"])
        let added = try await command(local, ["machine", "add", "--name", "box", "--via", quote(via.path)])
        let machine = try JSONDecoder().decode(HerdrRemote.self, from: added)
        let client = HerdrCoreClient(executable: executable, environment: local)
        client.startAgentMonitoring()
        defer { client.stopAgentMonitoring() }
        var workspace: WorkspaceViewController? = WorkspaceViewController()
        workspace!.herdrCoreClient = client
        workspace!.debugLoadForTesting()
        let localWorkspace = workspace!.debugSelectedWorkspace
        workspace!.createRemoteHerdrWorkspace(machine)
        let remoteWorkspace = workspace!.debugSelectedWorkspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace!.view; workspace!.viewDidAppear()
        defer { window.contentView = nil; workspace = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var stage = "initial attach"
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<1000 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Remote workspace timed out at \(stage): \(descendants(workspace!.view).compactMap { ($0 as? TerminalView)?.delegate as? TerminalPaneController }.map { $0.displayTitle })")
            throw CLIError("Remote workspace condition timed out at \(stage)")
        }
        do {
            var terminal = try XCTUnwrap(descendants(workspace!.view).compactMap { $0 as? TerminalView }.first)
            workspace!.view.layoutSubtreeIfNeeded(); terminal.fitToSize()
            var pane = try XCTUnwrap(terminal.delegate as? TerminalPaneController)
            var session = try XCTUnwrap(pane.herdrSession)
            try await waitFor { session.state == .live }
            let binding = try XCTUnwrap(session.binding)
            XCTAssertEqual(binding.coreID, machine.id)
            XCTAssertEqual(binding.remote, true)
            let before = try await client.terminal(binding)
            let remoteRecord = try JSONDecoder().decode(HerdrCoreTerminal.self, from: await command(remote, ["get", binding.address]))
            XCTAssertEqual(before.pid, remoteRecord.pid)
            XCTAssertTrue(terminal.paste(text: #"sh -c 'printf "REMOTE-SOCKET:%s\n" "${SANTTY_CONTROL_SOCKET-unset}"'; printf 'REMOTE-%s-OK\n' INPUT"#))
            XCTAssertTrue(terminal.sendKey(.enter))
            stage = "remote input"
            try await waitFor { terminal.readScreenText()?.contains("REMOTE-INPUT-OK") == true }
            XCTAssertTrue(terminal.readScreenText()?.contains("REMOTE-SOCKET:unset") == true)
            XCTAssertTrue(pane.workingDirectoryForNewPane?.hasPrefix("/") == true)
            XCTAssertNil(try workspace!.handleCLIRequest(.init(command: "list")).tabs?.first?.panes.first?.foregroundProcessGroupID)
            if let foreground = session.record?.foreground {
                let inputSource = try await pane.inputSourceForeground()
                XCTAssertEqual(inputSource.groupID, Int(foreground.pid))
                XCTAssertEqual(inputSource.processes.first?.name, foreground.name)
            }
            XCTAssertTrue(terminal.paste(text: #"printf '\033]7501;state=working:app=codex\033\\'"#))
            XCTAssertTrue(terminal.sendKey(.enter))
            stage = "remote agent working status"
            try await waitFor { client.agents.snapshots.contains { $0.binding == binding && $0.displayState == .running } }
            XCTAssertTrue(terminal.paste(text: #"printf '\033]7501;state=done:app=codex:msg=UmVtb3RlIHJldmlldyByZWFkeQ==\033\\'"#))
            XCTAssertTrue(terminal.sendKey(.enter))
            try await waitFor { client.agents.messages.count == 1 }
            XCTAssertEqual(client.agents.messages.first?.body, "Remote review ready")
            XCTAssertEqual(client.agents.messages.first?.binding.coreID, machine.id)
            let connection = try await client.connection()
            let external: HerdrCoreTerminal = try await HerdrCoreClient.request(connection, "terminal.run",
                ["on": machine.id, "no_parent": true, "argv": ["/bin/sh", "-c", #"printf '\033]7501;state=idle:app=opencode\033\\'; exec /bin/cat"#]])
            let externalBinding = try XCTUnwrap(client.binding(for: external, remote: machine, connection: connection))
            workspace!.navigateToAgent(externalBinding)
            stage = "external remote agent viewer"
            try await waitFor { workspace!.savedWorkspace().tabs.first { $0.id == workspace!.debugSelectedTabID }?.panes.first?.herdr == externalBinding }
            let externalTab = try XCTUnwrap(workspace!.debugSelectedTabID)
            XCTAssertEqual(workspace!.savedWorkspace().tabs.first { $0.id == externalTab }?.panes.first?.herdrViewer, true)
            workspace!.debugCloseTab(withID: externalTab)
            try await waitFor { workspace!.debugTabIDs.count == 1 }
            let externalLive = try await client.terminal(externalBinding)
            XCTAssertEqual(externalLive.pid, external.pid)
            XCTAssertEqual(externalLive.state, "live")
            try await client.kill(externalBinding)
            workspace!.debugToggleFloatingPane()
            XCTAssertNotNil(workspace!.debugActiveFloatingPaneState)
            XCTAssertTrue(terminal.paste(text: "awk 'BEGIN {for(i=1;i<=1000;i++) print \"remote-row-\" i \" 中文🙂\"; print \"REMOTE-SCROLL-\" \"DONE\"}'"))
            XCTAssertTrue(terminal.sendKey(.enter))
            stage = "remote scroll output"
            try await waitFor { terminal.readScreenText()?.contains("REMOTE-SCROLL-DONE") == true }
            workspace!.enterScrollMode(nil)
            XCTAssertTrue(workspace!.debugFocusedPaneIsInScrollMode)
            let scroll = try XCTUnwrap(descendants(workspace!.view).compactMap { $0 as? TerminalScrollModeView }.first)
            scroll.move(.top); scroll.toggleSelection(linewise: true); scroll.move(.bottom)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            scroll.copySelection(to: pasteboard)
            XCTAssertTrue(pasteboard.string(forType: .string)?.contains("remote-row-1000 中文🙂") == true)
            try Data().write(to: gate)
            _ = try await command(remote, ["server", "restart"])
            stage = "offline"
            try await waitFor { session.state != .live }
            XCTAssertFalse(workspace!.debugFocusedPaneIsInScrollMode)
            XCTAssertNil(pane.inputSourceTargetView)
            do { try await session.closeTerminal(); XCTFail("Offline close must retain the binding") }
            catch { XCTAssertEqual(session.binding, binding) }
            try FileManager.default.removeItem(at: gate)
            stage = "reconnect"
            try await waitFor { session.state == .live }
            let after = try await client.terminal(binding)
            XCTAssertEqual(after.pid, before.pid)
            _ = try await command(local, ["machine", "rename", "box", "renamed"])
            _ = try await client.configuredMachines()
            let checkedRecord = try await client.terminal(binding)
            XCTAssertEqual(checkedRecord.pid, before.pid)
            XCTAssertTrue(terminal.paste(text: "printf 'RENAMED-%s-OK\\n' INPUT"))
            XCTAssertTrue(terminal.sendKey(.enter))
            stage = "renamed input"
            try await waitFor { terminal.readScreenText()?.contains("RENAMED-INPUT-OK") == true }
            XCTAssertTrue(terminal.paste(text: #"printf '\033]7501;state=working:app=codex\033\\'"#))
            XCTAssertTrue(terminal.sendKey(.enter))
            stage = "renamed remote agent metadata"
            try await waitFor { client.agents.snapshots.contains { $0.binding == binding && $0.backendStatusAvailable && $0.displayState == .running } }
            XCTAssertEqual(client.agents.messages.count, 1, "Reconnect and alias changes must not replay completion notices")
            var saved = workspace!.savedWorkspace()
            try saved.validate()
            // Reopen an uncertain run and reconcile its label on the correct machine.
            saved.tabs[0].panes[0].herdr = nil
            saved.tabs[0].panes[0].herdrRunPending = true
            window.contentView = nil; workspace = nil
            workspace = WorkspaceViewController(); workspace!.herdrCoreClient = client; workspace!.debugLoadForTesting()
            try workspace!.restoreWorkspace(saved)
            window.contentView = workspace!.view; workspace!.viewDidAppear(); workspace!.view.layoutSubtreeIfNeeded()
            terminal = try XCTUnwrap(descendants(workspace!.view).compactMap { $0 as? TerminalView }.first)
            terminal.fitToSize()
            pane = try XCTUnwrap(terminal.delegate as? TerminalPaneController); session = try XCTUnwrap(pane.herdrSession)
            stage = "restore"
            try await waitFor { session.state == .live }
            XCTAssertEqual(session.binding, binding)
            let restoredRecord = try await client.terminal(binding)
            XCTAssertEqual(restoredRecord.pid, before.pid)
            workspace!.closeLocalWorkspace(remoteWorkspace)
            try await waitFor { workspace!.debugSelectedWorkspace == localWorkspace }
            let finished = try await client.terminal(binding), machines = try await client.configuredMachines()
            XCTAssertEqual(finished.state, "finished")
            XCTAssertEqual(machines.first?.id, machine.id, "Closing a workspace must not remove the shared machine")

            window.contentView = nil; workspace = nil
            workspace = WorkspaceViewController(); workspace!.herdrCoreClient = client; workspace!.debugLoadForTesting()
            workspace!.createRemoteHerdrWorkspace(machine)
            var uncertain = workspace!.savedWorkspace()
            uncertain.tabs[0].panes[0].herdrRunPending = true
            try workspace!.restoreWorkspace(uncertain)
            window.contentView = workspace!.view; workspace!.viewDidAppear(); workspace!.view.layoutSubtreeIfNeeded()
            terminal = try XCTUnwrap(descendants(workspace!.view).compactMap { $0 as? TerminalView }.first); terminal.fitToSize()
            session = try XCTUnwrap((terminal.delegate as? TerminalPaneController)?.herdrSession)
            stage = "unknown run protection"
            try await waitFor { if case .failed = session.state { return true }; return false }
            XCTAssertNil(session.binding)
            XCTAssertTrue(session.createResultUnknown)
            session.retry()
            try await waitFor { if case .failed = session.state { return true }; return false }
            XCTAssertNil(session.binding, "Retry must never create a replacement for an uncertain run")
            let list = try await command(remote, ["ls"])
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: list) as? [String: Any])
            XCTAssertTrue((object["terminals"] as? [[String: Any]])?.isEmpty == true)
            do { try await session.closeTerminal(); XCTFail("Unknown run must retain its pane") }
            catch { XCTAssertTrue(session.createResultUnknown) }
        } catch {
            let machines = try? await client.configuredMachines()
            XCTFail("Remote flow failed at \(stage): \(error.localizedDescription); actual machines: \(String(describing: machines)); gate: \(FileManager.default.fileExists(atPath: gate.path))")
            throw error
        }
    }

    func testProductionHerdrWorkspaceRunsFloatsRestoresAndClosesTerminal() async throws {
        let executable: URL
        do { executable = try HerdrCoreTransport.executable() }
        catch { throw XCTSkip("hc is required for the real workspace integration test") }
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("santty-hc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HC_") }
        env["HC_SESSION"] = "probe"; env["HC_SOCKET"] = root.appendingPathComponent("core.sock").path
        env["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        env["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path; env["XDG_RUNTIME_DIR"] = root.path
        let suite = "HerdrWorkspaceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = HerdrCoreClient(executable: executable, environment: env, settings: HerdrSettings(defaults: defaults))
        defer {
            let stop = Process(); stop.executableURL = executable; stop.arguments = ["server", "stop"]; stop.environment = env
            stop.standardOutput = FileHandle.nullDevice; stop.standardError = FileHandle.nullDevice
            do { try stop.run(); stop.waitUntilExit(); try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Private core cleanup failed: \(error)") }
        }
        var workspace: WorkspaceViewController? = WorkspaceViewController()
        workspace!.herdrCoreClient = client
        workspace!.debugLoadForTesting()
        let local = workspace!.debugSelectedWorkspace
        workspace!.newHerdrWorkspace(nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [], backing: .buffered, defer: false)
        window.contentView = workspace!.view
        workspace!.viewDidAppear()
        defer { window.contentView = nil; workspace = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let terminal = try XCTUnwrap(descendants(workspace!.view).compactMap { $0 as? TerminalView }.first)
        workspace!.view.layoutSubtreeIfNeeded(); terminal.fitToSize()
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<500 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "HerdrWorkspaceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Workspace condition timed out"])
        }
        try await waitFor { workspace!.savedWorkspace().tabs.first?.panes.first?.herdr != nil }
        let paneID = try XCTUnwrap(workspace!.debugFocusedPaneID)
        let binding = try XCTUnwrap(workspace!.savedWorkspace().tabs.first?.panes.first?.herdr)
        // The first attach must finish before accepting interactive input.
        try await waitFor { !workspace!.debugDisplayTitle(forTabID: workspace!.debugSelectedTabID!)!.contains("Connecting") }
        XCTAssertTrue(window.firstResponder === terminal)
        XCTAssertTrue(terminal.paste(text: "printf 'PRODUCTION-%s-OK\\n' CORE"))
        XCTAssertTrue(terminal.sendKey(.enter))
        try await waitFor { terminal.readScreenText()?.contains("PRODUCTION-CORE-OK") == true }
        workspace!.debugSplitFocusedPane(along: .horizontal)
        let secondPane = try XCTUnwrap(workspace!.debugFocusedPaneID)
        try await waitFor { workspace!.savedWorkspace().tabs[0].panes.first { $0.id == secondPane }?.herdr != nil }
        let secondBinding = try XCTUnwrap(workspace!.savedWorkspace().tabs[0].panes.first { $0.id == secondPane }?.herdr)
        XCTAssertNotEqual(secondBinding.address, binding.address)
        workspace!.debugPerformClosePane(withID: secondPane)
        try await waitFor { workspace!.debugFocusedPaneID == paneID }
        let secondFinished = try await client.terminal(secondBinding)
        XCTAssertEqual(secondFinished.state, "finished")
        workspace!.debugNewTab()
        let newTab = try XCTUnwrap(workspace!.debugSelectedTabID)
        try await waitFor { workspace!.savedWorkspace().tabs.first { $0.id == newTab }?.panes.first?.herdr != nil }
        let thirdBinding = try XCTUnwrap(workspace!.savedWorkspace().tabs.first { $0.id == newTab }?.panes.first?.herdr)
        workspace!.debugCloseTab(withID: newTab)
        try await waitFor { workspace!.debugTabIDs.count == 1 }
        let thirdFinished = try await client.terminal(thirdBinding)
        XCTAssertEqual(thirdFinished.state, "finished")
        let beforeRestart = try await client.terminal(binding)
        let oldConnection = try await client.connection()
        let session = try XCTUnwrap((terminal.delegate as? TerminalPaneController)?.herdrSession)
        let restartEnvironment = env
        let restartStatus = try await Task.detached {
            let process = Process()
            process.executableURL = executable; process.arguments = ["server", "restart"]; process.environment = restartEnvironment
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }.value
        XCTAssertEqual(restartStatus, 0)
        var reattached = false
        for _ in 0..<500 {
            if let connection = try? await client.connection(), connection !== oldConnection, session.state == .live {
                reattached = true; break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(reattached, "Viewer did not recover after core restart")
        let afterRestart = try await client.terminal(binding)
        XCTAssertEqual(afterRestart.pid, beforeRestart.pid)
        do {
            _ = try await client.terminal(.init(coreID: "different-core", address: binding.address))
            XCTFail("A saved address from another core must be rejected")
        } catch { XCTAssertEqual((error as? HerdrCoreError)?.kind, "identity_changed") }
        let before = try await client.terminal(binding)
        workspace!.debugToggleFloatingPane()
        XCTAssertEqual(workspace!.debugActiveFloatingPaneState?.paneID, paneID)
        let burst = #"awk 'BEGIN { for(i=1;i<=6000;i++) printf "real-row-%04d 中文🙂 0123456789012345678901234567890123456789012345678901234567890123456789\n",i; print "REAL-BURST-" "DONE" }'"#
        XCTAssertTrue(terminal.paste(text: burst))
        XCTAssertTrue(terminal.sendKey(.enter))
        workspace!.enterScrollMode(nil)
        XCTAssertTrue(workspace!.debugFocusedPaneIsInScrollMode)
        try await waitFor { terminal.readScreenText()?.contains("REAL-BURST-DONE") == true }
        XCTAssertTrue(workspace!.debugFocusedPaneIsInScrollMode)
        let scroll = try XCTUnwrap(descendants(workspace!.view).compactMap { $0 as? TerminalScrollModeView }.first)
        scroll.move(.top)
        scroll.toggleSelection(linewise: true)
        scroll.move(.bottom)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        scroll.copySelection(to: pasteboard)
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains("real-row-0001 中文🙂") == true)
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains("real-row-6000 中文🙂") == true)

        client.settings.historyLines = 0
        try await client.reconnect()
        try await waitFor { session.state == .live }
        XCTAssertFalse(workspace!.debugFocusedPaneIsInScrollMode)
        try await waitFor {
            let text = terminal.readScreenText() ?? ""
            return text.contains("REAL-BURST-DONE") && !text.contains("real-row-5000")
        }
        workspace!.enterScrollMode(nil)
        let restoredScroll = try XCTUnwrap(descendants(workspace!.view).compactMap { $0 as? TerminalScrollModeView }.first)
        restoredScroll.move(.top); restoredScroll.toggleSelection(linewise: true); restoredScroll.move(.bottom)
        restoredScroll.copySelection(to: pasteboard)
        XCTAssertFalse(pasteboard.string(forType: .string)?.contains("real-row-5000") == true, "Zero history should not replay old scrollback")
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains("REAL-BURST-DONE") == true)
        client.settings.historyLines = HerdrSettings.defaultHistoryLines

        workspace!.toggleSidebar(nil)
        let sidebarID = try XCTUnwrap(workspace!.debugSidebarPaneIDs.first)
        let sidebarPane = try XCTUnwrap(workspace!.debugSidebarPane(sidebarID) as? TerminalPaneController)
        let sidebarSession = try XCTUnwrap(sidebarPane.herdrSession)
        let sidebarTerminal = try XCTUnwrap(descendants(sidebarPane.hostView).compactMap { $0 as? TerminalView }.first)
        workspace!.view.layoutSubtreeIfNeeded(); sidebarTerminal.fitToSize()
        try await waitFor { sidebarSession.state == .live }
        let sidebarBinding = try XCTUnwrap(sidebarSession.binding)
        XCTAssertEqual(sidebarBinding.coreID, binding.coreID)
        XCTAssertNil(sidebarBinding.remote)
        workspace!.debugFocusSidebarPane(sidebarID)
        workspace!.debugSetFocusedPaneName("Sidebar shell")
        XCTAssertTrue(sidebarTerminal.paste(text: #"printf 'SIDEBAR-%s-OK\n' CORE; printf '\033]7501;state=done:app=codex:msg=U2lkZWJhciByZWFkeQ==\033\\'"#))
        XCTAssertTrue(sidebarTerminal.sendKey(.enter))
        try await waitFor { sidebarTerminal.readScreenText()?.contains("SIDEBAR-CORE-OK") == true }
        try await waitFor { client.agents.messages.contains { $0.binding == sidebarBinding && $0.body == "Sidebar ready" } }
        XCTAssertEqual(client.agents.context?(sidebarBinding), "Sidebar › Sidebar shell")
        workspace!.newTerminalPane(nil)
        let sidebarSplitID = try XCTUnwrap(workspace!.debugSidebarFocusedPaneID)
        let sidebarSplit = try XCTUnwrap(workspace!.debugSidebarPane(sidebarSplitID) as? TerminalPaneController)
        try await waitFor { sidebarSplit.herdrSession?.state == .live }
        let sidebarSplitBinding = try XCTUnwrap(sidebarSplit.herdrSession?.binding)
        XCTAssertNotEqual(sidebarSplitBinding, sidebarBinding)
        workspace!.debugPerformClosePane(withID: sidebarSplitID)
        try await waitFor { workspace!.debugSidebarPane(sidebarSplitID) == nil }
        let sidebarSplitFinished = try await client.terminal(sidebarSplitBinding)
        XCTAssertEqual(sidebarSplitFinished.state, "finished")
        workspace!.toggleSidebar(nil)
        let sidebarBefore = try await client.terminal(sidebarBinding)
        XCTAssertEqual(sidebarBefore.state, "live")

        workspace!.selectWorkspace(local)
        XCTAssertEqual(workspace!.savedWorkspace().workspaceKind, nil)
        let stillRunning = try await client.terminal(binding)
        XCTAssertEqual(stillRunning.state, "live")
        XCTAssertEqual(stillRunning.address, before.address)
        let saved = workspace!.savedWorkspace()
        try saved.validate()
        XCTAssertEqual(saved.sidebar?.tab.panes.first?.herdr, sidebarBinding)
        window.contentView = nil; workspace = nil

        workspace = WorkspaceViewController()
        workspace!.herdrCoreClient = client
        workspace!.debugLoadForTesting()
        try workspace!.restoreWorkspace(saved)
        let herdrID = try XCTUnwrap(workspace!.debugWorkspaceEntries.first { $0.kind == .herdr }?.reference)
        workspace!.selectWorkspace(herdrID)
        window.contentView = workspace!.view
        workspace!.viewDidAppear()
        workspace!.view.layoutSubtreeIfNeeded()
        let restoredTerminal = try XCTUnwrap(descendants(workspace!.view).compactMap { $0 as? TerminalView }
            .first { ($0.delegate as? TerminalPaneController)?.id == paneID })
        restoredTerminal.fitToSize()
        try await waitFor { restoredTerminal.readScreenText()?.contains("REAL-BURST-DONE") == true }
        XCTAssertEqual(workspace!.savedWorkspace().tabs.first?.panes.first?.herdr, binding)
        XCTAssertFalse(workspace!.debugSidebarVisible)
        let mainTabs = workspace!.debugTabIDs
        workspace!.navigateToAgent(sidebarBinding)
        try await waitFor { workspace!.debugSidebarFocused && workspace!.debugSidebarVisible }
        XCTAssertEqual(workspace!.debugSidebarFocusedPaneID, sidebarID)
        XCTAssertEqual(workspace!.debugSelectedWorkspace, herdrID)
        XCTAssertEqual(workspace!.debugTabIDs, mainTabs, "A sidebar agent must reuse its pane instead of opening a viewer tab")
        let restoredSidebarPane = try XCTUnwrap(workspace!.debugSidebarPane(sidebarID) as? TerminalPaneController)
        let restoredSidebarSession = try XCTUnwrap(restoredSidebarPane.herdrSession)
        let restoredSidebarTerminal = try XCTUnwrap(descendants(restoredSidebarPane.hostView).compactMap { $0 as? TerminalView }.first)
        workspace!.view.layoutSubtreeIfNeeded(); restoredSidebarTerminal.fitToSize()
        try await waitFor { restoredSidebarSession.state == .live && restoredSidebarTerminal.readScreenText()?.contains("SIDEBAR-CORE-OK") == true }
        let sidebarAfter = try await client.terminal(sidebarBinding)
        XCTAssertEqual(sidebarAfter.pid, sidebarBefore.pid)
        try await client.reconnect()
        try await waitFor { restoredSidebarSession.state == .live }
        XCTAssertEqual(restoredSidebarSession.binding, sidebarBinding)
        workspace!.debugPerformClosePane(withID: sidebarID)
        try await waitFor { workspace!.debugSidebarPaneIDs.isEmpty }
        let sidebarFinished = try await client.terminal(sidebarBinding)
        XCTAssertEqual(sidebarFinished.state, "finished")
        XCTAssertFalse(workspace!.debugSidebarVisible)
        workspace!.closeLocalWorkspace(herdrID)
        try await waitFor { workspace!.debugSelectedWorkspace == local }
        let finished = try await client.terminal(binding)
        XCTAssertEqual(finished.state, "finished")
    }
}
