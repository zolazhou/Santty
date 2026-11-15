import AppKit
import XCTest
@testable import Santty

@MainActor
private final class PaneOwnerFixture {
    let root: URL
    let owner: NativeTerminalPaneSession
    let view: NativeTerminalScrollView
    let window: NSWindow
    var current = true
    var frontend: NativeTerminalFrontend?
    init(script: String = "printf 'ADAPTER-READY'; exec /bin/cat", paneID: UUID = UUID(), attachWindow: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("santty-adapter-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let driver = try GhosttyVTDriver(columns:40,rows:4)
        let launch = try NativeLocalPTYLaunch(paneID:paneID,executable:"/bin/sh",arguments:["-c",script],
            environment:["HOME":root.path,"PATH":"/usr/bin:/bin","TERM":"xterm-256color"],workingDirectory:root.path)
        owner = .local(launch:launch,driver:driver)
        view = NativeTerminalScrollView(driver:driver,frame:.init(x:0,y:0,width:640,height:250))
        window = NSWindow(contentRect:view.frame,styleMask:[],backing:.buffered,defer:false)
        if attachWindow { window.contentView = view }
    }
    func bind() throws { frontend = try NativeTerminalFrontend(session:owner,view:view,isCurrent:{ [weak self] in self?.current == true }) }
    func stop() async throws {
        try await owner.close(.terminate); frontend?.detach(); frontend = nil
        window.contentView = nil
        try FileManager.default.removeItem(at:root)
    }
}

@MainActor
final class NativeTerminalPaneSessionTests: XCTestCase {
    private func wait(_ predicate: () throws -> Bool) async throws {
        for _ in 0..<500 { if try predicate() { return }; try await Task.sleep(for:.milliseconds(10)) }
        XCTFail("Owned adapter consumer timed out"); throw NativeLocalPTYError.shutdownTimeout
    }
    func testHiddenInitialFrontendUsesRealGridBeforeExecWithoutPublishingOrFocusing() async throws {
        // Original diagnostic used /usr/bin/stty (absent on this Mac). Keep
        // that failed premise in the compatibility record; /bin/stty is the
        // independently verified executable, not an injected terminal command.
        let f = try PaneOwnerFixture(script:"/bin/stty size; printf 'ADAPTER-READY'; exec /bin/cat",attachWindow:false)
        do {
            let container = NSView(frame:f.view.frame); f.window.contentView = container
            let other = NSTextView(frame:.init(x:0,y:0,width:10,height:10)); container.addSubview(other)
            XCTAssertTrue(f.window.makeFirstResponder(other))
            try f.bind()
            try f.frontend?.startIfNeeded()
            try await wait { try f.owner.driver.readScreenText().contains("ADAPTER-READY") }
            let rows = max(1,Int(f.view.contentSize.height/f.view.renderer.cellSize.height))
            let columns = max(1,Int(f.view.contentSize.width/f.view.renderer.cellSize.width))
            XCTAssertEqual(f.owner.driver.rows,rows)
            XCTAssertEqual(f.owner.driver.columns,columns)
            let captured = try f.owner.driver.readScreenText()
            XCTAssertTrue(captured.contains("\(rows) \(columns)"),"owned stty transcript=\(captured.debugDescription), expected=\(rows) \(columns)")
            XCTAssertNil(f.view.presentedFrame,"reset may clear the initial empty page; hidden output must not publish a new one")
            XCTAssertTrue(f.window.firstResponder === other)
            try await f.stop()
        } catch { try? await f.stop(); throw error }
    }
    func testFactoryDoesNotLaunchAndRepeatedStartCannotReplacePID() async throws {
        let f = try PaneOwnerFixture()
        do {
            XCTAssertFalse(f.owner.hasStarted); XCTAssertNil(f.owner.localSession?.processInfo)
            try f.bind(); try f.frontend?.startIfNeeded()
            try await wait { f.owner.acceptsInput }
            let pid = try XCTUnwrap(f.owner.localSession?.processInfo?.shellPid)
            try f.frontend?.startIfNeeded()
            XCTAssertEqual(f.owner.localSession?.processInfo?.shellPid,pid)
            try await f.stop()
            XCTAssertThrowsError(try f.owner.startIfNeeded(viewport:f.view.viewport))
        } catch { try? await f.stop(); throw error }
    }
    func testFrontendDeinitUnbindsButDoesNotJoinOrCloseProcess() async throws {
        let f = try PaneOwnerFixture()
        do {
            try f.bind(); try f.frontend?.startIfNeeded(); try await wait { f.owner.acceptsInput }
            let pid = f.owner.localSession?.processInfo?.shellPid
            f.frontend = nil
            XCTAssertNil(f.view.renderer.output); XCTAssertTrue(f.owner.acceptsInput)
            XCTAssertEqual(f.owner.localSession?.processInfo?.shellPid,pid)
            try f.bind(); XCTAssertTrue(f.frontend?.bound == true)
            try await f.stop()
        } catch { try? await f.stop(); throw error }
    }
    func testInvalidInitialGeometryDoesNotConsumeLaunchAndSettingsDoNotFocus() async throws {
        let f = try PaneOwnerFixture(attachWindow:false)
        do {
            XCTAssertThrowsError(try f.owner.startIfNeeded(viewport:.init(columns:0,rows:24)))
            XCTAssertFalse(f.owner.hasStarted)
            try f.bind()
            let size = f.view.frame.size
            f.view.setFrameSize(.zero)
            XCTAssertThrowsError(try f.frontend?.startIfNeeded()); XCTAssertFalse(f.owner.hasStarted)
            f.view.setFrameSize(size)
            let settings = NativeTerminalSettings(theme:try NativeThemeCatalog.bundled().defaultTheme,fontSize:17)
            try f.frontend?.applySettings(settings)
            XCTAssertEqual(f.view.hostActions.zoomResetSize,17)
            XCTAssertNil(f.window.firstResponder as? NativeTerminalInputView)
            try f.frontend?.startIfNeeded(); try await wait { f.owner.acceptsInput }
            try await f.stop()
        } catch { try? await f.stop(); throw error }
    }

