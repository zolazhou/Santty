import Foundation

enum PaneCloseIntent: Equatable { case terminate, detach }
enum PaneCloseFailure: Error, Equatable, LocalizedError {
    case duplicatePane, paneChanged, conflictingIntent
    var errorDescription: String? {
        switch self {
        case .duplicatePane: "Close refused: duplicate pane identity."
        case .paneChanged: "The pane or container changed while closing. Its layout was retained; inspect it before trying again."
        case .conflictingIntent: "This terminal already has a different close operation. Finish that operation before trying another."
        }
    }
}

/// Backend-independent finite close snapshot. Retaining the concrete owner is
/// essential: registry removal must not release a process while cleanup awaits.
@MainActor
struct PaneCloseTarget {
    let id: UUID
    let owner: AnyObject
    var validate: (PaneCloseIntent) throws -> Void = { _ in }
    var begin: (PaneCloseIntent) throws -> Void = { _ in }
    let finish: @MainActor (PaneCloseIntent) async throws -> Void
    let isCurrent: () -> Bool
}

@MainActor
enum PaneCloseTransaction {
    static func perform(_ targets: [PaneCloseTarget], intent: PaneCloseIntent,
                        scopeIsCurrent: () -> Bool = { true }, then commit: () -> Void) async throws {
        defer { withExtendedLifetime(targets) {} } // concrete owners survive every await and commit
        try Task.checkCancellation()
        guard Set(targets.map(\.id)).count == targets.count else { throw PaneCloseFailure.duplicatePane }
        guard scopeIsCurrent(), targets.allSatisfy({ $0.isCurrent() }) else { throw PaneCloseFailure.paneChanged }
        for target in targets { try target.validate(intent) }
        for target in targets { try target.begin(intent) }
        let operations = targets.map { target in Task { try await target.finish(intent) } }
        var firstError: (any Error)?
        for operation in operations {
            do { try await operation.value } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
        try Task.checkCancellation()
        guard scopeIsCurrent(), targets.allSatisfy({ $0.isCurrent() }) else { throw PaneCloseFailure.paneChanged }
        commit() // no await between final identity checks and layout mutation
    }
}

/// Coalesces one concrete owner's close, not workspace operations or CLI IDs.
/// Native Local and Herdr both supply awaited ownership cleanup.
@MainActor
final class PaneCloseHandle {
    enum Policy { case awaitedOwner }
    let id: UUID
    let policy: Policy
    private let hasResources: () -> Bool
    private let normalize: (PaneCloseIntent) -> PaneCloseIntent
    private let suspend: (PaneCloseIntent) -> Void
    private let validateOwner: (PaneCloseIntent) throws -> Void
    private let operation: @MainActor (PaneCloseIntent) async throws -> Void
    private var intent: PaneCloseIntent?
    private var task: Task<Void, Error>?
    private var admissionPrepared = false
    private(set) var completed = false
    var hasBegun: Bool { intent != nil }
    func needsAwait(for requested: PaneCloseIntent) -> Bool {
        policy == .awaitedOwner && (hasResources() || hasBegun) && (!completed || intent != normalize(requested))
    }

    init(id: UUID, policy: Policy, hasResources: @escaping () -> Bool = { true }, normalize: @escaping (PaneCloseIntent) -> PaneCloseIntent = { $0 },
         validateOwner: @escaping (PaneCloseIntent) throws -> Void = { _ in }, suspend: @escaping (PaneCloseIntent) -> Void = { _ in }, operation: @escaping @MainActor (PaneCloseIntent) async throws -> Void) {
        self.id = id; self.policy = policy; self.hasResources = hasResources; self.normalize = normalize; self.validateOwner = validateOwner; self.suspend = suspend; self.operation = operation
    }
    func validate(_ requested: PaneCloseIntent) throws {
        if let intent, intent != normalize(requested) { throw PaneCloseFailure.conflictingIntent }
        try validateOwner(normalize(requested))
    }
    func begin(_ requested: PaneCloseIntent) throws {
        try validate(requested)
        guard !completed else { return }
        intent = normalize(requested)
        if !admissionPrepared { admissionPrepared = true; suspend(normalize(requested)) }
    }
    func finish(_ requested: PaneCloseIntent) async throws {
        try validate(requested)
        if let task { return try await task.value }
        guard !completed else { return }
        try begin(requested)
        let chosen = normalize(requested)
        let work = Task {
            do { try await operation(chosen); completed = true }
            catch { task = nil; admissionPrepared = false; throw error }
        }
        task = work
        try await work.value
    }
}
