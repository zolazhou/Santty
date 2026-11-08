import Foundation

/// Owns authorization and a bounded, launch-scoped mutation journal. Keeping the
/// task (not just its result) also coalesces retries while a Herdr close is pending.
@MainActor
final class CLICommandRouter {
    static var controlEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "cliControlEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "cliControlEnabled") }
    }
    static var inputEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "cliInputEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "cliInputEnabled") }
    }

    let instanceID = UUID()
    private struct Entry {
        let request: CLIRequest
        let expires: TimeInterval
        let task: Task<CLIResponse, Never>
    }
    private var journal: [String: Entry] = [:]

    var capabilities: CLICapabilities {
        CLICapabilities(commands: ["list", "read", "search", "capabilities"] + CLIRequest.paneCommands,
                        controlEnabled: Self.controlEnabled, inputEnabled: Self.inputEnabled, instanceID: instanceID)
    }

    func handle(_ request: CLIRequest, workspace: WorkspaceViewController) async -> CLIResponse {
        do {
            try request.validate()
            if request.command == "capabilities" { return CLIResponse(capabilities: capabilities) }
            if !request.isMutation { return try workspace.handleCLIRequest(request) }
            let allowed = request.isInput ? Self.inputEnabled : Self.controlEnabled
            guard allowed else {
                throw CLIError(request.isInput ? "Enable CLI terminal input in Settings → General." : "Enable CLI pane control in Settings → General.", code: "permission_denied")
            }
            guard let rawID = request.requestID, let token = CLIRequestToken(rawValue: rawID) else { throw CLIError("Missing request ID.") }
            try token.validate(instance: instanceID)
            let id = token.rawValue
            var canonicalRequest = request
            canonicalRequest.requestID = id
            if let entry = journal[id] {
                guard entry.request == canonicalRequest else { throw CLIError("Request ID already belongs to a different operation.", code: "request_conflict") }
                return await entry.task.value
            }
            let now = Date().timeIntervalSince1970
            journal = journal.filter { $0.value.expires > now }
            guard journal.count < 2048 else { throw CLIError("Too many recent operations. Wait for retry IDs to expire.", code: "busy") }
            let operation = canonicalRequest
            let task = Task { @MainActor in
                var response: CLIResponse
                do {
                    guard operation.isInput ? Self.inputEnabled : Self.controlEnabled else {
                        throw CLIError("CLI permission was revoked before the operation started.", code: "permission_denied")
                    }
                    response = try await workspace.performCLIPaneRequest(operation)
                } catch { response = CLIResponse.failure(error) }
                response.requestID = id
                return response
            }
            journal[id] = Entry(request: operation, expires: token.issued + CLIRequestToken.lifetime, task: task)
            return await task.value
        } catch {
            var response = CLIResponse.failure(error)
            response.requestID = request.requestID
            return response
        }
    }
}