    func testFrontendRejectsForeignDriverAndDuplicateBindingWithoutDamagingFirst() async throws {
        let f = try PaneOwnerFixture()
        do {
            let foreign = NativeTerminalScrollView(driver:try GhosttyVTDriver(),frame:f.view.frame)
            XCTAssertThrowsError(try NativeTerminalFrontend(session:f.owner,view:foreign,isCurrent:{ true }))
            try f.bind()
            let sameDriver = NativeTerminalScrollView(driver:f.owner.driver,frame:f.view.frame)
            XCTAssertThrowsError(try NativeTerminalFrontend(session:f.owner,view:sameDriver,isCurrent:{ true }))
            XCTAssertTrue(f.view.renderer.output === f.owner.output); XCTAssertTrue(f.frontend?.bound == true)
            try await f.stop()
        } catch { try? await f.stop(); throw error }
    }
    func testFrontendDetachKeepsOwnedProcessDrainingAndAllowsFreshViewBinding() async throws {
        let f = try PaneOwnerFixture()
        do {
            try f.bind(); try f.frontend?.startIfNeeded()
            try await wait { try f.owner.driver.readScreenText().contains("ADAPTER-READY") }
            let pid = f.owner.localSession?.processInfo?.shellPid
            f.frontend?.detach(); f.frontend = nil
            XCTAssertTrue(f.owner.acceptsInput); XCTAssertNil(f.view.renderer.output)
            XCTAssertTrue(try f.owner.output.sendText("printf-is-not-executed-by-cat\n"))
            try await wait { try f.owner.driver.readScreenText().contains("printf-is-not-executed-by-cat") }
            try f.bind()
            XCTAssertEqual(f.owner.localSession?.processInfo?.shellPid,pid)
            XCTAssertTrue(f.view.renderer.inputEnabled)
            try await f.stop()
        } catch { try? await f.stop(); throw error }
    }
    func testStaleFrontendCannotReadOrClearReplacementOutput() async throws {
        let f = try PaneOwnerFixture()
        do {
            try f.bind(); try f.frontend?.startIfNeeded()
            try await wait { f.owner.acceptsInput }
            let other = NativeTerminalOutput(driver:f.view.driver) { _ in }
            f.view.renderer.output = other
            f.frontend?.detach()
            XCTAssertTrue(f.view.renderer.output === other)
            let request = CLIRequest(command:"read",paneID:f.owner.paneID)
            do { _ = try await f.frontend?.read(request); XCTFail("Stale frontend read succeeded") }
            catch let error as CLIError { XCTAssertEqual(error.code,"pane_changed") }
            try await f.stop()
        } catch { try? await f.stop(); throw error }
    }
    func testPostAwaitReadChecksExactOwnerEvenForSamePaneUUID() async throws {
        let f = try PaneOwnerFixture(script:"printf 'BOUND-READ'; exec /bin/cat")
        do {
            try f.bind(); try f.frontend?.startIfNeeded()
            try await wait { try f.owner.driver.readScreenText().contains("BOUND-READ") }
            let request = CLIRequest(command:"read",paneID:f.owner.paneID)
            var checks = 0
            do {
                _ = try await f.owner.read(request,isCurrent:{ checks+=1; return checks == 1 })
                XCTFail("Post-await replacement was not rejected")
            } catch let error as CLIError { XCTAssertEqual(error.code,"pane_changed") }
            XCTAssertEqual(checks,2,"exact owner is checked before and after the background read")
            let response = try await f.owner.read(request,isCurrent:{ true })
            XCTAssertTrue(response.text?.contains("BOUND-READ") == true)
            try await f.stop()
        } catch { try? await f.stop(); throw error }
    }
    func testLocalDirectoryDoesNotInterpretRawForeignOSCURI() async throws {
        let f = try PaneOwnerFixture()
        do {
            _ = f.owner.driver.feed(Data("\u{1b}]7;file://remote.invalid/do-not-inspect\u{7}".utf8))
            guard case let .local(path) = f.owner.directoryForNewPane else { XCTFail("Expected Local directory"); throw CLIError("Missing Local directory") }
            XCTAssertEqual(path,f.root.path)
            XCTAssertEqual(f.owner.driver.metadata.rawWorkingDirectory,"file://remote.invalid/do-not-inspect")
            try await f.stop()
        } catch { try? await f.stop(); throw error }
    }
    func testMixedBarrierPrevalidatesDuplicatesAndStaleTargetsBeforeClosingAnything() async throws {
        let a = try PaneOwnerFixture(), b = try PaneOwnerFixture(paneID:UUID())
        do {
            try a.bind(); try a.frontend?.startIfNeeded(); try b.bind(); try b.frontend?.startIfNeeded()
            try await wait { a.owner.acceptsInput && b.owner.acceptsInput }
            let first = NativeTerminalCloseBarrier.Target(session:a.owner,isCurrent:{ true })
            var removed = false
            do { try await NativeTerminalCloseBarrier.close([first,first],intent:.terminate) { removed = true }; XCTFail("Duplicate accepted") }
            catch let error as NativeTerminalCloseBarrier.Failure { XCTAssertEqual(error,.duplicatePane) }
            let stale = NativeTerminalCloseBarrier.Target(session:b.owner,isCurrent:{ false })
            do { try await NativeTerminalCloseBarrier.close([first,stale],intent:.terminate) { removed = true }; XCTFail("Stale accepted") }
            catch let error as NativeTerminalCloseBarrier.Failure { XCTAssertEqual(error,.paneChanged) }
            XCTAssertFalse(removed); XCTAssertTrue(a.owner.acceptsInput); XCTAssertTrue(b.owner.acceptsInput)
            try await a.stop(); try await b.stop()
        } catch { try? await a.stop(); try? await b.stop(); throw error }
    }
    func testMixedBarrierPrecancellationDoesNotCloseOrRemove() async throws {
        let f = try PaneOwnerFixture()
        do {
            try f.bind(); try f.frontend?.startIfNeeded(); try await wait { f.owner.acceptsInput }
            var removed = false
            let task = Task { try await NativeTerminalCloseBarrier.close([.init(session:f.owner,isCurrent:{ true })],intent:.terminate) { removed = true } }
            task.cancel()
            do { try await task.value; XCTFail("Cancelled close succeeded") } catch is CancellationError { }
            XCTAssertFalse(removed); XCTAssertTrue(f.owner.acceptsInput); XCTAssertFalse(f.owner.isClosing)
            try await f.stop()
        } catch { try? await f.stop(); throw error }
    }
    func testMixedBarrierPostStartCancellationStillReapsButRetainsLayout() async throws {
        let f = try PaneOwnerFixture(script:"trap '' HUP TERM; printf 'ADAPTER-READY'; while :; do /bin/sleep 1; done")
        do {
            try f.bind(); try f.frontend?.startIfNeeded()
            try await wait { try f.owner.driver.readScreenText().contains("ADAPTER-READY") }
            var removed = false
            let task = Task { try await NativeTerminalCloseBarrier.close([.init(session:f.owner,isCurrent:{ true })],intent:.terminate) { removed = true } }
            try await wait { f.owner.isClosing }; task.cancel()
            do { try await task.value; XCTFail("Cancelled layout removal succeeded") } catch is CancellationError { }
            XCTAssertTrue(f.owner.isClosed); XCTAssertNil(f.owner.localSession?.processInfo)
            XCTAssertFalse(removed); XCTAssertFalse(try f.owner.output.sendText("no replay"))
            try await f.stop()
        } catch { try? await f.stop(); throw error }
    }
    func testMixedBarrierDoesNotRemoveSameUUIDReplacementAfterAwait() async throws {
        let f = try PaneOwnerFixture(script:"trap '' HUP TERM; printf 'ADAPTER-READY'; while :; do /bin/sleep 1; done")
        let replacement = try PaneOwnerFixture(paneID:f.owner.paneID)
        do {
            try f.bind(); try f.frontend?.startIfNeeded()
            try await wait { try f.owner.driver.readScreenText().contains("ADAPTER-READY") }
            var registered = f.owner, removed = false
            let target = NativeTerminalCloseBarrier.Target(session:f.owner,isCurrent:{ registered === f.owner })
            let task = Task { try await NativeTerminalCloseBarrier.close([target],intent:.terminate) { removed = true } }
            try await wait { f.owner.isClosing }; registered = replacement.owner
            do { try await task.value; XCTFail("Replacement removed") }
            catch let error as NativeTerminalCloseBarrier.Failure { XCTAssertEqual(error,.paneChanged) }
            XCTAssertFalse(removed); XCTAssertTrue(f.owner.isClosed)
            XCTAssertFalse(replacement.owner.hasStarted); XCTAssertFalse(replacement.owner.isClosing)
            try await f.stop(); try await replacement.stop()
        } catch { try? await f.stop(); try? await replacement.stop(); throw error }
    }
    func testMixedSuccessRemovesOnlyAfterBothLocalAndHerdrOwnersComplete() async throws {
        let lab = try NativeHerdrTestSession(driver:GhosttyVTDriver()) { _ in }, f = try PaneOwnerFixture()
        var herdr: NativeTerminalPaneSession?
        do {
            try await lab.start(viewport:.init(columns:80,rows:24)); try await wait { lab.session.state == .live }
            try f.bind(); try f.frontend?.startIfNeeded()
            let pane = try NativeTerminalPaneSession.herdr(paneID:UUID(),driver:GhosttyVTDriver(),client:lab.client,
                workingDirectory:lab.root.appendingPathComponent("home").path,binding:nil,beforeRun:{ }); herdr = pane
            try pane.startIfNeeded(viewport:.init(columns:80,rows:24))
            try await wait { f.owner.acceptsInput && pane.acceptsInput }
            let binding = try XCTUnwrap(pane.herdrSession?.binding)
            var removed = false, checks = 0
            let targets = [NativeTerminalCloseBarrier.Target(session:f.owner,isCurrent:{ checks+=1; return true }),
                           .init(session:pane,isCurrent:{ checks+=1; return true })]
            try await NativeTerminalCloseBarrier.close(targets,intent:.terminate) {
                XCTAssertTrue(f.owner.isClosed); XCTAssertTrue(pane.isClosed)
                XCTAssertNil(f.owner.localSession?.processInfo); removed = true
            }
            XCTAssertTrue(removed); XCTAssertEqual(checks,4)
            let record = try await lab.client.terminal(binding)
            XCTAssertEqual(record.state,"finished")
            try await f.stop(); try await lab.stop()
        } catch { try? await herdr?.close(.terminate); try? await f.stop(); try? await lab.stop(); throw error }
    }

