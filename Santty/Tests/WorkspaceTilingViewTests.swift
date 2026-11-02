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

    func testCollapsedNestedBranchConsumesNoSpaceOrDividers() {
        let ids = (0..<3).map { _ in PaneID() }
        for axis in [SplitAxis.horizontal, .vertical] {
            let layout = TilingLayout.compute(
                node: .split(axis: axis, children: [
                    .split(axis: axis == .horizontal ? .vertical : .horizontal,
                        children: [.panel(ids[0]), .panel(ids[1])], fractions: [0.5, 0.5]),
                    .panel(ids[2]),
                ], fractions: [0, 1]),
                rect: NSRect(x: 0, y: 0, width: 1000, height: 600))
            XCTAssertTrue(layout.panePlacements[0].frame.isEmpty)
            XCTAssertTrue(layout.panePlacements[1].frame.isEmpty)
            XCTAssertEqual(layout.panePlacements[2].frame, NSRect(x: 0, y: 0, width: 1000, height: 600))
            XCTAssertTrue(layout.dividerPlacements.isEmpty)
        }
    }

    func testCollapsedMiddlePaneHidesWithoutZeroResizeAndDividerDragSkipsIt() throws {
        let ids = (0..<3).map { _ in PaneID() }
        let views = Dictionary(uniqueKeysWithValues: ids.map { ($0, NSView()) })
        let tiling = WorkspaceTilingView()
        tiling.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        let original = LayoutNode.split(axis: .horizontal, children: ids.map(LayoutNode.panel), fractions: [0.34, 0.33, 0.33])
        tiling.setLayoutNode(original, paneViews: views)
        let middleFrame = try XCTUnwrap(views[ids[1]]).frame
        var commits: [[CGFloat]] = []
        tiling.onFractionsChange = { _, fractions, _ in commits.append(fractions) }
        tiling.setLayoutNode(.split(axis: .horizontal, children: ids.map(LayoutNode.panel), fractions: [0.5, 0, 0.5]),
            paneViews: views, animated: true, isTransient: true)
        XCTAssertTrue(try XCTUnwrap(views[ids[1]]).isHidden)
        XCTAssertEqual(views[ids[1]]?.frame, middleFrame)
        XCTAssertTrue(try XCTUnwrap(tiling.debugPaneFrame(paneID: ids[1])).isEmpty)
        XCTAssertEqual(try XCTUnwrap(tiling.debugPaneFrame(paneID: ids[2])).maxX, 1000, accuracy: 0.0001)
        XCTAssertTrue(commits.isEmpty)

        tiling.debugApplyDragForDivider(at: [], dividerIndex: 0, location: NSPoint(x: 600, y: 300))
        let fractions = try XCTUnwrap(commits.last)
        XCTAssertEqual(fractions[0], 600 / 994, accuracy: 0.0001)
        XCTAssertEqual(fractions[1], 0)
        XCTAssertEqual(fractions[2], 394 / 994, accuracy: 0.0001)
        tiling.setLayoutNode(original, paneViews: views)
        XCTAssertFalse(try XCTUnwrap(views[ids[1]]).isHidden)
        XCTAssertTrue(tiling.collapsedPaneIDs.isEmpty)
    }

    func testTransientMinimumSizeClampsDoNotPublishModelChanges() {
        let ids = [PaneID(), PaneID()]
        let tiling = WorkspaceTilingView()
        tiling.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        var commits = 0
        tiling.onFractionsChange = { _, _, _ in commits += 1 }
        tiling.setLayoutNode(.split(axis: .horizontal, children: ids.map(LayoutNode.panel), fractions: [0.01, 0.99]),
            paneViews: Dictionary(uniqueKeysWithValues: ids.map { ($0, NSView()) }),
            animated: false, isTransient: true)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(tiling.debugPaneFrame(paneID: ids[0])?.width ?? 0, 240, accuracy: 0.0001)
    }

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

    // MARK: - WorkspaceTilingView: Basic Layout

    func testTilingViewSinglePaneLayout() {
        let paneID = PaneID()
        let paneView = NSView()
        let tilingView = WorkspaceTilingView()
        tilingView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        tilingView.setLayoutNode(.panel(paneID), paneViews: [paneID: paneView])
        tilingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(paneView.frame, NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(paneView.superview === tilingView)
    }

    func testTilingViewHorizontalSplitLayout() {
        let paneA = PaneID()
        let paneB = PaneID()
        let viewA = NSView()
        let viewB = NSView()
        let tilingView = WorkspaceTilingView()
        tilingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)

        tilingView.setLayoutNode(
            .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.5, 0.5]
            ),
            paneViews: [paneA: viewA, paneB: viewB]
        )
        tilingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(viewA.frame.width, 497, accuracy: 0.01)
        XCTAssertEqual(viewA.frame.height, 600, accuracy: 0.01)
        XCTAssertEqual(viewB.frame.minX, 503, accuracy: 0.01)
        XCTAssertEqual(viewB.frame.width, 497, accuracy: 0.01)
        XCTAssertTrue(viewA.superview === tilingView)
        XCTAssertTrue(viewB.superview === tilingView)
    }

    func testTilingViewNestedSplitLayout() {
        let paneA = PaneID()
        let paneB = PaneID()
        let paneC = PaneID()
        let viewA = NSView()
        let viewB = NSView()
        let viewC = NSView()
        let tilingView = WorkspaceTilingView()
        tilingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)

        tilingView.setLayoutNode(
            .split(
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
            paneViews: [paneA: viewA, paneB: viewB, paneC: viewC]
        )
        tilingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(viewA.frame.width, 497, accuracy: 0.01)
        XCTAssertEqual(viewB.frame.minX, 503, accuracy: 0.01)
        XCTAssertEqual(viewB.frame.width, 497, accuracy: 0.01)
        XCTAssertEqual(viewB.frame.height, 297, accuracy: 0.01)
        XCTAssertEqual(viewC.frame.minX, 503, accuracy: 0.01)
        XCTAssertEqual(viewC.frame.width, 497, accuracy: 0.01)
        XCTAssertEqual(viewC.frame.height, 297, accuracy: 0.01)
    }

    func testTilingViewRemovesPaneOnStructuralChange() {
        let paneA = PaneID()
        let paneB = PaneID()
        let viewA = NSView()
        let viewB = NSView()
        let tilingView = WorkspaceTilingView()
        tilingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)

        tilingView.setLayoutNode(
            .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.5, 0.5]
            ),
            paneViews: [paneA: viewA, paneB: viewB]
        )
        tilingView.layoutSubtreeIfNeeded()
        XCTAssertTrue(viewB.superview === tilingView)

        // Close pane B — structural change
        tilingView.setLayoutNode(.panel(paneA), paneViews: [paneA: viewA])
        tilingView.layoutSubtreeIfNeeded()

        XCTAssertNil(viewB.superview)
        XCTAssertEqual(viewA.frame, NSRect(x: 0, y: 0, width: 1000, height: 600))
    }

    func testTilingViewAddsPaneOnStructuralChange() {
        let paneA = PaneID()
        let viewA = NSView()
        let tilingView = WorkspaceTilingView()
        tilingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)

        tilingView.setLayoutNode(.panel(paneA), paneViews: [paneA: viewA])
        tilingView.layoutSubtreeIfNeeded()

        // Split — add pane B
        let paneB = PaneID()
        let viewB = NSView()
        tilingView.setLayoutNode(
            .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.5, 0.5]
            ),
            paneViews: [paneA: viewA, paneB: viewB]
        )
        tilingView.layoutSubtreeIfNeeded()

        XCTAssertTrue(viewB.superview === tilingView)
        XCTAssertEqual(viewA.frame.width, 497, accuracy: 0.01)
        XCTAssertEqual(viewB.frame.width, 497, accuracy: 0.01)
    }

    // MARK: - WorkspaceTilingView: Debug API

    func testDebugCurrentFractionsReturnsStoredFractions() {
        let paneA = PaneID()
        let paneB = PaneID()
        let tilingView = WorkspaceTilingView()
        tilingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)

        tilingView.setLayoutNode(
            .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.3, 0.7]
            ),
            paneViews: [paneA: NSView(), paneB: NSView()]
        )
        tilingView.layoutSubtreeIfNeeded()

        let fractions = tilingView.debugCurrentFractions(at: [])
        XCTAssertNotNil(fractions)
        XCTAssertEqual(fractions![0], 0.3, accuracy: 0.0001)
        XCTAssertEqual(fractions![1], 0.7, accuracy: 0.0001)
    }

    func testDebugNodeFrameReturnsPaneFrameForPanelPath() {
        let paneA = PaneID()
        let paneB = PaneID()
        let viewA = NSView()
        let viewB = NSView()
        let tilingView = WorkspaceTilingView()
        tilingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)

        tilingView.setLayoutNode(
            .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.5, 0.5]
            ),
            paneViews: [paneA: viewA, paneB: viewB]
        )
        tilingView.layoutSubtreeIfNeeded()

        let frameA = tilingView.debugNodeFrame(at: [.child(0)])
        XCTAssertEqual(frameA, NSRect(x: 0, y: 0, width: 497, height: 600))

        let frameB = tilingView.debugNodeFrame(at: [.child(1)])
        XCTAssertEqual(frameB, NSRect(x: 503, y: 0, width: 497, height: 600))
    }

    func testDebugNodeFrameReturnsBoundingRectForSplitPath() throws {
        let paneA = PaneID()
        let paneB = PaneID()
        let paneC = PaneID()
        let tilingView = WorkspaceTilingView()
        tilingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)

        tilingView.setLayoutNode(
            .split(
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
            paneViews: [paneA: NSView(), paneB: NSView(), paneC: NSView()]
        )
        tilingView.layoutSubtreeIfNeeded()

        let nestedFrame = try XCTUnwrap(tilingView.debugNodeFrame(at: [.child(1)]))
        XCTAssertEqual(nestedFrame.minX, 503, accuracy: 0.01)
        XCTAssertEqual(nestedFrame.width, 497, accuracy: 0.01)
        XCTAssertEqual(nestedFrame.height, 600, accuracy: 0.01)
    }

    // MARK: - WorkspaceTilingView: Divider Drag

    func testDividerDragPublishesFractionsWhileDragging() throws {

        let a = PaneID(), b = PaneID()
        let tiling = WorkspaceTilingView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = tiling; window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        tiling.setLayoutNode(.split(axis: .horizontal, children: [.panel(a), .panel(b)], fractions: [0.5, 0.5]),
                             paneViews: [a: NSView(), b: NSView()])
        tiling.layoutSubtreeIfNeeded()
        var commits: [[CGFloat]] = []
        tiling.onFractionsChange = { _, fractions, source in
            if source == .userDrag { commits.append(fractions) }
        }
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 300), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseDragged, x: 600), atStart: false)
        NSApp.postEvent(try event(.leftMouseDragged, x: 700), atStart: false)
        NSApp.postEvent(try event(.leftMouseUp, x: 700), atStart: false)
        tiling.mouseDown(with: try event(.leftMouseDown, x: 500))
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits.last, tiling.debugCurrentFractions(at: []))
        XCTAssertGreaterThan(try XCTUnwrap(commits.last?.first), 0.6)
        XCTAssertFalse(tiling.isDraggingDivider)

    }

    func testDividerDragCallbackFiresWithCorrectPath() {
        let paneA = PaneID()
        let paneB = PaneID()
        let tilingView = WorkspaceTilingView()
        tilingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)

        var receivedPath: [LayoutPathComponent]?
        var receivedFractions: [CGFloat]?
        tilingView.onFractionsChange = { path, fractions, _ in
            receivedPath = path
            receivedFractions = fractions
        }

        tilingView.setLayoutNode(
            .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.5, 0.5]
            ),
            paneViews: [paneA: NSView(), paneB: NSView()]
        )
        tilingView.layoutSubtreeIfNeeded()

        // Simulate a drag on the root divider
        tilingView.debugApplyDragForDivider(
            at: [], dividerIndex: 0, location: NSPoint(x: 700, y: 300)
        )

        XCTAssertEqual(receivedPath, [])
        XCTAssertNotNil(receivedFractions)
        XCTAssertGreaterThan(receivedFractions![0], 0.5)
        XCTAssertLessThan(receivedFractions![1], 0.5)
    }

    func testDividerDragRespectsMinimumPaneSize() {
        let paneA = PaneID()
        let paneB = PaneID()
        let tilingView = WorkspaceTilingView()
        tilingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)

        var receivedFractions: [CGFloat]?
        tilingView.onFractionsChange = { _, fractions, _ in
            receivedFractions = fractions
        }

        tilingView.setLayoutNode(
            .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.5, 0.5]
            ),
            paneViews: [paneA: NSView(), paneB: NSView()]
        )
        tilingView.layoutSubtreeIfNeeded()

        // Drag far right — should clamp pane B to minimum
        tilingView.debugApplyDragForDivider(
            at: [], dividerIndex: 0, location: NSPoint(x: 950, y: 300)
        )

        XCTAssertNotNil(receivedFractions)
        let viewB = tilingView.paneViews[paneB]!
        XCTAssertGreaterThanOrEqual(viewB.frame.width, 240 - 0.01)
    }

    func testDividerDragOnNestedSplit() {
        let paneA = PaneID()
        let paneB = PaneID()
        let paneC = PaneID()
        let tilingView = WorkspaceTilingView()
        tilingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)

        var receivedPath: [LayoutPathComponent]?
        tilingView.onFractionsChange = { path, _, _ in
            receivedPath = path
        }

        tilingView.setLayoutNode(
            .split(
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
            paneViews: [paneA: NSView(), paneB: NSView(), paneC: NSView()]
        )
        tilingView.layoutSubtreeIfNeeded()

        // Drag the nested vertical divider
        tilingView.debugApplyDragForDivider(
            at: [.child(1)], dividerIndex: 0, location: NSPoint(x: 750, y: 200)
        )

        XCTAssertEqual(receivedPath, [.child(1)])
    }

    // MARK: - WorkspaceTilingView: FLIP Animation

    func testAnimatedFractionChangeUpdatesModelImmediately() {
        let paneA = PaneID()
        let paneB = PaneID()
        let viewA = NSView()
        let viewB = NSView()
        let tilingView = WorkspaceTilingView()
        tilingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)

        tilingView.setLayoutNode(
            .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.5, 0.5]
            ),
            paneViews: [paneA: viewA, paneB: viewB]
        )
        tilingView.layoutSubtreeIfNeeded()

        // Animated fraction change — model should update immediately
        tilingView.setLayoutNode(
            .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.7, 0.3]
            ),
            paneViews: [paneA: viewA, paneB: viewB],
            animated: true
        )

        let fractions = tilingView.debugCurrentFractions(at: [])
        XCTAssertNotNil(fractions)
        XCTAssertEqual(fractions![0], 0.7, accuracy: 0.0001)
        XCTAssertEqual(fractions![1], 0.3, accuracy: 0.0001)

        // Final frames should reflect new fractions
        XCTAssertEqual(viewA.frame.width, 695.8, accuracy: 0.1)
        XCTAssertEqual(viewB.frame.width, 298.2, accuracy: 0.1)
    }

    func testInterruptedAnimationKeepsLatestFractions() {
        let paneA = PaneID()
        let paneB = PaneID()
        let viewA = NSView()
        let viewB = NSView()
        let tilingView = WorkspaceTilingView()
        tilingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)

        tilingView.setLayoutNode(
            .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.5, 0.5]
            ),
            paneViews: [paneA: viewA, paneB: viewB]
        )
        tilingView.layoutSubtreeIfNeeded()

        tilingView.setLayoutNode(
            .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.7, 0.3]
            ),
            paneViews: [paneA: viewA, paneB: viewB],
            animated: true
        )

        // Interrupt with new fractions
        tilingView.setLayoutNode(
            .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.4, 0.6]
            ),
            paneViews: [paneA: viewA, paneB: viewB],
            animated: true
        )

        let fractions = tilingView.debugCurrentFractions(at: [])
        XCTAssertEqual(fractions![0], 0.4, accuracy: 0.0001)
        XCTAssertEqual(fractions![1], 0.6, accuracy: 0.0001)
    }

    func testStructuralChangeIgnoresAnimatedFlag() {
        let paneA = PaneID()
        let viewA = NSView()
        let tilingView = WorkspaceTilingView()
        tilingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)

        tilingView.setLayoutNode(.panel(paneA), paneViews: [paneA: viewA])
        tilingView.layoutSubtreeIfNeeded()

        // Add a pane — structural change, should be instant even with animated: true
        let paneB = PaneID()
        let viewB = NSView()
        tilingView.setLayoutNode(
            .split(
                axis: .horizontal,
                children: [.panel(paneA), .panel(paneB)],
                fractions: [0.5, 0.5]
            ),
            paneViews: [paneA: viewA, paneB: viewB],
            animated: true
        )
        tilingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(viewA.frame.width, 497, accuracy: 0.01)
        XCTAssertEqual(viewB.frame.width, 497, accuracy: 0.01)
    }
}
