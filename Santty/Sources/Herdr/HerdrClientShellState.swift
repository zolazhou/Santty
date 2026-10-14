import Foundation

struct HerdrShellSnapshot: Decodable, Sendable, Equatable {
    struct Workspace: Decodable, Sendable, Equatable {
        let workspace_id: String
        let active_tab_id: String
        let number: Int
        let label: String
        let focused: Bool
    }
    struct Tab: Decodable, Sendable, Equatable {
        let tab_id: String
        let workspace_id: String
        let number: Int
        let label: String
        let zoomed: Bool
        let focused: Bool
    }
    struct Pane: Decodable, Sendable, Equatable {
        let pane_id: String
        let workspace_id: String
        let tab_id: String
        let label: String?
        let cwd: String?
        let foreground_cwd: String?
        let focused: Bool
        let right_click_passthrough: Bool
    }
    struct Agent: Decodable, Sendable, Equatable {
        let pane_id: String
        let agent: String?
        let display_agent: String?
        let terminal_title: String?
        let terminal_title_stripped: String?
        let agent_status: String
        let state_change_seq: UInt64
        var workspace_id: String? = nil
        var tab_id: String? = nil
        var name: String? = nil
        var title: String? = nil
    }
    let boot_id: String
    let revision: UInt64
    let focused_workspace_id: String?
    let focused_tab_id: String?
    let focused_pane_id: String?
    let workspaces: [Workspace]
    let tabs: [Tab]
    let panes: [Pane]
    let agents: [Agent]?
    let config_diagnostic: String?

    func validate() throws {
        func validID(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= 1024 && !id.utf8.contains(0) }
        let spaces = Dictionary(workspaces.map { ($0.workspace_id, $0) }, uniquingKeysWith: { a, _ in a })
        let tabMap = Dictionary(tabs.map { ($0.tab_id, $0) }, uniquingKeysWith: { a, _ in a })
        let paneMap = Dictionary(panes.map { ($0.pane_id, $0) }, uniquingKeysWith: { a, _ in a })
        guard validID(boot_id), workspaces.count <= 64, tabs.count <= 256, panes.count <= 512,
              spaces.count == workspaces.count, tabMap.count == tabs.count, paneMap.count == panes.count,
              workspaces.allSatisfy({ validID($0.workspace_id) && $0.number > 0 && $0.label.utf8.count <= 4096
                  && tabMap[$0.active_tab_id]?.workspace_id == $0.workspace_id }),
              tabs.allSatisfy({ validID($0.tab_id) && spaces[$0.workspace_id] != nil && $0.number > 0 && $0.label.utf8.count <= 4096 }),
              panes.allSatisfy({ validID($0.pane_id) && tabMap[$0.tab_id]?.workspace_id == $0.workspace_id })
        else { throw CLIError("Invalid Herdr ClientShell snapshot topology") }
        if let agents {
            guard agents.count <= 512, Set(agents.map(\.pane_id)).count == agents.count,
                  agents.allSatisfy({ paneMap[$0.pane_id] != nil && ($0.tab_id == nil || paneMap[$0.pane_id]?.tab_id == $0.tab_id)
                    && ($0.workspace_id == nil || paneMap[$0.pane_id]?.workspace_id == $0.workspace_id)
                    && [$0.agent, $0.display_agent, $0.name, $0.title, $0.terminal_title, $0.terminal_title_stripped].allSatisfy { ($0?.utf8.count ?? 0) <= 4096 }
                    && $0.agent_status.utf8.count <= 128 })
            else { throw CLIError("Invalid Herdr ClientShell agent metadata") }
        }
        if let space = focused_workspace_id {
            guard spaces[space] != nil, let tab = focused_tab_id, tabMap[tab]?.workspace_id == space,
                  let pane = focused_pane_id, paneMap[pane]?.tab_id == tab
            else { throw CLIError("Invalid Herdr ClientShell selection") }
        } else if focused_tab_id != nil || focused_pane_id != nil || !workspaces.isEmpty {
            throw CLIError("Missing Herdr ClientShell selection")
        }
    }
}

struct HerdrShellAgentCompletions: Decodable, Sendable, Equatable {
    let boot_id: String
    let revision: UInt64
    let completions: [String: UInt64]
    func validate() throws {
        guard !boot_id.isEmpty, boot_id.utf8.count <= 1024, completions.count <= 512,
              completions.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.utf8.contains(0) })
        else { throw CLIError("Invalid Herdr agent completion metadata") }
    }
}

