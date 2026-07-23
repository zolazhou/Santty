import AppKit
import GhosttyTerminal
import XCTest
@testable import Santty

@MainActor
final class TerminalPaneInteractionTests: XCTestCase {
    func testTiledTerminalFocusRequestsWorkspaceFocus() {
        let paneID = PaneID()
        let controller = TerminalPaneController(id: paneID)
        var focusedPaneIDs: [PaneID] = []
        controller.onFocusRequest = { focusedPaneIDs.append($0) }

        controller.terminalDidChangeFocus(true)

        XCTAssertEqual(focusedPaneIDs, [paneID])
    }

    func testFloatingTerminalFocusKeepsPaneFloating() {
        let controller = TerminalPaneController()
        var focusedPaneIDs: [PaneID] = []
        controller.onFocusRequest = { focusedPaneIDs.append($0) }
        controller.updatePresentation(isFocused: true, isFloating: true)

        controller.terminalDidChangeFocus(true)

        XCTAssertTrue(focusedPaneIDs.isEmpty)
    }

    func testTerminalBlurDoesNotRequestWorkspaceFocus() {
        let controller = TerminalPaneController()
        var focusedPaneIDs: [PaneID] = []
        controller.onFocusRequest = { focusedPaneIDs.append($0) }

        controller.terminalDidChangeFocus(false)

        XCTAssertTrue(focusedPaneIDs.isEmpty)
    }

    func testAlreadyFocusedTerminalKeepsSameWorkspacePaneFocused() {
        let paneID = PaneID()
        let controller = TerminalPaneController(id: paneID)
        var focusedPaneID: PaneID? = paneID
        controller.onFocusRequest = { focusedPaneID = $0 }
        controller.updatePresentation(isFocused: true)

        controller.terminalDidChangeFocus(true)

        XCTAssertEqual(focusedPaneID, paneID)
    }

    func testClickingHostPaddingRequestsWorkspaceFocus() {
        let originalPadding = TerminalSettings.padding
        TerminalSettings.padding = 12
        defer { TerminalSettings.padding = originalPadding }

        let paneID = PaneID()
        let terminalView = RecordingTerminalView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 200)
        )
        let hostView = TerminalPaneHostView(paneID: paneID, terminalView: terminalView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        hostView.layoutSubtreeIfNeeded()

        var focusedPaneIDs: [PaneID] = []
        hostView.onFocusRequest = { focusedPaneIDs.append($0) }
        let paddingPoint = NSPoint(x: 6, y: hostView.bounds.midY)
        XCTAssertFalse(hostView.debugTerminalFrame.contains(paddingPoint))

        sendMouseEvent(
            .leftMouseDown,
            at: paddingPoint,
            in: window,
            eventNumber: 1,
            clickCount: 1
        )
        sendMouseEvent(
            .leftMouseUp,
            at: paddingPoint,
            in: window,
            eventNumber: 2,
            clickCount: 1
        )

        XCTAssertEqual(focusedPaneIDs, [paneID])
        XCTAssertTrue(terminalView.receivedMouseEvents.isEmpty)
    }

    func testHostDoesNotObserveTerminalClicksWithGestureRecognizer() {
        let terminalView = RecordingTerminalView(frame: .zero)
        let hostView = TerminalPaneHostView(paneID: PaneID(), terminalView: terminalView)

        XCTAssertFalse(hostView.gestureRecognizers.contains { $0 is NSClickGestureRecognizer })
    }

    func testPrimaryMouseSequencesReachTerminalView() {
        let terminalView = RecordingTerminalView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 200)
        )
        let hostView = TerminalPaneHostView(paneID: PaneID(), terminalView: terminalView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        hostView.layoutSubtreeIfNeeded()

        let start = NSPoint(x: hostView.debugTerminalFrame.midX, y: hostView.debugTerminalFrame.midY)
        let end = NSPoint(x: start.x + 40, y: start.y + 20)

        sendMouseEvent(.leftMouseDown, at: start, in: window, eventNumber: 1, clickCount: 1)
        sendMouseEvent(.leftMouseUp, at: start, in: window, eventNumber: 2, clickCount: 1)

        sendMouseEvent(.leftMouseDown, at: start, in: window, eventNumber: 3, clickCount: 1)
        sendMouseEvent(.leftMouseDragged, at: end, in: window, eventNumber: 4, clickCount: 1)
        sendMouseEvent(.leftMouseUp, at: end, in: window, eventNumber: 5, clickCount: 1)

        sendMouseEvent(.leftMouseDown, at: start, in: window, eventNumber: 6, clickCount: 1)
        sendMouseEvent(.leftMouseUp, at: start, in: window, eventNumber: 7, clickCount: 1)
        sendMouseEvent(.leftMouseDown, at: start, in: window, eventNumber: 8, clickCount: 2)
        sendMouseEvent(.leftMouseUp, at: start, in: window, eventNumber: 9, clickCount: 2)

        XCTAssertEqual(
            terminalView.receivedMouseEvents,
            [
                .down(clickCount: 1),
                .up(clickCount: 1),
                .down(clickCount: 1),
                .dragged(clickCount: 1),
                .up(clickCount: 1),
                .down(clickCount: 1),
                .up(clickCount: 1),
                .down(clickCount: 2),
                .up(clickCount: 2),
            ]
        )
    }

    private func sendMouseEvent(
        _ type: NSEvent.EventType,
        at location: NSPoint,
        in window: NSWindow,
        eventNumber: Int,
        clickCount: Int
    ) {
        guard
            let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: TimeInterval(eventNumber),
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumber,
                clickCount: clickCount,
                pressure: 1
            )
        else {
            return XCTFail("Failed to create mouse event")
        }

        window.sendEvent(event)
    }
}

@MainActor
private final class RecordingTerminalView: TerminalView {
    enum ReceivedMouseEvent: Equatable {
        case down(clickCount: Int)
        case dragged(clickCount: Int)
        case up(clickCount: Int)
    }

    private(set) var receivedMouseEvents: [ReceivedMouseEvent] = []

    override func mouseDown(with event: NSEvent) {
        receivedMouseEvents.append(.down(clickCount: event.clickCount))
    }

    override func mouseDragged(with event: NSEvent) {
        receivedMouseEvents.append(.dragged(clickCount: event.clickCount))
    }

    override func mouseUp(with event: NSEvent) {
        receivedMouseEvents.append(.up(clickCount: event.clickCount))
    }
}
