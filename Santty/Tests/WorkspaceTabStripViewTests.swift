import AppKit
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

    @MainActor
    func testNewTabUsesNativeSymbolButtonAndKeepsItsActionAfterReload() throws {
        let strip = WorkspaceTabStripView(frame: NSRect(x: 0, y: 0, width: 640, height: 32))
        let collection = try XCTUnwrap(strip.subviews.compactMap { $0 as? NSCollectionView }.first)
        let dataSource = try XCTUnwrap(collection.dataSource)
        var newTabCount = 0
        strip.onNewTab = { newTabCount += 1 }

        for tabCount in [0, 2] {
            strip.items = Self.tabIDs(count: tabCount).map {
                WorkspaceTabStripItem(id: $0, title: "santty", isSelected: false)
            }
            let indexPath = IndexPath(item: tabCount, section: 0)
            let item = dataSource.collectionView(collection, itemForRepresentedObjectAt: indexPath)
            let button = try XCTUnwrap(item.view.subviews.compactMap { $0 as? NSButton }.first)
            let size = strip.collectionView(
                collection,
                layout: try XCTUnwrap(collection.collectionViewLayout),
                sizeForItemAt: indexPath
            )
            XCTAssertEqual(size.width, size.height)
            XCTAssertEqual(size.height, WorkspaceTabButtonView.cornerRadius * 2)
            item.view.frame = NSRect(origin: .zero, size: size)
            item.view.layoutSubtreeIfNeeded()

            XCTAssertEqual(button.title, "")
            XCTAssertEqual(button.imagePosition, .imageOnly)
            XCTAssertNotNil(button.image)
            XCTAssertEqual(button.accessibilityLabel(), "New Tab")
            XCTAssertEqual(button.frame, item.view.bounds)
            XCTAssertEqual(item.view.layer?.cornerRadius, WorkspaceTabButtonView.cornerRadius)
            XCTAssertNil(strip.collectionView(collection, pasteboardWriterForItemAt: indexPath))
            button.performClick(nil)
        }
        XCTAssertEqual(newTabCount, 2)
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
