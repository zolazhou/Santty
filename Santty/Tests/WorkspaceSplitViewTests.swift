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

    func testHorizontalDividerDragUpdatesConstraintBackedLayout() throws {
        let splitView = makeSplitView(axis: .horizontal, fractions: [0.5, 0.5])
        splitView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        splitView.needsLayout = true
        splitView.layoutSubtreeIfNeeded()

        splitView.debugApplyDragForDividerAt(0, location: NSPoint(x: 700, y: 300))

        let firstFrame = try XCTUnwrap(splitView.debugChildFrame(at: 0))
        let dividerFrame = try XCTUnwrap(splitView.debugDividerFrame(at: 0))
        let secondFrame = try XCTUnwrap(splitView.debugChildFrame(at: 1))

        XCTAssertGreaterThan(firstFrame.width, 500)
        XCTAssertEqual(dividerFrame.minX, firstFrame.maxX, accuracy: 0.0001)
        XCTAssertEqual(secondFrame.minX, dividerFrame.maxX, accuracy: 0.0001)
        XCTAssertEqual(secondFrame.maxX, splitView.bounds.maxX, accuracy: 0.0001)
    }

    func testAnimatedHorizontalResizeComputesStablePaneAndDividerTargets() throws {
        let splitView = makeSplitView(axis: .horizontal, fractions: [0.5, 0.5])
        splitView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        splitView.needsLayout = true
        splitView.layoutSubtreeIfNeeded()

        splitView.setFractions([0.7, 0.3], animated: true)

        XCTAssertEqual(splitView.currentFractions[0], 0.7, accuracy: 0.0001)
        XCTAssertEqual(splitView.currentFractions[1], 0.3, accuracy: 0.0001)

        let firstFrame = try XCTUnwrap(splitView.debugChildFrame(at: 0))
        let dividerFrame = try XCTUnwrap(splitView.debugDividerFrame(at: 0))
        let secondFrame = try XCTUnwrap(splitView.debugChildFrame(at: 1))

        XCTAssertEqual(firstFrame.width, 695.8, accuracy: 0.0001)
        XCTAssertEqual(dividerFrame.minX, firstFrame.maxX, accuracy: 0.0001)
        XCTAssertEqual(dividerFrame.width, 6, accuracy: 0.0001)
        XCTAssertEqual(secondFrame.minX, dividerFrame.maxX, accuracy: 0.0001)
        XCTAssertEqual(secondFrame.maxX, splitView.bounds.maxX, accuracy: 0.0001)
    }

    func testInterruptedAnimatedResizeKeepsLatestTargetFractionsAndFrames() throws {
        let splitView = makeSplitView(axis: .horizontal, fractions: [0.5, 0.5])
        splitView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        splitView.needsLayout = true
        splitView.layoutSubtreeIfNeeded()

        splitView.setFractions([0.7, 0.3], animated: true)
        splitView.setFractions([0.4, 0.6], animated: true)

        XCTAssertEqual(splitView.currentFractions[0], 0.4, accuracy: 0.0001)
        XCTAssertEqual(splitView.currentFractions[1], 0.6, accuracy: 0.0001)

        let firstFrame = try XCTUnwrap(splitView.debugChildFrame(at: 0))
        let dividerFrame = try XCTUnwrap(splitView.debugDividerFrame(at: 0))
        let secondFrame = try XCTUnwrap(splitView.debugChildFrame(at: 1))

        XCTAssertEqual(firstFrame.width, 397.6, accuracy: 0.0001)
        XCTAssertEqual(dividerFrame.minX, firstFrame.maxX, accuracy: 0.0001)
        XCTAssertEqual(dividerFrame.width, 6, accuracy: 0.0001)
        XCTAssertEqual(secondFrame.minX, dividerFrame.maxX, accuracy: 0.0001)
        XCTAssertEqual(secondFrame.maxX, splitView.bounds.maxX, accuracy: 0.0001)
    }

    func testAnimatedParentResizeRelayoutsNestedSplitWithTargetBounds() throws {
        let nestedTopView = NSView()
        let nestedBottomView = NSView()
        let nestedSplitView = makeSplitView(
            axis: .vertical,
            fractions: [0.5, 0.5],
            childViews: [nestedTopView, nestedBottomView]
        )
        let outerSplitView = makeSplitView(
            axis: .horizontal,
            fractions: [0.5, 0.5],
            childViews: [NSView(), nestedSplitView]
        )
        outerSplitView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        outerSplitView.needsLayout = true
        outerSplitView.layoutSubtreeIfNeeded()

        outerSplitView.setFractions([0.3, 0.7], animated: true)

        let nestedFrame = try XCTUnwrap(outerSplitView.debugChildFrame(at: 1))
        let nestedTopFrame = try XCTUnwrap(nestedSplitView.debugChildFrame(at: 0))
        let nestedDividerFrame = try XCTUnwrap(nestedSplitView.debugDividerFrame(at: 0))
        let nestedBottomFrame = try XCTUnwrap(nestedSplitView.debugChildFrame(at: 1))

        XCTAssertEqual(nestedFrame.maxX, outerSplitView.bounds.maxX, accuracy: 0.0001)
        XCTAssertEqual(nestedTopFrame.width, nestedFrame.width, accuracy: 0.5)
        XCTAssertEqual(nestedTopFrame.height, 297, accuracy: 0.0001)
        XCTAssertEqual(nestedDividerFrame.height, 6, accuracy: 0.0001)
        XCTAssertEqual(nestedBottomFrame.width, nestedFrame.width, accuracy: 0.5)
        XCTAssertEqual(nestedBottomFrame.height, 297, accuracy: 0.0001)
    }

    func testHorizontalDragCanShrinkNestedVerticalSplitToMinimumWidth() throws {
        let nestedSplitView = makeSplitView(axis: .vertical, fractions: [0.5, 0.5])
        let outerSplitView = makeSplitView(
            axis: .horizontal,
            fractions: [0.5, 0.5],
            childViews: [NSView(), nestedSplitView]
        )
        outerSplitView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        outerSplitView.needsLayout = true
        outerSplitView.layoutSubtreeIfNeeded()

        outerSplitView.debugApplyDragForDividerAt(0, location: NSPoint(x: 900, y: 300))

        let rightFrame = try XCTUnwrap(outerSplitView.debugChildFrame(at: 1))

        XCTAssertEqual(rightFrame.width, 240, accuracy: 0.0001)
    }

    func testSplitViewClipsLayerBackedSubtreeDuringAnimatedResize() {
        let nestedSplitView = makeSplitView(axis: .vertical, fractions: [0.5, 0.5])
        let outerSplitView = makeSplitView(
            axis: .horizontal,
            fractions: [0.5, 0.5],
            childViews: [NSView(), nestedSplitView]
        )

        XCTAssertTrue(outerSplitView.wantsLayer)
        XCTAssertTrue(outerSplitView.layer?.masksToBounds == true)
        XCTAssertTrue(nestedSplitView.wantsLayer)
        XCTAssertTrue(nestedSplitView.layer?.masksToBounds == true)
    }

    private func makeSplitView(
        axis: SplitAxis,
        fractions: [CGFloat],
        childViews: [NSView]? = nil
    ) -> WorkspaceSplitView {
        let childViews = childViews ?? [NSView(), NSView()]
        return WorkspaceSplitView(
            axis: axis,
            fractions: fractions,
            childViews: childViews,
            childMinimumSizes: Array(
                repeating: NSSize(width: 240, height: 160),
                count: childViews.count
            ),
            dividerThickness: 6,
            onFractionsChange: { _, _ in }
        )
    }
}
