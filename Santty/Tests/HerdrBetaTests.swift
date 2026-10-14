import AppKit
import Darwin
import GhosttyTerminal
import XCTest
@testable import Santty

@MainActor
final class HerdrBetaTests: XCTestCase {
    private func executable(_ script: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(UUID().uuidString)
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    func testAbsoluteDiscoveryAndVersionBoundary() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-beta-\(UUID())")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let valid = try executable("printf 'herdr 0.9.3\\n'", in: bin)
        let installed = bin.appendingPathComponent("herdr")
        try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: valid)
        XCTAssertEqual(HerdrExecutable.suggestedPath(home: home), installed.path)
        let version = try await Task.detached { try HerdrExecutable.version(at: installed) }.value
        XCTAssertEqual(version, "0.9.3")
        XCTAssertThrowsError(try HerdrEndpoint(binary: bin, session: "default", socketPath: "/tmp/valid.sock").validate())
        XCTAssertThrowsError(try HerdrEndpoint(binary: installed, session: "../wrong", socketPath: "/tmp/valid.sock").validate())
        XCTAssertThrowsError(try HerdrEndpoint(binary: installed, session: "default", socketPath: "relative.sock").validate())
        let newer = try executable("printf 'herdr 0.9.4\\n'", in: bin)
        let newerVersion = try await Task.detached { try HerdrExecutable.version(at: newer) }.value
        XCTAssertEqual(newerVersion, "0.9.4", "Compatibility is negotiated by the endpoint, not the release string")
        for script in ["printf 'not-herdr\\n'", "exec /usr/bin/yes bad", "exec >&- 2>&-; exec /bin/sleep 5"] {
            let binary = try executable(script, in: bin)
            do { _ = try await Task.detached { try HerdrExecutable.version(at: binary) }.value; XCTFail("Invalid or hung client accepted") } catch {}
        }

    }

    func testQueriesNeverLaunchTheConfiguredExecutable() async throws {
        let service = HerdrWorkspaceTests.Service(); try await service.start("mirror"); defer { service.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-version-cache-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let count = directory.appendingPathComponent("probes")
        let binary = try executable("printf 'probe\\n' >> '\(count.path)'; printf 'herdr 0.9.3\\n'", in: directory)
        let client = HerdrWorkspaceClient(endpoint: .init(binary: binary, session: "default", socketPath: service.path))
        _ = try await client.snapshot()
        _ = try await client.snapshot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: count.path))
        let before = try XCTUnwrap(try service.state()["requests"] as? [String])
        try Data("#!/bin/sh\nprintf 'herdr 0.9.4\\n'\n".utf8).write(to: binary)
        _ = try await client.snapshot()
        XCTAssertGreaterThan((try service.state()["requests"] as? [String] ?? []).count, before.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: count.path))
    }

    func testFastVersionProbeDoesNotWaitAgainAfterExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-fast-probe-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try executable("printf 'herdr 0.9.3\\n'", in: directory)
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            _ = try await Task.detached { try HerdrExecutable.version(at: binary) }.value
            samples.append(ProcessInfo.processInfo.systemUptime - start)
        }
        // Five probes reduce scheduler noise; a completed-process wait alone costs about 63 ms here.
        XCTAssertLessThan(samples.sorted()[2], 0.05, "A quick version reply must not add a completed-process run-loop wait")
    }


    func testLatencySamplesAreBoundedAndIgnoreInvalidDurations() throws {
        var samples = HerdrShellLatencySamples()
        for seconds in [Double.nan, .infinity, -1] { samples.record(seconds: seconds) }
        XCTAssertEqual(samples.summary.sampleCount, 0)
        XCTAssertNil(samples.summary.p50Milliseconds)
        samples.record(seconds: 0.001)
        XCTAssertEqual(samples.summary.sampleCount, 1)
        XCTAssertEqual(try XCTUnwrap(samples.summary.lastMilliseconds), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(samples.summary.p99Milliseconds), 1, accuracy: 0.0001)
        for milliseconds in 0..<1200 { samples.record(seconds: Double(milliseconds) / 1000) }
        let summary = samples.summary
        XCTAssertEqual(summary.sampleCount, 1024)
        XCTAssertEqual(try XCTUnwrap(summary.lastMilliseconds), 1199, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.p50Milliseconds), 687, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.p95Milliseconds), 1148, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.p99Milliseconds), 1189, accuracy: 0.0001)
        XCTAssertEqual(HerdrDiagnosticError.summary("Ghostty image 1: SECRET_IMAGE_ERROR"), "Local terminal image upload failed")
        XCTAssertEqual(HerdrDiagnosticError.summary("SECRET cache exceeds budget"), "ClientShell resource limit exceeded")
    }





}
