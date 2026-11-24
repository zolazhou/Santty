import Foundation

/// Read-only pane-bound boundary for the eventual main pane adapter. This is
/// not a socket server, pane resolver, mutation route or authorization grant.
struct NativeTerminalReadService: Sendable {
    let paneID: UUID
    private let driver: GhosttyVTDriver
    private let maximumSnapshotBytes: Int

    init(paneID: UUID, driver: GhosttyVTDriver, maximumSnapshotBytes: Int = GhosttyVTReadSnapshot.maximumBytes) {
        self.paneID = paneID
        self.driver = driver
        self.maximumSnapshotBytes = maximumSnapshotBytes
    }

    func response(_ request: CLIRequest) async throws -> CLIResponse {
        guard request.command == "read" || request.command == "search" else {
            throw CLIError("This terminal endpoint only supports read and search.", code: "read_only")
        }
        try request.validate()
        guard request.paneID == paneID else { throw CLIError("The requested pane does not match this terminal.", code: "pane_changed") }
        try Task.checkCancellation()
        // Do not run full-history formatting/search on the UI executor. The
        // immutable result belongs to this driver, never a replacement pane.
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let text: String
            do { text = try driver.readScreenText(maximumBytes: maximumSnapshotBytes) }
            catch NativeReadSnapshotError.tooLarge {
                throw CLIError("Terminal text exceeds the snapshot safety budget; the buffer was not truncated.", code: "snapshot_too_large")
            }
            catch NativeReadSnapshotError.invalidUTF8 {
                throw CLIError("Terminal text is not valid UTF-8.", code: "read_unavailable")
            }
            try Task.checkCancellation()
            let response = try CLITextSnapshot.response(text, request: request)
            try Task.checkCancellation()
            return response
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
}
