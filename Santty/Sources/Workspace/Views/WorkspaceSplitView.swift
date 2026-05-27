import AppKit
import os

private let paneResizeLog = Logger(subsystem: "com.zola.santty", category: "PaneResize")

private func formatFractions(_ fractions: [CGFloat]) -> String {
    "[" + fractions.map { String(format: "%.4f", Double($0)) }.joined(separator: ", ") + "]"
}

private final class FlipAnimationProbe: NSObject, CAAnimationDelegate {
    let label: String
    weak var layer: CALayer?

    init(label: String, layer: CALayer) {
        self.label = label
        self.layer = layer
    }

    func animationDidStart(_ anim: CAAnimation) {
        paneResizeLog.debug("flip \(self.label, privacy: .public) didStart")
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        let presentationTransform = self.layer?.presentation()?.transform
        let modelTransform = self.layer?.transform
        let pres = presentationTransform.map {
            "m11=\($0.m11) m22=\($0.m22) m41=\($0.m41) m42=\($0.m42)"
        } ?? "nil"
        let model = modelTransform.map {
            "m11=\($0.m11) m22=\($0.m22) m41=\($0.m41) m42=\($0.m42)"
        } ?? "nil"
        paneResizeLog.debug(
            "flip \(self.label, privacy: .public) didStop finished=\(flag, privacy: .public) presentation=\(pres, privacy: .public) model=\(model, privacy: .public)"
        )
    }
}

enum WorkspaceSplitFractionChangeSource {
    case layoutClamp
    case userDrag
}

