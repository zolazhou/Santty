import AppKit
import GhosttyTerminal
import XCTest
@testable import Santty

@MainActor
final class HerdrClientShellHostStagingTests: XCTestCase {
    private final class Lifecycle: TerminalSurfaceLifecycleDelegate {
        var attachments = 0
        var detachments = 0
        func terminalDidAttachSurface(_: TerminalSurface) { attachments += 1 }
        func terminalDidDetachSurface() { detachments += 1 }
    }

    private func display() -> (TerminalView, InMemoryTerminalSession) {
        let memory = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        terminal.configuration = .init(backend: .inMemory(memory))
        terminal.controller = TerminalController(configuration: TerminalDefaults.configuration,
                                                 theme: TerminalDefaults.theme)
        return (terminal, memory)
    }

    func testShrinkingFixedGridHostKeepsTheCursorVisibleWithoutResizingTheGrid() throws {
        let (terminal, _) = display()
        let host = TerminalPaneHostView(paneID: UUID(), terminalView: terminal)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.setFixedTerminalSize(NSSize(width: 800, height: 500))
        let cursor = NSRect(x: 760, y: 460, width: 10, height: 20)
        host.setFixedTerminalCursorRect(cursor)
        window.setContentSize(NSSize(width: 400, height: 250))
        host.layoutSubtreeIfNeeded()
        let cursorInHost = NSRect(x: terminal.frame.minX + cursor.minX,
                                 y: terminal.frame.maxY - cursor.maxY,
                                 width: cursor.width, height: cursor.height)
        XCTAssertTrue(host.bounds.insetBy(dx: TerminalSettings.padding, dy: TerminalSettings.padding).contains(cursorInHost))
        XCTAssertEqual(terminal.frame.size, NSSize(width: 800, height: 500))
        let movedCursor = NSRect(x: 0, y: 0, width: 10, height: 20)
        host.setFixedTerminalCursorRect(movedCursor)
        XCTAssertEqual(terminal.frame.minX, TerminalSettings.padding)
        XCTAssertEqual(terminal.frame.maxY, host.bounds.maxY - TerminalSettings.padding)
        host.setFixedTerminalCursorRect(cursor)
        window.setContentSize(NSSize(width: 900, height: 650))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(terminal.frame.minX, TerminalSettings.padding)
        XCTAssertEqual(terminal.frame.maxY, host.bounds.maxY - TerminalSettings.padding)
    }

