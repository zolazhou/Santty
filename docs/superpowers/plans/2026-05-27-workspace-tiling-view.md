# WorkspaceTilingView Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the recursive `WorkspaceSplitView` hierarchy with a single flat `WorkspaceTilingView` that directly positions all panes from the `LayoutNode` tree in one coordinate space.

**Architecture:** A single `WorkspaceTilingView` holds the `LayoutNode` tree and a dictionary of pane views. It computes all pane frames and divider rects in one recursive pass via a pure `TilingLayout` struct, positioning all panes as direct subviews. Dividers are pure geometry — drawn as layers, no separate view type. FLIP animation operates in a single coordinate space. The `WorkspaceViewController` delegates to one tiling view instead of a `splitViewsByPath` dictionary.

**Tech Stack:** Swift 6.0 (strict concurrency), AppKit, XCTest, Tuist

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `Santty/Sources/Workspace/Views/WorkspaceTilingView.swift` | Create | `TilingLayout` (pure computation), `TilingFractionChangeSource`, `WorkspaceTilingView` (flat tiling NSView with layout, divider drag, FLIP animation) |
| `Santty/Sources/Workspace/WorkspaceViewController.swift` | Modify | Replace `splitViewsByPath` with single `tilingView`, update debug API, update auto-zoom and divider move |
| `Santty/Tests/WorkspaceTilingViewTests.swift` | Create | Tests for `TilingLayout` computation and `WorkspaceTilingView` behavior |
| `Santty/Sources/Workspace/Views/WorkspaceSplitView.swift` | Delete | Replaced by `WorkspaceTilingView` |
| `Santty/Tests/WorkspaceSplitViewTests.swift` | Delete | Replaced by `WorkspaceTilingViewTests` |

---

## Task 1: TilingLayout — Pure Layout Computation

**Files:**
- Create: `Santty/Sources/Workspace/Views/WorkspaceTilingView.swift` (partial — `TilingLayout` struct only)
- Create: `Santty/Tests/WorkspaceTilingViewTests.swift` (partial — `TilingLayout` tests only)

- [ ] **Step 1: Write TilingLayout tests**

Create `Santty/Tests/WorkspaceTilingViewTests.swift`:

```swift
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
        XCTAssertEqual(layout.panePlacements[0].frame, NSRect(x: 0, y: 0, width: 1000, height: 600))
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
        let nestedDivider = layout.dividerPlacements.first { $0.splitPath == [.child(1)] }!
        XCTAssertEqual(nestedDivider.rect.minY, 297, accuracy: 0.01)
        XCTAssertEqual(nestedDivider.rect.height, 6, accuracy: 0.01)
        XCTAssertEqual(nestedDivider.rect.width, 497, accuracy: 0.01)
    }

    // MARK: - TilingLayout: Minimum Size Clamping

    func testClampsFractionsToMinimumPaneWidth() {
        let paneA = PaneID()
        let paneB = PaneID()
        // Request 0.05/0.95 but minimum width is 240
        // Usable width = 1000 - 6 = 994
        // Minimum fraction for each pane = 240 / 994 ≈ 0.2415
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
        XCTAssertEqual(frameA.width + frameB.width + dividerThickness, 1000, accuracy: 0.01)
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
        // Both panes should be clamped to minimum
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -workspace Santty.xcworkspace -scheme Santty -destination 'platform=macOS' test -only-testing:SanttyTests/WorkspaceTilingViewTests 2>&1 | tail -20`
Expected: FAIL — `TilingLayout` is not defined

- [ ] **Step 3: Implement TilingLayout**

Create `Santty/Sources/Workspace/Views/WorkspaceTilingView.swift` with the `TilingLayout` struct:

