import Foundation

/// Only the terminal/row/column subset is projected. Unsupported layouts remain opaque in
/// HerdrWorkspaceDocument and cannot be silently flattened into a Santty terminal layout.
enum HerdrWorkspaceProjection {
    struct Seed: Sendable {
        let space: HerdrJSONValue
    }

    indirect enum Layout: Sendable, Equatable {
        case terminal(id: String, address: String)
        case split(id: String, axis: SplitAxis, children: [Layout], fractions: [Double])
    }

    static func spaceID(_ id: UUID) -> String { "s" + compact(id) }
    static func tabID(_ id: UUID) -> String { "c" + compact(id) }
    static func paneID(_ id: UUID) -> String { "p" + compact(id) }
    private static func compact(_ id: UUID) -> String { id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    static func export(_ workspace: SavedWorkspace.LocalWorkspace, coreID: String) throws -> Seed {
        guard workspace.kind == .herdr, !workspace.tabs.isEmpty,
              workspace.herdrRemote == nil || workspace.herdrRemote?.id == coreID else {
            throw HerdrWorkspaceDocument.invalid("Only a workspace on the selected Herdr core can be shared")
        }
        var saved = SavedWorkspace(selectedTabID: workspace.selectedTabID, tabs: workspace.tabs)
        saved.localWorkspaceID = workspace.id; saved.localWorkspaceName = workspace.name
        saved.workspaceKind = .herdr; saved.herdrRemote = workspace.herdrRemote
        try saved.validate()
        var addresses = Set<String>()
        let space = spaceID(workspace.id)
        let tabs: [HerdrJSONValue] = try workspace.tabs.map { tab in
            // Auto-resize/focus-zoom is this Mac's presentation preference: it is not shared.
            guard let layout = tab.layout, tab.detachedPaneIDs.isEmpty, tab.floating == nil,
                  tab.activeDetachedPaneID == nil else {
                throw HerdrWorkspaceDocument.invalid("Floating and hidden panes cannot be shared yet")
            }
            let id = tabID(tab.id)
            var terminals: [UUID: String] = [:]
            for pane in tab.panes {
                guard pane.kind == .herdrTerminal, pane.herdrViewer != true, pane.herdrRunPending != true,
                      let binding = pane.herdr, binding.coreID == coreID,
                      (binding.remote == true) == (workspace.herdrRemote != nil),
                      addresses.insert(binding.address).inserted else {
                    throw HerdrWorkspaceDocument.invalid("Sharing requires distinct, bound, owned Herdr terminal panes")
                }
                terminals[pane.id] = binding.address
            }
            func node(_ layout: LayoutNode, path: String, depth: Int) throws -> HerdrJSONValue {
                guard depth < 64 else { throw HerdrWorkspaceDocument.invalid("Shared layout is too deep") }
                switch layout {
                case let .panel(pane):
                    guard let address = terminals[pane] else { throw HerdrWorkspaceDocument.invalid("Missing terminal binding") }
                    return .object(["id": .string(paneID(pane)), "type": .string("block"),
                                    "content": .object(["terminal": .string(address)])])
                case let .split(axis, children, fractions):
                    let nodes = try zip(children.indices, children).map { index, child -> HerdrJSONValue in
                        var result = try node(child, path: path + "-\(index)", depth: depth + 1).object!
                        result["size"] = .object(["weight": .number(Double(fractions[index]))])
                        return .object(result)
                    }
                    return .object(["id": .string(path), "type": .string(axis == .horizontal ? "row" : "column"),
                                    "children": .array(nodes)])
                }
            }
            var root = try node(layout, path: id, depth: 0)
            if case .panel = layout {
                root = .object(["id": .string(id), "type": .string("row"), "children": .array([root])])
            }
            return .object(["id": .string(id), "name": .string(tab.customTitle ?? ""), "root": root])
        }
        let value: HerdrJSONValue = .object(["id": .string(space), "name": .string(workspace.name),
                                           "folder": .string(workspace.tabs.first?.panes.first?.cwd ?? ""), "tabs": .array(tabs)])
        // Apply the same document limits/identity checks as a received document.
        _ = try HerdrWorkspaceDocument().applying(.insertSpace(value))
        return Seed(space: value)
    }

    static func layout(_ root: HerdrJSONValue) throws -> Layout {
        var ids = Set<String>(), addresses = Set<String>()
        var count = 0
        func node(_ value: HerdrJSONValue, depth: Int) throws -> Layout {
            count += 1
            guard depth < 64, count <= 1024, let object = value.object,
                  let id = object["id"]?.string, !id.isEmpty, id.utf8.count <= 1024,
                  ids.insert(id).inserted,
                  object["hidden"] == nil || object["hidden"] == .bool(false),
                  object["floating"] == nil || object["floating"] == .array([]),
                  object["min"] == nil, object["max"] == nil else {
                throw HerdrWorkspaceDocument.invalid("Unsupported or invalid shared layout node")
            }
            switch object["type"]?.string {
            case "block":
                guard let content = object["content"]?.object, content.count == 1,
                      let address = content["terminal"]?.string,
                      address.range(of: "^t[0-9a-z]+$", options: .regularExpression) != nil,
                      addresses.insert(address).inserted else {
                    throw HerdrWorkspaceDocument.invalid("Only distinct machine-local terminal blocks can be projected")
                }
                return .terminal(id: id, address: address)
            case "row", "column":
                guard let children = object["children"]?.array, !children.isEmpty else {
                    throw HerdrWorkspaceDocument.invalid("Empty or invalid shared split")
                }
                let weights = try children.map { child -> Double in
                    guard let size = child["size"] else { return 1 }
                    guard let object = size.object, object.count == 1,
                          let weight = object["weight"]?.double, weight.isFinite, weight > 0 else {
                        throw HerdrWorkspaceDocument.invalid("Only positive shared split weights are supported")
                    }
                    return weight
                }
                let total = weights.reduce(0, +)
                let fractions = weights.map { $0 / total }
                guard total.isFinite, fractions.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                    throw HerdrWorkspaceDocument.invalid("Invalid shared split weights")
                }
                return .split(id: id, axis: object["type"]?.string == "row" ? .horizontal : .vertical,
                              children: try children.map { try node($0, depth: depth + 1) }, fractions: fractions)
            default: throw HerdrWorkspaceDocument.invalid("This Herdr layout node cannot be projected by Santty yet")
            }
        }
        return try node(root, depth: 0)
    }
}
