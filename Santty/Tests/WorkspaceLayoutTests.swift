import AppKit
import XCTest
@testable import Santty

final class WorkspaceLayoutTests: XCTestCase {
    func testSplitInsertsNewPaneAsTrailingSibling() throws {
        let originalPaneID = UUID()
        let newPaneID = UUID()

        let layoutNode = LayoutNode.panel(originalPaneID)
        let updatedLayoutNode = try XCTUnwrap(
            layoutNode.insertingSplit(
                for: originalPaneID,
                axis: .horizontal,
                newPaneID: newPaneID
            )
        )

        XCTAssertEqual(
            updatedLayoutNode,
            .split(
                axis: .horizontal,
                children: [.panel(originalPaneID), .panel(newPaneID)],
                fractions: [0.5, 0.5]
            )
        )
    }

    func testSameAxisSplitFlattensIntoParent() throws {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let thirdPaneID = UUID()

        let layoutNode = LayoutNode.split(
            axis: .horizontal,
            children: [.panel(firstPaneID), .panel(secondPaneID)],
            fractions: [0.4, 0.6]
        )

        let updatedLayoutNode = try XCTUnwrap(
            layoutNode.insertingSplit(
                for: secondPaneID,
                axis: .horizontal,
                newPaneID: thirdPaneID
            )
        )

        XCTAssertEqual(
            updatedLayoutNode,
            .split(
                axis: .horizontal,
                children: [.panel(firstPaneID), .panel(secondPaneID), .panel(thirdPaneID)],
                fractions: [0.4, 0.3, 0.3]
            )
        )
    }

    func testDifferentAxisSplitRemainsNested() throws {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let thirdPaneID = UUID()

        let layoutNode = LayoutNode.split(
            axis: .horizontal,
            children: [.panel(firstPaneID), .panel(secondPaneID)],
            fractions: [0.4, 0.6]
        )

        let updatedLayoutNode = try XCTUnwrap(
            layoutNode.insertingSplit(
                for: secondPaneID,
                axis: .vertical,
                newPaneID: thirdPaneID
            )
        )

        XCTAssertEqual(
            updatedLayoutNode,
            .split(
                axis: .horizontal,
                children: [
                    .panel(firstPaneID),
                    .split(
                        axis: .vertical,
                        children: [.panel(secondPaneID), .panel(thirdPaneID)],
                        fractions: [0.5, 0.5]
                    )
                ],
                fractions: [0.4, 0.6]
            )
        )
    }

