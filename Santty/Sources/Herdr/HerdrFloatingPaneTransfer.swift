import Foundation

struct HerdrFloatingPaneRecord: Codable, Sendable, Equatable {
    let paneID: UUID
    let source: HerdrPaneBinding
    var size: CGSize? = nil
    var sourceViewport: HerdrShellSize? = nil
    var placeholder: HerdrPaneBinding?
    var floating: HerdrPaneBinding?
}

@MainActor
final class HerdrFloatingPaneTransfer {
    private(set) var record: HerdrFloatingPaneRecord
    private let client: HerdrWorkspaceClient
    private let session: HerdrClientShellSession
    var onChange: ((HerdrFloatingPaneRecord) -> Void)?

    init(record: HerdrFloatingPaneRecord, client: HerdrWorkspaceClient, session: HerdrClientShellSession) {
        self.record = record; self.client = client; self.session = session
    }

    func enter() async throws {
        guard record.placeholder == nil, record.floating == nil else { throw CLIError("Herdr floating transfer already exists") }
        let result = try await client.requestPaneTransfer("pane.split", binding: record.source,
            params: .init(target_pane_id: record.source.paneID, direction: "right", focus: false, ratio: 0.5), session: session)
        guard let pane = result.pane, pane.workspace_id == record.source.workspaceID,
              pane.tab_id == record.source.tabID, pane.pane_id != record.source.paneID else {
            throw CLIError("Missing Herdr floating placeholder acknowledgement; refresh before retrying")
        }
        record.placeholder = try HerdrPaneBinding(endpoint: client.endpoint, pane: pane, includeRuntime: true)
        onChange?(record)
        do {
            let moved = try await move(record.source, to: .init(type: "new_tab", workspace_id: record.source.workspaceID,
                label: "Floating"))
            guard moved.tabID != record.source.tabID else { throw CLIError("Herdr did not create a floating tab") }
            record.floating = moved; onChange?(record)
        } catch {
            // Lost acknowledgements are reconciled by runtime identity, never replayed.
            let current = try? await client.snapshot().panes.first { $0.terminal_id == record.source.terminalID }
            if let current, current.workspace_id == record.source.workspaceID, current.tab_id != record.source.tabID {
                record.floating = try HerdrPaneBinding(endpoint: client.endpoint, pane: current, includeRuntime: true)
                onChange?(record)
            } else if current?.tab_id == record.source.tabID {
                try? await removePlaceholder()
            }
            throw error
        }
    }

    func leave() async throws {
        guard let placeholder = record.placeholder else { return }
        if let floating = record.floating, floating.tabID != record.source.tabID {
            let snapshot = try await client.snapshot()
            if snapshot.panes.contains(where: { floating.matches($0) }) {
                record.floating = try await move(floating, to: .init(type: "tab", tab_id: record.source.tabID,
                    target_pane_id: placeholder.paneID, split: "right", ratio: 0.5))
            } else {
                if let current = snapshot.panes.first(where: { $0.pane_id == floating.paneID }) {
                    guard current.terminal_id == record.source.terminalID,
                          current.workspace_id == record.source.workspaceID, current.tab_id == record.source.tabID else {
                        throw CLIError("Herdr floating placement changed")
                    }
                    record.floating = try .init(endpoint: client.endpoint, pane: current, includeRuntime: true)
                } else { record.floating = nil }
            }
            onChange?(record)
        }
        try await removePlaceholder()
        record.floating = nil; onChange?(record)
    }

    private func move(_ binding: HerdrPaneBinding,
                      to destination: HerdrConnection.Request.Params.MoveDestination) async throws -> HerdrPaneBinding {
        let result = try await client.requestPaneTransfer("pane.move", binding: binding,
            params: .init(pane_id: binding.paneID, focus: false, destination: destination), session: session)
        guard let move = result.move_result, move.changed,
              move.previous_pane_id == binding.paneID, move.previous_tab_id == binding.tabID,
              move.previous_workspace_id == binding.workspaceID,
              move.pane.workspace_id == record.source.workspaceID,
              move.pane.terminal_id == record.source.terminalID,
              destination.tab_id == nil || move.pane.tab_id == destination.tab_id else {
            throw CLIError("Herdr pane transfer was rejected or its identity changed")
        }
        return try .init(endpoint: client.endpoint, pane: move.pane, includeRuntime: true)
    }

    private func removePlaceholder() async throws {
        guard let placeholder = record.placeholder else { return }
        let snapshot = try await client.snapshot()
        guard snapshot.panes.contains(where: { placeholder.matches($0) }) else {
            guard !snapshot.panes.contains(where: { $0.pane_id == placeholder.paneID }) else { throw CLIError("Herdr placeholder runtime changed") }
            record.placeholder = nil; onChange?(record)
            return
        }
        _ = try await client.requestPaneTransfer("pane.close", binding: placeholder,
            params: .init(pane_id: placeholder.paneID), session: session)
        record.placeholder = nil; onChange?(record)
    }
}
