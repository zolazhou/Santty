import AppKit
import XCTest
@testable import Santty

@MainActor
private final class NativeInputPortHarness {
    let fixture: NativeHostFixture
    var current = true
    var source = "en"
    var selections: [String] = []
    var queries = 0
    var foreground = InputSourceForeground(groupID:10,processes:[.init(id:10,name:"codex")])
    var query: (() async throws -> InputSourceForeground)?
    var configuration = InputSourceSettings.Configuration(paneRulesEnabled:true,englishInputSourceID:"en",rules:[
        .init(program:"codex",inputSourceID:"zh"),.init(program:"nvim",inputSourceID:InputSourceSettings.english)])
    lazy var port: NativeTerminalInputSourcePort = {
        NativeTerminalInputSourcePort(paneID:UUID(),view:fixture.view,isCurrent:{ [weak self] in self?.current == true },
            foreground:{ [weak self] in
                guard let self else { throw NativeTerminalInputSourcePort.Failure.contextChanged }
                return try await self.foregroundSnapshot()
            })
    }()
    private func foregroundSnapshot() async throws -> InputSourceForeground {
        queries+=1
        if let query { return try await query() }
        return foreground
    }
    lazy var coordinator: PaneInputSourceCoordinator = {
        let c = PaneInputSourceCoordinator(configuration:{ [unowned self] in configuration },
            currentSource:{ [unowned self] in source },
            selectSource:{ [unowned self] id,view in
                XCTAssertTrue(view === fixture.view.renderer)
                selections.append(id); source = id; return true
            },isActive:{ true },inputView:{ [unowned self] in fixture.view.renderer })
        c.targetProvider = { [weak self] in self?.port.target }; return c
    }()
    init() throws { fixture = try NativeHostFixture() }
    func refresh() async { coordinator.refresh(); await coordinator.waitForPendingQuery() }
}

