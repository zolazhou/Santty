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