    func testClosingPaneInThreeChildSplitRedistributesFractions() throws {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let thirdPaneID = UUID()

        let layoutNode = LayoutNode.split(
            axis: .horizontal,
            children: [.panel(firstPaneID), .panel(secondPaneID), .panel(thirdPaneID)],
            fractions: [0.2, 0.3, 0.5]
        )

        let closePaneResult = try XCTUnwrap(layoutNode.closingPane(secondPaneID))

        guard case let .split(axis, children, fractions) = try XCTUnwrap(closePaneResult.root) else {
            return XCTFail("Expected a two-child split after closing the middle pane")
        }

        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children, [.panel(firstPaneID), .panel(thirdPaneID)])
        assertFractionsEqual(fractions, [0.2857142857, 0.7142857143], accuracy: 0.0001)
        XCTAssertEqual(closePaneResult.promotedPaneID, thirdPaneID)
    }

    func testClosingPanePromotesSiblingFromTwoChildSplit() throws {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let layoutNode = LayoutNode.split(
            axis: .horizontal,
            children: [.panel(firstPaneID), .panel(secondPaneID)],
            fractions: [0.5, 0.5]
        )

        let closePaneResult = try XCTUnwrap(layoutNode.closingPane(firstPaneID))

        XCTAssertEqual(closePaneResult.root, .panel(secondPaneID))
        XCTAssertEqual(closePaneResult.promotedPaneID, secondPaneID)
    }

    func testTraversalWrapsInRenderedOrder() {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let thirdPaneID = UUID()

        let layoutNode = LayoutNode.split(
            axis: .horizontal,
            children: [
                .panel(firstPaneID),
                .split(
                    axis: .vertical,
                    children: [.panel(secondPaneID), .panel(thirdPaneID)],
                    fractions: [0.5, 0.5]
                )
            ],
            fractions: [0.5, 0.5]
        )

        XCTAssertEqual(layoutNode.paneIDsInTraversalOrder, [firstPaneID, secondPaneID, thirdPaneID])
        XCTAssertEqual(layoutNode.nextPaneID(after: thirdPaneID), firstPaneID)
        XCTAssertEqual(layoutNode.previousPaneID(before: firstPaneID), thirdPaneID)
    }

    func testMinimumSizeAggregatesAcrossThreeChildSplit() {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let thirdPaneID = UUID()

        let horizontalLayout = LayoutNode.split(
            axis: .horizontal,
            children: [.panel(firstPaneID), .panel(secondPaneID), .panel(thirdPaneID)],
            fractions: [1 / 3, 1 / 3, 1 / 3]
        )

        let verticalLayout = LayoutNode.split(
            axis: .vertical,
            children: [.panel(firstPaneID), .panel(secondPaneID), .panel(thirdPaneID)],
            fractions: [1 / 3, 1 / 3, 1 / 3]
        )

        XCTAssertEqual(horizontalLayout.minimumSize(), NSSize(width: 732, height: 160))
        XCTAssertEqual(verticalLayout.minimumSize(), NSSize(width: 240, height: 492))
    }

    func testPathLookupWorksWithChildIndexComponents() throws {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let thirdPaneID = UUID()

        let layoutNode = LayoutNode.split(
            axis: .horizontal,
            children: [
                .panel(firstPaneID),
                .split(
                    axis: .vertical,
                    children: [.panel(secondPaneID), .panel(thirdPaneID)],
                    fractions: [0.4, 0.6]
                )
            ],
            fractions: [0.25, 0.75]
        )

        XCTAssertEqual(layoutNode.path(to: firstPaneID), [.child(0)])
        XCTAssertEqual(layoutNode.path(to: thirdPaneID), [.child(1), .child(1)])
        XCTAssertEqual(
            layoutNode.node(at: [.child(1)]),
            .split(
                axis: .vertical,
                children: [.panel(secondPaneID), .panel(thirdPaneID)],
                fractions: [0.4, 0.6]
            )
        )
    }

    func testParentSplitContextReturnsAxisPathFractionsAndFocusedIndex() throws {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let thirdPaneID = UUID()
        let fourthPaneID = UUID()

        let layoutNode = LayoutNode.split(
            axis: .horizontal,
            children: [
                .panel(firstPaneID),
                .split(
                    axis: .vertical,
                    children: [.panel(secondPaneID), .panel(thirdPaneID), .panel(fourthPaneID)],
                    fractions: [0.2, 0.3, 0.5]
                )
            ],
            fractions: [0.6, 0.4]
        )

        let context = try XCTUnwrap(layoutNode.parentSplitContext(for: thirdPaneID))
        XCTAssertEqual(context.axis, .vertical)
        XCTAssertEqual(context.splitPath, [.child(1)])
        XCTAssertEqual(context.fractions, [0.2, 0.3, 0.5])
        XCTAssertEqual(context.focusedChildIndex, 1)
        XCTAssertEqual(context.currentFocusedFraction, 0.3, accuracy: 0.0001)
    }

    func testReplacingFocusedChildFractionRedistributesRemainingBudget() {
        let context = ParentSplitContext(
            splitPath: [.child(0)],
            axis: .horizontal,
            fractions: [0.2, 0.3, 0.5],
            focusedChildIndex: 1
        )

        assertFractionsEqual(
            context.replacingFocusedChildFraction(0.7),
            [0.0857142857, 0.7, 0.2142857143],
            accuracy: 0.0001
        )
    }

    func testClampedFractionsRespectMinimumSizesForMultiChildSplit() {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let thirdPaneID = UUID()
        let layoutNode = LayoutNode.split(
            axis: .horizontal,
            children: [.panel(firstPaneID), .panel(secondPaneID), .panel(thirdPaneID)],
            fractions: [1 / 3, 1 / 3, 1 / 3]
        )

        let clampedFractions = layoutNode.clampedFractions(
            [0.1, 0.2, 0.7],
            in: NSSize(width: 900, height: 320)
        )

        XCTAssertEqual(clampedFractions[0], 240 / 888, accuracy: 0.0001)
        XCTAssertEqual(clampedFractions[1], 240 / 888, accuracy: 0.0001)
        XCTAssertEqual(clampedFractions[2], 1 - (480 / 888), accuracy: 0.0001)
    }
}

private extension XCTestCase {
    func assertFractionsEqual(_ lhs: [CGFloat], _ rhs: [CGFloat], accuracy: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
        for (left, right) in zip(lhs, rhs) {
            XCTAssertEqual(left, right, accuracy: accuracy, file: file, line: line)
        }
    }
}
