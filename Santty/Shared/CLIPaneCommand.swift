import Foundation

extension CLIRequest {
    func validatePaneCommand() throws {
        guard tail == nil, startLine == nil, endLine == nil, query == nil, ignoreCase == nil,
              limit == nil, includeProcesses == nil else { throw CLIError("Read options cannot be used with pane commands.") }
        guard let requestID, CLIRequestToken(rawValue: requestID) != nil else {
            throw CLIError("Pane commands require a valid request ID.")
        }
        if command == "pane.new" {
            guard workspaceID != nil, paneID == nil else { throw CLIError("pane new requires --workspace and no pane ID.") }
        } else {
            guard paneID != nil, workspaceID == nil else { throw CLIError("This command requires a pane UUID, not --workspace.") }
        }
        let creates = command == "pane.new" || command == "pane.split"
        guard creates || (paneType == nil && focus == nil) else { throw CLIError("--type and --focus require new or split.") }
        if let paneType, !["terminal", "browser", "agents", "workspaces"].contains(paneType) {
            throw CLIError("--type must be terminal, browser, agents or workspaces.")
        }
        let directional = ["pane.split", "pane.move", "pane.resize"].contains(command)
        if directional {
            guard let direction, ["left", "right", "up", "down"].contains(direction) else {
                throw CLIError("--direction must be left, right, up or down.")
            }
        } else if direction != nil { throw CLIError("--direction requires split, move or resize.") }
        guard command == "pane.resize" || amount == nil else { throw CLIError("--amount requires resize.") }
        if command == "pane.resize", !(1...10_000).contains(amount ?? 40) { throw CLIError("--amount must be 1–10000 points.") }
        guard command == "pane.focus" || activate == nil else { throw CLIError("--activate requires focus.") }
        guard command == "pane.close" || force == nil else { throw CLIError("--force requires close.") }
        guard command == "pane.rename" || name == nil else { throw CLIError("A name requires rename.") }
        if command == "pane.rename" {
            guard let name, name.utf8.count <= 1024, !name.contains(where: { $0.isNewline }),
                  !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw CLIError("Name must be a single line of at most 1024 UTF-8 bytes (empty clears it).")
            }
        }
        guard command == "pane.send-text" || text == nil else { throw CLIError("--text requires send-text.") }
        if command == "pane.send-text" {
            guard let text, !text.isEmpty, text.utf8.count <= 64 * 1024, !text.utf8.contains(0) else {
                throw CLIError("Text must be nonempty, without NUL, and at most 64 KiB.")
            }
        }
        guard command == "pane.send-key" || key == nil else { throw CLIError("A key requires send-key.") }
        if command == "pane.send-key" { _ = try CLIKey(key ?? "") }
    }
}

/// Retry IDs are scoped to one app launch and expire, so evicting a journal entry
/// can never turn an old retry into a second mutation. They contain no pane data.
struct CLIRequestToken: Sendable {
    static let lifetime: TimeInterval = 600
    let instance: UUID
    let issued: TimeInterval
    let nonce: UUID
    var rawValue: String { "\(instance.uuidString):\(Int(issued)):\(nonce.uuidString)" }

    init(instance: UUID, now: Date = Date()) {
        self.instance = instance
        issued = floor(now.timeIntervalSince1970)
        nonce = UUID()
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let instance = UUID(uuidString: String(parts[0])),
              let issued = Double(parts[1]), issued.isFinite, issued >= 0,
              issued <= Double(Int.max / 2), issued.rounded(.down) == issued,
              let nonce = UUID(uuidString: String(parts[2])) else { return nil }
        self.instance = instance; self.issued = issued; self.nonce = nonce
    }

    func validate(instance: UUID, now: Date = Date()) throws {
        guard self.instance == instance else { throw CLIError("Request belongs to another app launch. Do not blindly repeat the operation.", code: "stale_request") }
        let age = now.timeIntervalSince1970 - issued
        guard age >= -5, age < Self.lifetime else {
            throw CLIError("Request ID expired. Inspect the pane state before issuing a new operation.", code: "request_expired")
        }
    }
}

/// A deliberately small key vocabulary. No Command chords or arbitrary Ghostty actions.
struct CLIKey: Sendable {
    let base: String
    let control: Bool
    let shift: Bool

    init(_ value: String) throws {
        let parts = value.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let base = parts.last ?? ""
        let modifiers = Array(parts.dropLast())
        let allowed = ["enter", "tab", "escape", "backspace", "delete", "home", "end",
                       "pageup", "pagedown", "left", "right", "up", "down"]
        let letter = base.utf8.count == 1 && base.utf8.allSatisfy { (97...122).contains($0) }
        guard Set(modifiers).count == modifiers.count,
              modifiers.allSatisfy({ ["ctrl", "shift"].contains($0) }),
              allowed.contains(base) || (letter && modifiers.contains("ctrl")) else {
            throw CLIError("Unsupported key. Use Enter, Tab, Escape, Backspace, Delete, Home, End, PageUp, PageDown, arrows or Ctrl+A…Z; optional Ctrl/Shift modifiers.")
        }
        self.base = base; control = modifiers.contains("ctrl"); shift = modifiers.contains("shift")
    }
}
