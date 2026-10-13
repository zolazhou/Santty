import AppKit

@MainActor
struct ActiveFloatingPaneState: Equatable {
    let paneID: PaneID
    var size: NSSize?
}

@MainActor
final class WorkspaceTabState {
    let id: UUID
    var layoutNode: LayoutNode?
    var paneControllers: [PaneID: any PaneControlling]
    var paneAutoResizeConfigurations: [PaneID: PaneAutoResizeConfiguration]
    var focusedPaneID: PaneID?
    var customTitle: String?
    var herdrTabBinding: HerdrPaneBinding?
    var herdrBackendTitle: String?
    var herdrZoomed = false
    var herdrBackendLayout: LayoutNode?
    var herdrLocalLayout: LayoutNode?
    var herdrLocalFraction: CGFloat = 0.7
    var herdrFocusedPaneID: PaneID?
    struct SplitEdit {
        let id = UUID()
        let fractions: [CGFloat]
        let paneIDs: [PaneID]
        var acknowledged = false
    }
    var herdrSplitEdits: [[LayoutPathComponent]: SplitEdit] = [:]
    private var recentlyFocusedPaneIDs: [PaneID]
    var activeAutoZoomState: ActiveAutoZoomState?
    var activeFloatingPaneState: ActiveFloatingPaneState?
    var detachedPaneIDs: [PaneID] = []
    var activeDetachedPaneID: PaneID?
    var floatingPaneSizes: [PaneID: NSSize] = [:]

    init(
        id: UUID = UUID(),
        layoutNode: LayoutNode?,
        paneControllers: [PaneID: any PaneControlling],
        paneAutoResizeConfigurations: [PaneID: PaneAutoResizeConfiguration],
        focusedPaneID: PaneID?,
        customTitle: String? = nil,
        activeAutoZoomState: ActiveAutoZoomState? = nil,
        activeFloatingPaneState: ActiveFloatingPaneState? = nil
    ) {
        self.id = id
        self.layoutNode = layoutNode
        self.paneControllers = paneControllers
        self.paneAutoResizeConfigurations = paneAutoResizeConfigurations
        self.focusedPaneID = focusedPaneID
        self.customTitle = customTitle
        recentlyFocusedPaneIDs = focusedPaneID.map { [$0] } ?? []
        self.activeAutoZoomState = activeAutoZoomState
        self.activeFloatingPaneState = activeFloatingPaneState
    }

    func makeProjectionCandidate() -> WorkspaceTabState {
        let candidate = WorkspaceTabState(id: id, layoutNode: nil, paneControllers: [:],
            paneAutoResizeConfigurations: [:], focusedPaneID: nil)
        candidate.applyProjectionCandidate(self)
        return candidate
    }

    // Preserve the installed object for outstanding presentation callbacks.
    func applyProjectionCandidate(_ candidate: WorkspaceTabState) {
        precondition(id == candidate.id)
        layoutNode = candidate.layoutNode
        paneControllers = candidate.paneControllers
        paneAutoResizeConfigurations = candidate.paneAutoResizeConfigurations
        focusedPaneID = candidate.focusedPaneID
        customTitle = candidate.customTitle
        herdrTabBinding = candidate.herdrTabBinding
        herdrBackendTitle = candidate.herdrBackendTitle
        herdrZoomed = candidate.herdrZoomed
        herdrBackendLayout = candidate.herdrBackendLayout
        herdrLocalLayout = candidate.herdrLocalLayout
        herdrLocalFraction = candidate.herdrLocalFraction
        herdrFocusedPaneID = candidate.herdrFocusedPaneID
        herdrSplitEdits = candidate.herdrSplitEdits
        recentlyFocusedPaneIDs = candidate.recentlyFocusedPaneIDs
        activeAutoZoomState = candidate.activeAutoZoomState
        activeFloatingPaneState = candidate.activeFloatingPaneState
        detachedPaneIDs = candidate.detachedPaneIDs
        activeDetachedPaneID = candidate.activeDetachedPaneID
        floatingPaneSizes = candidate.floatingPaneSizes
    }

    var focusedPaneController: (any PaneControlling)? {
        guard let focusedPaneID else {
            return nil
        }

        return paneControllers[focusedPaneID]
    }

