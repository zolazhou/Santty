import Foundation

struct WorkspaceEntry: Equatable, Identifiable {
    let reference: UUID
    let name: String
    var id: String { "local." + reference.uuidString }
}
