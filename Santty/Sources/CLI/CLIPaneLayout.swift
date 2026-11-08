import AppKit

/// Pure model transformations. Background panes use the owning container's size,
/// not host-view frames (which are absent or stale in inactive tabs).
@MainActor
enum CLIPaneLayout {
    static func apply(_ request: CLIRequest, to node: LayoutNode, size: NSSize) throws -> LayoutNode {
        guard let id = request.paneID, node.path(to: id) != nil else { throw CLIError("Pane is not tiled.", code: "unsupported_layout") }
        if request.command == "pane.equalize" { return node.equalizingSplitFractions() }
        let direction = request.direction ?? ""
        let axis: SplitAxis = direction == "left" || direction == "right" ? .horizontal : .vertical
        let before = direction == "left" || direction == "up"
        let thickness = AppAppearanceSettings.workspaceDividerThickness
        let minimum = node.minimumSize(dividerThickness: thickness)
        let rect = NSRect(origin: .zero, size: NSSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height)))
        let geometry = TilingLayout.compute(node: node, rect: rect, dividerThickness: thickness)
        if request.command == "pane.move" {
            let frames = Dictionary(uniqueKeysWithValues: geometry.panePlacements.map { ($0.paneID, $0.frame) })
            guard let source = frames[id] else { throw CLIError("Pane has no layout frame.", code: "unsupported_layout") }
            let candidates = frames.compactMap { candidate, frame -> (PaneID, CGFloat)? in
                guard candidate != id else { return nil }
                let dx = frame.midX - source.midX, dy = frame.midY - source.midY
                let primary = axis == .horizontal ? dx : -dy
                guard before ? primary < 0 : primary > 0 else { return nil }
                let perpendicular = axis == .horizontal ? abs(dy) : abs(dx)
                return (candidate, abs(primary) + perpendicular * 2)
            }.sorted { $0.1 == $1.1 ? $0.0.uuidString < $1.0.uuidString : $0.1 < $1.1 }
            guard let target = candidates.first?.0, let result = node.swappingPane(id, with: target) else {
                throw CLIError("No pane in that direction.", code: "layout_boundary")
            }
            return result
        }
        // Expand the target toward the requested side, transferring only the
        // adjacent sibling's budget. Other fractions (including zero) stay put.
        for context in node.ancestorSplitContexts(for: id).reversed() where context.axis == axis {
            let neighbor = context.focusedChildIndex + (before ? -1 : 1)
            guard context.fractions.indices.contains(neighbor), context.fractions[neighbor] > 0,
                  case .split(_, let children, _) = node.node(at: context.splitPath),
                  let frame = geometry.nodeFrames[context.splitPath] else { continue }
            let visible = context.fractions.filter { $0 > 0 }.count
            let length = (axis == .horizontal ? frame.width : frame.height) - thickness * CGFloat(max(0, visible - 1))
            let neighborSize = children[neighbor].minimumSize(dividerThickness: thickness)
            let neighborMinimum = axis == .horizontal ? neighborSize.width : neighborSize.height
            guard length > 0 else { continue }
            let delta = min(CGFloat(request.amount ?? 40) / length, context.fractions[neighbor] - neighborMinimum / length)
            guard delta > 0.000001 else { throw CLIError("Adjacent pane is at its minimum size.", code: "layout_boundary") }
            var fractions = context.fractions
            fractions[context.focusedChildIndex] += delta
            fractions[neighbor] -= delta
            if let result = node.replacingFractions(at: context.splitPath, with: fractions) { return result }
        }
        throw CLIError("No resizable divider in that direction.", code: "layout_boundary")
    }
}
