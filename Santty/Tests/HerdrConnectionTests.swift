import Foundation
import XCTest
@testable import Santty

final class HerdrConnectionTests: XCTestCase {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/herdr-stage1-fixture.py")
    }

    func testClientShellManagementCompatibilityDoesNotRequirePrivateClientBuildMatch() {
        XCTAssertNoThrow(try HerdrServerInfo(version: "0.9.4", protocolVersion: 22).validate())
        XCTAssertNoThrow(try HerdrServerInfo(version: "0.9.4", protocolVersion: 22).validate())
        XCTAssertThrowsError(try HerdrServerInfo(version: "0.9.4", protocolVersion: 23).validate())
        XCTAssertThrowsError(try HerdrServerInfo(version: "", protocolVersion: 22).validate())
        XCTAssertThrowsError(try HerdrServerInfo(version: "bad\0version", protocolVersion: 22).validate())
    }

    func testManagementFramingValidationAndCompatibility() throws {
        var decoder = HerdrLineDecoder()
        XCTAssertTrue(try decoder.append(Data("{\"id\":\"x\",".utf8)).isEmpty)
        let lines = try decoder.append(Data("\"result\":{\"type\":\"pong\",\"version\":\"0.9.3\",\"protocol\":22}}\n{\"event\":\"future\"}\n".utf8))
        XCTAssertEqual(lines.count, 2)
        let result = try JSONDecoder().decode(HerdrAPIEnvelope.self, from: lines[0]).response(to: "x")
        XCTAssertEqual(result.protocol, 22)
        XCTAssertThrowsError(try JSONDecoder().decode(HerdrAPIEnvelope.self, from: lines[0]).response(to: "other"))
        try decoder.finish()
        _ = try decoder.append(Data("{".utf8))
        XCTAssertThrowsError(try decoder.finish())
        XCTAssertThrowsError(try decoder.append(Data(repeating: 65, count: HerdrLineDecoder.maximumBytes)))
        XCTAssertThrowsError(try HerdrServerInfo(version: "0.9.4", protocolVersion: 23).validate())
        let error = Data("{\"id\":\"x\",\"error\":{\"code\":\"invalid_request\",\"message\":\"fixture\"}}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(HerdrAPIEnvelope.self, from: error).response(to: "x"))
    }









    func testManagementSubscribeSnapshotRefreshAndReconnect() throws {
        let path = "/tmp/herdr-test-\(UUID().uuidString).sock"
        let process = Process()
        process.executableURL = fixture
        process.arguments = ["api", path]
        try process.run()
        defer { process.terminate(); process.waitUntilExit(); try? FileManager.default.removeItem(atPath: path) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: path) { Thread.sleep(forTimeInterval: 0.01) }
        _ = try HerdrConnection.preflight(socketPath: path)
        let first = expectation(description: "subscribed before initial snapshot")
        let updated = expectation(description: "event refresh")
        let reconnected = expectation(description: "fresh reconnect snapshot")
        let connection = HerdrConnection(socketPath: path, snapshot: { snapshot in
            switch snapshot.panes.first?.terminal_id {
            case "term_1": first.fulfill()
            case "term_2": updated.fulfill()
            case "term_3": reconnected.fulfill()
            default: break
            }
        }, state: { _ in })
        defer { connection.disconnect() }
        connection.connect()
        wait(for: [first, updated], timeout: 5)
        connection.connect()
        wait(for: [reconnected], timeout: 5)
        connection.disconnect()
        connection.disconnect()
    }

    func testDisconnectSuppressesInFlightSnapshot() throws {
        let path = "/tmp/herdr-test-\(UUID().uuidString).sock"
        let process = Process()
        process.executableURL = fixture
        process.arguments = ["api", path, "slow"]
        try process.run()
        defer {
            process.terminate(); process.waitUntilExit()
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".reading")
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: path) { Thread.sleep(forTimeInterval: 0.01) }
        let stale = expectation(description: "stale snapshot must be suppressed")
        stale.isInverted = true
        let connection = HerdrConnection(socketPath: path, snapshot: { _ in stale.fulfill() }, state: { _ in })
        connection.connect()
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: path + ".reading") { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".reading"))
        connection.disconnect()
        wait(for: [stale], timeout: 0.6)
    }


    func testLiveExternalManagementWithoutMutations() throws {
        guard ProcessInfo.processInfo.environment["SANTTY_HERDR_TARGET"] != nil else {
            throw XCTSkip("Explicit external-test authorization required")
        }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/herdr/herdr.sock").path
        let info = try HerdrConnection.preflight(socketPath: path)
        XCTAssertEqual(info.protocolVersion, 22)
        let snapshot = expectation(description: "live read-only snapshot")
        let connection = HerdrConnection(socketPath: path, snapshot: { state in
            XCTAssertTrue(state.panes.contains { $0.pane_id == "w5:p2" })
            snapshot.fulfill()
        }, state: { _ in })
        connection.connect()
        wait(for: [snapshot], timeout: 5)
        connection.disconnect()
    }
}
