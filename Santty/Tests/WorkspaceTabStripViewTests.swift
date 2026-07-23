import XCTest
@testable import Santty

final class WorkspaceTabStripViewTests: XCTestCase {
    func testReorderPreviewMovesFirstTabToEnd() throws {
        let tabIDs = Self.tabIDs(count: 3)

        let plan = try XCTUnwrap(
            WorkspaceTabReorderPreviewPlan.make(
                draggedTabID: tabIDs[0],
                modelIDs: tabIDs,
                currentPreviewIDs: nil,
                proposedDisplayIndex: 3
            )
        )

        XCTAssertEqual(plan.previewIDs, [tabIDs[1], tabIDs[2], tabIDs[0]])
        XCTAssertEqual(plan.modelDestinationIndex, 2)
        XCTAssertEqual(
            plan.previewMove,
            WorkspaceTabReorderPreviewMove(sourceIndex: 0, destinationIndex: 2)
        )
    }

    func testReorderPreviewMovesLastTabToFront() throws {
        let tabIDs = Self.tabIDs(count: 3)

        let plan = try XCTUnwrap(
            WorkspaceTabReorderPreviewPlan.make(
                draggedTabID: tabIDs[2],
                modelIDs: tabIDs,
                currentPreviewIDs: nil,
                proposedDisplayIndex: 0
            )
        )

        XCTAssertEqual(plan.previewIDs, [tabIDs[2], tabIDs[0], tabIDs[1]])
        XCTAssertEqual(plan.modelDestinationIndex, 0)
        XCTAssertEqual(
            plan.previewMove,
            WorkspaceTabReorderPreviewMove(sourceIndex: 2, destinationIndex: 0)
        )
    }

    func testReorderPreviewMovesMiddleTabLeftAndRight() throws {
        let tabIDs = Self.tabIDs(count: 4)

        let leftPlan = try XCTUnwrap(
            WorkspaceTabReorderPreviewPlan.make(
                draggedTabID: tabIDs[2],
                modelIDs: tabIDs,
                currentPreviewIDs: nil,
                proposedDisplayIndex: 1
            )
        )
        XCTAssertEqual(leftPlan.previewIDs, [tabIDs[0], tabIDs[2], tabIDs[1], tabIDs[3]])
        XCTAssertEqual(leftPlan.modelDestinationIndex, 1)

        let rightPlan = try XCTUnwrap(
            WorkspaceTabReorderPreviewPlan.make(
                draggedTabID: tabIDs[1],
                modelIDs: tabIDs,
                currentPreviewIDs: nil,
                proposedDisplayIndex: 4
            )
        )
        XCTAssertEqual(rightPlan.previewIDs, [tabIDs[0], tabIDs[2], tabIDs[3], tabIDs[1]])
        XCTAssertEqual(rightPlan.modelDestinationIndex, 3)
    }

    func testReorderPreviewDoesNotDriftWhenHoverStaysAtSamePreviewPosition() throws {
        let tabIDs = Self.tabIDs(count: 4)
        let firstPlan = try XCTUnwrap(
            WorkspaceTabReorderPreviewPlan.make(
                draggedTabID: tabIDs[0],
                modelIDs: tabIDs,
                currentPreviewIDs: nil,
                proposedDisplayIndex: 3
            )
        )

        let repeatedPlan = try XCTUnwrap(
            WorkspaceTabReorderPreviewPlan.make(
                draggedTabID: tabIDs[0],
                modelIDs: tabIDs,
                currentPreviewIDs: firstPlan.previewIDs,
                proposedDisplayIndex: 3
            )
        )

        XCTAssertEqual(repeatedPlan.previewIDs, firstPlan.previewIDs)
        XCTAssertEqual(repeatedPlan.modelDestinationIndex, firstPlan.modelDestinationIndex)
        XCTAssertNil(repeatedPlan.previewMove)
    }

    func testReorderPreviewClampsProposedIndexBeyondNewTabButtonToEnd() throws {
        let tabIDs = Self.tabIDs(count: 3)

        let plan = try XCTUnwrap(
            WorkspaceTabReorderPreviewPlan.make(
                draggedTabID: tabIDs[1],
                modelIDs: tabIDs,
                currentPreviewIDs: nil,
                proposedDisplayIndex: 99
            )
        )

        XCTAssertEqual(plan.previewIDs, [tabIDs[0], tabIDs[2], tabIDs[1]])
        XCTAssertEqual(plan.modelDestinationIndex, 2)
        XCTAssertEqual(
            plan.previewMove,
            WorkspaceTabReorderPreviewMove(sourceIndex: 1, destinationIndex: 2)
        )
    }

    func testReorderPreviewKeepsNoOpDropAtSourceDestination() throws {
        let tabIDs = Self.tabIDs(count: 3)

        let plan = try XCTUnwrap(
            WorkspaceTabReorderPreviewPlan.make(
                draggedTabID: tabIDs[1],
                modelIDs: tabIDs,
                currentPreviewIDs: nil,
                proposedDisplayIndex: 1
            )
        )

        XCTAssertEqual(plan.previewIDs, tabIDs)
        XCTAssertEqual(plan.modelDestinationIndex, 1)
        XCTAssertNil(plan.previewMove)
    }

    private static func tabIDs(count: Int) -> [UUID] {
        (0..<count).map { index in
            UUID(uuid: (
                UInt8(index + 1),
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0
            ))
        }
    }
}
