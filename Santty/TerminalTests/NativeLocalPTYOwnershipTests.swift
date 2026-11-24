import Darwin
import Foundation
import XCTest
@testable import Santty

final class NativeLocalPTYLaunchPolicyTests: XCTestCase {
    private func context(environment: [String: String] = [:]) -> NativeLocalPTYUserContext {
        .init(loginShell: "/owned/profile/bin/zsh", homeDirectory: "/owned/profile/home",
              environment: environment, locale: Locale(identifier: "zh_HK"), preferredLanguages: ["zh-Hant-HK", "en-US"])
    }

    func testProductionPolicyKeepsUserContextAndOverridesOnlyLocalTerminalFacts() throws {
        let id = UUID()
        let env = ["HOME":"/wrong/parent", "SHELL":"/bin/sh", "PATH":"/owned/tools:/usr/bin",
                   "CUSTOM_USER_TOKEN":"synthetic", "XDG_CONFIG_HOME":"/owned/config", "ZDOTDIR":"/owned/zsh",
                   "SSH_AUTH_SOCK":"/owned/agent.sock", "SANTTY_PANE_ID":"stale", "SANTTY_CONTROL_SOCKET":"stale",
                   "COLUMNS":"1", "LINES":"1", "GHOSTTY_RESOURCES_DIR":"/obsolete", "GHOSTTY_BIN_DIR":"/obsolete"]
        let launch = try NativeLocalPTYLaunch.productionLocal(paneID: id, controlSocket: "/owned/control.sock",
            context: context(environment: env), workingDirectory: "/owned/cwd space", appVersion: "test")
        XCTAssertEqual(launch.paneID, id); XCTAssertEqual(launch.executable, "/owned/profile/bin/zsh")
        XCTAssertEqual(launch.execName, "-zsh"); XCTAssertEqual(launch.arguments, ["-i"])
        XCTAssertEqual(launch.workingDirectory, "/owned/cwd space")
        XCTAssertEqual(launch.environment["HOME"], "/owned/profile/home")
        XCTAssertEqual(launch.environment["SHELL"], launch.executable)
        XCTAssertEqual(launch.environment["PWD"], launch.workingDirectory)
        for key in ["PATH", "CUSTOM_USER_TOKEN", "XDG_CONFIG_HOME", "ZDOTDIR", "SSH_AUTH_SOCK"] { XCTAssertEqual(launch.environment[key], env[key]) }
        XCTAssertEqual(launch.environment["SANTTY_PANE_ID"], id.uuidString)
        XCTAssertEqual(launch.environment["SANTTY_CONTROL_SOCKET"], "/owned/control.sock")
        XCTAssertEqual(launch.environment["TERM"], "xterm-256color")
        XCTAssertEqual(launch.environment["TERM_PROGRAM"], "Santty")
        XCTAssertEqual(launch.environment["TERM_PROGRAM_VERSION"], "test")
        for key in ["COLUMNS", "LINES", "GHOSTTY_RESOURCES_DIR", "GHOSTTY_BIN_DIR"] { XCTAssertNil(launch.environment[key]) }
        XCTAssertEqual(launch.environment["LANG"], "zh_HK.UTF-8")
        XCTAssertEqual(launch.environment["LANGUAGE"], "zh_HK.UTF-8:en_US.UTF-8")
        XCTAssertEqual(env["HOME"], "/wrong/parent", "no mutation of caller or global environment")
    }