```swift
import AppKit

struct TilingLayout: Equatable {
    struct PanePlacement: Equatable {
        let paneID: PaneID
        let frame: NSRect
    }

    struct DividerPlacement: Equatable {
        let splitPath: [LayoutPathComponent]
        let dividerIndex: Int
        let rect: NSRect
    }

    let panePlacements: [PanePlacement]
    let dividerPlacements: [DividerPlacement]
    let nodeFrames: [[LayoutPathComponent]: NSRect]
    let effectiveFractions: [[LayoutPathComponent]: [CGFloat]]

    static func compute(
        node: LayoutNode,
        rect: NSRect,
        dividerThickness: CGFloat = WorkspaceLayoutMetrics.dividerThickness,
        minimumPaneSize: NSSize = WorkspaceLayoutMetrics.minimumPaneSize
    ) -> TilingLayout {
        var panePlacements: [PanePlacement] = []
        var dividerPlacements: [DividerPlacement] = []
        var nodeFrames: [[LayoutPathComponent]: NSRect] = [:]
        var effectiveFractions: [[LayoutPathComponent]: [CGFloat]] = [:]

        walk(
            node: node,
            rect: rect,
            path: [],
            dividerThickness: dividerThickness,
            minimumPaneSize: minimumPaneSize,
            panePlacements: &panePlacements,
            dividerPlacements: &dividerPlacements,
            nodeFrames: &nodeFrames,
            effectiveFractions: &effectiveFractions
        )

        return TilingLayout(
            panePlacements: panePlacements,
            dividerPlacements: dividerPlacements,
            nodeFrames: nodeFrames,
            effectiveFractions: effectiveFractions
        )
    }

    private static func walk(
        node: LayoutNode,
        rect: NSRect,
        path: [LayoutPathComponent],
        dividerThickness: CGFloat,
        minimumPaneSize: NSSize,
        panePlacements: inout [PanePlacement],
        dividerPlacements: inout [DividerPlacement],
        nodeFrames: inout [[LayoutPathComponent]: NSRect],
        effectiveFractions: inout [[LayoutPathComponent]: [CGFloat]]
    ) {
        nodeFrames[path] = rect

        switch node {
        case .panel(let paneID):
            panePlacements.append(PanePlacement(paneID: paneID, frame: rect))

        case .split(let axis, let children, let fractions):
            let primaryLength = axis == .horizontal ? rect.width : rect.height
            let dividerCount = max(0, children.count - 1)
            let usablePrimaryLength = max(
                0,
                primaryLength - dividerThickness * CGFloat(dividerCount)
            )

            let clampedFractions: [CGFloat]
            if usablePrimaryLength > 0 {
                clampedFractions = node.clampedFractions(
                    fractions,
                    in: rect.size,
                    panelMinimumSize: minimumPaneSize,
                    dividerThickness: dividerThickness
                )
            } else {
                clampedFractions = Array(
                    repeating: 1.0 / CGFloat(max(1, children.count)),
                    count: children.count
                )
            }

            effectiveFractions[path] = clampedFractions

            var cursor: CGFloat = 0
            for (index, child) in children.enumerated() {
                let childPrimaryLength = usablePrimaryLength * clampedFractions[index]
                let childRect = Self.childRect(
                    in: rect,
                    axis: axis,
                    primaryOrigin: cursor,
                    primaryLength: childPrimaryLength
                )

                walk(
                    node: child,
                    rect: childRect,
                    path: path + [.child(index)],
                    dividerThickness: dividerThickness,
                    minimumPaneSize: minimumPaneSize,
                    panePlacements: &panePlacements,
                    dividerPlacements: &dividerPlacements,
                    nodeFrames: &nodeFrames,
                    effectiveFractions: &effectiveFractions
                )

                cursor += childPrimaryLength

                if index < children.count - 1 {
                    let divRect = Self.dividerRect(
                        in: rect,
                        axis: axis,
                        primaryOrigin: cursor,
                        dividerThickness: dividerThickness
                    )
                    dividerPlacements.append(
                        DividerPlacement(
                            splitPath: path,
                            dividerIndex: index,
                            rect: divRect
                        )
                    )
                    cursor += dividerThickness
                }
            }
        }
    }

    static func childRect(
        in parentRect: NSRect,
        axis: SplitAxis,
        primaryOrigin: CGFloat,
        primaryLength: CGFloat
    ) -> NSRect {
        switch axis {
        case .horizontal:
            return NSRect(
                x: parentRect.minX + primaryOrigin,
                y: parentRect.minY,
                width: primaryLength,
                height: parentRect.height
            )
        case .vertical:
            return NSRect(
                x: parentRect.minX,
                y: parentRect.maxY - primaryOrigin - primaryLength,
                width: parentRect.width,
                height: primaryLength
            )
        }
    }

    static func dividerRect(
        in parentRect: NSRect,
        axis: SplitAxis,
        primaryOrigin: CGFloat,
        dividerThickness: CGFloat
    ) -> NSRect {
        switch axis {
        case .horizontal:
            return NSRect(
                x: parentRect.minX + primaryOrigin,
                y: parentRect.minY,
                width: dividerThickness,
                height: parentRect.height
            )
        case .vertical:
            return NSRect(
                x: parentRect.minX,
                y: parentRect.maxY - primaryOrigin - dividerThickness,
                width: parentRect.width,
                height: dividerThickness
            )
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -workspace Santty.xcworkspace -scheme Santty -destination 'platform=macOS' test -only-testing:SanttyTests/WorkspaceTilingViewTests 2>&1 | tail -20`
Expected: All TilingLayout tests PASS

- [ ] **Step 5: Commit**

```bash
git add Santty/Sources/Workspace/Views/WorkspaceTilingView.swift Santty/Tests/WorkspaceTilingViewTests.swift
git commit -m "feat: add TilingLayout pure computation with tests"
```

---

## Task 2: WorkspaceTilingView — Basic Layout and Cursor Rects

**Files:**
- Modify: `Santty/Sources/Workspace/Views/WorkspaceTilingView.swift` (add `TilingFractionChangeSource` + `WorkspaceTilingView` class)
- Modify: `Santty/Tests/WorkspaceTilingViewTests.swift` (add view tests)

- [ ] **Step 1: Write WorkspaceTilingView basic layout tests**

Add to `Santty/Tests/WorkspaceTilingViewTests.swift`:

