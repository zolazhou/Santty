import Foundation
import GhosttyVt
import XCTest
@testable import Santty

/// Two owned local cores connected through hc's real machine proxy. This tests
/// remote routing/identity without touching a user's machine profile or SSH.
@MainActor
final class NativeRemoteSessionTests: XCTestCase {
    private func wait(_ stage: String, _ condition: () throws -> Bool) async throws {
        for _ in 0..<800 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Private remote fixture timed out: \(stage)")
        throw HerdrCoreError("Private remote fixture timed out", kind: "test")
    }

    private func text(_ driver: GhosttyVTDriver) throws -> String {
        let frame = try driver.snapshot(topRow: max(0, driver.totalRows - driver.rows))
        return frame.rows.sorted { $0.key < $1.key }.map { $0.value.cells.compactMap(\.text).joined() }.joined(separator: "\n")
    }

    func testNativeRemoteProxyMouseAndReconnectKeepIdentityAndDoNotReplayInput() async throws {
        let fixture: PrivateProxyFixture
        do { fixture = try PrivateProxyFixture() }
        catch let error as HerdrCoreError where error.kind == "not_installed" { throw XCTSkip("hc is required") }
        defer { fixture.cleanup() }
        _ = try await fixture.command(fixture.remote, ["server", "start"])
        try fixture.verifySocket(fixture.remote)
        _ = try await fixture.command(fixture.local, ["server", "start"])
        try fixture.verifySocket(fixture.local)
        let via = fixture.root.appendingPathComponent("via.sh")
        let values = fixture.remote.sorted { $0.key < $1.key }.map { PrivateProxyFixture.quote($0.key + "=" + $0.value) }.joined(separator: " ")
        try ("#!/bin/sh\nexec env -i " + values + " sh -c \"$1\"\n").write(to: via, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: via.path)
        let added = try await fixture.command(fixture.local, ["machine", "add", "--name", "private-test", "--via", PrivateProxyFixture.quote(via.path)])
        let machine = try JSONDecoder().decode(HerdrRemote.self, from: added)
        let domain = "SanttyTerminalLab.Remote.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let client = HerdrCoreClient(executable: fixture.executable, environment: fixture.local, settings: HerdrSettings(defaults: defaults))
        let driver = try GhosttyVTDriver(columns: 120, rows: 30)
        let owner = try NativeTerminalPaneSession.herdr(paneID:UUID(),driver:driver,client:client,
            workingDirectory:nil,binding:nil,remote:machine,controlSocketPath:fixture.root.appendingPathComponent("local-control-must-not-export.sock").path,
            beforeRun:{ })
        let output = owner.output, session = try XCTUnwrap(owner.herdrSession)
        var resets = 0, wasLive = false, checkedOffline = false
        owner.onReset = { resets += 1 }
        owner.onChange = { [weak session] in
            guard let session else { return }
            if session.state == .live { wasLive = true }
            else if wasLive, !checkedOffline {
                checkedOffline = true
                XCTAssertFalse((try? output.sendText("MUST-NOT-REPLAY")) == true)
            }
        }
        try owner.startIfNeeded(viewport:.init(columns:120,rows:30))
        do {
            try await wait("remote attach") { session.state == .live }
            let binding = try XCTUnwrap(session.binding)
            XCTAssertEqual(binding.coreID, machine.id)
            XCTAssertEqual(binding.remote, true)
            let initial = try await client.terminal(binding)
            let pid = try XCTUnwrap(initial.pid)
            XCTAssertTrue(try output.sendText("printf 'NATIVE-REMOTE-%s\\n' FIRST\r"))
            try await wait("remote parsed output") { try text(driver).contains("NATIVE-REMOTE-FIRST") }
            // Escaped shell quotes were a false presence check; independent
            // probe-adapter-shell-policy.py preserves that original control.
            XCTAssertTrue(try output.sendText(#"if [ -z "${SANTTY_CONTROL_SOCKET+x}" ]; then printf 'REMOTE-SOCKET-%s\n' ABSENT; else printf 'REMOTE-SOCKET-%s\n' PRESENT; fi"# + "\r"))
            try await wait("remote does not receive local control socket") { try text(driver).contains("REMOTE-SOCKET-ABSENT") }
            // A real remote PTY reads the encoded mouse packet; no screen-text
            // inference is used to decide whether input was delivered.
            let readMouse = #"stty -echo -icanon min 1 time 0; printf '\033[?1000h\033[?1006hREMOTE-MOUSE-%s\n' READY; dd bs=1 count=9 2>/dev/null | od -An -tx1; stty sane; printf '\033[?1000lREMOTE-MOUSE-%s\n' DONE"#
            XCTAssertTrue(try output.sendText(readMouse + "\r"))
            try await wait("remote mouse ready") { try text(driver).contains("REMOTE-MOUSE-READY") && driver.pointerModes.tracking && driver.renderHoldRemaining == nil }
            let mouse = NativeMouseInput(action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_LEFT,
                modifiers: 0, position: CGPoint(x: 15, y: 25), cell: CGSize(width: 10, height: 20), scale: 1,
                anyButton: true, modes: try driver.pointerModes)
            XCTAssertTrue(try output.send(.mouse(mouse)))
            try await wait("remote received mouse bytes") {
                try text(driver).split(whereSeparator: \.isWhitespace).joined(separator: " ").contains("1b 5b 3c 30 3b 32 3b 32 4d")
            }
            try await wait("remote reader finished") { try text(driver).contains("REMOTE-MOUSE-DONE") }
            try driver.selectAll()
            XCTAssertNotNil(try driver.selectedText())
            try await client.reconnect() // replace only the viewer transport
            try await wait("native remote restore") { session.state == .live && resets >= 2 }
            XCTAssertEqual(session.binding, binding)
            let restored = try await client.terminal(binding)
            XCTAssertEqual(restored.pid, pid)
            XCTAssertNil(try driver.selectedText())
            XCTAssertTrue(checkedOffline)
            XCTAssertTrue(try output.sendText("printf 'NATIVE-REMOTE-%s\\n' RECONNECTED\r"))
            try await wait("remote input after reconnect") { try text(driver).contains("NATIVE-REMOTE-RECONNECTED") }
            XCTAssertFalse(try text(driver).contains("MUST-NOT-REPLAY"))
            let viewerDriver = try GhosttyVTDriver(columns: 120, rows: 30)
            let viewerOwner = try NativeTerminalPaneSession.herdr(paneID:UUID(),driver:viewerDriver,client:client,
                workingDirectory:nil,binding:binding,remote:machine,viewerOnly:true,beforeRun:{ XCTFail("Remote viewer must not run") })
            let viewer = try XCTUnwrap(viewerOwner.herdrSession)
            try viewerOwner.startIfNeeded(viewport:.init(columns:120,rows:30))
            try await wait("remote viewer-only attach") { viewer.state == .live }
            try await viewerOwner.close(.terminate)
            XCTAssertNil(viewerOwner.localSession)
            guard case let .herdr(_,remote) = owner.directoryForNewPane else { throw CLIError("Lost typed remote directory") }
            XCTAssertEqual(remote?.id,machine.id)
            let afterDetach = try await client.terminal(binding)
            XCTAssertEqual(afterDetach.pid, pid)
            XCTAssertEqual(afterDetach.state, "live")
            try await owner.close(.terminate)
        } catch {
            try? await owner.close(.terminate)
            throw error
        }
    }
}

private struct PrivateProxyFixture {
    let root: URL
    let executable: URL
    let local: [String: String]
    let remote: [String: String]

    init() throws {
        executable = try HerdrCoreTransport.executable()
        root = URL(fileURLWithPath: "/tmp/santty-proxy-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let base = root, cli = executable
        func env(_ name: String) throws -> [String: String] {
            let dir = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return ["PATH": cli.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/bin:/bin",
                    "SHELL": "/bin/sh", "HOME": dir.path, "HC_SESSION": "native-proxy-test",
                    "HC_SOCKET": dir.appendingPathComponent("core.sock").path, "XDG_RUNTIME_DIR": dir.path,
                    "XDG_STATE_HOME": dir.appendingPathComponent("state").path,
                    "XDG_CONFIG_HOME": dir.appendingPathComponent("config").path]
        }
        local = try env("local"); remote = try env("remote")
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func run(_ env: [String: String], _ args: [String]) throws -> (Int32, Data) {
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = ["--json"] + args; process.environment = env
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    func command(_ env: [String: String], _ args: [String]) async throws -> Data {
        let (status, data) = try await Task.detached { try run(env, args) }.value
        guard status == 0 else { throw HerdrCoreError("Private proxy command failed", kind: "test") }
        return data
    }

    func verifySocket(_ environment: [String: String]) throws {
        guard let socket = environment["HC_SOCKET"], socket.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: socket) else {
            throw HerdrCoreError("Private core socket was not created; refusing mutations", kind: "isolation")
        }
    }

    func cleanup() {
        // Enumerate/kill only these two private cores; never the default socket.
        for env in [local, remote] {
            guard (try? verifySocket(env)) != nil else { continue }
            if let (_, data) = try? run(env, ["ls", "--all"]),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let terminals = object["terminals"] as? [[String: Any]] {
                for terminal in terminals {
                    if let address = terminal["address"] as? String, !address.contains("/") { _ = try? run(env, ["kill", address]) }
                }
            }
            _ = try? run(env, ["server", "stop"])
        }
        try? FileManager.default.removeItem(at: root)
    }
}