@MainActor
private final class WorkspaceSplitDividerView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // Suppress implicit position/bounds animations so they cannot fight
        // our explicit FLIP transform animation.
        layer?.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
        ]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }
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
    private let dividerViews: [WorkspaceSplitDividerView]

    private var fractions: [CGFloat]
    private var shouldPersistLayoutClamp = true
    private var childPrimaryConstraints: [NSLayoutConstraint] = []
    private var lastPrimaryConstraintContainerSize = NSSize.zero
    private var animationGeneration = 0
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
        self.dividerViews =
            childViews.count > 1
            ? (0..<(childViews.count - 1)).map { _ in WorkspaceSplitDividerView() }
            : []

        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // Suppress implicit position/bounds animations on the container layer
        // so layout-induced geometry changes can't fight an in-flight FLIP.
        layer?.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
        ]

        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        for childView in childViews {
            childView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(childView)
        }
        for dividerView in dividerViews {
            dividerView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dividerView)
        }

        installStructuralConstraints()
        rebuildPrimaryConstraints()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        if oldSize != newSize {
            paneResizeLog.debug(
                "setFrameSize WorkspaceSplitView#\(ObjectIdentifier(self).hashValue, privacy: .public) old=\(NSStringFromSize(oldSize), privacy: .public) new=\(NSStringFromSize(newSize), privacy: .public)"
            )
        }
        super.setFrameSize(newSize)
        updatePrimaryConstraintConstantsIfNeeded()
        if oldSize != newSize {
            needsLayout = true
        }
    }

    override func layout() {
        let clampedFractions = clampedFractions(self.fractions)
        if clampedFractions != self.fractions {
            paneResizeLog.debug(
                "split(\(ObjectIdentifier(self).hashValue, privacy: .public)) layout() clamp self.fractions=\(formatFractions(self.fractions), privacy: .public) -> \(formatFractions(clampedFractions), privacy: .public) persist=\(self.shouldPersistLayoutClamp, privacy: .public) bounds=\(NSStringFromSize(self.bounds.size), privacy: .public)"
            )
            self.fractions = clampedFractions
            updatePrimaryConstraintConstants()

            if shouldPersistLayoutClamp {
                paneResizeLog.debug(
                    "split(\(ObjectIdentifier(self).hashValue, privacy: .public)) layout() -> onFractionsChange(.layoutClamp) \(formatFractions(clampedFractions), privacy: .public)"
                )
                onFractionsChange(clampedFractions, .layoutClamp)
            }
        }

        updatePrimaryConstraintConstantsIfNeeded()
        super.layout()
        updateCachedFrames()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        layoutSubtreeIfNeeded()
        updateCachedFrames()

        let cursor: NSCursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
        for dividerRect in cachedDividerRects {
            addCursorRect(dividerRect, cursor: cursor)
        }
    }

    override func mouseDown(with event: NSEvent) {
        layoutSubtreeIfNeeded()
        updateCachedFrames()

        let location = convert(event.locationInWindow, from: nil)
        guard let dividerIndex = cachedDividerRects.firstIndex(where: { $0.contains(location) })
        else {
            super.mouseDown(with: event)
            return
        }

        animationGeneration += 1

        while let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            shouldPersistLayoutClamp = true
            let nextLocation = convert(nextEvent.locationInWindow, from: nil)
            fractions = fractions(forDraggingDividerAt: dividerIndex, location: nextLocation)
            updatePrimaryConstraintConstants()
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
        paneResizeLog.debug(
            "split(\(ObjectIdentifier(self).hashValue, privacy: .public)) setFractions enter requested=\(formatFractions(newFractions), privacy: .public) current=\(formatFractions(self.fractions), privacy: .public) animated=\(animated, privacy: .public) persist=\(persistLayoutClamp, privacy: .public) bounds=\(NSStringFromSize(self.bounds.size), privacy: .public)"
        )
        shouldPersistLayoutClamp = persistLayoutClamp

        let clampedFractions = clampedFractions(newFractions)
        guard clampedFractions != fractions else {
            paneResizeLog.debug(
                "split(\(ObjectIdentifier(self).hashValue, privacy: .public)) setFractions early-return clamped==current \(formatFractions(clampedFractions), privacy: .public)"
            )
            return
        }
        paneResizeLog.debug(
            "split(\(ObjectIdentifier(self).hashValue, privacy: .public)) setFractions clamped=\(formatFractions(clampedFractions), privacy: .public)"
        )

        if animated {
            let generation = animationGeneration + 1
            animationGeneration = generation

            // Settle the current layout and snapshot pre-animation frames so we
            // can FLIP each child/divider after we apply the new layout.
            layoutSubtreeIfNeeded()
            updateCachedFrames()
            let oldChildFrames = childFrames
            let oldDividerFrames = cachedDividerRects

            // Apply the new layout instantly. Doing this synchronously means
            // each pane's underlying Metal surface re-renders exactly once at
            // its final size, instead of snapping mid-animation while the host
            // wrapper's frame is still in motion.
            fractions = clampedFractions
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                updatePrimaryConstraintConstants()
                needsLayout = true
                layoutSubtreeIfNeeded()
            }
            updateCachedFrames()
            let newChildFrames = childFrames
            let newDividerFrames = cachedDividerRects
            CATransaction.commit()

            // Visually map each layer from its new frame back to its old frame
            // and animate the transform to identity. The host wrapper's mask
            // and corner radius live on the same layer as the Metal sublayer,
            // so they scale together and the right pane no longer appears to
            // teleport to its final position at frame 0.
            let duration = WorkspaceFocusZoomConfiguration.animationDuration
            let timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(timingFunction)
            CATransaction.setCompletionBlock { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    guard generation == self.animationGeneration else {
                        paneResizeLog.debug(
                            "split(\(ObjectIdentifier(self).hashValue, privacy: .public)) animation completion superseded generation=\(generation, privacy: .public) current=\(self.animationGeneration, privacy: .public)"
                        )
                        return
                    }

                    paneResizeLog.debug(
                        "split(\(ObjectIdentifier(self).hashValue, privacy: .public)) animation completion generation=\(generation, privacy: .public) fractions=\(formatFractions(self.fractions), privacy: .public)"
                    )
                    self.layoutSubtreeIfNeeded()
                    self.updateCachedFrames()
                }
            }

            for (index, childView) in childViews.enumerated() {
                guard
                    index < oldChildFrames.count,
                    index < newChildFrames.count
                else {
                    continue
                }
                animateFlip(
                    view: childView,
                    oldFrame: oldChildFrames[index],
                    newFrame: newChildFrames[index],
                    duration: duration,
                    timingFunction: timingFunction
                )
            }

            for (index, dividerView) in dividerViews.enumerated() {
                guard
                    index < oldDividerFrames.count,
                    index < newDividerFrames.count
                else {
                    continue
                }
                animateFlip(
                    view: dividerView,
                    oldFrame: oldDividerFrames[index],
                    newFrame: newDividerFrames[index],
                    duration: duration,
                    timingFunction: timingFunction
                )
            }

            CATransaction.commit()
        } else {
            animationGeneration += 1
            fractions = clampedFractions
            updatePrimaryConstraintConstants()
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
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
            paneResizeLog.debug(
                "animateFlip skip view=\(ObjectIdentifier(view).hashValue, privacy: .public) type=\(String(describing: Swift.type(of: view)), privacy: .public) reason=no-layer-or-zero-size new=\(NSStringFromRect(newFrame), privacy: .public)"
            )
            return
        }

        if oldFrame == newFrame {
            paneResizeLog.debug(
                "animateFlip skip view=\(ObjectIdentifier(view).hashValue, privacy: .public) type=\(String(describing: Swift.type(of: view)), privacy: .public) reason=same-frame frame=\(NSStringFromRect(newFrame), privacy: .public)"
            )
            return
        }

        let scaleX = oldFrame.width / newFrame.width
        let scaleY = oldFrame.height / newFrame.height

        // AppKit layer-backed NSViews don't use a fixed anchor point — for
        // non-flipped views it's typically (0, 0), not (0.5, 0.5). The visual
        // origin of a transformed layer is:
        //   visual.origin = newFrame.origin + anchor * newSize * (1 - scale)
        //                 + (tx, ty)
        // Solve for (tx, ty) so visual.origin == oldFrame.origin.
        let anchor = layer.anchorPoint
        let translateX = (oldFrame.minX - newFrame.minX)
            + anchor.x * (oldFrame.width - newFrame.width)
        let translateY = (oldFrame.minY - newFrame.minY)
            + anchor.y * (oldFrame.height - newFrame.height)

        paneResizeLog.debug(
            "animateFlip view=\(ObjectIdentifier(view).hashValue, privacy: .public) type=\(String(describing: Swift.type(of: view)), privacy: .public) old=\(NSStringFromRect(oldFrame), privacy: .public) new=\(NSStringFromRect(newFrame), privacy: .public) anchor=(\(Double(anchor.x), privacy: .public),\(Double(anchor.y), privacy: .public)) scale=(\(Double(scaleX), privacy: .public),\(Double(scaleY), privacy: .public)) translate=(\(Double(translateX), privacy: .public),\(Double(translateY), privacy: .public)) layerFlipped=\(layer.isGeometryFlipped, privacy: .public) viewFlipped=\(view.isFlipped, privacy: .public)"
        )

        // Build the transform that visually maps the layer (now positioned at
        // newFrame) back to oldFrame, applied around the layer's anchor point.
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
        let probe = FlipAnimationProbe(
            label: "\(String(describing: Swift.type(of: view)))#\(ObjectIdentifier(view).hashValue)",
            layer: layer
        )
        animation.delegate = probe
        layer.add(animation, forKey: "santty.paneResize.flip")
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

    func debugApplyDragForDividerAt(_ dividerIndex: Int, location: NSPoint) {
        fractions = fractions(forDraggingDividerAt: dividerIndex, location: location)
        updatePrimaryConstraintConstants()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func debugDividerFrame(at dividerIndex: Int) -> NSRect? {
        layoutSubtreeIfNeeded()
        updateCachedFrames()
        guard cachedDividerRects.indices.contains(dividerIndex) else {
            return nil
        }

        return cachedDividerRects[dividerIndex]
    }

    func debugChildFrame(at childIndex: Int) -> NSRect? {
        layoutSubtreeIfNeeded()
        updateCachedFrames()
        guard childFrames.indices.contains(childIndex) else {
            return nil
        }

        return childFrames[childIndex]
    }

    private func installStructuralConstraints() {
        guard !childViews.isEmpty else {
            return
        }

        switch axis {
        case .horizontal:
            installHorizontalConstraints()
        case .vertical:
            installVerticalConstraints()
        }
    }

    private func installHorizontalConstraints() {
        var constraints: [NSLayoutConstraint] = []
        var leadingAnchor: NSLayoutXAxisAnchor = self.leadingAnchor

        for index in childViews.indices {
            let childView = childViews[index]
            constraints += [
                childView.leadingAnchor.constraint(equalTo: leadingAnchor),
                childView.topAnchor.constraint(equalTo: topAnchor),
                childView.heightAnchor.constraint(equalTo: heightAnchor),
            ]

            if dividerViews.indices.contains(index) {
                let dividerView = dividerViews[index]
                let dividerLeadingConstraint = dividerView.leadingAnchor.constraint(
                    equalTo: childView.trailingAnchor
                )
                constraints += [
                    dividerLeadingConstraint,
                    dividerView.widthAnchor.constraint(equalToConstant: dividerThickness),
                    dividerView.topAnchor.constraint(equalTo: topAnchor),
                    dividerView.heightAnchor.constraint(equalTo: heightAnchor),
                ]
                leadingAnchor = dividerView.trailingAnchor
            } else {
                constraints.append(childView.trailingAnchor.constraint(equalTo: trailingAnchor))
            }
        }

        NSLayoutConstraint.activate(constraints)
    }

    private func installVerticalConstraints() {
        var constraints: [NSLayoutConstraint] = []
        var topAnchor: NSLayoutYAxisAnchor = self.topAnchor

        for index in childViews.indices {
            let childView = childViews[index]
            constraints += [
                childView.topAnchor.constraint(equalTo: topAnchor),
                childView.leadingAnchor.constraint(equalTo: leadingAnchor),
                childView.widthAnchor.constraint(equalTo: widthAnchor),
            ]

            if dividerViews.indices.contains(index) {
                let dividerView = dividerViews[index]
                let dividerTopConstraint = dividerView.topAnchor.constraint(
                    equalTo: childView.bottomAnchor
                )
                constraints += [
                    dividerTopConstraint,
                    dividerView.heightAnchor.constraint(equalToConstant: dividerThickness),
                    dividerView.leadingAnchor.constraint(equalTo: leadingAnchor),
                    dividerView.widthAnchor.constraint(equalTo: widthAnchor),
                ]
                topAnchor = dividerView.bottomAnchor
            } else {
                constraints.append(childView.bottomAnchor.constraint(equalTo: bottomAnchor))
            }
        }

        NSLayoutConstraint.activate(constraints)
    }

    private func rebuildPrimaryConstraints() {
        NSLayoutConstraint.deactivate(childPrimaryConstraints)
        childPrimaryConstraints = []

        guard !childViews.isEmpty else {
            return
        }

        childPrimaryConstraints = childViews.dropLast().map { childView in
            switch axis {
            case .horizontal:
                return childView.widthAnchor.constraint(equalToConstant: 0)
            case .vertical:
                return childView.heightAnchor.constraint(equalToConstant: 0)
            }
        }

        NSLayoutConstraint.activate(childPrimaryConstraints)
        updatePrimaryConstraintConstants()
    }

    private func updatePrimaryConstraintConstantsIfNeeded() {
        guard bounds.size != lastPrimaryConstraintContainerSize else {
            return
        }

        updatePrimaryConstraintConstants()
    }

    private func updatePrimaryConstraintConstants() {
        guard !childPrimaryConstraints.isEmpty else {
            return
        }

        lastPrimaryConstraintContainerSize = bounds.size
        let primaryLength = primaryLength(of: bounds.size)
        let usablePrimaryLength = max(
            0,
            primaryLength - dividerThickness * CGFloat(dividerViews.count)
        )
        let normalizedFractions = Self.normalizedFractions(fractions, count: childViews.count)

        for (constraint, fraction) in zip(childPrimaryConstraints, normalizedFractions.dropLast()) {
            constraint.constant = usablePrimaryLength * fraction
        }
    }

    private func updateCachedFrames() {
        let framesAndDividers = computeFramesAndDividers(for: fractions)
        childFrames = framesAndDividers.frames
        cachedDividerRects = framesAndDividers.dividers
    }

    private func computeFramesAndDividers(for fractions: [CGFloat]) -> (
        frames: [NSRect], dividers: [NSRect]
    ) {
        guard !childViews.isEmpty else {
            return ([], [])
        }

        let usablePrimaryLength = max(
            0,
            primaryLength(of: bounds.size) - dividerThickness * CGFloat(dividerViews.count)
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
                        - fractions.prefix(index).reduce(0) {
                            $0 + usablePrimaryLength * $1
                        }
                )
                : usablePrimaryLength * fractions[index]
            frames.append(
                frameForChild(
                    primaryOrigin: cursor,
                    primaryLength: childPrimaryLength,
                    secondaryLength: secondaryLength
                )
            )
            cursor += childPrimaryLength

            if !isLastChild {
                dividers.append(
                    dividerRect(atPrimaryOrigin: cursor, secondaryLength: secondaryLength)
                )
                cursor += dividerThickness
            }
        }

        return (frames, dividers)
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
        primaryOrigin: CGFloat,
        primaryLength: CGFloat,
        secondaryLength: CGFloat
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
