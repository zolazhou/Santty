import Foundation

enum WorkspaceKind: String, Codable, Sendable {
    case local, herdr
    var title: String { self == .local ? "Local Workspace" : "Herdr Workspace" }
    var symbol: String { self == .local ? "desktopcomputer" : "terminal" }
    var brandIcon: BrandIcon? { self == .herdr ? .herdr : nil }
}

struct WorkspaceEntry: Equatable, Identifiable {
    let reference: UUID
    let name: String
    var kind: WorkspaceKind = .local
    var remote: HerdrRemote? = nil
    var detail: String { remote.map { "Herdr · " + $0.name } ?? kind.title }
    var symbol: String { remote == nil ? kind.symbol : "network" }
    var brandIcon: BrandIcon? { kind.brandIcon }
    var id: String { kind.rawValue + "." + reference.uuidString }
}
