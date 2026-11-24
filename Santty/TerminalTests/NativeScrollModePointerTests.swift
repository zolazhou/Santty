import AppKit
import XCTest
@testable import Santty

@MainActor
final class NativeScrollModePointerTests: XCTestCase {
    private func fixture(driver: GhosttyVTDriver? = nil, text: String? = nil) throws -> (NSWindow,NativeTerminalScrollView) {
        let view = NativeTerminalScrollView(driver:try driver ?? GhosttyVTDriver(),frame:.init(x:0,y:0,width:640,height:250))
        let window = NSWindow(contentRect:view.frame,styleMask:[],backing:.buffered,defer:false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.feed(text ?? (0..<100).map { "line-\($0) hello 界 e\u{301}🙂\r\n" }.joined())
        XCTAssertTrue(view.scrollModeController.enter())
        _ = try view.driver.performScrollMode(.move(.top)); view.refresh()
        return (window,view)
    }
    private func event(_ type: NSEvent.EventType, _ window: NSWindow, _ view: NativeTerminalScrollView,
                       column: CGFloat, row: CGFloat, time: Double) throws -> NSEvent {
        let document = try XCTUnwrap(view.documentView), h = view.renderer.cellSize.height, w = view.renderer.cellSize.width
        let point = CGPoint(x:column*w,y:view.contentView.bounds.minY+row*h)
        return try XCTUnwrap(NSEvent.mouseEvent(with:type,location:document.convert(point,to:nil),modifierFlags:[],
            timestamp:time,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
    }
    private func send(_ type: NSEvent.EventType, _ window: NSWindow, _ view: NativeTerminalScrollView,
                      column: CGFloat, row: CGFloat, time: Double) throws {
        let e = try event(type,window,view,column:column,row:row,time:time)
        switch type {
        case .leftMouseDown: view.renderer.mouseDown(with:e)
        case .leftMouseUp: view.renderer.mouseUp(with:e)
        default: view.renderer.mouseDragged(with:e)
        }
    }

    func testSingleClickMovesCursorAndDragUsesTheExistingVTGestureAndCopy() throws {
        let (window,view) = try fixture(text:"hello world\r\nsecond\r\n")
        defer { window.contentView = nil }
        try send(.leftMouseDown,window,view,column:0.1,row:0.3,time:1)
        XCTAssertEqual(try view.driver.scrollModeState?.cell,.init(column:0,row:0))
        XCTAssertNil(try view.driver.readScrollModeSelection())
        XCTAssertTrue(view.scrollModeController.pointer.hasGesture,
            "permits=\(view.permitsScrollModePointer) appHidden=\(NSApp.isHidden) cell=\(view.renderer.cellSize)/\(view.presentedCellSize) size=\(view.contentSize) error=\(String(describing:view.scrollModeController.lastError))")
        try send(.leftMouseDragged,window,view,column:4.9,row:0.3,time:1.1)
        XCTAssertEqual(try view.driver.readScrollModeSelection(),"hello")
        try send(.leftMouseUp,window,view,column:4.9,row:0.3,time:1.2)
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
        XCTAssertTrue(view.scrollModeController.isActive)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(view.copySelection(to:board)); XCTAssertEqual(board.string(forType:.string),"hello")
    }

    func testReverseDragAndCoreDoubleTripleClickKeepTheirNativeSemantics() throws {
        let (window,view) = try fixture(text:"hello world\r\nsecond\r\n")
        defer { window.contentView = nil }
        try send(.leftMouseDown,window,view,column:4.9,row:0.3,time:1)
        try send(.leftMouseDragged,window,view,column:0.1,row:0.3,time:1.1)
        try send(.leftMouseUp,window,view,column:0.1,row:0.3,time:1.2)
        XCTAssertEqual(try view.driver.readScrollModeSelection(),"hello")
        view.renderer.resetInputState()
        for (time,expected): (Double,String?) in [(3,nil),(3.1,"hello"),(3.2,"hello world")] {
            try send(.leftMouseDown,window,view,column:1.2,row:0.3,time:time)
            XCTAssertEqual(try view.driver.readScrollModeSelection(),expected)
            try send(.leftMouseUp,window,view,column:1.2,row:0.3,time:time+0.01)
        }
    }

    func testWideCombiningAndSoftWrapCopyStillBelongToVT() throws {
        let (window,view) = try fixture(text:"a界🙂e\u{301}\r\nsecond")
        defer { window.contentView = nil }
        try send(.leftMouseDown,window,view,column:1.1,row:0.3,time:1)
        try send(.leftMouseDragged,window,view,column:5.9,row:0.3,time:1.1)
        try send(.leftMouseUp,window,view,column:5.9,row:0.3,time:1.2)
        XCTAssertEqual(try view.driver.readScrollModeSelection(),"界🙂e\u{301}")
        let frame = try XCTUnwrap(view.presentedFrame)
        XCTAssertFalse(frame.selection.isEmpty)
    }

    func testOrphanDragReleaseAndClickInElasticBlankCannotSelect() throws {
        let (window,view) = try fixture(text:"hello\r\n")
        defer { window.contentView = nil }
        let before = try view.driver.scrollModeState
        try send(.leftMouseDragged,window,view,column:4.9,row:0.3,time:1)
        try send(.leftMouseUp,window,view,column:4.9,row:0.3,time:1.1)
        XCTAssertEqual(try view.driver.scrollModeState,before)
        try send(.leftMouseDown,window,view,column:0.1,row:-1,time:2)
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
        XCTAssertNil(try view.driver.readScrollModeSelection())
        try send(.leftMouseDown,window,view,column:90,row:0.3,time:3)
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
    }

    func testModeNeverOpensCmdLinksOrChangesProgramMouseModes() throws {
        let (window,view) = try fixture(text:"https://example.com/path\r\n")
        defer { window.contentView = nil }
        view.driver.feed("\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1007h")
        let modes = try view.driver.pointerModes
        var opens = 0; view.openLink = { _ in opens += 1; return true }
        let document = try XCTUnwrap(view.documentView)
        let e = try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:document.convert(.init(x:2,y:5),to:nil),
            modifierFlags:.command,timestamp:1,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
        view.renderer.mouseDown(with:e); view.renderer.mouseUp(with:e)
        XCTAssertEqual(opens,0); XCTAssertEqual(try view.driver.pointerModes,modes)
        XCTAssertTrue(view.scrollModeController.isActive)
    }

    func testResizeFocusHoldAndResetCancelTheOwnedDragWithoutAReleaseReplay() throws {
        let (window,view) = try fixture()
        defer { window.contentView = nil }
        try send(.leftMouseDown,window,view,column:0.1,row:1.3,time:1)
        try send(.leftMouseDragged,window,view,column:5.9,row:1.3,time:1.1)
        view.renderer.resetInputState()
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
        let copied = try view.driver.readScrollModeSelection()
        try send(.leftMouseUp,window,view,column:30,row:1.3,time:1.2)
        XCTAssertEqual(try view.driver.readScrollModeSelection(),copied)
        try send(.leftMouseDown,window,view,column:0.1,row:1.3,time:2)
        view.renderer.font = .monospacedSystemFont(ofSize:19,weight:.regular); view.refresh(resizeTerminal:true)
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
        try send(.leftMouseDragged,window,view,column:4.9,row:1.3,time:2.1)
        XCTAssertNil(try view.driver.readScrollModeSelection())
        try send(.leftMouseDown,window,view,column:0.1,row:1.3,time:3)
        view.driver.feed("\u{1b}[?2026hheld")
        try send(.leftMouseDragged,window,view,column:4.9,row:1.3,time:3.1)
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
        view.driver.reset(); view.resetPresentation()
        XCTAssertFalse(view.scrollModeController.isActive)
    }

    func testActualPruningInvalidatesThePressOriginRatherThanReusingItsRow() throws {
        let driver = try GhosttyVTDriver(columns:80,rows:15,scrollbackLines:2000)
        let (window,view) = try fixture(driver:driver,text:(0..<4000).map { "prune-\($0)\r\n" }.joined())
        defer { window.contentView = nil }
        try send(.leftMouseDown,window,view,column:0.1,row:0.3,time:1)
        view.driver.feed((4000..<12_000).map { "prune-\($0)\r\n" }.joined())
        try send(.leftMouseDragged,window,view,column:5.9,row:0.3,time:1.1)
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
        XCTAssertNil(try view.driver.readScrollModeSelection())
        XCTAssertFalse(try view.driver.readScreenText().contains("prune-0\n"))
    }

    func testOriginalUnpresentedPruningVectorRejectsTheActuallyDiscardedOrigin() throws {
        let driver = try GhosttyVTDriver(columns:80,rows:15,scrollbackLines:2000)
        let lines = (0..<4000).map { String(format:"history-%04d\r\n",$0) }.joined()
        let (window,view) = try fixture(driver:driver,text:lines)
        defer { window.contentView = nil }
        for _ in 0..<40 { _ = try driver.performScrollMode(.move(.pageDown)) }
        view.refresh()
        let top = try XCTUnwrap(view.presentedViewport).firstRow
        let first = try XCTUnwrap(view.presentedFrame?.rows[top]).cells.compactMap(\.text).joined().trimmingCharacters(in:.whitespaces)
        try send(.leftMouseDown,window,view,column:0.1,row:0.3,time:1)
        driver.feed((4000..<4400).map { String(format:"history-%04d\r\n",$0) }.joined())
        try send(.leftMouseDragged,window,view,column:11.9,row:0.3,time:1.1)
        try send(.leftMouseUp,window,view,column:11.9,row:0.3,time:1.2)
        XCTAssertEqual(first,"history-2954")
        XCTAssertNil(try driver.readScrollModeSelection())
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
    }

    func testUnpresentedPruningRebasesARetainedPressOriginNotItsOldNumericRow() throws {
        let driver = try GhosttyVTDriver(columns:80,rows:15,scrollbackLines:2000)
        let lines = (0..<4000).map { String(format:"history-%04d\r\n",$0) }.joined()
        let (window,view) = try fixture(driver:driver,text:lines)
        defer { window.contentView = nil }
        _ = try driver.performScrollMode(.move(.bottom)); _ = try driver.performScrollMode(.move(.pageUp)); view.refresh()
        let top = try XCTUnwrap(view.presentedViewport).firstRow
        let first = try XCTUnwrap(view.presentedFrame?.rows[top]).cells.compactMap(\.text).joined().trimmingCharacters(in:.whitespaces)
        XCTAssertEqual(first,"history-3985","independent C probe proves this reference survives the same pruning")
        try send(.leftMouseDown,window,view,column:0.1,row:0.3,time:1)
        driver.feed((4000..<4400).map { String(format:"history-%04d\r\n",$0) }.joined())
        try send(.leftMouseDragged,window,view,column:11.9,row:0.3,time:1.1)
        try send(.leftMouseUp,window,view,column:11.9,row:0.3,time:1.2)
        XCTAssertEqual(try driver.readScrollModeSelection(),"history-3985")
    }

    func testFiniteAutoscrollStepExtendsFromTheCoreAnchorAndCopiesOriginalLines() throws {
        let text = (0..<100).map { "line-\($0)\r\n" }.joined()
        let (window,view) = try fixture(text:text)
        defer { window.contentView = nil }
        try send(.leftMouseDown,window,view,column:0.1,row:2.3,time:1)
        let out = view.contentSize.height/view.renderer.cellSize.height+3
        try send(.leftMouseDragged,window,view,column:0.1,row:out,time:1.1)
        XCTAssertFalse(view.scrollModeController.pointer.autoscrollArmed,"default hidden-window facts must not arm a loop")
        XCTAssertTrue(view.scrollModeController.pointer.autoscrollStep())
        let state = try XCTUnwrap(view.driver.scrollModeState)
        XCTAssertGreaterThan(state.viewport,0)
        let expected = (2..<(state.viewport+state.rows-1)).map { "line-\($0)" }.joined(separator:"\n")
        XCTAssertEqual(try view.driver.readScrollModeSelection(),expected)
        try send(.leftMouseUp,window,view,column:0.1,row:out,time:1.2)
        XCTAssertFalse(view.scrollModeController.pointer.autoscrollStep())
    }

    func testAutoscrollAtTheHistoryBoundaryDoesNotKeepPolling() throws {
        let (window,view) = try fixture()
        defer { window.contentView = nil }
        try send(.leftMouseDown,window,view,column:0.1,row:0.3,time:1)
        try send(.leftMouseDragged,window,view,column:0.1,row:-3,time:1.1)
        XCTAssertFalse(view.scrollModeController.pointer.autoscrollStep())
        XCTAssertFalse(view.scrollModeController.pointer.autoscrollArmed)
        XCTAssertTrue(view.scrollModeController.isActive)
    }

    func testDisplayFactSchedulerHasOneWeakWakeAndCancelsOnSleepAndRelease() async throws {
        let (window,view) = try fixture()
        defer { window.contentView = nil }
        view.scrollModeController.pointer.autoscrollIsVisible = { true } // owned offscreen scheduler fact only
        try send(.leftMouseDown,window,view,column:0.1,row:2.3,time:1)
        let out = view.contentSize.height/view.renderer.cellSize.height+3
        try send(.leftMouseDragged,window,view,column:0.1,row:out,time:1.1)
        XCTAssertTrue(view.scrollModeController.pointer.autoscrollArmed)
        try await Task.sleep(for:.milliseconds(80))
        XCTAssertGreaterThan(try XCTUnwrap(view.driver.scrollModeState).viewport,0)
        view.setDisplaysAsleep(true)
        XCTAssertFalse(view.scrollModeController.pointer.autoscrollArmed)
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
        view.setDisplaysAsleep(false)
        try send(.leftMouseUp,window,view,column:0.1,row:out,time:1.2)
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
    }

    func testCoreTokenRejectsStaleReleaseNewEpochWrongGridAndMalformedInput() throws {
        let (window,view) = try fixture(text:"hello world\r\n")
        defer { window.contentView = nil }
        let viewport = try XCTUnwrap(view.presentedViewport), cell = view.renderer.cellSize
        func input(_ step: NativeSelectionInput.Step, width: CGFloat? = nil, time: Double = 1) -> NativeSelectionInput {
            .init(step:step,column:0,row:viewport.firstRow,position:.init(x:1,y:5),cell:.init(width:width ?? cell.width,height:cell.height),
                viewportHeight:viewport.viewportHeight,time:time,doubleClickInterval:0.5)
        }
        XCTAssertNil(try view.driver.selectScrollMode(input(.drag),relativeTo:viewport,expectedColumns:view.driver.columns,token:UUID()))
        XCTAssertNil(try view.driver.selectScrollMode(input(.press,width:.infinity),relativeTo:viewport,expectedColumns:view.driver.columns))
        XCTAssertNil(try view.driver.selectScrollMode(input(.press,time:.nan),relativeTo:viewport,expectedColumns:view.driver.columns))
        XCTAssertNil(try view.driver.selectScrollMode(input(.press),relativeTo:viewport,expectedColumns:view.driver.columns+1))
        let pressed = try XCTUnwrap(view.driver.selectScrollMode(input(.press),relativeTo:viewport,expectedColumns:view.driver.columns))
        let token = try XCTUnwrap(pressed.token)
        _ = try view.driver.performScrollMode(.end); _ = try view.driver.performScrollMode(.begin)
        XCTAssertFalse(view.driver.scrollModePointerIsCurrent(token))
        XCTAssertNil(try view.driver.selectScrollMode(input(.release),relativeTo:viewport,expectedColumns:view.driver.columns,token:token))
    }

    func testAutoscrollLosingItsOriginalPageNeverSelectsReplacementRows() throws {
        let driver = try GhosttyVTDriver(columns:80,rows:15,scrollbackLines:2000)
        let (window,view) = try fixture(driver:driver,text:(0..<4000).map { "line-\($0)\r\n" }.joined())
        defer { window.contentView = nil }
        try send(.leftMouseDown,window,view,column:0.1,row:1.3,time:1)
        let out = view.contentSize.height/view.renderer.cellSize.height+3
        try send(.leftMouseDragged,window,view,column:0.1,row:out,time:1.1)
        driver.feed((4000..<12_000).map { "line-\($0)\r\n" }.joined())
        XCTAssertFalse(view.scrollModeController.pointer.autoscrollStep())
        XCTAssertNil(try driver.readScrollModeSelection())
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
    }

    func testConnectedHiddenWindowStaysBlockedEvenWithAnInjectedSchedulerFact() throws {
        let (window,view) = try fixture()
        defer { window.contentView = nil }
        view.scrollModeController.exit()
        let output = NativeTerminalOutput(driver:view.driver) { _ in }
        output.bindChecked { _ in XCTFail("mode must never send a program mouse report"); return true }
        output.setInputEnabled(true); view.renderer.output = output; view.renderer.inputEnabled = true
        view.driver.feed("\u{1b}[?1003h\u{1b}[?1006h")
        XCTAssertTrue(view.scrollModeController.enter())
        view.scrollModeController.pointer.autoscrollIsVisible = { true }
        try send(.leftMouseDown,window,view,column:0.1,row:0.3,time:1)
        try send(.leftMouseDragged,window,view,column:5.9,row:20,time:1.1)
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
        XCTAssertFalse(view.scrollModeController.pointer.autoscrollArmed)
        XCTAssertFalse(try output.sendText("still blocked"))
    }

    func testWheelCancelsDragAndBulkRowsExtendTheExistingVisualSelection() throws {
        let (window,view) = try fixture(text:(0..<100).map { "line-\($0)\r\n" }.joined())
        defer { window.contentView = nil }
        _ = try view.driver.performScrollMode(.toggleSelection(linewise:true))
        _ = try view.driver.scrollModeMoveRows(3)
        XCTAssertEqual(try view.driver.readScrollModeSelection(),(0...3).map { "line-\($0)" }.joined(separator:"\n"))
        try send(.leftMouseDown,window,view,column:0.1,row:1.3,time:1)
        try send(.leftMouseDragged,window,view,column:4.9,row:1.3,time:1.1)
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:-3,wheel2:0,wheel3:0))
        view.renderer.scrollWheel(with:try XCTUnwrap(NSEvent(cgEvent:wheel)))
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
        XCTAssertTrue(view.scrollModeController.isActive)
    }

    func testViewHidingCancelsTheDragAndDoesNotRearmOnUnhide() throws {
        let (window,view) = try fixture()
        defer { window.contentView = nil }
        view.scrollModeController.pointer.autoscrollIsVisible = { true }
        try send(.leftMouseDown,window,view,column:0.1,row:1.3,time:1)
        try send(.leftMouseDragged,window,view,column:4.9,row:20,time:1.1)
        XCTAssertTrue(view.scrollModeController.pointer.autoscrollArmed)
        view.isHidden = true
        XCTAssertFalse(view.scrollModeController.pointer.autoscrollArmed)
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
        view.isHidden = false
        XCTAssertFalse(view.scrollModeController.pointer.autoscrollArmed)
    }

    func testPointerHandoffClearsKeyboardPrefixAndKeyboardCancelsTheDrag() throws {
        let (window,view) = try fixture()
        defer { window.contentView = nil }
        func key(_ text: String, code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:1,windowNumber:0,
                context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code))
        }
        view.renderer.keyDown(with:try key("g",code:5))
        XCTAssertTrue(view.scrollModeController.awaitingSecondG)
        try send(.leftMouseDown,window,view,column:0.1,row:1.3,time:1)
        XCTAssertFalse(view.scrollModeController.awaitingSecondG)
        try send(.leftMouseDragged,window,view,column:4.9,row:1.3,time:1.1)
        XCTAssertTrue(view.scrollModeController.pointer.hasGesture)
        view.renderer.keyDown(with:try key("j",code:38))
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
        let copied = try view.driver.readScrollModeSelection()
        try send(.leftMouseUp,window,view,column:20,row:1.3,time:1.2)
        XCTAssertEqual(try view.driver.readScrollModeSelection(),copied)
        view.renderer.keyDown(with:try key("g",code:5))
        let frame = view.presentedFrame
        let tiny = try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:-1,wheel2:0,wheel3:0))
        tiny.setIntegerValueField(.scrollWheelEventIsContinuous,value:1)
        tiny.setIntegerValueField(.scrollWheelEventScrollPhase,value:Int64(NSEvent.Phase.began.rawValue))
        let event = try XCTUnwrap(NSEvent(cgEvent:tiny))
        XCTAssertTrue(event.hasPreciseScrollingDeltas)
        view.renderer.scrollWheel(with:event)
        XCTAssertFalse(view.scrollModeController.awaitingSecondG)
        XCTAssertFalse(view.scrollModeController.overlay.title.contains(" · g"))
        XCTAssertTrue(view.presentedFrame?.rows[0] === frame?.rows[0],"sub-row wheel input only changes host decorations")
    }

    func testAQueuedAutoscrollWakeDoesNotRetainTheViewOrItsModeOwner() throws {
        let driver = try GhosttyVTDriver()
        weak var weakView: NativeTerminalScrollView?
        weak var weakPointer: NativeScrollModePointer?
        try autoreleasepool {
            let (window,view) = try fixture(driver:driver)
            defer { window.contentView = nil }
            weakView = view; weakPointer = view.scrollModeController.pointer
            view.scrollModeController.pointer.autoscrollIsVisible = { true }
            try send(.leftMouseDown,window,view,column:0.1,row:1.3,time:1)
            try send(.leftMouseDragged,window,view,column:0.1,row:20,time:1.1)
            XCTAssertTrue(view.scrollModeController.pointer.autoscrollArmed)
        }
        XCTAssertNil(weakView); XCTAssertNil(weakPointer)
        XCTAssertNil(try driver.scrollModeState)
    }

    func testWheelBankKeepsFractionsDropsInheritedMomentumAndBoundsOneEvent() {
        var bank = NativeScrollModeWheel()
        func rows(_ y: CGFloat,began: Bool = false,ended: Bool = false,momentumEnded: Bool = false) -> Int {
            bank.rows(deltaY:y,rowHeight:16,precise:true,began:began,ended:ended,momentumEnded:momentumEnded,hasPhase:true)
        }
        XCTAssertEqual(rows(-80),0,"an entry momentum tail is not a new gesture")
        XCTAssertEqual(rows(-4,began:true),0)
        XCTAssertEqual(rows(-4),0); XCTAssertEqual(rows(-8),1)
        XCTAssertEqual(rows(-100_000),40)
        XCTAssertEqual(rows(0,momentumEnded:true),0); XCTAssertEqual(rows(-80),0)
        XCTAssertEqual(rows(.nan,began:true),0)
        XCTAssertEqual(bank.rows(deltaY:-0.1,rowHeight:16,precise:false,began:false,ended:false,momentumEnded:false,hasPhase:false),1)
    }

    func testLocalWheelRowsStayInModeAndNeverCallTheProgramEncoder() throws {
        let (window,view) = try fixture()
        defer { window.contentView = nil }
        let before = try XCTUnwrap(view.driver.scrollModeState)
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:-3,wheel2:0,wheel3:0))
        view.renderer.scrollWheel(with:try XCTUnwrap(NSEvent(cgEvent:wheel)))
        XCTAssertTrue(view.scrollModeController.isActive)
        XCTAssertGreaterThan(try XCTUnwrap(view.driver.scrollModeState).cell.row,before.cell.row)
        XCTAssertFalse(view.scrollModeController.pointer.hasGesture)
    }
}
