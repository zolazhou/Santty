import AppKit

typealias PaneID = UUID

enum SplitAxis: Equatable {
    case horizontal
    case vertical
}

enum PaneFocusDirection: Equatable {
    case left
    case right
    case above
    case below
}

enum LayoutPathComponent: Hashable {
    case child(Int)
}

struct ParentSplitContext: Equatable {
    let splitPath: [LayoutPathComponent]
    let axis: SplitAxis
    let fractions: [CGFloat]
    let focusedChildIndex: Int

    var currentFocusedFraction: CGFloat {
        guard fractions.indices.contains(focusedChildIndex) else {
            return 0
        }

        return fractions[focusedChildIndex]
    }

    func replacingFocusedChildFraction(_ focusedFraction: CGFloat) -> [CGFloat] {
        guard fractions.indices.contains(focusedChildIndex) else {
            return fractions
        }

        let boundedFocusedFraction = min(max(focusedFraction, 0), 1)
        let remainingBudget = max(0, 1 - boundedFocusedFraction)
        let otherIndices = fractions.indices.filter { $0 != focusedChildIndex }
        let otherFractionSum = otherIndices.reduce(0) { partialResult, index in
            partialResult + max(0, fractions[index])
        }

        var updatedFractions = fractions
        updatedFractions[focusedChildIndex] = boundedFocusedFraction

        if otherIndices.isEmpty {
            return updatedFractions
        }

        if otherFractionSum > 0 {
            for index in otherIndices {
                updatedFractions[index] =
                    max(0, fractions[index]) / otherFractionSum * remainingBudget
            }
        } else {
            let fallbackFraction = remainingBudget / CGFloat(otherIndices.count)
            for index in otherIndices {
                updatedFractions[index] = fallbackFraction
            }
        }

        return updatedFractions
    }

    fileprivate func prefixed(with component: LayoutPathComponent) -> ParentSplitContext {
        ParentSplitContext(
            splitPath: [component] + splitPath,
            axis: axis,
            fractions: fractions,
            focusedChildIndex: focusedChildIndex
        )
    }
}

struct WorkspaceLayoutMetrics {
    static let minimumPaneSize = NSSize(width: 240, height: 160)
    static let dividerThickness: CGFloat = 6
    static let workspaceEdgePadding: CGFloat = 8
    static let workspaceSectionSpacing: CGFloat = 8
    static let tabStripHeight: CGFloat = 32
    static let minimumWindowContentSize = NSSize(width: 480, height: 320)
}

struct ClosePaneResult {
    let root: LayoutNode?
    let promotedPaneID: PaneID?
}