    func testHomeDefaultExplicitLocaleAndNoPrivateLabStartupDefaults() throws {
        let launch = try NativeLocalPTYLaunch.productionLocal(paneID: UUID(), controlSocket: "/owned/sock",
            context: context(environment: ["LANG":"fr_FR.UTF-8", "LANGUAGE":"custom", "LC_ALL":"C"]), appVersion: "test")
        XCTAssertEqual(launch.workingDirectory, "/owned/profile/home")
        XCTAssertEqual(launch.environment["LANG"], "fr_FR.UTF-8"); XCTAssertEqual(launch.environment["LANGUAGE"], "custom")
        XCTAssertEqual(launch.environment["LC_ALL"], "C")
        XCTAssertEqual(launch.environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertNil(launch.environment["XDG_CONFIG_HOME"]); XCTAssertNil(launch.environment["TMPDIR"])
        XCTAssertNotEqual(launch.environment["TERM_PROGRAM"], "SanttyTerminalLab")
    }

    func testMissingLocaleRegionStillHasAnExplicitUTF8ChildFallback() throws {
        let context = NativeLocalPTYUserContext(loginShell: "/owned/shell", homeDirectory: "/owned/home", environment: [:],
            locale: Locale(identifier: "en"), preferredLanguages: [])
        let launch = try NativeLocalPTYLaunch.productionLocal(paneID: UUID(), controlSocket: "/owned/sock", context: context, appVersion: "test")
        XCTAssertEqual(launch.environment["LANG"], "en_US.UTF-8")
    }

    func testValidatedExecContextRefusesNULRelativePathsAndInvalidEnvironmentKeys() throws {
        let id = UUID()
        for (executable, cwd, name, env, args) in [
            ("sh", "/owned", nil, [:], [String]()),
            ("/bin/sh", "relative", nil, [:], []),
            ("/bin/sh", "/owned", "", [:], []),
            ("/bin/sh", "/owned", "bad\0name", [:], []),
            ("/bin/sh", "/owned", nil, ["bad=key":"x"], []),
            ("/bin/sh", "/owned", nil, ["":"x"], []),
            ("/bin/sh", "/owned", nil, ["key":"bad\0value"], []),
            ("/bin/sh", "/owned", nil, [:], ["bad\0arg"])
        ] as [(String, String, String?, [String:String], [String])] {
            XCTAssertThrowsError(try NativeLocalPTYLaunch(paneID: id, executable: executable, execName: name,
                arguments: args, environment: env, workingDirectory: cwd))
        }
        XCTAssertThrowsError(try NativeLocalPTYLaunch.productionLocal(paneID: id, controlSocket: "relative",
            context: context(), appVersion: "test"))
    }

    func testLocaleConversionRetainsPinnedIndependentNamesAndBounds() throws {
        for (tag, expected) in [("zh-Hans-SG", "zh_SG"), ("zh-Hant-HK", "zh_HK"), ("zh-Hant-MO", "zh_MO"),
                                ("zh-Hans-HK", "zh_CN"), ("sr-Latn", "sr@latin"), ("pa-Arab", "pa_PK"),
                                ("Brazilian Portuguese", "pt_BR"), ("en-US", "en_US"), ("Kazakh", "kk"),
                                ("Kazakh", "Kazakh")] {
            XCTAssertEqual(NativeLocalLocaleName.posix(tag), expected)
        }
        XCTAssertNil(NativeLocalLocale.values(languageCode: "en", countryCode: nil, preferredLanguages: []))
        XCTAssertNil(NativeLocalLocale.values(languageCode: String(repeating: "x", count: 128), countryCode: "US", preferredLanguages: []))
        let values = NativeLocalLocale.values(languageCode: "en", countryCode: "US", preferredLanguages: Array(repeating: "en-US", count: 200))
        XCTAssertEqual(values?.lang, "en_US.UTF-8"); XCTAssertNil(values?.language)
    }

    func testCurrentAccountSnapshotReadsOwnedStringsWithoutLaunchingOrLoggingUserEnvironment() throws {
        let snapshot = try NativeLocalPTYUserContext.current()
        XCTAssertTrue(snapshot.loginShell.hasPrefix("/")); XCTAssertTrue(snapshot.homeDirectory.hasPrefix("/"))
    }
}

@MainActor
private final class OwnedLocalPaneSlot {
    var current: NativeLocalPTYSession?
    var removals = 0
    init(_ session: NativeLocalPTYSession) { current = session }
    func target(_ session: NativeLocalPTYSession) -> NativeLocalPTYCloseBarrier.Target {
        .init(session: session, isCurrent: { [self] in current === session })
    }
}

@MainActor
final class NativeLocalPTYOwnershipTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let root: URL
        let home: URL
        let session: NativeLocalPTYSession
        var environment: [String:String] { ["HOME":home.path, "PATH":"/usr/bin:/bin", "LANG":"en_US.UTF-8", "TERM":"xterm-256color"] }
        func launch(_ script: String) throws -> NativeLocalPTYLaunch {
            try .init(paneID: session.paneID, executable: "/bin/sh", arguments: ["-c", script], environment: environment, workingDirectory: home.path)
        }
    }
    private let viewport = TerminalStreamViewport(columns: 120, rows: 30, cellWidthPixels: 8, cellHeightPixels: 16)
    private func fixture(paneID: UUID = UUID()) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("santty-owner-\(UUID())", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        return .init(root: root, home: home, session: NativeLocalPTYSession(paneID: paneID, driver: try GhosttyVTDriver()) { _ in })
    }
    private func dispose(_ fixture: Fixture) async throws {
        try await fixture.session.stop()
        try FileManager.default.removeItem(at: fixture.root)
    }
    private func wait(_ condition: () throws -> Bool) async throws {
        for _ in 0..<500 { if try condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Owned session condition timed out"); throw NativeLocalPTYError.shutdownTimeout
    }
    private let ignoringScript = "trap '' HUP TERM; printf OWNER-READY; while :; do sleep 1; done"

    func testReusableOwnerDoesNotOwnOrDeleteTheCallersHomeAndCannotRelaunch() async throws {
        let f = try fixture()
        do {
            try f.session.start(f.launch("printf 'OWNER-FINAL\\n'"), viewport: viewport)
            try await wait { if case .exited = f.session.state { return true }; return false }
            XCTAssertEqual(try f.session.output.driver.readScreenText(), "OWNER-FINAL")
            XCTAssertEqual(f.session.outputDrainComplete, true)
            try await f.session.stop()
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.home.path))
            XCTAssertThrowsError(try f.session.start(f.launch("printf must-not-run"), viewport: viewport))
            XCTAssertFalse(try f.session.output.sendText("must not replay"))
            try await dispose(f)
        } catch { try? await dispose(f); throw error }
    }

    func testProductionLaunchContextReachesAnOwnedExecProbeWithoutRunningUserProfiles() async throws {
        let f = try fixture()
        do {
            let source = f.root.appendingPathComponent("probe.c"), executable = f.root.appendingPathComponent("owned-login-shell")
            let code = """
            #include <stdio.h>
            #include <stdlib.h>
            #include <string.h>
            int main(int argc, char **argv) {
                if (argc != 2 || strcmp(argv[1], "-i") != 0) return 2;
                printf("ARGV0:%s\\nHOME:%s\\nPWD:%s\\nPANE:%s\\nSOCKET:%s\\nCUSTOM:%s\\n", argv[0], getenv("HOME"), getenv("PWD"), getenv("SANTTY_PANE_ID"), getenv("SANTTY_CONTROL_SOCKET"), getenv("OWNED_CONTEXT_TOKEN"));
                return 0;
            }
            """
            try code.write(to: source, atomically: true, encoding: .utf8)
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = ["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", source.path, "-o", executable.path]
            compiler.environment = ["PATH":"/usr/bin:/bin", "HOME":f.home.path, "TMPDIR":f.root.path]
            try compiler.run(); compiler.waitUntilExit()
            XCTAssertEqual(compiler.terminationStatus, 0)
            let socket = f.root.appendingPathComponent("owned-control.sock").path
            let context = NativeLocalPTYUserContext(loginShell: executable.path, homeDirectory: f.home.path,
                environment: ["PATH":"/usr/bin:/bin", "OWNED_CONTEXT_TOKEN":"synthetic-only"],
                locale: Locale(identifier: "en_US"), preferredLanguages: ["en-US"])
            let launch = try NativeLocalPTYLaunch.productionLocal(paneID: f.session.paneID, controlSocket: socket,
                context: context, appVersion: "test")
            try f.session.start(launch, viewport: viewport)
            try await wait { if case .exited = f.session.state { return true }; return false }
            let text = try f.session.output.driver.readScreenText()
            XCTAssertTrue(text.contains("ARGV0:-owned-login-shell"))
            XCTAssertTrue(text.contains("HOME:" + f.home.path)); XCTAssertTrue(text.contains("PWD:" + f.home.path))
            XCTAssertTrue(text.contains("PANE:" + f.session.paneID.uuidString))
            XCTAssertTrue(text.contains("SOCKET:" + socket)); XCTAssertTrue(text.contains("CUSTOM:synthetic-only"))
            try await dispose(f)
        } catch { try? await dispose(f); throw error }
    }

    func testWrongLaunchPaneIsRefusedBeforeResetOrFork() async throws {
        let f = try fixture()
        do {
            f.session.output.driver.feed("unchanged")
            let wrong = try NativeLocalPTYLaunch(paneID: UUID(), executable: "/bin/sh", arguments: [], environment: f.environment, workingDirectory: f.home.path)
            XCTAssertThrowsError(try f.session.start(wrong, viewport: viewport))
            XCTAssertEqual(f.session.state, .idle); XCTAssertNil(f.session.processInfo)
            XCTAssertEqual(try f.session.output.driver.readScreenText(), "unchanged")
            try await dispose(f)
        } catch { try? await dispose(f); throw error }
    }

    func testSynchronousAdmissionBarrierAndCoalescedStopsReapTheSameLaunch() async throws {
        let f = try fixture()
        do {
            try f.session.start(f.launch(ignoringScript), viewport: viewport)
            try await wait { try f.session.output.driver.readScreenText().contains("OWNER-READY") }
            f.session.beginClosing()
            XCTAssertEqual(f.session.state, .closing)
            XCTAssertFalse(try f.session.output.sendText("not admitted"))
            async let a: Void = f.session.stop(); async let b: Void = f.session.stop()
            try await a; try await b
            XCTAssertNil(f.session.processInfo)
            if case .exited = f.session.state {} else { XCTFail("must wait for reap, not only signal acceptance") }
            try await dispose(f)
        } catch { try? await dispose(f); throw error }
    }

    func testMultiOwnerBarrierRemovesOnlyAfterEveryOwnedLaunchIsClosed() async throws {
        let a = try fixture(), b = try fixture()
        let x = OwnedLocalPaneSlot(a.session), y = OwnedLocalPaneSlot(b.session)
        do {
            try a.session.start(a.launch(ignoringScript), viewport: viewport)
            try b.session.start(b.launch(ignoringScript), viewport: viewport)
            try await wait { try a.session.output.driver.readScreenText().contains("OWNER-READY") && b.session.output.driver.readScreenText().contains("OWNER-READY") }
            try await NativeLocalPTYCloseBarrier.close([x.target(a.session), y.target(b.session)]) {
                XCTAssertNil(a.session.processInfo); XCTAssertNil(b.session.processInfo)
                x.current = nil; y.current = nil; x.removals += 1; y.removals += 1
            }
            XCTAssertEqual(x.removals, 1); XCTAssertEqual(y.removals, 1)
            XCTAssertFalse(try a.session.output.sendText("no")); XCTAssertFalse(try b.session.output.sendText("no"))
            try await dispose(a); try await dispose(b)
        } catch { try? await dispose(a); try? await dispose(b); throw error }
    }

    func testReplacedPaneDuringAwaitIsNeverRemovedOrStoppedByOldClose() async throws {
        let f = try fixture()
        let replacement = try fixture(paneID: f.session.paneID)
        let slot = OwnedLocalPaneSlot(f.session)
        do {
            try f.session.start(f.launch(ignoringScript), viewport: viewport)
            try await wait { try f.session.output.driver.readScreenText().contains("OWNER-READY") }
            let close = Task { try await NativeLocalPTYCloseBarrier.close([slot.target(f.session)]) { slot.removals += 1; slot.current = nil } }
            try await wait { f.session.state == .closing }
            slot.current = replacement.session
            do { try await close.value; XCTFail("stale close must fail") }
            catch let error as NativeLocalPTYCloseBarrier.Failure { XCTAssertEqual(error, .paneChanged) }
            XCTAssertTrue(slot.current === replacement.session); XCTAssertEqual(slot.removals, 0)
            XCTAssertEqual(replacement.session.state, .idle)
            try await dispose(f); try await dispose(replacement)
        } catch { try? await dispose(f); try? await dispose(replacement); throw error }
    }

    func testCancelledCloseFinishesOwnedCleanupButRetainsLayout() async throws {
        let f = try fixture(), slot: OwnedLocalPaneSlot
        slot = OwnedLocalPaneSlot(f.session)
        do {
            try f.session.start(f.launch(ignoringScript), viewport: viewport)
            try await wait { try f.session.output.driver.readScreenText().contains("OWNER-READY") }
            let close = Task { try await NativeLocalPTYCloseBarrier.close([slot.target(f.session)]) { slot.removals += 1 } }
            try await wait { f.session.state == .closing }; close.cancel()
            do { try await close.value; XCTFail("cancelled close must not remove layout") } catch is CancellationError {}
            XCTAssertNil(f.session.processInfo); XCTAssertEqual(slot.removals, 0)
            XCTAssertTrue(slot.current === f.session)
            try await dispose(f)
        } catch { try? await dispose(f); throw error }
    }

    func testAlreadyCancelledBarrierNeverStartsClosingAnIdleOwner() async throws {
        let f = try fixture(), slot: OwnedLocalPaneSlot
        slot = OwnedLocalPaneSlot(f.session)
        do {
            let close = Task { try await NativeLocalPTYCloseBarrier.close([slot.target(f.session)]) { slot.removals += 1 } }
            close.cancel()
            do { try await close.value; XCTFail("already cancelled") } catch is CancellationError {}
            XCTAssertEqual(f.session.state, .idle); XCTAssertEqual(slot.removals, 0)
            try await dispose(f)
        } catch { try? await dispose(f); throw error }
    }

    func testDuplicateAndAlreadyStaleTargetsHaveNoCloseSideEffects() async throws {
        let f = try fixture(), slot: OwnedLocalPaneSlot
        slot = OwnedLocalPaneSlot(f.session)
        do {
            let target = slot.target(f.session)
            do { try await NativeLocalPTYCloseBarrier.close([target, target]) { XCTFail("must not remove") }; XCTFail("duplicate") }
            catch let error as NativeLocalPTYCloseBarrier.Failure { XCTAssertEqual(error, .duplicatePane) }
            slot.current = nil
            do { try await NativeLocalPTYCloseBarrier.close([target]) { XCTFail("must not remove") }; XCTFail("stale") }
            catch let error as NativeLocalPTYCloseBarrier.Failure { XCTAssertEqual(error, .paneChanged) }
            XCTAssertEqual(f.session.state, .idle)
            try await dispose(f)
        } catch { try? await dispose(f); throw error }
    }
}
