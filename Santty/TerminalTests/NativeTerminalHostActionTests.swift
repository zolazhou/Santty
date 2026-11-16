import AppKit
import Darwin
import GhosttyVt
import XCTest
@testable import Santty

final class HostActionBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    var data: Data { lock.withLock { value } }
    func append(_ data: Data) { lock.withLock { value.append(data) } }
}

@MainActor
final class NativeHostFixture {
    let view: NativeTerminalScrollView
    let window: NSWindow
    let output: NativeTerminalOutput
    let bytes = HostActionBytes()
    let board = NSPasteboard.withUniqueName()
    let actions: NativeTerminalHostActions
    init() throws {
        view = NativeTerminalScrollView(driver:try GhosttyVTDriver(),frame:.init(x:0,y:0,width:640,height:250))
        view.feed("published 界 e\u{301}")
        window = NSWindow(contentRect:view.frame,styleMask:[],backing:.buffered,defer:false)
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view.renderer))
        output = NativeTerminalOutput(driver:view.driver) { _ in }
        let bytes = bytes
        output.bindChecked { bytes.append($0); return true }; output.setInputEnabled(true)
        view.renderer.output = output; view.renderer.inputEnabled = true
        actions = view.hostActions
        let board = board
        actions.pasteboard = { board }
        actions.reviewPresenter = { _,_ in }
    }
    isolated deinit { window.contentView = nil; board.releaseGlobally() }
    func review(_ text: String = "a\nb") throws -> UUID {
        guard case let .review(id) = actions.submit(text) else { throw CLIError("Expected owned paste review") }
        return id
    }
}