```swift
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

    func testTilingViewHorizontalSplitLayout() throws {
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

    func testTilingViewNestedSplitLayout() throws {
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

    func testDebugNodeFrameReturnsBoundingRectForSplitPath() {
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

        // [.child(1)] is the nested vertical split — its bounding rect is the right half
        let nestedFrame = tilingView.debugNodeFrame(at: [.child(1)])
        XCTAssertEqual(nestedFrame?.minX, 503, accuracy: 0.01)
        XCTAssertEqual(nestedFrame?.width, 497, accuracy: 0.01)
        XCTAssertEqual(nestedFrame?.height, 600, accuracy: 0.01)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -workspace Santty.xcworkspace -scheme Santty -destination 'platform=macOS' test -only-testing:SanttyTests/WorkspaceTilingViewTests 2>&1 | tail -20`
Expected: FAIL — `WorkspaceTilingView` is not defined

- [ ] **Step 3: Implement WorkspaceTilingView basic layout**

Add to `Santty/Sources/Workspace/Views/WorkspaceTilingView.swift`:

```swift
enum TilingFractionChangeSource: Equatable {
    case layoutClamp
    case userDrag
}

@MainActor
final class WorkspaceTilingView: NSView {
    var onFractionsChange:
        (([LayoutPathComponent], [CGFloat], TilingFractionChangeSource) -> Void)?

    private var layoutNode: LayoutNode?
    var paneViews: [PaneID: NSView] = [:]  // internal for @testable test access
    private var currentLayout: TilingLayout?
    private let dividerThickness: CGFloat
    private let minimumPaneSize: NSSize
    private var animationGeneration = 0

    override var mouseDownCanMoveWindow: Bool { false }

    init(
        dividerThickness: CGFloat = WorkspaceLayoutMetrics.dividerThickness,
        minimumPaneSize: NSSize = WorkspaceLayoutMetrics.minimumPaneSize
    ) {
        self.dividerThickness = dividerThickness
        self.minimumPaneSize = minimumPaneSize
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    func setLayoutNode(_ node: LayoutNode, paneViews: [PaneID: NSView]) {
        setLayoutNode(node, paneViews: paneViews, animated: false)
    }

    func setLayoutNode(_ node: LayoutNode, paneViews: [PaneID: NSView], animated: Bool) {
        let oldPaneIDs = Set(self.layoutNode?.paneIDsInTraversalOrder ?? [])
        let newPaneIDs = Set(node.paneIDsInTraversalOrder)
        let structureChanged = oldPaneIDs != newPaneIDs

        // Remove views for panes no longer in the tree
        for (paneID, view) in self.paneViews where !newPaneIDs.contains(paneID) {
            view.removeFromSuperview()
            self.paneViews.removeValue(forKey: paneID)
        }

        // Add views for new panes
        for (paneID, view) in paneViews where self.paneViews[paneID] == nil {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
            self.paneViews[paneID] = view
        }

        // Replace views that changed (e.g., host view ↔ placeholder)
        for (paneID, view) in paneViews where self.paneViews[paneID] !== view {
            self.paneViews[paneID]?.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
            self.paneViews[paneID] = view
        }

        self.layoutNode = node
        self.paneViews = paneViews

        if !structureChanged && animated {
            applyAnimatedLayout()
        } else {
            animationGeneration += 1
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        guard let layoutNode else { return }

        let layout = TilingLayout.compute(
            node: layoutNode,
            rect: bounds,
            dividerThickness: dividerThickness,
            minimumPaneSize: minimumPaneSize
        )
        currentLayout = layout
        applyPaneFrames(layout)
        checkForClampedFractions(layout, node: layoutNode)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layout = currentLayout else { return }

        for divider in layout.dividerPlacements {
            guard let node = layoutNode?.node(at: divider.splitPath),
                  case .split(let axis, _, _) = node
            else {
                continue
            }

            let cursor: NSCursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
            addCursorRect(divider.rect, cursor: cursor)
        }
    }

    private func applyPaneFrames(_ layout: TilingLayout) {
        for placement in layout.panePlacements {
            if let view = paneViews[placement.paneID] {
                view.frame = placement.frame
            }
        }
    }

    private func checkForClampedFractions(_ layout: TilingLayout, node: LayoutNode) {
        checkForClampedFractionsRecursive(layout: layout, node: node, path: [])
    }

    private func checkForClampedFractionsRecursive(
        layout: TilingLayout,
        node: LayoutNode,
        path: [LayoutPathComponent]
    ) {
        guard case .split(_, let children, let storedFractions) = node else {
            return
        }

        if let effectiveFractions = layout.effectiveFractions[path],
            effectiveFractions != storedFractions
        {
            layoutNode = layoutNode?.replacingFractions(at: path, with: effectiveFractions)
            onFractionsChange?(path, effectiveFractions, .layoutClamp)
        }

        for (index, child) in children.enumerated() {
            checkForClampedFractionsRecursive(
                layout: layout,
                node: child,
                path: path + [.child(index)]
            )
        }
    }

    // MARK: - Debug API

    func debugCurrentFractions(at path: [LayoutPathComponent]) -> [CGFloat]? {
        guard let node = layoutNode?.node(at: path) else { return nil }
        guard case .split(_, _, let fractions) = node else { return nil }
        return fractions
    }

    func debugPaneFrame(paneID: PaneID) -> NSRect? {
        currentLayout?.panePlacements.first { $0.paneID == paneID }?.frame
    }

    func debugNodeFrame(at path: [LayoutPathComponent]) -> NSRect? {
        currentLayout?.nodeFrames[path]
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -workspace Santty.xcworkspace -scheme Santty -destination 'platform=macOS' test -only-testing:SanttyTests/WorkspaceTilingViewTests 2>&1 | tail -30`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Santty/Sources/Workspace/Views/WorkspaceTilingView.swift Santty/Tests/WorkspaceTilingViewTests.swift
git commit -m "feat: add WorkspaceTilingView with basic layout and debug API"
```

---

## Task 3: Divider Drag Interaction

**Files:**
- Modify: `Santty/Sources/Workspace/Views/WorkspaceTilingView.swift` (add mouse handling)
- Modify: `Santty/Tests/WorkspaceTilingViewTests.swift` (add drag tests)

- [ ] **Step 1: Write divider drag tests**

Add to `Santty/Tests/WorkspaceTilingViewTests.swift`:

```swift
    // MARK: - WorkspaceTilingView: Divider Drag

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
        tilingView.debugApplyDragForDivider(at: [], dividerIndex: 0, location: NSPoint(x: 700, y: 300))

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
        tilingView.debugApplyDragForDivider(at: [], dividerIndex: 0, location: NSPoint(x: 950, y: 300))

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
        tilingView.debugApplyDragForDivider(at: [.child(1)], dividerIndex: 0, location: NSPoint(x: 750, y: 200))

        XCTAssertEqual(receivedPath, [.child(1)])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -workspace Santty.xcworkspace -scheme Santty -destination 'platform=macOS' test -only-testing:SanttyTests/WorkspaceTilingViewTests 2>&1 | tail -20`
Expected: FAIL — `debugApplyDragForDivider` is not defined

- [ ] **Step 3: Implement divider drag**

Add to `WorkspaceTilingView` in `WorkspaceTilingView.swift`:

```swift
    override func mouseDown(with event: NSEvent) {
        layoutSubtreeIfNeeded()
        guard let layout = currentLayout else {
            super.mouseDown(with: event)
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        guard let hitDivider = layout.dividerPlacements.first(where: {
            $0.rect.contains(location)
        }) else {
            super.mouseDown(with: event)
            return
        }

        animationGeneration += 1

        while let nextEvent = window?.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) {
            let nextLocation = convert(nextEvent.locationInWindow, from: nil)
            applyDividerDrag(
                splitPath: hitDivider.splitPath,
                dividerIndex: hitDivider.dividerIndex,
                location: nextLocation
            )

            if nextEvent.type == .leftMouseUp {
                return
            }
        }
    }

    private func applyDividerDrag(
        splitPath: [LayoutPathComponent],
        dividerIndex: Int,
        location: NSPoint
    ) {
        guard let layoutNode,
              let splitNode = layoutNode.node(at: splitPath),
              case .split(let axis, let children, let fractions) = splitNode
        else {
            return
        }

        guard let splitRect = currentLayout?.nodeFrames[splitPath] else { return }

        let newFractions = Self.computeDragFractions(
            axis: axis,
            fractions: fractions,
            dividerIndex: dividerIndex,
            location: location,
            splitRect: splitRect,
            children: children,
            dividerThickness: dividerThickness,
            minimumPaneSize: minimumPaneSize
        )

        guard newFractions != fractions else { return }

        if let updatedNode = layoutNode.replacingFractions(
            at: splitPath, with: newFractions
        ) {
            self.layoutNode = updatedNode
            let layout = TilingLayout.compute(
                node: updatedNode,
                rect: bounds,
                dividerThickness: dividerThickness,
                minimumPaneSize: minimumPaneSize
            )
            currentLayout = layout
            applyPaneFrames(layout)
            onFractionsChange?(splitPath, newFractions, .userDrag)
        }
    }

    private static func computeDragFractions(
        axis: SplitAxis,
        fractions: [CGFloat],
        dividerIndex: Int,
        location: NSPoint,
        splitRect: NSRect,
        children: [LayoutNode],
        dividerThickness: CGFloat,
        minimumPaneSize: NSSize
    ) -> [CGFloat] {
        let primaryLength =
            axis == .horizontal ? splitRect.width : splitRect.height
        let dividerCount = max(0, children.count - 1)
        let usablePrimaryLength = max(
            0,
            primaryLength - dividerThickness * CGFloat(dividerCount)
        )

        guard usablePrimaryLength > 0 else { return fractions }

        // Compute the combined primary extent of the two adjacent children
        let leadingMinSize = children[dividerIndex].minimumSize(
            panelMinimumSize: minimumPaneSize, dividerThickness: dividerThickness
        )
        let trailingMinSize = children[dividerIndex + 1].minimumSize(
            panelMinimumSize: minimumPaneSize, dividerThickness: dividerThickness
        )
        let minimumLeadingLength =
            axis == .horizontal ? leadingMinSize.width : leadingMinSize.height
        let minimumTrailingLength =
            axis == .horizontal ? trailingMinSize.width : trailingMinSize.height

        // Sum of primary lengths for the two adjacent panes
        let combinedPrimaryLength =
            usablePrimaryLength * fractions[dividerIndex]
            + usablePrimaryLength * fractions[dividerIndex + 1]

        // Compute the proposed leading length from the drag location
        let proposedLeadingLength: CGFloat
        switch axis {
        case .horizontal:
            proposedLeadingLength = location.x - splitRect.minX
                - fractions.prefix(dividerIndex).reduce(0) {
                    $0 + usablePrimaryLength * $1 + dividerThickness
                }
        case .vertical:
            let leadingOrigin = fractions.prefix(dividerIndex).reduce(0) {
                $0 + usablePrimaryLength * $1 + dividerThickness
            }
            let leadingTop =
                splitRect.maxY - leadingOrigin
            proposedLeadingLength = leadingTop - location.y
        }

        let clampedLeadingLength = min(
            max(proposedLeadingLength, minimumLeadingLength),
            combinedPrimaryLength - minimumTrailingLength
        )
        let clampedTrailingLength = combinedPrimaryLength - clampedLeadingLength

        var updated = fractions
        updated[dividerIndex] = clampedLeadingLength / usablePrimaryLength
        updated[dividerIndex + 1] = clampedTrailingLength / usablePrimaryLength
        return updated
    }

    // MARK: - Debug Drag

    func debugApplyDragForDivider(
        at splitPath: [LayoutPathComponent],
        dividerIndex: Int,
        location: NSPoint
    ) {
        layoutSubtreeIfNeeded()
        applyDividerDrag(
            splitPath: splitPath,
            dividerIndex: dividerIndex,
            location: location
        )
    }
