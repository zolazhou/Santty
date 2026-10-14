import Foundation

enum WorkspaceKind: String, Codable, Sendable {
    case local, herdr, remoteHerdr

    var title: String {
        switch self {
        case .local: "Local Workspace"
        case .herdr: "Herdr Workspace"
        case .remoteHerdr: "Remote Herdr Workspace"
        }
    }

    var symbol: String {
        switch self {
        case .local: "desktopcomputer"
        case .herdr: "server.rack"
        case .remoteHerdr: "network"
        }
    }
}

struct WorkspaceReference: Codable, Sendable, Equatable {
    enum Source: Codable, Sendable, Equatable {
        case local(UUID)
        case herdr(endpoint: HerdrEndpoint, workspaceID: String)
    }
    let source: Source

    var kind: WorkspaceKind {
        switch source {
        case .local: .local
        case .herdr(let endpoint, _): endpoint.machine == nil ? .herdr : .remoteHerdr
        }
    }

    var id: String {
        switch source {
        case .local(let id): "local." + id.uuidString
        case .herdr(let endpoint, let workspaceID):
            endpoint.id + ".workspace." + Data(workspaceID.utf8).base64EncodedString()
        }
    }
}

struct WorkspaceEntry: Codable, Sendable, Equatable, Identifiable {
    let reference: WorkspaceReference
    let name: String
    var isAvailable = true
    var status: String? = nil
    var id: String { reference.id }
    var kind: WorkspaceKind { reference.kind }
    var title: String {
        if case .herdr(let endpoint, _) = reference.source, let machine = endpoint.machine {
            return name + " · " + machine.label
        }
        return name
    }
}
