import Darwin
import Foundation

let usage = """
    Usage:
      santty list [--json] [--socket PATH]
      santty read <pane-id> [--tail N | --start-line N --end-line M] [--json] [--socket PATH]
      santty search <pane-id> <text> [--ignore-case] [--limit N] [--json] [--socket PATH]

    Read terminal text, including retained scrollback, without changing focus or selection.
    --tail defaults to 200 (maximum 10000); output is capped at 256 KiB.
    Ranges are 1-based and inclusive (maximum 10000 lines).
    Search is literal, returns matching lines in buffer order, and defaults to 100 results (maximum 1000).
    Line numbers refer to the current buffer and can change when history is discarded or the screen changes.
    SANTTY_CONTROL_SOCKET is a hint; stale instance paths are rediscovered.
    Inside Herdr, HERDR_PANE_ID and HERDR_SOCKET_PATH select matching native views; ambiguous instances require --socket.
    Persistent read/search covers the backend's most recent 1000 rows, not complete history.
    """

do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] {
        print(usage)
        exit(0)
    }
    let command = arguments.removeFirst()
    var request = CLIRequest(command: command)
    var json = false
    let environment = ProcessInfo.processInfo.environment
    var explicitSocket: String?
    if command == "read" || command == "search" {
        guard let value = arguments.first, let id = UUID(uuidString: value) else {
            throw CLIError("\(command) requires a pane UUID. Run santty list --json first.")
        }
        request.paneID = id
        arguments.removeFirst()
    }
    if command == "search" {
        guard !arguments.isEmpty else { throw CLIError("search requires text to find.") }
        request.query = arguments.removeFirst()
    }
    while !arguments.isEmpty {
        let flag = arguments.removeFirst()
        switch flag {
        case "--json": json = true
        case "--tail":
            guard command == "read", !arguments.isEmpty,
                let count = Int(arguments.removeFirst())
            else { throw CLIError("--tail requires an integer and the read command.") }
            request.tail = count
        case "--start-line", "--end-line", "--limit":
            guard !arguments.isEmpty, let count = Int(arguments.removeFirst()) else {
                throw CLIError("\(flag) requires an integer.")
            }
            if flag == "--start-line" { request.startLine = count }
            if flag == "--end-line" { request.endLine = count }
            if flag == "--limit" { request.limit = count }
        case "--ignore-case": request.ignoreCase = true
        case "--socket":
            guard !arguments.isEmpty else { throw CLIError("--socket requires a path.") }
            explicitSocket = arguments.removeFirst()
        default: throw CLIError("Unknown argument: \(flag)\n\(usage)")
        }
    }
    try request.validate()
    let candidates: [String]
    if explicitSocket == nil {
        try CLITransport.prepareDirectory()
        candidates = try FileManager.default.contentsOfDirectory(
            atPath: CLITransport.directory.path
        )
        .filter { $0.hasSuffix(".sock") }.map { CLITransport.directory.appendingPathComponent($0).path }
    } else { candidates = [] }
    let socketPath = try CLIInstanceDiscovery.resolve(explicit: explicitSocket, inherited: environment["SANTTY_CONTROL_SOCKET"],
        herdrPaneID: environment["HERDR_PANE_ID"], herdrSocketPath: environment["HERDR_SOCKET_PATH"], candidates: candidates) { path in
            let fd = try CLITransport.connect(to: path); defer { close(fd) }
            try CLITransport.write(CLIRequest(command: "list", includeProcesses: false), to: fd)
            return try JSONDecoder().decode(CLIResponse.self, from: CLITransport.readLine(fd, limit: CLITransport.maximumResponseBytes))
        }
    let fd = try CLITransport.connect(to: socketPath)
    defer { close(fd) }
    try CLITransport.write(request, to: fd)
    let data = try CLITransport.readLine(fd, limit: CLITransport.maximumResponseBytes)
    let response = try JSONDecoder().decode(CLIResponse.self, from: data)
    guard response.version == 2 else {
        throw CLIError("CLI protocol mismatch. Reinstall the CLI from Santty settings.")
    }
    if let error = response.error { throw CLIError(error) }
    if !json, response.textSource == "herdr_recent_1000" {
        FileHandle.standardError.write(Data("santty: persistent history is a recent snapshot of at most 1000 rows; line numbers are relative to that snapshot.\n".utf8))
    }
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(response))
        print("")
    } else if command == "list" {
        for tab in response.tabs ?? [] {
            print("\(tab.isSelected ? "*" : " ") Tab \(tab.id): \(tab.title)")
            for pane in tab.panes {
                let name = pane.name.map { "  name=\($0)" } ?? ""
                print("  \(pane.id)  \(pane.kind)  \(pane.title)\(name)  \(pane.cwd ?? "")")
                for process in pane.processes { print("    \(process.pid) \(process.command)") }
            }
        }
    } else if command == "search" {
        for match in response.matches ?? [] {
            print("\(match.line):\(match.text)")
        }
        if response.truncated == true {
            FileHandle.standardError.write(
                Data("santty: search output limited by --limit or the 256 KiB cap.\n".utf8))
        }
    } else {
        let text = response.text ?? ""
        FileHandle.standardOutput.write(Data(text.utf8))
        if !text.isEmpty && !text.hasSuffix("\n") { print("") }
        if response.truncated == true {
            FileHandle.standardError.write(
                Data(
                    "santty: output limited by --tail or the 256 KiB cap; use --json for returned line numbers.\n"
                        .utf8))
        }
    }
} catch {
    FileHandle.standardError.write(Data("santty: \(error.localizedDescription)\n".utf8))
    exit(1)
}
