import CryptoKit
import Foundation

/// A canonical, comparable view of one shared workspace: what both Santty and Herdr store in a
/// space of the `herdr-app` document. Order is significant; unknown fields are not represented.
struct HerdrSharedView: Sendable, Equatable {
    struct Tab: Sendable, Equatable {
        var id: String
        var name: String
        var root: HerdrJSONValue
    }
    var id: String
    var name: String
    var folder: String
    var tabs: [Tab]

    static func from(space: HerdrWorkspaceDocument.Space) -> HerdrSharedView {
        HerdrSharedView(id: space.id, name: space.name, folder: space.folder,
                        tabs: space.tabs.map { Tab(id: $0.id, name: $0.name, root: $0.root) })
    }

    var documentValue: HerdrJSONValue {
        .object(["id": .string(id), "name": .string(name), "folder": .string(folder),
                 "tabs": .array(tabs.map { .object(["id": .string($0.id), "name": .string($0.name), "root": $0.root]) })])
    }
}

/// Three-way merge over shared structure. Per tab, and for the space's name/folder:
/// - only the document changed: adopt it
/// - only this screen changed: keep it (and publish it)
/// - both changed differently: the document wins and the loss is reported, never silent
/// A tab deleted on one side and untouched on the other is deleted; if the other side changed it
/// too, the surviving copy wins and that is reported.
enum HerdrWorkspaceMerge {
    struct Result: Sendable, Equatable {
        var view: HerdrSharedView
        var conflicts: [String]
        var createSpace: Bool
    }

