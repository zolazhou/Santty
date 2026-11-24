import AppKit
import XCTest
@testable import Santty

@MainActor
final class NativeTerminalHerdrOwnerTests: XCTestCase {
    private func wait(_ predicate: () throws -> Bool) async throws {
        for _ in 0..<500 { if try predicate() { return }; try await Task.sleep(for:.milliseconds(10)) }
        XCTFail("Owned Herdr adapter timed out"); throw NativeLocalPTYError.shutdownTimeout
    }
    private func make(_ lab: NativeHerdrTestSession, binding: HerdrTerminalBinding? = nil, viewer: Bool = false,
                      beforeRun: @escaping @MainActor () async throws -> Void = {}) throws -> NativeTerminalPaneSession {
        try .herdr(paneID:UUID(),driver:GhosttyVTDriver(columns:120,rows:30),client:lab.client,
            workingDirectory:lab.root.appendingPathComponent("home").path,binding:binding,viewerOnly:viewer,beforeRun:beforeRun)
    }
    func testFactoryKeepsHiddenStreamAndCoreMetadataAuthoritativeAcrossViewDetach() async throws {
        let lab = try NativeHerdrTestSession(driver:GhosttyVTDriver()) { _ in }
        var owner: NativeTerminalPaneSession?
        do {
            try await lab.start(viewport:.init(columns:80,rows:24))
            var saves = 0
            let pane = try make(lab,beforeRun:{ saves+=1 }); owner = pane
            let view = NativeTerminalScrollView(driver:pane.driver,frame:.init(x:0,y:0,width:960,height:480))
            let frontend = try NativeTerminalFrontend(session:pane,view:view,isCurrent:{ true })
            try frontend.startIfNeeded(); try await wait { pane.acceptsInput }
            XCTAssertEqual(saves,1)
            let binding = try XCTUnwrap(pane.herdrSession?.binding)
            XCTAssertTrue(try pane.output.sendText("printf '\\033]2;CORE-AUTHORITATIVE\\007'; awk 'BEGIN{for(i=0;i<3000;i++) print i \" " + String(repeating:"x",count:80) + "\"; print \"ADAPTER-CREDIT-\" \"DONE\"}'\r"))
            try await wait { try pane.driver.readScreenText().contains("ADAPTER-CREDIT-DONE") }
            try await wait { pane.herdrSession?.record?.title == "CORE-AUTHORITATIVE" }
            XCTAssertNil(view.presentedFrame,"connected hidden frontend does not publish output")
            frontend.detach()
            XCTAssertEqual(pane.herdrSession?.state,.live)
            pane.output.receive(Data("\u{1b}]2;VT-DISPLAY-ONLY\u{7}\u{1b}]7;file://remote.invalid/do-not-inspect\u{7}".utf8))
            try await wait { pane.metadata.title == "VT-DISPLAY-ONLY" }
            XCTAssertEqual(pane.title,"CORE-AUTHORITATIVE"); XCTAssertNil(pane.localSession)
            guard case let .herdr(path,remote) = pane.directoryForNewPane else { XCTFail("Not a Herdr path"); throw CLIError("Missing Herdr path") }
            XCTAssertNil(remote); XCTAssertFalse(path.contains("do-not-inspect"))
            let response = try await pane.read(.init(command:"read",paneID:pane.paneID,tail:3),isCurrent:{ true })
            XCTAssertTrue(response.text?.contains("ADAPTER-CREDIT-DONE") == true)
            XCTAssertEqual(pane.herdrSession?.binding,binding)
            try await pane.close(.terminate); try await lab.stop()
        } catch { try? await owner?.close(.terminate); try? await lab.stop(); throw error }
    }
    func testWindowDetachAndExplicitExternalViewerCloseDoNotKillAndPreserveBinding() async throws {
        let lab = try NativeHerdrTestSession(driver:GhosttyVTDriver()) { _ in }
        var owners: [NativeTerminalPaneSession] = []
        do {
            try await lab.start(viewport:.init(columns:80,rows:24))
            let pane = try make(lab); owners.append(pane)
            try pane.startIfNeeded(viewport:.init(columns:80,rows:24))
            try await wait { pane.acceptsInput }
            let binding = try XCTUnwrap(pane.herdrSession?.binding)
            let initial = try await lab.client.terminal(binding)
            let viewer = try make(lab,binding:binding,viewer:true,beforeRun:{ XCTFail("Viewer must not create/reconcile") })
            owners.append(viewer); try viewer.startIfNeeded(viewport:.init(columns:80,rows:24))
            try await wait { viewer.acceptsInput }
            try await viewer.close(.terminate)
            let afterViewer = try await lab.client.terminal(binding)
            XCTAssertEqual(afterViewer.pid,initial.pid); XCTAssertEqual(afterViewer.state,"live")
            try await pane.close(.detach)
            XCTAssertTrue(pane.isClosed); XCTAssertEqual(pane.herdrSession?.binding,binding)
            let afterWindow = try await lab.client.terminal(binding)
            XCTAssertEqual(afterWindow.pid,initial.pid); XCTAssertEqual(afterWindow.state,"live")
            XCTAssertFalse(try pane.output.sendText("must-not-replay")); pane.retryConnection()
            XCTAssertFalse(pane.acceptsInput)
            // A new owner/controller restores exactly this binding, not a new shell.
            let restored = try make(lab,binding:binding,beforeRun:{ XCTFail("Bound restore must not run") })
            owners.append(restored); try restored.startIfNeeded(viewport:.init(columns:80,rows:24))
            try await wait { restored.acceptsInput }
            XCTAssertEqual(restored.herdrSession?.binding,binding)
            let afterRestore = try await lab.client.terminal(binding)
            XCTAssertEqual(afterRestore.pid,initial.pid)
            try await restored.close(.terminate)
            let finished = try await lab.client.terminal(binding)
            XCTAssertEqual(finished.state,"finished")
            try await lab.stop()
        } catch { for owner in owners { try? await owner.close(.detach) }; try? await lab.stop(); throw error }
    }
    func testDetachWaitsForPendingSaveAndPreventsAnUnsentRunWithoutKillingCore() async throws {
        let lab = try NativeHerdrTestSession(driver:GhosttyVTDriver()) { _ in }
        var owner: NativeTerminalPaneSession?
        var pending: CheckedContinuation<Void,Never>?
        do {
            try await lab.start(viewport:.init(columns:80,rows:24))
            // start() returns before the fixture's asynchronous attach is live.
            try await wait { lab.session.state == .live }
            let pane = try make(lab,beforeRun:{ await withCheckedContinuation { pending = $0 } }); owner = pane
            try pane.startIfNeeded(viewport:.init(columns:80,rows:24))
            try await wait { pending != nil }
            XCTAssertTrue(pane.herdrSession?.createResultUnknown == true)
            let close = Task { try await pane.close(.detach) }
            try await wait { pane.isClosing }
            XCTAssertFalse(pane.isClosed); XCTAssertNil(pane.output.userInputLease)
            pending?.resume(); pending = nil
            try await close.value
            XCTAssertTrue(pane.isClosed); XCTAssertNil(pane.herdrSession?.binding)
            XCTAssertFalse(pane.herdrSession?.createResultUnknown == true)
            struct Records: Decodable, Sendable { let terminals: [HerdrCoreTerminal] }
            let connection = try await lab.client.connection()
            let listed: Records = try await HerdrCoreClient.request(connection,"terminal.list",
                ["all":true,"labels":["santty-pane":pane.paneID.uuidString]])
            XCTAssertTrue(listed.terminals.isEmpty)
            XCTAssertEqual(lab.session.state,.live,"closing a viewer never stops the private/shared core")
            try await lab.stop()
        } catch { pending?.resume(); try? await owner?.close(.detach); try? await lab.stop(); throw error }
    }
    func testInvalidViewerFailsBeforeConnectionAndConflictingIntentNeverEscalatesDetach() async throws {
        let lab = try NativeHerdrTestSession(driver:GhosttyVTDriver()) { _ in }
        do {
            XCTAssertThrowsError(try make(lab,viewer:true))
            let pane = try make(lab)
            try pane.beginClosing(.detach)
            do { try await pane.close(.terminate); XCTFail("Detach was escalated") }
            catch let error as NativeTerminalPaneSession.Failure { XCTAssertEqual(error,.conflictingCloseIntent) }
            XCTAssertNil(pane.herdrSession?.binding)
            try await pane.close(.detach); try await lab.stop()
        } catch { try? await lab.stop(); throw error }
    }
}
