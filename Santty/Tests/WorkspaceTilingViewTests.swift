import AppKit
import XCTest
@testable import Santty

@MainActor
final class WorkspaceTilingViewTests: XCTestCase {
    private let dividerThickness: CGFloat = 6
    private let minimumPaneSize = NSSize(width: 240, height: 160)

    // MARK: - TilingLayout: Single Panel

    func testSinglePanelFillsBounds() {
        let paneID = PaneID()
        let layout = TilingLayout.compute(
            node: .panel(paneID),
            rect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            dividerThickness: dividerThickness,
            minimumPaneSize: minimumPaneSize
        )

        XCTAssertEqual(layout.panePlacements.count, 1)
        XCTAssertEqual(layout.panePlacements[0].paneID, paneID)
        XCTAssertEqual(
            layout.panePlacements[0].frame,
            NSRect(x: 0, y: 0, width: 1000, height: 600)
        )
        XCTAssertTrue(layout.dividerPlacements.isEmpty)
    }

    // MARK: - TilingLayout: Horizontal Split

    func testHorizontalSplitTwoPanesEqualFractions() {
        let paneA = PaneID()
        let paneB = PaneID()
        let layout = TilingLayout.compute(
            node: .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.5, 0.5]
            ),
            rect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            dividerThickness: dividerThickness,
            minimumPaneSize: minimumPaneSize
        )

        XCTAssertEqual(layout.panePlacements.count, 2)
        XCTAssertEqual(layout.dividerPlacements.count, 1)

        let frameA = layout.panePlacements[0].frame
        let frameB = layout.panePlacements[1].frame
        let divider = layout.dividerPlacements[0]

        // Usable width = 1000 - 6 = 994, each pane = 497
        XCTAssertEqual(frameA, NSRect(x: 0, y: 0, width: 497, height: 600))
        XCTAssertEqual(divider.rect, NSRect(x: 497, y: 0, width: 6, height: 600))
        XCTAssertEqual(frameB, NSRect(x: 503, y: 0, width: 497, height: 600))
        XCTAssertEqual(divider.splitPath, [])
        XCTAssertEqual(divider.dividerIndex, 0)
    }

    func testHorizontalSplitUnequalFractions() {
        let paneA = PaneID()
        let paneB = PaneID()
        let layout = TilingLayout.compute(
            node: .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.3, 0.7]
            ),
            rect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            dividerThickness: dividerThickness,
            minimumPaneSize: minimumPaneSize
        )

        let frameA = layout.panePlacements[0].frame
        let frameB = layout.panePlacements[1].frame
        let divider = layout.dividerPlacements[0]

        // Usable width = 994, A = 298.2, B = 695.8
        XCTAssertEqual(frameA.width, 298.2, accuracy: 0.01)
        XCTAssertEqual(divider.rect.minX, frameA.maxX, accuracy: 0.01)
        XCTAssertEqual(frameB.minX, divider.rect.maxX, accuracy: 0.01)
        XCTAssertEqual(frameB.maxX, 1000, accuracy: 0.01)
    }

    func testHorizontalSplitThreePanes() {
        let paneA = PaneID()
        let paneB = PaneID()
        let paneC = PaneID()
        let layout = TilingLayout.compute(
            node: .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB), .panel(paneC)],
                fractions: [0.5, 0.25, 0.25]
            ),
            rect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            dividerThickness: dividerThickness,
            minimumPaneSize: minimumPaneSize
        )

        XCTAssertEqual(layout.panePlacements.count, 3)
        XCTAssertEqual(layout.dividerPlacements.count, 2)

        let frameA = layout.panePlacements[0].frame
        let divider0 = layout.dividerPlacements[0]
        let frameB = layout.panePlacements[1].frame
        let divider1 = layout.dividerPlacements[1]
        let frameC = layout.panePlacements[2].frame

        // Usable width = 1000 - 12 = 988
        // A = 494, B = 247, C = 247
        XCTAssertEqual(frameA.width, 494, accuracy: 0.01)
        XCTAssertEqual(divider0.rect.minX, frameA.maxX, accuracy: 0.01)
        XCTAssertEqual(frameB.minX, divider0.rect.maxX, accuracy: 0.01)
        XCTAssertEqual(frameB.width, 247, accuracy: 0.01)
        XCTAssertEqual(divider1.rect.minX, frameB.maxX, accuracy: 0.01)
        XCTAssertEqual(frameC.minX, divider1.rect.maxX, accuracy: 0.01)
        XCTAssertEqual(frameC.maxX, 1000, accuracy: 0.01)
    }

    // MARK: - TilingLayout: Vertical Split

    func testVerticalSplitTwoPanesEqualFractions() {
        let paneA = PaneID()
        let paneB = PaneID()
        let layout = TilingLayout.compute(
            node: .split(
                axis: .vertical,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.5, 0.5]
            ),
            rect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            dividerThickness: dividerThickness,
            minimumPaneSize: minimumPaneSize
        )

        let frameA = layout.panePlacements[0].frame
        let frameB = layout.panePlacements[1].frame
        let divider = layout.dividerPlacements[0]

        // Usable height = 600 - 6 = 594, each pane = 297
        // Pane A (index 0) is at the top (high Y)
        XCTAssertEqual(frameA, NSRect(x: 0, y: 303, width: 1000, height: 297))
        XCTAssertEqual(divider.rect, NSRect(x: 0, y: 297, width: 1000, height: 6))
        XCTAssertEqual(frameB, NSRect(x: 0, y: 0, width: 1000, height: 297))
    }

    // MARK: - TilingLayout: Nested Split

    func testNestedSplitComputesAbsoluteFrames() {
        let paneA = PaneID()
        let paneB = PaneID()
        let paneC = PaneID()
        let layout = TilingLayout.compute(
            node: .split(
                axis: .horizontal,
                children: [
                    .panel(paneA),
                    .split(
                        axis: .vertical,
                        children: [.panel(paneB), .panel(paneC)],
                        fractions: [0.5, 0.5]
                    ),
                ],
                fractions: [0.5, 0.5]
            ),
            rect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            dividerThickness: dividerThickness,
            minimumPaneSize: minimumPaneSize
        )

        XCTAssertEqual(layout.panePlacements.count, 3)
        XCTAssertEqual(layout.dividerPlacements.count, 2)

        let frameA = layout.panePlacements.first { $0.paneID == paneA }!.frame
        let frameB = layout.panePlacements.first { $0.paneID == paneB }!.frame
        let frameC = layout.panePlacements.first { $0.paneID == paneC }!.frame

        // Root horizontal split: A gets left half, nested split gets right half
        XCTAssertEqual(frameA.width, 497, accuracy: 0.01)
        XCTAssertEqual(frameA.height, 600, accuracy: 0.01)

        // Nested vertical split: right half is (503, 0, 497, 600)
        // B (top) and C (bottom) each get 297 height
        XCTAssertEqual(frameB.width, 497, accuracy: 0.01)
        XCTAssertEqual(frameB.height, 297, accuracy: 0.01)
        XCTAssertEqual(frameB.minX, 503, accuracy: 0.01)
        XCTAssertEqual(frameB.maxY, 600, accuracy: 0.01)

        XCTAssertEqual(frameC.width, 497, accuracy: 0.01)
        XCTAssertEqual(frameC.height, 297, accuracy: 0.01)
        XCTAssertEqual(frameC.minX, 503, accuracy: 0.01)
        XCTAssertEqual(frameC.minY, 0, accuracy: 0.01)

        // Root divider
        let rootDivider = layout.dividerPlacements.first { $0.splitPath == [] }!
        XCTAssertEqual(rootDivider.rect.minX, 497, accuracy: 0.01)
        XCTAssertEqual(rootDivider.rect.width, 6, accuracy: 0.01)
        XCTAssertEqual(rootDivider.rect.height, 600, accuracy: 0.01)

        // Nested divider
        let nestedDivider = layout.dividerPlacements.first {
            $0.splitPath == [.child(1)]
        }!
        XCTAssertEqual(nestedDivider.rect.minY, 297, accuracy: 0.01)
        XCTAssertEqual(nestedDivider.rect.height, 6, accuracy: 0.01)
        XCTAssertEqual(nestedDivider.rect.width, 497, accuracy: 0.01)
    }

    // MARK: - TilingLayout: Minimum Size Clamping

    func testClampsFractionsToMinimumPaneWidth() {
        let paneA = PaneID()
        let paneB = PaneID()
        let layout = TilingLayout.compute(
            node: .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.05, 0.95]
            ),
            rect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            dividerThickness: dividerThickness,
            minimumPaneSize: minimumPaneSize
        )

        let frameA = layout.panePlacements[0].frame
        let frameB = layout.panePlacements[1].frame

        XCTAssertGreaterThanOrEqual(frameA.width, 240 - 0.01)
        XCTAssertGreaterThanOrEqual(frameB.width, 240 - 0.01)
        XCTAssertEqual(
            frameA.width + frameB.width + dividerThickness, 1000, accuracy: 0.01
        )
    }

    // MARK: - TilingLayout: Effective Fractions

    func testEffectiveFractionsMatchStoredWhenNoClamping() {
        let paneA = PaneID()
        let paneB = PaneID()
        let layout = TilingLayout.compute(
            node: .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.3, 0.7]
            ),
            rect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            dividerThickness: dividerThickness,
            minimumPaneSize: minimumPaneSize
        )

        let rootFractions = layout.effectiveFractions[[]]
        XCTAssertNotNil(rootFractions)
        XCTAssertEqual(rootFractions![0], 0.3, accuracy: 0.0001)
        XCTAssertEqual(rootFractions![1], 0.7, accuracy: 0.0001)
    }

    func testEffectiveFractionsReflectClamping() {
        let paneA = PaneID()
        let paneB = PaneID()
        let layout = TilingLayout.compute(
            node: .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.01, 0.99]
            ),
            rect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            dividerThickness: dividerThickness,
            minimumPaneSize: minimumPaneSize
        )

        let rootFractions = layout.effectiveFractions[[]]
        XCTAssertNotNil(rootFractions)
        XCTAssertGreaterThan(rootFractions![0], 0.01)
    }

    // MARK: - TilingLayout: Node Frames

    func testNodeFramesIncludeRootAndChildPaths() {
        let paneA = PaneID()
        let paneB = PaneID()
        let layout = TilingLayout.compute(
            node: .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.5, 0.5]
            ),
            rect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            dividerThickness: dividerThickness,
            minimumPaneSize: minimumPaneSize
        )

        let rootFrame = layout.nodeFrames[[]]
        XCTAssertEqual(rootFrame, NSRect(x: 0, y: 0, width: 1000, height: 600))

        let child0Frame = layout.nodeFrames[[.child(0)]]
        XCTAssertEqual(child0Frame, NSRect(x: 0, y: 0, width: 497, height: 600))

        let child1Frame = layout.nodeFrames[[.child(1)]]
        XCTAssertEqual(child1Frame, NSRect(x: 503, y: 0, width: 497, height: 600))
    }
}