```

The `paneViews` property is already `internal` (set in Task 2), so `@testable import` tests can access it directly.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -workspace Santty.xcworkspace -scheme Santty -destination 'platform=macOS' test -only-testing:SanttyTests/WorkspaceTilingViewTests 2>&1 | tail -30`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Santty/Sources/Workspace/Views/WorkspaceTilingView.swift Santty/Tests/WorkspaceTilingViewTests.swift
git commit -m "feat: add divider drag interaction to WorkspaceTilingView"
```

---

## Task 4: FLIP Animation

**Files:**
- Modify: `Santty/Sources/Workspace/Views/WorkspaceTilingView.swift` (add FLIP animation)
- Modify: `Santty/Tests/WorkspaceTilingViewTests.swift` (add animation tests)

- [ ] **Step 1: Write FLIP animation tests**

Add to `Santty/Tests/WorkspaceTilingViewTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -workspace Santty.xcworkspace -scheme Santty -destination 'platform=macOS' test -only-testing:SanttyTests/WorkspaceTilingViewTests 2>&1 | tail -20`
Expected: Tests may pass already since `setLayoutNode(animated:)` falls through to instant layout. The animation test checks model state and final frames, which are correct even without FLIP. This is expected — the FLIP animation is a visual effect that doesn't change the model or final frames.

- [ ] **Step 3: Implement FLIP animation**

Add the `applyAnimatedLayout` method to `WorkspaceTilingView`:

```swift
    private func applyAnimatedLayout() {
        guard let layoutNode else { return }

        let generation = animationGeneration + 1
        animationGeneration = generation

        // Settle current layout and snapshot pre-animation frames
        layoutSubtreeIfNeeded()
        let oldFrames = paneViews.mapValues { $0.frame }

        // Apply new layout instantly
        let newLayout = TilingLayout.compute(
            node: layoutNode,
            rect: bounds,
            dividerThickness: dividerThickness,
            minimumPaneSize: minimumPaneSize
        )
        currentLayout = newLayout
        applyPaneFrames(newLayout)
        checkForClampedFractions(newLayout, node: layoutNode)

        let newFrames = paneViews.mapValues { $0.frame }

        // FLIP: apply inverse transforms and animate to identity
        let duration = WorkspaceFocusZoomConfiguration.animationDuration
        let timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(timingFunction)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard generation == self.animationGeneration else { return }
                self.layoutSubtreeIfNeeded()
            }
        }

        for (paneID, view) in paneViews {
            guard let oldFrame = oldFrames[paneID],
                  let newFrame = newFrames[paneID]
            else {
                continue
            }

            animateFlip(
                view: view,
                oldFrame: oldFrame,
                newFrame: newFrame,
                duration: duration,
                timingFunction: timingFunction
            )
        }

        CATransaction.commit()
    }

    private func animateFlip(
        view: NSView,
        oldFrame: NSRect,
        newFrame: NSRect,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction
    ) {
        guard let layer = view.layer,
              newFrame.width > 0,
              newFrame.height > 0
        else {
            return
        }

        if oldFrame == newFrame { return }

        let scaleX = oldFrame.width / newFrame.width
        let scaleY = oldFrame.height / newFrame.height

        let anchor = layer.anchorPoint
        let translateX = (oldFrame.minX - newFrame.minX)
            + anchor.x * (oldFrame.width - newFrame.width)
        let translateY = (oldFrame.minY - newFrame.minY)
            + anchor.y * (oldFrame.height - newFrame.height)

        let initialAffine = CGAffineTransform.identity
            .translatedBy(x: translateX, y: translateY)
            .scaledBy(x: scaleX, y: scaleY)
        let initialTransform = CATransform3DMakeAffineTransform(initialAffine)

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: initialTransform)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = duration
        animation.timingFunction = timingFunction
        animation.fillMode = .both
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: "santty.paneResize.flip")
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -workspace Santty.xcworkspace -scheme Santty -destination 'platform=macOS' test -only-testing:SanttyTests/WorkspaceTilingViewTests 2>&1 | tail -30`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Santty/Sources/Workspace/Views/WorkspaceTilingView.swift Santty/Tests/WorkspaceTilingViewTests.swift
git commit -m "feat: add FLIP animation to WorkspaceTilingView"
```

