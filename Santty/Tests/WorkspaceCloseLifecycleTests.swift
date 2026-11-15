import AppKit
import XCTest
@testable import Santty

/// Lifecycle/order tests below the unchanged authorization router. These use
/// synthetic awaited owners, not claims that legacy Local has native stop/drain.
@MainActor
final class WorkspaceCloseLifecycleTests: XCTestCase {
    enum Fault: Error { case refused }
    @MainActor private final class Probe {
        let id: UUID
        let gate: CloseGate?
        var starts = 0
        var intents: [PaneCloseIntent] = []
        var effect: (() throws -> Void)?
        lazy var handle: PaneCloseHandle = {
            PaneCloseHandle(id:id,policy:.awaitedOwner,operation:{ [weak self] intent in
                guard let self else { throw Fault.refused }
                starts+=1; intents.append(intent)
                if let gate { try await gate.wait() }
                try effect?()
            })
        }()
        init(id: UUID, gate: CloseGate? = nil) { self.id = id; self.gate = gate }
    }
    private func workspace() -> WorkspaceViewController {
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        workspace.resourceCloseErrorHandler = { _ in }
        return workspace
    }
    @discardableResult
    private func install(_ probe: Probe, in workspace: WorkspaceViewController) -> TerminalPaneController {
        let pane = TerminalPaneController(id:probe.id,resourceCloseHandle:probe.handle)
        workspace.debugInstallPaneForCloseTesting(pane)
        return pane
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for:.milliseconds(10)) }
        XCTFail("Owned workspace lifecycle timed out"); throw Fault.refused
    }
    func testGUIPaneCloseWaitsForOwnerAndDuplicateClickCoalesces() async throws {
        let workspace = workspace(), gate = CloseGate(); defer { gate.release() }
        let id = try XCTUnwrap(workspace.debugFocusedPaneID), probe = Probe(id:id,gate:gate)
        install(probe,in:workspace)
        workspace.debugPerformClosePane(withID:id)
        try await wait { gate.waiting }
        XCTAssertTrue(workspace.debugSelectedTabContainsPane(withID:id))
        workspace.debugPerformClosePane(withID:id); XCTAssertEqual(probe.starts,1)
        gate.release(); try await wait { !workspace.debugSelectedTabContainsPane(withID:id) }
        XCTAssertEqual(probe.intents,[.terminate])
    }
    func testGUITabCloseWaitsAndDoesNotRemoveNewlyInsertedSibling() async throws {
        let workspace = workspace(), gate = CloseGate(); defer { gate.release() }
        let tab = try XCTUnwrap(workspace.debugSelectedTabID), id = try XCTUnwrap(workspace.debugFocusedPaneID)
        let probe = Probe(id:id,gate:gate); install(probe,in:workspace)
        workspace.debugNewTab(); workspace.debugSelectTab(withID:tab)
        var errors = 0; workspace.resourceCloseErrorHandler = { _ in errors+=1 }
        workspace.debugCloseTab(withID:tab); try await wait { gate.waiting }
        workspace.debugSplitFocusedPane(along:.horizontal)
        let retained = workspace.debugPaneIDsInTraversalOrder
        XCTAssertEqual(retained.count,2)
        gate.release(); try await wait { errors == 1 }
        XCTAssertTrue(workspace.debugTabIDs.contains(tab)); XCTAssertEqual(workspace.debugPaneIDsInTraversalOrder,retained)
        XCTAssertTrue(probe.handle.completed)
    }
    func testGUIWorkspaceCloseDoesNotDiscardNewTabCreatedDuringAwait() async throws {
        let workspace = workspace()
        let original = workspace.debugSelectedWorkspace, id = try XCTUnwrap(workspace.debugFocusedPaneID)
        let gate = CloseGate(); defer { gate.release() }
        let probe = Probe(id:id,gate:gate); install(probe,in:workspace)
        workspace.newWorkspace(nil); workspace.selectLocalWorkspace(original)
        var errors = 0; workspace.resourceCloseErrorHandler = { _ in errors+=1 }
        workspace.closeLocalWorkspace(original); try await wait { gate.waiting }
        workspace.debugNewTab(); let tabs = workspace.debugTabIDs
        gate.release(); try await wait { errors == 1 }
        XCTAssertEqual(workspace.debugSelectedWorkspace,original); XCTAssertEqual(workspace.debugTabIDs,tabs)
    }
    func testGUISameUUIDReplacementIsNotRemovedAfterAwait() async throws {
        let workspace = workspace(), gate = CloseGate(); defer { gate.release() }
        let id = try XCTUnwrap(workspace.debugFocusedPaneID), old = Probe(id:id,gate:gate), replacement = Probe(id:id)
        install(old,in:workspace)
        var errors = 0; workspace.resourceCloseErrorHandler = { _ in errors+=1 }
        workspace.debugPerformClosePane(withID:id); try await wait { gate.waiting }
        let newer = install(replacement,in:workspace); newer.name = "replacement"
        gate.release(); try await wait { errors == 1 }
        XCTAssertTrue(workspace.debugSelectedTabContainsPane(withID:id))
        XCTAssertEqual(workspace.savedWorkspace().tabs.first?.panes.first?.name,"replacement")
        XCTAssertEqual(replacement.starts,0)
    }
    func testCLICloseSharesBarrierAndRequiresMatchingReplyBeforeFinalWindowPreparation() async throws {
        let workspace = workspace(), gate = CloseGate(); defer { gate.release() }
        let id = try XCTUnwrap(workspace.debugFocusedPaneID), probe = Probe(id:id,gate:gate)
        install(probe,in:workspace)
        let close = Task { try await workspace.performCLIPaneRequest(.init(command:"pane.close",paneID:id,force:true,requestID:"owned-reply")) }
        try await wait { gate.waiting }; XCTAssertTrue(workspace.debugSelectedTabContainsPane(withID:id))
        gate.release(); let response = try await close.value
        XCTAssertEqual(response.status,"closed"); XCTAssertFalse(workspace.debugDidRequestWindowClose)
        let premature = await workspace.prepareForWindowClose(); XCTAssertFalse(premature)
        workspace.finishCLIReply(requestID:"wrong"); XCTAssertFalse(workspace.debugDidRequestWindowClose)
        workspace.finishCLIReply(requestID:"owned-reply"); XCTAssertTrue(workspace.debugDidRequestWindowClose)
    }
    func testCLISameUUIDReplacementReturnsPaneChangedWithoutClosingReplacement() async throws {
        let workspace = workspace(), gate = CloseGate(); defer { gate.release() }
        let id = try XCTUnwrap(workspace.debugFocusedPaneID), old = Probe(id:id,gate:gate), newer = Probe(id:id)
        install(old,in:workspace)
        let close = Task { try await workspace.performCLIPaneRequest(.init(command:"pane.close",paneID:id,force:true)) }
        try await wait { gate.waiting }; install(newer,in:workspace); gate.release()
        do { _ = try await close.value; XCTFail("Replacement removed") }
        catch let error as CLIError { XCTAssertEqual(error.code,"pane_changed") }
        XCTAssertTrue(workspace.debugSelectedTabContainsPane(withID:id)); XCTAssertEqual(newer.starts,0)
    }
    func testWindowPreparationIncludesBackgroundWorkspacesAndSidebarAndCoalesces() async throws {
        let workspace = workspace()
        let firstID = try XCTUnwrap(workspace.debugFocusedPaneID), first = Probe(id:firstID)
        install(first,in:workspace)
        workspace.newWorkspace(nil)
        let secondID = try XCTUnwrap(workspace.debugFocusedPaneID), gate = CloseGate(); defer { gate.release() }
        let second = Probe(id:secondID,gate:gate); install(second,in:workspace)
        // The sidebar is lazy: establish an owned pane, then hide it again.
        workspace.toggleSidebar(nil)
        let sidebarID = try XCTUnwrap(workspace.debugSidebarPaneIDs.first), sidebar = Probe(id:sidebarID)
        install(sidebar,in:workspace); workspace.toggleSidebar(nil)
        let selected = workspace.debugSelectedWorkspace, tab = workspace.debugSelectedTabID
        let a = Task { await workspace.prepareForWindowClose() }
        try await wait { gate.waiting }
        let b = Task { await workspace.prepareForWindowClose() }
        let count = workspace.debugTabIDs.count
        workspace.debugNewTab(); XCTAssertEqual(workspace.debugTabIDs.count,count,"busy fence blocks new owners")
        gate.release()
        let resultA = await a.value, resultB = await b.value
        XCTAssertTrue(resultA); XCTAssertTrue(resultB)
        XCTAssertEqual(first.intents,[.detach]); XCTAssertEqual(second.intents,[.detach]); XCTAssertEqual(sidebar.intents,[.detach])
        XCTAssertEqual(workspace.debugSelectedWorkspace,selected); XCTAssertEqual(workspace.debugSelectedTabID,tab)
        XCTAssertTrue(workspace.debugSidebarPaneIDs.contains(sidebarID))
        do { _ = try await workspace.performCLIPaneRequest(.init(command:"pane.send-text",paneID:secondID,text:"no input")); XCTFail("Window close fence bypassed") }
        catch let error as CLIError { XCTAssertEqual(error.code,"busy") }
    }
    func testWindowFailureRetainsLayoutAndExplicitRetryCoalescesOnlyCleanup() async throws {
        let workspace = workspace(), id = try XCTUnwrap(workspace.debugFocusedPaneID), probe = Probe(id:id)
        install(probe,in:workspace); probe.effect = { throw Fault.refused }
        var errors = 0; workspace.resourceCloseErrorHandler = { _ in errors+=1 }
        let first = await workspace.prepareForWindowClose()
        XCTAssertFalse(first); XCTAssertEqual(errors,1); XCTAssertTrue(workspace.debugSelectedTabContainsPane(withID:id))
        probe.effect = nil
        let retry = await workspace.prepareForWindowClose()
        XCTAssertTrue(retry); XCTAssertEqual(probe.starts,2); XCTAssertTrue(probe.handle.completed)
    }
    func testWindowLateReplacementInvalidatesFinalSaveCommit() async throws {
        let workspace = workspace(), id = try XCTUnwrap(workspace.debugFocusedPaneID), gate = CloseGate(); defer { gate.release() }
        let old = Probe(id:id,gate:gate), newer = Probe(id:id); install(old,in:workspace)
        let task = Task { await workspace.prepareForWindowClose() }
        try await wait { gate.waiting }; install(newer,in:workspace); gate.release()
        let result = await task.value
        XCTAssertFalse(result); XCTAssertEqual(newer.starts,0); XCTAssertTrue(workspace.debugSelectedTabContainsPane(withID:id))
    }
    func testFinalRealAtomicSaveReflectsChangesCompletedDuringDetach() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("santty-close-save-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("workspace.json"), workspace = WorkspaceViewController()
        await workspace.prepareWorkspacePersistence(url:url); workspace.debugLoadForTesting()
        workspace.resourceCloseErrorHandler = { _ in XCTFail("Unexpected close error") }
        let id = try XCTUnwrap(workspace.debugFocusedPaneID), probe = Probe(id:id)
        let pane = install(probe,in:workspace); pane.name = "before-detach"
        probe.effect = { [weak pane] in
            let before = try JSONDecoder().decode(SavedWorkspace.self,from:Data(contentsOf:url))
            XCTAssertEqual(before.tabs.first?.panes.first?.name,"before-detach","pre-save must finish before effects")
            pane?.name = "after-detach"
        }
        let result = await workspace.prepareForWindowClose(); XCTAssertTrue(result)
        let after = try JSONDecoder().decode(SavedWorkspace.self,from:Data(contentsOf:url))
        XCTAssertEqual(after.tabs.first?.panes.first?.name,"after-detach")
        XCTAssertEqual(after,workspace.savedWorkspace()); try after.validate()
    }
}
