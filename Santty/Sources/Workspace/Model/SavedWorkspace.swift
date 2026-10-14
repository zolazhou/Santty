import Foundation

struct SavedWorkspace: Codable, Sendable, Equatable {
    static let currentVersion = 6
    var version = Self.currentVersion
    var selectedTabID: UUID?
    var tabs: [Tab]
    var herdrWindowBinding: HerdrPaneBinding? = nil
    var herdrWindowMode: HerdrTerminalMode? = nil
    var herdrWindowTransport: HerdrPaneTransport? = nil
    var parkedTabs: [Tab]? = nil
    var parkedSelectedTabID: UUID? = nil
    var herdrAuxiliaryTabs: [Tab]? = nil
    var localWorkspaceID: UUID? = nil
    var localWorkspaceName: String? = nil
    var otherLocalWorkspaces: [LocalWorkspace]? = nil
    var workspaces: [WorkspaceEntry]? = nil
    var selectedWorkspace: WorkspaceReference? = nil

    struct LocalWorkspace: Codable, Sendable, Equatable {
        let id: UUID
        var name: String
        var selectedTabID: UUID?
        var tabs: [Tab]
    }


    var restoredHerdrWindowTransport: HerdrPaneTransport {
        .clientShell
    }

    struct Pane: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable { case localTerminal, persistentTerminal, browser, notes }
        let id: UUID
        let kind: Kind
        var name: String?
        var title: String
        var cwd: String?
        var binding: HerdrPaneBinding?
        var mode: HerdrTerminalMode = .control
        var browserURL: String?
        var noteFileName: String?
        var noteFileURL: URL?
    }

    struct Floating: Codable, Sendable, Equatable { let paneID: UUID; let size: CGSize? }
    struct Tab: Codable, Sendable, Equatable {
        let id: UUID
        var layout: LayoutNode?
        var panes: [Pane]
        var focusedPaneID: UUID?
        var customTitle: String?
        var backendBinding: HerdrPaneBinding?
        var autoResize: [UUID: PaneAutoResizeConfiguration]
        var detachedPaneIDs: [UUID]
        var activeDetachedPaneID: UUID?
        var floating: Floating?
        var floatingSizes: [UUID: CGSize]
        var herdrBackendLayout: LayoutNode? = nil
        var herdrLocalLayout: LayoutNode? = nil
        var herdrLocalFraction: CGFloat? = nil
        var herdrFocusedPaneID: UUID? = nil
    }

    func validate() throws { try validate(allowMissingRuntime: false) }

    private func validate(allowMissingRuntime: Bool) throws {
        guard (1...Self.currentVersion).contains(version) else { throw CLIError("Unsupported workspace version \(version); the file will not be overwritten") }
        if let workspaces {
            guard version >= 6, workspaces.count <= 4096, Set(workspaces.map(\.id)).count == workspaces.count,
                  selectedWorkspace.map({ selected in workspaces.contains { $0.reference == selected } }) != false else {
                throw CLIError("Invalid unified workspace directory")
            }
            for entry in workspaces {
                guard !entry.name.isEmpty, entry.name.utf8.count <= 4096 else { throw CLIError("Invalid workspace name") }
                if case .herdr(let endpoint, let id) = entry.reference.source {
                    guard !id.isEmpty, id.utf8.count <= 1024, endpoint.binary.isFileURL,
                          endpoint.binary.path.hasPrefix("/"), !endpoint.session.isEmpty else { throw CLIError("Invalid workspace source") }
                    if let machine = endpoint.machine { try machine.validate() }
                }
            }
        } else if selectedWorkspace != nil { throw CLIError("Missing unified workspace directory") }
        guard tabs.count <= 64, Set(tabs.map(\.id)).count == tabs.count,
              selectedTabID == nil || tabs.contains(where: { $0.id == selectedTabID }) else { throw CLIError("Invalid workspace tabs") }
        if let parkedTabs {
            try SavedWorkspace(selectedTabID: parkedSelectedTabID, tabs: parkedTabs).validate()
            guard Set(parkedTabs.map(\.id)).isDisjoint(with: Set(tabs.map(\.id))),
                  Set(parkedTabs.flatMap(\.panes).map(\.id)).isDisjoint(with: Set(tabs.flatMap(\.panes).map(\.id))) else { throw CLIError("Duplicate parked tabs") }
        }
        if let auxiliaries = herdrAuxiliaryTabs {
            guard (version >= 4 || herdrWindowBinding != nil), auxiliaries.allSatisfy({ tab in
                tab.backendBinding != nil
                    && (version >= 4 || (tab.backendBinding?.endpoint == herdrWindowBinding?.endpoint
                        && tab.backendBinding?.serviceIdentity == herdrWindowBinding?.serviceIdentity))
                    && tab.herdrBackendLayout == nil && tab.herdrLocalLayout == tab.layout
                    && tab.panes.allSatisfy { $0.binding == nil }
            }) else { throw CLIError("Invalid Herdr auxiliary tabs") }
            try SavedWorkspace(tabs: auxiliaries).validate(allowMissingRuntime: version >= 3 && restoredHerdrWindowTransport == .clientShell)
        }
        guard (localWorkspaceID == nil) == (localWorkspaceName == nil),
              localWorkspaceName.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) != false,
              version >= 5 || (localWorkspaceID == nil && otherLocalWorkspaces == nil) else { throw CLIError("Invalid local workspace identity") }
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
        let allTabs = tabs + (parkedTabs ?? []) + (herdrAuxiliaryTabs ?? []) + (otherLocalWorkspaces ?? []).flatMap(\.tabs)
        guard allTabs.count <= 64, Set(allTabs.map(\.id)).count == allTabs.count,
              allTabs.flatMap(\.panes).count <= 512,
              Set(allTabs.flatMap(\.panes).map(\.id)).count == allTabs.flatMap(\.panes).count else { throw CLIError("Duplicate or excessive workspace contents") }
        guard (herdrWindowBinding == nil) == (parkedTabs == nil) else { throw CLIError("Invalid saved Herdr window") }
        guard herdrWindowTransport == nil || herdrWindowBinding != nil,
              version >= 3 || herdrWindowTransport == nil else { throw CLIError("Invalid saved Herdr transport") }
        if herdrWindowBinding != nil, version >= 3, herdrWindowTransport != nil {
            guard herdrWindowMode == .control,
                  tabs.flatMap(\.panes).filter({ $0.kind == .persistentTerminal }).allSatisfy({ $0.mode == .control })
            else { throw CLIError("ClientShell workspace requires Control mode") }
        }
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
        func validateBinding(_ binding: HerdrPaneBinding) throws {
            let runtimeValid = binding.terminalID.map { !$0.isEmpty && $0.utf8.count <= 1024 }
                ?? (version >= 3 && (allowMissingRuntime || restoredHerdrWindowTransport == .clientShell) && binding.serviceIdentity != nil)
            guard runtimeValid, binding.endpoint.binary.isFileURL, binding.endpoint.binary.path.hasPrefix("/"),
                  !binding.endpoint.session.isEmpty, binding.endpoint.session.utf8.count <= 64,
                  binding.endpoint.session.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  [binding.paneID, binding.workspaceID, binding.tabID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 })
            else { throw CLIError("Invalid saved terminal identity") }
            if let machine = binding.endpoint.machine {
                try machine.validate()
                guard machine.session == binding.endpoint.session else { throw CLIError("Invalid remote workspace session") }
            } else { try CLITransport.withAddress(binding.endpoint.socketPath) { _, _ in } }
        }
        if let binding = herdrWindowBinding {
            try validateBinding(binding)
            guard tabs.contains(where: { $0.backendBinding == binding }), tabs.allSatisfy({ tab in
                tab.backendBinding?.endpoint == binding.endpoint && tab.backendBinding?.workspaceID == binding.workspaceID
                    && tab.backendBinding?.serviceIdentity == binding.serviceIdentity
                    && (tab.herdrBackendLayout != nil || tab.panes.allSatisfy { $0.kind == .persistentTerminal })
                    && tab.panes.allSatisfy { pane in pane.binding == nil || (pane.binding?.workspaceID == binding.workspaceID && pane.binding?.tabID == tab.backendBinding?.tabID && pane.binding?.endpoint == binding.endpoint && pane.binding?.serviceIdentity == binding.serviceIdentity) }
            }) else { throw CLIError("Invalid saved Herdr window references") }
        }
        for tab in tabs {
            let ids = Set(tab.panes.map(\.id))
            let tiled = tab.layout?.paneIDsInTraversalOrder ?? []
            let detached = Set(tab.detachedPaneIDs)
            let backendIDs = Set(tab.herdrBackendLayout?.paneIDsInTraversalOrder ?? [])
            guard ids.count == tab.panes.count, allIDs.isDisjoint(with: ids),
                  tiled.count == Set(tiled).count, detached.count == tab.detachedPaneIDs.count,
                  Set(tiled).intersection(detached).isSubset(of: backendIDs), Set(tiled).union(detached) == ids,
                  tab.focusedPaneID == nil || ids.contains(tab.focusedPaneID!),
                  tab.activeDetachedPaneID == nil || detached.contains(tab.activeDetachedPaneID!),
                  tab.floating == nil || Set(tiled).contains(tab.floating!.paneID),
                  tab.floating == nil || tab.activeDetachedPaneID == nil,
                  Set(tab.autoResize.keys).isSubset(of: ids), Set(tab.floatingSizes.keys).isSubset(of: ids),
                  tab.floatingSizes.values.allSatisfy(sizeValid), tab.floating?.size.map(sizeValid) != false,
                  tab.herdrLocalFraction.map({ $0.isFinite && $0 > 0 && $0 < 1 }) != false,
                  (tab.customTitle?.utf8.count ?? 0) <= 1024 else { throw CLIError("Invalid workspace pane references") }
            if let layout = tab.layout { try validateLayout(layout) }
            if let backend = tab.herdrBackendLayout {
                let localIDs = Set(tab.herdrLocalLayout?.paneIDsInTraversalOrder ?? [])
                let persistentIDs = Set(tab.panes.filter { $0.kind == .persistentTerminal }.map(\.id))
                let fraction = tab.herdrLocalFraction ?? 0.7
                let combined: LayoutNode = tab.herdrLocalLayout.map { .split(axis: .horizontal, children: [backend, $0], fractions: [fraction, 1 - fraction]) } ?? backend
                guard tab.backendBinding != nil, fraction.isFinite, fraction > 0, fraction < 1,
                      backendIDs.count == backend.paneIDsInTraversalOrder.count, backendIDs == persistentIDs,
                      backendIDs.isDisjoint(with: localIDs), combined == tab.layout,
                      tab.herdrFocusedPaneID == nil || backendIDs.contains(tab.herdrFocusedPaneID!),
                      localIDs.union(detached.subtracting(backendIDs)) == ids.subtracting(backendIDs) else { throw CLIError("Invalid Herdr layout partition") }
                try validateLayout(backend)
            }
            if let local = tab.herdrLocalLayout { try validateLayout(local) }
            if let binding = tab.backendBinding { try validateBinding(binding) }
            for config in tab.autoResize.values {
                guard [config.ratios.horizontal, config.ratios.vertical].allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 }) else { throw CLIError("Invalid workspace auto-resize ratios") }
            }
            for pane in tab.panes {
                guard pane.title.utf8.count <= 1024, (pane.name?.utf8.count ?? 0) <= 1024,
                      (pane.cwd?.utf8.count ?? 0) <= 4096,
                      (pane.kind == .persistentTerminal) == (pane.binding != nil),
                      (pane.browserURL?.utf8.count ?? 0) <= 8192,
                      pane.noteFileName == nil || (!pane.noteFileName!.contains("/") && ![".", ".."].contains(pane.noteFileName!))
                else { throw CLIError("Invalid saved pane") }
                if let url = pane.noteFileURL {
                    guard url.isFileURL, url.lastPathComponent == pane.noteFileName else { throw CLIError("Invalid saved note reference") }
                }
                if let binding = pane.binding {
                    try validateBinding(binding)
                }
            }
            allIDs.formUnion(ids)
        }
        guard allIDs.count <= 512 else { throw CLIError("Workspace has too many panes") }
    }
}