---

## Task 5: WorkspaceViewController Integration

**Files:**
- Modify: `Santty/Sources/Workspace/WorkspaceViewController.swift`

This is the most complex task. The controller currently uses `splitViewsByPath` (a dictionary of `WorkspaceSplitView` instances) and `makeRenderedView` (recursive view factory). We replace both with a single `tilingView`.

- [ ] **Step 1: Replace `splitViewsByPath` with `tilingView`**

In `WorkspaceViewController.swift`, replace the `splitViewsByPath` property:

```swift
// DELETE:
private var splitViewsByPath: [[LayoutPathComponent]: WorkspaceSplitView] = [:]

// ADD:
private var tilingView: WorkspaceTilingView?
```

- [ ] **Step 2: Rewrite `rebuildWorkspaceLayout`**

Replace the `rebuildWorkspaceLayout` method:

```swift
    private func rebuildWorkspaceLayout(applyAutoZoomAnimated: Bool = false) {
        updateTabStrip()

        guard let tabState = selectedTabState, let layoutNode = tabState.layoutNode else {
            tilingView = nil
            rootView.installRenderedContentView(NSView())
            view.layoutSubtreeIfNeeded()
            updateWindowTitle()
            updateWindowMinimumSize()
            applyFocusedPaneResponder()
            return
        }

        let paneViews = buildPaneViewsDictionary(for: tabState)

        if let tilingView {
            tilingView.setLayoutNode(layoutNode, paneViews: paneViews)
        } else {
            let newTilingView = WorkspaceTilingView()
            newTilingView.onFractionsChange = { [weak self] path, fractions, source in
                self?.updateSplitFractions(
                    at: path, to: fractions, changeSource: source
                )
            }
            tilingView = newTilingView
            newTilingView.setLayoutNode(layoutNode, paneViews: paneViews)
            rootView.installRenderedContentView(newTilingView)
        }

        view.layoutSubtreeIfNeeded()
        if !applyPreservedActiveAutoZoom(in: tabState) {
            applyAutoZoomToFocusedPane(in: tabState, animated: applyAutoZoomAnimated)
        }
        updatePanePresentation(in: tabState)
        updateWindowTitle()
        updateWindowMinimumSize()
        applyFocusedPaneResponder()
    }
```

