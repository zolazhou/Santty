import AppKit
import Darwin
import GhosttyVt
import XCTest
@testable import Santty

private final class ScrollUIBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    var data: Data { lock.withLock { stored } }
    func append(_ bytes: Data) { lock.withLock { stored.append(bytes) } }
}

@MainActor
final class NativeScrollModeUITests: XCTestCase {
    private func key(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
                     type: NSEvent.EventType = .keyDown, repeatKey: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with:type,location:.zero,modifierFlags:modifiers,timestamp:1,
            windowNumber:0,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:repeatKey,keyCode:code))
    }
    private func fixture() throws -> NativeTerminalScrollView {
        let view = NativeTerminalScrollView(driver:try GhosttyVTDriver(),frame:.init(x:0,y:0,width:640,height:250))
        view.feed((0..<100).map { "row-\($0) hello 界🙂\r\n" }.joined())
        return view
    }
    private func top(_ view: NativeTerminalScrollView) throws {
        view.renderer.keyDown(with:try key("g",code:5)); view.renderer.keyUp(with:try key("g",code:5,type:.keyUp))
        view.renderer.keyDown(with:try key("g",code:5))
    }
    private func attach(_ view: NativeTerminalScrollView) -> (NativeTerminalOutput, ScrollUIBytes) {
        // Connected panes receive a real layout before the visibility gate can
        // suppress painting. Keep the separate fixture-entry bad vector above.
        view.refresh(resizeTerminal:true)
        let bytes = ScrollUIBytes()
        let output = NativeTerminalOutput(driver:view.driver) { _ in }
        output.bindChecked { bytes.append($0); return true }; output.setInputEnabled(true)
        view.renderer.output = output; view.renderer.inputEnabled = true
        return (output,bytes)
    }

    func testFixtureMenuChordWorksWithoutAnInputWriterAndPaintsBadge() throws {
        let view = try fixture()
        XCTAssertFalse(view.renderer.inputEnabled)
        XCTAssertTrue(view.renderer.performKeyEquivalent(with:try key("s",code:1,modifiers:[.command,.shift])))
        XCTAssertTrue(view.scrollModeController.isActive)
        XCTAssertFalse(view.scrollModeController.overlay.isHidden)
        XCTAssertEqual(view.scrollModeController.overlay.title,"SCROLL")
        XCTAssertEqual(view.driver.rows,15)
        XCTAssertEqual(try view.driver.scrollModeState?.cell.row,100,"fractional live bottom starts at the real input cursor")
        let state = try view.driver.scrollModeState
        XCTAssertFalse(view.scrollModeController.overlay.cursorRect.isEmpty,
            "state=\(String(describing:state)) bounds=\(view.renderer.bounds) clip=\(view.renderer.visibleRect) viewport=\(String(describing:view.presentedViewport))")
        XCTAssertNil(view.scrollModeController.overlay.hitTest(.zero))
        XCTAssertFalse(view.scrollModeController.overlay.acceptsFirstResponder)
    }

    func testGGWordSelectionCopyEscThenExitKeepTheRendererAsResponder() throws {
        let view = try fixture()
        let window = NSWindow(contentRect:view.frame,styleMask:[],backing:.buffered,defer:false)
        window.contentView = view; defer { window.contentView = nil }
        XCTAssertTrue(window.makeFirstResponder(view.renderer))
        XCTAssertTrue(view.scrollModeController.enter())
        try top(view)
        XCTAssertEqual(try view.driver.scrollModeState?.cell,.init(column:0,row:0))
        view.renderer.keyDown(with:try key("v",code:9,modifiers:.shift))
        XCTAssertEqual(view.scrollModeController.overlay.title,"SELECT LINE")
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        view.scrollModeController.copyPasteboard = { board }
        view.renderer.keyDown(with:try key("y",code:16))
        XCTAssertEqual(board.string(forType:.string),"row-0 hello 界🙂")
        XCTAssertNotNil(view.scrollModeController.overlay.flashRect)
        view.renderer.keyDown(with:try key("\u{1b}",code:53))
        XCTAssertTrue(view.scrollModeController.isActive)
        XCTAssertNil(try view.driver.scrollModeState?.selection)
        view.renderer.keyDown(with:try key("\u{1b}",code:53))
        XCTAssertFalse(view.scrollModeController.isActive)
        XCTAssertTrue(window.firstResponder === view.renderer)
    }

    func testAllUserInputIsSuppressedButAutomaticQueriesStillDrain() throws {
        let view = try fixture(), (output,bytes) = attach(view)
        XCTAssertTrue(view.scrollModeController.enter())
        XCTAssertFalse(try output.sendText("forbidden")); XCTAssertFalse(try output.paste("forbidden\n"))
        XCTAssertFalse(try output.sendKey(GHOSTTY_KEY_ENTER))
        view.renderer.keyDown(with:try key("c",code:8,modifiers:.control))
        view.renderer.keyUp(with:try key("c",code:8,modifiers:.control,type:.keyUp))
        view.renderer.insertText("late IME",replacementRange:.init(location:NSNotFound,length:0))
        view.renderer.setMarkedText("preedit",selectedRange:.init(location:0,length:0),replacementRange:.init(location:NSNotFound,length:0))
        view.renderer.doCommand(by:#selector(NSResponder.insertNewline(_:)))
        view.renderer.paste(nil)
        XCTAssertFalse(view.renderer.hasMarkedText()); XCTAssertTrue(bytes.data.isEmpty)
        output.receive(Data("\u{1b}[5n".utf8))
        XCTAssertEqual(bytes.data,Data("\u{1b}[0n".utf8))
        view.scrollModeController.exit()
        XCTAssertTrue(try output.sendText("fresh"))
        XCTAssertEqual(bytes.data.suffix(5),Data("fresh".utf8))
    }

    func testExitKeyReleaseAndRepeatAreNotReplayedToKittyConsumer() throws {
        let view = try fixture(), (_,bytes) = attach(view)
        view.driver.feed("\u{1b}[>31u")
        XCTAssertTrue(view.scrollModeController.enter())
        view.renderer.keyDown(with:try key("j",code:38))
        view.renderer.keyDown(with:try key("q",code:12))
        XCTAssertFalse(view.scrollModeController.isActive)
        view.renderer.keyUp(with:try key("q",code:12,type:.keyUp))
        view.renderer.keyDown(with:try key("j",code:38,repeatKey:true))
        view.renderer.keyUp(with:try key("j",code:38,type:.keyUp))
        XCTAssertTrue(bytes.data.isEmpty)
        view.renderer.keyDown(with:try key("x",code:7))
        XCTAssertFalse(bytes.data.isEmpty,"a new live press resumes the normal encoder")
    }

    func testFlagsChangedNeverUsesCharactersAndModeConsumesUnmappedKeys() throws {
        let view = try fixture(), (_,bytes) = attach(view)
        view.driver.feed("\u{1b}[>31u")
        XCTAssertTrue(view.scrollModeController.enter())
        let flags = try XCTUnwrap(NSEvent.keyEvent(with:.flagsChanged,location:.zero,modifierFlags:.shift,
            timestamp:1,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:56))
        view.renderer.flagsChanged(with:flags)
        view.renderer.keyDown(with:try key("unmapped",code:123,modifiers:.option))
        XCTAssertTrue(bytes.data.isEmpty)
        XCTAssertFalse(view.renderer.performKeyEquivalent(with:try key("q",code:12,modifiers:.command)),"app Quit remains available")
    }

    func testCmdPasteAndSelectAllAreConsumedCopyOnlyOnExplicitRequest() throws {
        let view = try fixture(), (_,bytes) = attach(view)
        XCTAssertTrue(view.scrollModeController.enter())
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("unchanged",forType:.string)
        view.scrollModeController.copyPasteboard = { board }
        XCTAssertTrue(view.renderer.performKeyEquivalent(with:try key("v",code:9,modifiers:.command)))
        XCTAssertTrue(view.renderer.performKeyEquivalent(with:try key("a",code:0,modifiers:.command)))
        XCTAssertTrue(view.renderer.performKeyEquivalent(with:try key("c",code:8,modifiers:.command)))
        XCTAssertEqual(board.string(forType:.string),"unchanged")
        XCTAssertTrue(bytes.data.isEmpty)
    }

    func testPointerWheelAndProgramModesCannotLeakThroughKeyboardMode() throws {
        let view = try fixture(), (_,bytes) = attach(view)
        view.driver.feed("\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1007h")
        let modes = try view.driver.pointerModes
        XCTAssertTrue(view.scrollModeController.enter())
        let click = try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:.init(x:10,y:10),modifierFlags:[],
            timestamp:1,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
        view.renderer.mouseDown(with:click)
        view.renderer.mouseDragged(with:click); view.renderer.mouseUp(with:click)
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:50,wheel2:0,wheel3:0))
        view.renderer.scrollWheel(with:try XCTUnwrap(NSEvent(cgEvent:wheel)))
        XCTAssertTrue(bytes.data.isEmpty)
        XCTAssertEqual(try view.driver.pointerModes,modes,"do not turn off VT program modes to implement host ownership")
    }

    func testEnteringDiscardsPreeditWithoutCommittingItAndResetReleasesTheGate() throws {
        let view = try fixture(), (output,bytes) = attach(view)
        view.renderer.setMarkedText("pending",selectedRange:.init(location:1,length:0),replacementRange:.init(location:NSNotFound,length:0))
        XCTAssertTrue(view.renderer.hasMarkedText())
        XCTAssertTrue(view.scrollModeController.enter()); XCTAssertFalse(view.renderer.hasMarkedText())
        XCTAssertTrue(bytes.data.isEmpty)
        view.resetPresentation()
        XCTAssertFalse(view.scrollModeController.isActive); XCTAssertTrue(view.scrollModeController.overlay.isHidden)
        XCTAssertTrue(try output.sendText("new")); XCTAssertEqual(bytes.data,Data("new".utf8))
    }

    func testResetBeforeUICallbackConsumesTheCurrentKeyInsteadOfTypingIntoANewEpoch() throws {
        let view = try fixture(), (_,bytes) = attach(view)
        XCTAssertTrue(view.scrollModeController.enter())
        view.driver.reset()
        view.renderer.keyDown(with:try key("q",code:12))
        XCTAssertFalse(view.scrollModeController.isActive)
        XCTAssertTrue(bytes.data.isEmpty)
    }

    func testReplacingOutputEndsModeAndReleasesOnlyItsOwnSuppressionToken() throws {
        let view = try fixture(), (old,bytes) = attach(view)
        XCTAssertTrue(view.scrollModeController.enter())
        let independentOwner = UUID()
        old.suppressUserInput(true,owner:independentOwner)
        let replacement = NativeTerminalOutput(driver:view.driver) { _ in }
        replacement.bindChecked { _ in XCTFail("no automatic input on swap"); return true }; replacement.setInputEnabled(true)
        view.renderer.output = replacement
        XCTAssertFalse(view.scrollModeController.isActive)
        XCTAssertFalse(try old.sendText("still suppressed by another owner"))
        old.suppressUserInput(false,owner:independentOwner)
        XCTAssertTrue(try old.sendText("allowed")); XCTAssertEqual(bytes.data,Data("allowed".utf8))
    }

    func testHoldKeepsOwnershipAndEscapeAlwaysWorksWithoutRevealingHeldText() throws {
        let view = try fixture()
        XCTAssertTrue(view.scrollModeController.enter())
        let before = view.presentedFrame
        view.driver.feed("\u{1b}[?2026hHELD")
        view.renderer.keyDown(with:try key("j",code:38))
        XCTAssertTrue(view.scrollModeController.isActive)
        XCTAssertTrue(view.presentedFrame?.rows[0] === before?.rows[0])
        view.renderer.keyDown(with:try key("\u{1b}",code:53))
        XCTAssertFalse(view.scrollModeController.isActive)
        XCTAssertNotNil(view.driver.renderHoldRemaining)
    }

    func testFocusResetDoesNotExitModeOrChangeFirstResponderOnOutput() throws {
        let view = try fixture()
        let window = NSWindow(contentRect:view.frame,styleMask:[],backing:.buffered,defer:false)
        window.contentView = view; defer { window.contentView = nil }
        window.makeFirstResponder(view.renderer)
        XCTAssertTrue(view.scrollModeController.enter())
        view.renderer.keyDown(with:try key("g",code:5))
        XCTAssertTrue(view.scrollModeController.awaitingSecondG)
        view.renderer.resetInputState()
        XCTAssertTrue(view.scrollModeController.isActive); XCTAssertFalse(view.scrollModeController.awaitingSecondG)
        view.feed("background")
        XCTAssertTrue(window.firstResponder === view.renderer)
    }

    func testPinnedBindingsIncludeArrowsHalfPagesWordsAndShiftVariants() throws {
        let vectors: [(String,UInt16,NSEvent.ModifierFlags,NativeScrollModeKeyAction)] = [
            ("",123,[],.move(.left)), ("",124,[],.move(.right)), ("",125,[],.move(.down)), ("",126,[],.move(.up)),
            ("d",2,.control,.move(.halfDown)), ("u",32,.control,.move(.halfUp)),
            ("f",3,.control,.move(.pageDown)), ("b",11,.control,.move(.pageUp)),
            ("w",13,[],.move(.wordForward(big:false))), ("w",13,.shift,.move(.wordForward(big:true))),
            ("b",11,[],.move(.wordBackward(big:false))), ("e",14,.shift,.move(.wordEnd(big:true))),
            ("6",22,.shift,.move(.firstNonblank)), ("4",21,.shift,.move(.lineEnd)),
            ("g",5,.shift,.move(.bottom)), ("g",5,[],.awaitSecondG)]
        for (text,code,mods,expected) in vectors {
            XCTAssertEqual(NativeScrollModeKeyAction(event:try key(text,code:code,modifiers:mods),awaitingSecondG:false),expected)
        }
        XCTAssertEqual(NativeScrollModeKeyAction(event:try key("g",code:5),awaitingSecondG:true),.move(.top))
    }

    func testControllerReleaseCannotLeaveAnOtherwiseLiveOutputSuppressed() throws {
        let bytes = ScrollUIBytes()
        let driver = try GhosttyVTDriver()
        let output = NativeTerminalOutput(driver:driver) { _ in }
        output.bindChecked { bytes.append($0); return true }; output.setInputEnabled(true)
        weak var weakView: NativeTerminalScrollView?
        try autoreleasepool {
            let view = NativeTerminalScrollView(driver:driver,frame:.init(x:0,y:0,width:320,height:144))
            view.feed("owned"); view.refresh(resizeTerminal:true)
            view.renderer.output = output; weakView = view
            XCTAssertTrue(view.scrollModeController.enter())
            XCTAssertFalse(try output.sendText("blocked"))
        }
        XCTAssertNil(weakView)
        XCTAssertNil(try driver.scrollModeState)
        XCTAssertTrue(try output.sendText("fresh")); XCTAssertEqual(bytes.data,Data("fresh".utf8))
    }

    func testHiddenConnectedOutputDoesNotPaintOrStealResponderDuringMode() throws {
        let view = try fixture(), (output,_) = attach(view)
        XCTAssertTrue(view.scrollModeController.enter())
        let conversions = view.source.convertedRows, frame = view.presentedFrame
        output.receive(Data("hidden-new".utf8))
        view.parsedOutput(reset:false)
        XCTAssertTrue(view.hasPendingOutput); XCTAssertEqual(view.source.convertedRows,conversions)
        XCTAssertTrue(view.presentedFrame?.rows[0] === frame?.rows[0])
        XCTAssertTrue(view.scrollModeController.isActive)
        XCTAssertFalse(try output.sendText("blocked"))
    }

    func testMotionBudgetErrorKeepsTheGateAndCursorRatherThanTypingTheKey() throws {
        let view = NativeTerminalScrollView(driver:try GhosttyVTDriver(),frame:.init(x:0,y:0,width:640,height:250))
        view.feed(String(repeating:"\r\n",count:1000)+"end")
        let (output,bytes) = attach(view)
        XCTAssertTrue(view.scrollModeController.enter()); try top(view)
        let before = try view.driver.scrollModeState
        view.renderer.keyDown(with:try key("w",code:13))
        XCTAssertNotNil(view.scrollModeController.lastError)
        XCTAssertEqual(try view.driver.scrollModeState,before)
        XCTAssertTrue(bytes.data.isEmpty); XCTAssertFalse(try output.sendText("blocked"))
    }

    func testModifiedCommandCopyDoesNotSilentlyInvokePlainCommandCopy() throws {
        let view = try fixture()
        XCTAssertTrue(view.scrollModeController.enter()); try top(view)
        view.renderer.keyDown(with:try key("v",code:9,modifiers:.shift))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        view.scrollModeController.copyPasteboard = { XCTFail("not the plain Cmd-C binding"); return board }
        XCTAssertFalse(view.renderer.performKeyEquivalent(with:try key("c",code:8,modifiers:[.command,.option])))
    }

    func testOwnedRawPTYReceivesAutomaticReplyButNoModeInputOrExitReplay() async throws {
        let view = try fixture()
        view.refresh(resizeTerminal:true)
        let lab = try NativeLocalPTYTestSession(driver:view.driver) { _ in }
        let fifo = lab.root.appendingPathComponent("mode-control.fifo")
        let ack = lab.root.appendingPathComponent("mode-ack"), extra = lab.root.appendingPathComponent("mode-extra")
        XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        let control = Darwin.open(fifo.path,O_RDWR|O_NONBLOCK|O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(control,0); defer { Darwin.close(control) }
        func wait(_ condition: () throws -> Bool) async throws {
            for _ in 0..<500 { if try condition() { return }; try await Task.sleep(for:.milliseconds(10)) }
            XCTFail("Owned mode consumer timed out"); throw NativeLocalPTYError.shutdownTimeout
        }
        let script = """
        import os,sys,tty,select
        tty.setraw(0)
        ctl=os.open(sys.argv[1],os.O_RDONLY)
        os.write(1,b'MODE-READY')
        os.read(ctl,1)
        os.write(1,b'\\x1b[5n')
        data=b''
        while len(data)<4: data+=os.read(0,4-len(data))
        with open(sys.argv[2],'w') as f: f.write(data.hex())
        os.read(ctl,1)
        extra=b''
        while len(extra)<16384 and select.select([0],[],[],0)[0]: extra+=os.read(0,4096)
        with open(sys.argv[3],'w') as f: f.write(extra.hex() if extra else 'EMPTY')
        os.write(1,b'PROGRAM-DONE')
        """
        do {
            let python = try XCTUnwrap(["/usr/bin/python3","/opt/homebrew/bin/python3"].first { FileManager.default.isExecutableFile(atPath:$0) })
            try lab.start(viewport:view.viewport,executable:python,args:["-c",script,fifo.path,ack.path,extra.path])
            try await wait { try view.driver.readScreenText().contains("MODE-READY") }
            // First owned presentation precedes the renderer's initial binding;
            // no hidden-connected paint gate or real user window is bypassed.
            view.refresh(resizeTerminal:true)
            view.renderer.output = lab.output; view.renderer.inputEnabled = true
            XCTAssertTrue(view.scrollModeController.enter())
            let published = try XCTUnwrap(view.presentedViewport), cell = view.renderer.cellSize
            func gesture(_ step: NativeSelectionInput.Step, column: Int, x: CGFloat, time: Double) -> NativeSelectionInput {
                .init(step:step,column:column,row:published.firstRow,position:.init(x:x,y:5),cell:cell,
                    viewportHeight:published.viewportHeight,time:time,doubleClickInterval:0.5)
            }
            let press = try XCTUnwrap(view.driver.selectScrollMode(gesture(.press,column:0,x:1,time:1),
                relativeTo:published,expectedColumns:view.driver.columns))
            _ = try view.driver.selectScrollMode(gesture(.drag,column:3,x:3.9*cell.width,time:1.1),
                relativeTo:published,expectedColumns:view.driver.columns,token:press.token)
            XCTAssertEqual(try view.driver.readScrollModeSelection(),"MODE")
            XCTAssertFalse(try lab.output.sendText("POISON\r"))
            view.renderer.insertText("IMEPOISON",replacementRange:.init(location:NSNotFound,length:0))
            view.renderer.keyDown(with:try key("c",code:8,modifiers:.control))
            var byte: UInt8 = 1
            XCTAssertEqual(Darwin.write(control,&byte,1),1)
            try await wait { (try? String(contentsOf:ack,encoding:.utf8)) == "1b5b306e" }
            XCTAssertTrue(view.scrollModeController.isActive)
            view.scrollModeController.exit()
            XCTAssertEqual(Darwin.write(control,&byte,1),1)
            try await wait { (try? String(contentsOf:extra,encoding:.utf8)) == "EMPTY" }
            try await wait { if case .exited = lab.state { return true }; return false }
            XCTAssertEqual(lab.outputDrainComplete,true)
            XCTAssertTrue(try view.driver.readScreenText().contains("PROGRAM-DONE"))
            try await lab.stop()
        } catch { view.scrollModeController.exit(refresh:false); try? await lab.stop(); throw error }
    }

    func testFlashHasOneFiniteTaskAndDoesNotParseOrMoveTheViewport() async throws {
        let view = try fixture()
        XCTAssertTrue(view.scrollModeController.enter()); try top(view)
        view.renderer.keyDown(with:try key("v",code:9,modifiers:.shift))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(view.scrollModeController.copy(to:board))
        let before = view.presentedViewport
        XCTAssertNotNil(view.scrollModeController.overlay.flashRect)
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertNil(view.scrollModeController.overlay.flashRect)
        XCTAssertEqual(view.presentedViewport?.offset,before?.offset)
    }
}
