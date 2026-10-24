import AppKit

@MainActor
final class WindowContentView: NSView {
    let mainView = WorkspaceRootView()
    let sidebarView = WorkspaceTilingView(dividerThickness: AppAppearanceSettings.workspaceDividerThickness)
    private let outerLayout = WorkspaceTilingView()
    private let mainID = UUID()
    private let sidebarID = UUID()
    private var side: SidebarSide = .left
    private var preferredWidth: CGFloat = 280
    private var sidebarVisible = false
    private var mainMinimumWidth: CGFloat = 240
    private var sidebarMinimumWidth: CGFloat = 240
    var onSidebarLayout: (() -> Void)?
    var onWidthChange: ((CGFloat) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(outerLayout)
        outerLayout.onFractionsChange = { [weak self] _, fractions, source in
            guard let self, source == .userDrag, fractions.count == 2 else { return }
            let index = side == .left ? 0 : 1
            let proposed = fractions[index] * max(0, outerLayout.bounds.width - AppAppearanceSettings.workspaceDividerThickness)
            preferredWidth = clampedSidebarWidth(proposed)
            if preferredWidth != proposed { installLayout() }
            onSidebarLayout?()
            onWidthChange?(preferredWidth)
        }
        sidebarView.setAccessibilityLabel("Sidebar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func updateSidebar(_ state: WindowSidebarState) {
        side = state.side
        preferredWidth = state.preferredWidth
        sidebarVisible = state.isVisible
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        outerLayout.frame = bounds
        outerLayout.updateDividerThickness(AppAppearanceSettings.workspaceDividerThickness)
        guard !outerLayout.isDraggingDivider else { return }
        guard sidebarVisible else {
            outerLayout.setLayoutNode(.panel(mainID), paneViews: [mainID: mainView])
            return
        }
        installLayout()
        onSidebarLayout?()
    }

    func updateMinimumWidths(main: CGFloat, sidebar: CGFloat) {
        guard mainMinimumWidth != main || sidebarMinimumWidth != sidebar else { return }
        mainMinimumWidth = main
        sidebarMinimumWidth = sidebar
        needsLayout = true
    }

    private func clampedSidebarWidth(_ proposed: CGFloat) -> CGFloat {
        let available = max(0, bounds.width - AppAppearanceSettings.workspaceDividerThickness)
        return min(available, max(sidebarMinimumWidth, min(proposed, available - mainMinimumWidth)))
    }

    private func installLayout() {
        let available = max(1, bounds.width - AppAppearanceSettings.workspaceDividerThickness)
        let fraction = min(1, max(0, clampedSidebarWidth(preferredWidth) / available))
        let children: [LayoutNode] = side == .left ? [.panel(sidebarID), .panel(mainID)] : [.panel(mainID), .panel(sidebarID)]
        let fractions = side == .left ? [fraction, 1 - fraction] : [1 - fraction, fraction]
        outerLayout.setLayoutNode(.split(axis: .horizontal, children: children, fractions: fractions),
            paneViews: [sidebarID: sidebarView, mainID: mainView])
    }
}
