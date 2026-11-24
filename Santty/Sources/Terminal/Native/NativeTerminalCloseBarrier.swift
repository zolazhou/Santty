import Foundation

/// Finite mixed Local/Herdr owner set. Not a workspace registry or permission
/// grant. Callers choose terminate (explicit close) vs detach (window/app close),
/// and must preserve saved bindings for detached Herdr programs.
@MainActor
enum NativeTerminalCloseBarrier {
    typealias Failure = PaneCloseFailure
    struct Target {
        let session: NativeTerminalPaneSession
        let isCurrent: @MainActor () -> Bool
    }
    static func close(_ targets: [Target], intent: NativeTerminalPaneSession.CloseIntent,
                      then remove: @MainActor () -> Void) async throws {
        let bound = targets.map { target in
            PaneCloseTarget(id:target.session.paneID,owner:target.session,
                validate:{ try target.session.validateClose($0) },begin:{ try target.session.beginClosing($0) },
                finish:{ try await target.session.close($0) },isCurrent:target.isCurrent)
        }
        try await PaneCloseTransaction.perform(bound,intent:intent,then:remove)
    }
}
