import AppKit

enum WorkspaceSplitFractionChangeSource {
    case layoutClamp
    case userDrag
}

@MainActor
final class WorkspaceSplitView: NSView {
    let axis: SplitAxis
    var path: [LayoutPathComponent] = []
    var currentFractions: [CGFloat] { fractions }

    private let childViews: [NSView]
    private let childMinimumSizes: [NSSize]
    private let onFractionsChange: ([CGFloat], WorkspaceSplitFractionChangeSource) -> Void
    private let dividerThickness: CGFloat

    private var fractions: [CGFloat]
    private var shouldPersistLayoutClamp = true
    private var cachedDividerRects: [NSRect] = []
    private var childFrames: [NSRect] = []

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    init(
        axis: SplitAxis,
        fractions: [CGFloat],
        childViews: [NSView],
        childMinimumSizes: [NSSize],
        dividerThickness: CGFloat = WorkspaceLayoutMetrics.dividerThickness,
        onFractionsChange: @escaping ([CGFloat], WorkspaceSplitFractionChangeSource) -> Void
    ) {
        self.axis = axis
        self.fractions = Self.normalizedFractions(fractions, count: childViews.count)
        self.childViews = childViews
        self.childMinimumSizes = childMinimumSizes
        self.dividerThickness = dividerThickness
        self.onFractionsChange = onFractionsChange

        super.init(frame: .zero)

        for childView in childViews {
            addSubview(childView)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()

        let clampedFractions = clampedFractions(self.fractions)
        if clampedFractions != self.fractions {
            self.fractions = clampedFractions

            if shouldPersistLayoutClamp {
                onFractionsChange(clampedFractions, .layoutClamp)
            }
        }

        let framesAndDividers = computeFramesAndDividers(for: self.fractions)
        childFrames = framesAndDividers.frames
        cachedDividerRects = framesAndDividers.dividers

        for (childView, frame) in zip(childViews, childFrames) {
            childView.frame = frame
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()

        let cursor: NSCursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
        for dividerRect in cachedDividerRects {
            addCursorRect(dividerRect, cursor: cursor)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let dividerIndex = cachedDividerRects.firstIndex(where: { $0.contains(location) })
        else {
            super.mouseDown(with: event)
            return
        }

        while let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            shouldPersistLayoutClamp = true
            let nextLocation = convert(nextEvent.locationInWindow, from: nil)
            fractions = fractions(forDraggingDividerAt: dividerIndex, location: nextLocation)
            onFractionsChange(fractions, .userDrag)
            needsLayout = true
            layoutSubtreeIfNeeded()

            if nextEvent.type == .leftMouseUp {
                return
            }
        }
    }

    func setFractions(_ newFractions: [CGFloat], animated: Bool) {
        setFractions(newFractions, animated: animated, persistLayoutClamp: false)
    }

    func setFractions(_ newFractions: [CGFloat], animated: Bool, persistLayoutClamp: Bool) {
        shouldPersistLayoutClamp = persistLayoutClamp

        let clampedFractions = clampedFractions(newFractions)
        guard clampedFractions != fractions else {
            return
        }

        layoutSubtreeIfNeeded()
        let framesAndDividers = computeFramesAndDividers(for: clampedFractions)
        fractions = clampedFractions
        childFrames = framesAndDividers.frames
        cachedDividerRects = framesAndDividers.dividers

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = WorkspaceFocusZoomConfiguration.animationDuration
                for (childView, targetFrame) in zip(childViews, childFrames) {
                    childView.animator().frame = targetFrame
                }
            } completionHandler: { [weak self] in
                guard let self else {
                    return
                }

                self.needsLayout = true
                self.layoutSubtreeIfNeeded()
            }
        } else {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    private func computeFramesAndDividers(for fractions: [CGFloat]) -> (
        frames: [NSRect], dividers: [NSRect]
    ) {
        guard !childViews.isEmpty else {
            return ([], [])
        }

        let usablePrimaryLength = max(
            0,
            primaryLength(of: bounds.size) - dividerThickness
                * CGFloat(max(0, childViews.count - 1))
        )
        let secondaryLength = secondaryLength(of: bounds.size)
        var frames: [NSRect] = []
        var dividers: [NSRect] = []

        var cursor: CGFloat = 0
        for index in childViews.indices {
            let isLastChild = index == childViews.count - 1
            let childPrimaryLength =
                isLastChild
                ? max(
                    0,
                    usablePrimaryLength
                        - fractions.prefix(index).reduce(0) { $0 + usablePrimaryLength * $1 })
                : usablePrimaryLength * fractions[index]
            let frame = frameForChild(
                primaryOrigin: cursor, primaryLength: childPrimaryLength,
                secondaryLength: secondaryLength)
            frames.append(frame)
            cursor += childPrimaryLength

            if !isLastChild {
                dividers.append(
                    dividerRect(atPrimaryOrigin: cursor, secondaryLength: secondaryLength))
                cursor += dividerThickness
            }
        }

        return (frames, dividers)
    }

    private func fractions(forDraggingDividerAt dividerIndex: Int, location: NSPoint) -> [CGFloat] {
        let normalizedCurrentFractions = Self.normalizedFractions(
            fractions, count: childViews.count)
        let usablePrimaryLength = max(
            0,
            primaryLength(of: bounds.size) - dividerThickness
                * CGFloat(max(0, childViews.count - 1))
        )

        guard usablePrimaryLength > 0 else {
            return normalizedCurrentFractions
        }

        let leadingFrame = childFrames[dividerIndex]
        let trailingFrame = childFrames[dividerIndex + 1]
        let combinedPrimaryLength =
            primaryLength(of: leadingFrame.size) + primaryLength(of: trailingFrame.size)
        let minimumLeadingLength = minimumPrimaryLength(for: childMinimumSizes[dividerIndex])
        let minimumTrailingLength = minimumPrimaryLength(for: childMinimumSizes[dividerIndex + 1])

        let proposedLeadingLength: CGFloat
        switch axis {
        case .horizontal:
            let localOrigin = location.x - leadingFrame.minX - dividerThickness / 2
            proposedLeadingLength = localOrigin
        case .vertical:
            proposedLeadingLength = leadingFrame.maxY - location.y - dividerThickness / 2
        }

        let clampedLeadingLength = min(
            max(proposedLeadingLength, minimumLeadingLength),
            combinedPrimaryLength - minimumTrailingLength
        )
        let clampedTrailingLength = combinedPrimaryLength - clampedLeadingLength

        var updatedFractions = normalizedCurrentFractions
        updatedFractions[dividerIndex] = clampedLeadingLength / usablePrimaryLength
        updatedFractions[dividerIndex + 1] = clampedTrailingLength / usablePrimaryLength
        return Self.normalizedFractions(updatedFractions, count: updatedFractions.count)
    }

    func debugFractionsForDraggingDividerAt(_ dividerIndex: Int, location: NSPoint) -> [CGFloat] {
        fractions(forDraggingDividerAt: dividerIndex, location: location)
    }

    private func clampedFractions(_ proposedFractions: [CGFloat]) -> [CGFloat] {
        let usablePrimaryLength = max(
            0,
            primaryLength(of: bounds.size) - dividerThickness
                * CGFloat(max(0, childViews.count - 1))
        )

        guard usablePrimaryLength > 0 else {
            return Self.normalizedFractions(proposedFractions, count: childViews.count)
        }

        let minimumFractions = childMinimumSizes.map {
            minimumPrimaryLength(for: $0) / usablePrimaryLength
        }
        return Self.clampFractions(
            Self.normalizedFractions(proposedFractions, count: childViews.count),
            minimumFractions: minimumFractions
        )
    }

    private func primaryLength(of size: NSSize) -> CGFloat {
        axis == .horizontal ? size.width : size.height
    }

    private func secondaryLength(of size: NSSize) -> CGFloat {
        axis == .horizontal ? size.height : size.width
    }

    private func minimumPrimaryLength(for size: NSSize) -> CGFloat {
        axis == .horizontal ? size.width : size.height
    }

    private func frameForChild(
        primaryOrigin: CGFloat, primaryLength: CGFloat, secondaryLength: CGFloat
    ) -> NSRect {
        switch axis {
        case .horizontal:
            return NSRect(x: primaryOrigin, y: 0, width: primaryLength, height: secondaryLength)
        case .vertical:
            return NSRect(
                x: 0,
                y: bounds.height - primaryOrigin - primaryLength,
                width: secondaryLength,
                height: primaryLength
            )
        }
    }

    private func dividerRect(atPrimaryOrigin primaryOrigin: CGFloat, secondaryLength: CGFloat)
        -> NSRect
    {
        switch axis {
        case .horizontal:
            return NSRect(x: primaryOrigin, y: 0, width: dividerThickness, height: secondaryLength)
        case .vertical:
            return NSRect(
                x: 0,
                y: bounds.height - primaryOrigin - dividerThickness,
                width: secondaryLength,
                height: dividerThickness
            )
        }
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
            let remainingBudget = 1 - fixedIndices.reduce(CGFloat.zero) { $0 + result[$1] }

            guard !remainingIndices.isEmpty else {
                break
            }

            let remainingProposedSum = remainingIndices.reduce(CGFloat.zero) {
                $0 + proposedFractions[$1]
            }

            for index in remainingIndices {
                if remainingProposedSum > tolerance {
                    result[index] =
                        proposedFractions[index] / remainingProposedSum * remainingBudget
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

        return normalizedFractions(result, count: count)
    }
}
