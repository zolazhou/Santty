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

enum TilingFractionChangeSource: Equatable {
    case layoutClamp
    case userDrag
}

@MainActor
final class WorkspaceTilingView: NSView {
    var onFractionsChange:
        (([LayoutPathComponent], [CGFloat], TilingFractionChangeSource) -> Void)?

    private var layoutNode: LayoutNode?
    var paneViews: [PaneID: NSView] = [:]
    private var currentLayout: TilingLayout?
    private let dividerThickness: CGFloat
    private let minimumPaneSize: NSSize
    var animationGeneration = 0

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
        // Suppress implicit position/bounds animations so layout-induced
        // geometry changes don't fight an in-flight FLIP.
        layer?.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
        ]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    // MARK: - Public API

    func setLayoutNode(_ node: LayoutNode, paneViews: [PaneID: NSView]) {
        setLayoutNode(node, paneViews: paneViews, animated: false)
    }

    func setLayoutNode(
        _ node: LayoutNode,
        paneViews: [PaneID: NSView],
        animated: Bool
    ) {
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

        // Replace views that changed identity (e.g., host view ↔ placeholder).
        // Only detach the old view when it is still our direct subview; the
        // floating-pane flow re-parents the host view into the floating
        // overlay before we get here, and a blind removeFromSuperview() would
        // rip it out of the overlay and make the floating pane invisible.
        for (paneID, view) in paneViews where self.paneViews[paneID] !== view {
            let oldView = self.paneViews[paneID]
            if oldView?.superview === self {
                oldView?.removeFromSuperview()
            }
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
            self.paneViews[paneID] = view
        }

        let desiredViewIDs = Set(paneViews.values.map { ObjectIdentifier($0) })
        for subview in subviews where !desiredViewIDs.contains(ObjectIdentifier(subview)) {
            subview.removeFromSuperview()
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

    // MARK: - Layout

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

            let cursor: NSCursor =
                axis == .horizontal ? .resizeLeftRight : .resizeUpDown
            addCursorRect(divider.rect, cursor: cursor)
        }
    }

    // MARK: - Internal

    func applyPaneFrames(_ layout: TilingLayout) {
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
            layoutNode = layoutNode?.replacingFractions(
                at: path, with: effectiveFractions
            )
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

    func applyAnimatedLayout() {
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

    func animateFlip(
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

    // MARK: - Mouse Handling

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

        let combinedPrimaryLength =
            usablePrimaryLength * fractions[dividerIndex]
            + usablePrimaryLength * fractions[dividerIndex + 1]

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
            let leadingTop = splitRect.maxY - leadingOrigin
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

    // MARK: - Debug API

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
