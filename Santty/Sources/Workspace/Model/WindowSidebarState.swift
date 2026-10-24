import AppKit

enum SidebarSide: String, Codable, Sendable { case left, right }

@MainActor
final class WindowSidebarState {
    var side: SidebarSide = .left
    var preferredWidth: CGFloat = 280
    var isVisible = false
    var tab = WorkspaceTabState(layoutNode: nil, paneControllers: [:],
        paneAutoResizeConfigurations: [:], focusedPaneID: nil)
}
