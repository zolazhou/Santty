import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] {
    print(CLIInvocation.usage)
    exit(0)
}
var outputJSON = arguments.contains("--json")
var mutationID: String?
do {
    var invocation = try CLIInvocation.parse(arguments)
    outputJSON = invocation.json
    if invocation.readsStdin {
        var data = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 64 * 1024 else { throw CLIError("Input exceeds 64 KiB.") }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw CLIError("stdin must contain UTF-8 text.") }
        invocation.request.text = text
    }
    let environment = ProcessInfo.processInfo.environment
    let candidates: [String]
    if invocation.socket == nil {
        try CLITransport.prepareDirectory()
        candidates = try FileManager.default.contentsOfDirectory(atPath: CLITransport.directory.path)
            .filter { $0.hasSuffix(".sock") }.map { CLITransport.directory.appendingPathComponent($0).path }
    } else { candidates = [] }
    func exchange(_ request: CLIRequest, at path: String) throws -> CLIResponse {
        let fd = try CLITransport.connect(to: path)
        defer { close(fd) }
        if request.isMutation { CLITransport.configure(fd, timeoutSeconds: 30) }
        try CLITransport.write(request, to: fd)
        return try JSONDecoder().decode(CLIResponse.self, from: CLITransport.readLine(fd, limit: CLITransport.maximumResponseBytes))
    }
    let path = try CLIInstanceDiscovery.resolve(explicit: invocation.socket, inherited: environment["SANTTY_CONTROL_SOCKET"], candidates: candidates) {
        try exchange(CLIRequest(command: "list", includeProcesses: false), at: $0)
    }
    if invocation.request.isMutation {
        let response = try exchange(CLIRequest(command: "capabilities"), at: path)
        guard response.version == 2, let capabilities = response.capabilities,
              capabilities.commands.contains(invocation.request.command) else {
            throw CLIError("This Santty server does not support pane control. Update and restart Santty.", code: "unsupported_command")
        }
        if invocation.request.requestID == nil {
            invocation.request.requestID = CLIRequestToken(instance: capabilities.instanceID).rawValue
        }
        mutationID = invocation.request.requestID
    }
    try invocation.request.validate()
    let response: CLIResponse
    do { response = try exchange(invocation.request, at: path) }
    catch {
        if invocation.request.isMutation {
            throw CLIError("Delivery/result is unknown. Inspect pane state or recover using the SAME --request-id \(mutationID ?? ""). Never automatically resend with a new ID.", code: "result_unknown")
        }
        throw error
    }
    guard response.version == 2 else { throw CLIError("CLI protocol mismatch. Reinstall the CLI from Santty settings.") }
    if invocation.json {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(response)); print("")
        if response.error != nil { exit(1) }
    } else {
        if let error = response.error { throw CLIError(error, code: response.errorCode ?? "operation_failed") }
        if invocation.request.command == "list" {
            for tab in response.tabs ?? [] {
                let context = " [\(tab.workspaceName ?? "") \(tab.workspaceID?.uuidString ?? "sidebar")]"
                print("\(tab.isSelected ? "*" : " ") Tab \(tab.id): \(tab.title)\(context)")
                for pane in tab.panes {
                    let name = pane.name.map { "  name=\($0)" } ?? ""
                    print("  \(pane.id)  \(pane.kind)  \(pane.title)\(name)  \(pane.cwd ?? "")")
                    for process in pane.processes { print("    \(process.pid) \(process.command)") }
                }
            }
        } else if let capabilities = response.capabilities {
            print(capabilities.commands.joined(separator: "\n"))
            print("control=\(capabilities.controlEnabled) input=\(capabilities.inputEnabled)")
        } else if invocation.request.isMutation {
            print("\(response.status ?? "ok")\(response.paneID.map { " " + $0.uuidString } ?? "")")
            if let requestID = response.requestID { print("request-id=\(requestID)") }
        } else if invocation.request.command == "search" {
            for match in response.matches ?? [] { print("\(match.line):\(match.text)") }
        } else {
            let text = response.text ?? ""
            FileHandle.standardOutput.write(Data(text.utf8))
            if !text.isEmpty && !text.hasSuffix("\n") { print("") }
        }
        if response.truncated == true {
            FileHandle.standardError.write(Data("santty: output limited by the requested limit or 256 KiB cap; use --json for line metadata.\n".utf8))
        }
    }
} catch {
    if outputJSON {
        var response = CLIResponse.failure(error); response.requestID = mutationID
        if let data = try? JSONEncoder().encode(response) { FileHandle.standardOutput.write(data); print("") }
    } else {
        FileHandle.standardError.write(Data("santty: \(error.localizedDescription)\n".utf8))
        if let mutationID { FileHandle.standardError.write(Data("request-id=\(mutationID)\n".utf8)) }
    }
    exit(1)
}
