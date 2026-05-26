import AppKit

@MainActor
struct ActiveFloatingPaneState: Equatable {
    let paneID: PaneID
}

@MainActor
final class WorkspaceTabState {
    let id: UUID
    var layoutNode: LayoutNode?
    var paneControllers: [PaneID: TerminalPaneController]
    var paneAutoResizeConfigurations: [PaneID: PaneAutoResizeConfiguration]
    var focusedPaneID: PaneID?
    var customTitle: String?
    private var recentlyFocusedPaneIDs: [PaneID]
    var activeAutoZoomState: ActiveAutoZoomState?
    var activeFloatingPaneState: ActiveFloatingPaneState?

    init(
        id: UUID = UUID(),
        layoutNode: LayoutNode?,
        paneControllers: [PaneID: TerminalPaneController],
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

    var focusedPaneController: TerminalPaneController? {
        guard let focusedPaneID else {
            return nil
        }

        return paneControllers[focusedPaneID]
    }

    var displayTitle: String {
        if let customTitle {
            return customTitle
        }

        return focusedPaneController?.displayTitle ?? "Shell"
    }

    func containsPane(withID paneID: PaneID) -> Bool {
        paneControllers[paneID] != nil
    }

    func focusRecency(for paneID: PaneID) -> Int? {
        recentlyFocusedPaneIDs.firstIndex(of: paneID)
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
