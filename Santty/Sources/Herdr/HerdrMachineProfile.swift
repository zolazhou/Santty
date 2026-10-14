import Foundation

struct HerdrMachineProfile: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let label: String
    let target: String
    let session: String
    let enabled: Bool

    func validate() throws {
        guard id.utf8.count == 32, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !label.isEmpty, label.utf8.count <= 1024, !label.contains(where: \.isNewline),
              !target.isEmpty, target.utf8.count <= 4096, !target.hasPrefix("-"),
              !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !session.isEmpty, session.utf8.count <= 64,
              session.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw CLIError("Invalid saved Herdr machine")
        }
    }

    static func decodeList(_ data: Data) throws -> [Self] {
        guard data.count <= 1024 * 1024 else { throw CLIError("Herdr machine catalog is too large") }
        let profiles = try JSONDecoder().decode([Self].self, from: data)
        guard profiles.count <= 64, Set(profiles.map(\.id)).count == profiles.count else {
            throw CLIError("Invalid or excessive saved Herdr machines")
        }
        for profile in profiles { try profile.validate() }
        return profiles
    }

    static func list(binary: URL) throws -> [Self] {
        let output = try HerdrProcess.run(binary, arguments: ["machine", "list", "--json"])
        guard output.status == 0 else { throw CLIError("Cannot read Herdr machines: " + String(decoding: output.stderr.prefix(4096), as: UTF8.self)) }
        return try decodeList(output.stdout)
    }

    static func setupCommand(binary: URL, target: String, session: String, label: String) throws -> String {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = session.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self(id: String(repeating: "0", count: 32), label: label.isEmpty ? target : label,
                 target: target, session: session.isEmpty ? "default" : session, enabled: true).validate()
        guard binary.isFileURL, binary.path.hasPrefix("/"), !binary.path.contains(where: \.isNewline) else { throw CLIError("Invalid Herdr executable") }
        var args = [binary.path, "machine", "add", target]
        if !session.isEmpty { args += ["--remote-session", session] }
        if !label.isEmpty { args += ["--label", label] }
        return args.map(HerdrSSHBridge.quote).joined(separator: " ")
    }
}
