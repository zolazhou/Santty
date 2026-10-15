import Foundation

struct HerdrLayout: Decodable, Sendable {
    let workspace_id: String
    let tab_id: String
    let zoomed: Bool
    let focused_pane_id: String
    let root: Node
    var serviceIdentity: HerdrServiceIdentity? = nil
    enum CodingKeys: String, CodingKey { case workspace_id, tab_id, zoomed, focused_pane_id, root }

    static func nativeShellViewportSize(surface: HerdrShellSurface, nativeSize: CGSize,
                                        availableSize: CGSize, cellSize: CGSize) -> HerdrShellSize? {
        guard cellSize.width.isFinite, cellSize.height.isFinite, cellSize.width > 0, cellSize.height > 0 else { return nil }
        // Resize from the authoritative frame, reclaiming chrome omitted by the native projection.
        let columns = CGFloat(surface.frame.width) + floor((availableSize.width - nativeSize.width) / cellSize.width)
        let rows = CGFloat(surface.frame.height) + floor((availableSize.height - nativeSize.height) / cellSize.height)
        guard columns.isFinite, rows.isFinite, columns >= 1, rows >= 1 else { return nil }
        return .init(cols: UInt16(min(columns, CGFloat(UInt16.max))), rows: UInt16(min(rows, CGFloat(UInt16.max))))
    }

    static func matchesShellProjection(layouts: [String: HerdrLayout],
                                       shell: HerdrShellSnapshot, surface: HerdrShellSurface) -> Bool {
        guard shell.boot_id == surface.boot_id, shell.revision == surface.projection_revision,
              let workspace = shell.focused_workspace_id, let activeTab = shell.focused_tab_id else { return false }
        let tabs = shell.tabs.filter { $0.workspace_id == workspace }
        guard layouts.count == tabs.count else { return false }
        for tab in tabs {
            guard let layout = layouts[tab.tab_id], layout.workspace_id == workspace, layout.tab_id == tab.tab_id,
                  Set(layout.root.paneIDs).count == layout.root.paneIDs.count,
                  Set(layout.root.paneIDs) == Set(shell.panes.filter { $0.workspace_id == workspace && $0.tab_id == tab.tab_id }.map(\.pane_id))
            else { return false }
        }
        guard let active = layouts[activeTab] else { return false }
        return (try? active.root.projected(on: surface)) != nil
    }

