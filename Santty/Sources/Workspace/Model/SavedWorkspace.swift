import Foundation

struct SavedWorkspace: Codable, Sendable, Equatable {
    static let currentVersion = 10
    var version = Self.currentVersion
    struct Sidebar: Codable, Sendable, Equatable {
        var side: SidebarSide
        var preferredWidth: CGFloat
        var isVisible: Bool
        var tab: Tab
    }
    var sidebar: Sidebar? = nil
    var sidebarIsFocused: Bool? = nil
    var selectedTabID: UUID?
    var tabs: [Tab]
    var localWorkspaceID: UUID? = nil
    var localWorkspaceName: String? = nil
    var otherLocalWorkspaces: [LocalWorkspace]? = nil

    struct LocalWorkspace: Codable, Sendable, Equatable {
        let id: UUID
        var name: String
        var selectedTabID: UUID?
        var tabs: [Tab]
    }

    struct Pane: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable { case localTerminal, browser, workspaces }
        let id: UUID
        let kind: Kind
        var name: String?
        var title: String
        var cwd: String?
        var browserURL: String?
    }

    struct Floating: Codable, Sendable, Equatable { let paneID: UUID; let size: CGSize? }
    struct Tab: Codable, Sendable, Equatable {
        let id: UUID
        var layout: LayoutNode?
        var panes: [Pane]
        var focusedPaneID: UUID?
        var customTitle: String?
        var autoResize: [UUID: PaneAutoResizeConfiguration]
        var detachedPaneIDs: [UUID]
        var activeDetachedPaneID: UUID?
        var floating: Floating?
        var floatingSizes: [UUID: CGSize]
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw CLIError("Unsupported workspace version \(version); the file will not be overwritten") }
        if let sidebar {
            guard sidebar.preferredWidth.isFinite,
                  sidebar.preferredWidth >= 240, sidebar.preferredWidth <= 100_000,
                  sidebar.tab.detachedPaneIDs.isEmpty, sidebar.tab.activeDetachedPaneID == nil,
                  sidebar.tab.floating == nil, sidebar.tab.floatingSizes.isEmpty,
                  sidebar.tab.autoResize.isEmpty,
                  sidebar.tab.panes.allSatisfy({ [.browser, .workspaces].contains($0.kind) }),
                  !sidebar.isVisible || sidebar.tab.layout != nil,
                  sidebarIsFocused != true || sidebar.isVisible && sidebar.tab.focusedPaneID != nil else {
                throw CLIError("Invalid saved window sidebar")
            }
            try SavedWorkspace(tabs: [sidebar.tab]).validate()
        } else if sidebarIsFocused == true { throw CLIError("Missing focused sidebar") }

        guard tabs.count <= 64, Set(tabs.map(\.id)).count == tabs.count,
              selectedTabID == nil || tabs.contains(where: { $0.id == selectedTabID }) else { throw CLIError("Invalid workspace tabs") }

        guard (localWorkspaceID == nil) == (localWorkspaceName == nil),
              localWorkspaceName.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) != false else { throw CLIError("Invalid local workspace identity") }
        if let others = otherLocalWorkspaces {
            guard localWorkspaceID != nil, others.count < 64,
                  Set(others.map(\.id)).count == others.count,
                  !others.contains(where: { $0.id == localWorkspaceID }) else { throw CLIError("Invalid local workspaces") }
            for workspace in others {
                guard !workspace.name.isEmpty, workspace.name.utf8.count <= 1024,
                      !workspace.tabs.isEmpty
                else { throw CLIError("Invalid local workspace contents") }
                try SavedWorkspace(selectedTabID: workspace.selectedTabID, tabs: workspace.tabs).validate()
            }
        }
        let allTabs = tabs + (otherLocalWorkspaces ?? []).flatMap(\.tabs) + (sidebar.map { [$0.tab] } ?? [])
        guard allTabs.count <= (sidebar == nil ? 64 : 65), Set(allTabs.map(\.id)).count == allTabs.count,
              allTabs.flatMap(\.panes).count <= 512,
              Set(allTabs.flatMap(\.panes).map(\.id)).count == allTabs.flatMap(\.panes).count else { throw CLIError("Duplicate or excessive workspace contents") }
        var allIDs = Set<UUID>()
        func validateLayout(_ node: LayoutNode, depth: Int = 0) throws {
            guard depth < 64 else { throw CLIError("Workspace layout is too deep") }
            if case .split(_, let children, let fractions) = node {
                guard children.count >= 2, children.count == fractions.count,
                      fractions.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1 }),
                      abs(fractions.reduce(0, +) - 1) < 0.001 else { throw CLIError("Invalid workspace split") }
                for child in children { try validateLayout(child, depth: depth + 1) }
            }
        }
        func sizeValid(_ size: CGSize) -> Bool {
            size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
                && size.width <= 100_000 && size.height <= 100_000
        }
        for tab in tabs {
            let ids = Set(tab.panes.map(\.id))
            let tiled = tab.layout?.paneIDsInTraversalOrder ?? []
            let detached = Set(tab.detachedPaneIDs)
            guard ids.count == tab.panes.count, allIDs.isDisjoint(with: ids),
                  tiled.count == Set(tiled).count, detached.count == tab.detachedPaneIDs.count,
                  Set(tiled).isDisjoint(with: detached), Set(tiled).union(detached) == ids,
                  tab.focusedPaneID == nil || ids.contains(tab.focusedPaneID!),
                  tab.activeDetachedPaneID == nil || detached.contains(tab.activeDetachedPaneID!),
                  tab.floating == nil || Set(tiled).contains(tab.floating!.paneID),
                  tab.floating == nil || tab.activeDetachedPaneID == nil,
                  Set(tab.autoResize.keys).isSubset(of: ids), Set(tab.floatingSizes.keys).isSubset(of: ids),
                  tab.floatingSizes.values.allSatisfy(sizeValid), tab.floating?.size.map(sizeValid) != false,
                  (tab.customTitle?.utf8.count ?? 0) <= 1024 else { throw CLIError("Invalid workspace pane references") }
            if let layout = tab.layout { try validateLayout(layout) }

            for config in tab.autoResize.values {
                guard [config.ratios.horizontal, config.ratios.vertical].allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 }) else { throw CLIError("Invalid workspace auto-resize ratios") }
            }
            for pane in tab.panes {
                guard pane.title.utf8.count <= 1024, (pane.name?.utf8.count ?? 0) <= 1024,
                      (pane.cwd?.utf8.count ?? 0) <= 4096,
                      (pane.browserURL?.utf8.count ?? 0) <= 8192
                else { throw CLIError("Invalid saved pane") }
            }
            allIDs.formUnion(ids)
        }
        guard allIDs.count <= 512 else { throw CLIError("Workspace has too many panes") }
    }
}