- [ ] **Step 3: Add `buildPaneViewsDictionary` helper**

Add this method to `WorkspaceViewController`:

```swift
    private func buildPaneViewsDictionary(
        for tabState: WorkspaceTabState
    ) -> [PaneID: NSView] {
        var result: [PaneID: NSView] = [:]
        for (paneID, paneController) in tabState.paneControllers {
            if tabState.activeFloatingPaneState?.paneID == paneID {
                result[paneID] = TerminalPanePlaceholderView(paneID: paneID)
            } else {
                result[paneID] = paneController.hostView
            }
        }
        return result
    }
```

- [ ] **Step 4: Delete `makeRenderedView`**

Remove the `makeRenderedView(for:path:)` method entirely. It's no longer needed — the tiling view handles all view hierarchy internally.

- [ ] **Step 5: Update `updateSplitFractions`**

Replace `WorkspaceSplitFractionChangeSource` with `TilingFractionChangeSource` in the method signature and implementation:

```swift
    private func updateSplitFractions(
        at path: [LayoutPathComponent],
        to fractions: [CGFloat],
        changeSource: TilingFractionChangeSource
    ) {
        guard let tabState = selectedTabState, let layoutNode = tabState.layoutNode else {
            return
        }

        if tabState.activeAutoZoomState?.splitStates.contains(where: { $0.splitPath == path })
            == true
        {
            tabState.activeAutoZoomState = nil
        }

        if changeSource == .userDrag {
            disableAutoResizeForPanesAffectedBySplit(at: path, in: tabState)
        }

        tabState.layoutNode = layoutNode.replacingFractions(at: path, with: fractions)
        updateWindowMinimumSize()
    }
```