indirect enum LayoutNode: Equatable {
    case panel(PaneID)
    case split(axis: SplitAxis, children: [LayoutNode], fractions: [CGFloat])

    var firstPaneID: PaneID? {
        switch self {
        case .panel(let id):
            id
        case .split(_, let children, _):
            children.first?.firstPaneID
        }
    }

    var paneIDsInTraversalOrder: [PaneID] {
        switch self {
        case .panel(let id):
            [id]
        case .split(_, let children, _):
            children.flatMap(\.paneIDsInTraversalOrder)
        }
    }

    func path(to paneID: PaneID) -> [LayoutPathComponent]? {
        switch self {
        case .panel(let id):
            return id == paneID ? [] : nil
        case .split(_, let children, _):
            for (index, child) in children.enumerated() {
                if let childPath = child.path(to: paneID) {
                    return [.child(index)] + childPath
                }
            }

            return nil
        }
    }

    func node(at path: [LayoutPathComponent]) -> LayoutNode? {
        guard let component = path.first else {
            return self
        }

        let remainingPath = Array(path.dropFirst())

        switch self {
        case .split(_, let children, _):
            switch component {
            case .child(let index):
                guard children.indices.contains(index) else {
                    return nil
                }

                return children[index].node(at: remainingPath)
            }
        case .panel:
            return nil
        }
    }

    func parentSplitContext(for paneID: PaneID) -> ParentSplitContext? {
        switch self {
        case .panel:
            return nil
        case .split(let axis, let children, let fractions):
            for (index, child) in children.enumerated() {
                if let childContext = child.parentSplitContext(for: paneID) {
                    return childContext.prefixed(with: .child(index))
                }

                if child.path(to: paneID) != nil {
                    return ParentSplitContext(
                        splitPath: [],
                        axis: axis,
                        fractions: fractions,
                        focusedChildIndex: index
                    )
                }
            }

            return nil
        }
    }

    func ancestorSplitContexts(for paneID: PaneID) -> [ParentSplitContext] {
        ancestorSplitContexts(for: paneID, splitPath: []) ?? []
    }

    private func ancestorSplitContexts(
        for paneID: PaneID,
        splitPath: [LayoutPathComponent]
    ) -> [ParentSplitContext]? {
        switch self {
        case .panel(let id):
            return id == paneID ? [] : nil
        case .split(let axis, let children, let fractions):
            for (index, child) in children.enumerated() {
                let childPath = splitPath + [.child(index)]
                guard let childContexts = child.ancestorSplitContexts(
                    for: paneID,
                    splitPath: childPath
                ) else {
                    continue
                }

                let context = ParentSplitContext(
                    splitPath: splitPath,
                    axis: axis,
                    fractions: fractions,
                    focusedChildIndex: index
                )
                return [context] + childContexts
            }

            return nil
        }
    }

    func minimumSize(
        panelMinimumSize: NSSize = WorkspaceLayoutMetrics.minimumPaneSize,
        dividerThickness: CGFloat = WorkspaceLayoutMetrics.dividerThickness
    ) -> NSSize {
        switch self {
        case .panel:
            return panelMinimumSize
        case .split(let axis, let children, _):
            let minimumSizes = children.map {
                $0.minimumSize(
                    panelMinimumSize: panelMinimumSize,
                    dividerThickness: dividerThickness
                )
            }
            let dividerCount = max(0, children.count - 1)

            switch axis {
            case .horizontal:
                return NSSize(
                    width: minimumSizes.reduce(0) { $0 + $1.width } + dividerThickness
                        * CGFloat(dividerCount),
                    height: minimumSizes.map(\.height).max() ?? panelMinimumSize.height
                )
            case .vertical:
                return NSSize(
                    width: minimumSizes.map(\.width).max() ?? panelMinimumSize.width,
                    height: minimumSizes.reduce(0) { $0 + $1.height } + dividerThickness
                        * CGFloat(dividerCount)
                )
            }
        }
    }

    func insertingSplit(
        for targetPaneID: PaneID,
        axis: SplitAxis,
        newPaneID: PaneID,
        ratio: CGFloat = 0.5
    ) -> LayoutNode? {
        switch self {
        case .panel(let id):
            guard id == targetPaneID else {
                return nil
            }

            return .split(
                axis: axis,
                children: [.panel(id), .panel(newPaneID)],
                fractions: Self.normalizedFractions([1 - ratio, ratio], count: 2)
            )
        case .split(let currentAxis, let children, let fractions):
            for (index, child) in children.enumerated() {
                if let updatedChild = child.insertingSplit(
                    for: targetPaneID,
                    axis: axis,
                    newPaneID: newPaneID,
                    ratio: ratio
                ) {
                    var updatedChildren = children
                    updatedChildren[index] = updatedChild

                    return
                        LayoutNode
                        .split(axis: currentAxis, children: updatedChildren, fractions: fractions)
                        .normalized()
                }
            }

            return nil
        }
    }

    func replacingFractions(at path: [LayoutPathComponent], with newFractions: [CGFloat])
        -> LayoutNode?
    {
        switch self {
        case .split(let axis, let children, _) where path.isEmpty:
            guard children.count == newFractions.count else {
                return nil
            }

            return .split(
                axis: axis,
                children: children,
                fractions: Self.normalizedFractions(newFractions, count: children.count)
            )
        case .split(let axis, let children, let fractions):
            guard let component = path.first else {
                return nil
            }

            let remainingPath = Array(path.dropFirst())

            switch component {
            case .child(let index):
                guard children.indices.contains(index) else {
                    return nil
                }

                guard
                    let updatedChild = children[index].replacingFractions(
                        at: remainingPath, with: newFractions)
                else {
                    return nil
                }

                var updatedChildren = children
                updatedChildren[index] = updatedChild

                return .split(axis: axis, children: updatedChildren, fractions: fractions)
            }
        case .panel:
            return nil
        }
    }

    func equalizingSplitFractions() -> LayoutNode {
        switch self {
        case .panel:
            return self
        case .split(let axis, let children, _):
            return .split(
                axis: axis,
                children: children.map { $0.equalizingSplitFractions() },
                fractions: Self.normalizedFractions([], count: children.count)
            )
        }
    }

    func swappingPane(_ firstPaneID: PaneID, with secondPaneID: PaneID) -> LayoutNode? {
        guard firstPaneID != secondPaneID,
            path(to: firstPaneID) != nil,
            path(to: secondPaneID) != nil
        else {
            return nil
        }

        return replacingPaneIDs([
            firstPaneID: secondPaneID,
            secondPaneID: firstPaneID,
        ])
    }

    func closingPane(_ paneID: PaneID) -> ClosePaneResult? {
        guard let removalResult = removingPane(paneID) else {
            return nil
        }

        switch removalResult {
        case .removed:
            return ClosePaneResult(root: nil, promotedPaneID: nil)
        case .kept(let root, let promotedPaneID):
            return ClosePaneResult(root: root, promotedPaneID: promotedPaneID)
        }
    }

    func nextPaneID(after paneID: PaneID) -> PaneID? {
        let paneIDs = paneIDsInTraversalOrder
        guard let index = paneIDs.firstIndex(of: paneID), !paneIDs.isEmpty else {
            return paneIDs.first
        }

        return paneIDs[(index + 1) % paneIDs.count]
    }

    func previousPaneID(before paneID: PaneID) -> PaneID? {
        let paneIDs = paneIDsInTraversalOrder
        guard let index = paneIDs.firstIndex(of: paneID), !paneIDs.isEmpty else {
            return paneIDs.last
        }

        return paneIDs[(index - 1 + paneIDs.count) % paneIDs.count]
    }

    func clampedFractions(
        _ proposedFractions: [CGFloat],
        in availableSize: NSSize,
        panelMinimumSize: NSSize = WorkspaceLayoutMetrics.minimumPaneSize,
        dividerThickness: CGFloat = WorkspaceLayoutMetrics.dividerThickness
    ) -> [CGFloat] {
        guard case .split(let axis, let children, _) = self,
            children.count == proposedFractions.count
        else {
            return proposedFractions
        }

        let totalPrimaryLength = max(
            0,
            (axis == .horizontal ? availableSize.width : availableSize.height)
                - (dividerThickness * CGFloat(max(0, children.count - 1)))
        )

        guard totalPrimaryLength > 0 else {
            return Self.normalizedFractions(proposedFractions, count: proposedFractions.count)
        }

        let minimumFractions = children.map { child in
            let minimumSize = child.minimumSize(
                panelMinimumSize: panelMinimumSize,
                dividerThickness: dividerThickness
            )

            let minimumLength = axis == .horizontal ? minimumSize.width : minimumSize.height
            return minimumLength / totalPrimaryLength
        }

        return Self.clampFractions(
            proposedFractions,
            minimumFractions: minimumFractions
        )
    }

    private enum RemovalResult {
        case removed
        case kept(LayoutNode, promotedPaneID: PaneID?)
    }

    private func replacingPaneIDs(_ replacements: [PaneID: PaneID]) -> LayoutNode {
        switch self {
        case .panel(let id):
            return .panel(replacements[id] ?? id)
        case .split(let axis, let children, let fractions):
            return .split(
                axis: axis,
                children: children.map { $0.replacingPaneIDs(replacements) },
                fractions: fractions
            )
        }
    }

    private func removingPane(_ paneID: PaneID) -> RemovalResult? {
        switch self {
        case .panel(let id):
            return id == paneID ? .removed : nil
        case .split(let axis, let children, let fractions):
            for (index, child) in children.enumerated() {
                if let childRemovalResult = child.removingPane(paneID) {
                    switch childRemovalResult {
                    case .removed:
                        var remainingChildren = children
                        remainingChildren.remove(at: index)

                        if remainingChildren.isEmpty {
                            return .removed
                        }

                        let promotedPaneID = remainingChildren[
                            min(index, remainingChildren.count - 1)
                        ].firstPaneID

                        if remainingChildren.count == 1 {
                            return .kept(remainingChildren[0], promotedPaneID: promotedPaneID)
                        }

                        var remainingFractions = fractions
                        let removedFraction = remainingFractions.remove(at: index)

                        return .kept(
                            LayoutNode
                                .split(
                                    axis: axis,
                                    children: remainingChildren,
                                    fractions: Self.redistributingRemovedFraction(
                                        removedFraction,
                                        across: remainingFractions
                                    )
                                )
                                .normalized(),
                            promotedPaneID: promotedPaneID
                        )
                    case .kept(let updatedChild, let promotedPaneID):
                        var updatedChildren = children
                        updatedChildren[index] = updatedChild

                        return .kept(
                            LayoutNode
                                .split(axis: axis, children: updatedChildren, fractions: fractions)
                                .normalized(),
                            promotedPaneID: promotedPaneID
                        )
                    }
                }
            }

            return nil
        }
    }

    private func normalized() -> LayoutNode {
        switch self {
        case .panel:
            return self
        case .split(let axis, let children, let fractions):
            let normalizedFractions = Self.normalizedFractions(fractions, count: children.count)
            var flattenedChildren: [LayoutNode] = []
            var flattenedFractions: [CGFloat] = []

            for (child, fraction) in zip(children, normalizedFractions) {
                let normalizedChild = child.normalized()

                if case .split(let childAxis, let grandChildren, let grandFractions) =
                    normalizedChild,
                    childAxis == axis
                {
                    for (grandChild, grandFraction) in zip(grandChildren, grandFractions) {
                        flattenedChildren.append(grandChild)
                        flattenedFractions.append(max(0, fraction) * max(0, grandFraction))
                    }
                } else {
                    flattenedChildren.append(normalizedChild)
                    flattenedFractions.append(max(0, fraction))
                }
            }

            switch flattenedChildren.count {
            case 0:
                return self
            case 1:
                return flattenedChildren[0]
            default:
                return .split(
                    axis: axis,
                    children: flattenedChildren,
                    fractions: Self.normalizedFractions(
                        flattenedFractions, count: flattenedChildren.count)
                )
            }
        }
    }

    private static func redistributingRemovedFraction(
        _ removedFraction: CGFloat,
        across fractions: [CGFloat]
    ) -> [CGFloat] {
        guard !fractions.isEmpty else {
            return []
        }

        let normalizedBaseFractions = normalizedFractions(fractions, count: fractions.count)
        let remainder = max(0, removedFraction)
        let baseSum = normalizedBaseFractions.reduce(0, +)

        guard baseSum > 0 else {
            return normalizedFractions(
                Array(repeating: 1 / CGFloat(fractions.count), count: fractions.count),
                count: fractions.count
            )
        }

        return normalizedFractions(
            normalizedBaseFractions.map { fraction in
                fraction + (fraction / baseSum * remainder)
            },
            count: fractions.count
        )
    }

    private static func normalizedFractions(_ fractions: [CGFloat], count: Int) -> [CGFloat] {
        guard count > 0 else {
            return []
        }

        var boundedFractions = Array(fractions.prefix(count)).map { max(0, $0) }
        if boundedFractions.count < count {
            boundedFractions += Array(repeating: 0, count: count - boundedFractions.count)
        }

        let sum = boundedFractions.reduce(0, +)
        guard sum > 0 else {
            let equalFraction = 1 / CGFloat(count)
            return Array(repeating: equalFraction, count: count)
        }

        return boundedFractions.map { $0 / sum }
    }

    private static func clampFractions(
        _ proposedFractions: [CGFloat],
        minimumFractions: [CGFloat]
    ) -> [CGFloat] {
        let count = minimumFractions.count
        guard count > 0 else {
            return []
        }

        let normalizedProposedFractions = normalizedFractions(proposedFractions, count: count)
        let boundedMinimumFractions = minimumFractions.map { max(0, $0) }
        let minimumFractionSum = boundedMinimumFractions.reduce(0, +)

        if minimumFractionSum >= 1 {
            return normalizedFractions(boundedMinimumFractions, count: count)
        }

        let tolerance: CGFloat = 0.000_001
        var result = Array(repeating: CGFloat.zero, count: count)
        var fixedIndices = Set<Int>()

        while fixedIndices.count < count {
            let remainingIndices = (0..<count).filter { !fixedIndices.contains($0) }
            let remainingBudget =
                1
                - fixedIndices.reduce(CGFloat.zero) { partialResult, index in
                    partialResult + result[index]
                }

            guard !remainingIndices.isEmpty else {
                break
            }

            let remainingProposedSum = remainingIndices.reduce(CGFloat.zero) {
                partialResult, index in
                partialResult + normalizedProposedFractions[index]
            }

            for index in remainingIndices {
                if remainingProposedSum > tolerance {
                    result[index] =
                        normalizedProposedFractions[index] / remainingProposedSum * remainingBudget
                } else {
                    result[index] = remainingBudget / CGFloat(remainingIndices.count)
                }
            }

            let violatingIndices = remainingIndices.filter {
                result[$0] + tolerance < boundedMinimumFractions[$0]
            }

            if violatingIndices.isEmpty {
                break
            }

            for index in violatingIndices {
                result[index] = boundedMinimumFractions[index]
                fixedIndices.insert(index)
            }
        }

        let total = result.reduce(0, +)
        let delta = 1 - total
        if abs(delta) > tolerance, let index = result.indices.max(by: { result[$0] < result[$1] }) {
            result[index] += delta
        }

        return result
    }
}
