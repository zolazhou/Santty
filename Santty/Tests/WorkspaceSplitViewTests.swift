import AppKit
import XCTest
@testable import Santty

@MainActor
final class WorkspaceSplitViewTests: XCTestCase {
    func testVerticalDividerDragAtCurrentCenterKeepsFractionsStable() {
        let splitView = makeSplitView(axis: .vertical, fractions: [0.5, 0.5])
        splitView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        splitView.needsLayout = true
        splitView.layoutSubtreeIfNeeded()

        let updatedFractions = splitView.debugFractionsForDraggingDividerAt(
            0,
            location: NSPoint(x: 500, y: 500)
        )

        XCTAssertEqual(updatedFractions[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(updatedFractions[1], 0.5, accuracy: 0.0001)
    }

    func testVerticalDividerDragDownGrowsTopPane() {
        let splitView = makeSplitView(axis: .vertical, fractions: [0.5, 0.5])
        splitView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        splitView.needsLayout = true
        splitView.layoutSubtreeIfNeeded()

        let updatedFractions = splitView.debugFractionsForDraggingDividerAt(
            0,
            location: NSPoint(x: 500, y: 400)
        )

        XCTAssertGreaterThan(updatedFractions[0], 0.5)
        XCTAssertLessThan(updatedFractions[1], 0.5)
    }

    private func makeSplitView(axis: SplitAxis, fractions: [CGFloat]) -> WorkspaceSplitView {
        WorkspaceSplitView(
            axis: axis,
            fractions: fractions,
            childViews: [NSView(), NSView()],
            childMinimumSizes: [
                NSSize(width: 240, height: 160),
                NSSize(width: 240, height: 160),
            ],
            dividerThickness: 6,
            onFractionsChange: { _, _ in }
        )
    }
}