    func testDelegateHandoffDoesNotReportTheRetiredSurfaceAsTheReplacementDetaching() async throws {
        let (old, oldMemory) = display(), (candidate, newMemory) = display()
        let owner = Lifecycle(), candidateLifecycle = Lifecycle()
        old.delegate = owner
        candidate.delegate = candidateLifecycle
        let root = WorkspaceRootView(frame: old.frame)
        let window = NSWindow(contentRect: root.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = root
        root.installRenderedContentView(old)
        window.orderBack(nil)
        root.layoutSubtreeIfNeeded()
        old.fitToSize()
        root.stageContentView(candidate)
        candidate.fitToSize()
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<100 where newMemory.readViewportText() == nil || oldMemory.readViewportText() == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(owner.attachments, 1)
        XCTAssertEqual(candidateLifecycle.attachments, 1)
        old.delegate = nil
        candidate.delegate = owner
        XCTAssertEqual(owner.attachments, 1, "Changing delegate does not replay the candidate's attachment")
        XCTAssertTrue(root.commitStagedContentView(candidate))
        old.controller = nil
        XCTAssertNil(oldMemory.readViewportText())
        XCTAssertEqual(owner.detachments, 0, "Retiring the old C surface cannot invalidate the promoted display owner")
        XCTAssertEqual(candidateLifecycle.detachments, 0)
        XCTAssertNotNil(newMemory.readViewportText())
        candidate.controller = nil
        XCTAssertEqual(owner.detachments, 1, "The owner receives the replacement's actual teardown")
        XCTAssertNil(newMemory.readViewportText())
    }

    func testFloatingCandidateKeepsThePresentedContainerUntilCommitAndCancel() {
        let root = WorkspaceRootView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        root.installRenderedContentView(NSView()); root.layoutSubtreeIfNeeded()
        let old = NSView(), candidate = NSView()
        root.installFloatingPaneView(old, initialFrame: root.floatingPaneTargetFrame(), animated: false)
        let oldFrame = root.floatingPaneFrame(for: old)
        root.stageFloatingPaneView(candidate, size: NSSize(width: 360, height: 240))
        XCTAssertEqual(root.floatingPaneFrame(for: old), oldFrame)
        XCTAssertTrue(root.isStagedFloatingPaneView(candidate))
        root.cancelStagedFloatingPaneView()
        XCTAssertNil(candidate.superview?.superview)
        XCTAssertEqual(root.floatingPaneFrame(for: old), oldFrame)
        root.stageFloatingPaneView(candidate, size: NSSize(width: 360, height: 240))
        XCTAssertTrue(root.commitStagedFloatingPaneView(candidate))
        XCTAssertNil(old.window)
        XCTAssertFalse(root.isStagedFloatingPaneView(candidate))
        XCTAssertEqual(root.floatingPaneFrame(for: candidate)?.size, NSSize(width: 360, height: 240))
        root.removeFloatingPaneView()
        XCTAssertNil(candidate.superview?.superview)
    }

    func testPopupCandidateKeepsThePresentedPopupAndItsHitTargetUntilCommit() {
        let root = WorkspaceRootView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        root.installRenderedContentView(NSView())
        root.layoutSubtreeIfNeeded()
        let old = NSView(), candidate = NSView()
        let size = NSSize(width: 120, height: 80)
        let region = root.contentContainerView.bounds
        root.installHerdrPopupView(old, size: size, backendFrame: region)
        let point = old.convert(NSPoint(x: old.bounds.midX, y: old.bounds.midY), to: root)
        root.stageHerdrPopupView(candidate, size: size, backendFrame: region)
        XCTAssertTrue(root.debugHerdrPopupView === old)
        XCTAssertTrue(root.hitTest(point) === old, "An alpha-zero candidate must not intercept popup events")
        root.cancelStagedHerdrPopupView(candidate)
        XCTAssertTrue(root.debugHerdrPopupView === old)
        XCTAssertTrue(root.hitTest(point) === old)
        root.stageHerdrPopupView(candidate, size: size, backendFrame: region)
        XCTAssertTrue(root.commitStagedHerdrPopupView(candidate))
        XCTAssertNil(old.superview)
        XCTAssertTrue(root.debugHerdrPopupView === candidate)
        XCTAssertTrue(root.hitTest(point) === candidate)
        root.removeHerdrPopupView()
        XCTAssertNil(root.debugHerdrPopupView)
        XCTAssertNil(candidate.superview)
    }

    func testOccludedCandidateParsesWithoutReparentingThePresentedHost() async throws {
        for commit in [false, true] {
            let (presented, oldMemory) = display()
            let (candidate, newMemory) = display()
            XCTAssertFalse(newMemory.receiveIfAttached(Data("unattached".utf8)))
            let root = WorkspaceRootView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
            let window = NSWindow(contentRect: root.frame, styleMask: [], backing: .buffered, defer: false)
            window.contentView = root
            root.installRenderedContentView(presented)
            window.orderBack(nil)
            root.layoutSubtreeIfNeeded()
            presented.fitToSize()
            defer { window.orderOut(nil); window.contentView = nil }
            for _ in 0..<100 where oldMemory.readViewportText() == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(oldMemory.receiveIfAttached(Data("\u{1b}[2J\u{1b}[Hpresented host".utf8)))
            await Task.detached { oldMemory.waitForPendingOutput() }.value
            let oldFrame = presented.frame
            root.stageContentView(candidate)
            candidate.fitToSize()
            for _ in 0..<100 where newMemory.readViewportText() == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            let grid = try XCTUnwrap(candidate.scrollModeGrid)
            XCTAssertGreaterThan(grid.columns, 0)
            XCTAssertGreaterThan(grid.rows, 0)
            XCTAssertGreaterThan(grid.cellWidthPixels, 0)
            XCTAssertGreaterThan(grid.cellHeightPixels, 0)
            XCTAssertTrue(candidate.window === window)
            XCTAssertTrue(newMemory.receiveIfAttached(Data("\u{1b}[2J\u{1b}[Hcandidate host".utf8)))
            await Task.detached { newMemory.waitForPendingOutput() }.value
            XCTAssertTrue(candidate.readScreenText()?.contains("candidate host") == true)
            XCTAssertTrue(presented.readScreenText()?.contains("presented host") == true)
            XCTAssertEqual(presented.frame, oldFrame)
            XCTAssertTrue(presented.superview === root.contentContainerView)
            let point = presented.convert(NSPoint(x: presented.bounds.midX, y: presented.bounds.midY), to: root)
            let hit = root.hitTest(point)
            XCTAssertTrue(hit === presented || hit?.isDescendant(of: presented) == true,
                          "The occluded candidate must not acquire input hit targets")
            if commit {
                XCTAssertTrue(root.commitStagedContentView(candidate))
                XCTAssertNil(presented.window)
                XCTAssertTrue(candidate.window === window)
                XCTAssertTrue(candidate.readScreenText()?.contains("candidate host") == true)
            } else {
                root.cancelStagedContentView(candidate)
                XCTAssertNil(candidate.window)
                XCTAssertTrue(presented.window === window)
                XCTAssertTrue(presented.readScreenText()?.contains("presented host") == true)
            }
            XCTAssertEqual(root.contentContainerView.subviews.count, 1)
        }
    }
}