// Confined to the session's serial event queue. Only matching pairs are presentable.
struct HerdrShellProjection {
    static let maximumAssetBytes = 256 * 1024 * 1024
    private(set) var snapshot: HerdrShellSnapshot?
    private(set) var surface: HerdrShellSurface?
    private(set) var pendingSurface: HerdrShellSurface?
    private(set) var assets: [HerdrShellAssetKey: Data] = [:]

    var coherentSurface: HerdrShellSurface? {
        guard let snapshot, let surface, surface.boot_id == snapshot.boot_id,
              surface.projection_revision == snapshot.revision else { return nil }
        return surface
    }

    @discardableResult
    mutating func receive(_ next: HerdrShellSnapshot) throws -> Bool {
        try next.validate()
        if let snapshot, next.boot_id == snapshot.boot_id, next.revision < snapshot.revision { return false }
        if let snapshot, next.boot_id == snapshot.boot_id, next.revision == snapshot.revision {
            guard next == snapshot else { throw CLIError("Herdr changed a snapshot without advancing its revision") }
            return coherentSurface != nil
        }
        let restarted = snapshot.map { $0.boot_id != next.boot_id } ?? false
        if !restarted, let pendingSurface, pendingSurface.projection_revision == next.revision {
            try validate(pendingSurface, against: next)
        }
        if restarted { surface = nil; pendingSurface = nil; assets.removeAll() }
        snapshot = next
        if let pendingSurface, pendingSurface.projection_revision == next.revision {
            surface = pendingSurface; self.pendingSurface = nil
        } else if pendingSurface.map({ $0.projection_revision < next.revision }) == true {
            pendingSurface = nil
        }
        return coherentSurface != nil
    }

    @discardableResult
    mutating func receive(_ next: HerdrShellSurface) throws -> Bool {
        guard let snapshot, next.boot_id == snapshot.boot_id, next.projection_revision >= snapshot.revision else { return false }
        if let current = pendingSurface ?? surface {
            if next.projection_revision < current.projection_revision
                || (next.projection_revision == current.projection_revision && next.surface_revision <= current.surface_revision) { return false }
        }
        if next.projection_revision == snapshot.revision { try validate(next, against: snapshot) }
        var nextAssets = assets
        for asset in next.graphics.assets { nextAssets[asset.key] = asset.data }
        let desired = Set(next.graphics.placements.map(\.asset) + next.graphics.retained_assets)
        // The server can defer an inline asset to a later surface when one frame exceeds its budget.
        // Keep both visible and pending scenes while their snapshot is in flight.
        let visible = surface.map { Set($0.graphics.placements.map(\.asset) + $0.graphics.retained_assets) } ?? []
        nextAssets = nextAssets.filter { desired.contains($0.key) || visible.contains($0.key) }
        var assetBytes = 0
        for (key, data) in nextAssets {
            let pixels = UInt64(key.image_width) * UInt64(key.image_height)
            let components: UInt64 = key.format == 0 ? 3 : 4
            guard pixels <= UInt64(Self.maximumAssetBytes) / components else { throw CLIError("Herdr decoded image exceeds cache budget") }
            assetBytes += max(data.count, Int(pixels * components))
            guard assetBytes <= Self.maximumAssetBytes else { throw CLIError("Herdr image cache exceeds budget") }
        }
        var next = next
        if !next.hasRetainedCells { next.damage = nil }
        if next.damage == nil { next.recordCellDamage([]) }
        assets = nextAssets
        if next.projection_revision == snapshot.revision { surface = next; pendingSurface = nil }
        else { pendingSurface = next }
        return coherentSurface != nil && next.projection_revision == snapshot.revision
    }