    func terminalPaneController(for paneID: PaneID) -> TerminalPaneController? {
        paneControllers[paneID] as? TerminalPaneController
    }

    var displayTitle: String {
        if let customTitle {
            return customTitle
        }

        if let herdrBackendTitle { return herdrBackendTitle }
        if let focusedTitle = focusedPaneController?.displayTitle {
            return focusedTitle
        }

        if let firstDetachedPaneID = detachedPaneIDs.first,
            let detachedPaneController = paneControllers[firstDetachedPaneID]
        {
            return detachedPaneController.displayTitle
        }

        return "Shell"
    }

    func containsPane(withID paneID: PaneID) -> Bool {
        paneControllers[paneID] != nil
    }

    func focusRecency(for paneID: PaneID) -> Int? {
        recentlyFocusedPaneIDs.firstIndex(of: paneID)
    }

    func remapPresentationPaneIDs(_ replacements: [PaneID: PaneID]) {
        guard !replacements.isEmpty else { return }
        func mapped(_ id: PaneID) -> PaneID { replacements[id] ?? id }
        focusedPaneID = focusedPaneID.map(mapped)
        herdrFocusedPaneID = herdrFocusedPaneID.map(mapped)
        recentlyFocusedPaneIDs = recentlyFocusedPaneIDs.map(mapped)
        detachedPaneIDs = detachedPaneIDs.map(mapped)
        activeDetachedPaneID = activeDetachedPaneID.map(mapped)
        activeFloatingPaneState = activeFloatingPaneState.map { .init(paneID: mapped($0.paneID), size: $0.size) }
        paneAutoResizeConfigurations = Dictionary(uniqueKeysWithValues: paneAutoResizeConfigurations.map { (mapped($0.key), $0.value) })
        floatingPaneSizes = Dictionary(uniqueKeysWithValues: floatingPaneSizes.map { (mapped($0.key), $0.value) })
    }

    func isPaneDetached(_ paneID: PaneID) -> Bool {
        detachedPaneIDs.contains(paneID)
    }

    func isPaneTiled(_ paneID: PaneID) -> Bool {
        layoutNode?.path(to: paneID) != nil && !isPaneDetached(paneID)
    }

    var tiledPaneIDsInTraversalOrder: [PaneID] {
        (layoutNode?.paneIDsInTraversalOrder ?? []).filter { !isPaneDetached($0) }
    }

    func composeHerdrLayout() {
        guard let backend = herdrBackendLayout else { return }
        layoutNode = combinedHerdrLayout(backend: previewHerdrLayout(backend))
    }

    func previewHerdrLayout(_ backend: LayoutNode) -> LayoutNode {
        var preview = backend
        for (path, edit) in herdrSplitEdits where backend.node(at: path)?.paneIDsInTraversalOrder == edit.paneIDs {
            preview = preview.replacingFractions(at: path, with: edit.fractions) ?? preview
        }
        return preview
    }

    func combinedHerdrLayout(backend: LayoutNode) -> LayoutNode {
        guard let local = herdrLocalLayout else { return backend }
        return .split(axis: .horizontal, children: [backend, local], fractions: [herdrLocalFraction, 1 - herdrLocalFraction])
    }

    var renderedLayout: LayoutNode? {
        guard herdrZoomed, let backend = herdrBackendLayout, let focused = herdrFocusedPaneID else { return layoutNode }
        return combinedHerdrLayout(backend: backend.path(to: focused) == nil ? previewHerdrLayout(backend) : .panel(focused))
    }

    var lastFocusedTiledPaneID: PaneID? {
        recentlyFocusedPaneIDs.first { isPaneTiled($0) } ?? tiledPaneIDsInTraversalOrder.first
    }

    func markPaneFocused(_ paneID: PaneID) {
        recentlyFocusedPaneIDs.removeAll { $0 == paneID }
        recentlyFocusedPaneIDs.insert(paneID, at: 0)
        pruneFocusHistory()
    }

    func removePaneFromFocusHistory(_ paneID: PaneID) {
        recentlyFocusedPaneIDs.removeAll { $0 == paneID }
    }

    func pruneFocusHistory() {
        recentlyFocusedPaneIDs.removeAll { paneControllers[$0] == nil }
    }
}
