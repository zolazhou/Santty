import AppKit
import XCTest
@testable import Santty

@MainActor
final class NativeProductionIntegrationTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<250 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
        XCTFail("Owned production native terminal timed out"); throw NativeLocalPTYError.shutdownTimeout
    }
    func testProductionLocalCloseAwaitsOwnerBeforeRemovingPane() async throws {
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        let first = try XCTUnwrap(workspace.debugFocusedPaneID)
        workspace.debugSplitFocusedPane(along:.horizontal)
        let survivor = try XCTUnwrap(workspace.debugFocusedPaneID)
        let f = try PrivatePaneFixture(id:first)
        do {
            workspace.debugInstallPaneForCloseTesting(f.pane)
            var earlyExits = 0; f.pane.onExit = { _ in earlyExits += 1 }
            f.pane.startIfNeeded(); f.pane.fitToSize()
            try await wait { f.owner.acceptsInput }
            let response = try await workspace.performCLIPaneRequest(.init(command:"pane.close",paneID:first,force:true))
            XCTAssertEqual(response.status,"closed")
            XCTAssertEqual(workspace.debugPaneIDsInTraversalOrder,[survivor])
            XCTAssertTrue(f.owner.isClosed); XCTAssertFalse(f.owner.acceptsInput)
            XCTAssertTrue(f.pane.focusTargetView === f.pane.terminalView?.renderer,"Closed history remains an explicitly focusable read-only target")
            XCTAssertEqual(f.owner.localSession?.pendingInputBytes,0)
            XCTAssertEqual(earlyExits,0,"Explicit cleanup must not auto-remove layout through onExit")
            try await f.stop()
        } catch { try? await f.stop(); throw error }
    }
    func testReadinessCompletesOnlyOurExplicitLoadingHostFocus() async throws {
        let f = try PrivatePaneFixture()
        let window = NSWindow(contentRect:.init(x:0,y:0,width:720,height:480),styleMask:[],backing:.buffered,defer:false)
        window.contentView = f.pane.hostView
        defer { window.contentView = nil }
        do {
            f.pane.updatePresentation(isFocused:true)
            XCTAssertTrue(window.makeFirstResponder(f.pane.hostView))
            f.pane.startIfNeeded(); f.pane.fitToSize()
            try await wait { window.firstResponder === f.pane.terminalView?.renderer }
            XCTAssertTrue(f.owner.acceptsInput)
            try await f.stop()
        } catch { try? await f.stop(); throw error }
    }
    func testReadinessAndMetadataCannotStealAnotherResponderOrAuthorizeStalePrompt() async throws {
        let f = try PrivatePaneFixture()
        let root = NSView(frame:.init(x:0,y:0,width:720,height:480))
        f.pane.hostView.frame = root.bounds; root.addSubview(f.pane.hostView)
        let other = NSTextField(frame:.init(x:0,y:0,width:100,height:24)); root.addSubview(other)
        let window = NSWindow(contentRect:root.frame,styleMask:[],backing:.buffered,defer:false); window.contentView = root
        defer { window.contentView = nil }
        do {
            XCTAssertTrue(window.makeFirstResponder(other)); let responder = window.firstResponder
            f.pane.updatePresentation(isFocused:true); f.pane.startIfNeeded(); f.pane.fitToSize()
            try await wait { f.owner.acceptsInput }
            f.pane.setTitleForTesting("metadata only")
            XCTAssertTrue(window.firstResponder === responder)
            let lease = f.owner.output.userInputLease
            f.pane.isCurrent = { false }
            XCTAssertFalse(f.pane.submitPrompt("must not run",expected:lease))
            XCTAssertThrowsError(try f.pane.sendForCLI(.init(command:"pane.send-text",text:"must not run")))
            XCTAssertTrue(window.firstResponder === responder)
            try await f.stop()
        } catch { try? await f.stop(); throw error }
    }
    func testHiddenEntryEstablishesVTReferencesWithoutPublishingPixelsOrAX() throws {
        let driver = try GhosttyVTDriver()
        let view = NativeTerminalScrollView(driver:driver,frame:.init(x:0,y:0,width:640,height:250))
        let output = NativeTerminalOutput(driver:driver) { _ in }
        output.bindChecked { _ in XCTFail("Scroll Mode input escaped"); return false }
        output.setInputEnabled(true); view.renderer.output = output
        output.receive(Data("hidden history\r\nnext\r\n".utf8))
        XCTAssertNil(view.presentedViewport)
        XCTAssertTrue(view.scrollModeController.enter())
        XCTAssertNotNil(try driver.scrollModeState)
        XCTAssertNil(view.presentedViewport,"A reading origin is not a published presentation page")
        XCTAssertFalse(view.canAutoscrollScrollMode)
        XCTAssertFalse(try output.sendText("no input"))
        XCTAssertFalse(view.scrollModeController.overlay.badgeRect.isNull)
        view.scrollModeController.exit()
    }
}
