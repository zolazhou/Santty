import Foundation

/// Explicit, core-bound document operations. No polling, background publishing, offline queue,
/// automatic CAS retry, label changes, terminal creation or terminal termination.
@MainActor
struct HerdrWorkspaceDocumentStore {
    let client: HerdrCoreClient
    let coreID: String
    let remote: Bool

    struct Snapshot: Sendable {
        let coreID: String
        let remote: Bool
        let version: UInt64
        let exists: Bool
        let document: HerdrWorkspaceDocument
        fileprivate let connection: HerdrCoreTransport
    }
    private struct ReadResult: Decodable, Sendable {
        let value: HerdrJSONValue
        let version: UInt64
    }
    private struct WriteResult: Decodable, Sendable { let version: UInt64 }

    init(client: HerdrCoreClient, coreID: String, remote: Bool = false) {
        self.client = client; self.coreID = coreID; self.remote = remote
    }

    func read() async throws -> Snapshot {
        let connection = try await checkedConnection()
        let reply = try await connection.call(method: "doc.get", params: JSONEncoder().encode(parameters()))
        let result = try JSONDecoder().decode(HerdrCoreReply<ReadResult>.self, from: reply).get()
        let document = try result.value == .null ? HerdrWorkspaceDocument() : HerdrWorkspaceDocument(value: result.value)
        guard client.isCurrentConnection(connection) else {
            throw HerdrCoreError("The workspace connection changed while reading. Refresh it.", kind: "stale_workspace")
        }
        return Snapshot(coreID: coreID, remote: remote, version: result.version, exists: result.value != .null,
                        document: document, connection: connection)
    }

    func apply(_ edit: HerdrWorkspaceDocument.Edit, to snapshot: Snapshot) async throws -> Snapshot {
        let connection = try await checkedConnection()
        guard snapshot.coreID == coreID, snapshot.remote == remote, snapshot.connection === connection else {
            throw HerdrCoreError("The workspace connection changed. Read it again before editing.", kind: "stale_workspace")
        }
        let document = try snapshot.document.applying(edit)
        var params = parameters()
        params["version"] = .unsigned(snapshot.version)
        params["value"] = document.value
        // Core checks the revision atomically. Never retry an ambiguous or conflicting write here.
        let reply = try await connection.call(method: "doc.set", params: JSONEncoder().encode(params))
        let result = try JSONDecoder().decode(HerdrCoreReply<WriteResult>.self, from: reply).get()
        guard client.isCurrentConnection(connection) else {
            throw HerdrCoreError("The write may have completed on the old connection. Refresh before editing again.", kind: "stale_workspace")
        }
        return Snapshot(coreID: coreID, remote: remote, version: result.version, exists: true,
                        document: document, connection: connection)
    }

    private func parameters() -> [String: HerdrJSONValue] {
        var params: [String: HerdrJSONValue] = ["name": .string(HerdrWorkspaceDocument.name)]
        if remote { params["on"] = .string(coreID) }
        return params
    }

    private func checkedConnection() async throws -> HerdrCoreTransport {
        guard !coreID.isEmpty, coreID.utf8.count <= 128,
              coreID.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else {
            throw HerdrCoreError("Invalid shared workspace core identity", kind: "identity_changed")
        }
        let connection = try await client.connection()
        guard ["doc.get", "doc.set"].allSatisfy(connection.hello.methods.contains) else {
            throw HerdrCoreError("This core does not support shared workspace documents", kind: "needs_update")
        }
        if remote {
            let machines = try await client.configuredMachines()
            guard let machine = machines.first(where: { $0.id == coreID }) else {
                throw HerdrCoreError("The workspace's remote core is no longer configured", kind: "identity_changed")
            }
            guard machine.state == "connected" else {
                throw HerdrCoreError("The workspace's remote core is unavailable", kind: "unavailable")
            }
            guard client.isCurrentConnection(connection) else {
                throw HerdrCoreError("The workspace connection changed. Read it again.", kind: "stale_workspace")
            }
        } else if coreID != connection.hello.core.id {
            throw HerdrCoreError("The saved workspace belongs to another core", kind: "identity_changed")
        }
        return connection
    }
}
