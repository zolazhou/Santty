import AppKit
import XCTest
@testable import Santty

@MainActor
final class HerdrSettingsTests: XCTestCase {
    func testPreferencesValidateAndPersistWithoutChangingOtherSettings() throws {
        let suite = "HerdrSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = HerdrSettings(defaults: defaults)
        XCTAssertNil(settings.executablePath)
        XCTAssertEqual(settings.historyLines, 2000)
        settings.historyLines = -1
        XCTAssertEqual(settings.historyLines, 0)
        settings.historyLines = Int.max
        XCTAssertEqual(settings.historyLines, 10_000)
        settings.historyLines = 500
        XCTAssertEqual(HerdrSettings(defaults: defaults).historyLines, 500)
        settings.saveExecutablePath("/usr/local/bin/hc")
        XCTAssertEqual(HerdrSettings(defaults: defaults).executablePath, "/usr/local/bin/hc")
        settings.saveExecutablePath(nil)
        XCTAssertNil(settings.executablePath)
        XCTAssertNil(try HerdrSettings.executableURL(for: nil))
        XCTAssertThrowsError(try HerdrSettings.executableURL(for: "hc"))
        XCTAssertThrowsError(try HerdrSettings.executableURL(for: "/tmp"))
        XCTAssertThrowsError(try HerdrSettings.executableURL(for: "/missing/hc"))
        XCTAssertThrowsError(try HerdrSettings.executableURL(for: "/bin/sh\n"))
        XCTAssertEqual(try HerdrSettings.executableURL(for: "/bin/sh")?.path, "/bin/sh")
        let link = URL(fileURLWithPath: "/tmp/herdr-hc-link-\(UUID())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertEqual(try HerdrSettings.executableURL(for: link.path), link)
        let terminal = try XCTUnwrap(SettingsSection.allCases.firstIndex(of: .terminal))
        XCTAssertEqual(SettingsSection.allCases[terminal + 1], .herdr)
        XCTAssertEqual(SettingsSection.allCases[terminal + 2], .keybindings)
        XCTAssertEqual(SettingsSection.herdr.title, "Herdr")
    }

    func testExecutableApplyIsTransactionalReconnectKeepsProgramsAndRejectsOtherCore() async throws {
        let executable: URL
        do { executable = try HerdrCoreTransport.executable() }
        catch { throw XCTSkip("hc is required for the real settings integration test") }
        let root = URL(fileURLWithPath: "/tmp/santty-hc-settings-\(UUID().uuidString.prefix(8))")
        let suite = "HerdrSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = HerdrSettings(defaults: defaults)
        func environment(_ name: String) throws -> [String: String] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HC_") }
            env["HC_SESSION"] = "probe"; env["HC_SOCKET"] = directory.appendingPathComponent("core.sock").path
            env["XDG_STATE_HOME"] = directory.appendingPathComponent("state").path
            env["XDG_CONFIG_HOME"] = directory.appendingPathComponent("config").path; env["XDG_RUNTIME_DIR"] = directory.path
            env["SETTINGS_TEST_SECRET"] = "environment-must-not-be-copied"
            return env
        }
        let first = try environment("first"), second = try environment("second")
        defer {
            for env in [first, second] {
                let stop = Process(); stop.executableURL = executable; stop.arguments = ["server", "stop"]; stop.environment = env
                stop.standardOutput = FileHandle.nullDevice; stop.standardError = FileHandle.nullDevice
                if (try? stop.run()) != nil { stop.waitUntilExit() }
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func wrapper(_ name: String, _ body: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let client = HerdrCoreClient(executable: executable, environment: first, settings: settings)
        let connection = try await client.connection()
        let terminal: HerdrCoreTerminal = try await HerdrCoreClient.request(connection, "terminal.run",
            ["argv": ["/bin/cat"], "no_parent": true, "cwd": root.path])
        let binding = HerdrTerminalBinding(coreID: connection.hello.core.id, address: terminal.address)
        XCTAssertEqual(client.details?.executablePath, executable.path)
        XCTAssertNotNil(client.details?.version)

        let bad = try wrapper("incompatible-hc", "printf '%s\\n' '{\"error\":{\"message\":\"TOKEN=private-error-must-not-be-copied\",\"data\":{\"kind\":\"needs_update\"}}}'")
        do { try await client.applyExecutablePath(bad.path); XCTFail("An incompatible binary must not be applied") }
        catch { XCTAssertEqual((error as? HerdrCoreError)?.kind, "needs_update") }
        let unchanged = try await client.connection()
        XCTAssertTrue(unchanged === connection)
        XCTAssertNil(settings.executablePath)
        XCTAssertEqual(client.configuredExecutablePath, executable.path)
        XCTAssertTrue(client.diagnosticText.contains("needs_update"))
        XCTAssertFalse(client.diagnosticText.contains("private-error-must-not-be-copied"))
        XCTAssertFalse(client.diagnosticText.contains("environment-must-not-be-copied"))
        do { try await client.applyExecutablePath("/missing/hc"); XCTFail("Missing executable accepted") }
        catch { XCTAssertEqual((error as? HerdrCoreError)?.kind, "invalid_executable") }
        let afterInvalidPath = try await client.connection()
        XCTAssertTrue(afterInvalidPath === connection)

        try await client.reconnect()
        let reconnected = try await client.connection()
        XCTAssertFalse(reconnected === connection)
        let afterReconnect = try await client.terminal(binding)
        XCTAssertEqual(afterReconnect.pid, terminal.pid)
        XCTAssertEqual(afterReconnect.state, "live")
        let good = try wrapper("hc with spaces", "exec " + quote(executable.path) + " \"$@\"")
        try await client.applyExecutablePath(good.path)
        XCTAssertEqual(settings.executablePath, good.path)
        XCTAssertEqual(client.details?.executablePath, good.path)
        let afterApply = try await client.terminal(binding)
        XCTAssertEqual(afterApply.pid, terminal.pid)

        let other = HerdrCoreClient(executable: executable, environment: second, settings: settings)
        let otherConnection = try await other.connection()
        let foreign: HerdrCoreTerminal = try await HerdrCoreClient.request(otherConnection, "terminal.run",
            ["argv": ["/bin/cat"], "no_parent": true, "cwd": root.path])
        XCTAssertEqual(foreign.address, terminal.address, "Fixture must collide on terminal address")
        var wrongRecordReceived = false
        var identityChanged = false
        let observer = UUID()
        client.observe(binding, id: observer) { record, error in
            wrongRecordReceived = wrongRecordReceived || record?.pid == foreign.pid
            identityChanged = identityChanged || error?.kind == "identity_changed"
        }
        defer { client.removeObserver(observer) }
        let pairs = ["HC_SESSION", "HC_SOCKET", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR"]
        let alternate = try wrapper("other-hc", "exec env " + pairs.map { quote($0 + "=" + second[$0]!) }.joined(separator: " ") + " " + quote(executable.path) + " \"$@\"")
        try await client.applyExecutablePath(alternate.path)
        XCTAssertTrue(identityChanged)
        XCTAssertFalse(wrongRecordReceived, "A different core's t1 must never be applied to the saved binding")
        do { _ = try await client.terminal(binding); XCTFail("Different core accepted") }
        catch { XCTAssertEqual((error as? HerdrCoreError)?.kind, "identity_changed") }
        let originalReader = HerdrCoreClient(executable: executable, environment: first, settings: settings)
        let originalRecord = try await originalReader.terminal(binding)
        XCTAssertEqual(originalRecord.pid, terminal.pid)
        XCTAssertEqual(originalRecord.state, "live")
        try await client.applyExecutablePath(nil)
        XCTAssertNil(settings.executablePath)
        XCTAssertNil(client.configuredExecutablePath)
        let automatic = try await client.terminal(binding)
        XCTAssertEqual(automatic.pid, terminal.pid)
        try await client.kill(binding)
        try await other.kill(.init(coreID: otherConnection.hello.core.id, address: foreign.address))
    }
}