    indirect enum Node: Decodable, Sendable {
        case pane(String)
        case split(SplitAxis, Double, Node, Node)

        private enum Keys: String, CodingKey { case type, pane_id, direction, ratio, first, second }
        init(from decoder: Decoder) throws { self = try Self.decode(decoder, depth: 0) }
        private static func decode(_ decoder: Decoder, depth: Int) throws -> Node {
            guard depth < 64 else { throw CLIError("Herdr layout is too deep") }
            let fields = try decoder.container(keyedBy: Keys.self)
            switch try fields.decode(String.self, forKey: .type) {
            case "pane":
                let id = try fields.decode(String.self, forKey: .pane_id)
                guard !id.isEmpty, id.utf8.count <= 1024 else { throw CLIError("Invalid Herdr pane ID") }
                return .pane(id)
            case "split":
                let direction = try fields.decode(String.self, forKey: .direction)
                let ratio = try fields.decode(Double.self, forKey: .ratio)
                guard ["right", "down"].contains(direction), ratio.isFinite, ratio > 0, ratio < 1 else {
                    throw CLIError("Invalid Herdr split")
                }
                return .split(direction == "right" ? .horizontal : .vertical, ratio,
                    try decode(fields.superDecoder(forKey: .first), depth: depth + 1),
                    try decode(fields.superDecoder(forKey: .second), depth: depth + 1))
            default: throw CLIError("Unsupported Herdr layout node")
            }
        }

        var paneIDs: [String] {
            switch self {
            case .pane(let id): [id]
            case .split(_, _, let first, let second): first.paneIDs + second.paneIDs
            }
        }

        func nativeLayout(panes: [String: UUID]) throws -> LayoutNode {
            switch self {
            case .pane(let id):
                guard let id = panes[id] else { throw CLIError("Herdr layout references an unknown pane") }
                return .panel(id)
            case .split(let axis, let ratio, let first, let second):
                return .split(axis: axis, children: [try first.nativeLayout(panes: panes), try second.nativeLayout(panes: panes)],
                              fractions: [CGFloat(ratio), CGFloat(1 - ratio)])
            }
        }

        func nativeShellLayout(panes: [String: UUID], surface: HerdrShellSurface,
                               cellSize: CGSize, padding: CGFloat, divider: CGFloat) throws -> (layout: LayoutNode, size: CGSize) {
            guard Set(surface.panes.map(\.pane_id)).count == surface.panes.count else { throw CLIError("Duplicate ClientShell native pane") }
            let nativePanes = Dictionary(uniqueKeysWithValues: surface.panes.map { ($0.pane_id, $0) })
            let hasLeftBorders = surface.panes.contains { $0.inner_rect.x > $0.rect.x }
            let hasScrollbarGutter = surface.panes.contains { pane in
                let rightInset = Int(pane.rect.x) + Int(pane.rect.width) - Int(pane.inner_rect.x) - Int(pane.inner_rect.width)
                return pane.scrollbar_rect != nil || !pane.alternate_screen_active
                    && (rightInset >= 2 || !hasLeftBorders && rightInset == 1)
            }
            func build(_ node: Node) throws -> (LayoutNode, CGSize) {
                switch node {
                case .pane(let key):
                    guard let id = panes[key], let pane = nativePanes[key] else { throw CLIError("Missing ClientShell native pane") }
                    let rect = pane.inner_rect
                    let rightInset = Int(pane.rect.x) + Int(pane.rect.width) - Int(rect.x) - Int(rect.width)
                    // Herdr's normal-mode right gutter disappears in alternate screen; it is not a window resize.
                    let gutter: CGFloat = hasScrollbarGutter && !pane.alternate_screen_active && rect.width >= 4 && rightInset > 0 ? 1 : 0
                    return (.panel(id), CGSize(width: (CGFloat(rect.width) + gutter) * cellSize.width + padding * 2,
                                              height: CGFloat(rect.height) * cellSize.height + padding * 2))
                case .split(let axis, _, let first, let second):
                    let (a, sizeA) = try build(first), (b, sizeB) = try build(second)
                    let horizontal = axis == .horizontal
                    let firstSpan = horizontal ? sizeA.width : sizeA.height
                    let secondSpan = horizontal ? sizeB.width : sizeB.height
                    guard firstSpan.isFinite, secondSpan.isFinite, firstSpan > 0, secondSpan > 0,
                          (firstSpan + secondSpan).isFinite else { throw CLIError("Invalid ClientShell native dimensions") }
                    let ratio = firstSpan / (firstSpan + secondSpan)
                    let size = horizontal
                        ? CGSize(width: sizeA.width + sizeB.width + divider, height: max(sizeA.height, sizeB.height))
                        : CGSize(width: max(sizeA.width, sizeB.width), height: sizeA.height + sizeB.height + divider)
                    return (.split(axis: axis, children: [a, b], fractions: [ratio, 1 - ratio]), size)
                }
            }
            guard cellSize.width.isFinite, cellSize.height.isFinite, cellSize.width > 0, cellSize.height > 0,
                  padding.isFinite, padding >= 0, divider.isFinite, divider >= 0 else { throw CLIError("Invalid ClientShell native cell metrics") }
            return try build(self)
        }

        // Surface splits are drag handles, not a complete tree when borders/gaps are disabled.
        func projected(on surface: HerdrShellSurface) throws -> Node {
            let ids = paneIDs
            let visible = surface.panes.map(\.pane_id)
            guard !visible.isEmpty, visible.count <= 512, ids.count <= 512,
                  Set(ids).count == ids.count, Set(visible).count == visible.count,
                  Set(visible).isSubset(of: Set(ids)) else { throw CLIError("Herdr surface and layout identities differ") }
            let panes = Dictionary(uniqueKeysWithValues: surface.panes.map { ($0.pane_id, $0.rect) })
            guard surface.splits.count <= 511, surface.splits.allSatisfy({ $0.path.count < 64 }),
                  Set(surface.splits.map(\.path)).count == surface.splits.count else {
                throw CLIError("Invalid Herdr surface split paths")
            }
            let splits = Dictionary(uniqueKeysWithValues: surface.splits.map { ($0.path, $0) })
            let bounds = HerdrShellRect(x: 0, y: 0, width: surface.frame.width, height: surface.frame.height)
            guard panes.values.allSatisfy({ $0.width > 0 && $0.height > 0 && bounds.contains($0) }) else {
                throw CLIError("Herdr layout pane lies outside the surface")
            }
            if visible.count == 1 {
                guard splits.isEmpty else { throw CLIError("Single Herdr pane has split handles") }
                return .pane(visible[0])
            }
            guard Set(visible) == Set(ids) else { throw CLIError("Herdr surface has an incomplete layout") }
            var usedSplits = Set<[Bool]>()
            func project(_ node: Node, path: [Bool]) throws -> (Node, HerdrShellRect) {
                guard path.count < 64 else { throw CLIError("Herdr layout is too deep") }
                switch node {
                case .pane(let id):
                    guard let rect = panes[id] else { throw CLIError("Missing Herdr layout pane") }
                    return (.pane(id), rect)
                case .split(let axis, _, let first, let second):
                    let (a, ar) = try project(first, path: path + [false])
                    let (b, br) = try project(second, path: path + [true])
                    let x = min(ar.x, br.x), y = min(ar.y, br.y)
                    let right = max(Int(ar.x) + Int(ar.width), Int(br.x) + Int(br.width))
                    let bottom = max(Int(ar.y) + Int(ar.height), Int(br.y) + Int(br.height))
                    let rect = HerdrShellRect(x: x, y: y, width: UInt16(right - Int(x)), height: UInt16(bottom - Int(y)))
                    let horizontal = axis == .horizontal
                    let end = horizontal ? Int(ar.x) + Int(ar.width) : Int(ar.y) + Int(ar.height)
                    let start = horizontal ? Int(br.x) : Int(br.y)
                    guard end <= start else { throw CLIError("Herdr layout branches overlap or changed order") }
                    var origin = horizontal ? Int(rect.x) : Int(rect.y)
                    var span = horizontal ? Int(rect.width) : Int(rect.height)
                    var position = Double(end + start) / 2
                    if let split = splits[path] {
                        guard split.horizontal == horizontal, bounds.contains(split.area), split.area.contains(rect),
                              Int(split.pos) >= end, Int(split.pos) <= start else {
                            throw CLIError("Herdr split geometry differs from its layout")
                        }
                        usedSplits.insert(path)
                        origin = horizontal ? Int(split.area.x) : Int(split.area.y)
                        span = horizontal ? Int(split.area.width) : Int(split.area.height)
                        position = Double(split.pos)
                    }
                    let ratio = (position - Double(origin)) / Double(span)
                    guard ratio.isFinite, ratio > 0, ratio < 1 else { throw CLIError("Invalid Herdr projected split ratio") }
                    return (.split(axis, ratio, a, b), rect)
                }
            }
            let (root, _) = try project(self, path: [])
            guard usedSplits.count == splits.count else { throw CLIError("Herdr surface contains an unknown split path") }
            return root
        }
    }
}
