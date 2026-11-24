import AppKit

/// Creates targets for the EXISTING PaneInputSourceCoordinator. No second rule
/// engine, source catalog, timer, process scan or automatic system selection.
@MainActor
final class NativeTerminalInputSourcePort {
    enum Failure: Error { case contextChanged }
    let paneID: UUID
    private weak var view: NativeTerminalScrollView?
    private let foreground: @MainActor () async throws -> InputSourceForeground
    private let isCurrent: @MainActor () -> Bool

    init(paneID: UUID, view: NativeTerminalScrollView,
         isCurrent: @escaping @MainActor () -> Bool,
         foreground: @escaping @MainActor () async throws -> InputSourceForeground) {
        self.paneID = paneID; self.view = view; self.isCurrent = isCurrent; self.foreground = foreground
    }

    var target: PaneInputSourceCoordinator.Target? {
        guard let view, isCurrent(), !view.isHiddenOrHasHiddenAncestor, view.renderer.inputEnabled,
              view.window?.firstResponder === view.renderer, !view.scrollModeController.isActive, !view.renderer.hasMarkedText(),
              let output = view.renderer.output, output.driver === view.driver, let lease = output.userInputLease else { return nil }
        return .init(paneID:paneID,view:view.renderer,foreground:{ [weak self, weak output] in
            guard let self, let output, self.matches(output,lease) else { throw Failure.contextChanged }
            let snapshot = try await self.foreground()
            try Task.checkCancellation()
            guard self.matches(output,lease) else { throw Failure.contextChanged }
            return snapshot
        })
    }
    private func matches(_ output: NativeTerminalOutput, _ lease: NativeUserInputLease) -> Bool {
        guard isCurrent(), let view, !view.isHiddenOrHasHiddenAncestor, view.renderer.output === output,
              output.driver === view.driver, view.renderer.inputEnabled,
              view.window?.firstResponder === view.renderer, !view.scrollModeController.isActive, !view.renderer.hasMarkedText() else { return false }
        return output.userInputLease == lease
    }
}