- [ ] **Step 6: Update `closeTab` to clear `tilingView`**

In `closeTab(withID:bypassTabConfirmation:)`, replace `splitViewsByPath = [:]` with `tilingView = nil`:

```swift
            splitViewsByPath = [:]  // DELETE
            tilingView = nil        // ADD
```

- [ ] **Step 7: Update `movePaneDivider` and `focusedResizeTarget`**

Replace `focusedResizeTarget` to use `tilingView` instead of `splitViewsByPath`:

```swift
    private func focusedResizeTarget(
        for axis: SplitAxis
    ) -> (
        context: ParentSplitContext,
        splitNode: LayoutNode,
        tilingView: WorkspaceTilingView
    )? {
        guard
            let tabState = selectedTabState,
            let layoutNode = tabState.layoutNode,
            let focusedPaneID = tabState.focusedPaneID,
            let tilingView,
            let context = layoutNode.ancestorSplitContexts(for: focusedPaneID).reversed()
                .first(where: { $0.axis == axis && $0.fractions.count > 1 }),
            let splitNode = layoutNode.node(at: context.splitPath)
        else {
            return nil
        }

        return (context, splitNode, tilingView)
    }
```

Update `movePaneDivider` to use the tiling view:

```swift
    private func movePaneDivider(_ direction: PaneDividerMoveDirection) {
        guard
            let target = focusedResizeTarget(for: direction.axis),
            let targetFractions = movedDividerFractions(
                in: target.context,
                direction: direction
            )
        else {
            NSSound.beep()
            return
        }

        let clampedFractions = target.splitNode.clampedFractions(
            targetFractions,
            in: target.tilingView.bounds.size
        )
        guard clampedFractions != target.context.fractions else {
            NSSound.beep()
            return
        }

        // Update the model
        if let layoutNode = selectedTabState?.layoutNode,
           let updatedNode = layoutNode.replacingFractions(
               at: target.context.splitPath, with: clampedFractions
           )
        {
            selectedTabState?.layoutNode = updatedNode
            let paneViews = buildPaneViewsDictionary(for: selectedTabState!)
            target.tilingView.setLayoutNode(
                updatedNode, paneViews: paneViews, animated: true
            )
        }

        updateSplitFractions(
            at: target.context.splitPath,
            to: clampedFractions,
            changeSource: .userDrag
        )
    }
```

- [ ] **Step 8: Update auto-zoom methods**

Replace `autoZoomTargetStates` and `applyAutoZoomTargetStates` to use the tiling view:

```swift
    private func autoZoomTargetStates(
        for focusedPaneID: PaneID,
        in tabState: WorkspaceTabState
    ) -> [(ParentSplitContext, [CGFloat])] {
        guard
            let layoutNode = tabState.layoutNode,
            let autoResizeConfiguration = tabState.paneAutoResizeConfigurations[focusedPaneID],
            autoResizeConfiguration.isEnabled,
            let tilingView
        else {
            return []
        }

        return layoutNode.ancestorSplitContexts(for: focusedPaneID).compactMap {
            context -> (ParentSplitContext, [CGFloat])? in
            guard let splitNode = layoutNode.node(at: context.splitPath) else {
                return nil
            }

            let focusedRatio = autoResizeConfiguration.ratios[context.axis]
            let proposedFractions = context.replacingFocusedChildFraction(focusedRatio)
            let targetFractions = splitNode.clampedFractions(
                proposedFractions, in: tilingView.bounds.size
            )

            guard targetFractions != context.fractions else {
                return nil
            }

            return (context, targetFractions)
        }
    }
```

Update `applyAutoZoomToFocusedPane` to batch all fraction changes into a single `setLayoutNode` call:

```swift
    private func applyAutoZoomToFocusedPane(in tabState: WorkspaceTabState, animated: Bool) {
        guard tabState.activeFloatingPaneState == nil else { return }

        guard
            let focusedPaneID = tabState.focusedPaneID,
            let autoResizeConfiguration = tabState.paneAutoResizeConfigurations[focusedPaneID],
            autoResizeConfiguration.isEnabled
        else {
            tabState.activeAutoZoomState = nil
            return
        }

        let targetStates = autoZoomTargetStates(for: focusedPaneID, in: tabState)
        guard !targetStates.isEmpty else {
            tabState.activeAutoZoomState = nil
            return
        }

        tabState.activeAutoZoomState = ActiveAutoZoomState(
            focusedPaneID: focusedPaneID,
            splitStates: targetStates.map { context, _ in
                ActiveAutoZoomSplitState(
                    splitPath: context.splitPath,
                    originalFractions: context.fractions
                )
            }
        )

        applyAutoZoomTargetStates(targetStates, animated: animated)
    }

    private func applyAutoZoomTargetStates(
        _ targetStates: [(ParentSplitContext, [CGFloat])],
        animated: Bool
    ) {
        guard let tabState = selectedTabState,
              var layoutNode = tabState.layoutNode,
              let tilingView
        else {
            return
        }

        for (context, targetFractions) in targetStates {
            if let updated = layoutNode.replacingFractions(
                at: context.splitPath, with: targetFractions
            ) {
                layoutNode = updated
            }
        }

        tabState.layoutNode = layoutNode
        let paneViews = buildPaneViewsDictionary(for: tabState)
        tilingView.setLayoutNode(layoutNode, paneViews: paneViews, animated: animated)
    }
```