    @discardableResult
    mutating func receive(_ patch: HerdrShellPatch) throws -> Bool {
        guard var next = coherentSurface, pendingSurface == nil, patch.boot_id == next.boot_id,
              patch.projection_revision == next.projection_revision, patch.base_surface_revision == next.surface_revision,
              next.surface_revision < UInt64.max, patch.surface_revision == next.surface_revision + 1,
              next.popup == nil, next.graphics.placements.isEmpty, next.graphics.retained_assets.isEmpty
        else { throw CLIError("Herdr surface patch lost its baseline") }
        var paneIndices: [String: Int] = [:]
        for (index, pane) in next.panes.enumerated() { paneIndices[pane.pane_id] = index }
        guard Set(patch.panes.map(\.pane_id)).count == patch.panes.count else { throw CLIError("Duplicate Herdr patch pane") }
        for updated in patch.panes {
            guard let index = paneIndices[updated.pane_id] else { throw CLIError("Unknown Herdr patch pane") }
            let current = next.panes[index]
            // content_revision includes an unstable-render bit; it is not the ordered patch baseline.
            guard current.rect == updated.rect, current.inner_rect == updated.inner_rect,
                  current.focused == updated.focused, current.pixel_width == updated.pixel_width,
                  current.pixel_height == updated.pixel_height
            else { throw CLIError("Herdr patch changed pane geometry") }
        }
        let width = Int(next.frame.width), height = Int(next.frame.height)
        for row in patch.rows {
            let x = Int(row.x), y = Int(row.y)
            guard !row.cells.isEmpty, y < height, x <= width, row.cells.count <= width - x,
                  row.cells.allSatisfy({ $0.hyperlink.map { Int($0) < next.frame.hyperlinks.count } ?? true }),
                  patch.panes.contains(where: { pane in
                      let inner = pane.inner_rect
                      if x >= Int(inner.x), x + row.cells.count <= Int(inner.x) + Int(inner.width),
                         y >= Int(inner.y), y < Int(inner.y) + Int(inner.height) { return true }
                      let scroll = pane.scrollbar_rect ?? next.panes[paneIndices[pane.pane_id]!].scrollbar_rect
                      return scroll.map { x == Int($0.x) && row.cells.count == Int($0.width)
                          && y >= Int($0.y) && y < Int($0.y) + Int($0.height) } ?? false
                  }) else { throw CLIError("Invalid Herdr patch row") }
        }
        if let cursor = patch.cursor, cursor.visible, cursor.x >= next.frame.width || cursor.y >= next.frame.height {
            throw CLIError("Invalid Herdr patch cursor")
        }
        for scroll in patch.scrolls {
            guard scroll.rect.width > 0, scroll.rect.height >= 2, scroll.shift != 0,
                  abs(scroll.shift) < Int(scroll.rect.height),
                  patch.panes.contains(where: { $0.inner_rect.contains(scroll.rect) }) else {
                throw CLIError("Invalid Herdr scroll pane region")
            }
        }
        for scroll in patch.scrolls { next.frame.scroll(scroll.rect, by: scroll.shift) }
        for row in patch.rows {
            next.frame.replaceCells(row.cells, x: Int(row.x), y: Int(row.y))
            next.damage?.mark(.init(x: row.x, y: row.y, width: UInt16(row.cells.count), height: 1),
                              panes: next.panes, revision: patch.surface_revision)
        }
        for scroll in patch.scrolls { next.damage?.mark(scroll.rect, panes: next.panes, revision: patch.surface_revision) }
        for pane in patch.panes { next.panes[paneIndices[pane.pane_id]!] = pane }
        next.frame.cursor = patch.cursor
        next.surface_revision = patch.surface_revision
        surface = next
        return true
    }

    private func validate(_ surface: HerdrShellSurface, against snapshot: HerdrShellSnapshot) throws {
        guard let tabID = snapshot.focused_tab_id,
              let tab = snapshot.tabs.first(where: { $0.tab_id == tabID }) else { throw CLIError("Herdr surface has no selected tab") }
        let members = Set(snapshot.panes.filter { $0.tab_id == tabID }.map(\.pane_id))
        let visible = Set(surface.panes.map(\.pane_id))
        guard visible.isSubset(of: members), tab.zoomed || members == visible,
              !visible.isEmpty, surface.panes.filter(\.focused).count <= 1,
              surface.panes.first(where: \.focused)?.pane_id == snapshot.focused_pane_id
        else { throw CLIError("Herdr surface does not match its snapshot") }
        for placement in surface.graphics.placements {
            switch placement.asset.source {
            case .pane(let id, _), .layer(let id, _):
                guard visible.contains(id) else { throw CLIError("Herdr image targets an invisible pane") }
            case .popup(let id, _):
                guard surface.popup?.terminal_id == id else { throw CLIError("Herdr image targets an unknown popup") }
            }
        }
    }
}
