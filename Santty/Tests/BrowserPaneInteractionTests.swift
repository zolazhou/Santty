import AppKit
import WebKit
import XCTest
@testable import Santty

@MainActor
final class BrowserPaneInteractionTests: XCTestCase {
    func testTiledBrowserClickRequestsWorkspaceFocus() {
        let paneID = PaneID()
        let hostView = BrowserPaneHostView(paneID: paneID)
        var focusedPaneIDs: [PaneID] = []
        hostView.onFocusRequest = { focusedPaneIDs.append($0) }

        hostView.webView.onMouseDown?()

        XCTAssertEqual(focusedPaneIDs, [paneID])
    }

    func testFloatingBrowserClickKeepsPaneFloating() {
        let paneID = PaneID()
        let hostView = BrowserPaneHostView(paneID: paneID)
        var focusedPaneIDs: [PaneID] = []
        hostView.onFocusRequest = { focusedPaneIDs.append($0) }
        hostView.updatePresentation(isFocused: true, isFloating: true)

        hostView.webView.onMouseDown?()

        XCTAssertTrue(focusedPaneIDs.isEmpty)
    }

    func testStartIfNeededFocusesAddressFieldBeforeLoad() {
        let controller = BrowserPaneController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.hostView
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        controller.startIfNeeded()

        XCTAssertTrue(controller.browserHostView.locationBar.isBarVisible)
        XCTAssertNotNil(controller.browserHostView.addressField.currentEditor())
    }

    func testStartIfNeededDoesNotTouchHiddenAddressFieldAfterLoad() {
        let controller = BrowserPaneController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.hostView
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        // A windowed host can auto-select the address field as initial first
        // responder; a real load moves focus to the web view on submit.
        controller.webView(controller.browserHostView.webView, didStartProvisionalNavigation: nil)
        window.makeFirstResponder(controller.browserHostView.webView)
        controller.webView(controller.browserHostView.webView, didFinish: nil)

        controller.startIfNeeded()

        XCTAssertFalse(controller.browserHostView.locationBar.isBarVisible)
        XCTAssertNil(controller.browserHostView.addressField.currentEditor())
    }

    func testLocationBarHidesAfterLoadFinishes() {
        let controller = BrowserPaneController()
        let hostView = controller.browserHostView

        controller.webView(hostView.webView, didStartProvisionalNavigation: nil)
        XCTAssertTrue(hostView.locationBar.isBarVisible)

        controller.webView(hostView.webView, didFinish: nil)
        XCTAssertFalse(hostView.locationBar.isBarVisible)
    }

    func testFailedLoadKeepsLocationBarAndShowsError() {
        let controller = BrowserPaneController()
        let hostView = controller.browserHostView
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotFindHost,
            userInfo: [NSLocalizedDescriptionKey: "A server with the specified hostname could not be found."]
        )

        controller.webView(hostView.webView, didStartProvisionalNavigation: nil)
        controller.webView(
            hostView.webView, didFailProvisionalNavigation: nil, withError: error
        )

        XCTAssertTrue(hostView.locationBar.isBarVisible)
        XCTAssertTrue(hostView.isErrorVisible)
    }

    func testCancelledLoadIsNotTreatedAsFailure() {
        let controller = BrowserPaneController()
        let hostView = controller.browserHostView
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        controller.webView(hostView.webView, didStartProvisionalNavigation: nil)
        controller.webView(
            hostView.webView, didFailProvisionalNavigation: nil, withError: error
        )

        XCTAssertTrue(hostView.locationBar.isBarVisible)
        XCTAssertFalse(hostView.isErrorVisible)
    }

    func testFocusLocationBarRevealsAndFocusesAfterLoad() {
        let controller = BrowserPaneController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.hostView
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        controller.webView(controller.browserHostView.webView, didFinish: nil)

        controller.focusLocationBar()

        XCTAssertTrue(controller.browserHostView.locationBar.isBarVisible)
        XCTAssertNotNil(controller.browserHostView.addressField.currentEditor())
    }

    func testEscapeHidesLocationBarAndReturnsFocusToWebView() {
        let controller = BrowserPaneController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.hostView
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        let hostView = controller.browserHostView
        controller.webView(hostView.webView, didStartProvisionalNavigation: nil)
        controller.webView(hostView.webView, didFinish: nil)
        controller.focusLocationBar()

        hostView.locationBar.onCancel?()

        XCTAssertFalse(hostView.locationBar.isBarVisible)
        XCTAssertTrue(window.firstResponder === hostView.webView)
    }

    func testBrowserPaneStateSurvivesTilingTabSwitch() throws {
        let loadExpectation = expectation(description: "page loaded")
        let waiter = NavigationWaiter(didFinishExpectation: loadExpectation)

        let browserPaneID = PaneID()
        let otherPaneID = PaneID()
        let hostView = BrowserPaneHostView(paneID: browserPaneID)
        hostView.showWebView()
        let webView = hostView.webView
        webView.navigationDelegate = waiter

        let tilingView = WorkspaceTilingView(
            dividerThickness: AppAppearanceSettings.workspaceDividerThickness
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = tilingView
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        tilingView.setLayoutNode(.panel(browserPaneID), paneViews: [browserPaneID: hostView])
        window.layoutIfNeeded()

        webView.loadHTMLString(
            "<script>window.__santtyState = 'alive'</script><body>probe</body>",
            baseURL: nil
        )
        wait(for: [loadExpectation], timeout: 10)

        // Switch to another tab and back, exactly like rebuildWorkspaceLayout.
        tilingView.setLayoutNode(.panel(otherPaneID), paneViews: [otherPaneID: NSView()])
        window.layoutIfNeeded()
        tilingView.setLayoutNode(.panel(browserPaneID), paneViews: [browserPaneID: hostView])
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let stateExpectation = expectation(description: "state evaluated")
        var state: String?
        webView.evaluateJavaScript("window.__santtyState ?? 'gone'") { result, _ in
            state = result as? String
            stateExpectation.fulfill()
        }
        wait(for: [stateExpectation], timeout: 10)

        XCTAssertEqual(state, "alive", "Browser pane lost its page after a tab switch")
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    let didFinishExpectation: XCTestExpectation

    init(didFinishExpectation: XCTestExpectation) {
        self.didFinishExpectation = didFinishExpectation
    }

    nonisolated func webView(_: WKWebView, didFinish _: WKNavigation!) {
        didFinishExpectation.fulfill()
    }
}
