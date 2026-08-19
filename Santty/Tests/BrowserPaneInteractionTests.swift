import AppKit
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
}
