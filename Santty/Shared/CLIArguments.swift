import Foundation

struct CLIInvocation {
    static let usage = """
    Usage:
      santty list [--json]
      santty read <pane-id> [--tail N | --start-line N --end-line M] [--json]
      santty search <pane-id> <text> [--ignore-case] [--limit N] [--json]
      santty capabilities [--json]
      santty pane new --workspace <workspace-id> [--type terminal|browser|agents|workspaces] [--focus]
      santty pane split <pane-id> --direction left|right|up|down [--type TYPE] [--focus]
      santty pane close <pane-id> [--force]
      santty pane focus <pane-id> [--activate]
      santty pane rename <pane-id> <name>
      santty pane move <pane-id> --direction left|right|up|down
      santty pane resize <pane-id> --direction left|right|up|down [--amount POINTS]
      santty pane equalize <pane-id>
      santty pane send-text <pane-id> (--text TEXT | --stdin)
      santty pane send-key <pane-id> <key>

    All commands accept --socket PATH and --json. Pane commands require opt-in
    control/input permissions in Settings → General. No implicit focus or Enter.
    Pane commands accept --request-id TOKEN to recover a result within 10 minutes
    of the same app launch. Never blindly repeat a timed-out mutation with a new ID.
    Read: defaults to 200 lines, at most 10000 lines / 256 KiB. Search is literal.
    Input: at most 64 KiB UTF-8. Keys: Enter, Tab, Escape, Backspace, Delete,
    Home, End, PageUp, PageDown, Left/Right/Up/Down, Ctrl+A…Z; Ctrl/Shift modifiers.
    """

    var request: CLIRequest
    var json = false
    var socket: String?
    var readsStdin = false

    static func parse(_ arguments: [String]) throws -> CLIInvocation {
        var args = arguments
        func take(_ description: String) throws -> String {
            guard !args.isEmpty else { throw CLIError("Missing \(description).") }
            return args.removeFirst()
        }
        var command = try take("command")
        if command == "pane" { command += "." + (try take("pane subcommand")) }
        guard ["list", "read", "search", "capabilities"].contains(command) || CLIRequest.paneCommands.contains(command) else {
            throw CLIError("Unknown command: \(command)")
        }
        var result = CLIInvocation(request: CLIRequest(command: command))
        if ["read", "search"].contains(command) || (result.request.isMutation && command != "pane.new") {
            guard let id = UUID(uuidString: try take("pane UUID")) else { throw CLIError("Invalid pane UUID. Run santty list --json.") }
            result.request.paneID = id
        }
        if command == "search" { result.request.query = try take("search text") }
        if command == "pane.rename" { result.request.name = try take("name (use an empty string to clear)") }
        if command == "pane.send-key" { result.request.key = try take("key") }
        var seen: Set<String> = []
        while !args.isEmpty {
            let flag = args.removeFirst()
            guard seen.insert(flag).inserted else { throw CLIError("Duplicate option: \(flag)") }
            switch flag {
            case "--json": result.json = true
            case "--socket": result.socket = try take("socket path")
            case "--request-id": result.request.requestID = try take("request ID")
            case "--workspace":
                guard let id = UUID(uuidString: try take("workspace UUID")) else { throw CLIError("Invalid workspace UUID.") }
                result.request.workspaceID = id
            case "--type": result.request.paneType = try take("pane type")
            case "--direction": result.request.direction = try take("direction")
            case "--text": result.request.text = try take("text")
            case "--stdin": result.readsStdin = true
            case "--focus": result.request.focus = true
            case "--activate": result.request.activate = true
            case "--force": result.request.force = true
            case "--ignore-case": result.request.ignoreCase = true
            case "--tail", "--start-line", "--end-line", "--limit", "--amount":
                guard let count = Int(try take("integer for \(flag)")) else { throw CLIError("\(flag) requires an integer.") }
                switch flag {
                case "--tail": result.request.tail = count
                case "--start-line": result.request.startLine = count
                case "--end-line": result.request.endLine = count
                case "--limit": result.request.limit = count
                default: result.request.amount = count
                }
            default: throw CLIError("Unknown option: \(flag)")
            }
        }
        if result.readsStdin {
            guard command == "pane.send-text", result.request.text == nil else {
                throw CLIError("--stdin requires send-text and cannot be combined with --text.")
            }
        }
        // Validate before connecting. The actual server-scoped retry ID and stdin
        // payload are installed later and validated again before sending.
        var validation = result.request
        if validation.isMutation, validation.requestID == nil {
            validation.requestID = CLIRequestToken(instance: UUID()).rawValue
        }
        if result.readsStdin { validation.text = "stdin" }
        try validation.validate()
        return result
    }
}