@MainActor
final class NativeTerminalHostActionTests: XCTestCase {
    func testSafePasteUsesOneUserWriterAndDoesNotTouchPublishedPage() throws {
        let f = try NativeHostFixture(), frame = f.view.presentedFrame
        XCTAssertEqual(f.actions.submit("hello 界"),.accepted)
        XCTAssertEqual(f.bytes.data,Data("hello 界".utf8))
        XCTAssertEqual(f.view.presentedFrame?.rows.mapValues(\.cells),frame?.rows.mapValues(\.cells))
        XCTAssertEqual(f.view.presentedFrame?.topRow,frame?.topRow)
        XCTAssertEqual(f.view.presentedFrame?.totalRows,frame?.totalRows)
        XCTAssertTrue(f.window.firstResponder === f.view.renderer)
    }
    func testUnsafeConsentIsEscapedSingleUseAndLegacyCRLFIsOneCR() throws {
        let f = try NativeHostFixture()
        var review: NativeHostPasteReview?
        f.actions.reviewPresenter = { offered,_ in review = offered }
        let id = try f.review("a\r\nb")
        XCTAssertTrue(f.bytes.data.isEmpty)
        XCTAssertEqual(review?.preview,"a\\u{d}\\u{a}b")
        XCTAssertTrue(f.actions.completeReview(id:id,approved:true))
        XCTAssertEqual(f.bytes.data,Data("a\rb".utf8))
        XCTAssertFalse(f.actions.completeReview(id:id,approved:true))
    }
    func testBracketedNewlineRequiresNoReviewAndPreservesExactBytes() throws {
        let f = try NativeHostFixture()
        _ = f.view.driver.feed(Data("\u{1b}[?2004h".utf8))
        f.actions.reviewPresenter = { _,_ in XCTFail("VT accepts bracketed newline without consent") }
        XCTAssertEqual(f.actions.submit("a\r\nb"),.accepted)
        XCTAssertEqual(f.bytes.data,Data("\u{1b}[200~a\r\nb\u{1b}[201~".utf8))
    }
    func testEmbeddedPasteTerminatorUsesVTRejectionAndSanitization() throws {
        let f = try NativeHostFixture()
        _ = f.view.driver.feed(Data("\u{1b}[?2004h".utf8))
        let id = try f.review("a\u{1b}[201~b")
        XCTAssertTrue(f.bytes.data.isEmpty)
        XCTAssertTrue(f.actions.completeReview(id:id,approved:true))
        XCTAssertEqual(f.bytes.data,Data("\u{1b}[200~a [201~b\u{1b}[201~".utf8))
    }
    func testCancelAndReplacementNeverConsumeAnotherReview() throws {
        let f = try NativeHostFixture(), old = try f.review(), current = try f.review("new\nvalue")
        XCTAssertFalse(f.actions.completeReview(id:old,approved:true))
        XCTAssertEqual(f.actions.pendingReviewID,current)
        XCTAssertFalse(f.actions.completeReview(id:current,approved:false))
        XCTAssertNil(f.actions.pendingReviewID); XCTAssertTrue(f.bytes.data.isEmpty)
    }
    func testReboundWriterCannotReceiveOldConsent() throws {
        let f = try NativeHostFixture(), id = try f.review(), other = HostActionBytes()
        f.output.bindChecked { other.append($0); return true }
        XCTAssertFalse(f.actions.completeReview(id:id,approved:true))
        XCTAssertTrue(f.bytes.data.isEmpty); XCTAssertTrue(other.data.isEmpty)
    }
    func testSameDriverNewOutputCannotReceiveOldConsent() throws {
        let f = try NativeHostFixture(), id = try f.review(), other = HostActionBytes()
        let replacement = NativeTerminalOutput(driver:f.view.driver) { _ in }
        replacement.bindChecked { other.append($0); return true }; replacement.setInputEnabled(true)
        f.view.renderer.output = replacement
        XCTAssertFalse(f.actions.completeReview(id:id,approved:true))
        XCTAssertNil(f.actions.pendingReviewID); XCTAssertTrue(other.data.isEmpty)
    }
    func testDisableEnableAndSuppressionRoundTripsInvalidateConsent() throws {
        let f = try NativeHostFixture(), first = try f.review()
        f.output.setInputEnabled(false); f.output.setInputEnabled(true)
        XCTAssertFalse(f.actions.completeReview(id:first,approved:true))
        let second = try f.review(), owner = UUID()
        f.output.suppressUserInput(true,owner:owner); f.output.suppressUserInput(false,owner:owner)
        XCTAssertFalse(f.actions.completeReview(id:second,approved:true)); XCTAssertTrue(f.bytes.data.isEmpty)
    }
    func testRISAndBracketedModeChangeInvalidateConsentWithoutUIReset() throws {
        let f = try NativeHostFixture(), first = try f.review()
        _ = f.view.driver.feed(Data("\u{1b}c".utf8))
        XCTAssertFalse(f.actions.completeReview(id:first,approved:true))
        let second = try f.review()
        _ = f.view.driver.feed(Data("\u{1b}[?2004h".utf8))
        XCTAssertFalse(f.actions.completeReview(id:second,approved:true)); XCTAssertTrue(f.bytes.data.isEmpty)
    }
    func testOtherUserInputInvalidatesConsentButAutomaticReplyDoesNot() throws {
        let f = try NativeHostFixture(), first = try f.review()
        XCTAssertTrue(try f.output.sendText("x"))
        XCTAssertFalse(f.actions.completeReview(id:first,approved:true))
        let second = try f.review()
        let lease = f.output.userInputLease
        f.output.receive(Data("\u{1b}[5n".utf8))
        XCTAssertEqual(f.output.userInputLease,lease)
        XCTAssertTrue(f.actions.completeReview(id:second,approved:true))
        XCTAssertEqual(f.bytes.data,Data("x\u{1b}[0na\rb".utf8),"automatic reply never leaks into the captured paste sink")
    }
    func testLostResponderHiddenAndScrollModeRefusePasteWithoutReadingClipboard() throws {
        let f = try NativeHostFixture()
        var reads = 0
        let board = f.board
        f.actions.pasteboard = { reads+=1; return board }
        XCTAssertTrue(f.window.makeFirstResponder(nil))
        XCTAssertEqual(f.actions.paste(),.refused)
        XCTAssertTrue(f.window.makeFirstResponder(f.view.renderer))
        f.view.isHidden = true; XCTAssertEqual(f.actions.paste(),.refused); f.view.isHidden = false
        XCTAssertTrue(f.view.scrollModeController.enter())
        XCTAssertEqual(f.actions.paste(),.refused)
        XCTAssertTrue(f.actions.dragOperation(types:[.string]).isEmpty)
        f.view.renderer.paste(nil)
        XCTAssertEqual(reads,0); XCTAssertTrue(f.bytes.data.isEmpty)
    }
    func testModeRoundTripInvalidatesConsentAndDoesNotReplayOnExit() throws {
        let f = try NativeHostFixture(), id = try f.review()
        XCTAssertTrue(f.view.scrollModeController.enter()); f.view.scrollModeController.exit()
        XCTAssertFalse(f.actions.completeReview(id:id,approved:true)); XCTAssertTrue(f.bytes.data.isEmpty)
    }
    func testPasteboardURLAndDropTextUseSharedProductionRules() throws {
        let f = try NativeHostFixture()
        f.board.clearContents(); f.board.setString("https://example.invalid/a b?q=1&x=2",forType:.URL)
        XCTAssertEqual(f.actions.drop(from:f.board),.accepted)
        XCTAssertEqual(f.bytes.data,Data("https://example.invalid/a\\ b\\?q=1\\&x=2".utf8))
    }
    func testFilePasteEscapesPathsWithoutReadingOrStagingFiles() throws {
        let f = try NativeHostFixture()
        let root = "/tmp/santty-host-literal-\(UUID().uuidString)"
        f.board.writeObjects([URL(fileURLWithPath:root+"/a b's.txt") as NSURL,URL(fileURLWithPath:root+"/c&d.txt") as NSURL])
        XCTAssertEqual(f.actions.paste(),.accepted)
        XCTAssertEqual(f.bytes.data,Data("\(root)/a\\ b\\'s.txt \(root)/c\\&d.txt".utf8))
    }
    func testExplicitDropFocusesOnlyOwnedRendererAndPlainTextStaysUnescaped() throws {
        let f = try NativeHostFixture()
        XCTAssertTrue(f.window.makeFirstResponder(nil))
        f.board.setString("echo hello && pwd",forType:.string)
        XCTAssertEqual(f.actions.dragOperation(types:f.board.types),.copy)
        XCTAssertEqual(f.actions.drop(from:f.board),.accepted)
        XCTAssertTrue(f.window.firstResponder === f.view.renderer)
        XCTAssertEqual(f.bytes.data,Data("echo hello && pwd".utf8))
    }
    func testOversizedAndEmptyPayloadsNeverEnterVTOrWriter() throws {
        let f = try NativeHostFixture()
        XCTAssertEqual(f.actions.submit(""),.refused)
        XCTAssertEqual(f.actions.submit(String(repeating:"a",count:NativeTerminalHostActions.maximumPasteBytes+1)),.refused)
        XCTAssertTrue(f.bytes.data.isEmpty)
        XCTAssertThrowsError(try f.view.driver.prepareHostPaste(String(repeating:"a",count:1024*1024+1)))
    }
    func testWriterRefusalConsumesReviewWithoutRetry() throws {
        let f = try NativeHostFixture()
        f.output.bindChecked { _ in false }
        let id = try f.review()
        XCTAssertFalse(f.actions.completeReview(id:id,approved:true))
        XCTAssertFalse(f.actions.completeReview(id:id,approved:true)); XCTAssertNil(f.actions.pendingReviewID)
    }
    func testReadOnlyMenuSelectionAndCopyWorkAfterInputCloses() throws {
        let f = try NativeHostFixture()
        f.output.setInputEnabled(false); f.view.renderer.inputEnabled = false
        XCTAssertTrue(f.actions.canPerform(.selectAll)); f.view.renderer.selectAll(nil); f.view.renderer.copy(nil)
        XCTAssertEqual(f.board.string(forType:.string),"published 界 e\u{301}")
        XCTAssertTrue(f.bytes.data.isEmpty)
        XCTAssertFalse(f.view.renderer.validateMenuItem(NSMenuItem(title:"Paste",action:#selector(NativeTerminalInputView.paste(_:)),keyEquivalent:"v")))
    }
    func testMenuZoomPreservesSettingsResponderAndTransport() throws {
        let f = try NativeHostFixture(), theme = try NativeThemeCatalog.bundled().defaultTheme
        try f.view.applySettings(.init(theme:theme,fontSize:14,padding:7,paddingFill:.off,backgroundOpacity:0.25,cursorShape:.bar,cursorBlink:false))
        f.actions.zoomResetSize = 14
        f.view.renderer.increaseFontSize(nil)
        XCTAssertEqual(f.view.settings?.fontSize,15); XCTAssertEqual(f.view.settings?.padding,7)
        XCTAssertEqual(f.view.settings?.paddingFill,.off)
        XCTAssertEqual(f.view.settings?.backgroundOpacity,0.25); XCTAssertEqual(f.view.settings?.cursorShape,.bar)
        f.view.renderer.resetFontSize(nil); XCTAssertEqual(f.view.settings?.fontSize,14)
        XCTAssertTrue(f.window.firstResponder === f.view.renderer); XCTAssertTrue(f.bytes.data.isEmpty)
    }
    func testForeignDriverOutputCannotBecomeThisViewsHostOrInputSourceTarget() throws {
        let f = try NativeHostFixture(), foreignBytes = HostActionBytes()
        let foreign = NativeTerminalOutput(driver:try GhosttyVTDriver()) { _ in }
        foreign.bindChecked { foreignBytes.append($0); return true }; foreign.setInputEnabled(true)
        f.view.renderer.output = foreign
        XCTAssertEqual(f.actions.submit("must-not-retarget"),.refused)
        let port = NativeTerminalInputSourcePort(paneID:UUID(),view:f.view,isCurrent:{ true },
            foreground:{ .init(groupID:nil,processes:[]) })
        XCTAssertNil(port.target); XCTAssertTrue(foreignBytes.data.isEmpty)
    }

    func testReviewExpiresAtExistingBoundaryAndClockRegressionIsRefused() throws {
        let f = try NativeHostFixture()
        var now: TimeInterval = 100
        let actions = NativeTerminalHostActions(view:f.view,clock:{ now })
        actions.reviewPresenter = { _,_ in }
        guard case let .review(expiring) = actions.submit("a\nb") else { return XCTFail("Expected review") }
        now = 220
        XCTAssertFalse(actions.completeReview(id:expiring,approved:true))
        guard case let .review(regressing) = actions.submit("a\nb") else { return XCTFail("Expected review") }
        now = 219
        XCTAssertFalse(actions.completeReview(id:regressing,approved:true)); XCTAssertTrue(f.bytes.data.isEmpty)
    }

    func testOwnedRawPTYSeesOnlyConfirmedPasteAndExactVTBracketedBytes() async throws {
        let f = try NativeHostFixture(), lab = try NativeLocalPTYTestSession(driver:f.view.driver) { _ in }
        let fifo = lab.root.appendingPathComponent("host-control.fifo"), ack = lab.root.appendingPathComponent("host-ack")
        let legacy = lab.root.appendingPathComponent("host-legacy"), bracket = lab.root.appendingPathComponent("host-bracket")
        XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        let control = Darwin.open(fifo.path,O_RDWR|O_NONBLOCK|O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(control,0); defer { Darwin.close(control) }
        func wait(_ condition: () throws -> Bool) async throws {
            for _ in 0..<500 { if try condition() { return }; try await Task.sleep(for:.milliseconds(10)) }
            XCTFail("Owned host consumer timed out"); throw NativeLocalPTYError.shutdownTimeout
        }
        let script = """
        import os,sys,tty
        tty.setraw(0)
        ctl=os.open(sys.argv[1],os.O_RDONLY)
        def read_exact(n):
            data=b''
            while len(data)<n: data+=os.read(0,n-len(data))
            return data
        os.write(1,b'HOST-READY')
        os.read(ctl,1)
        os.write(1,b'\\x1b[5n')
        with open(sys.argv[2],'w') as f: f.write(read_exact(4).hex())
        os.read(ctl,1)
        with open(sys.argv[3],'w') as f: f.write(read_exact(3).hex())
        os.write(1,b'\\x1b[?2004hHOST-BRACKETED')
        with open(sys.argv[4],'w') as f: f.write(read_exact(16).hex())
        os.write(1,b'HOST-DONE')
        """
        do {
            let python = try XCTUnwrap(["/usr/bin/python3","/opt/homebrew/bin/python3"].first { FileManager.default.isExecutableFile(atPath:$0) })
            try lab.start(viewport:f.view.viewport,executable:python,args:["-c",script,fifo.path,ack.path,legacy.path,bracket.path])
            try await wait { try f.view.driver.readScreenText().contains("HOST-READY") }
            f.view.refresh(resizeTerminal:true); f.view.renderer.output = lab.output
            let id = try f.review("a\r\nb")
            var byte: UInt8 = 1
            XCTAssertEqual(Darwin.write(control,&byte,1),1)
            try await wait { (try? String(contentsOf:ack,encoding:.utf8)) == "1b5b306e" }
            XCTAssertTrue(f.actions.completeReview(id:id,approved:true))
            XCTAssertEqual(Darwin.write(control,&byte,1),1)
            try await wait { (try? String(contentsOf:legacy,encoding:.utf8)) == "610d62" }
            try await wait { try f.view.driver.readScreenText().contains("HOST-BRACKETED") }
            XCTAssertEqual(f.actions.submit("a\r\nb"),.accepted)
            try await wait { (try? String(contentsOf:bracket,encoding:.utf8)) == "1b5b3230307e610d0a621b5b3230317e" }
            try await wait { if case .exited = lab.state { return true }; return false }
            XCTAssertEqual(lab.outputDrainComplete,true)
            XCTAssertTrue(try f.view.driver.readScreenText().contains("HOST-DONE"))
            try await lab.stop()
        } catch { try? await lab.stop(); throw error }
    }

    func testNamedCLIKeysUseVTAndRespectScrollModeInputOwner() throws {
        let f = try NativeHostFixture()
        for value in UInt8(97)...UInt8(122) {
            let key = try CLIKey("ctrl+"+String(UnicodeScalar(value)))
            XCTAssertTrue(try f.output.send(NativeTerminalNamedKey.event(key)))
        }
        XCTAssertEqual(f.bytes.data,Data(1...26))
        XCTAssertTrue(try f.output.send(NativeTerminalNamedKey.event(CLIKey("enter"))))
        XCTAssertTrue(try f.output.send(NativeTerminalNamedKey.event(CLIKey("up"))))
        XCTAssertEqual(f.bytes.data.suffix(4),Data("\r\u{1b}[A".utf8))
        XCTAssertTrue(f.view.scrollModeController.enter())
        XCTAssertFalse(try f.output.send(NativeTerminalNamedKey.event(CLIKey("ctrl+c"))))
        f.view.scrollModeController.exit(); XCTAssertEqual(f.bytes.data.count,30)
    }
}
