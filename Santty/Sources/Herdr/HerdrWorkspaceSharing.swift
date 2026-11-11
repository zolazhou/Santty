import Foundation

/// Keeps each shared workspace and its core document in step, in both directions.
///
/// One pass is: read the document, merge base/local/remote, write only when the merged structure
/// differs from the document, then let the window adopt the merged structure. Merging is
/// idempotent, so a write that comes back as a doc event causes no further write, and a doc change
/// made in Herdr or on the phone is adopted here. Conflicts are reported, never resolved silently
/// against the shared document.
@MainActor
final class HerdrWorkspaceSharing {
    struct Local: Sendable {
        let id: UUID
        let coreID: String
        let remote: Bool
        let view: HerdrSharedView
    }
    struct Applied: Sendable {
        let id: UUID
        let view: HerdrSharedView
    }

    static let didChangeNotification = Notification.Name("HerdrWorkspaceSharingDidChange")

    var localProvider: (() -> [Local])?
    var apply: ((Applied) -> Void)?
    var status: ((String?) -> Void)?

    private let client: HerdrCoreClient
    private let settings: HerdrSettings
    private var base: [UUID: HerdrSharedView] = [:]
    private var publishedLabels: [String: [String: String]] = [:]
    /// Workspaces whose space was deleted in the shared document: kept on this screen, not re-created.
    private var unshared: Set<UUID> = []
    private var task: Task<Void, Never>?
    private var pending = false
    private var suspended = 0

    init(client: HerdrCoreClient, settings: HerdrSettings = .shared) {
        self.client = client
        self.settings = settings
    }

    var isEnabled: Bool { settings.shareWorkspaces }

    /// Coalesces bursts of local and remote changes; no queue survives a failed pass.
    func schedule() {
        guard isEnabled, suspended == 0 else { return }
        pending = true
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, self.pending, !Task.isCancelled else { break }
                self.pending = false
                await self.sync()
            }
            self?.task = nil
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        pending = false
        base.removeAll()
        publishedLabels.removeAll()
        unshared.removeAll()
    }

    private func sync() async {
        guard isEnabled, let locals = localProvider?(), !locals.isEmpty else { return }
        var snapshots: [String: HerdrWorkspaceDocumentStore.Snapshot] = [:]
        var notes: [String] = []
        for local in locals {
            let store = HerdrWorkspaceDocumentStore(client: client, coreID: local.coreID, remote: local.remote)
            do {
                let snapshot: HerdrWorkspaceDocumentStore.Snapshot
                if let cached = snapshots[local.coreID] { snapshot = cached } else { snapshot = try await store.read() }
                let remoteSpace = try snapshot.document.space(id: local.view.id).map(HerdrSharedView.from)
                // A space deleted elsewhere means "closed there". Re-publishing it would resurrect it.
                if remoteSpace == nil, base[local.id] != nil {
                    base[local.id] = nil
                    unshared.insert(local.id)
                }
                if unshared.contains(local.id) {
                    notes.append("a shared workspace was closed in the document; it no longer syncs from here")
                    continue
                }
                let result = HerdrWorkspaceMerge.merge(base: base[local.id], local: local.view, remote: remoteSpace)
                var written = snapshot
                if result.createSpace {
                    written = try await store.apply(.insertSpace(result.view.documentValue), to: snapshot)
                } else if let remoteSpace, result.view != remoteSpace {
                    written = try await store.apply(.setSpace(result.view.documentValue, expectedName: remoteSpace.name), to: snapshot)
                }
                snapshots[local.coreID] = written
                base[local.id] = result.view
                notes += result.conflicts
                if result.view != local.view {
                    suspended += 1
                    apply?(.init(id: local.id, view: result.view))
                    suspended -= 1
                }
                await publishLabels(for: result.view, local: local, notes: &notes)
            } catch let error as HerdrCoreError where error.kind == "conflict" {
                // Someone else wrote between our read and write. Merge again from the fresh document;
                // never retry the same value.
                pending = true
                base[local.id] = nil
            } catch is CancellationError {
                return
            } catch {
                notes.insert(error.localizedDescription, at: 0)
            }
        }
        status?(notes.isEmpty ? nil : Array(notes.prefix(3)).joined(separator: " · "))
    }

    /// Herdr adopts terminals through these two labels, so a pane added here shows up there, and a
    /// pane removed from the shared structure stops being adopted. Other labels are never touched.
    private func publishLabels(for view: HerdrSharedView, local: Local, notes: inout [String]) async {
        var desired: [String: [String: String]] = [:]
        for tab in view.tabs {
            guard let layout = try? HerdrWorkspaceProjection.layout(tab.root) else { continue }
            for address in Self.addresses(layout) {
                desired[address] = ["herdr.space": view.id, "herdr.tab": tab.id]
            }
        }
        let connection: HerdrCoreTransport
        do { connection = try await client.connection() } catch { notes.append(error.localizedDescription); return }
        for (address, labels) in desired where publishedLabels[local.coreID + "/" + address] != labels {
            let route = local.remote ? local.coreID + "/" + address : address
            do {
                let _: HerdrTerminalLabels = try await HerdrCoreClient.request(connection, "terminal.label",
                                                                              ["terminal": route, "labels": labels])
                publishedLabels[local.coreID + "/" + address] = labels
            } catch let error as HerdrCoreError where ["not_found", "machine_unknown"].contains(error.kind) {
                continue
            } catch {
                notes.append(error.localizedDescription)
                return
            }
        }
        // A terminal we published that left the shared structure must stop being adopted, or Herdr
        // would put it back into a space of its own.
        for (key, labels) in publishedLabels where key.hasPrefix(local.coreID + "/") {
            let address = String(key.dropFirst(local.coreID.count + 1))
            guard desired[address] == nil else { continue }
            let route = local.remote ? key : address
            do {
                let _: HerdrTerminalLabels = try await HerdrCoreClient.request(connection, "terminal.label",
                                                                              ["terminal": route, "labels": ["herdr.space": "", "herdr.tab": ""]])
                publishedLabels.removeValue(forKey: key)
            } catch let error as HerdrCoreError where ["not_found", "machine_unknown"].contains(error.kind) {
                publishedLabels.removeValue(forKey: key)
            } catch {
                _ = labels
                notes.append(error.localizedDescription)
                return
            }
        }
    }

    private static func addresses(_ layout: HerdrWorkspaceProjection.Layout) -> [String] {
        switch layout {
        case let .terminal(_, address): [address]
        case let .split(_, _, children, _): children.flatMap(addresses)
        }
    }
}

private struct HerdrTerminalLabels: Decodable, Sendable {
    let labels: [String: String]?
}