    static func merge(base: HerdrSharedView?, local: HerdrSharedView, remote: HerdrSharedView?) -> Result {
        guard let remote else { return Result(view: local, conflicts: [], createSpace: true) }
        // First sync in this session: the machine's document is the shared structure.
        guard let base else { return Result(view: remote, conflicts: [], createSpace: false) }

        var conflicts: [String] = []
        let (name, nameConflict) = text(base.name, local.name, remote.name)
        if nameConflict { conflicts.append("space name: kept \(remote.name)") }
        let (folder, folderConflict) = text(base.folder, local.folder, remote.folder)
        if folderConflict { conflicts.append("space folder: kept \(remote.folder)") }

        let baseTabs = Dictionary(base.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localTabs = Dictionary(local.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteTabs = Dictionary(remote.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = []
        var seen = Set<String>()
        for tab in remote.tabs where seen.insert(tab.id).inserted { order.append(tab.id) }
        for (index, tab) in local.tabs.enumerated() where !seen.contains(tab.id) {
            let predecessor = local.tabs[..<index].last { seen.contains($0.id) }?.id
            let at = predecessor.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? order.count
            order.insert(tab.id, at: at)
            seen.insert(tab.id)
        }

        var tabs: [HerdrSharedView.Tab] = []
        func keep(_ tab: HerdrSharedView.Tab, _ reason: String? = nil) {
            tabs.append(tab)
            if let reason { conflicts.append(reason) }
        }
        for id in order {
            let baseTab = baseTabs[id], localTab = localTabs[id], remoteTab = remoteTabs[id]
            switch (baseTab, localTab, remoteTab) {
            case let (_, .some(local), .some(remote)) where local == remote: tabs.append(local)
            case let (.some(base), .some(local), .some(remote)):
                if local == base { tabs.append(remote) }
                else if remote == base { tabs.append(local) }
                else { keep(remote, "tab \(remote.name.isEmpty ? id : remote.name): kept the shared document's version") }
            case let (nil, .some(local), nil): tabs.append(local)
            case let (nil, nil, .some(remote)): tabs.append(remote)
            case let (nil, .some(local), .some(remote)):
                keep(remote, "tab \(remote.name.isEmpty ? id : remote.name): added on both sides, kept the shared document's version")
            case let (.some(base), .some(local), nil):
                if local == base { continue }
                keep(local, "tab \(local.name.isEmpty ? id : local.name): deleted in the shared document but changed here, restored")
            case let (.some(base), nil, .some(remote)):
                if remote == base { continue }
                keep(remote, "tab \(remote.name.isEmpty ? id : remote.name): deleted here but changed in the shared document, restored")
            case let (_, .some(local), nil): tabs.append(local)
            case let (_, nil, .some(remote)): tabs.append(remote)
            case (_, nil, nil): continue
            }
        }
        return Result(view: HerdrSharedView(id: remote.id, name: name, folder: folder, tabs: tabs),
                      conflicts: conflicts, createSpace: false)
    }

    private static func text(_ base: String, _ local: String, _ remote: String) -> (String, Bool) {
        if local == remote { return (local, false) }
        if local == base { return (remote, false) }
        if remote == base { return (local, false) }
        return (remote, true)
    }
}

/// Machine-local Herdr IDs (`p<32 hex>`, `c<32 hex>`, `s<32 hex>` from Santty; anything else from
/// Herdr or a mod) become stable UUIDs, so a pane keeps its identity across both clients and restarts.
enum HerdrWorkspaceIdentity {
    static func uuid(_ id: String, coreID: String) -> UUID {
        let hex = id.dropFirst()
        if "pcs".contains(id.first ?? " "), hex.count == 32,
           let value = UUID(uuidString: String(hex.prefix(8)) + "-" + String(hex.dropFirst(8).prefix(4)) + "-"
                            + String(hex.dropFirst(12).prefix(4)) + "-" + String(hex.dropFirst(16).prefix(4)) + "-"
                            + String(hex.dropFirst(20))) {
            return value
        }
        var digest = Array(SHA256.hash(data: Data((coreID + "/" + id).utf8)).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }
}

/// Converts between Santty's saved workspace and the shared view. Unsupported local content is
/// rejected, never dropped; unsupported remote content is reported, never guessed.
enum HerdrWorkspaceAdapter {
    static func view(_ workspace: SavedWorkspace.LocalWorkspace, coreID: String) throws -> HerdrSharedView {
        let seed = try HerdrWorkspaceProjection.export(workspace, coreID: coreID)
        let document = try HerdrWorkspaceDocument().applying(.insertSpace(seed.space))
        guard let space = try document.spaces().first else { throw HerdrWorkspaceDocument.invalid("Empty projection") }
        return HerdrSharedView.from(space: space)
    }

    /// Remote tabs as Santty tabs. Panes that already exist keep their controller, cwd and ownership;
    /// panes only the document knows become external viewers (close detaches, never kills).
    static func tabs(_ view: HerdrSharedView, coreID: String,
                     existing: [UUID: SavedWorkspace.Pane]) throws -> [SavedWorkspace.Tab] {
        try view.tabs.map { tab in
            let tabID = HerdrWorkspaceIdentity.uuid(tab.id, coreID: coreID)
            let projection = try HerdrWorkspaceProjection.layout(tab.root)
            var panes: [UUID: SavedWorkspace.Pane] = [:]
            var order: [UUID] = []
            func keep(_ node: HerdrWorkspaceProjection.Layout) -> LayoutNode {
                switch node {
                case let .terminal(nodeID, address):
                    let paneID = HerdrWorkspaceIdentity.uuid(nodeID, coreID: coreID)
                    if let existing = existing[paneID] {
                        panes[paneID] = existing
                    } else {
                        panes[paneID] = .init(id: paneID, kind: .herdrTerminal, title: "Terminal",
                                              herdr: .init(coreID: coreID, address: address), herdrViewer: true)
                    }
                    if !order.contains(paneID) { order.append(paneID) }
                    return .panel(paneID)
                case let .split(_, axis, children, fractions):
                    return .split(axis: axis, children: children.map(keep), fractions: fractions.map { CGFloat($0) })
                }
            }
            let layout = keep(projection)
            let saved = order.compactMap { panes[$0] }
            guard saved.count == order.count, !saved.isEmpty else {
                throw HerdrWorkspaceDocument.invalid("A shared tab has no terminals Santty can show")
            }
            return .init(id: tabID, layout: layout, panes: saved, focusedPaneID: order.first,
                         customTitle: tab.name.isEmpty ? nil : tab.name, autoResize: [:],
                         detachedPaneIDs: [], activeDetachedPaneID: nil, floating: nil, floatingSizes: [:])
        }
    }
}