    func testMixedHerdrFailureStillAwaitsLocalCleanupAndRetainsBothTargets() async throws {
        let lab = try NativeHerdrTestSession(driver:GhosttyVTDriver()) { _ in }, f = try PaneOwnerFixture()
        do {
            try await lab.start(viewport:.init(columns:80,rows:24))
            // start() initiates connection; it is not a promise of live state.
            try await wait { lab.session.state == .live }
            try f.bind(); try f.frontend?.startIfNeeded(); try await wait { f.owner.acceptsInput }
            let bad = try NativeTerminalPaneSession.herdr(paneID:UUID(),driver:GhosttyVTDriver(),client:lab.client,
                workingDirectory:nil,binding:.init(coreID:"not-this-owned-core",address:"not-an-owned-terminal"),beforeRun:{ XCTFail("Bound owner cannot run") })
            var removed = false
            do {
                try await NativeTerminalCloseBarrier.close([.init(session:bad,isCurrent:{ true }),.init(session:f.owner,isCurrent:{ true })],intent:.terminate) { removed = true }
                XCTFail("Identity failure was ignored")
            } catch { XCTAssertNotNil(bad.lastCloseError) }
            XCTAssertTrue(f.owner.isClosed); XCTAssertNil(f.owner.localSession?.processInfo)
            XCTAssertFalse(bad.isClosed); XCTAssertTrue(bad.isClosing); XCTAssertFalse(removed)
            XCTAssertNil(bad.output.userInputLease); XCTAssertEqual(lab.session.state,.live)
            try await f.stop(); try await lab.stop()
        } catch { try? await f.stop(); try? await lab.stop(); throw error }
    }

    func testCoalescedCloseCommitsStateBeforeBothWaitersReturnAndReadOnlyTextSurvives() async throws {
        let f = try PaneOwnerFixture()
        do {
            try f.bind(); try f.frontend?.startIfNeeded()
            try await wait { try f.owner.driver.readScreenText().contains("ADAPTER-READY") }
            async let a: Void = f.owner.close(.detach)
            async let b: Void = f.owner.close(.terminate) // Local intents both mean process stop
            try await a; XCTAssertTrue(f.owner.isClosed)
            try await b; XCTAssertTrue(f.owner.isClosed)
            XCTAssertFalse(f.owner.acceptsInput); XCTAssertFalse(try f.owner.output.sendText("no-replay"))
            let request = CLIRequest(command:"read",paneID:f.owner.paneID)
            let response = try await f.owner.read(request,isCurrent:{ true })
            XCTAssertTrue(response.text?.contains("ADAPTER-READY") == true)
            try await f.stop()
        } catch { try? await f.stop(); throw error }
    }
}