@MainActor
final class NativeTerminalInputSourcePortTests: XCTestCase {
    func testExistingCoordinatorMatchesRulesAndPreservesManualChoiceWithoutFocusChanges() async throws {
        let h = try NativeInputPortHarness(); defer { h.coordinator.stop() }
        await h.refresh(); XCTAssertEqual(h.selections,["zh"])
        h.source = "manual"; await h.refresh(); XCTAssertEqual(h.selections,["zh"])
        h.foreground = .init(groupID:20,processes:[.init(id:20,name:"nvim"),.init(id:30,name:"codex")])
        await h.refresh(); XCTAssertEqual(h.selections,["zh","en"])
        XCTAssertTrue(h.fixture.window.firstResponder === h.fixture.view.renderer)
        XCTAssertTrue(h.fixture.bytes.data.isEmpty)
    }
    func testOptOutDoesNotQueryForegroundOrSelectAnySystemSource() async throws {
        let h = try NativeInputPortHarness(); defer { h.coordinator.stop() }
        h.configuration.paneRulesEnabled = false
        await h.refresh(); XCTAssertEqual(h.queries,0); XCTAssertTrue(h.selections.isEmpty)
    }
    func testIMEFocusInputGateAndScrollModeHaveNoEligibleTarget() throws {
        let h = try NativeInputPortHarness(), f = h.fixture
        XCTAssertNotNil(h.port.target)
        XCTAssertTrue(f.window.makeFirstResponder(nil)); XCTAssertNil(h.port.target)
        XCTAssertTrue(f.window.makeFirstResponder(f.view.renderer))
        f.view.renderer.inputEnabled = false; XCTAssertNil(h.port.target); f.view.renderer.inputEnabled = true
        let owner = UUID(); f.output.suppressUserInput(true,owner:owner); XCTAssertNil(h.port.target)
        f.output.suppressUserInput(false,owner:owner)
        XCTAssertTrue(f.view.scrollModeController.enter()); XCTAssertNil(h.port.target); f.view.scrollModeController.exit()
        f.view.renderer.setMarkedText("预编辑",selectedRange:.init(location:0,length:0),replacementRange:.init(location:NSNotFound,length:0))
        XCTAssertNil(h.port.target); f.view.renderer.clearComposition(); XCTAssertNotNil(h.port.target)
        f.view.isHidden = true; XCTAssertNil(h.port.target); f.view.isHidden = false
        h.current = false; XCTAssertNil(h.port.target)
    }
    private func suspended(_ h: NativeInputPortHarness,
                           change: () throws -> Void) async throws {
        var continuation: CheckedContinuation<InputSourceForeground,Error>?
        h.query = { try await withCheckedThrowingContinuation { continuation = $0 } }
        let target = try XCTUnwrap(h.port.target)
        let task = Task { try await target.foreground() }; defer { task.cancel() }
        for _ in 0..<50 { if continuation != nil { break }; await Task.yield() }
        let pending = try XCTUnwrap(continuation)
        try change(); pending.resume(returning:h.foreground)
        do { _ = try await task.value; XCTFail("Late metadata must not authorize a source change") }
        catch is NativeTerminalInputSourcePort.Failure { }
    }
    func testLateForegroundCannotCrossRebindEvenWithSameViewAndPaneUUID() async throws {
        let h = try NativeInputPortHarness()
        try await suspended(h) { h.fixture.output.bindChecked { _ in true } }
    }
    func testLateForegroundCannotCrossRIS() async throws {
        let h = try NativeInputPortHarness()
        try await suspended(h) { _ = h.fixture.view.driver.feed(Data("\u{1b}c".utf8)) }
    }
    func testLateForegroundCannotCrossNewUserInput() async throws {
        let h = try NativeInputPortHarness()
        try await suspended(h) { XCTAssertTrue(try h.fixture.output.sendText("new-context")) }
    }
    func testLateForegroundCannotCrossReplacedControllerIdentity() async throws {
        let h = try NativeInputPortHarness()
        try await suspended(h) { h.current = false }
    }
    func testLateForegroundCannotCrossIMEOrFocusLoss() async throws {
        let h = try NativeInputPortHarness()
        try await suspended(h) {
            h.fixture.view.renderer.setMarkedText("IME",selectedRange:.init(location:0,length:0),replacementRange:.init(location:NSNotFound,length:0))
        }
        h.fixture.view.renderer.clearComposition()
        try await suspended(h) { XCTAssertTrue(h.fixture.window.makeFirstResponder(nil)) }
    }
    func testAutomaticRepliesAndTitleMetadataDoNotChangeInputSourceTargetOrFirstResponder() async throws {
        let h = try NativeInputPortHarness()
        var continuation: CheckedContinuation<InputSourceForeground,Error>?
        h.query = { try await withCheckedThrowingContinuation { continuation = $0 } }
        let target = try XCTUnwrap(h.port.target), task = Task { try await target.foreground() }
        for _ in 0..<50 { if continuation != nil { break }; await Task.yield() }
        let pending = try XCTUnwrap(continuation), lease = h.fixture.output.userInputLease
        h.fixture.output.receive(Data("\u{1b}]2;owned-metadata\u{7}\u{1b}[5n".utf8))
        pending.resume(returning:h.foreground)
        let result = try await task.value
        XCTAssertEqual(result.groupID,10); XCTAssertEqual(h.fixture.output.userInputLease,lease)
        XCTAssertTrue(h.fixture.window.firstResponder === h.fixture.view.renderer)
        XCTAssertEqual(h.fixture.bytes.data,Data("\u{1b}[0n".utf8))
    }
    func testCancelledForegroundResultIsNotPublished() async throws {
        let h = try NativeInputPortHarness()
        var continuation: CheckedContinuation<InputSourceForeground,Error>?
        h.query = { try await withCheckedThrowingContinuation { continuation = $0 } }
        let target = try XCTUnwrap(h.port.target), task = Task { try await target.foreground() }
        for _ in 0..<50 { if continuation != nil { break }; await Task.yield() }
        let pending = try XCTUnwrap(continuation)
        task.cancel(); pending.resume(returning:h.foreground)
        do { _ = try await task.value; XCTFail("Cancelled query returned metadata") } catch is CancellationError { }
    }
}