Update `restoreActiveAutoZoom` similarly:

```swift
    private func restoreActiveAutoZoom(in tabState: WorkspaceTabState, animated: Bool) {
        guard let activeAutoZoomState = tabState.activeAutoZoomState,
              var layoutNode = tabState.layoutNode,
              let tilingView
        else {
            return
        }

        for splitState in activeAutoZoomState.splitStates.reversed() {
            if let updated = layoutNode.replacingFractions(
                at: splitState.splitPath, with: splitState.originalFractions
            ) {
                layoutNode = updated
            }
        }

        tabState.layoutNode = layoutNode
        let paneViews = buildPaneViewsDictionary(for: tabState)
        tilingView.setLayoutNode(layoutNode, paneViews: paneViews, animated: animated)
        tabState.activeAutoZoomState = nil
    }
```

- [ ] **Step 9: Update debug API methods**

Replace the debug methods that delegate to `splitViewsByPath`:

```swift
    func debugRenderedSplitFractions(at path: [LayoutPathComponent]) -> [CGFloat]? {
        tilingView?.debugCurrentFractions(at: path)
    }

    func debugRenderedSplitChildFrame(
        at path: [LayoutPathComponent],
        childIndex: Int
    ) -> NSRect? {
        tilingView?.debugNodeFrame(at: path + [.child(childIndex)])
    }

    func debugUpdateSplitFractions(at path: [LayoutPathComponent], to fractions: [CGFloat]) {
        guard let tabState = selectedTabState,
              var layoutNode = tabState.layoutNode,
              let tilingView
        else {
            return
        }

        if let updated = layoutNode.replacingFractions(at: path, with: fractions) {
            layoutNode = updated
        }

        tabState.layoutNode = layoutNode
        let paneViews = buildPaneViewsDictionary(for: tabState)
        tilingView.setLayoutNode(layoutNode, paneViews: paneViews)
        updateSplitFractions(at: path, to: fractions, changeSource: .userDrag)
    }
```

- [ ] **Step 10: Delete `clampedAutoZoomFractions` method**

This method took a `WorkspaceSplitView` parameter and is no longer needed — clamping is now done inline in `autoZoomTargetStates` via `splitNode.clampedFractions(proposedFractions, in: tilingView.bounds.size)`. Remove the entire method.

- [ ] **Step 11: Remove `WorkspaceSplitFractionChangeSource` references**

The old enum `WorkspaceSplitFractionChangeSource` was defined in `WorkspaceSplitView.swift` (which we'll delete). The controller now uses `TilingFractionChangeSource` from `WorkspaceTilingView.swift`. Ensure no remaining references to `WorkspaceSplitFractionChangeSource` exist.

Search for `WorkspaceSplitFractionChangeSource` and replace all occurrences with `TilingFractionChangeSource`.

- [ ] **Step 12: Build and run all tests**

Run: `xcodebuild -workspace Santty.xcworkspace -scheme Santty -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

Run: `xcodebuild -workspace Santty.xcworkspace -scheme Santty -destination 'platform=macOS' test 2>&1 | tail -40`
Expected: All tests PASS (both `WorkspaceTilingViewTests` and `WorkspaceViewControllerTests`)

- [ ] **Step 13: Commit**

```bash
git add Santty/Sources/Workspace/WorkspaceViewController.swift
git commit -m "refactor: integrate WorkspaceTilingView into WorkspaceViewController"
```

---

## Task 6: Cleanup — Delete Old Code

**Files:**
- Delete: `Santty/Sources/Workspace/Views/WorkspaceSplitView.swift`
- Delete: `Santty/Tests/WorkspaceSplitViewTests.swift`

- [ ] **Step 1: Delete WorkspaceSplitView.swift**

```bash
git rm Santty/Sources/Workspace/Views/WorkspaceSplitView.swift
```

- [ ] **Step 2: Delete WorkspaceSplitViewTests.swift**

```bash
git rm Santty/Tests/WorkspaceSplitViewTests.swift
```

- [ ] **Step 3: Build and run all tests**

Run: `xcodebuild -workspace Santty.xcworkspace -scheme Santty -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

Run: `xcodebuild -workspace Santty.xcworkspace -scheme Santty -destination 'platform=macOS' test 2>&1 | tail -40`
Expected: All tests PASS

- [ ] **Step 4: Search for any remaining references to deleted types**

Search the codebase for `WorkspaceSplitView`, `WorkspaceSplitDividerView`, `FlipAnimationProbe`, `WorkspaceSplitFractionChangeSource`. There should be zero hits outside of git history.

If any references remain, fix them and re-run tests.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove WorkspaceSplitView, replaced by flat WorkspaceTilingView"
```
