import Foundation

struct AgentPaneSnapshot: Equatable {
    let paneID: PaneID
    var title: String
    var workingDirectory: String?
}

@MainActor
final class AgentPaneRegistry {
    static let shared = AgentPaneRegistry()

    private var panes: [PaneID: AgentPaneSnapshot] = [:]

    private init() {}

    func register(paneID: PaneID, title: String, workingDirectory: String?) {
        panes[paneID] = AgentPaneSnapshot(
            paneID: paneID,
            title: title,
            workingDirectory: workingDirectory
        )
    }

    func update(paneID: PaneID, title: String? = nil, workingDirectory: String? = nil) {
        guard var pane = panes[paneID] else {
            return
        }

        if let title {
            pane.title = title
        }
        if let workingDirectory {
            pane.workingDirectory = workingDirectory
        }
        panes[paneID] = pane
    }

    func unregister(paneID: PaneID) {
        panes.removeValue(forKey: paneID)
    }

    func snapshot(for paneID: PaneID) -> AgentPaneSnapshot? {
        panes[paneID]
    }

    func reset() {
        panes.removeAll()
    }
}
