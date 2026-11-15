import Foundation

/// A finite snapshot of LOCAL owners, not a second workspace registry. Herdr
/// detach/kill policies must keep using HerdrTerminalSession, never this API.
@MainActor
enum NativeLocalPTYCloseBarrier {
    enum Failure: Error, Equatable { case duplicatePane, paneChanged }

    struct Target {
        let session: NativeLocalPTYSession
        /// The future workspace host checks controller AND session identity.
        /// No await is allowed between this check and layout/binding removal.
        let isCurrent: @MainActor () -> Bool
    }

    static func close(_ targets: [Target], then remove: @MainActor () -> Void) async throws {
        try Task.checkCancellation()
        guard Set(targets.map { $0.session.paneID }).count == targets.count else { throw Failure.duplicatePane }
        guard targets.allSatisfy({ $0.isCurrent() }) else { throw Failure.paneChanged }
        // All targets reject new input before the first suspension. Individual
        // cleanup tasks run concurrently; one failure must not abandon others.
        targets.forEach { $0.session.beginClosing() }
        let tasks = targets.map { target in Task { try await target.session.stop() } }
        var firstError: (any Error)?
        for task in tasks {
            do { try await task.value } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
        // Cancellation cannot undo killing a program. Retain the layout on
        // cancellation/failure/stale identity, rather than remove a replacement.
        try Task.checkCancellation()
        guard targets.allSatisfy({ $0.isCurrent() }) else { throw Failure.paneChanged }
        remove()
    }
}
