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

    func isPaneDetached(_ paneID: PaneID) -> Bool {
        detachedPaneIDs.contains(paneID)
    }

    func isPaneTiled(_ paneID: PaneID) -> Bool {
        layoutNode?.path(to: paneID) != nil
    }

    var tiledPaneIDsInTraversalOrder: [PaneID] {
        layoutNode?.paneIDsInTraversalOrder ?? []
    }

    var lastFocusedTiledPaneID: PaneID? {
        recentlyFocusedPaneIDs.first { isPaneTiled($0) } ?? layoutNode?.firstPaneID
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
