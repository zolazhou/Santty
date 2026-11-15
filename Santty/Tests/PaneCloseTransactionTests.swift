import Foundation
import XCTest
@testable import Santty

@MainActor
final class CloseGate {
    var continuation: CheckedContinuation<Void,Error>?
    var waiting: Bool { continuation != nil }
    func wait() async throws { try await withCheckedThrowingContinuation { continuation = $0 } }
    func release() { let pending = continuation; continuation = nil; pending?.resume() }
}

@MainActor
final class PaneCloseTransactionTests: XCTestCase {
    enum Fault: Error { case refused }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for:.milliseconds(10)) }
        XCTFail("Owned close transaction timed out"); throw Fault.refused
    }
    func testAllAdmissionFencesPrecedeCleanupAndCommitFollowsAllOwners() async throws {
        let a = NSObject(), b = NSObject(); var events: [String] = []
        let targets = [PaneCloseTarget(id:UUID(),owner:a,begin:{ _ in events.append("begin-a") },finish:{ _ in events.append("end-a") },isCurrent:{ true }),
                       .init(id:UUID(),owner:b,begin:{ _ in events.append("begin-b") },finish:{ _ in events.append("end-b") },isCurrent:{ true })]
        try await PaneCloseTransaction.perform(targets,intent:.terminate) { events.append("commit") }
        XCTAssertEqual(Array(events.prefix(2)),["begin-a","begin-b"])
        XCTAssertEqual(Set(events[2..<4]),Set(["end-a","end-b"])); XCTAssertEqual(events.last,"commit")
    }
    func testFirstFailureStillWaitsForAnotherOwnerBeforeReturning() async throws {
        let gate = CloseGate(); defer { gate.release() }
        var finished = false, returned = false, committed = false
        let targets = [PaneCloseTarget(id:UUID(),owner:NSObject(),finish:{ _ in throw Fault.refused },isCurrent:{ true }),
                       .init(id:UUID(),owner:gate,finish:{ _ in try await gate.wait(); finished = true },isCurrent:{ true })]
        let task = Task {
            defer { returned = true }
            do { try await PaneCloseTransaction.perform(targets,intent:.terminate) { committed = true }; XCTFail("Failure lost") }
            catch is Fault { }
        }
        try await wait { gate.waiting }; XCTAssertFalse(returned)
        gate.release(); try await task.value
        XCTAssertTrue(finished); XCTAssertFalse(committed)
    }
    func testDuplicateAndInitiallyStaleTargetsHaveNoEffects() async throws {
        var starts = 0
        let target = PaneCloseTarget(id:UUID(),owner:NSObject(),begin:{ _ in starts+=1 },finish:{ _ in },isCurrent:{ true })
        do { try await PaneCloseTransaction.perform([target,target],intent:.terminate) {}; XCTFail("Duplicate allowed") }
        catch let error as PaneCloseFailure { XCTAssertEqual(error,.duplicatePane) }
        let stale = PaneCloseTarget(id:UUID(),owner:NSObject(),finish:{ _ in },isCurrent:{ false })
        do { try await PaneCloseTransaction.perform([target,stale],intent:.terminate) {}; XCTFail("Stale allowed") }
        catch let error as PaneCloseFailure { XCTAssertEqual(error,.paneChanged) }
        XCTAssertEqual(starts,0)
    }
    func testAllIntentsValidateBeforeAnyAdmissionFence() async throws {
        var starts = 0
        let first = PaneCloseTarget(id:UUID(),owner:NSObject(),begin:{ _ in starts+=1 },finish:{ _ in },isCurrent:{ true })
        let second = PaneCloseTarget(id:UUID(),owner:NSObject(),validate:{ _ in throw PaneCloseFailure.conflictingIntent },finish:{ _ in },isCurrent:{ true })
        do { try await PaneCloseTransaction.perform([first,second],intent:.detach) {}; XCTFail("Conflict allowed") }
        catch let error as PaneCloseFailure { XCTAssertEqual(error,.conflictingIntent) }
        XCTAssertEqual(starts,0)
    }
    func testPrecancellationPreventsSignalsAndCommit() async throws {
        var starts = 0
        let target = PaneCloseTarget(id:UUID(),owner:NSObject(),begin:{ _ in starts+=1 },finish:{ _ in },isCurrent:{ true })
        let task = Task { try await PaneCloseTransaction.perform([target],intent:.terminate) { XCTFail("Cancelled commit") } }
        task.cancel()
        do { try await task.value; XCTFail("Precancel ignored") } catch is CancellationError { }
        XCTAssertEqual(starts,0)
    }
    func testPostStartCancellationCompletesCleanupButRetainsLayout() async throws {
        let gate = CloseGate(); defer { gate.release() }
        var finished = false, committed = false
        let target = PaneCloseTarget(id:UUID(),owner:gate,finish:{ _ in try await gate.wait(); finished = true },isCurrent:{ true })
        let task = Task { try await PaneCloseTransaction.perform([target],intent:.terminate) { committed = true } }
        try await wait { gate.waiting }; task.cancel(); gate.release()
        do { try await task.value; XCTFail("Cancelled commit allowed") } catch is CancellationError { }
        XCTAssertTrue(finished); XCTAssertFalse(committed)
    }
    func testLateOwnerOrContainerMembershipChangeRefusesCommit() async throws {
        for changeOwner in [true,false] {
            let gate = CloseGate(); defer { gate.release() }
            var ownerIsCurrent = true, scopeIsCurrent = true, committed = false
            let target = PaneCloseTarget(id:UUID(),owner:gate,finish:{ _ in try await gate.wait() },isCurrent:{ ownerIsCurrent })
            let task = Task { try await PaneCloseTransaction.perform([target],intent:.terminate,scopeIsCurrent:{ scopeIsCurrent }) { committed = true } }
            try await wait { gate.waiting }
            if changeOwner { ownerIsCurrent = false } else { scopeIsCurrent = false }
            gate.release()
            do { try await task.value; XCTFail("Late mutation allowed") }
            catch let error as PaneCloseFailure { XCTAssertEqual(error,.paneChanged) }
            XCTAssertFalse(committed)
        }
    }
    func testHandleCoalescesAndCommitsCompletionBeforeBothWaitersReturn() async throws {
        let gate = CloseGate(); defer { gate.release() }
        var calls = 0, fences = 0
        let handle = PaneCloseHandle(id:UUID(),policy:.awaitedOwner,suspend:{ _ in fences+=1 },operation:{ _ in calls+=1; try await gate.wait() })
        let a = Task { try await handle.finish(.terminate); XCTAssertTrue(handle.completed) }
        try await wait { gate.waiting }
        let b = Task { try await handle.finish(.terminate); XCTAssertTrue(handle.completed) }
        gate.release(); try await a.value; try await b.value
        XCTAssertEqual(calls,1); XCTAssertEqual(fences,1)
        try await handle.finish(.terminate); XCTAssertEqual(calls,1)
    }
    func testFailedHandleRearmsAdmissionOnExplicitCleanupRetry() async throws {
        var calls = 0, fences = 0
        let handle = PaneCloseHandle(id:UUID(),policy:.awaitedOwner,suspend:{ _ in fences+=1 },operation:{ _ in
            XCTAssertEqual(fences,calls+1,"an explicit retry must re-fence a backend that may have reconnected")
            calls+=1; if calls == 1 { throw Fault.refused }
        })
        do { try await handle.finish(.terminate); XCTFail("Expected failure") } catch is Fault { }
        XCTAssertTrue(handle.hasBegun); XCTAssertFalse(handle.completed)
        try await handle.finish(.terminate)
        XCTAssertTrue(handle.completed); XCTAssertEqual(calls,2); XCTAssertEqual(fences,2)
    }
    func testViewerNormalizationAndConflictingCompletedIntentNeverEscalate() async throws {
        var intents: [PaneCloseIntent] = []
        let viewer = PaneCloseHandle(id:UUID(),policy:.awaitedOwner,normalize:{ _ in .detach },operation:{ intents.append($0) })
        try await viewer.finish(.terminate); try await viewer.finish(.detach)
        XCTAssertEqual(intents,[.detach])
        let managed = PaneCloseHandle(id:UUID(),policy:.awaitedOwner,operation:{ intents.append($0) })
        try await managed.finish(.detach)
        XCTAssertTrue(managed.needsAwait(for:.terminate))
        XCTAssertThrowsError(try managed.validate(.terminate))
        XCTAssertEqual(intents,[.detach,.detach])
    }
    func testUnstartedNativeOwnerCanBeRemovedWithoutAnIOWait() {
        let handle = PaneCloseHandle(id:UUID(),policy:.awaitedOwner,hasResources:{ false },operation:{ _ in })
        XCTAssertFalse(handle.needsAwait(for:.terminate)); XCTAssertEqual(handle.policy,.awaitedOwner)
        XCTAssertFalse(handle.completed)
    }
}
